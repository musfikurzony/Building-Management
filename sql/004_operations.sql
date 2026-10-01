-- =====================================================================
-- 004_operations.sql — Phase 3: the physical building and the people
-- who look after it.
--
-- Three ideas keep this from becoming nine separate modules:
--
--   1. ONE ASSET REGISTER. A generator, a lift and a fire extinguisher
--      are all things with a location, a service provider, a warranty,
--      a next-service date and a photo. They differ only in their
--      type-specific details, which live in a `specs` JSONB. Adding a
--      water pump or a CCTV camera later is one row, not one module.
--
--   2. ONE CHECKLIST ENGINE. The cleaner's round, the gardener's week
--      and the guard's patrol are the same shape: a template of items,
--      a daily log, a tick per item, an optional photo.
--
--   3. ONE LEDGER. Nothing here stores an amount that a report reads.
--      Fuel, servicing, parts, repairs and salaries all carry a txn_id
--      into bms.transactions.
--
-- The mosque is not a table. It is a department, its imam is a row in
-- staff, and its electricity bill is a row in transactions.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- ASSETS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.assets (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_code          text NOT NULL UNIQUE,
  asset_type          text NOT NULL CHECK (asset_type IN
                        ('GENERATOR','LIFT','FIRE_EXTINGUISHER','WATER_PUMP',
                         'SUBSTATION','CCTV','TANK','OTHER')),
  name                text NOT NULL,
  location            text,
  floor               int CHECK (floor IS NULL OR floor >= 0),
  department_id       uuid REFERENCES bms.departments(id) ON DELETE RESTRICT,
  manufacturer        text,
  model               text,
  capacity            text,                 -- "150 kVA", "8 persons", "5 kg"
  serial_no           text,
  installation_date   date,
  warranty_expiry     date,
  service_provider_id uuid REFERENCES bms.vendors(id) ON DELETE RESTRICT,
  service_interval_days int CHECK (service_interval_days IS NULL OR service_interval_days > 0),
  last_service_date   date,
  next_service_date   date,
  last_inspection_date date,
  next_inspection_date date,
  condition           text NOT NULL DEFAULT 'GOOD'
                      CHECK (condition IN ('GOOD','FAIR','POOR','OUT_OF_ORDER')),
  status              text NOT NULL DEFAULT 'ACTIVE'
                      CHECK (status IN ('ACTIVE','UNDER_REPAIR','RETIRED')),
  purchase_cost       bms.money_amount CHECK (purchase_cost IS NULL OR purchase_cost >= 0),
  photo_path          text,
  -- Type-specific details that are never summed or filtered on:
  -- a generator's fuel type, a lift's floors served, an extinguisher's
  -- class and refill date.
  specs               jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid REFERENCES auth.users(id)
);
CREATE INDEX IF NOT EXISTS assets_type_idx    ON bms.assets(asset_type) WHERE status <> 'RETIRED';
CREATE INDEX IF NOT EXISTS assets_service_idx ON bms.assets(next_service_date);
CREATE INDEX IF NOT EXISTS assets_inspect_idx ON bms.assets(next_inspection_date);

-- Servicing, repairs, breakdowns and part replacements — one history.
CREATE TABLE IF NOT EXISTS bms.asset_service_logs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id       uuid NOT NULL REFERENCES bms.assets(id) ON DELETE RESTRICT,
  service_date   date NOT NULL,
  service_type   text NOT NULL CHECK (service_type IN
                   ('ROUTINE','REPAIR','BREAKDOWN','PART_REPLACEMENT','INSPECTION','OTHER')),
  vendor_id      uuid REFERENCES bms.vendors(id) ON DELETE RESTRICT,
  technician     text,
  description    text NOT NULL,
  cost           bms.money_amount NOT NULL DEFAULT 0 CHECK (cost >= 0),
  txn_id         uuid REFERENCES bms.transactions(id),
  downtime_hours numeric(8,2) CHECK (downtime_hours IS NULL OR downtime_hours >= 0),
  result_status  text NOT NULL DEFAULT 'COMPLETED'
                 CHECK (result_status IN ('COMPLETED','PENDING_PARTS','FAILED')),
  checklist      jsonb NOT NULL DEFAULT '{}'::jsonb,
  next_due_date  date,
  performed_by   uuid REFERENCES auth.users(id),
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS service_asset_idx ON bms.asset_service_logs(asset_id, service_date DESC);

