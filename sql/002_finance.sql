-- =====================================================================
-- 002_finance.sql — the central financial engine.
-- Departments, categories, vendors, accounts, accounting periods,
-- transactions, ledger entries, attachments, budgets.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Document numbering. One row per (scope, year); incremented atomically.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.doc_counters (
  scope     text NOT NULL,
  year      int  NOT NULL,
  last_val  int  NOT NULL DEFAULT 0,
  PRIMARY KEY (scope, year)
);

CREATE OR REPLACE FUNCTION bms.next_doc_no(p_scope text, p_year int, p_prefix text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v int;
BEGIN
  INSERT INTO bms.doc_counters(scope, year, last_val)
       VALUES (p_scope, p_year, 1)
  ON CONFLICT (scope, year)
       DO UPDATE SET last_val = bms.doc_counters.last_val + 1
    RETURNING last_val INTO v;
  RETURN p_prefix || '-' || p_year::text || '-' || lpad(v::text, 4, '0');
END $$;

-- ---------------------------------------------------------------------
-- DEPARTMENTS and CATEGORIES.
-- categories is self-referencing: parent_id NULL = a category,
-- parent_id set = a sub-category. One table, unlimited depth.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.departments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  description text,
  sort_order  int NOT NULL DEFAULT 100,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bms.categories (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  department_id uuid NOT NULL REFERENCES bms.departments(id) ON DELETE RESTRICT,
  parent_id     uuid REFERENCES bms.categories(id) ON DELETE RESTRICT,
  name          text NOT NULL,
  txn_type      text NOT NULL DEFAULT 'EXPENSE'
                CHECK (txn_type IN ('INCOME','EXPENSE','BOTH')),
  is_active     boolean NOT NULL DEFAULT true,
  sort_order    int NOT NULL DEFAULT 100,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (department_id, parent_id, name)
);
CREATE INDEX IF NOT EXISTS categories_dept_idx ON bms.categories(department_id);

-- The UNIQUE above does NOT stop the same top-level category being created
-- twice, because parent_id is NULL on every one of them and a unique index
-- treats each NULL as distinct. That made ON CONFLICT DO NOTHING in the
-- seed a no-op, so every re-run of the migrations silently duplicated the
-- whole category list. This partial index is what actually enforces "one
-- category of this name per department".
CREATE UNIQUE INDEX IF NOT EXISTS categories_dept_name_uq
  ON bms.categories (department_id, name) WHERE parent_id IS NULL;

-- A category may not be its own ancestor, and may not sit under a
-- category from a different department.
CREATE OR REPLACE FUNCTION bms.categories_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_parent_dept uuid; v_cursor uuid; v_depth int := 0;
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    IF NEW.parent_id = NEW.id THEN
      RAISE EXCEPTION 'A category cannot be its own parent';
    END IF;
    SELECT department_id INTO v_parent_dept FROM bms.categories WHERE id = NEW.parent_id;
    IF v_parent_dept IS DISTINCT FROM NEW.department_id THEN
      RAISE EXCEPTION 'Sub-category must belong to the same department as its parent';
    END IF;
    v_cursor := NEW.parent_id;
    WHILE v_cursor IS NOT NULL AND v_depth < 20 LOOP
      IF v_cursor = NEW.id THEN
        RAISE EXCEPTION 'Category hierarchy would form a loop';
      END IF;
      SELECT parent_id INTO v_cursor FROM bms.categories WHERE id = v_cursor;
      v_depth := v_depth + 1;
    END LOOP;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_categories_guard ON bms.categories;
CREATE TRIGGER trg_categories_guard BEFORE INSERT OR UPDATE ON bms.categories
  FOR EACH ROW EXECUTE FUNCTION bms.categories_guard();

-- ---------------------------------------------------------------------
-- VENDORS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.vendors (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL,
  vendor_type    text,
  contact_person text,
  mobile         text,
  email          text,
  address        text,
  notes          text,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid REFERENCES auth.users(id)
);
CREATE UNIQUE INDEX IF NOT EXISTS vendors_name_uq ON bms.vendors (lower(name));

-- ---------------------------------------------------------------------
-- ACCOUNTS — bank, cash, mobile wallet, fixed-deposit holding accounts.
-- current_balance is NOT stored; see bms.v_account_balances.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.accounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code            text NOT NULL UNIQUE,
  name            text NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('BANK','CASH','MOBILE_WALLET','FD')),
  bank_name       text,
  branch          text,
  account_type    text,
  opening_balance bms.money_amount NOT NULL DEFAULT 0,
  opening_date    date NOT NULL DEFAULT CURRENT_DATE,
  is_active       boolean NOT NULL DEFAULT true,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid REFERENCES auth.users(id)
);

