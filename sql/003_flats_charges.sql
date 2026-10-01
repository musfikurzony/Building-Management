-- =====================================================================
-- 003_flats_charges.sql — flats, owners, occupancy, and the service
-- charge receivable ledger.
--
-- flat_charges = what is OWED (accrual).
-- transactions = what ARRIVED (cash).
-- A payment writes to both, exactly once.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- OWNERS — people, kept separate from flats so an owner can hold more
-- than one flat and survives a flat changing hands.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.owners (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  mobile        text,
  email         text,
  alt_contact   text,
  address       text,
  notes         text,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid REFERENCES auth.users(id)
);

-- ---------------------------------------------------------------------
-- FLATS — the master. service_charge is PER FLAT; NULL falls back to
-- building_settings.default_service_charge.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.flats (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_number    text NOT NULL UNIQUE,
  floor          int  NOT NULL CHECK (floor >= 0),
  area_sqft      numeric(10,2) CHECK (area_sqft IS NULL OR area_sqft > 0),
  service_charge bms.money_amount CHECK (service_charge IS NULL OR service_charge >= 0),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
  notes          text,
  sort_order     int,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid REFERENCES auth.users(id)
);
CREATE INDEX IF NOT EXISTS flats_floor_idx ON bms.flats(floor);

-- Late FK from transactions, now that flats exists.
DO $$ BEGIN
  ALTER TABLE bms.transactions
    ADD CONSTRAINT transactions_flat_fk
    FOREIGN KEY (flat_id) REFERENCES bms.flats(id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------
-- OCCUPANCY — who was responsible for a flat, and when. Answers
-- "who owed this in March?" correctly even after a sale.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.flat_occupancy (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_id       uuid NOT NULL REFERENCES bms.flats(id)  ON DELETE CASCADE,
  owner_id      uuid NOT NULL REFERENCES bms.owners(id) ON DELETE RESTRICT,
  relation_type text NOT NULL DEFAULT 'OWNER' CHECK (relation_type IN ('OWNER','TENANT')),
  is_billed     boolean NOT NULL DEFAULT true,   -- who receives the bill
  from_date     date NOT NULL DEFAULT CURRENT_DATE,
  to_date       date,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT occupancy_dates_ck CHECK (to_date IS NULL OR to_date >= from_date)
);
CREATE INDEX IF NOT EXISTS occupancy_flat_idx ON bms.flat_occupancy(flat_id);
-- At most one current billed occupant per flat.
CREATE UNIQUE INDEX IF NOT EXISTS occupancy_one_current_billed
  ON bms.flat_occupancy(flat_id) WHERE to_date IS NULL AND is_billed;

-- Links a login to a flat. Dormant until the owner portal; costs nothing now.
CREATE TABLE IF NOT EXISTS bms.flat_users (
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  flat_id    uuid NOT NULL REFERENCES bms.flats(id)  ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, flat_id)
);

-- ---------------------------------------------------------------------
-- CHARGE RUNS — one per generated month. UNIQUE(year, month) makes
-- generation idempotent: pressing the button twice cannot double-bill.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.charge_runs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  period_year  int NOT NULL CHECK (period_year BETWEEN 2000 AND 2200),
  period_month int NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  run_type     text NOT NULL DEFAULT 'MONTHLY' CHECK (run_type IN ('MONTHLY','OPENING')),
  flat_count   int NOT NULL DEFAULT 0,
  total_amount bms.money_amount NOT NULL DEFAULT 0,
  notes        text,
  generated_by uuid REFERENCES auth.users(id),
  generated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (period_year, period_month, run_type)
);