CREATE TABLE IF NOT EXISTS bms.asset_parts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_log_id  uuid NOT NULL REFERENCES bms.asset_service_logs(id) ON DELETE CASCADE,
  part_name       text NOT NULL,
  quantity        numeric(10,2) NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_cost       bms.money_amount NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  total_cost      numeric(14,2) GENERATED ALWAYS AS (quantity * unit_cost) STORED,
  warranty_months int CHECK (warranty_months IS NULL OR warranty_months >= 0),
  notes           text
);

-- Fire extinguisher and safety inspections.
CREATE TABLE IF NOT EXISTS bms.asset_inspections (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id             uuid NOT NULL REFERENCES bms.assets(id) ON DELETE RESTRICT,
  inspection_date      date NOT NULL,
  inspector            text,
  result               text NOT NULL CHECK (result IN ('PASS','NEEDS_ATTENTION','FAIL')),
  pressure_ok          boolean,
  seal_ok              boolean,
  access_clear         boolean,
  next_inspection_date date,
  photo_path           text,
  remarks              text,
  recorded_by          uuid REFERENCES auth.users(id),
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS inspection_asset_idx ON bms.asset_inspections(asset_id, inspection_date DESC);

-- Generator hour meters, water meters, electricity meters — one shape.
CREATE TABLE IF NOT EXISTS bms.asset_meter_readings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id      uuid NOT NULL REFERENCES bms.assets(id) ON DELETE RESTRICT,
  reading_date  date NOT NULL,
  reading_value numeric(14,2) NOT NULL CHECK (reading_value >= 0),
  unit          text NOT NULL DEFAULT 'HOURS',
  recorded_by   uuid REFERENCES auth.users(id),
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (asset_id, reading_date)
);

-- ---------------------------------------------------------------------
-- GENERATOR OPERATION
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.generator_runs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id          uuid NOT NULL REFERENCES bms.assets(id) ON DELETE RESTRICT,
  outage_start      timestamptz,
  gen_start         timestamptz NOT NULL,
  gen_stop          timestamptz,
  outage_end        timestamptz,
  duration_minutes  int GENERATED ALWAYS AS
                    (CASE WHEN gen_stop IS NULL THEN NULL
                          ELSE GREATEST(0, (EXTRACT(EPOCH FROM (gen_stop - gen_start)) / 60)::int)
                     END) STORED,
  reason            text NOT NULL DEFAULT 'POWER_CUT'
                    CHECK (reason IN ('POWER_CUT','TESTING','MAINTENANCE','OTHER')),
  hour_meter_start  numeric(14,2),
  hour_meter_stop   numeric(14,2),
  fuel_used_litres  numeric(10,2) CHECK (fuel_used_litres IS NULL OR fuel_used_litres >= 0),
  problem_remark    text,
  -- The hook for automatic monitoring later. Nothing else changes when
  -- a sensor starts writing these rows instead of the caretaker.
  source            text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL','AUTO')),
  recorded_by       uuid REFERENCES auth.users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gen_run_order_ck CHECK (gen_stop IS NULL OR gen_stop >= gen_start)
);
CREATE INDEX IF NOT EXISTS gen_runs_idx ON bms.generator_runs(asset_id, gen_start DESC);