-- Account number lives in its own table so RLS can grant the ledger
-- without granting the number.
CREATE TABLE IF NOT EXISTS bms.account_secrets (
  account_id     uuid PRIMARY KEY REFERENCES bms.accounts(id) ON DELETE CASCADE,
  account_number text,
  routing_number text,
  extra          jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid REFERENCES auth.users(id)
);

-- ---------------------------------------------------------------------
-- ACCOUNTING PERIODS — a closed month cannot be written to.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.accounting_periods (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  period_year  int NOT NULL CHECK (period_year BETWEEN 2000 AND 2200),
  period_month int NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  status       text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED')),
  closed_by    uuid REFERENCES auth.users(id),
  closed_at    timestamptz,
  notes        text,
  UNIQUE (period_year, period_month)
);

-- Returns the period for a date, creating it OPEN if it does not exist.
CREATE OR REPLACE FUNCTION bms.period_for(p_date date)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM bms.accounting_periods
   WHERE period_year = EXTRACT(YEAR FROM p_date)::int
     AND period_month = EXTRACT(MONTH FROM p_date)::int;
  IF v_id IS NULL THEN
    INSERT INTO bms.accounting_periods(period_year, period_month)
    VALUES (EXTRACT(YEAR FROM p_date)::int, EXTRACT(MONTH FROM p_date)::int)
    ON CONFLICT (period_year, period_month) DO UPDATE SET notes = bms.accounting_periods.notes
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION bms.period_is_closed(p_date date)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT COALESCE((SELECT status = 'CLOSED' FROM bms.accounting_periods
                    WHERE period_year = EXTRACT(YEAR FROM p_date)::int
                      AND period_month = EXTRACT(MONTH FROM p_date)::int), false)
$$;

-- ---------------------------------------------------------------------
-- TRANSACTIONS — the one ledger every module writes to.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.transactions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  txn_no             text UNIQUE,
  txn_date           date NOT NULL,
  direction          text NOT NULL CHECK (direction IN ('INCOME','EXPENSE','TRANSFER')),
  department_id      uuid REFERENCES bms.departments(id) ON DELETE RESTRICT,
  category_id        uuid REFERENCES bms.categories(id)  ON DELETE RESTRICT,
  description        text NOT NULL,
  amount             bms.money_amount NOT NULL CHECK (amount > 0),
  payment_method     text NOT NULL DEFAULT 'CASH'
                     CHECK (payment_method IN ('CASH','BANK_TRANSFER','CHEQUE','BKASH','NAGAD','ROCKET','CARD','ADJUSTMENT')),
  account_id         uuid REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  counter_account_id uuid REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  vendor_id          uuid REFERENCES bms.vendors(id)  ON DELETE RESTRICT,
  flat_id            uuid,   -- FK added in 003 once bms.flats exists
  staff_id           uuid,   -- FK added in 004 once bms.staff exists
  reference_no       text,
  status             text NOT NULL DEFAULT 'DRAFT'
                     CHECK (status IN ('DRAFT','SUBMITTED','PENDING_APPROVAL','APPROVED',
                                       'REJECTED','RETURNED','POSTED','REVERSED','CANCELLED')),
  period_id          uuid REFERENCES bms.accounting_periods(id),
  notes              text,
  rejected_reason    text,
  source_module      text,
  source_ref         uuid,
  is_reversal        boolean NOT NULL DEFAULT false,
  reversal_of_txn_id uuid REFERENCES bms.transactions(id),
  reversed_by_txn_id uuid REFERENCES bms.transactions(id),
  reversal_reason    text,
  created_by         uuid REFERENCES auth.users(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  submitted_by       uuid REFERENCES auth.users(id),
  submitted_at       timestamptz,
  approved_by        uuid REFERENCES auth.users(id),
  approved_at        timestamptz,
  posted_at          timestamptz,
  updated_at         timestamptz NOT NULL DEFAULT now(),

  -- A transfer needs both ends, and they must differ.
  CONSTRAINT txn_transfer_ck CHECK (
    (direction <> 'TRANSFER')
    OR (account_id IS NOT NULL AND counter_account_id IS NOT NULL
        AND account_id <> counter_account_id)
  ),
  -- Income and expense never have a counter account.
  CONSTRAINT txn_non_transfer_ck CHECK (
    direction = 'TRANSFER' OR counter_account_id IS NULL
  )
);
CREATE INDEX IF NOT EXISTS txn_date_idx       ON bms.transactions(txn_date);
CREATE INDEX IF NOT EXISTS txn_status_idx     ON bms.transactions(status);
CREATE INDEX IF NOT EXISTS txn_dept_idx       ON bms.transactions(department_id);
CREATE INDEX IF NOT EXISTS txn_account_idx    ON bms.transactions(account_id);
CREATE INDEX IF NOT EXISTS txn_source_idx     ON bms.transactions(source_module, source_ref);
CREATE INDEX IF NOT EXISTS txn_flat_idx       ON bms.transactions(flat_id);