-- ---------------------------------------------------------------------
-- FLAT CHARGES — what each flat owes for each month.
-- net_payable is a GENERATED column, so it can never disagree with its
-- own parts. Payment status is DERIVED (see v_flat_charges), never stored.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.flat_charges (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id            uuid REFERENCES bms.charge_runs(id) ON DELETE RESTRICT,
  flat_id           uuid NOT NULL REFERENCES bms.flats(id) ON DELETE RESTRICT,
  period_year       int NOT NULL CHECK (period_year BETWEEN 2000 AND 2200),
  period_month      int NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  charge_source     text NOT NULL DEFAULT 'MONTHLY' CHECK (charge_source IN ('MONTHLY','OPENING')),
  charge_amount     bms.money_amount NOT NULL DEFAULT 0 CHECK (charge_amount >= 0),
  adjustment_amount bms.money_amount NOT NULL DEFAULT 0,
  waiver_amount     bms.money_amount NOT NULL DEFAULT 0 CHECK (waiver_amount >= 0),
  net_payable       numeric(14,2) GENERATED ALWAYS AS
                    (charge_amount + adjustment_amount - waiver_amount) STORED,
  due_date          date NOT NULL,
  is_cancelled      boolean NOT NULL DEFAULT false,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (flat_id, period_year, period_month, charge_source)
);
CREATE INDEX IF NOT EXISTS flat_charges_flat_idx   ON bms.flat_charges(flat_id);
CREATE INDEX IF NOT EXISTS flat_charges_period_idx ON bms.flat_charges(period_year, period_month);

-- Itemised breakdown, so a bill can show more than one line without
-- needing new tables later.
CREATE TABLE IF NOT EXISTS bms.charge_line_items (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_charge_id uuid NOT NULL REFERENCES bms.flat_charges(id) ON DELETE CASCADE,
  label          text NOT NULL,
  kind           text NOT NULL DEFAULT 'SERVICE'
                 CHECK (kind IN ('SERVICE','UTILITY','PENALTY','OPENING','OTHER')),
  amount         bms.money_amount NOT NULL,
  sort_order     int NOT NULL DEFAULT 100
);
CREATE INDEX IF NOT EXISTS charge_lines_parent_idx ON bms.charge_line_items(flat_charge_id);

-- ---------------------------------------------------------------------
-- PAYMENTS and their ALLOCATIONS.
-- advance(flat) = SUM(payments.amount) - SUM(allocations.amount)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.payments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_no    text UNIQUE,
  flat_id       uuid NOT NULL REFERENCES bms.flats(id) ON DELETE RESTRICT,
  payer_name    text,
  payment_date  date NOT NULL,
  amount        bms.money_amount NOT NULL CHECK (amount > 0),
  method        text NOT NULL DEFAULT 'CASH'
                CHECK (method IN ('CASH','BANK_TRANSFER','CHEQUE','BKASH','NAGAD','ROCKET','CARD')),
  account_id    uuid NOT NULL REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  reference_no  text,
  txn_id        uuid REFERENCES bms.transactions(id),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','REVERSED')),
  reversal_reason text,
  notes         text,
  received_by   uuid REFERENCES auth.users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS payments_flat_idx ON bms.payments(flat_id, payment_date);