CREATE TABLE IF NOT EXISTS bms.fuel_purchases (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id           uuid REFERENCES bms.assets(id) ON DELETE RESTRICT,
  purchase_date      date NOT NULL,
  fuel_type          text NOT NULL DEFAULT 'DIESEL'
                     CHECK (fuel_type IN ('DIESEL','OCTANE','PETROL','ENGINE_OIL','COOLANT','OTHER')),
  quantity           numeric(10,3) NOT NULL CHECK (quantity > 0),
  unit               text NOT NULL DEFAULT 'LITRE' CHECK (unit IN ('LITRE','KG','PIECE')),
  unit_price         bms.money_amount NOT NULL CHECK (unit_price >= 0),
  total_amount       numeric(14,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  vendor_id          uuid REFERENCES bms.vendors(id) ON DELETE RESTRICT,
  invoice_no         text,
  hour_meter_reading numeric(14,2),
  txn_id             uuid REFERENCES bms.transactions(id),
  entered_by         uuid REFERENCES auth.users(id),
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fuel_date_idx ON bms.fuel_purchases(purchase_date DESC);

-- ---------------------------------------------------------------------
-- MAINTENANCE ISSUES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.issues (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_no           text UNIQUE,
  department_id      uuid REFERENCES bms.departments(id) ON DELETE RESTRICT,
  asset_id           uuid REFERENCES bms.assets(id) ON DELETE RESTRICT,
  flat_id            uuid REFERENCES bms.flats(id) ON DELETE RESTRICT,
  location           text,
  floor              int,
  title              text NOT NULL,
  description        text,
  priority           text NOT NULL DEFAULT 'MEDIUM'
                     CHECK (priority IN ('LOW','MEDIUM','HIGH','CRITICAL')),
  status             text NOT NULL DEFAULT 'OPEN'
                     CHECK (status IN ('OPEN','ASSIGNED','IN_PROGRESS','COMPLETED','VERIFIED','CANCELLED')),
  reported_by        uuid REFERENCES auth.users(id),
  reported_at        timestamptz NOT NULL DEFAULT now(),
  assigned_staff_id  uuid,        -- FK added below, once staff exists
  assigned_vendor_id uuid REFERENCES bms.vendors(id) ON DELETE RESTRICT,
  assigned_at        timestamptz,
  due_at             timestamptz,           -- from the priority SLA in settings
  estimated_cost     bms.money_amount CHECK (estimated_cost IS NULL OR estimated_cost >= 0),
  actual_cost        bms.money_amount CHECK (actual_cost IS NULL OR actual_cost >= 0),
  txn_id             uuid REFERENCES bms.transactions(id),
  resolution         text,
  completed_at       timestamptz,
  verified_by        uuid REFERENCES auth.users(id),
  verified_at        timestamptz,
  cancel_reason      text,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS issues_status_idx ON bms.issues(status) WHERE status NOT IN ('VERIFIED','CANCELLED');
CREATE INDEX IF NOT EXISTS issues_asset_idx  ON bms.issues(asset_id);

CREATE TABLE IF NOT EXISTS bms.issue_updates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_id    uuid NOT NULL REFERENCES bms.issues(id) ON DELETE CASCADE,
  note        text,
  status_from text,
  status_to   text,
  photo_path  text,
  created_by  uuid REFERENCES auth.users(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS issue_updates_idx ON bms.issue_updates(issue_id, created_at);

-- ---------------------------------------------------------------------
-- STAFF
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.staff_positions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code          text NOT NULL UNIQUE,
  name          text NOT NULL,
  department_id uuid REFERENCES bms.departments(id) ON DELETE RESTRICT,
  -- Which ledger category a salary for this position posts to.
  category_id   uuid REFERENCES bms.categories(id) ON DELETE RESTRICT,
  sort_order    int NOT NULL DEFAULT 100,
  is_active     boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS bms.staff (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_code        text NOT NULL UNIQUE,
  name              text NOT NULL,
  position_id       uuid NOT NULL REFERENCES bms.staff_positions(id) ON DELETE RESTRICT,
  mobile            text,
  address           text,
  emergency_contact text,
  joining_date      date NOT NULL DEFAULT CURRENT_DATE,
  leaving_date      date,
  salary            bms.money_amount NOT NULL DEFAULT 0 CHECK (salary >= 0),
  shift             text CHECK (shift IS NULL OR shift IN ('MORNING','EVENING','NIGHT','GENERAL')),
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
  photo_path        text,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid REFERENCES auth.users(id),
  CONSTRAINT staff_dates_ck CHECK (leaving_date IS NULL OR leaving_date >= joining_date)
);
CREATE INDEX IF NOT EXISTS staff_position_idx ON bms.staff(position_id);

DO $$ BEGIN
  ALTER TABLE bms.issues
    ADD CONSTRAINT issues_staff_fk
    FOREIGN KEY (assigned_staff_id) REFERENCES bms.staff(id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE bms.transactions
    ADD CONSTRAINT transactions_staff_fk
    FOREIGN KEY (staff_id) REFERENCES bms.staff(id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS bms.staff_attendance (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id    uuid NOT NULL REFERENCES bms.staff(id) ON DELETE CASCADE,
  work_date   date NOT NULL,
  status      text NOT NULL CHECK (status IN ('PRESENT','ABSENT','LEAVE','HALF_DAY','HOLIDAY')),
  shift       text,
  check_in    time,
  check_out   time,
  remarks     text,
  recorded_by uuid REFERENCES auth.users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (staff_id, work_date)
);
CREATE INDEX IF NOT EXISTS attendance_date_idx ON bms.staff_attendance(work_date);

CREATE TABLE IF NOT EXISTS bms.staff_leaves (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id    uuid NOT NULL REFERENCES bms.staff(id) ON DELETE CASCADE,
  from_date   date NOT NULL,
  to_date     date NOT NULL,
  leave_type  text NOT NULL DEFAULT 'CASUAL'
              CHECK (leave_type IN ('CASUAL','SICK','UNPAID','FESTIVAL','OTHER')),
  reason      text,
  status      text NOT NULL DEFAULT 'PENDING'
              CHECK (status IN ('PENDING','APPROVED','REJECTED')),
  approved_by uuid REFERENCES auth.users(id),
  approved_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT leave_dates_ck CHECK (to_date >= from_date)
);

-- Salary advances are routine here, and without a place for them they get
-- miscoded as ordinary expenses and payroll stops adding up.
CREATE TABLE IF NOT EXISTS bms.staff_advances (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id         uuid NOT NULL REFERENCES bms.staff(id) ON DELETE RESTRICT,
  advance_date     date NOT NULL,
  amount           bms.money_amount NOT NULL CHECK (amount > 0),
  recovered_amount bms.money_amount NOT NULL DEFAULT 0 CHECK (recovered_amount >= 0),
  reason           text,
  txn_id           uuid REFERENCES bms.transactions(id),
  created_by       uuid REFERENCES auth.users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT advance_recovery_ck CHECK (recovered_amount <= amount)
);

CREATE TABLE IF NOT EXISTS bms.salary_runs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  period_year  int NOT NULL CHECK (period_year BETWEEN 2000 AND 2200),
  period_month int NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  status       text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','FINALISED')),
  staff_count  int NOT NULL DEFAULT 0,
  total_amount bms.money_amount NOT NULL DEFAULT 0,
  notes        text,
  generated_by uuid REFERENCES auth.users(id),
  generated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (period_year, period_month)
);

CREATE TABLE IF NOT EXISTS bms.salary_payments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id           uuid NOT NULL REFERENCES bms.salary_runs(id) ON DELETE CASCADE,
  staff_id         uuid NOT NULL REFERENCES bms.staff(id) ON DELETE RESTRICT,
  base_salary      bms.money_amount NOT NULL CHECK (base_salary >= 0),
  bonus            bms.money_amount NOT NULL DEFAULT 0 CHECK (bonus >= 0),
  deduction        bms.money_amount NOT NULL DEFAULT 0 CHECK (deduction >= 0),
  advance_recovery bms.money_amount NOT NULL DEFAULT 0 CHECK (advance_recovery >= 0),
  net_payable      numeric(14,2) GENERATED ALWAYS AS
                   (base_salary + bonus - deduction - advance_recovery) STORED,
  absent_days      int NOT NULL DEFAULT 0 CHECK (absent_days >= 0),
  paid_date        date,
  txn_id           uuid REFERENCES bms.transactions(id),
  status           text NOT NULL DEFAULT 'PENDING'
                   CHECK (status IN ('PENDING','PAID','CANCELLED')),
  notes            text,
  UNIQUE (run_id, staff_id)
);
CREATE INDEX IF NOT EXISTS salary_staff_idx ON bms.salary_payments(staff_id);

-- ---------------------------------------------------------------------
-- WORK MONITORING — cleaner, gardener, guard, caretaker rounds.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.work_checklist_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  position_id uuid REFERENCES bms.staff_positions(id) ON DELETE RESTRICT,
  frequency   text NOT NULL DEFAULT 'DAILY'
              CHECK (frequency IN ('DAILY','WEEKLY','MONTHLY')),
  is_active   boolean NOT NULL DEFAULT true,
  sort_order  int NOT NULL DEFAULT 100
);

CREATE TABLE IF NOT EXISTS bms.work_checklist_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id   uuid NOT NULL REFERENCES bms.work_checklist_templates(id) ON DELETE CASCADE,
  label         text NOT NULL,
  requires_photo boolean NOT NULL DEFAULT false,
  sort_order    int NOT NULL DEFAULT 100
);

CREATE TABLE IF NOT EXISTS bms.work_logs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id    uuid NOT NULL REFERENCES bms.work_checklist_templates(id) ON DELETE RESTRICT,
  staff_id       uuid REFERENCES bms.staff(id) ON DELETE RESTRICT,
  log_date       date NOT NULL,
  shift          text,
  overall_status text NOT NULL DEFAULT 'DONE'
                 CHECK (overall_status IN ('DONE','PARTIAL','NOT_DONE')),
  remarks        text,
  photo_path     text,
  recorded_by    uuid REFERENCES auth.users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (template_id, staff_id, log_date)
);
CREATE INDEX IF NOT EXISTS work_logs_date_idx ON bms.work_logs(log_date DESC);

CREATE TABLE IF NOT EXISTS bms.work_log_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_log_id uuid NOT NULL REFERENCES bms.work_logs(id) ON DELETE CASCADE,
  item_id     uuid NOT NULL REFERENCES bms.work_checklist_items(id) ON DELETE RESTRICT,
  is_done     boolean NOT NULL DEFAULT false,
  remarks     text,
  photo_path  text,
  UNIQUE (work_log_id, item_id)
);