-- ---------------------------------------------------------------------
-- LEDGER ENTRIES — machine-written when a transaction posts.
-- Every balance in the system is a SUM over this table and nothing else.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.ledger_entries (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  txn_id         uuid NOT NULL REFERENCES bms.transactions(id) ON DELETE RESTRICT,
  account_id     uuid NOT NULL REFERENCES bms.accounts(id)     ON DELETE RESTRICT,
  entry_date     date NOT NULL,
  signed_amount  bms.money_amount NOT NULL CHECK (signed_amount <> 0),
  memo           text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ledger_account_idx ON bms.ledger_entries(account_id, entry_date);
CREATE INDEX IF NOT EXISTS ledger_txn_idx     ON bms.ledger_entries(txn_id);

-- ---------------------------------------------------------------------
-- ATTACHMENTS — polymorphic file index. The database is the index;
-- a storage object with no row here is an orphan.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.attachments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket        text NOT NULL CHECK (bucket IN ('bms-receipts','bms-photos','bms-documents')),
  storage_path  text NOT NULL UNIQUE,
  entity_table  text NOT NULL,
  entity_id     uuid NOT NULL,
  file_name     text NOT NULL,
  mime_type     text NOT NULL,
  size_bytes    bigint NOT NULL CHECK (size_bytes > 0),
  checksum      text,
  caption       text,
  supersedes_id uuid REFERENCES bms.attachments(id),
  uploaded_by   uuid REFERENCES auth.users(id),
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  deleted_by    uuid REFERENCES auth.users(id),
  CONSTRAINT attachments_entity_ck CHECK (entity_table IN
    ('transactions','issues','asset_service_logs','asset_inspections','assets',
     'staff','salary_payments','fixed_deposits','bank_statements','work_logs',
     'payments','flats','fuel_purchases','generator_runs'))
);
CREATE INDEX IF NOT EXISTS attachments_entity_idx ON bms.attachments(entity_table, entity_id) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- BUDGETS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.budgets (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fiscal_year   int NOT NULL CHECK (fiscal_year BETWEEN 2000 AND 2200),
  department_id uuid NOT NULL REFERENCES bms.departments(id) ON DELETE RESTRICT,
  category_id   uuid REFERENCES bms.categories(id) ON DELETE RESTRICT,
  annual_amount bms.money_amount NOT NULL CHECK (annual_amount >= 0),
  notes         text,
  created_by    uuid REFERENCES auth.users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fiscal_year, department_id, category_id)
);

-- The UNIQUE above does NOT stop two department-level budgets for the
-- same year, because a unique index treats each NULL category as
-- distinct. This partial index is what actually enforces "one budget per
-- department per year".
CREATE UNIQUE INDEX IF NOT EXISTS budgets_dept_year_uq
  ON bms.budgets (fiscal_year, department_id) WHERE category_id IS NULL;

CREATE TABLE IF NOT EXISTS bms.budget_lines (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  budget_id    uuid NOT NULL REFERENCES bms.budgets(id) ON DELETE CASCADE,
  period_month int NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  amount       bms.money_amount NOT NULL DEFAULT 0 CHECK (amount >= 0),
  UNIQUE (budget_id, period_month)
);

-- Late FK: settings points at an account, and accounts is defined here.
DO $$ BEGIN
  ALTER TABLE bms.building_settings
    ADD CONSTRAINT settings_cash_account_fk
    FOREIGN KEY (default_cash_account_id) REFERENCES bms.accounts(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DROP TRIGGER IF EXISTS trg_departments_updated ON bms.departments;
DROP TRIGGER IF EXISTS trg_categories_updated  ON bms.categories;
DROP TRIGGER IF EXISTS trg_vendors_updated     ON bms.vendors;
DROP TRIGGER IF EXISTS trg_accounts_updated    ON bms.accounts;
DROP TRIGGER IF EXISTS trg_txn_updated         ON bms.transactions;
DROP TRIGGER IF EXISTS trg_budgets_updated     ON bms.budgets;
CREATE TRIGGER trg_departments_updated BEFORE UPDATE ON bms.departments  FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_categories_updated  BEFORE UPDATE ON bms.categories   FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_vendors_updated     BEFORE UPDATE ON bms.vendors      FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_accounts_updated    BEFORE UPDATE ON bms.accounts     FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_txn_updated         BEFORE UPDATE ON bms.transactions FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_budgets_updated     BEFORE UPDATE ON bms.budgets      FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