CREATE TABLE IF NOT EXISTS bms.payment_allocations (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id     uuid NOT NULL REFERENCES bms.payments(id)     ON DELETE CASCADE,
  flat_charge_id uuid NOT NULL REFERENCES bms.flat_charges(id) ON DELETE RESTRICT,
  amount         bms.money_amount NOT NULL CHECK (amount > 0),
  allocated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS alloc_payment_idx ON bms.payment_allocations(payment_id);
CREATE INDEX IF NOT EXISTS alloc_charge_idx  ON bms.payment_allocations(flat_charge_id);

-- ---------------------------------------------------------------------
-- ADJUSTMENTS — waivers, discounts, penalties, corrections.
-- A waiver NEVER edits charge_amount; it lands here with a reason and an
-- approver, and a trigger folds approved rows into the parent charge.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.adjustments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_id        uuid NOT NULL REFERENCES bms.flats(id) ON DELETE RESTRICT,
  flat_charge_id uuid NOT NULL REFERENCES bms.flat_charges(id) ON DELETE CASCADE,
  adj_type       text NOT NULL CHECK (adj_type IN ('WAIVER','DISCOUNT','PENALTY','CORRECTION')),
  amount         bms.money_amount NOT NULL CHECK (amount > 0),
  reason         text NOT NULL,
  status         text NOT NULL DEFAULT 'PENDING'
                 CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
  requested_by   uuid REFERENCES auth.users(id),
  requested_at   timestamptz NOT NULL DEFAULT now(),
  approved_by    uuid REFERENCES auth.users(id),
  approved_at    timestamptz,
  rejected_reason text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS adjustments_charge_idx ON bms.adjustments(flat_charge_id);

-- Fold approved adjustments into the parent charge. WAIVER and DISCOUNT
-- reduce; PENALTY increases; CORRECTION adjusts either way.
CREATE OR REPLACE FUNCTION bms.recalc_flat_charge_adjustments() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_charge uuid;
BEGIN
  v_charge := COALESCE(NEW.flat_charge_id, OLD.flat_charge_id);
  UPDATE bms.flat_charges fc
     SET waiver_amount = COALESCE((
           SELECT SUM(a.amount) FROM bms.adjustments a
            WHERE a.flat_charge_id = v_charge AND a.status = 'APPROVED'
              AND a.adj_type IN ('WAIVER','DISCOUNT')), 0),
         adjustment_amount = COALESCE((
           SELECT SUM(CASE WHEN a.adj_type = 'PENALTY' THEN a.amount ELSE a.amount END)
             FROM bms.adjustments a
            WHERE a.flat_charge_id = v_charge AND a.status = 'APPROVED'
              AND a.adj_type IN ('PENALTY','CORRECTION')), 0)
   WHERE fc.id = v_charge;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_adjustments_recalc ON bms.adjustments;
CREATE TRIGGER trg_adjustments_recalc
  AFTER INSERT OR UPDATE OR DELETE ON bms.adjustments
  FOR EACH ROW EXECUTE FUNCTION bms.recalc_flat_charge_adjustments();

-- A charge can never be over-allocated.
CREATE OR REPLACE FUNCTION bms.guard_allocation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_net numeric(14,2); v_allocated numeric(14,2);
BEGIN
  SELECT net_payable INTO v_net FROM bms.flat_charges WHERE id = NEW.flat_charge_id;
  SELECT COALESCE(SUM(amount),0) INTO v_allocated
    FROM bms.payment_allocations WHERE flat_charge_id = NEW.flat_charge_id AND id <> NEW.id;
  IF v_allocated + NEW.amount > v_net + 0.001 THEN
    RAISE EXCEPTION 'Allocation of % would exceed the charge (net %, already allocated %)',
      NEW.amount, v_net, v_allocated;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_alloc_guard ON bms.payment_allocations;
CREATE TRIGGER trg_alloc_guard BEFORE INSERT OR UPDATE ON bms.payment_allocations
  FOR EACH ROW EXECUTE FUNCTION bms.guard_allocation();

DROP TRIGGER IF EXISTS trg_owners_updated       ON bms.owners;
DROP TRIGGER IF EXISTS trg_flats_updated        ON bms.flats;
DROP TRIGGER IF EXISTS trg_flat_charges_updated ON bms.flat_charges;
DROP TRIGGER IF EXISTS trg_payments_updated     ON bms.payments;
DROP TRIGGER IF EXISTS trg_adjustments_updated  ON bms.adjustments;
CREATE TRIGGER trg_owners_updated       BEFORE UPDATE ON bms.owners       FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_flats_updated        BEFORE UPDATE ON bms.flats        FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_flat_charges_updated BEFORE UPDATE ON bms.flat_charges FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_payments_updated     BEFORE UPDATE ON bms.payments     FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_adjustments_updated  BEFORE UPDATE ON bms.adjustments  FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