-- ---------------------------------------------------------------------
-- Settings that Phase 3 introduces.
-- ---------------------------------------------------------------------
DO $$ BEGIN
  ALTER TABLE bms.building_settings
    ADD COLUMN sla_hours_critical int NOT NULL DEFAULT 4  CHECK (sla_hours_critical > 0),
    ADD COLUMN sla_hours_high     int NOT NULL DEFAULT 24 CHECK (sla_hours_high > 0),
    ADD COLUMN sla_hours_medium   int NOT NULL DEFAULT 72 CHECK (sla_hours_medium > 0),
    ADD COLUMN sla_hours_low      int NOT NULL DEFAULT 168 CHECK (sla_hours_low > 0);
EXCEPTION WHEN duplicate_column THEN NULL; END $$;

DROP TRIGGER IF EXISTS trg_assets_updated ON bms.assets;
DROP TRIGGER IF EXISTS trg_issues_updated ON bms.issues;
DROP TRIGGER IF EXISTS trg_staff_updated  ON bms.staff;
CREATE TRIGGER trg_assets_updated BEFORE UPDATE ON bms.assets FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_issues_updated BEFORE UPDATE ON bms.issues FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_staff_updated  BEFORE UPDATE ON bms.staff  FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();

-- Attachments may now hang off the Phase 3 records too.
DO $$ BEGIN
  ALTER TABLE bms.attachments DROP CONSTRAINT IF EXISTS attachments_entity_ck;
  ALTER TABLE bms.attachments ADD CONSTRAINT attachments_entity_ck CHECK (entity_table IN
    ('transactions','issues','issue_updates','asset_service_logs','asset_inspections',
     'assets','staff','salary_payments','fixed_deposits','bank_statements','work_logs',
     'work_log_items','payments','flats','fuel_purchases','generator_runs','staff_advances'));
END $$;
