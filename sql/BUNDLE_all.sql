-- =====================================================================
-- BUNDLE_all.sql — every migration, in order, in one file.
--
-- GENERATED FILE. Do not edit. Run scripts/build-bundle.sh instead.
--
-- HOW TO USE
--   1. Open your Supabase project -> SQL Editor -> New query.
--   2. Paste this whole file.
--   3. Run.
--
-- It is safe to run more than once: every statement is written to be
-- repeatable (CREATE ... IF NOT EXISTS, CREATE OR REPLACE, DROP POLICY
-- IF EXISTS before CREATE POLICY, ON CONFLICT DO NOTHING on seed rows).
-- Running it twice does not duplicate seed data and does not reset
-- anything you have entered.
--
-- WHAT IT TOUCHES
--   Everything it creates lives in the `bms` schema, which it creates.
--   It reads auth.users (Supabase's own table) by foreign key only, and
--   never writes to it. It does not read, alter or drop anything in
--   `public`. sql/test/t00_self_contained.sql exists to fail the build
--   if that ever stops being true.
--
-- STORAGE
--   The last section attaches policies to three storage buckets. If the
--   buckets do not exist yet it prints a notice and skips that part —
--   create them, then run this file again, or run sql/090_storage.sql
--   on its own.
-- =====================================================================



-- =====================================================================
-- BEGIN 001_core.sql
-- =====================================================================

-- =====================================================================
-- 001_core.sql — schema, shared types, identity, roles, permissions,
--                building configuration.
--
-- SAFETY: every object in this file is created inside the `bms` schema.
-- Nothing here alters, drops or reads any LPG Ledger table.
-- =====================================================================

SET search_path = bms, public;

CREATE SCHEMA IF NOT EXISTS bms;

-- Money is ALWAYS this type. Never float, never numeric without a scale.
DO $$ BEGIN
  CREATE DOMAIN bms.money_amount AS numeric(14,2);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Small helper used by every table for the updated_at column.
CREATE OR REPLACE FUNCTION bms.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- MODULES — the registry that drives navigation and the permission grid.
-- Adding module 22 is one INSERT, not a restructure.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.modules (
  code        text PRIMARY KEY,
  name        text NOT NULL,
  icon        text,
  sort_order  int  NOT NULL DEFAULT 100,
  phase       int  NOT NULL DEFAULT 1,
  is_enabled  boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- PERMISSIONS — one row per module x action.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.permissions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  module_code  text NOT NULL REFERENCES bms.modules(code) ON DELETE CASCADE,
  action       text NOT NULL,
  description  text,
  UNIQUE (module_code, action),
  CONSTRAINT permissions_action_ck CHECK (action IN
    ('view','add','edit','approve','export','cancel','waive','view_sensitive','manage','close'))
);

-- ---------------------------------------------------------------------
-- ROLES and their permission bundles.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  description text,
  is_system   boolean NOT NULL DEFAULT false,   -- system roles cannot be deleted
  is_superuser boolean NOT NULL DEFAULT false,  -- implies every permission
  -- Money limits. NULL means unlimited (only sensible for a superuser role).
  approve_limit   bms.money_amount,   -- largest expense this role may approve
  auto_post_limit bms.money_amount,   -- posts straight through up to here; NULL = unlimited
  sort_order  int NOT NULL DEFAULT 100,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bms.role_permissions (
  role_id       uuid NOT NULL REFERENCES bms.roles(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES bms.permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

-- ---------------------------------------------------------------------
-- USER PROFILES — building-side profile, deliberately SEPARATE from the
-- LPG Ledger's public.profiles so that table is never altered.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.user_profiles (
  user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name   text NOT NULL,
  email       text,
  phone       text,
  is_active   boolean NOT NULL DEFAULT false,   -- new sign-ups wait for an admin
  approval_limit bms.money_amount,              -- NULL = use the role default
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bms.user_roles (
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role_id     uuid NOT NULL REFERENCES bms.roles(id) ON DELETE CASCADE,
  assigned_by uuid REFERENCES auth.users(id),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role_id)
);
CREATE INDEX IF NOT EXISTS user_roles_user_idx ON bms.user_roles(user_id);

-- ---------------------------------------------------------------------
-- BUILDING SETTINGS — the singleton. Nothing from the spec is hard-coded
-- in application code; it all lives here.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.building_settings (
  id                        boolean PRIMARY KEY DEFAULT true CHECK (id),
  building_name             text NOT NULL DEFAULT 'Our Building',
  address                   text,
  floor_count               int  NOT NULL DEFAULT 9  CHECK (floor_count > 0),
  currency_code             text NOT NULL DEFAULT 'BDT',
  currency_symbol           text NOT NULL DEFAULT 'Tk',
  locale                    text NOT NULL DEFAULT 'en-BD',
  timezone                  text NOT NULL DEFAULT 'Asia/Dhaka',
  fiscal_year_start_month   int  NOT NULL DEFAULT 1 CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  default_service_charge    bms.money_amount NOT NULL DEFAULT 5000.00 CHECK (default_service_charge >= 0),
  charge_due_day            int  NOT NULL DEFAULT 10 CHECK (charge_due_day BETWEEN 1 AND 28),
  late_fee_enabled          boolean NOT NULL DEFAULT false,
  late_fee_type             text NOT NULL DEFAULT 'FIXED' CHECK (late_fee_type IN ('FIXED','PERCENT')),
  late_fee_value            bms.money_amount NOT NULL DEFAULT 0 CHECK (late_fee_value >= 0),
  late_fee_grace_days       int  NOT NULL DEFAULT 5 CHECK (late_fee_grace_days >= 0),
  allow_self_approval       boolean NOT NULL DEFAULT false,
  inspection_warn_days      int  NOT NULL DEFAULT 30 CHECK (inspection_warn_days >= 0),
  service_warn_days         int  NOT NULL DEFAULT 15 CHECK (service_warn_days >= 0),
  fd_maturity_warn_days     int  NOT NULL DEFAULT 30 CHECK (fd_maturity_warn_days >= 0),
  receipt_prefix            text NOT NULL DEFAULT 'RCT',
  -- Where an entry with no account chosen lands (the caretaker's petty cash).
  default_cash_account_id   uuid,
  logo_path                 text,
  updated_at                timestamptz NOT NULL DEFAULT now(),
  updated_by                uuid REFERENCES auth.users(id)
);

-- ---------------------------------------------------------------------
-- has_perm() — the single gate every RLS policy calls.
--
-- SECURITY DEFINER so that a user whose SELECT on bms.user_roles is
-- itself restricted can still have their own permissions evaluated.
-- STABLE so Postgres evaluates it once per statement, not per row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.has_perm(p_module text, p_action text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1
    FROM bms.user_roles ur
    JOIN bms.roles r            ON r.id = ur.role_id
    JOIN bms.user_profiles up   ON up.user_id = ur.user_id
    LEFT JOIN bms.role_permissions rp ON rp.role_id = r.id
    LEFT JOIN bms.permissions p       ON p.id = rp.permission_id
    WHERE ur.user_id = auth.uid()
      AND up.is_active
      AND ( r.is_superuser
            OR (p.module_code = p_module AND p.action = p_action) )
  )
$$;

-- Convenience: is the caller an active user of the building system at all?
CREATE OR REPLACE FUNCTION bms.is_active_user()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM bms.user_profiles up
    WHERE up.user_id = auth.uid() AND up.is_active
  )
$$;

CREATE OR REPLACE FUNCTION bms.is_superuser()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM bms.user_roles ur
    JOIN bms.roles r          ON r.id = ur.role_id
    JOIN bms.user_profiles up ON up.user_id = ur.user_id
    WHERE ur.user_id = auth.uid() AND up.is_active AND r.is_superuser
  )
$$;

-- How much may a user approve? NULL means unlimited.
-- A per-user override on user_profiles wins over the role limits;
-- otherwise it is the highest limit across the user's roles.
CREATE OR REPLACE FUNCTION bms.approval_limit(p_user uuid DEFAULT NULL)
RETURNS bms.money_amount
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_user uuid := COALESCE(p_user, auth.uid());
        v_override bms.money_amount;
        v_unlimited boolean;
        v_limit bms.money_amount;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
     WHERE ur.user_id = v_user AND (r.is_superuser OR r.approve_limit IS NULL)
  ) INTO v_unlimited;
  IF v_unlimited THEN RETURN NULL; END IF;

  SELECT up.approval_limit INTO v_override
    FROM bms.user_profiles up WHERE up.user_id = v_user;
  IF v_override IS NOT NULL THEN RETURN v_override; END IF;

  SELECT MAX(r.approve_limit) INTO v_limit
    FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
   WHERE ur.user_id = v_user;
  RETURN COALESCE(v_limit, 0);
END $$;

-- Below this amount a user's own entries post straight to the ledger.
CREATE OR REPLACE FUNCTION bms.auto_post_limit(p_user uuid DEFAULT NULL)
RETURNS bms.money_amount
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_user uuid := COALESCE(p_user, auth.uid());
        v_unlimited boolean; v_limit bms.money_amount;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
     WHERE ur.user_id = v_user AND (r.is_superuser OR r.auto_post_limit IS NULL)
  ) INTO v_unlimited;
  IF v_unlimited THEN RETURN NULL; END IF;

  SELECT MAX(r.auto_post_limit) INTO v_limit
    FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
   WHERE ur.user_id = v_user;
  RETURN COALESCE(v_limit, 0);
END $$;

-- The whole permission list for the signed-in user, for the UI to cache.
CREATE OR REPLACE FUNCTION bms.my_permissions()
RETURNS TABLE (module_code text, action text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT DISTINCT p.module_code, p.action
  FROM bms.user_roles ur
  JOIN bms.roles r                  ON r.id = ur.role_id
  JOIN bms.user_profiles up         ON up.user_id = ur.user_id
  JOIN bms.role_permissions rp      ON rp.role_id = r.id
  JOIN bms.permissions p            ON p.id = rp.permission_id
  WHERE ur.user_id = auth.uid() AND up.is_active AND NOT r.is_superuser
  UNION
  SELECT p.module_code, p.action
  FROM bms.permissions p
  WHERE bms.is_superuser()
$$;

DROP TRIGGER IF EXISTS trg_modules_updated       ON bms.modules;
DROP TRIGGER IF EXISTS trg_roles_updated         ON bms.roles;
DROP TRIGGER IF EXISTS trg_user_profiles_updated ON bms.user_profiles;
CREATE TRIGGER trg_modules_updated       BEFORE UPDATE ON bms.modules       FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_roles_updated         BEFORE UPDATE ON bms.roles         FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_user_profiles_updated BEFORE UPDATE ON bms.user_profiles FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();

-- END 001_core.sql


-- =====================================================================
-- BEGIN 002_finance.sql
-- =====================================================================

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

-- END 002_finance.sql


-- =====================================================================
-- BEGIN 003_flats_charges.sql
-- =====================================================================

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

-- END 003_flats_charges.sql


-- =====================================================================
-- BEGIN 004_operations.sql
-- =====================================================================

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

-- END 004_operations.sql


-- =====================================================================
-- BEGIN 005_funds.sql
-- =====================================================================

-- =====================================================================
-- 005_funds.sql — Phase 4/5: reserve funds, fixed deposits, bank
-- reconciliation and notifications.
--
-- The idea that keeps this honest:
--
--   A RESERVE FUND IS A LABEL ON MONEY YOU ALREADY HAVE.
--
-- Tk 800,000 of reserve does not exist unless Tk 800,000 is sitting in
-- an account or a fixed deposit somewhere. So `funds` tracks the
-- EARMARK and `accounts` tracks the CASH, and the dashboard can then
-- tell you the uncomfortable but important thing: whether the reserve
-- is actually funded.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- FUNDS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.funds (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code            text NOT NULL UNIQUE,
  name            text NOT NULL,
  fund_type       text NOT NULL DEFAULT 'RESERVE'
                  CHECK (fund_type IN ('RESERVE','SINKING','EMERGENCY','PROJECT')),
  purpose         text,
  opening_balance bms.money_amount NOT NULL DEFAULT 0,
  opening_date    date NOT NULL DEFAULT CURRENT_DATE,
  target_amount   bms.money_amount CHECK (target_amount IS NULL OR target_amount >= 0),
  target_date     date,
  -- Where the money physically sits, when it sits somewhere of its own.
  account_id      uuid REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  is_active       boolean NOT NULL DEFAULT true,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS bms.fund_movements (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fund_id        uuid NOT NULL REFERENCES bms.funds(id) ON DELETE RESTRICT,
  movement_date  date NOT NULL,
  direction      text NOT NULL CHECK (direction IN
                   ('CONTRIBUTION','WITHDRAWAL','INTEREST','TRANSFER_IN','TRANSFER_OUT')),
  amount         bms.money_amount NOT NULL CHECK (amount > 0),
  -- TRUE when real money moved between accounts as well as the earmark
  -- changing. FALSE when the committee simply set money aside and it
  -- stayed exactly where it was.
  is_cash_movement boolean NOT NULL DEFAULT false,
  txn_id         uuid REFERENCES bms.transactions(id),
  purpose        text,
  notes          text,
  approved_by    uuid REFERENCES auth.users(id),
  created_by     uuid REFERENCES auth.users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fund_cash_needs_txn CHECK (NOT is_cash_movement OR txn_id IS NOT NULL
                                        OR direction = 'INTEREST')
);
CREATE INDEX IF NOT EXISTS fund_mov_idx ON bms.fund_movements(fund_id, movement_date);

-- ---------------------------------------------------------------------
-- FIXED DEPOSITS
--
-- An FD is modelled as an accounts row of kind 'FD' plus the record
-- below. Opening one is a TRANSFER from the bank into that account, so
-- the bank balance falls, the FD shows separately, and the building's
-- total position stays right without anybody adding anything up by hand.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.fixed_deposits (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fd_no                  text NOT NULL UNIQUE,
  bank_name              text NOT NULL,
  branch                 text,
  account_id             uuid REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  source_account_id      uuid REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  fund_id                uuid REFERENCES bms.funds(id) ON DELETE RESTRICT,
  principal              bms.money_amount NOT NULL CHECK (principal > 0),
  deposit_date           date NOT NULL,
  tenure_months          int CHECK (tenure_months IS NULL OR tenure_months > 0),
  interest_rate          numeric(6,3) CHECK (interest_rate IS NULL OR interest_rate >= 0),
  maturity_date          date,
  expected_maturity_amount bms.money_amount,
  actual_maturity_amount bms.money_amount,
  auto_renew             boolean NOT NULL DEFAULT false,
  parent_fd_id           uuid REFERENCES bms.fixed_deposits(id),
  purpose                text,
  status                 text NOT NULL DEFAULT 'ACTIVE'
                         CHECK (status IN ('ACTIVE','MATURED','RENEWED','ENCASHED')),
  certificate_path       text,
  notes                  text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  created_by             uuid REFERENCES auth.users(id)
);
CREATE INDEX IF NOT EXISTS fd_maturity_idx ON bms.fixed_deposits(maturity_date) WHERE status = 'ACTIVE';

CREATE TABLE IF NOT EXISTS bms.fd_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fd_id       uuid NOT NULL REFERENCES bms.fixed_deposits(id) ON DELETE CASCADE,
  event_type  text NOT NULL CHECK (event_type IN
                ('OPENED','INTEREST_CREDIT','RENEWAL','PARTIAL_ENCASH','MATURITY','PREMATURE_ENCASH')),
  event_date  date NOT NULL,
  amount      bms.money_amount,
  txn_id      uuid REFERENCES bms.transactions(id),
  notes       text,
  created_by  uuid REFERENCES auth.users(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- BANK RECONCILIATION
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.bank_statements (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      uuid NOT NULL REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  statement_date  date NOT NULL,
  period_start    date,
  period_end      date,
  opening_balance bms.money_amount,
  closing_balance bms.money_amount NOT NULL,
  status          text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RECONCILED')),
  notes           text,
  uploaded_by     uuid REFERENCES auth.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, statement_date)
);

CREATE TABLE IF NOT EXISTS bms.bank_statement_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  statement_id    uuid NOT NULL REFERENCES bms.bank_statements(id) ON DELETE CASCADE,
  line_date       date NOT NULL,
  description     text,
  reference       text,
  debit           bms.money_amount NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit          bms.money_amount NOT NULL DEFAULT 0 CHECK (credit >= 0),
  matched_txn_id  uuid REFERENCES bms.transactions(id),
  match_status    text NOT NULL DEFAULT 'UNMATCHED'
                  CHECK (match_status IN ('UNMATCHED','AUTO_MATCHED','MANUAL_MATCHED','IGNORED')),
  notes           text,
  CONSTRAINT stmt_line_one_side CHECK (NOT (debit > 0 AND credit > 0))
);
CREATE INDEX IF NOT EXISTS stmt_lines_idx ON bms.bank_statement_lines(statement_id);

CREATE TABLE IF NOT EXISTS bms.reconciliations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      uuid NOT NULL REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  statement_id    uuid REFERENCES bms.bank_statements(id) ON DELETE RESTRICT,
  as_of_date      date NOT NULL,
  system_balance  bms.money_amount NOT NULL,
  bank_balance    bms.money_amount NOT NULL,
  difference      numeric(14,2) GENERATED ALWAYS AS (bank_balance - system_balance) STORED,
  status          text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','AGREED','DISPUTED')),
  notes           text,
  reconciled_by   uuid REFERENCES auth.users(id),
  reconciled_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- NOTIFICATIONS
--
-- In-app only for now. The `channel` column and the rules table are what
-- let email, SMS or WhatsApp be added later without a schema change or a
-- rewrite of anything that creates a notification.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.notification_rules (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_type  text NOT NULL UNIQUE,
  title       text NOT NULL,
  is_enabled  boolean NOT NULL DEFAULT true,
  severity    text NOT NULL DEFAULT 'NORMAL' CHECK (severity IN ('LOW','NORMAL','HIGH')),
  -- Which permission a person must hold to be told about this at all.
  module_code text NOT NULL,
  action      text NOT NULL DEFAULT 'view',
  channels    text[] NOT NULL DEFAULT ARRAY['IN_APP'],
  config      jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS bms.notifications (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  alert_type   text NOT NULL,
  title        text NOT NULL,
  body         text,
  severity     text NOT NULL DEFAULT 'NORMAL' CHECK (severity IN ('LOW','NORMAL','HIGH')),
  link         text,
  channel      text NOT NULL DEFAULT 'IN_APP'
               CHECK (channel IN ('IN_APP','EMAIL','SMS','WHATSAPP')),
  -- One notification per person per alert per day: nobody wants the same
  -- "3 approvals waiting" seventeen times.
  dedupe_key   text NOT NULL,
  is_read      boolean NOT NULL DEFAULT false,
  read_at      timestamptz,
  delivered_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, dedupe_key)
);
CREATE INDEX IF NOT EXISTS notif_unread_idx ON bms.notifications(user_id) WHERE NOT is_read;

DROP TRIGGER IF EXISTS trg_funds_updated ON bms.funds;
DROP TRIGGER IF EXISTS trg_fd_updated    ON bms.fixed_deposits;
CREATE TRIGGER trg_funds_updated BEFORE UPDATE ON bms.funds          FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_fd_updated    BEFORE UPDATE ON bms.fixed_deposits FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();

-- Certificates and statements can carry attachments too.
DO $$ BEGIN
  ALTER TABLE bms.attachments DROP CONSTRAINT IF EXISTS attachments_entity_ck;
  ALTER TABLE bms.attachments ADD CONSTRAINT attachments_entity_ck CHECK (entity_table IN
    ('transactions','issues','issue_updates','asset_service_logs','asset_inspections',
     'assets','staff','salary_payments','fixed_deposits','bank_statements','work_logs',
     'work_log_items','payments','flats','fuel_purchases','generator_runs','staff_advances',
     'funds','fund_movements','reconciliations'));
END $$;

-- END 005_funds.sql


-- =====================================================================
-- BEGIN 010_functions.sql
-- =====================================================================

-- =====================================================================
-- 010_functions.sql — the rules that make the ledger trustworthy.
--
-- Everything here runs inside PostgreSQL, so it holds whether the caller
-- is the portal UI, a console, or a direct API call. Hiding a button in
-- the browser is decoration; these are the actual rules.
-- =====================================================================

SET search_path = bms, public;

CREATE OR REPLACE FUNCTION bms.assert_perm(p_module text, p_action text)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF NOT bms.has_perm(p_module, p_action) THEN
    RAISE EXCEPTION 'Permission denied: you need % on %', p_action, p_module
      USING ERRCODE = '42501';
  END IF;
END $$;

-- =====================================================================
-- TRANSACTION GUARD — rules 1, 3, 4 and 6 from the design.
-- =====================================================================
CREATE OR REPLACE FUNCTION bms.txn_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_allow_self boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF bms.period_is_closed(NEW.txn_date) THEN
      RAISE EXCEPTION 'Accounting period % is closed — no transaction can be dated then',
        to_char(NEW.txn_date, 'Mon YYYY') USING ERRCODE = '23514';
    END IF;
    NEW.period_id  := bms.period_for(NEW.txn_date);
    NEW.created_by := COALESCE(NEW.created_by, auth.uid());
    IF NEW.status NOT IN ('DRAFT','SUBMITTED') THEN
      RAISE EXCEPTION 'A transaction must be created as DRAFT or SUBMITTED, not %', NEW.status;
    END IF;
    IF NEW.direction <> 'TRANSFER' AND NEW.account_id IS NULL THEN
      RAISE EXCEPTION 'An account is required';
    END IF;
    -- An income category may not carry an expense, or the year's figures
    -- come out plausible and wrong. Categories marked BOTH take either.
    --
    -- A reversal is exempt, and must be: undoing a service-charge receipt
    -- is written as an EXPENSE against the service-charge category on
    -- purpose, so that the two halves cancel in the same line of the
    -- report. Forcing it into a different category would leave the
    -- original income standing in the year's figures forever.
    -- Service charge has exactly one door.
    --
    -- Typing a service-charge receipt straight into the ledger produces
    -- income that belongs to no flat: the money shows on the dashboard,
    -- the flat still reads as unpaid, and if the payment was ALSO recorded
    -- properly the month is counted twice. That happened in the live
    -- building — two receipts for the same money, one attached to a flat
    -- and one floating.
    --
    -- record_payment() stamps source_module = 'charges'; a hand-typed
    -- entry does not. So the category is refused here unless the entry
    -- came through the Service Charge screen, and the message says where
    -- to go instead. Reversals are exempt for the reason below.
    IF NEW.direction = 'INCOME'
       AND NOT COALESCE(NEW.is_reversal, false)
       AND COALESCE(NEW.source_module,'') <> 'charges'
       AND EXISTS (SELECT 1 FROM bms.categories c
                     JOIN bms.departments d ON d.id = c.department_id
                    WHERE c.id = NEW.category_id AND d.code = 'SERVICE_CHARGE') THEN
      RAISE EXCEPTION 'Service charge is recorded in Service Charge → Record payment, so it lands against a flat and appears on that flat''s statement. Entering it here would count the money twice.'
        USING ERRCODE = '23514';
    END IF;

    IF NEW.category_id IS NOT NULL AND NEW.direction IN ('INCOME','EXPENSE')
       AND NOT COALESCE(NEW.is_reversal, false)
       AND EXISTS (SELECT 1 FROM bms.categories c
                    WHERE c.id = NEW.category_id
                      AND c.txn_type NOT IN ('BOTH', NEW.direction)) THEN
      RAISE EXCEPTION 'Category "%" cannot be used for %',
        (SELECT name FROM bms.categories WHERE id = NEW.category_id),
        lower(NEW.direction) USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  -- ---- UPDATE ----
  -- Rule 3: a posted transaction is frozen. Only these may still change.
  IF OLD.status = 'POSTED' THEN
    IF NEW.txn_date          IS DISTINCT FROM OLD.txn_date
    OR NEW.amount            IS DISTINCT FROM OLD.amount
    OR NEW.direction         IS DISTINCT FROM OLD.direction
    OR NEW.account_id        IS DISTINCT FROM OLD.account_id
    OR NEW.counter_account_id IS DISTINCT FROM OLD.counter_account_id
    OR NEW.department_id     IS DISTINCT FROM OLD.department_id
    OR NEW.category_id       IS DISTINCT FROM OLD.category_id
    OR NEW.payment_method    IS DISTINCT FROM OLD.payment_method
    OR NEW.vendor_id         IS DISTINCT FROM OLD.vendor_id
    OR NEW.flat_id           IS DISTINCT FROM OLD.flat_id THEN
      RAISE EXCEPTION 'Transaction % is posted and cannot be edited. Reverse it instead.',
        COALESCE(OLD.txn_no, OLD.id::text) USING ERRCODE = '23514';
    END IF;
    IF NEW.status NOT IN ('POSTED','REVERSED') THEN
      RAISE EXCEPTION 'A posted transaction can only move to REVERSED, not %', NEW.status;
    END IF;
  END IF;

  IF OLD.status IN ('REVERSED','CANCELLED','REJECTED')
     AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'Transaction is % and is final', OLD.status;
  END IF;

  -- Rule 6: no editing a financial field into or inside a closed month.
  IF (NEW.txn_date IS DISTINCT FROM OLD.txn_date OR NEW.amount IS DISTINCT FROM OLD.amount)
     AND (bms.period_is_closed(NEW.txn_date) OR bms.period_is_closed(OLD.txn_date)) THEN
    RAISE EXCEPTION 'That accounting period is closed';
  END IF;

  IF NEW.txn_date IS DISTINCT FROM OLD.txn_date THEN
    NEW.period_id := bms.period_for(NEW.txn_date);
  END IF;

  -- Rule 1: the approver may not be the creator.
  -- A reversal is the one exception: it undoes money rather than moving new
  -- money out, it already required the finance.cancel permission, and it
  -- carries a mandatory reason. Re-entering the expense afterwards would
  -- still need a second person, so the control is not weakened.
  IF NEW.approved_by IS NOT NULL
     AND NOT COALESCE(NEW.is_reversal, false)
     AND NEW.approved_by IS DISTINCT FROM OLD.approved_by
     AND NEW.approved_by = NEW.created_by THEN
    SELECT allow_self_approval INTO v_allow_self FROM bms.building_settings WHERE id;
    IF NOT COALESCE(v_allow_self, false) THEN
      RAISE EXCEPTION 'You cannot approve a transaction you created. A second person must approve it.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- A human-readable number is assigned the moment it leaves DRAFT.
  IF NEW.txn_no IS NULL AND NEW.status <> 'DRAFT' THEN
    NEW.txn_no := bms.next_doc_no(
      CASE NEW.direction WHEN 'INCOME' THEN 'INC' WHEN 'EXPENSE' THEN 'EXP' ELSE 'TRF' END,
      EXTRACT(YEAR FROM NEW.txn_date)::int,
      CASE NEW.direction WHEN 'INCOME' THEN 'INC' WHEN 'EXPENSE' THEN 'EXP' ELSE 'TRF' END);
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_txn_guard ON bms.transactions;
CREATE TRIGGER trg_txn_guard BEFORE INSERT OR UPDATE ON bms.transactions
  FOR EACH ROW EXECUTE FUNCTION bms.txn_guard();

-- Rule 4: nothing is ever deleted. Belt as well as braces — the REVOKE in
-- 020_rls.sql is the primary control; this catches anything privileged.
CREATE OR REPLACE FUNCTION bms.block_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Rows in % are never deleted. Use cancellation or reversal.', TG_TABLE_NAME
    USING ERRCODE = '42501';
END $$;

DROP TRIGGER IF EXISTS trg_txn_no_delete    ON bms.transactions;
DROP TRIGGER IF EXISTS trg_ledger_no_delete ON bms.ledger_entries;
DROP TRIGGER IF EXISTS trg_pay_no_delete    ON bms.payments;
CREATE TRIGGER trg_txn_no_delete    BEFORE DELETE ON bms.transactions   FOR EACH ROW EXECUTE FUNCTION bms.block_delete();
CREATE TRIGGER trg_ledger_no_delete BEFORE DELETE ON bms.ledger_entries FOR EACH ROW EXECUTE FUNCTION bms.block_delete();
CREATE TRIGGER trg_pay_no_delete    BEFORE DELETE ON bms.payments       FOR EACH ROW EXECUTE FUNCTION bms.block_delete();

-- Ledger entries are written by post_transaction() only, and never edited.
CREATE OR REPLACE FUNCTION bms.block_ledger_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Ledger entries are immutable' USING ERRCODE = '42501';
END $$;
DROP TRIGGER IF EXISTS trg_ledger_no_update ON bms.ledger_entries;
CREATE TRIGGER trg_ledger_no_update BEFORE UPDATE ON bms.ledger_entries
  FOR EACH ROW EXECUTE FUNCTION bms.block_ledger_update();

-- =====================================================================
-- TRANSACTION LIFECYCLE RPCs
-- =====================================================================

-- Does this amount, entered by this user, need someone else to approve it?
CREATE OR REPLACE FUNCTION bms.needs_approval(p_amount bms.money_amount, p_user uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_limit bms.money_amount := bms.auto_post_limit(COALESCE(p_user, auth.uid()));
BEGIN
  IF v_limit IS NULL THEN RETURN false; END IF;   -- unlimited
  RETURN p_amount > v_limit;
END $$;

-- Write the account movements for a transaction and mark it POSTED.
CREATE OR REPLACE FUNCTION bms.post_transaction(p_txn uuid)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions;
BEGIN
  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status = 'POSTED' THEN RETURN t; END IF;
  IF t.status <> 'APPROVED' THEN
    RAISE EXCEPTION 'Only an APPROVED transaction can be posted (this one is %)', t.status;
  END IF;
  IF bms.period_is_closed(t.txn_date) THEN
    RAISE EXCEPTION 'That accounting period is closed';
  END IF;

  IF t.direction = 'INCOME' THEN
    INSERT INTO bms.ledger_entries(txn_id, account_id, entry_date, signed_amount, memo)
    VALUES (t.id, t.account_id, t.txn_date, t.amount, t.description);
  ELSIF t.direction = 'EXPENSE' THEN
    INSERT INTO bms.ledger_entries(txn_id, account_id, entry_date, signed_amount, memo)
    VALUES (t.id, t.account_id, t.txn_date, -t.amount, t.description);
  ELSE  -- TRANSFER: out of one account, into the other. Never income or expense.
    INSERT INTO bms.ledger_entries(txn_id, account_id, entry_date, signed_amount, memo)
    VALUES (t.id, t.account_id,        t.txn_date, -t.amount, t.description || ' (out)');
    INSERT INTO bms.ledger_entries(txn_id, account_id, entry_date, signed_amount, memo)
    VALUES (t.id, t.counter_account_id, t.txn_date,  t.amount, t.description || ' (in)');
  END IF;

  UPDATE bms.transactions
     SET status = 'POSTED', posted_at = now()
   WHERE id = t.id
  RETURNING * INTO t;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION bms.submit_transaction(p_txn uuid)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions;
BEGIN
  PERFORM bms.assert_perm('finance','add');
  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status NOT IN ('DRAFT','RETURNED') THEN
    RAISE EXCEPTION 'Only a DRAFT or RETURNED transaction can be submitted (this one is %)', t.status;
  END IF;

  IF bms.needs_approval(t.amount, t.created_by) THEN
    UPDATE bms.transactions
       SET status = 'PENDING_APPROVAL', submitted_by = auth.uid(), submitted_at = now()
     WHERE id = t.id RETURNING * INTO t;
  ELSE
    -- Under the entrant's own auto-post limit: approved by themselves and
    -- posted straight away. Recorded as such, not hidden.
    UPDATE bms.transactions
       SET status = 'APPROVED', submitted_by = auth.uid(), submitted_at = now(),
           approved_by = NULL, approved_at = now(),
           notes = COALESCE(t.notes,'') ||
                   CASE WHEN COALESCE(t.notes,'') = '' THEN '' ELSE E'\n' END ||
                   '[auto-posted: within entrant''s limit]'
     WHERE id = t.id RETURNING * INTO t;
    t := bms.post_transaction(t.id);
  END IF;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION bms.approve_transaction(p_txn uuid, p_post boolean DEFAULT true)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions; v_limit bms.money_amount;
BEGIN
  PERFORM bms.assert_perm('finance','approve');
  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status <> 'PENDING_APPROVAL' THEN
    RAISE EXCEPTION 'Only a PENDING_APPROVAL transaction can be approved (this one is %)', t.status;
  END IF;

  -- Rule 2: within this approver's limit.
  v_limit := bms.approval_limit();
  IF v_limit IS NOT NULL AND t.amount > v_limit THEN
    RAISE EXCEPTION 'This transaction of % is above your approval limit of %', t.amount, v_limit
      USING ERRCODE = '42501';
  END IF;

  UPDATE bms.transactions
     SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now()
   WHERE id = t.id RETURNING * INTO t;   -- the guard trigger blocks self-approval

  IF p_post THEN t := bms.post_transaction(t.id); END IF;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION bms.reject_transaction(p_txn uuid, p_reason text, p_return boolean DEFAULT false)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions;
BEGIN
  PERFORM bms.assert_perm('finance','approve');
  IF COALESCE(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'A reason is required';
  END IF;
  UPDATE bms.transactions
     SET status = CASE WHEN p_return THEN 'RETURNED' ELSE 'REJECTED' END,
         rejected_reason = p_reason,
         approved_by = NULL, approved_at = NULL
   WHERE id = p_txn AND status = 'PENDING_APPROVAL'
  RETURNING * INTO t;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction is not pending approval'; END IF;
  RETURN t;
END $$;

-- Rule 5: a reversal is a real, opposite transaction, linked both ways.
CREATE OR REPLACE FUNCTION bms.reverse_transaction(p_txn uuid, p_reason text, p_date date DEFAULT NULL)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions; r bms.transactions; v_date date;
BEGIN
  PERFORM bms.assert_perm('finance','cancel');
  IF COALESCE(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'A reversal reason is required';
  END IF;

  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status <> 'POSTED' THEN
    RAISE EXCEPTION 'Only a POSTED transaction can be reversed (this one is %)', t.status;
  END IF;
  IF t.reversed_by_txn_id IS NOT NULL THEN
    RAISE EXCEPTION 'That transaction has already been reversed';
  END IF;

  -- Reverse into the original month if it is still open, otherwise today.
  v_date := COALESCE(p_date, t.txn_date);
  IF bms.period_is_closed(v_date) THEN v_date := CURRENT_DATE; END IF;
  IF bms.period_is_closed(v_date) THEN
    RAISE EXCEPTION 'Both the original period and the current period are closed';
  END IF;

  INSERT INTO bms.transactions(
      txn_date, direction, department_id, category_id, description, amount,
      payment_method, account_id, counter_account_id, vendor_id, flat_id,
      reference_no, status, notes, source_module, source_ref,
      is_reversal, reversal_of_txn_id, reversal_reason, created_by)
  VALUES (
      v_date,
      CASE t.direction WHEN 'INCOME' THEN 'EXPENSE' WHEN 'EXPENSE' THEN 'INCOME' ELSE 'TRANSFER' END,
      t.department_id, t.category_id,
      'Reversal of ' || COALESCE(t.txn_no, t.id::text) || ' — ' || p_reason,
      t.amount, t.payment_method,
      -- a transfer reverses by swapping its two ends
      CASE WHEN t.direction = 'TRANSFER' THEN t.counter_account_id ELSE t.account_id END,
      CASE WHEN t.direction = 'TRANSFER' THEN t.account_id ELSE NULL END,
      t.vendor_id, t.flat_id, t.reference_no, 'DRAFT', t.notes, t.source_module, t.source_ref,
      true, t.id, p_reason, auth.uid())
  RETURNING * INTO r;

  UPDATE bms.transactions SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now()
   WHERE id = r.id;
  r := bms.post_transaction(r.id);

  UPDATE bms.transactions
     SET status = 'REVERSED', reversed_by_txn_id = r.id, reversal_reason = p_reason
   WHERE id = t.id;

  RETURN r;
END $$;

-- Create + submit in one atomic call, which is what the UI actually does.
CREATE OR REPLACE FUNCTION bms.create_transaction(
    p_txn_date date, p_direction text, p_department_id uuid, p_category_id uuid,
    p_description text, p_amount bms.money_amount, p_payment_method text,
    p_account_id uuid, p_counter_account_id uuid DEFAULT NULL,
    p_vendor_id uuid DEFAULT NULL, p_flat_id uuid DEFAULT NULL,
    p_reference_no text DEFAULT NULL, p_notes text DEFAULT NULL,
    p_submit boolean DEFAULT true,
    p_source_module text DEFAULT NULL, p_source_ref uuid DEFAULT NULL)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions; v_account uuid := p_account_id;
BEGIN
  PERFORM bms.assert_perm('finance','add');
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero';
  END IF;

  -- A caretaker has no sight of the bank, so an entry with no account
  -- chosen lands in the petty-cash account named in settings.
  IF v_account IS NULL AND p_direction <> 'TRANSFER' THEN
    SELECT COALESCE(bs.default_cash_account_id,
                    (SELECT a.id FROM bms.accounts a
                      WHERE a.kind = 'CASH' AND a.is_active ORDER BY a.created_at LIMIT 1))
      INTO v_account FROM bms.building_settings bs WHERE bs.id;
    IF v_account IS NULL THEN
      RAISE EXCEPTION 'No account was chosen and no default cash account is configured';
    END IF;
  END IF;

  INSERT INTO bms.transactions(
      txn_date, direction, department_id, category_id, description, amount,
      payment_method, account_id, counter_account_id, vendor_id, flat_id,
      reference_no, notes, status, created_by, source_module, source_ref)
  VALUES (
      p_txn_date, p_direction, p_department_id, p_category_id, p_description, p_amount,
      p_payment_method, v_account, p_counter_account_id, p_vendor_id, p_flat_id,
      p_reference_no, p_notes, 'DRAFT', auth.uid(), p_source_module, p_source_ref)
  RETURNING * INTO t;

  IF p_submit THEN t := bms.submit_transaction(t.id); END IF;
  RETURN t;
END $$;

-- =====================================================================
-- ACCOUNTING PERIODS
-- =====================================================================
CREATE OR REPLACE FUNCTION bms.close_period(p_year int, p_month int)
RETURNS bms.accounting_periods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE p bms.accounting_periods; v_open int;
BEGIN
  PERFORM bms.assert_perm('finance','close');
  SELECT COUNT(*) INTO v_open FROM bms.transactions t
   WHERE EXTRACT(YEAR FROM t.txn_date)::int = p_year
     AND EXTRACT(MONTH FROM t.txn_date)::int = p_month
     AND t.status IN ('DRAFT','SUBMITTED','PENDING_APPROVAL','RETURNED','APPROVED');
  IF v_open > 0 THEN
    RAISE EXCEPTION '% transaction(s) in that month are still unposted. Post, reject or cancel them first.', v_open;
  END IF;

  PERFORM bms.period_for(make_date(p_year, p_month, 1));
  UPDATE bms.accounting_periods
     SET status = 'CLOSED', closed_by = auth.uid(), closed_at = now()
   WHERE period_year = p_year AND period_month = p_month
  RETURNING * INTO p;
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION bms.reopen_period(p_year int, p_month int, p_reason text)
RETURNS bms.accounting_periods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE p bms.accounting_periods;
BEGIN
  PERFORM bms.assert_perm('finance','close');
  IF COALESCE(btrim(p_reason),'') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;
  UPDATE bms.accounting_periods
     SET status = 'OPEN', closed_by = NULL, closed_at = NULL,
         notes = COALESCE(notes,'') || E'\nReopened: ' || p_reason
   WHERE period_year = p_year AND period_month = p_month
  RETURNING * INTO p;
  IF NOT FOUND THEN RAISE EXCEPTION 'No such period'; END IF;
  RETURN p;
END $$;


-- ---------------------------------------------------------------------
-- A safe account picker for people who may record a spend but must not
-- see balances. Returns names only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.entry_accounts()
RETURNS TABLE (id uuid, code text, name text, kind text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF NOT (bms.has_perm('finance','add') OR bms.has_perm('bank','view')
          OR bms.has_perm('charges','add')) THEN
    RAISE EXCEPTION 'Permission denied' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT a.id, a.code, a.name, a.kind FROM bms.accounts a
     WHERE a.is_active AND a.kind <> 'FD' ORDER BY a.kind, a.name;
END $$;
REVOKE ALL ON FUNCTION bms.entry_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bms.entry_accounts() TO authenticated;

-- What a person is allowed to see about their own submissions, without
-- granting them the whole ledger.
CREATE OR REPLACE FUNCTION bms.my_submissions()
RETURNS SETOF bms.transactions
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT * FROM bms.transactions WHERE created_by = auth.uid() ORDER BY created_at DESC
$$;
REVOKE ALL ON FUNCTION bms.my_submissions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bms.my_submissions() TO authenticated;

-- END 010_functions.sql


-- =====================================================================
-- BEGIN 011_charge_functions.sql
-- =====================================================================

-- =====================================================================
-- 011_charge_functions.sql — service charge generation, payment
-- allocation, waivers, opening balances.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- What is still unpaid on a single charge.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.charge_due(p_charge uuid)
RETURNS numeric(14,2)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT GREATEST(fc.net_payable - COALESCE((
           SELECT SUM(a.amount) FROM bms.payment_allocations a
            WHERE a.flat_charge_id = fc.id), 0), 0)
    FROM bms.flat_charges fc WHERE fc.id = p_charge AND NOT fc.is_cancelled
$$;

-- ---------------------------------------------------------------------
-- ALLOCATION ENGINE.
-- Spreads every not-yet-allocated taka a flat has paid across its unpaid
-- charges, oldest charge first, oldest payment first. Anything left over
-- stays as advance and is picked up automatically next month.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.allocate_flat_advance(p_flat uuid)
RETURNS numeric(14,2)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  pay   record;
  chg   record;
  v_free      numeric(14,2);
  v_due       numeric(14,2);
  v_take      numeric(14,2);
  v_allocated numeric(14,2) := 0;
BEGIN
  FOR pay IN
    SELECT p.id,
           p.amount - COALESCE((SELECT SUM(a.amount) FROM bms.payment_allocations a
                                 WHERE a.payment_id = p.id), 0) AS unallocated
      FROM bms.payments p
     WHERE p.flat_id = p_flat AND p.status = 'ACTIVE'
     ORDER BY p.payment_date, p.created_at
  LOOP
    v_free := pay.unallocated;
    CONTINUE WHEN v_free <= 0;

    FOR chg IN
      SELECT fc.id
        FROM bms.flat_charges fc
       WHERE fc.flat_id = p_flat AND NOT fc.is_cancelled
       ORDER BY fc.period_year, fc.period_month,
                CASE fc.charge_source WHEN 'OPENING' THEN 0 ELSE 1 END
    LOOP
      EXIT WHEN v_free <= 0;
      v_due := bms.charge_due(chg.id);
      CONTINUE WHEN v_due <= 0;

      v_take := LEAST(v_free, v_due);
      INSERT INTO bms.payment_allocations(payment_id, flat_charge_id, amount)
      VALUES (pay.id, chg.id, v_take);
      v_free      := v_free - v_take;
      v_allocated := v_allocated + v_take;
    END LOOP;
  END LOOP;

  RETURN v_allocated;
END $$;

-- ---------------------------------------------------------------------
-- GENERATE A MONTH.
-- Idempotent by construction: charge_runs is UNIQUE on (year, month, type)
-- and flat_charges is UNIQUE on (flat, year, month, source).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.generate_monthly_charges(p_year int, p_month int)
RETURNS bms.charge_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  run       bms.charge_runs;
  s         bms.building_settings;
  f         record;
  v_amount  numeric(14,2);
  v_due     date;
  v_count   int := 0;
  v_total   numeric(14,2) := 0;
  v_charge  uuid;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_month < 1 OR p_month > 12 THEN RAISE EXCEPTION 'Month must be 1-12'; END IF;

  SELECT * INTO s FROM bms.building_settings WHERE id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building settings have not been configured yet'; END IF;

  IF bms.period_is_closed(make_date(p_year, p_month, 1)) THEN
    RAISE EXCEPTION 'Accounting period % is closed', to_char(make_date(p_year,p_month,1),'Mon YYYY');
  END IF;

  -- Make sure the month exists as an accounting period even if no cash has
  -- moved yet, so it shows up on the settings screen and can be closed.
  PERFORM bms.period_for(make_date(p_year, p_month, 1));

  -- Reuse the month's run if there is one; the charges hang off it either
  -- way, so a flat added in week three belongs to the same monthly run as
  -- the flats billed in week one.
  SELECT * INTO run FROM bms.charge_runs
   WHERE period_year = p_year AND period_month = p_month AND run_type = 'MONTHLY';
  IF NOT FOUND THEN
    INSERT INTO bms.charge_runs(period_year, period_month, run_type, generated_by)
    VALUES (p_year, p_month, 'MONTHLY', auth.uid())
    RETURNING * INTO run;
  END IF;

  v_due := make_date(p_year, p_month, LEAST(s.charge_due_day, 28));

  -- Only the flats that are not billed for this month yet.
  FOR f IN SELECT fl.id, fl.flat_number, fl.service_charge FROM bms.flats fl
            WHERE fl.status = 'ACTIVE'
              AND NOT EXISTS (SELECT 1 FROM bms.flat_charges fc
                               WHERE fc.flat_id = fl.id
                                 AND fc.period_year = p_year
                                 AND fc.period_month = p_month
                                 AND fc.charge_source = 'MONTHLY')
            ORDER BY fl.floor, fl.flat_number
  LOOP
    v_amount := COALESCE(f.service_charge, s.default_service_charge);

    INSERT INTO bms.flat_charges(run_id, flat_id, period_year, period_month,
                                 charge_source, charge_amount, due_date)
    VALUES (run.id, f.id, p_year, p_month, 'MONTHLY', v_amount, v_due)
    RETURNING id INTO v_charge;

    INSERT INTO bms.charge_line_items(flat_charge_id, label, kind, amount, sort_order)
    VALUES (v_charge, 'Monthly service charge', 'SERVICE', v_amount, 10);

    v_count := v_count + 1;
    v_total := v_total + v_amount;
  END LOOP;

  -- The run totals describe the month as a whole, not just this pass, so
  -- they are recounted from the charges rather than incremented. After a
  -- top-up the row still answers "what was billed for September".
  UPDATE bms.charge_runs r
     SET flat_count   = (SELECT COUNT(*) FROM bms.flat_charges fc
                          WHERE fc.period_year = p_year AND fc.period_month = p_month
                            AND fc.charge_source = 'MONTHLY'),
         total_amount = (SELECT COALESCE(SUM(fc.charge_amount),0) FROM bms.flat_charges fc
                          WHERE fc.period_year = p_year AND fc.period_month = p_month
                            AND fc.charge_source = 'MONTHLY')
   WHERE r.id = run.id RETURNING * INTO run;

  -- How many this pass actually added, so the screen can say so instead of
  -- leaving the person guessing whether anything happened. Set on the
  -- returned record only — deliberately NOT written to the row, because it
  -- describes this call, not the month.
  run.notes := CASE WHEN v_count = 0 THEN 'Every active flat was already billed for this month.'
                    ELSE v_count || ' flat' || CASE WHEN v_count = 1 THEN '' ELSE 's' END
                         || ' billed, ' || to_char(v_total, 'FM999,999,990.00') || ' added.'
               END;

  -- Any flat carrying an advance settles the new month immediately.
  FOR f IN SELECT DISTINCT flat_id FROM bms.payments WHERE status = 'ACTIVE' LOOP
    PERFORM bms.allocate_flat_advance(f.flat_id);
  END LOOP;

  RETURN run;
END $$;

-- ---------------------------------------------------------------------
-- OPENING BALANCE — what a flat already owed on go-live day.
-- Stored as a flat_charges row dated the month before go-live, so all the
-- normal arithmetic applies to it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_opening_balance(
    p_flat uuid, p_amount bms.money_amount, p_year int, p_month int)
RETURNS bms.flat_charges
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE run bms.charge_runs; fc bms.flat_charges; v_paid numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('charges','edit');
  IF p_amount < 0 THEN RAISE EXCEPTION 'Opening balance cannot be negative'; END IF;

  SELECT * INTO run FROM bms.charge_runs
   WHERE period_year = p_year AND period_month = p_month AND run_type = 'OPENING';
  IF NOT FOUND THEN
    INSERT INTO bms.charge_runs(period_year, period_month, run_type, generated_by,
                                notes)
    VALUES (p_year, p_month, 'OPENING', auth.uid(),
            'Opening balances carried in at go-live')
    RETURNING * INTO run;
  END IF;

  SELECT * INTO fc FROM bms.flat_charges
   WHERE flat_id = p_flat AND period_year = p_year AND period_month = p_month
     AND charge_source = 'OPENING';

  IF FOUND THEN
    SELECT COALESCE(SUM(amount),0) INTO v_paid
      FROM bms.payment_allocations WHERE flat_charge_id = fc.id;
    IF v_paid > 0 THEN
      RAISE EXCEPTION 'This opening balance has already been paid against and cannot be changed';
    END IF;
    UPDATE bms.flat_charges SET charge_amount = p_amount WHERE id = fc.id RETURNING * INTO fc;
    DELETE FROM bms.charge_line_items WHERE flat_charge_id = fc.id;
  ELSE
    INSERT INTO bms.flat_charges(run_id, flat_id, period_year, period_month,
                                 charge_source, charge_amount, due_date)
    VALUES (run.id, p_flat, p_year, p_month, 'OPENING', p_amount,
            make_date(p_year, p_month, 28))
    RETURNING * INTO fc;
  END IF;

  INSERT INTO bms.charge_line_items(flat_charge_id, label, kind, amount, sort_order)
  VALUES (fc.id, 'Balance brought forward', 'OPENING', p_amount, 1);

  UPDATE bms.charge_runs cr
     SET flat_count   = (SELECT COUNT(*)            FROM bms.flat_charges WHERE run_id = cr.id),
         total_amount = (SELECT COALESCE(SUM(charge_amount),0) FROM bms.flat_charges WHERE run_id = cr.id)
   WHERE cr.id = run.id;

  PERFORM bms.allocate_flat_advance(p_flat);
  RETURN fc;
END $$;

-- ---------------------------------------------------------------------
-- RECORD A PAYMENT — one atomic operation.
-- payment row -> allocate oldest first -> post INCOME -> receipt number.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.record_payment(
    p_flat uuid, p_amount bms.money_amount, p_date date, p_method text,
    p_account uuid, p_reference text DEFAULT NULL, p_notes text DEFAULT NULL,
    p_payer_name text DEFAULT NULL)
RETURNS bms.payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  pay bms.payments; t bms.transactions; s bms.building_settings;
  v_dept uuid; v_cat uuid; v_flat_no text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF bms.period_is_closed(p_date) THEN RAISE EXCEPTION 'That accounting period is closed'; END IF;

  SELECT flat_number INTO v_flat_no FROM bms.flats WHERE id = p_flat;
  IF v_flat_no IS NULL THEN RAISE EXCEPTION 'Flat not found'; END IF;
  SELECT * INTO s FROM bms.building_settings WHERE id;

  INSERT INTO bms.payments(receipt_no, flat_id, payer_name, payment_date, amount,
                           method, account_id, reference_no, notes, received_by)
  VALUES (bms.next_doc_no('RECEIPT', EXTRACT(YEAR FROM p_date)::int, COALESCE(s.receipt_prefix,'RCT')),
          p_flat, p_payer_name, p_date, p_amount, p_method, p_account, p_reference, p_notes, auth.uid())
  RETURNING * INTO pay;

  PERFORM bms.allocate_flat_advance(p_flat);

  -- Money received is income, and posts immediately: collecting a service
  -- charge is not a spend that needs a second person's approval.
  SELECT id INTO v_dept FROM bms.departments WHERE code = 'SERVICE_CHARGE';
  SELECT id INTO v_cat  FROM bms.categories
    WHERE department_id = v_dept AND name = 'Monthly service charge' LIMIT 1;

  INSERT INTO bms.transactions(
      txn_date, direction, department_id, category_id, description, amount,
      payment_method, account_id, flat_id, reference_no, status, created_by,
      source_module, source_ref)
  VALUES (p_date, 'INCOME', v_dept, v_cat,
          'Service charge received — flat ' || v_flat_no || ' (' || pay.receipt_no || ')',
          p_amount, p_method, p_account, p_flat, p_reference, 'DRAFT', auth.uid(),
          'charges', pay.id)
  RETURNING * INTO t;

  UPDATE bms.transactions SET status = 'APPROVED', approved_by = NULL, approved_at = now()
   WHERE id = t.id;
  t := bms.post_transaction(t.id);

  UPDATE bms.payments SET txn_id = t.id WHERE id = pay.id RETURNING * INTO pay;
  RETURN pay;
END $$;

-- Reverse a payment: undo its allocations, reverse its income transaction,
-- and re-run allocation so later payments settle the freed-up charges.
CREATE OR REPLACE FUNCTION bms.reverse_payment(p_payment uuid, p_reason text)
RETURNS bms.payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE pay bms.payments;
BEGIN
  PERFORM bms.assert_perm('charges','cancel');
  IF COALESCE(btrim(p_reason),'') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO pay FROM bms.payments WHERE id = p_payment FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF pay.status = 'REVERSED' THEN RAISE EXCEPTION 'That payment is already reversed'; END IF;

  DELETE FROM bms.payment_allocations WHERE payment_id = pay.id;

  IF pay.txn_id IS NOT NULL THEN
    PERFORM bms.reverse_transaction(pay.txn_id, 'Payment reversed: ' || p_reason);
  END IF;

  UPDATE bms.payments SET status = 'REVERSED', reversal_reason = p_reason
   WHERE id = pay.id RETURNING * INTO pay;

  PERFORM bms.allocate_flat_advance(pay.flat_id);
  RETURN pay;
END $$;

-- ---------------------------------------------------------------------
-- WAIVERS AND ADJUSTMENTS — requested by one person, approved by another.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.request_adjustment(
    p_charge uuid, p_type text, p_amount bms.money_amount, p_reason text)
RETURNS bms.adjustments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE a bms.adjustments; v_flat uuid; v_net numeric(14,2); v_paid numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF COALESCE(btrim(p_reason),'') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;

  SELECT flat_id, net_payable INTO v_flat, v_net FROM bms.flat_charges WHERE id = p_charge;
  IF v_flat IS NULL THEN RAISE EXCEPTION 'Charge not found'; END IF;

  IF p_type IN ('WAIVER','DISCOUNT') THEN
    SELECT COALESCE(SUM(amount),0) INTO v_paid
      FROM bms.payment_allocations WHERE flat_charge_id = p_charge;
    IF p_amount > v_net - v_paid THEN
      RAISE EXCEPTION 'Cannot waive % — only % is still outstanding on that charge',
        p_amount, v_net - v_paid;
    END IF;
  END IF;

  INSERT INTO bms.adjustments(flat_id, flat_charge_id, adj_type, amount, reason, requested_by)
  VALUES (v_flat, p_charge, p_type, p_amount, p_reason, auth.uid())
  RETURNING * INTO a;
  RETURN a;
END $$;

CREATE OR REPLACE FUNCTION bms.approve_adjustment(p_adj uuid)
RETURNS bms.adjustments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE a bms.adjustments; v_allow_self boolean;
BEGIN
  PERFORM bms.assert_perm('charges','waive');
  SELECT * INTO a FROM bms.adjustments WHERE id = p_adj FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Adjustment not found'; END IF;
  IF a.status <> 'PENDING' THEN RAISE EXCEPTION 'That adjustment is already %', a.status; END IF;

  IF a.requested_by = auth.uid() THEN
    SELECT allow_self_approval INTO v_allow_self FROM bms.building_settings WHERE id;
    IF NOT COALESCE(v_allow_self, false) THEN
      RAISE EXCEPTION 'You cannot approve a waiver you requested yourself' USING ERRCODE = '42501';
    END IF;
  END IF;

  UPDATE bms.adjustments SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now()
   WHERE id = a.id RETURNING * INTO a;

  PERFORM bms.allocate_flat_advance(a.flat_id);
  RETURN a;
END $$;

CREATE OR REPLACE FUNCTION bms.reject_adjustment(p_adj uuid, p_reason text)
RETURNS bms.adjustments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE a bms.adjustments;
BEGIN
  PERFORM bms.assert_perm('charges','waive');
  UPDATE bms.adjustments
     SET status = 'REJECTED', rejected_reason = p_reason,
         approved_by = auth.uid(), approved_at = now()
   WHERE id = p_adj AND status = 'PENDING'
  RETURNING * INTO a;
  IF NOT FOUND THEN RAISE EXCEPTION 'That adjustment is not pending'; END IF;
  RETURN a;
END $$;

-- END 011_charge_functions.sql


-- =====================================================================
-- BEGIN 012_operations_functions.sql
-- =====================================================================

-- =====================================================================
-- 012_operations_functions.sql — Phase 3 rules.
--
-- Same principle as the finance engine: anything that changes state or
-- spends money goes through a function here, so the rule holds whether
-- the caller is the portal, a console or a direct API call.
-- =====================================================================

SET search_path = bms, public;

-- Which module governs an asset. One asset table, but a caretaker who may
-- log a generator run must not be able to retire a lift.
CREATE OR REPLACE FUNCTION bms.asset_module(p_type text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_type
           WHEN 'GENERATOR'         THEN 'generator'
           WHEN 'LIFT'              THEN 'lift'
           WHEN 'FIRE_EXTINGUISHER' THEN 'fire'
           ELSE 'maintenance'
         END
$$;

-- ---------------------------------------------------------------------
-- GENERATOR
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.log_generator_run(
    p_asset uuid, p_gen_start timestamptz, p_gen_stop timestamptz DEFAULT NULL,
    p_outage_start timestamptz DEFAULT NULL, p_outage_end timestamptz DEFAULT NULL,
    p_reason text DEFAULT 'POWER_CUT',
    p_hour_start numeric DEFAULT NULL, p_hour_stop numeric DEFAULT NULL,
    p_fuel_litres numeric DEFAULT NULL, p_remark text DEFAULT NULL)
RETURNS bms.generator_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.generator_runs; v_type text;
BEGIN
  PERFORM bms.assert_perm('generator','add');

  SELECT asset_type INTO v_type FROM bms.assets WHERE id = p_asset;
  IF v_type IS NULL THEN RAISE EXCEPTION 'Generator not found'; END IF;
  IF v_type <> 'GENERATOR' THEN RAISE EXCEPTION 'That asset is not a generator'; END IF;
  IF p_gen_stop IS NOT NULL AND p_gen_stop < p_gen_start THEN
    RAISE EXCEPTION 'The generator cannot stop before it started';
  END IF;
  IF p_gen_start > now() + INTERVAL '1 hour' THEN
    RAISE EXCEPTION 'A generator run cannot be logged for a future time';
  END IF;
  IF p_hour_stop IS NOT NULL AND p_hour_start IS NOT NULL AND p_hour_stop < p_hour_start THEN
    RAISE EXCEPTION 'The hour meter cannot go backwards';
  END IF;

  INSERT INTO bms.generator_runs(asset_id, outage_start, gen_start, gen_stop, outage_end,
                                 reason, hour_meter_start, hour_meter_stop,
                                 fuel_used_litres, problem_remark, recorded_by)
  VALUES (p_asset, p_outage_start, p_gen_start, p_gen_stop, p_outage_end,
          p_reason, p_hour_start, p_hour_stop, p_fuel_litres, p_remark, auth.uid())
  RETURNING * INTO r;

  -- A stop reading is also a meter reading. Recording it in one place keeps
  -- "hours run this month" honest even when a run is logged in two steps.
  IF p_hour_stop IS NOT NULL THEN
    INSERT INTO bms.asset_meter_readings(asset_id, reading_date, reading_value, unit, recorded_by)
    VALUES (p_asset, COALESCE(p_gen_stop, p_gen_start)::date, p_hour_stop, 'HOURS', auth.uid())
    ON CONFLICT (asset_id, reading_date)
      DO UPDATE SET reading_value = GREATEST(bms.asset_meter_readings.reading_value, EXCLUDED.reading_value);
  END IF;

  RETURN r;
END $$;

-- Close a run that was started earlier and left open.
CREATE OR REPLACE FUNCTION bms.close_generator_run(
    p_run uuid, p_gen_stop timestamptz, p_hour_stop numeric DEFAULT NULL,
    p_outage_end timestamptz DEFAULT NULL, p_remark text DEFAULT NULL)
RETURNS bms.generator_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.generator_runs;
BEGIN
  PERFORM bms.assert_perm('generator','edit');
  SELECT * INTO r FROM bms.generator_runs WHERE id = p_run FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Run not found'; END IF;
  IF r.gen_stop IS NOT NULL THEN RAISE EXCEPTION 'That run is already closed'; END IF;
  IF p_gen_stop < r.gen_start THEN RAISE EXCEPTION 'The generator cannot stop before it started'; END IF;

  UPDATE bms.generator_runs
     SET gen_stop = p_gen_stop, hour_meter_stop = COALESCE(p_hour_stop, hour_meter_stop),
         outage_end = COALESCE(p_outage_end, outage_end),
         problem_remark = COALESCE(p_remark, problem_remark)
   WHERE id = p_run RETURNING * INTO r;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION bms.record_fuel_purchase(
    p_asset uuid, p_date date, p_fuel_type text, p_quantity numeric,
    p_unit_price bms.money_amount, p_unit text DEFAULT 'LITRE',
    p_vendor uuid DEFAULT NULL, p_invoice text DEFAULT NULL,
    p_hour_meter numeric DEFAULT NULL, p_account uuid DEFAULT NULL,
    p_method text DEFAULT 'CASH')
RETURNS bms.fuel_purchases
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE fp bms.fuel_purchases; t bms.transactions; v_dept uuid; v_cat uuid; v_name text;
BEGIN
  PERFORM bms.assert_perm('generator','add');
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than zero'; END IF;
  IF p_unit_price < 0 THEN RAISE EXCEPTION 'Unit price cannot be negative'; END IF;

  INSERT INTO bms.fuel_purchases(asset_id, purchase_date, fuel_type, quantity, unit,
                                 unit_price, vendor_id, invoice_no, hour_meter_reading, entered_by)
  VALUES (p_asset, p_date, p_fuel_type, p_quantity, p_unit, p_unit_price,
          p_vendor, p_invoice, p_hour_meter, auth.uid())
  RETURNING * INTO fp;

  SELECT name INTO v_name FROM bms.assets WHERE id = p_asset;
  SELECT id INTO v_dept FROM bms.departments WHERE code = 'GENERATOR';
  SELECT id INTO v_cat FROM bms.categories
   WHERE department_id = v_dept
     AND name = CASE WHEN p_fuel_type IN ('ENGINE_OIL','COOLANT')
                     THEN 'Engine oil & coolant' ELSE 'Diesel / fuel' END
   LIMIT 1;

  -- The money goes through the ordinary expense route, so a caretaker's
  -- fuel bill waits for approval exactly like any other spend.
  t := bms.create_transaction(
        p_date, 'EXPENSE', v_dept, v_cat,
        format('%s %s %s for %s', p_quantity, lower(p_unit), lower(replace(p_fuel_type,'_',' ')),
               COALESCE(v_name, 'the generator')),
        fp.total_amount, p_method, p_account, NULL, p_vendor, NULL,
        p_invoice, NULL, true, 'generator', fp.id);

  UPDATE bms.fuel_purchases SET txn_id = t.id WHERE id = fp.id RETURNING * INTO fp;

  IF p_hour_meter IS NOT NULL AND p_asset IS NOT NULL THEN
    INSERT INTO bms.asset_meter_readings(asset_id, reading_date, reading_value, unit, recorded_by)
    VALUES (p_asset, p_date, p_hour_meter, 'HOURS', auth.uid())
    ON CONFLICT (asset_id, reading_date) DO UPDATE SET reading_value = EXCLUDED.reading_value;
  END IF;

  RETURN fp;
END $$;

-- ---------------------------------------------------------------------
-- ASSET SERVICING AND INSPECTION
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.record_asset_service(
    p_asset uuid, p_date date, p_service_type text, p_description text,
    p_cost bms.money_amount DEFAULT 0, p_vendor uuid DEFAULT NULL,
    p_technician text DEFAULT NULL, p_next_due date DEFAULT NULL,
    p_account uuid DEFAULT NULL, p_method text DEFAULT 'CASH',
    p_parts jsonb DEFAULT '[]'::jsonb, p_notes text DEFAULT NULL)
RETURNS bms.asset_service_logs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  log bms.asset_service_logs; t bms.transactions;
  a bms.assets; v_module text; v_dept uuid; v_cat uuid;
  part jsonb; v_next date;
BEGIN
  SELECT * INTO a FROM bms.assets WHERE id = p_asset;
  IF NOT FOUND THEN RAISE EXCEPTION 'Asset not found'; END IF;
  v_module := bms.asset_module(a.asset_type);
  PERFORM bms.assert_perm(v_module, 'add');
  IF p_cost < 0 THEN RAISE EXCEPTION 'Cost cannot be negative'; END IF;

  -- If no next date was given, work it out from the asset's own interval.
  v_next := COALESCE(p_next_due,
              CASE WHEN a.service_interval_days IS NOT NULL
                   THEN p_date + a.service_interval_days ELSE NULL END);

  INSERT INTO bms.asset_service_logs(asset_id, service_date, service_type, vendor_id,
                                     technician, description, cost, next_due_date,
                                     performed_by, notes)
  VALUES (p_asset, p_date, p_service_type, p_vendor, p_technician, p_description,
          p_cost, v_next, auth.uid(), p_notes)
  RETURNING * INTO log;

  FOR part IN SELECT * FROM jsonb_array_elements(COALESCE(p_parts, '[]'::jsonb)) LOOP
    INSERT INTO bms.asset_parts(service_log_id, part_name, quantity, unit_cost, warranty_months)
    VALUES (log.id,
            COALESCE(part->>'part_name', 'Part'),
            COALESCE((part->>'quantity')::numeric, 1),
            COALESCE((part->>'unit_cost')::numeric, 0),
            NULLIF(part->>'warranty_months','')::int);
  END LOOP;

  IF p_cost > 0 THEN
    v_dept := a.department_id;
    IF v_dept IS NULL THEN
      SELECT id INTO v_dept FROM bms.departments
       WHERE code = CASE a.asset_type WHEN 'GENERATOR' THEN 'GENERATOR'
                                      WHEN 'LIFT' THEN 'LIFT'
                                      ELSE 'MAINTENANCE' END;
    END IF;
    SELECT id INTO v_cat FROM bms.categories
     WHERE department_id = v_dept
       AND name = CASE WHEN p_service_type = 'ROUTINE' AND a.asset_type = 'LIFT'
                       THEN 'Monthly servicing (AMC)'
                       WHEN p_service_type = 'ROUTINE' THEN 'Servicing'
                       ELSE 'Repair & parts' END
     LIMIT 1;
    IF v_cat IS NULL THEN
      SELECT id INTO v_cat FROM bms.categories WHERE department_id = v_dept LIMIT 1;
    END IF;

    t := bms.create_transaction(
          p_date, 'EXPENSE', v_dept, v_cat,
          format('%s — %s', a.name, p_description),
          p_cost, p_method, p_account, NULL, p_vendor, NULL,
          NULL, NULL, true, 'asset_service', log.id);
    UPDATE bms.asset_service_logs SET txn_id = t.id WHERE id = log.id RETURNING * INTO log;
  END IF;

  UPDATE bms.assets
     SET last_service_date = GREATEST(COALESCE(last_service_date, p_date), p_date),
         next_service_date = COALESCE(v_next, next_service_date),
         condition = CASE WHEN p_service_type = 'BREAKDOWN' THEN 'FAIR' ELSE condition END
   WHERE id = p_asset;

  RETURN log;
END $$;

CREATE OR REPLACE FUNCTION bms.record_inspection(
    p_asset uuid, p_date date, p_result text,
    p_next_date date DEFAULT NULL, p_inspector text DEFAULT NULL,
    p_pressure_ok boolean DEFAULT NULL, p_seal_ok boolean DEFAULT NULL,
    p_access_clear boolean DEFAULT NULL, p_remarks text DEFAULT NULL)
RETURNS bms.asset_inspections
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE ins bms.asset_inspections; a bms.assets; v_next date;
BEGIN
  SELECT * INTO a FROM bms.assets WHERE id = p_asset;
  IF NOT FOUND THEN RAISE EXCEPTION 'Asset not found'; END IF;
  PERFORM bms.assert_perm(bms.asset_module(a.asset_type), 'add');

  v_next := COALESCE(p_next_date,
              CASE WHEN a.service_interval_days IS NOT NULL
                   THEN p_date + a.service_interval_days
                   ELSE p_date + 180 END);   -- six months is the usual default

  INSERT INTO bms.asset_inspections(asset_id, inspection_date, inspector, result,
                                    pressure_ok, seal_ok, access_clear,
                                    next_inspection_date, remarks, recorded_by)
  VALUES (p_asset, p_date, p_inspector, p_result, p_pressure_ok, p_seal_ok,
          p_access_clear, v_next, p_remarks, auth.uid())
  RETURNING * INTO ins;

  UPDATE bms.assets
     SET last_inspection_date = p_date,
         next_inspection_date = v_next,
         condition = CASE p_result WHEN 'FAIL' THEN 'POOR'
                                   WHEN 'NEEDS_ATTENTION' THEN 'FAIR'
                                   ELSE condition END
   WHERE id = p_asset;

  RETURN ins;
END $$;

-- ---------------------------------------------------------------------
-- MAINTENANCE ISSUES
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.create_issue(
    p_title text, p_description text DEFAULT NULL,
    p_priority text DEFAULT 'MEDIUM', p_department uuid DEFAULT NULL,
    p_asset uuid DEFAULT NULL, p_flat uuid DEFAULT NULL,
    p_location text DEFAULT NULL, p_floor int DEFAULT NULL,
    p_estimated_cost bms.money_amount DEFAULT NULL)
RETURNS bms.issues
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE i bms.issues; s bms.building_settings; v_hours int;
BEGIN
  PERFORM bms.assert_perm('maintenance','add');
  IF COALESCE(btrim(p_title),'') = '' THEN RAISE EXCEPTION 'Please describe the problem'; END IF;

  SELECT * INTO s FROM bms.building_settings WHERE id;
  v_hours := CASE p_priority
               WHEN 'CRITICAL' THEN s.sla_hours_critical
               WHEN 'HIGH'     THEN s.sla_hours_high
               WHEN 'MEDIUM'   THEN s.sla_hours_medium
               ELSE s.sla_hours_low END;

  INSERT INTO bms.issues(issue_no, title, description, priority, department_id,
                         asset_id, flat_id, location, floor, estimated_cost,
                         reported_by, due_at)
  VALUES (bms.next_doc_no('ISSUE', EXTRACT(YEAR FROM CURRENT_DATE)::int, 'ISS'),
          p_title, p_description, p_priority, p_department, p_asset, p_flat,
          p_location, p_floor, p_estimated_cost, auth.uid(),
          now() + make_interval(hours => v_hours))
  RETURNING * INTO i;

  INSERT INTO bms.issue_updates(issue_id, note, status_to, created_by)
  VALUES (i.id, 'Reported', 'OPEN', auth.uid());
  RETURN i;
END $$;

CREATE OR REPLACE FUNCTION bms.update_issue(
    p_issue uuid, p_status text, p_note text DEFAULT NULL,
    p_staff uuid DEFAULT NULL, p_vendor uuid DEFAULT NULL,
    p_actual_cost bms.money_amount DEFAULT NULL, p_resolution text DEFAULT NULL,
    p_account uuid DEFAULT NULL, p_method text DEFAULT 'CASH')
RETURNS bms.issues
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE i bms.issues; old_status text; t bms.transactions; v_cat uuid; v_dept uuid;
BEGIN
  SELECT * INTO i FROM bms.issues WHERE id = p_issue FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Issue not found'; END IF;
  old_status := i.status;

  -- Verifying is a separate authority from doing the work. A caretaker may
  -- report a problem and mark it done; signing off that it really is done
  -- needs maintenance.approve, which the caretaker role does not hold.
  IF p_status = 'VERIFIED' THEN
    PERFORM bms.assert_perm('maintenance','approve');
    IF i.status <> 'COMPLETED' THEN
      RAISE EXCEPTION 'Only a completed issue can be verified (this one is %)', i.status;
    END IF;
    IF i.completed_at IS NOT NULL AND EXISTS (
         SELECT 1 FROM bms.issue_updates u
          WHERE u.issue_id = p_issue AND u.status_to = 'COMPLETED'
            AND u.created_by = auth.uid())
       AND NOT COALESCE((SELECT allow_self_approval FROM bms.building_settings WHERE id), false) THEN
      RAISE EXCEPTION 'You marked this work complete, so someone else must verify it'
        USING ERRCODE = '42501';
    END IF;
  ELSE
    PERFORM bms.assert_perm('maintenance','edit');
  END IF;

  IF p_status = 'CANCELLED' AND COALESCE(btrim(p_note),'') = '' THEN
    RAISE EXCEPTION 'A reason is required to cancel an issue';
  END IF;

  UPDATE bms.issues
     SET status = p_status,
         assigned_staff_id  = COALESCE(p_staff, assigned_staff_id),
         assigned_vendor_id = COALESCE(p_vendor, assigned_vendor_id),
         assigned_at = CASE WHEN p_status = 'ASSIGNED' THEN now() ELSE assigned_at END,
         actual_cost = COALESCE(p_actual_cost, actual_cost),
         resolution  = COALESCE(p_resolution, resolution),
         completed_at = CASE WHEN p_status = 'COMPLETED' THEN now() ELSE completed_at END,
         verified_by  = CASE WHEN p_status = 'VERIFIED' THEN auth.uid() ELSE verified_by END,
         verified_at  = CASE WHEN p_status = 'VERIFIED' THEN now() ELSE verified_at END,
         cancel_reason = CASE WHEN p_status = 'CANCELLED' THEN p_note ELSE cancel_reason END
   WHERE id = p_issue
  RETURNING * INTO i;

  INSERT INTO bms.issue_updates(issue_id, note, status_from, status_to, created_by)
  VALUES (p_issue, p_note, old_status, p_status, auth.uid());

  -- A cost recorded on completion becomes an ordinary expense, with the
  -- ordinary approval rules.
  IF p_status IN ('COMPLETED','VERIFIED') AND p_actual_cost IS NOT NULL
     AND p_actual_cost > 0 AND i.txn_id IS NULL THEN
    v_dept := COALESCE(i.department_id,
                       (SELECT id FROM bms.departments WHERE code = 'MAINTENANCE'));
    SELECT id INTO v_cat FROM bms.categories WHERE department_id = v_dept LIMIT 1;
    t := bms.create_transaction(
          CURRENT_DATE, 'EXPENSE', v_dept, v_cat,
          format('%s — %s', COALESCE(i.issue_no,'Issue'), i.title),
          p_actual_cost, p_method, p_account, NULL, i.assigned_vendor_id, i.flat_id,
          NULL, NULL, true, 'maintenance', i.id);
    UPDATE bms.issues SET txn_id = t.id WHERE id = p_issue RETURNING * INTO i;
  END IF;

  RETURN i;
END $$;

-- ---------------------------------------------------------------------
-- STAFF: attendance, salary
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.mark_attendance(
    p_work_date date, p_entries jsonb)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE e jsonb; n int := 0;
BEGIN
  PERFORM bms.assert_perm('staff','add');
  IF p_work_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'Attendance cannot be marked for a future date';
  END IF;

  FOR e IN SELECT * FROM jsonb_array_elements(COALESCE(p_entries, '[]'::jsonb)) LOOP
    INSERT INTO bms.staff_attendance(staff_id, work_date, status, remarks, recorded_by)
    VALUES ((e->>'staff_id')::uuid, p_work_date, e->>'status',
            NULLIF(e->>'remarks',''), auth.uid())
    ON CONFLICT (staff_id, work_date)
      DO UPDATE SET status = EXCLUDED.status, remarks = EXCLUDED.remarks,
                    recorded_by = EXCLUDED.recorded_by;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION bms.generate_salary_run(p_year int, p_month int)
RETURNS bms.salary_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  run bms.salary_runs; st record;
  v_absent int; v_deduction numeric(14,2); v_daily numeric(14,2);
  v_days int; v_advance numeric(14,2);
  v_count int := 0; v_total numeric(14,2) := 0;
BEGIN
  PERFORM bms.assert_perm('salary','add');

  SELECT * INTO run FROM bms.salary_runs
   WHERE period_year = p_year AND period_month = p_month;
  IF FOUND THEN
    RAISE EXCEPTION 'Salary for % has already been generated.',
      to_char(make_date(p_year,p_month,1),'Mon YYYY');
  END IF;

  v_days := EXTRACT(DAY FROM (make_date(p_year,p_month,1) + INTERVAL '1 month - 1 day'))::int;

  INSERT INTO bms.salary_runs(period_year, period_month, generated_by)
  VALUES (p_year, p_month, auth.uid()) RETURNING * INTO run;

  FOR st IN
    SELECT s.id, s.salary FROM bms.staff s
     WHERE s.status = 'ACTIVE'
       AND s.joining_date <= make_date(p_year, p_month, v_days)
       AND (s.leaving_date IS NULL OR s.leaving_date >= make_date(p_year, p_month, 1))
  LOOP
    SELECT COUNT(*) INTO v_absent FROM bms.staff_attendance a
     WHERE a.staff_id = st.id AND a.status = 'ABSENT'
       AND EXTRACT(YEAR FROM a.work_date)::int = p_year
       AND EXTRACT(MONTH FROM a.work_date)::int = p_month;

    -- An unexcused absence costs one day's pay. Everything about that rule
    -- is arithmetic in SQL, not in a browser.
    v_daily     := ROUND(st.salary / v_days, 2);
    v_deduction := ROUND(v_daily * v_absent, 2);

    SELECT COALESCE(SUM(amount - recovered_amount), 0) INTO v_advance
      FROM bms.staff_advances WHERE staff_id = st.id;
    v_advance := LEAST(v_advance, GREATEST(st.salary - v_deduction, 0));

    INSERT INTO bms.salary_payments(run_id, staff_id, base_salary, deduction,
                                    advance_recovery, absent_days)
    VALUES (run.id, st.id, st.salary, v_deduction, v_advance, v_absent);

    v_count := v_count + 1;
    v_total := v_total + (st.salary - v_deduction - v_advance);
  END LOOP;

  UPDATE bms.salary_runs SET staff_count = v_count, total_amount = v_total
   WHERE id = run.id RETURNING * INTO run;
  RETURN run;
END $$;

CREATE OR REPLACE FUNCTION bms.pay_salary(
    p_payment uuid, p_date date, p_account uuid, p_method text DEFAULT 'CASH')
RETURNS bms.salary_payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  sp bms.salary_payments; t bms.transactions;
  v_name text; v_dept uuid; v_cat uuid; v_period text; v_left numeric(14,2);
  adv record;
BEGIN
  PERFORM bms.assert_perm('salary','edit');
  SELECT * INTO sp FROM bms.salary_payments WHERE id = p_payment FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Salary line not found'; END IF;
  IF sp.status = 'PAID' THEN RAISE EXCEPTION 'That salary has already been paid'; END IF;
  IF sp.net_payable <= 0 THEN RAISE EXCEPTION 'Nothing is payable on that line'; END IF;

  SELECT s.name, sp2.department_id, sp2.category_id INTO v_name, v_dept, v_cat
    FROM bms.staff s JOIN bms.staff_positions sp2 ON sp2.id = s.position_id
   WHERE s.id = sp.staff_id;

  SELECT to_char(make_date(r.period_year, r.period_month, 1), 'Mon YYYY') INTO v_period
    FROM bms.salary_runs r WHERE r.id = sp.run_id;

  IF v_cat IS NULL THEN
    SELECT id INTO v_cat FROM bms.categories WHERE department_id = v_dept LIMIT 1;
  END IF;

  t := bms.create_transaction(
        p_date, 'EXPENSE', v_dept, v_cat,
        format('Salary %s — %s', v_period, v_name),
        sp.net_payable, p_method, p_account, NULL, NULL, NULL,
        NULL, NULL, true, 'salary', sp.id);

  UPDATE bms.salary_payments
     SET status = 'PAID', paid_date = p_date, txn_id = t.id
   WHERE id = p_payment RETURNING * INTO sp;

  -- Recover the advance against the oldest outstanding advance first.
  v_left := sp.advance_recovery;
  FOR adv IN SELECT id, amount - recovered_amount AS outstanding
               FROM bms.staff_advances
              WHERE staff_id = sp.staff_id AND amount > recovered_amount
              ORDER BY advance_date
  LOOP
    EXIT WHEN v_left <= 0;
    UPDATE bms.staff_advances
       SET recovered_amount = recovered_amount + LEAST(v_left, adv.outstanding)
     WHERE id = adv.id;
    v_left := v_left - LEAST(v_left, adv.outstanding);
  END LOOP;

  RETURN sp;
END $$;

CREATE OR REPLACE FUNCTION bms.record_staff_advance(
    p_staff uuid, p_date date, p_amount bms.money_amount,
    p_account uuid, p_reason text DEFAULT NULL, p_method text DEFAULT 'CASH')
RETURNS bms.staff_advances
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE adv bms.staff_advances; t bms.transactions; v_name text; v_dept uuid; v_cat uuid;
BEGIN
  PERFORM bms.assert_perm('salary','add');
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;

  SELECT s.name, sp.department_id, sp.category_id INTO v_name, v_dept, v_cat
    FROM bms.staff s JOIN bms.staff_positions sp ON sp.id = s.position_id
   WHERE s.id = p_staff;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Staff member not found'; END IF;

  INSERT INTO bms.staff_advances(staff_id, advance_date, amount, reason, created_by)
  VALUES (p_staff, p_date, p_amount, p_reason, auth.uid()) RETURNING * INTO adv;

  t := bms.create_transaction(
        p_date, 'EXPENSE', v_dept, v_cat,
        format('Salary advance — %s', v_name),
        p_amount, p_method, p_account, NULL, NULL, NULL,
        NULL, p_reason, true, 'staff_advance', adv.id);

  UPDATE bms.staff_advances SET txn_id = t.id WHERE id = adv.id RETURNING * INTO adv;
  RETURN adv;
END $$;

-- ---------------------------------------------------------------------
-- WORK MONITORING
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.save_work_log(
    p_template uuid, p_staff uuid, p_date date, p_items jsonb,
    p_remarks text DEFAULT NULL, p_shift text DEFAULT NULL)
RETURNS bms.work_logs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE wl bms.work_logs; it jsonb; v_total int; v_done int;
BEGIN
  PERFORM bms.assert_perm('work','add');
  IF p_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'A work log cannot be dated in the future';
  END IF;

  INSERT INTO bms.work_logs(template_id, staff_id, log_date, shift, remarks, recorded_by)
  VALUES (p_template, p_staff, p_date, p_shift, p_remarks, auth.uid())
  ON CONFLICT (template_id, staff_id, log_date)
    DO UPDATE SET remarks = EXCLUDED.remarks, shift = EXCLUDED.shift,
                  recorded_by = EXCLUDED.recorded_by
  RETURNING * INTO wl;

  FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) LOOP
    INSERT INTO bms.work_log_items(work_log_id, item_id, is_done, remarks)
    VALUES (wl.id, (it->>'item_id')::uuid,
            COALESCE((it->>'is_done')::boolean, false), NULLIF(it->>'remarks',''))
    ON CONFLICT (work_log_id, item_id)
      DO UPDATE SET is_done = EXCLUDED.is_done, remarks = EXCLUDED.remarks;
  END LOOP;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE is_done) INTO v_total, v_done
    FROM bms.work_log_items WHERE work_log_id = wl.id;

  UPDATE bms.work_logs
     SET overall_status = CASE WHEN v_total = 0 OR v_done = 0 THEN 'NOT_DONE'
                               WHEN v_done = v_total THEN 'DONE'
                               ELSE 'PARTIAL' END
   WHERE id = wl.id RETURNING * INTO wl;
  RETURN wl;
END $$;


-- ---------------------------------------------------------------------
-- Editing an asset's condition, location or notes is day-to-day work.
-- Retiring it from the register, or changing what the building paid for
-- it, is not: those need the module's approve permission.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.guard_asset_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF (NEW.status        IS DISTINCT FROM OLD.status
   OR NEW.purchase_cost IS DISTINCT FROM OLD.purchase_cost
   OR NEW.asset_type    IS DISTINCT FROM OLD.asset_type
   OR NEW.asset_code    IS DISTINCT FROM OLD.asset_code)
     AND NOT bms.has_perm(bms.asset_module(NEW.asset_type), 'approve') THEN
    RAISE EXCEPTION 'Changing an asset''s status, code, type or cost needs approval rights'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_assets_guard ON bms.assets;
CREATE TRIGGER trg_assets_guard BEFORE UPDATE ON bms.assets
  FOR EACH ROW EXECUTE FUNCTION bms.guard_asset_update();

-- END 012_operations_functions.sql


-- =====================================================================
-- BEGIN 013_fund_functions.sql
-- =====================================================================

-- =====================================================================
-- 013_fund_functions.sql — reserve funds, fixed deposits, budgets,
-- reconciliation and the notification generator.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- FUNDS
-- ---------------------------------------------------------------------

-- Money set aside. Two shapes, and the difference matters:
--
--   cash-backed  the money physically moves to another account. That is
--                a TRANSFER in the ledger; income and expense are
--                untouched, and both balances change.
--   earmark      the committee resolves to set money aside and it stays
--                exactly where it is. The reserve rises; the bank does
--                not move. No transaction, because no money moved.
CREATE OR REPLACE FUNCTION bms.record_fund_movement(
    p_fund uuid, p_date date, p_direction text, p_amount bms.money_amount,
    p_cash_backed boolean DEFAULT false,
    p_from_account uuid DEFAULT NULL, p_to_account uuid DEFAULT NULL,
    p_purpose text DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS bms.fund_movements
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE mv bms.fund_movements; t bms.transactions; f bms.funds; v_balance numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('reserve','add');
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;

  SELECT * INTO f FROM bms.funds WHERE id = p_fund;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fund not found'; END IF;

  -- You cannot take out more than the fund holds.
  IF p_direction IN ('WITHDRAWAL','TRANSFER_OUT') THEN
    SELECT current_balance INTO v_balance FROM bms.v_fund_balances WHERE fund_id = p_fund;
    IF p_amount > COALESCE(v_balance, 0) THEN
      RAISE EXCEPTION 'The fund only holds %, so % cannot be taken out',
        COALESCE(v_balance,0), p_amount;
    END IF;
  END IF;

  IF p_cash_backed AND p_direction <> 'INTEREST' THEN
    IF p_from_account IS NULL OR p_to_account IS NULL THEN
      RAISE EXCEPTION 'A cash-backed movement needs the account it comes from and the account it goes to';
    END IF;
    IF p_from_account = p_to_account THEN
      RAISE EXCEPTION 'A transfer needs two different accounts';
    END IF;
    t := bms.create_transaction(
          p_date, 'TRANSFER', NULL, NULL,
          format('%s — %s', f.name, COALESCE(p_purpose,
                 CASE p_direction WHEN 'CONTRIBUTION' THEN 'reserve contribution'
                                  WHEN 'WITHDRAWAL'   THEN 'reserve withdrawal'
                                  ELSE lower(replace(p_direction,'_',' ')) END)),
          p_amount, 'BANK_TRANSFER', p_from_account, p_to_account,
          NULL, NULL, NULL, p_notes, true, 'reserve', p_fund);
  END IF;

  INSERT INTO bms.fund_movements(fund_id, movement_date, direction, amount,
                                 is_cash_movement, txn_id, purpose, notes, created_by)
  VALUES (p_fund, p_date, p_direction, p_amount, p_cash_backed, t.id, p_purpose, p_notes, auth.uid())
  RETURNING * INTO mv;
  RETURN mv;
END $$;

-- ---------------------------------------------------------------------
-- FIXED DEPOSITS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.open_fixed_deposit(
    p_fd_no text, p_bank text, p_principal bms.money_amount, p_date date,
    p_source_account uuid, p_tenure_months int DEFAULT NULL,
    p_rate numeric DEFAULT NULL, p_maturity date DEFAULT NULL,
    p_fund uuid DEFAULT NULL, p_purpose text DEFAULT NULL, p_branch text DEFAULT NULL)
RETURNS bms.fixed_deposits
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE fd bms.fixed_deposits; acct bms.accounts; t bms.transactions;
        v_maturity date; v_expected numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('reserve','add');
  IF p_principal <= 0 THEN RAISE EXCEPTION 'The principal must be greater than zero'; END IF;
  IF p_source_account IS NULL THEN
    RAISE EXCEPTION 'Say which account the money comes from';
  END IF;

  v_maturity := COALESCE(p_maturity,
    CASE WHEN p_tenure_months IS NOT NULL
         THEN (p_date + make_interval(months => p_tenure_months))::date END);

  -- Simple interest is what Bangladeshi FD certificates quote, so that is
  -- what we show as "expected". The bank's actual figure is recorded on
  -- maturity and is the one that reaches the ledger.
  v_expected := CASE
    WHEN p_rate IS NOT NULL AND p_tenure_months IS NOT NULL
    THEN ROUND(p_principal * (1 + (p_rate / 100.0) * (p_tenure_months / 12.0)), 2)
  END;

  -- The FD gets its own account, so the money is visibly somewhere.
  INSERT INTO bms.accounts(code, name, kind, bank_name, opening_balance, opening_date, notes)
  VALUES ('FD-' || upper(p_fd_no), 'FD ' || p_fd_no || ' — ' || p_bank, 'FD',
          p_bank, 0, p_date, p_purpose)
  RETURNING * INTO acct;

  INSERT INTO bms.fixed_deposits(fd_no, bank_name, branch, account_id, source_account_id,
                                 fund_id, principal, deposit_date, tenure_months,
                                 interest_rate, maturity_date, expected_maturity_amount,
                                 purpose, created_by)
  VALUES (p_fd_no, p_bank, p_branch, acct.id, p_source_account, p_fund, p_principal,
          p_date, p_tenure_months, p_rate, v_maturity, v_expected, p_purpose, auth.uid())
  RETURNING * INTO fd;

  -- Opening an FD moves money; it does not spend it.
  t := bms.create_transaction(
        p_date, 'TRANSFER', NULL, NULL,
        format('Fixed deposit %s opened at %s', p_fd_no, p_bank),
        p_principal, 'BANK_TRANSFER', p_source_account, acct.id,
        NULL, NULL, p_fd_no, p_purpose, true, 'fixed_deposit', fd.id);

  INSERT INTO bms.fd_events(fd_id, event_type, event_date, amount, txn_id, created_by)
  VALUES (fd.id, 'OPENED', p_date, p_principal, t.id, auth.uid());

  -- No fund_movement is written when the deposit is tagged to a fund.
  -- Tying an FD to a fund does not change what the fund holds — it says
  -- WHERE the fund holds it. v_fund_balances picks the deposit up as
  -- backing through fixed_deposits.fund_id, so writing a movement here
  -- would count the same money twice.

  RETURN fd;
END $$;

CREATE OR REPLACE FUNCTION bms.record_fd_interest(
    p_fd uuid, p_date date, p_amount bms.money_amount, p_to_account uuid DEFAULT NULL)
RETURNS bms.fd_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE ev bms.fd_events; fd bms.fixed_deposits; t bms.transactions;
        v_dept uuid; v_cat uuid;
BEGIN
  PERFORM bms.assert_perm('reserve','add');
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Interest must be greater than zero'; END IF;
  SELECT * INTO fd FROM bms.fixed_deposits WHERE id = p_fd;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixed deposit not found'; END IF;

  SELECT id INTO v_dept FROM bms.departments WHERE code = 'RESERVE';
  SELECT id INTO v_cat  FROM bms.categories
   WHERE department_id = v_dept AND name = 'Bank interest' LIMIT 1;

  -- Interest is real income, wherever it is credited.
  t := bms.create_transaction(
        p_date, 'INCOME', v_dept, v_cat,
        format('Interest on fixed deposit %s', fd.fd_no),
        p_amount, 'BANK_TRANSFER', COALESCE(p_to_account, fd.account_id),
        NULL, NULL, NULL, fd.fd_no, NULL, true, 'fixed_deposit', fd.id);

  INSERT INTO bms.fd_events(fd_id, event_type, event_date, amount, txn_id, created_by)
  VALUES (p_fd, 'INTEREST_CREDIT', p_date, p_amount, t.id, auth.uid())
  RETURNING * INTO ev;
  RETURN ev;
END $$;

CREATE OR REPLACE FUNCTION bms.mature_fixed_deposit(
    p_fd uuid, p_date date, p_actual_amount bms.money_amount, p_to_account uuid,
    p_premature boolean DEFAULT false)
RETURNS bms.fixed_deposits
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE fd bms.fixed_deposits; t bms.transactions; v_interest numeric(14,2);
        v_held numeric(14,2); v_dept uuid; v_cat uuid;
BEGIN
  PERFORM bms.assert_perm('reserve','approve');
  SELECT * INTO fd FROM bms.fixed_deposits WHERE id = p_fd FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixed deposit not found'; END IF;
  IF fd.status <> 'ACTIVE' THEN RAISE EXCEPTION 'That deposit is already %', fd.status; END IF;
  IF p_actual_amount <= 0 THEN RAISE EXCEPTION 'Enter the amount the bank paid out'; END IF;

  -- Whatever came back above what the deposit already held is NEW income.
  --
  -- The subtlety, and it is the one that silently doubles a building's
  -- reported interest: quarterly interest credited earlier is already
  -- inside this deposit. Booking (payout − principal) again would count
  -- that interest a second time. So the base is what the deposit actually
  -- holds today, not the original principal.
  SELECT COALESCE(current_balance, fd.principal) INTO v_held
    FROM bms.v_account_balances WHERE account_id = fd.account_id;

  v_interest := p_actual_amount - COALESCE(v_held, fd.principal);

  IF v_interest <> 0 THEN
    SELECT id INTO v_dept FROM bms.departments WHERE code = 'RESERVE';
    SELECT id INTO v_cat  FROM bms.categories
     WHERE department_id = v_dept
       AND name = CASE WHEN v_interest > 0 THEN 'Bank interest' ELSE 'Deposit penalty' END
     LIMIT 1;

    -- A premature break can pay back LESS than the deposit holds, because
    -- the bank claws interest back. That is a real cost, and it is booked
    -- as one rather than being quietly lost.
    t := bms.create_transaction(
          p_date,
          CASE WHEN v_interest > 0 THEN 'INCOME' ELSE 'EXPENSE' END,
          v_dept, v_cat,
          format('%s fixed deposit %s',
                 CASE WHEN v_interest > 0 THEN 'Interest on maturity of'
                      ELSE 'Interest forfeited on early encashment of' END, fd.fd_no),
          ABS(v_interest), 'BANK_TRANSFER', fd.account_id, NULL, NULL, NULL,
          fd.fd_no, NULL, true, 'fixed_deposit', fd.id);
  END IF;

  -- Then the whole balance comes back to the bank.
  t := bms.create_transaction(
        p_date, 'TRANSFER', NULL, NULL,
        format('Fixed deposit %s %s', fd.fd_no,
               CASE WHEN p_premature THEN 'encashed early' ELSE 'matured' END),
        p_actual_amount, 'BANK_TRANSFER', fd.account_id, p_to_account,
        NULL, NULL, fd.fd_no, NULL, true, 'fixed_deposit', fd.id);

  UPDATE bms.fixed_deposits
     SET status = CASE WHEN p_premature THEN 'ENCASHED' ELSE 'MATURED' END,
         actual_maturity_amount = p_actual_amount
   WHERE id = p_fd RETURNING * INTO fd;

  INSERT INTO bms.fd_events(fd_id, event_type, event_date, amount, txn_id, created_by)
  VALUES (p_fd, CASE WHEN p_premature THEN 'PREMATURE_ENCASH' ELSE 'MATURITY' END,
          p_date, p_actual_amount, t.id, auth.uid());

  UPDATE bms.accounts SET is_active = false WHERE id = fd.account_id;
  RETURN fd;
END $$;

-- ---------------------------------------------------------------------
-- BUDGETS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_budget(
    p_year int, p_department uuid, p_annual bms.money_amount,
    p_category uuid DEFAULT NULL, p_monthly jsonb DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS bms.budgets
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE b bms.budgets; m int; v_amount numeric(14,2); v_spread numeric(14,2); v_last numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('budget','add');
  IF p_annual < 0 THEN RAISE EXCEPTION 'A budget cannot be negative'; END IF;

  -- Deliberately NOT an ON CONFLICT. A department-level budget has a NULL
  -- category, and in a unique index NULL never equals NULL — so the
  -- conflict would never fire and every re-set would silently stack a
  -- second budget on the first, doubling the year's allowance.
  SELECT * INTO b FROM bms.budgets
   WHERE fiscal_year = p_year AND department_id = p_department
     AND category_id IS NOT DISTINCT FROM p_category
   FOR UPDATE;

  IF FOUND THEN
    UPDATE bms.budgets SET annual_amount = p_annual, notes = p_notes
     WHERE id = b.id RETURNING * INTO b;
  ELSE
    INSERT INTO bms.budgets(fiscal_year, department_id, category_id,
                            annual_amount, notes, created_by)
    VALUES (p_year, p_department, p_category, p_annual, p_notes, auth.uid())
    RETURNING * INTO b;
  END IF;

  DELETE FROM bms.budget_lines WHERE budget_id = b.id;

  IF p_monthly IS NOT NULL AND jsonb_typeof(p_monthly) = 'object' THEN
    FOR m IN 1..12 LOOP
      v_amount := COALESCE((p_monthly ->> m::text)::numeric, 0);
      INSERT INTO bms.budget_lines(budget_id, period_month, amount) VALUES (b.id, m, v_amount);
    END LOOP;
  ELSE
    -- Spread evenly, and put the rounding remainder in December rather
    -- than letting twelve roundings quietly lose a few taka.
    v_spread := ROUND(p_annual / 12.0, 2);
    v_last   := p_annual - (v_spread * 11);
    FOR m IN 1..12 LOOP
      INSERT INTO bms.budget_lines(budget_id, period_month, amount)
      VALUES (b.id, m, CASE WHEN m = 12 THEN v_last ELSE v_spread END);
    END LOOP;
  END IF;

  RETURN b;
END $$;

-- ---------------------------------------------------------------------
-- BANK RECONCILIATION
-- ---------------------------------------------------------------------
-- The statement header. Re-uploading the same account/date returns the
-- statement already there rather than creating a second one, and replaces
-- its lines, so a corrected download from the bank overwrites cleanly
-- instead of doubling every figure.
CREATE OR REPLACE FUNCTION bms.create_bank_statement(
    p_account uuid, p_statement_date date, p_closing_balance bms.money_amount,
    p_period_start date DEFAULT NULL, p_period_end date DEFAULT NULL,
    p_opening_balance bms.money_amount DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS bms.bank_statements
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE st bms.bank_statements;
BEGIN
  PERFORM bms.assert_perm('bank','edit');
  IF p_account IS NULL THEN RAISE EXCEPTION 'Say which account this statement is for'; END IF;

  SELECT * INTO st FROM bms.bank_statements
   WHERE account_id = p_account AND statement_date = p_statement_date;

  IF FOUND THEN
    IF st.status = 'RECONCILED' THEN
      RAISE EXCEPTION 'That statement is already reconciled and cannot be replaced';
    END IF;
    DELETE FROM bms.bank_statement_lines WHERE statement_id = st.id;
    UPDATE bms.bank_statements
       SET closing_balance = p_closing_balance, opening_balance = p_opening_balance,
           period_start = p_period_start, period_end = p_period_end, notes = p_notes
     WHERE id = st.id RETURNING * INTO st;
    RETURN st;
  END IF;

  INSERT INTO bms.bank_statements(account_id, statement_date, period_start, period_end,
                                  opening_balance, closing_balance, notes, uploaded_by)
  VALUES (p_account, p_statement_date, p_period_start, p_period_end,
          p_opening_balance, p_closing_balance, p_notes, auth.uid())
  RETURNING * INTO st;
  RETURN st;
END $$;

-- Pair a statement line with a transaction by hand, for the ones
-- auto-matching would not touch.
CREATE OR REPLACE FUNCTION bms.match_statement_line(
    p_line uuid, p_txn uuid, p_ignore boolean DEFAULT false)
RETURNS bms.bank_statement_lines
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE ln bms.bank_statement_lines;
BEGIN
  PERFORM bms.assert_perm('bank','edit');

  IF p_ignore THEN
    UPDATE bms.bank_statement_lines
       SET matched_txn_id = NULL, match_status = 'IGNORED'
     WHERE id = p_line RETURNING * INTO ln;
  ELSE
    -- One bank line, one transaction. Letting a transaction answer for
    -- two lines is how a reconciliation comes out clean while the money
    -- is wrong.
    IF EXISTS (SELECT 1 FROM bms.bank_statement_lines
                WHERE matched_txn_id = p_txn AND id <> p_line) THEN
      RAISE EXCEPTION 'That transaction is already matched to another statement line';
    END IF;
    UPDATE bms.bank_statement_lines
       SET matched_txn_id = p_txn, match_status = 'MANUAL_MATCHED'
     WHERE id = p_line RETURNING * INTO ln;
  END IF;

  IF ln.id IS NULL THEN RAISE EXCEPTION 'Statement line not found'; END IF;
  RETURN ln;
END $$;

CREATE OR REPLACE FUNCTION bms.import_statement_lines(p_statement uuid, p_lines jsonb)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE ln jsonb; n int := 0;
BEGIN
  PERFORM bms.assert_perm('bank','edit');
  FOR ln IN SELECT * FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) LOOP
    INSERT INTO bms.bank_statement_lines(statement_id, line_date, description, reference, debit, credit)
    VALUES (p_statement, (ln->>'line_date')::date, ln->>'description', ln->>'reference',
            COALESCE((ln->>'debit')::numeric, 0), COALESCE((ln->>'credit')::numeric, 0));
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Match statement lines to posted transactions on the same account, by
-- amount and a close date. Anything ambiguous is left alone for a person
-- to decide: a wrong automatic match is worse than no match.
CREATE OR REPLACE FUNCTION bms.auto_match_statement(p_statement uuid, p_day_window int DEFAULT 3)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE st bms.bank_statements; ln record; v_txn uuid; v_count int := 0; v_hits int;
BEGIN
  PERFORM bms.assert_perm('bank','edit');
  SELECT * INTO st FROM bms.bank_statements WHERE id = p_statement;
  IF NOT FOUND THEN RAISE EXCEPTION 'Statement not found'; END IF;

  FOR ln IN SELECT * FROM bms.bank_statement_lines
             WHERE statement_id = p_statement AND match_status = 'UNMATCHED'
  LOOP
    SELECT COUNT(*), (array_agg(c.txn_id))[1] INTO v_hits, v_txn
      FROM (
        SELECT DISTINCT l.txn_id
          FROM bms.ledger_entries l
          JOIN bms.transactions t ON t.id = l.txn_id
         WHERE l.account_id = st.account_id
           AND t.status = 'POSTED'
           AND ABS(l.signed_amount - (ln.credit - ln.debit)) < 0.005
           AND l.entry_date BETWEEN ln.line_date - p_day_window AND ln.line_date + p_day_window
           AND NOT EXISTS (SELECT 1 FROM bms.bank_statement_lines x
                            WHERE x.matched_txn_id = l.txn_id AND x.id <> ln.id)
      ) c;

    IF v_hits = 1 THEN
      UPDATE bms.bank_statement_lines
         SET matched_txn_id = v_txn, match_status = 'AUTO_MATCHED'
       WHERE id = ln.id;
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END $$;

CREATE OR REPLACE FUNCTION bms.reconcile_account(
    p_statement uuid, p_notes text DEFAULT NULL)
RETURNS bms.reconciliations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE st bms.bank_statements; r bms.reconciliations; v_system numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('bank','edit');
  SELECT * INTO st FROM bms.bank_statements WHERE id = p_statement;
  IF NOT FOUND THEN RAISE EXCEPTION 'Statement not found'; END IF;

  SELECT COALESCE(a.opening_balance, 0) + COALESCE(SUM(l.signed_amount), 0)
    INTO v_system
    FROM bms.accounts a
    LEFT JOIN bms.ledger_entries l
           ON l.account_id = a.id AND l.entry_date <= st.statement_date
   WHERE a.id = st.account_id
   GROUP BY a.opening_balance;

  INSERT INTO bms.reconciliations(account_id, statement_id, as_of_date,
                                  system_balance, bank_balance, notes,
                                  status, reconciled_by)
  VALUES (st.account_id, p_statement, st.statement_date,
          COALESCE(v_system, 0), st.closing_balance, p_notes,
          CASE WHEN ABS(st.closing_balance - COALESCE(v_system,0)) < 0.005
               THEN 'AGREED' ELSE 'DISPUTED' END,
          auth.uid())
  RETURNING * INTO r;

  IF r.status = 'AGREED' THEN
    UPDATE bms.bank_statements SET status = 'RECONCILED' WHERE id = p_statement;
  END IF;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- NOTIFICATIONS
--
-- One generator, driven by the same alert view the dashboard uses, so a
-- new alert becomes a new notification with no extra code. Runs nightly
-- under pg_cron where that is available, and on demand otherwise.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.generate_notifications()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  al record; usr record; rule bms.notification_rules;
  v_key text; v_made int := 0; v_today text := to_char(CURRENT_DATE, 'YYYY-MM-DD');
BEGIN
  IF NOT bms.is_active_user() THEN
    RAISE EXCEPTION 'Not permitted' USING ERRCODE = '42501';
  END IF;

  FOR al IN SELECT * FROM bms.v_alerts_all LOOP
    SELECT * INTO rule FROM bms.notification_rules WHERE alert_type = al.alert_type;
    CONTINUE WHEN NOT FOUND OR NOT rule.is_enabled;

    FOR usr IN SELECT up.user_id FROM bms.user_profiles up WHERE up.is_active LOOP
      -- Only tell people who would be allowed to open the thing.
      CONTINUE WHEN NOT EXISTS (
        SELECT 1 FROM bms.user_roles ur
          JOIN bms.roles r ON r.id = ur.role_id
          LEFT JOIN bms.role_permissions rp ON rp.role_id = r.id
          LEFT JOIN bms.permissions p ON p.id = rp.permission_id
         WHERE ur.user_id = usr.user_id
           AND (r.is_superuser
                OR (p.module_code = rule.module_code AND p.action = rule.action)));

      v_key := al.alert_type || ':' || v_today;
      INSERT INTO bms.notifications(user_id, alert_type, title, body, severity, link, dedupe_key)
      VALUES (usr.user_id, al.alert_type, rule.title,
              format('%s item%s', al.item_count, CASE WHEN al.item_count = 1 THEN '' ELSE 's' END)
                || CASE WHEN al.amount IS NOT NULL THEN ' · ' || al.amount::text ELSE '' END,
              rule.severity, al.link, v_key)
      ON CONFLICT (user_id, dedupe_key) DO NOTHING;
      IF FOUND THEN v_made := v_made + 1; END IF;
    END LOOP;
  END LOOP;
  RETURN v_made;
END $$;

CREATE OR REPLACE FUNCTION bms.mark_notifications_read(p_ids uuid[] DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE bms.notifications
     SET is_read = true, read_at = now()
   WHERE user_id = auth.uid() AND NOT is_read
     AND (p_ids IS NULL OR id = ANY(p_ids));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- END 013_fund_functions.sql


-- =====================================================================
-- BEGIN 020_audit.sql
-- =====================================================================

-- =====================================================================
-- 020_audit.sql — one append-only log, written by a generic trigger so
-- no future developer has to remember to log anything.
-- =====================================================================

SET search_path = bms, public;

CREATE TABLE IF NOT EXISTS bms.audit_log (
  id                  bigserial PRIMARY KEY,
  occurred_at         timestamptz NOT NULL DEFAULT now(),
  actor_user_id       uuid,
  actor_name_snapshot text,          -- the name AS IT WAS at the time
  action              text NOT NULL,
  module_code         text,
  entity_table        text,
  entity_id           uuid,
  entity_label        text,          -- human string: "Flat A-103", "EXP-2026-0417"
  old_values          jsonb,
  new_values          jsonb,
  changed_fields      text[],
  severity            text NOT NULL DEFAULT 'NORMAL' CHECK (severity IN ('LOW','NORMAL','HIGH')),
  detail              text,
  user_agent          text
);
CREATE INDEX IF NOT EXISTS audit_time_idx   ON bms.audit_log(occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_entity_idx ON bms.audit_log(entity_table, entity_id);
CREATE INDEX IF NOT EXISTS audit_actor_idx  ON bms.audit_log(actor_user_id);
CREATE INDEX IF NOT EXISTS audit_sev_idx    ON bms.audit_log(severity) WHERE severity = 'HIGH';

-- Columns whose VALUES never enter the log. We record that they changed,
-- not what they changed to.
CREATE OR REPLACE FUNCTION bms.audit_mask(p_row jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(p_row, '{}'::jsonb)
         - 'account_number' - 'routing_number' - 'extra'
$$;

CREATE OR REPLACE FUNCTION bms.actor_name() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT COALESCE(
    (SELECT up.full_name FROM bms.user_profiles up WHERE up.user_id = auth.uid()),
    (SELECT u.email      FROM auth.users u        WHERE u.id = auth.uid()),
    'system')
$$;

-- TG_ARGV[0] = module code, TG_ARGV[1] = label column, TG_ARGV[2] = severity
CREATE OR REPLACE FUNCTION bms.audit_trigger() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  v_old jsonb; v_new jsonb; v_changed text[]; v_label text;
  v_module text := COALESCE(TG_ARGV[0], TG_TABLE_NAME);
  v_labelcol text := TG_ARGV[1];
  v_sev text := COALESCE(TG_ARGV[2], 'NORMAL');
  v_id uuid; v_action text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new := bms.audit_mask(to_jsonb(NEW)); v_action := 'INSERT';
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := bms.audit_mask(to_jsonb(OLD));
    v_new := bms.audit_mask(to_jsonb(NEW));
    SELECT array_agg(key ORDER BY key) INTO v_changed
      FROM jsonb_each(v_new) n
     WHERE key <> 'updated_at'
       AND n.value IS DISTINCT FROM (v_old -> n.key);
    IF v_changed IS NULL THEN RETURN NULL; END IF;   -- nothing meaningful changed
    v_action := 'UPDATE';
  ELSE
    v_old := bms.audit_mask(to_jsonb(OLD)); v_action := 'DELETE';
  END IF;

  BEGIN
    v_id := (COALESCE(v_new, v_old) ->> 'id')::uuid;
  EXCEPTION WHEN others THEN v_id := NULL; END;

  IF v_labelcol IS NOT NULL THEN
    v_label := COALESCE(v_new ->> v_labelcol, v_old ->> v_labelcol);
  END IF;

  -- A status change on a financial record is always worth flagging.
  IF v_changed IS NOT NULL AND 'status' = ANY(v_changed) THEN v_sev := 'HIGH'; END IF;

  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code,
                            entity_table, entity_id, entity_label,
                            old_values, new_values, changed_fields, severity)
  VALUES (auth.uid(), bms.actor_name(), v_action, v_module,
          TG_TABLE_NAME, v_id, v_label, v_old, v_new, v_changed, v_sev);
  RETURN NULL;
END $$;

-- Explicit events the database cannot see by itself (login, export, download).
CREATE OR REPLACE FUNCTION bms.log_event(
    p_action text, p_module text DEFAULT NULL, p_detail text DEFAULT NULL,
    p_entity_table text DEFAULT NULL, p_entity_id uuid DEFAULT NULL,
    p_entity_label text DEFAULT NULL, p_severity text DEFAULT 'NORMAL')
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF p_action NOT IN ('LOGIN','LOGOUT','LOGIN_FAILED','EXPORT','FILE_DOWNLOAD',
                      'FILE_UPLOAD','REPORT_VIEW','PERIOD_CLOSE','NOTE') THEN
    RAISE EXCEPTION 'Unsupported audit action %', p_action;
  END IF;
  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code,
                            entity_table, entity_id, entity_label, detail, severity)
  VALUES (auth.uid(), bms.actor_name(), p_action, p_module,
          p_entity_table, p_entity_id, p_entity_label, p_detail, p_severity);
END $$;

-- ---------------------------------------------------------------------
-- Attach the trigger to everything that matters.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t record;
  spec text[][] := ARRAY[
    ['transactions',    'finance',  'txn_no',      'HIGH'],
    ['ledger_entries',  'finance',  NULL,          'HIGH'],
    ['accounts',        'bank',     'name',        'HIGH'],
    ['account_secrets', 'bank',     NULL,          'HIGH'],
    ['accounting_periods','finance',NULL,          'HIGH'],
    ['payments',        'charges',  'receipt_no',  'HIGH'],
    ['payment_allocations','charges',NULL,         'NORMAL'],
    ['flat_charges',    'charges',  NULL,          'NORMAL'],
    ['charge_runs',     'charges',  NULL,          'HIGH'],
    ['adjustments',     'charges',  NULL,          'HIGH'],
    ['flats',           'flats',    'flat_number', 'NORMAL'],
    ['owners',          'flats',    'name',        'NORMAL'],
    ['flat_occupancy',  'flats',    NULL,          'NORMAL'],
    ['vendors',         'finance',  'name',        'LOW'],
    ['departments',     'settings', 'name',        'NORMAL'],
    ['categories',      'settings', 'name',        'LOW'],
    ['budgets',         'budget',   NULL,          'NORMAL'],
    ['budget_lines',    'budget',   NULL,          'LOW'],
    ['roles',           'users',    'name',        'HIGH'],
    ['role_permissions','users',    NULL,          'HIGH'],
    ['user_roles',      'users',    NULL,          'HIGH'],
    ['user_profiles',   'users',    'full_name',   'HIGH'],
    ['building_settings','settings',NULL,          'HIGH'],
    ['attachments',     'finance',  'file_name',   'NORMAL'],
    ['assets',          'maintenance','asset_code','NORMAL'],
    ['asset_service_logs','maintenance',NULL,      'NORMAL'],
    ['asset_inspections','fire',     NULL,          'NORMAL'],
    ['generator_runs',  'generator', NULL,          'LOW'   ],
    ['fuel_purchases',  'generator', 'invoice_no',  'NORMAL'],
    ['issues',          'maintenance','issue_no',   'NORMAL'],
    ['staff',           'staff',     'name',        'HIGH'  ],
    ['staff_attendance','staff',     NULL,          'LOW'   ],
    ['staff_advances',  'salary',    NULL,          'HIGH'  ],
    ['salary_runs',     'salary',    NULL,          'HIGH'  ],
    ['salary_payments', 'salary',    NULL,          'HIGH'  ],
    ['work_logs',       'work',      NULL,          'LOW'   ],
    ['funds',           'reserve',   'name',        'HIGH'  ],
    ['fund_movements',  'reserve',   NULL,          'HIGH'  ],
    ['fixed_deposits',  'reserve',   'fd_no',       'HIGH'  ],
    ['fd_events',       'reserve',   NULL,          'HIGH'  ],
    ['bank_statements', 'bank',      NULL,          'NORMAL'],
    ['reconciliations', 'bank',      NULL,          'HIGH'  ],
    ['notification_rules','settings',  'title',     'LOW'   ]
  ];
  i int;
BEGIN
  FOR i IN 1 .. array_length(spec, 1) LOOP
    IF to_regclass('bms.' || spec[i][1]) IS NOT NULL THEN
      EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_%1$s ON bms.%1$s', spec[i][1]);
      EXECUTE format(
        'CREATE TRIGGER trg_audit_%1$s AFTER INSERT OR UPDATE OR DELETE ON bms.%1$s
           FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger(%2$L, %3$s, %4$L)',
        spec[i][1], spec[i][2],
        CASE WHEN spec[i][3] IS NULL THEN 'NULL' ELSE quote_literal(spec[i][3]) END,
        spec[i][4]);
    END IF;
  END LOOP;
END $$;

-- The log is append-only for everyone, including admins.
CREATE OR REPLACE FUNCTION bms.block_audit_write() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'The audit log is append-only' USING ERRCODE = '42501';
END $$;
DROP TRIGGER IF EXISTS trg_audit_immutable ON bms.audit_log;
CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON bms.audit_log
  FOR EACH ROW EXECUTE FUNCTION bms.block_audit_write();

-- END 020_audit.sql


-- =====================================================================
-- BEGIN 030_rls.sql
-- =====================================================================

-- =====================================================================
-- 030_rls.sql — Row Level Security.
--
-- This file is the security boundary. The browser holds only the public
-- anon key; everything a signed-in user may do is decided here.
-- =====================================================================

SET search_path = bms, public;

-- The anon (signed-out) role gets nothing at all in this schema.
REVOKE ALL ON SCHEMA bms FROM PUBLIC;
GRANT  USAGE ON SCHEMA bms TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- Generated policies. Each row is: table, module, and which actions are
-- permitted at all. DELETE is granted nowhere on financial data.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  spec text[][] := ARRAY[
    -- table                 module      select add   edit  delete
    ['permissions',          'users',    'any',  'no',  'no',  'no' ],
    ['roles',                'users',    'any',  'add', 'edit','no' ],
    ['role_permissions',     'users',    'any',  'add', 'edit','yes'],
    ['user_roles',           'users',    'view', 'add', 'edit','yes'],
    ['departments',          'settings', 'any',  'add', 'edit','no' ],
    ['categories',           'settings', 'any',  'add', 'edit','no' ],
    ['vendors',              'finance',  'view', 'add', 'edit','no' ],
    ['accounts',             'bank',     'view', 'add', 'edit','no' ],
    ['accounting_periods',   'finance',  'view', 'no',  'no',  'no' ],
    ['transactions',         'finance',  'view', 'add', 'edit','no' ],
    ['ledger_entries',       'finance',  'view', 'no',  'no',  'no' ],
    ['attachments',          'finance',  'view', 'add', 'edit','no' ],
    ['budgets',              'budget',   'view', 'add', 'edit','no' ],
    ['budget_lines',         'budget',   'view', 'add', 'edit','yes'],
    ['flats',                'flats',    'view', 'add', 'edit','no' ],
    ['owners',               'flats',    'view', 'add', 'edit','no' ],
    ['flat_occupancy',       'flats',    'view', 'add', 'edit','no' ],
    ['flat_users',           'users',    'view', 'add', 'edit','yes'],
    ['charge_runs',          'charges',  'view', 'no',  'no',  'no' ],
    ['flat_charges',         'charges',  'view', 'no',  'edit','no' ],
    ['charge_line_items',    'charges',  'view', 'no',  'no',  'no' ],
    ['payments',             'charges',  'view', 'no',  'edit','no' ],
    ['payment_allocations',  'charges',  'view', 'no',  'no',  'no' ],
    ['adjustments',          'charges',  'view', 'no',  'no',  'no' ],
    ['doc_counters',         'finance',  'no',   'no',  'no',  'no' ],
    -- Phase 3
    ['generator_runs',       'generator','view', 'add', 'edit','no' ],
    ['fuel_purchases',       'generator','view', 'no',  'no',  'no' ],
    ['issues',               'maintenance','view','add', 'edit','no' ],
    ['issue_updates',        'maintenance','view','add', 'no',  'no' ],
    ['staff_positions',      'staff',    'any',  'add', 'edit','no' ],
    ['staff',                'staff',    'view', 'add', 'edit','no' ],
    ['staff_attendance',     'staff',    'view', 'add', 'edit','no' ],
    ['staff_leaves',         'staff',    'view', 'add', 'edit','no' ],
    ['staff_advances',       'salary',   'view', 'no',  'no',  'no' ],
    ['salary_runs',          'salary',   'view', 'no',  'no',  'no' ],
    ['salary_payments',      'salary',   'view', 'no',  'edit','no' ],
    ['work_checklist_templates','work',  'any',  'add', 'edit','no' ],
    ['work_checklist_items', 'work',     'any',  'add', 'edit','yes'],
    ['work_logs',            'work',     'view', 'no',  'no',  'no' ],
    ['work_log_items',       'work',     'view', 'no',  'no',  'no' ],
    -- Phase 4/5. Money-bearing rows are written only through the RPC
    -- functions, so INSERT/UPDATE are withheld from the client entirely.
    ['funds',                'reserve',  'view', 'add', 'edit','no' ],
    ['fund_movements',       'reserve',  'view', 'no',  'no',  'no' ],
    ['fixed_deposits',       'reserve',  'view', 'no',  'edit','no' ],
    ['fd_events',            'reserve',  'view', 'no',  'no',  'no' ],
    ['bank_statements',      'bank',     'view', 'no',  'no',  'no' ],
    ['bank_statement_lines', 'bank',     'view', 'no',  'edit','no' ],
    ['reconciliations',      'bank',     'view', 'no',  'no',  'no' ],
    ['notification_rules',   'settings', 'any',  'no',  'edit','no' ]
  ];
  i int; tbl text; m text;
BEGIN
  FOR i IN 1 .. array_length(spec,1) LOOP
    tbl := spec[i][1]; m := spec[i][2];
    CONTINUE WHEN to_regclass('bms.'||tbl) IS NULL;

    EXECUTE format('ALTER TABLE bms.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('REVOKE ALL ON bms.%I FROM PUBLIC, anon', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON bms.%I', tbl||'_sel', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON bms.%I', tbl||'_ins', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON bms.%I', tbl||'_upd', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON bms.%I', tbl||'_del', tbl);

    -- SELECT
    IF spec[i][3] = 'any' THEN
      EXECUTE format('GRANT SELECT ON bms.%I TO authenticated', tbl);
      EXECUTE format('CREATE POLICY %I ON bms.%I FOR SELECT TO authenticated USING (bms.is_active_user())', tbl||'_sel', tbl);
    ELSIF spec[i][3] = 'view' THEN
      EXECUTE format('GRANT SELECT ON bms.%I TO authenticated', tbl);
      EXECUTE format('CREATE POLICY %I ON bms.%I FOR SELECT TO authenticated USING (bms.has_perm(%L,''view''))', tbl||'_sel', tbl, m);
    END IF;

    -- INSERT
    IF spec[i][4] = 'add' THEN
      EXECUTE format('GRANT INSERT ON bms.%I TO authenticated', tbl);
      EXECUTE format('CREATE POLICY %I ON bms.%I FOR INSERT TO authenticated WITH CHECK (bms.has_perm(%L,''add''))', tbl||'_ins', tbl, m);
    END IF;

    -- UPDATE
    IF spec[i][5] = 'edit' THEN
      EXECUTE format('GRANT UPDATE ON bms.%I TO authenticated', tbl);
      EXECUTE format('CREATE POLICY %I ON bms.%I FOR UPDATE TO authenticated USING (bms.has_perm(%L,''edit'')) WITH CHECK (bms.has_perm(%L,''edit''))', tbl||'_upd', tbl, m, m);
    END IF;

    -- DELETE (only ever on join tables that carry no money)
    IF spec[i][6] = 'yes' THEN
      EXECUTE format('GRANT DELETE ON bms.%I TO authenticated', tbl);
      EXECUTE format('CREATE POLICY %I ON bms.%I FOR DELETE TO authenticated USING (bms.has_perm(%L,''edit''))', tbl||'_del', tbl, m);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- Hand-written policies for the tables that need more than the pattern.
-- ---------------------------------------------------------------------

-- TRANSACTIONS: a person can always read back what they themselves
-- entered, even without finance.view. Without this a caretaker could
-- submit an expense and then never see what happened to it.
DROP POLICY IF EXISTS transactions_sel_own ON bms.transactions;
CREATE POLICY transactions_sel_own ON bms.transactions FOR SELECT TO authenticated
  USING (created_by = auth.uid() AND bms.has_perm('finance','add'));

-- ASSETS: one table, but which module governs a row depends on what kind
-- of thing it is. A caretaker who may log a generator run must not be able
-- to retire a lift.
ALTER TABLE bms.assets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.assets FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON bms.assets TO authenticated;
DROP POLICY IF EXISTS assets_sel ON bms.assets;
DROP POLICY IF EXISTS assets_ins ON bms.assets;
DROP POLICY IF EXISTS assets_upd ON bms.assets;
CREATE POLICY assets_sel ON bms.assets FOR SELECT TO authenticated
  USING (bms.has_perm(bms.asset_module(asset_type), 'view'));
CREATE POLICY assets_ins ON bms.assets FOR INSERT TO authenticated
  WITH CHECK (bms.has_perm(bms.asset_module(asset_type), 'add'));
CREATE POLICY assets_upd ON bms.assets FOR UPDATE TO authenticated
  USING (bms.has_perm(bms.asset_module(asset_type), 'edit'))
  WITH CHECK (bms.has_perm(bms.asset_module(asset_type), 'edit'));

-- Everything hanging off an asset inherits the asset's own visibility.
DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['asset_service_logs','asset_inspections','asset_meter_readings'] LOOP
    EXECUTE format('ALTER TABLE bms.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('REVOKE ALL ON bms.%I FROM PUBLIC, anon', tbl);
    EXECUTE format('GRANT SELECT ON bms.%I TO authenticated', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON bms.%I', tbl||'_sel', tbl);
    EXECUTE format($f$CREATE POLICY %I ON bms.%I FOR SELECT TO authenticated
        USING (EXISTS (SELECT 1 FROM bms.assets a WHERE a.id = asset_id
                        AND bms.has_perm(bms.asset_module(a.asset_type), 'view')))$f$,
      tbl||'_sel', tbl);
  END LOOP;
END $$;

-- Parts belong to a service log, which belongs to an asset.
ALTER TABLE bms.asset_parts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.asset_parts FROM PUBLIC, anon;
GRANT SELECT ON bms.asset_parts TO authenticated;
DROP POLICY IF EXISTS asset_parts_sel ON bms.asset_parts;
CREATE POLICY asset_parts_sel ON bms.asset_parts FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM bms.asset_service_logs l
                   JOIN bms.assets a ON a.id = l.asset_id
                  WHERE l.id = service_log_id
                    AND bms.has_perm(bms.asset_module(a.asset_type), 'view')));

-- MODULES: every active user reads the registry so the nav can render.
ALTER TABLE bms.modules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.modules FROM PUBLIC, anon;
GRANT SELECT ON bms.modules TO authenticated;
GRANT INSERT, UPDATE ON bms.modules TO authenticated;
DROP POLICY IF EXISTS modules_sel ON bms.modules;
DROP POLICY IF EXISTS modules_wri ON bms.modules;
CREATE POLICY modules_sel ON bms.modules FOR SELECT TO authenticated USING (bms.is_active_user());
CREATE POLICY modules_wri ON bms.modules FOR ALL TO authenticated
  USING (bms.has_perm('settings','edit')) WITH CHECK (bms.has_perm('settings','edit'));

-- USER PROFILES: a person can always see and name themselves. Only an
-- admin can activate an account or change anyone else's row.
ALTER TABLE bms.user_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.user_profiles FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON bms.user_profiles TO authenticated;
DROP POLICY IF EXISTS up_sel_self  ON bms.user_profiles;
DROP POLICY IF EXISTS up_sel_admin ON bms.user_profiles;
DROP POLICY IF EXISTS up_ins_self  ON bms.user_profiles;
DROP POLICY IF EXISTS up_upd_self  ON bms.user_profiles;
DROP POLICY IF EXISTS up_upd_admin ON bms.user_profiles;
CREATE POLICY up_sel_self  ON bms.user_profiles FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY up_sel_admin ON bms.user_profiles FOR SELECT TO authenticated USING (bms.has_perm('users','view'));
-- First sign-in creates the row; is_active must be false and stays false
-- until an administrator turns it on.
CREATE POLICY up_ins_self  ON bms.user_profiles FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND is_active = false AND approval_limit IS NULL);
CREATE POLICY up_upd_self  ON bms.user_profiles FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY up_upd_admin ON bms.user_profiles FOR UPDATE TO authenticated
  USING (bms.has_perm('users','edit')) WITH CHECK (bms.has_perm('users','edit'));

-- A policy cannot read its own table without recursing, so the "you may
-- edit your own name but not your own access" rule lives in a trigger.
--
-- The auth.uid() IS NULL branch is what makes the very first account
-- possible. This guard exists to stop a SIGNED-IN person raising their
-- own access level. When there is no signed-in person there is no "own"
-- to protect: that is the SQL Editor, a migration, or a scheduled job,
-- all of which are already running as the database owner and could drop
-- this trigger outright. Without the branch, BOOTSTRAP_ADMIN.sql fails
-- the moment the profile row already exists — which is exactly what
-- happens when someone follows the documented order and signs up in the
-- app first, so the first administrator can never be activated.
--
-- A browser client always carries a JWT, so auth.uid() is never NULL on
-- the path this guard is defending.
CREATE OR REPLACE FUNCTION bms.guard_user_profile() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;                       -- server-side, not a user editing themselves
  END IF;

  IF (NEW.is_active      IS DISTINCT FROM OLD.is_active
   OR NEW.approval_limit IS DISTINCT FROM OLD.approval_limit)
     AND NOT bms.has_perm('users','edit') THEN
    RAISE EXCEPTION 'You cannot change your own access level' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_user_profile_guard ON bms.user_profiles;
CREATE TRIGGER trg_user_profile_guard BEFORE UPDATE ON bms.user_profiles
  FOR EACH ROW EXECUTE FUNCTION bms.guard_user_profile();

-- BUILDING SETTINGS: everyone reads (currency, building name, due day);
-- only settings.edit writes.
ALTER TABLE bms.building_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.building_settings FROM PUBLIC, anon;
GRANT SELECT, UPDATE ON bms.building_settings TO authenticated;
DROP POLICY IF EXISTS bs_sel ON bms.building_settings;
DROP POLICY IF EXISTS bs_upd ON bms.building_settings;
CREATE POLICY bs_sel ON bms.building_settings FOR SELECT TO authenticated USING (bms.is_active_user());
CREATE POLICY bs_upd ON bms.building_settings FOR UPDATE TO authenticated
  USING (bms.has_perm('settings','edit')) WITH CHECK (bms.has_perm('settings','edit'));

-- ACCOUNT SECRETS: the account number needs its own permission.
ALTER TABLE bms.account_secrets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.account_secrets FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON bms.account_secrets TO authenticated;
DROP POLICY IF EXISTS as_sel ON bms.account_secrets;
DROP POLICY IF EXISTS as_wri ON bms.account_secrets;
CREATE POLICY as_sel ON bms.account_secrets FOR SELECT TO authenticated
  USING (bms.has_perm('bank','view_sensitive'));
CREATE POLICY as_wri ON bms.account_secrets FOR ALL TO authenticated
  USING (bms.has_perm('bank','view_sensitive') AND bms.has_perm('bank','edit'))
  WITH CHECK (bms.has_perm('bank','view_sensitive') AND bms.has_perm('bank','edit'));

-- AUDIT LOG: readable with audit.view, never writable from a client.
ALTER TABLE bms.audit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.audit_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.audit_log TO authenticated;
DROP POLICY IF EXISTS audit_sel ON bms.audit_log;
CREATE POLICY audit_sel ON bms.audit_log FOR SELECT TO authenticated
  USING (bms.has_perm('audit','view'));

-- NOTIFICATIONS: strictly personal. You read your own and mark your own
-- read (through mark_notifications_read); nobody reads anybody else's,
-- not even an administrator, because the row set is derived from data
-- they can already see and the inbox itself is private.
ALTER TABLE bms.notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.notifications FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.notifications TO authenticated;
DROP POLICY IF EXISTS notif_sel ON bms.notifications;
CREATE POLICY notif_sel ON bms.notifications FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- The counter table is written only by next_doc_no() (SECURITY DEFINER).
ALTER TABLE bms.doc_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.doc_counters FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Function grants. Everything is revoked from PUBLIC first, then handed
-- to signed-in users explicitly.
-- ---------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'bms'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
  END LOOP;
END $$;

-- Trigger functions and internal helpers are not callable directly.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'bms.txn_guard()','bms.block_delete()','bms.block_ledger_update()',
    'bms.block_audit_write()','bms.audit_trigger()','bms.set_updated_at()',
    'bms.categories_guard()','bms.guard_allocation()',
    'bms.recalc_flat_charge_adjustments()','bms.guard_user_profile()',
    'bms.guard_asset_update()',
    'bms.next_doc_no(text,int,text)'
  ] LOOP
    IF to_regprocedure(f) IS NOT NULL THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f);
    END IF;
  END LOOP;
END $$;

-- Sequences used by tables that authenticated may insert into.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA bms TO authenticated;

-- END 030_rls.sql


-- =====================================================================
-- BEGIN 040_views.sql
-- =====================================================================

-- =====================================================================
-- 040_views.sql — the reporting layer.
--
-- Every view is security_invoker, so Row Level Security applies to the
-- caller exactly as it does on the underlying tables. There is no
-- back door here.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- ACCOUNT BALANCES — opening balance plus the ledger, and nothing else.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_account_balances WITH (security_invoker = true) AS
SELECT a.id           AS account_id,
       a.code, a.name, a.kind, a.bank_name, a.is_active,
       a.opening_balance,
       COALESCE(l.movement, 0)::numeric(14,2)                     AS movement,
       (a.opening_balance + COALESCE(l.movement, 0))::numeric(14,2) AS current_balance,
       l.last_entry_date
  FROM bms.accounts a
  LEFT JOIN (
        SELECT account_id,
               SUM(signed_amount)::numeric(14,2) AS movement,
               MAX(entry_date)                   AS last_entry_date
          FROM bms.ledger_entries GROUP BY account_id
       ) l ON l.account_id = a.id;

-- ---------------------------------------------------------------------
-- FLAT CHARGES with payment status DERIVED, never stored.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_flat_charges WITH (security_invoker = true) AS
SELECT fc.id, fc.flat_id, f.flat_number, f.floor,
       fc.period_year, fc.period_month,
       make_date(fc.period_year, fc.period_month, 1) AS period_start,
       fc.charge_source, fc.charge_amount, fc.adjustment_amount, fc.waiver_amount,
       fc.net_payable, fc.due_date, fc.is_cancelled, fc.run_id,
       COALESCE(p.paid, 0)::numeric(14,2)                            AS paid_amount,
       (fc.net_payable - COALESCE(p.paid, 0))::numeric(14,2)         AS due_amount,
       CASE
         WHEN fc.is_cancelled                              THEN 'CANCELLED'
         WHEN fc.net_payable <= 0 AND fc.waiver_amount > 0 THEN 'WAIVED'
         WHEN COALESCE(p.paid,0) >= fc.net_payable         THEN 'PAID'
         WHEN COALESCE(p.paid,0) > 0                       THEN 'PARTIAL'
         WHEN fc.due_date < CURRENT_DATE                   THEN 'OVERDUE'
         ELSE 'UNPAID'
       END AS status,
       GREATEST(0, CURRENT_DATE - fc.due_date) AS days_overdue
  FROM bms.flat_charges fc
  JOIN bms.flats f ON f.id = fc.flat_id
  LEFT JOIN (
        SELECT flat_charge_id, SUM(amount)::numeric(14,2) AS paid
          FROM bms.payment_allocations GROUP BY flat_charge_id
       ) p ON p.flat_charge_id = fc.id;

-- ---------------------------------------------------------------------
-- ONE ROW PER FLAT — outstanding, advance, and where it stands.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_flat_dues WITH (security_invoker = true) AS
WITH charged AS (
  SELECT flat_id, SUM(net_payable)::numeric(14,2) AS charged
    FROM bms.flat_charges WHERE NOT is_cancelled GROUP BY flat_id
), allocated AS (
  SELECT fc.flat_id, SUM(pa.amount)::numeric(14,2) AS allocated
    FROM bms.payment_allocations pa
    JOIN bms.flat_charges fc ON fc.id = pa.flat_charge_id
   GROUP BY fc.flat_id
), paid AS (
  SELECT flat_id, SUM(amount)::numeric(14,2) AS received,
         MAX(payment_date) AS last_payment_date
    FROM bms.payments WHERE status = 'ACTIVE' GROUP BY flat_id
)
SELECT f.id AS flat_id, f.flat_number, f.floor, f.status AS flat_status,
       f.service_charge,
       COALESCE(c.charged, 0)   AS total_charged,
       COALESCE(a.allocated, 0) AS total_allocated,
       COALESCE(p.received, 0)  AS total_received,
       GREATEST(COALESCE(c.charged,0) - COALESCE(a.allocated,0), 0)::numeric(14,2) AS outstanding,
       GREATEST(COALESCE(p.received,0) - COALESCE(a.allocated,0), 0)::numeric(14,2) AS advance,
       p.last_payment_date,
       (SELECT o.name FROM bms.flat_occupancy fo JOIN bms.owners o ON o.id = fo.owner_id
         WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) AS billed_to,
       (SELECT o.mobile FROM bms.flat_occupancy fo JOIN bms.owners o ON o.id = fo.owner_id
         WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) AS billed_mobile
  FROM bms.flats f
  LEFT JOIN charged   c ON c.flat_id = f.id
  LEFT JOIN allocated a ON a.flat_id = f.id
  LEFT JOIN paid      p ON p.flat_id = f.id;

-- ---------------------------------------------------------------------
-- MONTHLY COLLECTION — charged vs settled, per month.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_monthly_collection WITH (security_invoker = true) AS
SELECT fc.period_year, fc.period_month,
       COUNT(*)                                                  AS charge_count,
       SUM(fc.net_payable)::numeric(14,2)                        AS charged,
       COALESCE(SUM(pa.paid), 0)::numeric(14,2)                  AS collected,
       (SUM(fc.net_payable) - COALESCE(SUM(pa.paid),0))::numeric(14,2) AS outstanding,
       CASE WHEN SUM(fc.net_payable) > 0
            THEN ROUND(COALESCE(SUM(pa.paid),0) * 100.0 / SUM(fc.net_payable), 1)
            ELSE 0 END                                           AS collection_pct,
       COUNT(*) FILTER (WHERE COALESCE(pa.paid,0) >= fc.net_payable) AS flats_paid,
       COUNT(*) FILTER (WHERE COALESCE(pa.paid,0) > 0
                          AND COALESCE(pa.paid,0) < fc.net_payable) AS flats_partial,
       COUNT(*) FILTER (WHERE COALESCE(pa.paid,0) = 0)               AS flats_unpaid
  FROM bms.flat_charges fc
  LEFT JOIN (SELECT flat_charge_id, SUM(amount) AS paid
               FROM bms.payment_allocations GROUP BY flat_charge_id) pa
         ON pa.flat_charge_id = fc.id
 WHERE NOT fc.is_cancelled
 GROUP BY fc.period_year, fc.period_month;

-- ---------------------------------------------------------------------
-- INCOME AND EXPENSE.
--
-- Three things are deliberately excluded:
--   * transfers between our own accounts — they are not income or expense;
--   * a transaction that has been reversed;
--   * the reversal that cancelled it.
--
-- The pair nets to zero either way, so the NET figure is the same. But
-- leaving them in inflates both totals: a bounced Tk 5,000 cheque would
-- add 5,000 to "money in" AND 5,000 to "money out" for the month, and a
-- committee reading "we collected Tk 21,500" when Tk 5,000 of it bounced
-- is being told something untrue. Both entries stay fully visible in the
-- ledger and the audit log; they are just not counted twice here.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_real_transactions WITH (security_invoker = true) AS
SELECT * FROM bms.transactions t
 WHERE t.status = 'POSTED'
   AND t.direction <> 'TRANSFER'
   AND NOT t.is_reversal
   AND t.reversed_by_txn_id IS NULL;

CREATE OR REPLACE VIEW bms.v_income_expense_monthly WITH (security_invoker = true) AS
SELECT EXTRACT(YEAR  FROM t.txn_date)::int AS period_year,
       EXTRACT(MONTH FROM t.txn_date)::int AS period_month,
       COALESCE(SUM(t.amount) FILTER (WHERE t.direction = 'INCOME'),0)::numeric(14,2)  AS income,
       COALESCE(SUM(t.amount) FILTER (WHERE t.direction = 'EXPENSE'),0)::numeric(14,2) AS expense,
       (COALESCE(SUM(t.amount) FILTER (WHERE t.direction = 'INCOME'),0)
      - COALESCE(SUM(t.amount) FILTER (WHERE t.direction = 'EXPENSE'),0))::numeric(14,2) AS net
  FROM bms.v_real_transactions t
 GROUP BY 1, 2;

CREATE OR REPLACE VIEW bms.v_department_spend WITH (security_invoker = true) AS
SELECT d.id AS department_id, d.code, d.name,
       EXTRACT(YEAR  FROM t.txn_date)::int AS period_year,
       EXTRACT(MONTH FROM t.txn_date)::int AS period_month,
       COALESCE(SUM(t.amount) FILTER (WHERE t.direction = 'EXPENSE'),0)::numeric(14,2) AS expense,
       COALESCE(SUM(t.amount) FILTER (WHERE t.direction = 'INCOME'),0)::numeric(14,2)  AS income
  FROM bms.v_real_transactions t
  JOIN bms.departments d ON d.id = t.department_id
 GROUP BY 1,2,3,4,5;

-- ---------------------------------------------------------------------
-- TRANSACTIONS, joined up for the ledger screen and exports.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_transactions WITH (security_invoker = true) AS
SELECT t.id, t.txn_no, t.txn_date, t.direction, t.description, t.amount,
       t.payment_method, t.reference_no, t.status, t.notes,
       t.is_reversal, t.reversal_of_txn_id, t.reversed_by_txn_id, t.reversal_reason,
       t.source_module, t.source_ref, t.created_at, t.approved_at, t.posted_at,
       -- One definition of "this is real money that stayed", used by every
       -- report and by the ledger screen's totals.
       (t.status = 'POSTED' AND t.direction <> 'TRANSFER'
        AND NOT t.is_reversal AND t.reversed_by_txn_id IS NULL) AS counts_in_totals,
       d.name  AS department_name, d.code AS department_code, t.department_id,
       c.name  AS category_name,   t.category_id,
       pc.name AS parent_category_name,
       a.name  AS account_name,    t.account_id,
       ca.name AS counter_account_name, t.counter_account_id,
       v.name  AS vendor_name,     t.vendor_id,
       f.flat_number,              t.flat_id,
       cu.full_name AS created_by_name, t.created_by,
       au.full_name AS approved_by_name, t.approved_by
  FROM bms.transactions t
  LEFT JOIN bms.departments   d  ON d.id  = t.department_id
  LEFT JOIN bms.categories    c  ON c.id  = t.category_id
  LEFT JOIN bms.categories    pc ON pc.id = c.parent_id
  LEFT JOIN bms.accounts      a  ON a.id  = t.account_id
  LEFT JOIN bms.accounts      ca ON ca.id = t.counter_account_id
  LEFT JOIN bms.vendors       v  ON v.id  = t.vendor_id
  LEFT JOIN bms.flats         f  ON f.id  = t.flat_id
  LEFT JOIN bms.user_profiles cu ON cu.user_id = t.created_by
  LEFT JOIN bms.user_profiles au ON au.user_id = t.approved_by;

-- ---------------------------------------------------------------------
-- FLAT STATEMENT — every charge and payment for a flat, in date order.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_flat_ledger WITH (security_invoker = true) AS
SELECT fc.flat_id,
       make_date(fc.period_year, fc.period_month, 1) AS entry_date,
       'CHARGE'                                      AS entry_type,
       CASE fc.charge_source WHEN 'OPENING' THEN 'Balance brought forward'
            ELSE to_char(make_date(fc.period_year, fc.period_month, 1), 'Mon YYYY')
                 || ' service charge' END            AS description,
       fc.net_payable                                AS debit,
       0::numeric(14,2)                              AS credit,
       fc.id                                         AS ref_id,
       NULL::text                                    AS ref_no
  FROM bms.flat_charges fc WHERE NOT fc.is_cancelled
UNION ALL
SELECT p.flat_id, p.payment_date, 'PAYMENT',
       'Payment received (' || p.method || ')',
       0::numeric(14,2), p.amount, p.id, p.receipt_no
  FROM bms.payments p WHERE p.status = 'ACTIVE';

-- ---------------------------------------------------------------------
-- BUDGET VS ACTUAL — pro-rated to date, so December is not a surprise.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_budget_vs_actual WITH (security_invoker = true) AS
SELECT b.id AS budget_id, b.fiscal_year, b.department_id,
       d.code AS department_code, d.name AS department_name,
       b.category_id, c.name AS category_name, b.annual_amount,
       COALESCE(bl.budget_to_date, 0)::numeric(14,2) AS budget_to_date,
       COALESCE(act.actual, 0)::numeric(14,2)        AS actual,
       (b.annual_amount - COALESCE(act.actual,0))::numeric(14,2) AS remaining,
       CASE WHEN COALESCE(bl.budget_to_date,0) > 0
            THEN ROUND((COALESCE(act.actual,0) - bl.budget_to_date) * 100.0 / bl.budget_to_date, 1)
            ELSE NULL END AS variance_pct_to_date,
       (COALESCE(act.actual,0) > COALESCE(bl.budget_to_date,0)) AS over_budget_to_date
  FROM bms.budgets b
  JOIN bms.departments d ON d.id = b.department_id
  LEFT JOIN bms.categories c ON c.id = b.category_id
  LEFT JOIN (
        SELECT budget_id, SUM(amount) AS budget_to_date
          FROM bms.budget_lines
         WHERE period_month <= EXTRACT(MONTH FROM CURRENT_DATE)::int
         GROUP BY budget_id
       ) bl ON bl.budget_id = b.id
  LEFT JOIN LATERAL (
        SELECT SUM(t.amount) AS actual
          FROM bms.v_real_transactions t
         WHERE t.direction = 'EXPENSE'
           AND t.department_id = b.department_id
           AND (b.category_id IS NULL OR t.category_id = b.category_id)
           AND EXTRACT(YEAR FROM t.txn_date)::int = b.fiscal_year
       ) act ON true;

-- ---------------------------------------------------------------------
-- DASHBOARD ALERTS — one UNION, each row carrying its own severity and
-- a link target. New alert types are added here and nowhere else.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_dashboard_alerts WITH (security_invoker = true) AS
SELECT 'PENDING_APPROVAL'::text AS alert_type,
       'HIGH'::text             AS severity,
       COUNT(*)::int            AS item_count,
       SUM(amount)::numeric(14,2) AS amount,
       'Expense approvals waiting'::text AS title,
       '#/finance/approvals'::text      AS link
  FROM bms.transactions WHERE status = 'PENDING_APPROVAL'
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'SERVICE_CHARGE_OVERDUE', 'HIGH', COUNT(*)::int, SUM(due_amount)::numeric(14,2),
       'Flats with overdue service charge', '#/charges/outstanding'
  FROM bms.v_flat_charges WHERE status = 'OVERDUE'
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'PENDING_WAIVER', 'NORMAL', COUNT(*)::int, SUM(amount)::numeric(14,2),
       'Waivers waiting for approval', '#/charges/adjustments'
  FROM bms.adjustments WHERE status = 'PENDING'
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'RETURNED_TO_ME', 'NORMAL', COUNT(*)::int, SUM(amount)::numeric(14,2),
       'Your entries returned for correction', '#/finance'
  FROM bms.transactions WHERE status = 'RETURNED' AND created_by = auth.uid()
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'UNPOSTED_DRAFTS', 'LOW', COUNT(*)::int, SUM(amount)::numeric(14,2),
       'Draft entries not yet submitted', '#/finance'
  FROM bms.transactions WHERE status = 'DRAFT' AND created_by = auth.uid()
 HAVING COUNT(*) > 0;

-- ---------------------------------------------------------------------
-- AUDIT LOG, rendered.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_audit_log WITH (security_invoker = true) AS
SELECT al.id, al.occurred_at, al.actor_name_snapshot, al.action, al.module_code,
       al.entity_table, al.entity_id, al.entity_label, al.severity, al.detail,
       al.changed_fields,
       (SELECT string_agg(
                  cf || ': ' ||
                  COALESCE(al.old_values ->> cf, '(none)') || ' -> ' ||
                  COALESCE(al.new_values ->> cf, '(none)'), '; ')
          FROM unnest(COALESCE(al.changed_fields, ARRAY[]::text[])) AS cf
         WHERE cf NOT IN ('id','created_at','updated_at','period_id')) AS change_summary
  FROM bms.audit_log al;

GRANT SELECT ON ALL TABLES IN SCHEMA bms TO authenticated;
REVOKE SELECT ON bms.doc_counters FROM authenticated;

-- END 040_views.sql


-- =====================================================================
-- BEGIN 041_operations_views.sql
-- =====================================================================

-- =====================================================================
-- 041_operations_views.sql — the Phase 3 reporting layer.
--
-- Green / amber / red is COMPUTED from the next due date against the
-- warning window in settings. It is never stored, so it can never be
-- stale, and changing the warning window changes every screen at once.
-- =====================================================================

SET search_path = bms, public;

CREATE OR REPLACE VIEW bms.v_assets WITH (security_invoker = true) AS
SELECT a.id, a.asset_code, a.asset_type, a.name, a.location, a.floor,
       a.manufacturer, a.model, a.capacity, a.serial_no,
       a.installation_date, a.warranty_expiry,
       a.last_service_date, a.next_service_date,
       a.last_inspection_date, a.next_inspection_date,
       a.condition, a.status, a.purchase_cost, a.specs, a.notes,
       a.department_id, a.service_provider_id, a.service_interval_days,
       d.name AS department_name,
       v.name AS service_provider,
       bms.asset_module(a.asset_type) AS module_code,

       -- Service: RED once overdue, AMBER inside the warning window.
       CASE WHEN a.status = 'RETIRED'          THEN 'RETIRED'
            WHEN a.next_service_date IS NULL   THEN 'UNKNOWN'
            WHEN a.next_service_date < CURRENT_DATE THEN 'OVERDUE'
            WHEN a.next_service_date <= CURRENT_DATE + s.service_warn_days THEN 'DUE_SOON'
            ELSE 'OK' END AS service_status,
       (a.next_service_date - CURRENT_DATE) AS service_days_left,

       -- Inspection: the same shape, on its own window.
       CASE WHEN a.status = 'RETIRED'            THEN 'RETIRED'
            WHEN a.next_inspection_date IS NULL  THEN 'UNKNOWN'
            WHEN a.next_inspection_date < CURRENT_DATE THEN 'OVERDUE'
            WHEN a.next_inspection_date <= CURRENT_DATE + s.inspection_warn_days THEN 'DUE_SOON'
            ELSE 'OK' END AS inspection_status,
       (a.next_inspection_date - CURRENT_DATE) AS inspection_days_left,

       (a.warranty_expiry IS NOT NULL AND a.warranty_expiry >= CURRENT_DATE) AS under_warranty,
       (SELECT COUNT(*) FROM bms.issues i
         WHERE i.asset_id = a.id AND i.status NOT IN ('VERIFIED','CANCELLED')) AS open_issues,
       (SELECT COALESCE(SUM(l.cost),0) FROM bms.asset_service_logs l
         WHERE l.asset_id = a.id
           AND EXTRACT(YEAR FROM l.service_date)::int = EXTRACT(YEAR FROM CURRENT_DATE)::int
       )::numeric(14,2) AS service_cost_ytd
  FROM bms.assets a
  CROSS JOIN bms.building_settings s
  LEFT JOIN bms.departments d ON d.id = a.department_id
  LEFT JOIN bms.vendors     v ON v.id = a.service_provider_id;

-- ---------------------------------------------------------------------
-- GENERATOR — hours run, fuel bought, what it all cost.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_generator_monthly WITH (security_invoker = true) AS
WITH runs AS (
  SELECT asset_id,
         EXTRACT(YEAR  FROM gen_start)::int AS period_year,
         EXTRACT(MONTH FROM gen_start)::int AS period_month,
         COUNT(*)                                   AS run_count,
         COALESCE(SUM(duration_minutes),0)          AS minutes_run,
         ROUND(COALESCE(SUM(duration_minutes),0) / 60.0, 2) AS hours_run
    FROM bms.generator_runs
   GROUP BY 1,2,3
), fuel AS (
  SELECT asset_id,
         EXTRACT(YEAR  FROM purchase_date)::int AS period_year,
         EXTRACT(MONTH FROM purchase_date)::int AS period_month,
         COALESCE(SUM(quantity) FILTER (WHERE fuel_type = 'DIESEL'),0)::numeric(12,2) AS diesel_litres,
         COALESCE(SUM(total_amount),0)::numeric(14,2) AS fuel_cost
    FROM bms.fuel_purchases GROUP BY 1,2,3
), svc AS (
  SELECT asset_id,
         EXTRACT(YEAR  FROM service_date)::int AS period_year,
         EXTRACT(MONTH FROM service_date)::int AS period_month,
         COALESCE(SUM(cost),0)::numeric(14,2) AS service_cost
    FROM bms.asset_service_logs GROUP BY 1,2,3
)
SELECT a.id AS asset_id, a.name AS asset_name,
       COALESCE(r.period_year, f.period_year, s.period_year)   AS period_year,
       COALESCE(r.period_month, f.period_month, s.period_month) AS period_month,
       COALESCE(r.run_count, 0)      AS run_count,
       COALESCE(r.hours_run, 0)      AS hours_run,
       COALESCE(f.diesel_litres, 0)  AS diesel_litres,
       COALESCE(f.fuel_cost, 0)      AS fuel_cost,
       COALESCE(s.service_cost, 0)   AS service_cost,
       (COALESCE(f.fuel_cost,0) + COALESCE(s.service_cost,0))::numeric(14,2) AS total_cost,
       CASE WHEN COALESCE(r.hours_run,0) > 0
            THEN ROUND(COALESCE(f.diesel_litres,0) / r.hours_run, 2) END AS litres_per_hour,
       CASE WHEN COALESCE(r.hours_run,0) > 0
            THEN ROUND((COALESCE(f.fuel_cost,0) + COALESCE(s.service_cost,0)) / r.hours_run, 2) END AS cost_per_hour
  FROM bms.assets a
  LEFT JOIN runs r ON r.asset_id = a.id
  LEFT JOIN fuel f ON f.asset_id = a.id
                  AND f.period_year = r.period_year AND f.period_month = r.period_month
  LEFT JOIN svc  s ON s.asset_id = a.id
                  AND s.period_year = COALESCE(r.period_year, f.period_year)
                  AND s.period_month = COALESCE(r.period_month, f.period_month)
 WHERE a.asset_type = 'GENERATOR'
   AND COALESCE(r.period_year, f.period_year, s.period_year) IS NOT NULL;

-- ---------------------------------------------------------------------
-- MAINTENANCE
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_issues WITH (security_invoker = true) AS
SELECT i.id, i.issue_no, i.title, i.description, i.priority, i.status,
       i.location, i.floor, i.reported_at, i.due_at, i.assigned_at,
       i.completed_at, i.verified_at, i.estimated_cost, i.actual_cost,
       i.resolution, i.cancel_reason, i.txn_id, i.asset_id, i.flat_id,
       i.department_id, i.assigned_staff_id, i.assigned_vendor_id,
       d.name  AS department_name,
       a.name  AS asset_name,
       a.asset_type,
       f.flat_number,
       st.name AS assigned_staff,
       v.name  AS assigned_vendor,
       rp.full_name AS reported_by_name,
       vp.full_name AS verified_by_name,
       (i.status NOT IN ('COMPLETED','VERIFIED','CANCELLED')
        AND i.due_at IS NOT NULL AND i.due_at < now()) AS is_overdue,
       CASE WHEN i.completed_at IS NOT NULL
            THEN ROUND(EXTRACT(EPOCH FROM (i.completed_at - i.reported_at)) / 3600.0, 1)
       END AS hours_to_complete
  FROM bms.issues i
  LEFT JOIN bms.departments   d  ON d.id  = i.department_id
  LEFT JOIN bms.assets        a  ON a.id  = i.asset_id
  LEFT JOIN bms.flats         f  ON f.id  = i.flat_id
  LEFT JOIN bms.staff         st ON st.id = i.assigned_staff_id
  LEFT JOIN bms.vendors       v  ON v.id  = i.assigned_vendor_id
  LEFT JOIN bms.user_profiles rp ON rp.user_id = i.reported_by
  LEFT JOIN bms.user_profiles vp ON vp.user_id = i.verified_by;

-- ---------------------------------------------------------------------
-- STAFF
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_staff WITH (security_invoker = true) AS
SELECT s.id, s.staff_code, s.name, s.mobile, s.address, s.emergency_contact,
       s.joining_date, s.leaving_date, s.salary, s.shift, s.status,
       s.photo_path, s.notes, s.position_id,
       p.name AS position_name, p.department_id,
       d.name AS department_name,
       (SELECT COUNT(*) FROM bms.staff_attendance a
         WHERE a.staff_id = s.id AND a.status = 'PRESENT'
           AND EXTRACT(YEAR FROM a.work_date)::int = EXTRACT(YEAR FROM CURRENT_DATE)::int
           AND EXTRACT(MONTH FROM a.work_date)::int = EXTRACT(MONTH FROM CURRENT_DATE)::int) AS present_this_month,
       (SELECT COUNT(*) FROM bms.staff_attendance a
         WHERE a.staff_id = s.id AND a.status = 'ABSENT'
           AND EXTRACT(YEAR FROM a.work_date)::int = EXTRACT(YEAR FROM CURRENT_DATE)::int
           AND EXTRACT(MONTH FROM a.work_date)::int = EXTRACT(MONTH FROM CURRENT_DATE)::int) AS absent_this_month,
       (SELECT a.status FROM bms.staff_attendance a
         WHERE a.staff_id = s.id AND a.work_date = CURRENT_DATE) AS today_status,
       (SELECT COALESCE(SUM(amount - recovered_amount),0) FROM bms.staff_advances adv
         WHERE adv.staff_id = s.id)::numeric(14,2) AS advance_outstanding
  FROM bms.staff s
  JOIN bms.staff_positions p ON p.id = s.position_id
  LEFT JOIN bms.departments d ON d.id = p.department_id;

CREATE OR REPLACE VIEW bms.v_attendance_monthly WITH (security_invoker = true) AS
SELECT a.staff_id, s.name AS staff_name,
       EXTRACT(YEAR  FROM a.work_date)::int AS period_year,
       EXTRACT(MONTH FROM a.work_date)::int AS period_month,
       COUNT(*) FILTER (WHERE a.status = 'PRESENT')   AS present_days,
       COUNT(*) FILTER (WHERE a.status = 'ABSENT')    AS absent_days,
       COUNT(*) FILTER (WHERE a.status = 'LEAVE')     AS leave_days,
       COUNT(*) FILTER (WHERE a.status = 'HALF_DAY')  AS half_days,
       COUNT(*)                                        AS marked_days
  FROM bms.staff_attendance a
  JOIN bms.staff s ON s.id = a.staff_id
 GROUP BY 1,2,3,4;

CREATE OR REPLACE VIEW bms.v_salary_payments WITH (security_invoker = true) AS
SELECT sp.id, sp.run_id, sp.staff_id, sp.base_salary, sp.bonus, sp.deduction,
       sp.advance_recovery, sp.net_payable, sp.absent_days, sp.paid_date,
       sp.status, sp.txn_id, sp.notes,
       s.name AS staff_name, s.staff_code,
       pos.name AS position_name,
       r.period_year, r.period_month, r.status AS run_status
  FROM bms.salary_payments sp
  JOIN bms.salary_runs r     ON r.id = sp.run_id
  JOIN bms.staff s           ON s.id = sp.staff_id
  JOIN bms.staff_positions pos ON pos.id = s.position_id;

-- ---------------------------------------------------------------------
-- WORK MONITORING — was the round actually done?
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_work_logs WITH (security_invoker = true) AS
SELECT w.id, w.log_date, w.shift, w.overall_status, w.remarks, w.photo_path,
       w.template_id, w.staff_id,
       tpl.name AS template_name, tpl.frequency,
       s.name   AS staff_name,
       (SELECT COUNT(*) FROM bms.work_log_items li WHERE li.work_log_id = w.id) AS item_count,
       (SELECT COUNT(*) FROM bms.work_log_items li WHERE li.work_log_id = w.id AND li.is_done) AS done_count,
       rp.full_name AS recorded_by_name
  FROM bms.work_logs w
  JOIN bms.work_checklist_templates tpl ON tpl.id = w.template_id
  LEFT JOIN bms.staff s ON s.id = w.staff_id
  LEFT JOIN bms.user_profiles rp ON rp.user_id = w.recorded_by;

CREATE OR REPLACE VIEW bms.v_work_compliance WITH (security_invoker = true) AS
SELECT tpl.id AS template_id, tpl.name AS template_name,
       EXTRACT(YEAR  FROM w.log_date)::int AS period_year,
       EXTRACT(MONTH FROM w.log_date)::int AS period_month,
       COUNT(*)                                        AS logs_recorded,
       COUNT(*) FILTER (WHERE w.overall_status = 'DONE')     AS fully_done,
       COUNT(*) FILTER (WHERE w.overall_status = 'PARTIAL')  AS partly_done,
       COUNT(*) FILTER (WHERE w.overall_status = 'NOT_DONE') AS not_done,
       CASE WHEN COUNT(*) > 0
            THEN ROUND(COUNT(*) FILTER (WHERE w.overall_status = 'DONE') * 100.0 / COUNT(*), 1)
            ELSE 0 END AS done_pct
  FROM bms.work_logs w
  JOIN bms.work_checklist_templates tpl ON tpl.id = w.template_id
 GROUP BY 1,2,3,4;

-- ---------------------------------------------------------------------
-- The dashboard alert list, now that there are assets and issues to
-- worry about. Same columns as before; more reasons to be told.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS bms.v_dashboard_alerts;
CREATE VIEW bms.v_dashboard_alerts WITH (security_invoker = true) AS
SELECT 'PENDING_APPROVAL'::text AS alert_type, 'HIGH'::text AS severity,
       COUNT(*)::int AS item_count, SUM(amount)::numeric(14,2) AS amount,
       'Expense approvals waiting'::text AS title, '#/finance/approvals'::text AS link
  FROM bms.transactions WHERE status = 'PENDING_APPROVAL' HAVING COUNT(*) > 0
UNION ALL
SELECT 'SERVICE_CHARGE_OVERDUE', 'HIGH', COUNT(*)::int, SUM(due_amount)::numeric(14,2),
       'Flats with overdue service charge', '#/charges/outstanding'
  FROM bms.v_flat_charges WHERE status = 'OVERDUE' HAVING COUNT(*) > 0
UNION ALL
SELECT 'PENDING_WAIVER', 'NORMAL', COUNT(*)::int, SUM(amount)::numeric(14,2),
       'Waivers waiting for approval', '#/charges/adjustments'
  FROM bms.adjustments WHERE status = 'PENDING' HAVING COUNT(*) > 0
UNION ALL
SELECT 'RETURNED_TO_ME', 'NORMAL', COUNT(*)::int, SUM(amount)::numeric(14,2),
       'Your entries returned for correction', '#/finance'
  FROM bms.transactions WHERE status = 'RETURNED' AND created_by = auth.uid() HAVING COUNT(*) > 0
UNION ALL
SELECT 'UNPOSTED_DRAFTS', 'LOW', COUNT(*)::int, SUM(amount)::numeric(14,2),
       'Draft entries not yet submitted', '#/finance'
  FROM bms.transactions WHERE status = 'DRAFT' AND created_by = auth.uid() HAVING COUNT(*) > 0
UNION ALL
SELECT 'SERVICE_OVERDUE', 'HIGH', COUNT(*)::int, NULL::numeric(14,2),
       'Equipment overdue for service', '#/assets'
  FROM bms.v_assets WHERE service_status = 'OVERDUE' HAVING COUNT(*) > 0
UNION ALL
SELECT 'SERVICE_DUE_SOON', 'NORMAL', COUNT(*)::int, NULL::numeric(14,2),
       'Equipment due for service soon', '#/assets'
  FROM bms.v_assets WHERE service_status = 'DUE_SOON' HAVING COUNT(*) > 0
UNION ALL
SELECT 'INSPECTION_OVERDUE', 'HIGH', COUNT(*)::int, NULL::numeric(14,2),
       'Fire extinguisher inspections overdue', '#/assets?type=FIRE_EXTINGUISHER'
  FROM bms.v_assets WHERE inspection_status = 'OVERDUE' AND asset_type = 'FIRE_EXTINGUISHER'
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'INSPECTION_DUE_SOON', 'NORMAL', COUNT(*)::int, NULL::numeric(14,2),
       'Fire extinguisher inspections due soon', '#/assets?type=FIRE_EXTINGUISHER'
  FROM bms.v_assets WHERE inspection_status = 'DUE_SOON' AND asset_type = 'FIRE_EXTINGUISHER'
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'ISSUES_OVERDUE', 'HIGH', COUNT(*)::int, NULL::numeric(14,2),
       'Maintenance issues past their target time', '#/maintenance'
  FROM bms.v_issues WHERE is_overdue HAVING COUNT(*) > 0
UNION ALL
SELECT 'ISSUES_OPEN', 'NORMAL', COUNT(*)::int, NULL::numeric(14,2),
       'Maintenance issues still open', '#/maintenance'
  FROM bms.v_issues WHERE status IN ('OPEN','ASSIGNED','IN_PROGRESS') HAVING COUNT(*) > 0
UNION ALL
SELECT 'ISSUES_TO_VERIFY', 'NORMAL', COUNT(*)::int, NULL::numeric(14,2),
       'Completed work waiting to be checked', '#/maintenance'
  FROM bms.v_issues WHERE status = 'COMPLETED' HAVING COUNT(*) > 0
UNION ALL
SELECT 'GENERATOR_RUNNING', 'NORMAL', COUNT(*)::int, NULL::numeric(14,2),
       'Generator runs left open', '#/generator'
  FROM bms.generator_runs WHERE gen_stop IS NULL HAVING COUNT(*) > 0
UNION ALL
SELECT 'SALARY_UNPAID', 'NORMAL', COUNT(*)::int, SUM(net_payable)::numeric(14,2),
       'Salaries generated but not yet paid', '#/staff/salary'
  FROM bms.v_salary_payments WHERE status = 'PENDING' HAVING COUNT(*) > 0
UNION ALL
SELECT 'WARRANTY_EXPIRING', 'LOW', COUNT(*)::int, NULL::numeric(14,2),
       'Warranties expiring within 60 days', '#/assets'
  FROM bms.assets
 WHERE status = 'ACTIVE' AND warranty_expiry IS NOT NULL
   AND warranty_expiry BETWEEN CURRENT_DATE AND CURRENT_DATE + 60
 HAVING COUNT(*) > 0;

GRANT SELECT ON ALL TABLES IN SCHEMA bms TO authenticated;
REVOKE SELECT ON bms.doc_counters FROM authenticated;

-- END 041_operations_views.sql


-- =====================================================================
-- BEGIN 042_fund_views.sql
-- =====================================================================

-- =====================================================================
-- 042_fund_views.sql — reserve, deposits, reconciliation, the building's
-- total financial position, and one alert list used by both the
-- dashboard and the notification generator.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- FUND BALANCES
--
-- A fund's balance is its opening balance plus what has been put in and
-- taken out. That is the EARMARK — what the committee says is set aside.
--
-- Whether the money is really there is a different question, and this
-- view answers it separately as `funded_amount`: fixed deposits tagged to
-- the fund, plus either the balance of the fund's own account (when it
-- has one) or the net cash actually moved for it (when it does not). The
-- two backings are never added together for the same fund, because a
-- fund with its own account moves cash INTO that account and counting
-- both would report the money twice.
--
-- `unfunded_amount` is the gap, and it is the number that matters: a
-- reserve of Tk 800,000 with Tk 800,000 unfunded is a minute of a
-- meeting, not money.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_fund_balances WITH (security_invoker = true) AS
WITH mv AS (
  SELECT fund_id,
         SUM(CASE WHEN direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN')
                  THEN amount ELSE -amount END)::numeric(14,2) AS movement,
         SUM(CASE WHEN is_cash_movement
                  THEN CASE WHEN direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN')
                            THEN amount ELSE -amount END
                  ELSE 0 END)::numeric(14,2) AS cash_movement,
         MAX(movement_date) AS last_movement
    FROM bms.fund_movements GROUP BY fund_id
)
, bal AS (
  SELECT f.id AS fund_id,
         (f.opening_balance + COALESCE(mv.movement, 0))::numeric(14,2) AS current_balance,
         COALESCE((SELECT SUM(fd.principal) FROM bms.fixed_deposits fd
                    WHERE fd.fund_id = f.id AND fd.status = 'ACTIVE'), 0)::numeric(14,2)
           AS held_in_deposits,
         CASE WHEN f.account_id IS NOT NULL
              THEN COALESCE((SELECT ab.current_balance FROM bms.v_account_balances ab
                              WHERE ab.account_id = f.account_id), 0)
              ELSE COALESCE(mv.cash_movement, 0)
         END::numeric(14,2) AS held_in_account
    FROM bms.funds f
    LEFT JOIN mv ON mv.fund_id = f.id
)
SELECT f.id AS fund_id, f.code, f.name, f.fund_type, f.purpose,
       f.opening_balance, f.target_amount, f.target_date, f.account_id, f.is_active,
       COALESCE(mv.movement, 0)                                   AS movement,
       b.current_balance,
       b.held_in_deposits,
       b.held_in_account,
       (b.held_in_deposits + b.held_in_account)::numeric(14,2)    AS funded_amount,
       GREATEST(b.current_balance - b.held_in_deposits - b.held_in_account, 0)::numeric(14,2)
            AS unfunded_amount,
       (b.held_in_deposits + b.held_in_account >= b.current_balance) AS is_funded,
       mv.last_movement,
       CASE WHEN f.target_amount > 0
            THEN LEAST(100, ROUND(b.current_balance * 100.0 / f.target_amount, 1))
       END AS progress_pct,
       GREATEST(f.target_amount - b.current_balance, 0)::numeric(14,2) AS remaining_required
  FROM bms.funds f
  JOIN bal b ON b.fund_id = f.id
  LEFT JOIN mv ON mv.fund_id = f.id;

-- ---------------------------------------------------------------------
-- FIXED DEPOSITS
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_fixed_deposits WITH (security_invoker = true) AS
SELECT fd.id, fd.fd_no, fd.bank_name, fd.branch, fd.principal, fd.deposit_date,
       fd.tenure_months, fd.interest_rate, fd.maturity_date,
       fd.expected_maturity_amount, fd.actual_maturity_amount,
       fd.auto_renew, fd.purpose, fd.status, fd.notes,
       fd.account_id, fd.source_account_id, fd.fund_id, fd.parent_fd_id,
       f.name AS fund_name,
       a.name AS holding_account,
       (fd.maturity_date - CURRENT_DATE) AS days_to_maturity,
       CASE WHEN fd.status <> 'ACTIVE'                       THEN fd.status
            WHEN fd.maturity_date IS NULL                    THEN 'ACTIVE'
            WHEN fd.maturity_date < CURRENT_DATE             THEN 'MATURED_UNCLAIMED'
            WHEN fd.maturity_date <= CURRENT_DATE + s.fd_maturity_warn_days THEN 'MATURING_SOON'
            ELSE 'ACTIVE' END AS maturity_status,
       (COALESCE(fd.expected_maturity_amount, fd.principal) - fd.principal)::numeric(14,2)
            AS expected_interest,
       COALESCE((SELECT SUM(e.amount) FROM bms.fd_events e
                  WHERE e.fd_id = fd.id AND e.event_type = 'INTEREST_CREDIT'), 0)::numeric(14,2)
            AS interest_received
  FROM bms.fixed_deposits fd
  CROSS JOIN bms.building_settings s
  LEFT JOIN bms.funds    f ON f.id = fd.fund_id
  LEFT JOIN bms.accounts a ON a.id = fd.account_id;

-- ---------------------------------------------------------------------
-- THE BUILDING'S TOTAL POSITION — question 13 of the specification.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_financial_position WITH (security_invoker = true) AS
SELECT
  (SELECT COALESCE(SUM(current_balance),0) FROM bms.v_account_balances WHERE kind = 'CASH')::numeric(14,2)          AS cash_in_hand,
  (SELECT COALESCE(SUM(current_balance),0) FROM bms.v_account_balances WHERE kind IN ('BANK','MOBILE_WALLET'))::numeric(14,2) AS bank_balance,
  (SELECT COALESCE(SUM(current_balance),0) FROM bms.v_account_balances WHERE kind = 'FD')::numeric(14,2)            AS fixed_deposits,
  (SELECT COALESCE(SUM(current_balance),0) FROM bms.v_account_balances)::numeric(14,2)                              AS total_held,
  (SELECT COALESCE(SUM(outstanding),0) FROM bms.v_flat_dues)::numeric(14,2)                                         AS service_charge_receivable,
  (SELECT COALESCE(SUM(advance),0)     FROM bms.v_flat_dues)::numeric(14,2)                                         AS advances_held,
  (SELECT COALESCE(SUM(amount),0) FROM bms.transactions
    WHERE status IN ('APPROVED','PENDING_APPROVAL') AND direction = 'EXPENSE')::numeric(14,2)                       AS committed_expense,
  (SELECT COALESCE(SUM(current_balance),0) FROM bms.v_fund_balances WHERE is_active)::numeric(14,2)                  AS reserve_earmarked,
  (SELECT COALESCE(SUM(net_payable),0) FROM bms.v_salary_payments WHERE status = 'PENDING')::numeric(14,2)           AS salary_due;

-- ---------------------------------------------------------------------
-- RECONCILIATION
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_bank_statements WITH (security_invoker = true) AS
SELECT st.id, st.account_id, st.statement_date, st.period_start, st.period_end,
       st.opening_balance, st.closing_balance, st.status, st.notes,
       a.name AS account_name, a.code AS account_code,
       (SELECT COUNT(*) FROM bms.bank_statement_lines l WHERE l.statement_id = st.id) AS line_count,
       (SELECT COUNT(*) FROM bms.bank_statement_lines l
         WHERE l.statement_id = st.id AND l.match_status = 'UNMATCHED')               AS unmatched_count,
       (SELECT COALESCE(a2.opening_balance,0) + COALESCE(SUM(le.signed_amount),0)
          FROM bms.accounts a2
          LEFT JOIN bms.ledger_entries le
                 ON le.account_id = a2.id AND le.entry_date <= st.statement_date
         WHERE a2.id = st.account_id
         GROUP BY a2.opening_balance)::numeric(14,2)                                   AS system_balance
  FROM bms.bank_statements st
  JOIN bms.accounts a ON a.id = st.account_id;

-- ---------------------------------------------------------------------
-- ALERTS, in one place.
--
-- v_alerts_all is deliberately NOT security_invoker and is NOT readable
-- by the client: the notification generator needs to see every alert
-- regardless of who is asking. What each person may be told is decided
-- once, in notification_rules, and applied by v_dashboard_alerts below.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bms.v_alerts_all AS
SELECT 'PENDING_APPROVAL'::text AS alert_type, COUNT(*)::int AS item_count,
       SUM(amount)::numeric(14,2) AS amount, '#/finance/approvals'::text AS link
  FROM bms.transactions WHERE status = 'PENDING_APPROVAL' HAVING COUNT(*) > 0
UNION ALL
SELECT 'SERVICE_CHARGE_OVERDUE', COUNT(*)::int, SUM(due_amount)::numeric(14,2), '#/charges/outstanding'
  FROM bms.v_flat_charges WHERE status = 'OVERDUE' HAVING COUNT(*) > 0
UNION ALL
SELECT 'PENDING_WAIVER', COUNT(*)::int, SUM(amount)::numeric(14,2), '#/charges/adjustments'
  FROM bms.adjustments WHERE status = 'PENDING' HAVING COUNT(*) > 0
UNION ALL
SELECT 'SERVICE_OVERDUE', COUNT(*)::int, NULL::numeric(14,2), '#/maintenance'
  FROM bms.assets a CROSS JOIN bms.building_settings s
 WHERE a.status = 'ACTIVE' AND a.next_service_date < CURRENT_DATE HAVING COUNT(*) > 0
UNION ALL
SELECT 'SERVICE_DUE_SOON', COUNT(*)::int, NULL::numeric(14,2), '#/maintenance'
  FROM bms.assets a CROSS JOIN bms.building_settings s
 WHERE a.status = 'ACTIVE' AND a.next_service_date >= CURRENT_DATE
   AND a.next_service_date <= CURRENT_DATE + s.service_warn_days HAVING COUNT(*) > 0
UNION ALL
SELECT 'INSPECTION_OVERDUE', COUNT(*)::int, NULL::numeric(14,2), '#/fire'
  FROM bms.assets a
 WHERE a.status = 'ACTIVE' AND a.asset_type = 'FIRE_EXTINGUISHER'
   AND (a.next_inspection_date IS NULL OR a.next_inspection_date < CURRENT_DATE)
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'INSPECTION_DUE_SOON', COUNT(*)::int, NULL::numeric(14,2), '#/fire'
  FROM bms.assets a CROSS JOIN bms.building_settings s
 WHERE a.status = 'ACTIVE' AND a.asset_type = 'FIRE_EXTINGUISHER'
   AND a.next_inspection_date >= CURRENT_DATE
   AND a.next_inspection_date <= CURRENT_DATE + s.inspection_warn_days HAVING COUNT(*) > 0
UNION ALL
SELECT 'ISSUES_OVERDUE', COUNT(*)::int, NULL::numeric(14,2), '#/maintenance'
  FROM bms.issues
 WHERE status NOT IN ('COMPLETED','VERIFIED','CANCELLED') AND due_at < now() HAVING COUNT(*) > 0
UNION ALL
SELECT 'ISSUES_OPEN', COUNT(*)::int, NULL::numeric(14,2), '#/maintenance'
  FROM bms.issues WHERE status IN ('OPEN','ASSIGNED','IN_PROGRESS') HAVING COUNT(*) > 0
UNION ALL
SELECT 'ISSUES_TO_VERIFY', COUNT(*)::int, NULL::numeric(14,2), '#/maintenance'
  FROM bms.issues WHERE status = 'COMPLETED' HAVING COUNT(*) > 0
UNION ALL
SELECT 'GENERATOR_RUNNING', COUNT(*)::int, NULL::numeric(14,2), '#/generator'
  FROM bms.generator_runs WHERE gen_stop IS NULL HAVING COUNT(*) > 0
UNION ALL
SELECT 'SALARY_UNPAID', COUNT(*)::int, SUM(sp.net_payable)::numeric(14,2), '#/salary'
  FROM bms.salary_payments sp WHERE sp.status = 'PENDING' HAVING COUNT(*) > 0
UNION ALL
SELECT 'WARRANTY_EXPIRING', COUNT(*)::int, NULL::numeric(14,2), '#/maintenance'
  FROM bms.assets
 WHERE status = 'ACTIVE' AND warranty_expiry BETWEEN CURRENT_DATE AND CURRENT_DATE + 60
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'FD_MATURING', COUNT(*)::int, SUM(fd.principal)::numeric(14,2), '#/reserve'
  FROM bms.fixed_deposits fd CROSS JOIN bms.building_settings s
 WHERE fd.status = 'ACTIVE' AND fd.maturity_date IS NOT NULL
   AND fd.maturity_date <= CURRENT_DATE + s.fd_maturity_warn_days HAVING COUNT(*) > 0
UNION ALL
SELECT 'BANK_UNRECONCILED', COUNT(*)::int, NULL::numeric(14,2), '#/bank/reconcile'
  FROM bms.bank_statements WHERE status = 'OPEN' HAVING COUNT(*) > 0
UNION ALL
SELECT 'OVER_BUDGET', COUNT(*)::int, NULL::numeric(14,2), '#/budget'
  FROM bms.v_budget_vs_actual WHERE over_budget_to_date HAVING COUNT(*) > 0;

REVOKE ALL ON bms.v_alerts_all FROM PUBLIC, anon, authenticated;

-- What a given person is actually told: the alerts their role covers,
-- plus the two that are about them personally.
--
-- This view is the SECOND and last deliberate definer view in the schema.
-- It has to be: it reads v_alerts_all, which no client may read, so a
-- security_invoker view here would simply fail for everybody. Reading as
-- the owner is safe because the only thing that escapes is a count and a
-- total for an alert the caller passes bms.has_perm() on — the same test
-- that governs the screen the alert links to. It emits no row-level data
-- and no identifiers.
DROP VIEW IF EXISTS bms.v_dashboard_alerts;
CREATE VIEW bms.v_dashboard_alerts AS
SELECT a.alert_type, r.severity, a.item_count, a.amount, r.title, a.link
  FROM bms.v_alerts_all a
  JOIN bms.notification_rules r ON r.alert_type = a.alert_type
 WHERE r.is_enabled AND bms.has_perm(r.module_code, r.action)
UNION ALL
SELECT 'RETURNED_TO_ME', 'NORMAL', COUNT(*)::int, SUM(amount)::numeric(14,2),
       'Your entries returned for correction', '#/finance'
  FROM bms.transactions WHERE status = 'RETURNED' AND created_by = auth.uid()
 HAVING COUNT(*) > 0
UNION ALL
SELECT 'UNPOSTED_DRAFTS', 'LOW', COUNT(*)::int, SUM(amount)::numeric(14,2),
       'Draft entries not yet submitted', '#/finance'
  FROM bms.transactions WHERE status = 'DRAFT' AND created_by = auth.uid()
 HAVING COUNT(*) > 0;

-- A person's own notifications, and nobody else's.
CREATE OR REPLACE VIEW bms.v_my_notifications WITH (security_invoker = true) AS
SELECT n.* FROM bms.notifications n WHERE n.user_id = auth.uid();

GRANT SELECT ON ALL TABLES IN SCHEMA bms TO authenticated;
REVOKE SELECT ON bms.doc_counters  FROM authenticated;
REVOKE SELECT ON bms.v_alerts_all  FROM authenticated;
GRANT  SELECT ON bms.v_dashboard_alerts TO authenticated;

-- END 042_fund_views.sql


-- =====================================================================
-- BEGIN 050_seed.sql
-- =====================================================================

-- =====================================================================
-- 050_seed.sql — reference data: modules, permissions, roles, the role
-- matrix, departments, categories, and a starting settings row.
--
-- Safe to re-run: everything is ON CONFLICT DO NOTHING or an upsert.
-- It creates NO users and NO money.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- MODULES. phase 1 and 2 are enabled; later phases are registered now so
-- permissions can be configured before the screens exist.
-- ---------------------------------------------------------------------
INSERT INTO bms.modules (code, name, icon, sort_order, phase, is_enabled) VALUES
  ('dashboard',  'Dashboard',            'dashboard',  10,  1, true),
  ('flats',      'Flats & Owners',       'home',       20,  1, true),
  ('charges',    'Service Charge',       'receipt',    30,  2, true),
  ('finance',    'Finance / Ledger',     'ledger',     40,  1, true),
  ('bank',       'Bank & Cash',          'bank',       50,  1, true),
  ('reports',    'Reports',              'chart',      60,  2, true),
  ('budget',     'Budget',               'target',     70,  5, false),
  ('reserve',    'Reserve & Deposits',   'vault',      80,  5, false),
  ('generator',  'Generator',            'bolt',       90,  4, false),
  ('lift',       'Lift',                 'lift',      100,  4, false),
  ('fire',       'Fire Safety',          'flame',     110,  4, false),
  ('maintenance','Maintenance',          'wrench',    120,  4, false),
  ('staff',      'Staff',                'users',     130,  4, false),
  ('salary',     'Salary',               'wallet',    140,  4, false),
  ('work',       'Work Monitoring',      'check',     150,  4, false),
  ('mosque',     'Mosque',               'moon',      160,  4, false),
  ('users',      'Users & Roles',        'shield',    900,  1, true),
  ('audit',      'Audit Log',            'history',   910,  1, true),
  ('settings',   'Settings',             'settings',  920,  1, true)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, icon = EXCLUDED.icon,
      sort_order = EXCLUDED.sort_order, phase = EXCLUDED.phase;

-- ---------------------------------------------------------------------
-- PERMISSIONS — which actions each module supports.
-- ---------------------------------------------------------------------
INSERT INTO bms.permissions (module_code, action)
SELECT m.code, a.action
  FROM bms.modules m
  CROSS JOIN LATERAL (
    SELECT unnest(
      CASE m.code
        WHEN 'dashboard' THEN ARRAY['view']
        WHEN 'reports'   THEN ARRAY['view','export']
        WHEN 'audit'     THEN ARRAY['view','export']
        WHEN 'settings'  THEN ARRAY['view','edit']
        WHEN 'users'     THEN ARRAY['view','add','edit','manage']
        WHEN 'bank'      THEN ARRAY['view','add','edit','export','view_sensitive']
        WHEN 'finance'   THEN ARRAY['view','add','edit','approve','export','cancel','close']
        WHEN 'charges'   THEN ARRAY['view','add','edit','approve','export','cancel','waive']
        WHEN 'budget'    THEN ARRAY['view','add','edit','export']
        ELSE ARRAY['view','add','edit','approve','export','cancel']
      END) AS action
  ) a
ON CONFLICT (module_code, action) DO NOTHING;

-- ---------------------------------------------------------------------
-- ROLES
-- ---------------------------------------------------------------------
INSERT INTO bms.roles (code, name, description, is_system, is_superuser, approve_limit, auto_post_limit, sort_order) VALUES
  ('SUPER_ADMIN','Super Admin','Everything, including roles and settings. Keep this to one or two people.', true, true,  NULL,      NULL,  10),
  ('ADMIN','Admin','Full operational and financial access.',                                                true, false, NULL,      NULL,  20),
  ('FINANCE_MANAGER','Finance Manager','Ledger, service charge, bank, approvals and reports.',              true, false, 200000.00, 20000.00, 30),
  ('MANAGER','Manager','Day-to-day management with limited financial authority.',                           true, false,  25000.00,  5000.00, 40),
  ('CARETAKER','Caretaker','Operational logging and expense submission. Cannot approve or post.',           true, false,       0.00,     0.00, 50),
  ('COMMITTEE','Committee Member','Read-only across the building, including reports.',                      true, false,       0.00,     0.00, 60),
  ('AUDITOR','Auditor','Read-only everywhere, including the audit log. Changes nothing.',                   true, false,       0.00,     0.00, 70)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description,
      is_superuser = EXCLUDED.is_superuser,
      approve_limit = EXCLUDED.approve_limit,
      auto_post_limit = EXCLUDED.auto_post_limit;

-- Helper: give a role a set of actions on a module.
CREATE OR REPLACE FUNCTION bms.seed_grant(p_role text, p_module text, p_actions text[])
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO bms.role_permissions (role_id, permission_id)
  SELECT r.id, p.id
    FROM bms.roles r, bms.permissions p
   WHERE r.code = p_role AND p.module_code = p_module AND p.action = ANY(p_actions)
  ON CONFLICT DO NOTHING;
END $$;

DO $$
DECLARE
  ALL_OPS text[] := ARRAY['view','add','edit','approve','export','cancel'];
  m record;
BEGIN
  -- SUPER_ADMIN is is_superuser and needs no explicit rows.

  -- ADMIN: everything except the superuser flag.
  FOR m IN SELECT code FROM bms.modules LOOP
    INSERT INTO bms.role_permissions (role_id, permission_id)
    SELECT r.id, p.id FROM bms.roles r, bms.permissions p
     WHERE r.code = 'ADMIN' AND p.module_code = m.code
    ON CONFLICT DO NOTHING;
  END LOOP;

  -- FINANCE MANAGER
  PERFORM bms.seed_grant('FINANCE_MANAGER','dashboard', ARRAY['view']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','finance',   ARRAY['view','add','edit','approve','export','cancel','close']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','charges',   ARRAY['view','add','edit','approve','export','cancel','waive']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','bank',      ARRAY['view','add','edit','export','view_sensitive']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','budget',    ARRAY['view','add','edit','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','reserve',   ARRAY['view','add','edit','approve','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','flats',     ARRAY['view','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','reports',   ARRAY['view','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','audit',     ARRAY['view','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','salary',    ARRAY['view','add','edit','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','settings',  ARRAY['view']);
  -- Read-only sight of the operational modules: someone approving a
  -- Tk 18,000 lift repair should be able to open the job it came from.
  FOR m IN SELECT code FROM bms.modules
            WHERE code IN ('generator','lift','fire','maintenance','staff','work','mosque') LOOP
    PERFORM bms.seed_grant('FINANCE_MANAGER', m.code, ARRAY['view','export']);
  END LOOP;

  -- MANAGER
  PERFORM bms.seed_grant('MANAGER','dashboard', ARRAY['view']);
  PERFORM bms.seed_grant('MANAGER','finance',   ARRAY['view','add','approve','export']);
  PERFORM bms.seed_grant('MANAGER','charges',   ARRAY['view','add','export']);
  PERFORM bms.seed_grant('MANAGER','bank',      ARRAY['view']);
  PERFORM bms.seed_grant('MANAGER','flats',     ARRAY['view','add','edit','export']);
  PERFORM bms.seed_grant('MANAGER','reports',   ARRAY['view','export']);
  PERFORM bms.seed_grant('MANAGER','budget',    ARRAY['view','export']);
  PERFORM bms.seed_grant('MANAGER','reserve',   ARRAY['view']);
  PERFORM bms.seed_grant('MANAGER','settings',  ARRAY['view']);
  FOR m IN SELECT code FROM bms.modules
            WHERE code IN ('generator','lift','fire','maintenance','staff','work','mosque') LOOP
    PERFORM bms.seed_grant('MANAGER', m.code, ALL_OPS);
  END LOOP;

  -- CARETAKER: may submit an expense, never approve or post one.
  PERFORM bms.seed_grant('CARETAKER','dashboard', ARRAY['view']);
  PERFORM bms.seed_grant('CARETAKER','finance',   ARRAY['add']);
  PERFORM bms.seed_grant('CARETAKER','flats',     ARRAY['view']);
  FOR m IN SELECT code FROM bms.modules
            WHERE code IN ('generator','lift','fire','maintenance','work') LOOP
    PERFORM bms.seed_grant('CARETAKER', m.code, ARRAY['view','add','edit']);
  END LOOP;
  PERFORM bms.seed_grant('CARETAKER','staff', ARRAY['view']);

  -- COMMITTEE: read-only, no bank account numbers.
  PERFORM bms.seed_grant('COMMITTEE','dashboard', ARRAY['view']);
  FOR m IN SELECT code FROM bms.modules
            WHERE code NOT IN ('users','audit','settings','salary') LOOP
    PERFORM bms.seed_grant('COMMITTEE', m.code, ARRAY['view','export']);
  END LOOP;

  -- AUDITOR: read-only everywhere, including the audit log.
  FOR m IN SELECT code FROM bms.modules LOOP
    PERFORM bms.seed_grant('AUDITOR', m.code, ARRAY['view','export']);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- BUILDING SETTINGS — one row, editable in the UI.
-- ---------------------------------------------------------------------
INSERT INTO bms.building_settings (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPARTMENTS
-- ---------------------------------------------------------------------
INSERT INTO bms.departments (code, name, sort_order) VALUES
  ('SERVICE_CHARGE','Service Charge',  10),
  ('GENERATOR',     'Generator',       20),
  ('LIFT',          'Lift',            30),
  ('SECURITY',      'Security',        40),
  ('CLEANING',      'Cleaning',        50),
  ('GARDEN',        'Garden',          60),
  ('MOSQUE',        'Mosque',          70),
  ('MAINTENANCE',   'Maintenance',     80),
  ('UTILITIES',     'Utilities',       90),
  ('ADMIN',         'Administration', 100),
  ('RESERVE',       'Reserve & Funds',110),
  ('OTHER',         'Other',          900)
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name;

-- ---------------------------------------------------------------------
-- CATEGORIES
-- ---------------------------------------------------------------------
INSERT INTO bms.categories (department_id, name, txn_type, sort_order)
SELECT d.id, c.name, c.txn_type, c.sort_order
  FROM (VALUES
    ('SERVICE_CHARGE','Monthly service charge',  'INCOME',  10),
    ('SERVICE_CHARGE','Opening balance received','INCOME',  20),
    ('SERVICE_CHARGE','Late fee',                'INCOME',  30),
    ('GENERATOR',     'Diesel / fuel',           'EXPENSE', 10),
    ('GENERATOR',     'Engine oil & coolant',    'EXPENSE', 20),
    ('GENERATOR',     'Servicing',               'EXPENSE', 30),
    ('GENERATOR',     'Repair & parts',          'EXPENSE', 40),
    ('LIFT',          'Monthly servicing (AMC)', 'EXPENSE', 10),
    ('LIFT',          'Repair & parts',          'EXPENSE', 20),
    ('SECURITY',      'Guard salary',            'EXPENSE', 10),
    ('SECURITY',      'Uniform & equipment',     'EXPENSE', 20),
    ('CLEANING',      'Cleaner salary',          'EXPENSE', 10),
    ('CLEANING',      'Cleaning supplies',       'EXPENSE', 20),
    ('GARDEN',        'Gardener salary',         'EXPENSE', 10),
    ('GARDEN',        'Plants & fertiliser',     'EXPENSE', 20),
    ('MOSQUE',        'Imam salary',             'EXPENSE', 10),
    ('MOSQUE',        'Assistant Imam salary',   'EXPENSE', 20),
    ('MOSQUE',        'Supplies & repairs',      'EXPENSE', 30),
    ('MOSQUE',        'Donation received',       'INCOME',  40),
    ('MAINTENANCE',   'Plumbing',                'EXPENSE', 10),
    ('MAINTENANCE',   'Electrical',              'EXPENSE', 20),
    ('MAINTENANCE',   'Building repair',         'EXPENSE', 30),
    ('MAINTENANCE',   'Fire safety',             'EXPENSE', 40),
    ('UTILITIES',     'Electricity (DESCO)',     'EXPENSE', 10),
    ('UTILITIES',     'Water (WASA)',            'EXPENSE', 20),
    ('UTILITIES',     'Gas (Titas)',             'EXPENSE', 30),
    ('UTILITIES',     'Internet & phone',        'EXPENSE', 40),
    ('ADMIN',         'Caretaker salary',        'EXPENSE', 10),
    ('ADMIN',         'Manager salary',          'EXPENSE', 20),
    ('ADMIN',         'Office & printing',       'EXPENSE', 30),
    ('ADMIN',         'Bank charges',            'EXPENSE', 40),
    ('ADMIN',         'Festival bonus',          'EXPENSE', 50),
    ('RESERVE',       'Reserve contribution',    'EXPENSE', 10),
    ('RESERVE',       'Bank interest',           'INCOME',  20),
    ('RESERVE',       'Deposit penalty',         'EXPENSE', 30),
    ('OTHER',         'Other income',            'INCOME',  10),
    ('OTHER',         'Other expense',           'EXPENSE', 20)
  ) AS c(dept, name, txn_type, sort_order)
  JOIN bms.departments d ON d.code = c.dept
-- Named target, not a bare ON CONFLICT. The bare form matched the
-- (department_id, parent_id, name) constraint, which never fires for a
-- top-level category because parent_id is NULL — so re-running this file
-- used to duplicate every category.
ON CONFLICT (department_id, name) WHERE parent_id IS NULL DO NOTHING;

-- ---------------------------------------------------------------------
-- A cash account so the very first payment has somewhere to land.
-- The real bank account is added through the UI.
-- ---------------------------------------------------------------------
INSERT INTO bms.accounts (code, name, kind, opening_balance, opening_date)
VALUES ('CASH', 'Cash in hand', 'CASH', 0, CURRENT_DATE)
ON CONFLICT (code) DO NOTHING;

UPDATE bms.building_settings
   SET default_cash_account_id = (SELECT id FROM bms.accounts WHERE code = 'CASH')
 WHERE default_cash_account_id IS NULL;

DROP FUNCTION IF EXISTS bms.seed_grant(text, text, text[]);

-- END 050_seed.sql


-- =====================================================================
-- BEGIN 051_operations_seed.sql
-- =====================================================================

-- =====================================================================
-- 051_operations_seed.sql — Phase 3 reference data.
-- Safe to re-run. Creates no assets, no staff and no money.
-- =====================================================================

SET search_path = bms, public;

-- Turn the Phase 3 modules on. Permissions for them were already seeded.
UPDATE bms.modules SET is_enabled = true
 WHERE code IN ('generator','lift','fire','maintenance','staff','salary','work','mosque');

-- ---------------------------------------------------------------------
-- STAFF POSITIONS — each one knows which department it belongs to and
-- which ledger category its salary posts to, so payroll classifies
-- itself instead of asking the person entering it.
-- ---------------------------------------------------------------------
INSERT INTO bms.staff_positions (code, name, department_id, category_id, sort_order)
SELECT v.code, v.name, d.id,
       (SELECT c.id FROM bms.categories c
         WHERE c.department_id = d.id AND c.name = v.category LIMIT 1),
       v.sort_order
  FROM (VALUES
    ('CARETAKER',    'Caretaker',            'ADMIN',    'Caretaker salary',      10),
    ('MANAGER',      'Building Manager',     'ADMIN',    'Manager salary',        20),
    ('SECURITY',     'Security Guard',       'SECURITY', 'Guard salary',          30),
    ('CLEANER',      'Cleaner',              'CLEANING', 'Cleaner salary',        40),
    ('GARDENER',     'Gardener',             'GARDEN',   'Gardener salary',       50),
    ('IMAM',         'Imam',                 'MOSQUE',   'Imam salary',           60),
    ('ASST_IMAM',    'Assistant Imam',       'MOSQUE',   'Assistant Imam salary', 70),
    ('OTHER_STAFF',  'Other',                'ADMIN',    'Office & printing',    900)
  ) AS v(code, name, dept, category, sort_order)
  JOIN bms.departments d ON d.code = v.dept
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, department_id = EXCLUDED.department_id,
      category_id = EXCLUDED.category_id;

-- ---------------------------------------------------------------------
-- WORK CHECKLISTS — the caretaker's daily rounds. Every item is data,
-- so the committee can change the list without a developer.
-- ---------------------------------------------------------------------
INSERT INTO bms.work_checklist_templates (code, name, position_id, frequency, sort_order)
SELECT v.code, v.name, p.id, v.frequency, v.sort_order
  FROM (VALUES
    ('CLEAN_DAILY',  'Daily cleaning round',   'CLEANER',  'DAILY',  10),
    ('GARDEN_WEEK',  'Weekly garden care',     'GARDENER', 'WEEKLY', 20),
    ('SECURITY_SHIFT','Security shift check',  'SECURITY', 'DAILY',  30)
  ) AS v(code, name, position, frequency, sort_order)
  JOIN bms.staff_positions p ON p.code = v.position
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, frequency = EXCLUDED.frequency;

INSERT INTO bms.work_checklist_items (template_id, label, requires_photo, sort_order)
SELECT t.id, v.label, v.photo, v.sort_order
  FROM (VALUES
    ('CLEAN_DAILY', 'Staircase swept and mopped',        false, 10),
    ('CLEAN_DAILY', 'Lobby and entrance cleaned',        false, 20),
    ('CLEAN_DAILY', 'Lift floor and mirror cleaned',     false, 30),
    ('CLEAN_DAILY', 'Common toilets cleaned',            false, 40),
    ('CLEAN_DAILY', 'Rubbish removed from all floors',   true,  50),
    ('CLEAN_DAILY', 'Roof and car park tidy',            false, 60),

    ('GARDEN_WEEK', 'All plants watered',                false, 10),
    ('GARDEN_WEEK', 'Dead leaves and weeds cleared',     false, 20),
    ('GARDEN_WEEK', 'Trees and hedges trimmed',          false, 30),
    ('GARDEN_WEEK', 'Fertiliser applied where needed',   false, 40),
    ('GARDEN_WEEK', 'Pots and beds tidy',                true,  50),

    ('SECURITY_SHIFT','Main gate register up to date',   false, 10),
    ('SECURITY_SHIFT','All floors patrolled',            false, 20),
    ('SECURITY_SHIFT','Roof and basement doors locked',  false, 30),
    ('SECURITY_SHIFT','CCTV screens working',            false, 40),
    ('SECURITY_SHIFT','Nothing unusual to report',       false, 50)
  ) AS v(tpl, label, photo, sort_order)
  JOIN bms.work_checklist_templates t ON t.code = v.tpl
 WHERE NOT EXISTS (
   SELECT 1 FROM bms.work_checklist_items i
    WHERE i.template_id = t.id AND i.label = v.label);

-- ---------------------------------------------------------------------
-- A few extra ledger categories that Phase 3 needs.
-- ---------------------------------------------------------------------
INSERT INTO bms.categories (department_id, name, txn_type, sort_order)
SELECT d.id, c.name, c.txn_type, c.sort_order
  FROM (VALUES
    ('LIFT',        'Annual licence & inspection', 'EXPENSE', 30),
    ('MAINTENANCE', 'Lift repair',                 'EXPENSE', 50),
    ('MAINTENANCE', 'Generator repair',            'EXPENSE', 60),
    ('SECURITY',    'Festival bonus',              'EXPENSE', 30),
    ('CLEANING',    'Festival bonus',              'EXPENSE', 30),
    ('GARDEN',      'Pest control',                'EXPENSE', 30),
    ('MOSQUE',      'Electricity share',           'EXPENSE', 35)
  ) AS c(dept, name, txn_type, sort_order)
  JOIN bms.departments d ON d.code = c.dept
ON CONFLICT DO NOTHING;

-- END 051_operations_seed.sql


-- =====================================================================
-- BEGIN 052_funds_seed.sql
-- =====================================================================

-- =====================================================================
-- 052_funds_seed.sql — Phase 4/5 seed: turn on Budget and Reserve, set
-- up the default reserve fund, and register the notification rules.
-- =====================================================================

SET search_path = bms, public;

UPDATE bms.modules SET is_enabled = true WHERE code IN ('budget','reserve');

-- ---------------------------------------------------------------------
-- DEFAULT FUNDS
--
-- Two to start with, because they answer different questions: "can we
-- survive a bad month?" and "can we replace the lift when it dies?"
-- The committee can add more; these two are the ones every building
-- discovers it needed only after it needed them.
-- ---------------------------------------------------------------------
INSERT INTO bms.funds (code, name, fund_type, purpose, opening_balance, target_amount, notes)
VALUES
  ('RESERVE', 'General Reserve Fund', 'RESERVE',
   'Working reserve for unexpected building expenses',
   0, NULL,
   'Set a target amount once the committee agrees one. A common rule of thumb is three months of running cost.'),
  ('CAPEX', 'Capital Replacement Fund', 'SINKING',
   'Lift and generator replacement, major building repair',
   0, NULL,
   'Long-term. Money here is normally held in fixed deposits rather than the current account.')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- NOTIFICATION RULES
--
-- One row per alert the system can raise. `module_code` + `action` decide
-- WHO is told: a caretaker is not woken up about an unreconciled bank
-- statement, and a committee member is not asked to approve anything.
--
-- Turning an alert off is a single UPDATE here — no code change, and the
-- dashboard and the notification generator both stop showing it at once,
-- because they read the same table.
-- ---------------------------------------------------------------------
INSERT INTO bms.notification_rules (alert_type, title, severity, module_code, action) VALUES
  ('PENDING_APPROVAL',       'Expenses waiting for your approval',        'HIGH',   'finance',     'approve'),
  ('SERVICE_CHARGE_OVERDUE', 'Flats with overdue service charge',         'HIGH',   'charges',     'view'   ),
  ('PENDING_WAIVER',         'Waivers and adjustments awaiting decision', 'NORMAL', 'charges',     'waive'  ),
  ('SERVICE_OVERDUE',        'Equipment service overdue',                 'HIGH',   'maintenance', 'view'   ),
  ('SERVICE_DUE_SOON',       'Equipment service due soon',                'NORMAL', 'maintenance', 'view'   ),
  ('INSPECTION_OVERDUE',     'Fire extinguisher inspection overdue',      'HIGH',   'fire',        'view'   ),
  ('INSPECTION_DUE_SOON',    'Fire extinguisher inspection due soon',     'NORMAL', 'fire',        'view'   ),
  ('ISSUES_OVERDUE',         'Maintenance issues past their due date',    'HIGH',   'maintenance', 'view'   ),
  ('ISSUES_OPEN',            'Open maintenance issues',                   'LOW',    'maintenance', 'view'   ),
  ('ISSUES_TO_VERIFY',       'Completed work waiting to be verified',     'NORMAL', 'maintenance', 'approve'),
  ('GENERATOR_RUNNING',      'Generator run not yet closed',              'NORMAL', 'generator',   'view'   ),
  ('SALARY_UNPAID',          'Salaries generated but not yet paid',       'HIGH',   'salary',      'view'   ),
  ('WARRANTY_EXPIRING',      'Warranties expiring within 60 days',        'LOW',    'maintenance', 'view'   ),
  ('FD_MATURING',            'Fixed deposits maturing soon',              'HIGH',   'reserve',     'view'   ),
  ('BANK_UNRECONCILED',      'Bank statements not yet reconciled',        'NORMAL', 'bank',        'view'   ),
  ('OVER_BUDGET',            'Departments over budget',                   'HIGH',   'budget',      'view'   )
ON CONFLICT (alert_type) DO UPDATE
  SET title       = EXCLUDED.title,
      severity    = EXCLUDED.severity,
      module_code = EXCLUDED.module_code,
      action      = EXCLUDED.action;

-- END 052_funds_seed.sql


-- =====================================================================
-- BEGIN 070_reset.sql
-- =====================================================================

-- =====================================================================
-- 070_reset.sql — clearing test data so the building can start for real.
--
-- WHY THIS EXISTS
-- ---------------
-- Nobody trusts a financial system they have not played with, and nobody
-- can play with one they cannot then clean up. Without a reset, the
-- choices are to go live on top of invented numbers, or to rebuild the
-- database from scratch and lose the flats, the staff and the accounts
-- that were entered carefully. Both are bad, so this exists.
--
-- WHY IT IS BUILT LIKE THIS
-- -------------------------
-- Everything else in this schema is designed so that financial history
-- cannot be destroyed: DELETE is revoked from the application role, and
-- block_delete() sits on transactions, ledger_entries and payments as a
-- second line. This function is the single, deliberate exception, so the
-- exception is made as narrow as it can be:
--
--   * SUPER_ADMIN only — not "settings.edit", not an approval limit. The
--     one role that already has everything.
--   * A typed confirmation phrase, checked in SQL. A stray click cannot
--     reach it, and neither can a request forged from another page.
--   * A preview that counts every row it would remove, so the decision is
--     made against real numbers rather than a hopeful guess.
--   * One transaction. It removes everything or nothing.
--   * The reset writes its own audit row, and that row is written after
--     the audit log is cleared, so a reset can never be invisible.
--
-- The guards are lifted through a transaction-local setting rather than
-- by dropping the triggers: it cannot leak past COMMIT, and on its own it
-- grants nothing, because the application role still holds no DELETE
-- privilege on any of these tables.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Let block_delete() stand aside for a purge, and only for a purge.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.block_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- set_config(..., true) in reset_system() makes this local to the
  -- transaction, so it is impossible for it to survive a COMMIT or a
  -- ROLLBACK. And a client that sets it themselves gains nothing: DELETE
  -- is revoked from `authenticated` on every table this protects.
  IF current_setting('bms.purge', true) = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'Rows in % are never deleted. Use cancellation or reversal.', TG_TABLE_NAME
    USING ERRCODE = '42501';
END $$;

-- The audit log has its own append-only trigger. Same treatment.
CREATE OR REPLACE FUNCTION bms.block_audit_write() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('bms.purge', true) = 'on' AND TG_OP = 'DELETE' THEN
    RETURN OLD;                      -- a purge may clear it; nothing may edit it
  END IF;
  RAISE EXCEPTION 'The audit log is append-only' USING ERRCODE = '42501';
END $$;

-- ---------------------------------------------------------------------
-- What a reset would remove, counted before anything is touched.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.reset_preview()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_entries bigint; v_masters bigint; v_reminders bigint := 0;
BEGIN
  IF NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can reset the system' USING ERRCODE = '42501';
  END IF;

  -- Reminders arrive in 085. Counted dynamically so this function still
  -- works on a database that has not had that update.
  IF to_regclass('bms.charge_reminders') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM bms.charge_reminders' INTO v_reminders;
  END IF;

  SELECT
    (SELECT count(*) FROM bms.transactions)      + (SELECT count(*) FROM bms.payments)
  + (SELECT count(*) FROM bms.flat_charges)      + (SELECT count(*) FROM bms.fund_movements)
  + (SELECT count(*) FROM bms.fixed_deposits)    + (SELECT count(*) FROM bms.salary_payments)
  + (SELECT count(*) FROM bms.issues)            + (SELECT count(*) FROM bms.work_logs)
  + (SELECT count(*) FROM bms.generator_runs)    + (SELECT count(*) FROM bms.fuel_purchases)
  + (SELECT count(*) FROM bms.asset_service_logs)+ (SELECT count(*) FROM bms.asset_inspections)
  + (SELECT count(*) FROM bms.staff_attendance)  + (SELECT count(*) FROM bms.budgets)
  + (SELECT count(*) FROM bms.bank_statements)   + (SELECT count(*) FROM bms.notifications)
  + v_reminders
  INTO v_entries;

  SELECT
    (SELECT count(*) FROM bms.flats)  + (SELECT count(*) FROM bms.owners)
  + (SELECT count(*) FROM bms.staff)  + (SELECT count(*) FROM bms.assets)
  + (SELECT count(*) FROM bms.vendors)
  INTO v_masters;

  RETURN jsonb_build_object(
    'entries', jsonb_build_object(
      'transactions',      (SELECT count(*) FROM bms.transactions),
      'payments',          (SELECT count(*) FROM bms.payments),
      'service_charges',   (SELECT count(*) FROM bms.flat_charges),
      'fund_movements',    (SELECT count(*) FROM bms.fund_movements),
      'fixed_deposits',    (SELECT count(*) FROM bms.fixed_deposits),
      'salary_payments',   (SELECT count(*) FROM bms.salary_payments),
      'maintenance_issues',(SELECT count(*) FROM bms.issues),
      'work_logs',         (SELECT count(*) FROM bms.work_logs),
      'generator_runs',    (SELECT count(*) FROM bms.generator_runs),
      'fuel_purchases',    (SELECT count(*) FROM bms.fuel_purchases),
      'service_logs',      (SELECT count(*) FROM bms.asset_service_logs),
      'inspections',       (SELECT count(*) FROM bms.asset_inspections),
      'attendance',        (SELECT count(*) FROM bms.staff_attendance),
      'budgets',           (SELECT count(*) FROM bms.budgets),
      'bank_statements',   (SELECT count(*) FROM bms.bank_statements),
      'notifications',     (SELECT count(*) FROM bms.notifications),
      'reminders',         v_reminders),
    'masters', jsonb_build_object(
      'flats',   (SELECT count(*) FROM bms.flats),
      'owners',  (SELECT count(*) FROM bms.owners),
      'staff',   (SELECT count(*) FROM bms.staff),
      'assets',  (SELECT count(*) FROM bms.assets),
      'vendors', (SELECT count(*) FROM bms.vendors)),
    'kept', jsonb_build_object(
      'user_accounts',  (SELECT count(*) FROM bms.user_profiles),
      'roles',          (SELECT count(*) FROM bms.roles),
      'departments',    (SELECT count(*) FROM bms.departments),
      'categories',     (SELECT count(*) FROM bms.categories),
      'bank_accounts',  (SELECT count(*) FROM bms.accounts),
      'funds',          (SELECT count(*) FROM bms.funds)),
    'total_entries', v_entries,
    'total_masters', v_masters);
END $$;

-- ---------------------------------------------------------------------
-- The reset itself.
--
--   p_scope = 'entries'  every recorded entry: money, charges, payments,
--                        logs, issues, salaries, budgets, statements.
--                        Flats, owners, staff, assets and vendors stay,
--                        so the building is still set up.
--
--   p_scope = 'all'      the above, plus flats, owners, staff, assets and
--                        vendors, plus the audit log. What survives is
--                        people and their access, the building settings,
--                        the chart of departments and categories, the
--                        bank/cash accounts and the fund definitions.
--
-- Nothing removes a user account or a role. Losing access to the system
-- during a cleanup would be its own emergency, so it is not on offer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.reset_system(p_scope text, p_confirm text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_before jsonb; v_deleted bigint := 0; n bigint;
BEGIN
  IF NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can reset the system' USING ERRCODE = '42501';
  END IF;
  IF p_scope NOT IN ('entries','all') THEN
    RAISE EXCEPTION 'Unknown reset scope: %', p_scope;
  END IF;
  -- Checked here, not only in the browser. A confirmation that lives in
  -- JavaScript is a confirmation that can be skipped.
  IF p_confirm IS DISTINCT FROM 'RESET' THEN
    RAISE EXCEPTION 'Type RESET to confirm' USING ERRCODE = '22023';
  END IF;

  v_before := bms.reset_preview();

  -- Transaction-local. Gone at COMMIT, gone at ROLLBACK.
  PERFORM set_config('bms.purge', 'on', true);

  -- Every DELETE below says WHERE true, and that is not decoration.
  -- Supabase loads pg_safeupdate for the API role, which refuses a DELETE
  -- with no WHERE clause — inside SECURITY DEFINER functions too, because
  -- it is a session setting rather than a privilege. A bare "DELETE FROM
  -- t" therefore works perfectly on a plain PostgreSQL and fails on the
  -- live database with "DELETE requires a WHERE clause", which is exactly
  -- how this shipped broken. WHERE true satisfies it and reads as what it
  -- is: yes, every row, deliberately.

  -- Children before parents, throughout.
  DELETE FROM bms.work_log_items WHERE true;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.work_logs WHERE true;             GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.staff_attendance WHERE true;      GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.staff_leaves WHERE true;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.staff_advances WHERE true;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.salary_payments WHERE true;       GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.salary_runs WHERE true;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.issue_updates WHERE true;         GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.issues WHERE true;                GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.asset_parts WHERE true;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.asset_service_logs WHERE true;    GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.asset_inspections WHERE true;     GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.asset_meter_readings WHERE true;  GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.generator_runs WHERE true;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.fuel_purchases WHERE true;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.reconciliations WHERE true;       GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.bank_statement_lines WHERE true;  GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.bank_statements WHERE true;       GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.fd_events WHERE true;             GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.fixed_deposits WHERE true;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.fund_movements WHERE true;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.budget_lines WHERE true;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.budgets WHERE true;               GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.adjustments WHERE true;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.payment_allocations WHERE true;   GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.payments WHERE true;              GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  -- Combined receipts and sent bills arrive in 089; dynamic for the same
  -- reason as the reminders below.
  IF to_regclass('bms.payment_groups') IS NOT NULL THEN
    EXECUTE 'DELETE FROM bms.payment_groups WHERE true';
    GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  END IF;
  IF to_regclass('bms.bill_notices') IS NOT NULL THEN
    EXECUTE 'DELETE FROM bms.bill_notices WHERE true';
    GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  END IF;
  DELETE FROM bms.charge_line_items WHERE true;     GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.flat_charges WHERE true;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.charge_runs WHERE true;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.attachments WHERE true;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.ledger_entries WHERE true;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.transactions WHERE true;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.accounting_periods WHERE true;    GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.notifications WHERE true;         GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  -- Reminders are entries: a fresh start should not open with a history of
  -- having chased flats for invented money. Dynamic for the same reason as
  -- the count above.
  IF to_regclass('bms.charge_reminders') IS NOT NULL THEN
    EXECUTE 'DELETE FROM bms.charge_reminders WHERE true';
    GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  END IF;

  -- Document numbers start from 1 again, or the first new voucher would
  -- be numbered as though the deleted ones had happened.
  DELETE FROM bms.doc_counters WHERE true;

  IF p_scope = 'all' THEN
    DELETE FROM bms.flat_users WHERE true;      GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.flat_occupancy WHERE true;  GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.flats WHERE true;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.owners WHERE true;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.staff WHERE true;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.assets WHERE true;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.vendors WHERE true;         GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.audit_log WHERE true;
  END IF;

  -- Written last, and deliberately after the audit log may have been
  -- cleared, so that the first row in the new history says who wiped the
  -- old one. A reset that left no trace of itself would be the one
  -- action in this system nobody could account for.
  INSERT INTO bms.audit_log (actor_user_id, action, module_code, entity_table,
                             old_values, new_values, severity, detail)
  VALUES (auth.uid(), 'SYSTEM_RESET', 'settings', 'ALL', v_before,
          jsonb_build_object('scope', p_scope, 'rows_deleted', v_deleted), 'HIGH',
          'System reset — ' ||
          CASE p_scope WHEN 'all' THEN 'all entries and master records'
                       ELSE 'all entries; flats, staff and assets kept' END);

  RETURN jsonb_build_object('scope', p_scope, 'rows_deleted', v_deleted, 'before', v_before);
END $$;

REVOKE ALL ON FUNCTION bms.reset_preview()               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.reset_system(text, text)      FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.reset_preview()            TO authenticated;
GRANT EXECUTE ON FUNCTION bms.reset_system(text, text)   TO authenticated;

-- END 070_reset.sql


-- =====================================================================
-- BEGIN 080_roles.sql
-- =====================================================================

-- =====================================================================
-- 080_roles.sql — roles you can create yourself, and the guards that
-- have to exist before that is safe.
--
-- THE HOLE THIS CLOSES
-- --------------------
-- Before this file, an Admin — not a Super Admin, just the ADMIN role —
-- could do exactly this:
--
--     INSERT INTO bms.roles(code, name, is_superuser) VALUES ('X','X',true);
--     INSERT INTO bms.user_roles(user_id, role_id) VALUES (auth.uid(), <X>);
--
-- and was a Super Admin, with the system reset now available to them.
-- The RLS policy asked only for users.add, which ADMIN holds. I found it
-- by trying it, not by reading the policy, and the reason it had never
-- mattered is that nothing in the interface offered to create a role. The
-- moment a button does, the hole is one click wide, so it is closed here
-- rather than alongside.
--
-- THE RULE
-- --------
-- You cannot grant what you do not hold. A superuser role may only be
-- created or handed out by someone who is already a superuser; a role's
-- approval ceiling may not exceed the ceiling of the person setting it;
-- and a permission may only be ticked onto a role by someone who holds
-- that permission themselves. A Super Admin is exempt from all three,
-- because they already hold everything — that is what the role means.
--
-- The seven roles that ship are marked is_system and are protected from
-- renaming, recoding and deletion. They are what the documentation
-- describes and what a new administrator expects to find.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- The effective approval ceiling of the person making the request.
-- NULL means unlimited. Used to stop a role being given a bigger ceiling
-- than the person creating it has.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.my_approve_ceiling()
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT CASE
    WHEN bms.is_superuser() THEN NULL
    WHEN EXISTS (SELECT 1 FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
                  WHERE ur.user_id = auth.uid() AND r.approve_limit IS NULL) THEN NULL
    ELSE (SELECT MAX(r.approve_limit) FROM bms.user_roles ur
            JOIN bms.roles r ON r.id = ur.role_id
           WHERE ur.user_id = auth.uid())
  END;
$$;

-- ---------------------------------------------------------------------
-- Roles: what may be created, changed and removed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.guard_role() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_ceiling numeric;
BEGIN
  -- Server-side work (migrations, seeding, the bootstrap script) runs with
  -- no session user. Those are not people escalating themselves.
  IF auth.uid() IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.is_system THEN
      RAISE EXCEPTION 'The % role is part of the system and cannot be deleted', OLD.name
        USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM bms.user_roles WHERE role_id = OLD.id) THEN
      RAISE EXCEPTION 'Someone still has the % role. Move them off it first.', OLD.name
        USING ERRCODE = '23503';
    END IF;
    RETURN OLD;
  END IF;

  -- The escalation. Only a superuser may make a superuser.
  IF NEW.is_superuser
     AND (TG_OP = 'INSERT' OR NOT COALESCE(OLD.is_superuser, false))
     AND NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can create a role with full access'
      USING ERRCODE = '42501';
  END IF;

  -- ...and only a superuser may quietly mark a role as a system one, which
  -- would otherwise be a way to make a role undeletable.
  IF NEW.is_system AND (TG_OP = 'INSERT' OR NOT COALESCE(OLD.is_system, false))
     AND NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can mark a role as a system role'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.is_system THEN
    IF NEW.code IS DISTINCT FROM OLD.code THEN
      RAISE EXCEPTION 'The code of a system role cannot be changed' USING ERRCODE = '42501';
    END IF;
    IF NOT NEW.is_system THEN
      RAISE EXCEPTION 'A system role cannot be turned into an ordinary one' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- You cannot hand out a bigger cheque than you can sign.
  IF NOT bms.is_superuser() THEN
    v_ceiling := bms.my_approve_ceiling();
    IF v_ceiling IS NOT NULL
       AND (NEW.approve_limit IS NULL OR NEW.approve_limit > v_ceiling)
       AND NEW.approve_limit IS DISTINCT FROM (CASE WHEN TG_OP='UPDATE' THEN OLD.approve_limit END) THEN
      RAISE EXCEPTION 'You cannot give a role a higher approval limit than your own (%)', v_ceiling
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_role_guard ON bms.roles;
CREATE TRIGGER trg_role_guard BEFORE INSERT OR UPDATE OR DELETE ON bms.roles
  FOR EACH ROW EXECUTE FUNCTION bms.guard_role();

-- ---------------------------------------------------------------------
-- Handing a role to a person. Same rule from the other direction: even a
-- superuser role that already exists may only be given out by a superuser.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.guard_user_role() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM bms.roles WHERE id = NEW.role_id AND is_superuser)
     AND NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can give someone full access'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_user_role_guard ON bms.user_roles;
CREATE TRIGGER trg_user_role_guard BEFORE INSERT OR UPDATE ON bms.user_roles
  FOR EACH ROW EXECUTE FUNCTION bms.guard_user_role();

-- ---------------------------------------------------------------------
-- Ticking a permission onto a role. You may only grant what you hold.
-- Without this, someone with users.manage could tick finance.approve onto
-- their own role and walk around the approval limits entirely.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.guard_role_permission() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_mod text; v_act text;
BEGIN
  IF auth.uid() IS NULL OR bms.is_superuser() THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;                      -- taking access away is always allowed
  END IF;
  SELECT module_code, action INTO v_mod, v_act
    FROM bms.permissions WHERE id = NEW.permission_id;
  IF NOT bms.has_perm(v_mod, v_act) THEN
    RAISE EXCEPTION 'You cannot grant "% %" because you do not have it yourself', v_mod, v_act
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_role_perm_guard ON bms.role_permissions;
CREATE TRIGGER trg_role_perm_guard BEFORE INSERT OR UPDATE ON bms.role_permissions
  FOR EACH ROW EXECUTE FUNCTION bms.guard_role_permission();

-- ---------------------------------------------------------------------
-- Creating a role, with its permissions copied from an existing one.
--
-- A new role starting from nothing is 190 ticks of work and easy to get
-- wrong in the dangerous direction — forgetting to remove something.
-- Starting from "like the Caretaker, but only the generator" is how
-- people actually think about it, so that is what this takes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.create_role(
    p_name text,
    p_description text DEFAULT NULL,
    p_copy_from uuid DEFAULT NULL,
    p_approve_limit bms.money_amount DEFAULT 0,
    p_auto_post_limit bms.money_amount DEFAULT 0)
RETURNS bms.roles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.roles; v_code text; v_n int := 0;
BEGIN
  PERFORM bms.assert_perm('users','manage');

  IF COALESCE(btrim(p_name),'') = '' THEN
    RAISE EXCEPTION 'A role needs a name';
  END IF;

  -- A readable, stable code derived from the name: "Generator Operator"
  -- becomes GENERATOR_OPERATOR, with a numeric suffix only if it collides.
  v_code := upper(regexp_replace(btrim(p_name), '[^a-zA-Z0-9]+', '_', 'g'));
  v_code := btrim(v_code, '_');
  IF v_code = '' THEN v_code := 'ROLE'; END IF;
  v_code := left(v_code, 40);
  WHILE EXISTS (SELECT 1 FROM bms.roles WHERE code = v_code) LOOP
    v_n := v_n + 1;
    v_code := left(upper(regexp_replace(btrim(p_name), '[^a-zA-Z0-9]+', '_', 'g')), 36) || '_' || v_n;
    IF v_n > 50 THEN RAISE EXCEPTION 'Could not find a free code for "%"', p_name; END IF;
  END LOOP;

  INSERT INTO bms.roles (code, name, description, is_system, is_superuser,
                         approve_limit, auto_post_limit, sort_order)
  VALUES (v_code, btrim(p_name), NULLIF(btrim(COALESCE(p_description,'')),''),
          false, false, p_approve_limit, p_auto_post_limit,
          (SELECT COALESCE(MAX(sort_order),100) + 10 FROM bms.roles))
  RETURNING * INTO r;

  IF p_copy_from IS NOT NULL THEN
    -- A superuser role holds no permission rows — it is a flag, not a list —
    -- so copying from one would silently produce an empty role. Say so.
    IF EXISTS (SELECT 1 FROM bms.roles WHERE id = p_copy_from AND is_superuser) THEN
      RAISE EXCEPTION 'Super Admin has no permission list to copy. Start from Admin instead.';
    END IF;
    INSERT INTO bms.role_permissions (role_id, permission_id)
    SELECT r.id, rp.permission_id FROM bms.role_permissions rp
     WHERE rp.role_id = p_copy_from
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- Removing one. The guard above does the refusing; this exists so the
-- interface has something to call and gets a clear error back.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.delete_role(p_role uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('users','manage');
  DELETE FROM bms.roles WHERE id = p_role;
  IF NOT FOUND THEN RAISE EXCEPTION 'That role no longer exists'; END IF;
END $$;

REVOKE ALL ON FUNCTION bms.create_role(text, text, uuid, bms.money_amount, bms.money_amount) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.delete_role(uuid)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.my_approve_ceiling()   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.create_role(text, text, uuid, bms.money_amount, bms.money_amount) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.delete_role(uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION bms.my_approve_ceiling() TO authenticated;

-- Note: no DELETE privilege is granted to `authenticated`, deliberately.
-- A direct DELETE is refused by the grant before RLS or the guard above
-- is consulted. Removal goes through delete_role() instead, which runs
-- as the owner, fires the guard, and returns a sentence explaining why
-- when it refuses. Two layers, and the outer one needs no thought.

-- ---------------------------------------------------------------------
-- Categories: the same table the ledger uses, now editable.
--
-- Deleting one is not offered. A category that has been used is attached
-- to real transactions and removing it would either orphan them or
-- silently rewrite history; a category that has not been used is harmless
-- to leave. Hiding is the honest operation, so is_active is what the
-- screen changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.category_usage(p_category uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT (SELECT count(*) FROM bms.transactions WHERE category_id = p_category)
       + (SELECT count(*) FROM bms.budgets      WHERE category_id = p_category);
$$;
REVOKE ALL ON FUNCTION bms.category_usage(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.category_usage(uuid) TO authenticated;

-- END 080_roles.sql


-- =====================================================================
-- BEGIN 085_people_reminders.sql
-- =====================================================================

-- =====================================================================
-- 085_people_reminders.sql — who lives in a flat, who pays for it, and
-- reminding them when they have not.
--
-- PART 1 — OWNERS AND TENANTS
-- ---------------------------
-- A flat has an owner. It may also have a tenant. Exactly one of them
-- receives the service-charge bill. In this building that is often the
-- tenant: owners who live elsewhere let the flat, and the tenant pays the
-- building directly.
--
-- The table always allowed that (flat_occupancy keeps owner and tenant
-- rows side by side; the only rule is one CURRENT BILLED person per flat).
-- The screen did not. Linking a tenant through "Add owner" closed the
-- currently billed row — the owner's — by setting its to_date. The owner
-- then no longer owned the flat as far as the system was concerned, and
-- vanished from it. Moving the bill and ending an ownership are different
-- events, so they are now different functions, and every change happens
-- inside one transaction so the flat is never briefly billed to nobody.
--
-- PART 2 — REMINDERS
-- ------------------
-- A record of every time someone was asked to pay: who asked, when, to
-- which number, for how much, and the exact words. The app opens WhatsApp
-- (or SMS) with the message filled in; it cannot see whether Send was then
-- tapped, so a row here means "a reminder was prepared and handed to
-- WhatsApp", which is as much as a browser can honestly know.
--
-- Rows are never edited or deleted. A history you can rewrite is not a
-- history — and the count is what tells you how many times a flat has
-- been chased.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Settings that belong to reminders.
-- ---------------------------------------------------------------------
ALTER TABLE bms.building_settings
  ADD COLUMN IF NOT EXISTS reminder_how_to_pay    text,
  ADD COLUMN IF NOT EXISTS reminder_language      text NOT NULL DEFAULT 'en',
  ADD COLUMN IF NOT EXISTS reminder_deadline_days int  NOT NULL DEFAULT 7;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bs_reminder_language_ck') THEN
    ALTER TABLE bms.building_settings
      ADD CONSTRAINT bs_reminder_language_ck CHECK (reminder_language IN ('en','bn'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bs_reminder_deadline_ck') THEN
    ALTER TABLE bms.building_settings
      ADD CONSTRAINT bs_reminder_deadline_ck CHECK (reminder_deadline_days BETWEEN 1 AND 60);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- A phone number as WhatsApp wants it: digits only, country code first.
--
-- People type numbers every possible way — "01913469117", "+880 1913-
-- 469117", "008801913469117" — and an owner who lives abroad and lets the
-- flat has a foreign number. NULL means "this is not a number we can send
-- to", which the screen turns into a sentence rather than a broken link.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.normalize_mobile(p text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = bms, public, pg_temp AS $$
DECLARE v text; intl boolean := false;
BEGIN
  v := regexp_replace(COALESCE(p, ''), '[\s\-\(\)\.]', '', 'g');
  IF v = '' THEN RETURN NULL; END IF;

  IF v ~ '^\+' THEN v := substr(v, 2); intl := true;
  ELSIF v ~ '^00' THEN v := substr(v, 3); intl := true;
  END IF;
  IF v !~ '^[0-9]+$' THEN RETURN NULL; END IF;

  IF NOT intl THEN
    -- Bangladeshi mobiles: 013-019, eleven digits with the leading zero.
    IF v ~ '^01[3-9][0-9]{8}$'   THEN RETURN '88' || v; END IF;
    IF v ~ '^1[3-9][0-9]{8}$'    THEN RETURN '880' || v; END IF;
    IF v ~ '^8801[3-9][0-9]{8}$' THEN RETURN v; END IF;
    RETURN NULL;
  END IF;

  -- Written with a country code. A Bangladeshi one must still be a real
  -- mobile; anything else is taken as given if it is plausibly long.
  IF v ~ '^880' THEN
    RETURN CASE WHEN v ~ '^8801[3-9][0-9]{8}$' THEN v END;
  END IF;
  IF length(v) BETWEEN 8 AND 15 AND v !~ '^0' THEN RETURN v; END IF;
  RETURN NULL;
END $$;

-- =====================================================================
-- PART 1 — OWNERS AND TENANTS
-- =====================================================================

-- One row per flat: its current owner, its current tenant, and which of
-- them pays. The screens read this rather than re-deriving it.
CREATE OR REPLACE VIEW bms.v_flat_people WITH (security_invoker = true) AS
SELECT f.id AS flat_id, f.flat_number, f.floor, f.status AS flat_status,
       o.occupancy_id AS owner_occupancy_id, o.person_id AS owner_id,
       o.name AS owner_name, o.mobile AS owner_mobile, o.email AS owner_email,
       o.from_date AS owner_since, COALESCE(o.is_billed, false) AS owner_billed,
       t.occupancy_id AS tenant_occupancy_id, t.person_id AS tenant_id,
       t.name AS tenant_name, t.mobile AS tenant_mobile, t.email AS tenant_email,
       t.from_date AS tenant_since, COALESCE(t.is_billed, false) AS tenant_billed,
       CASE WHEN t.is_billed THEN 'TENANT' WHEN o.is_billed THEN 'OWNER' END AS billed_relation
  FROM bms.flats f
  LEFT JOIN LATERAL (
    SELECT fo.id AS occupancy_id, ow.id AS person_id, ow.name, ow.mobile, ow.email,
           fo.from_date, fo.is_billed
      FROM bms.flat_occupancy fo JOIN bms.owners ow ON ow.id = fo.owner_id
     WHERE fo.flat_id = f.id AND fo.relation_type = 'OWNER' AND fo.to_date IS NULL
     ORDER BY fo.from_date DESC, fo.created_at DESC LIMIT 1) o ON true
  LEFT JOIN LATERAL (
    SELECT fo.id AS occupancy_id, ow.id AS person_id, ow.name, ow.mobile, ow.email,
           fo.from_date, fo.is_billed
      FROM bms.flat_occupancy fo JOIN bms.owners ow ON ow.id = fo.owner_id
     WHERE fo.flat_id = f.id AND fo.relation_type = 'TENANT' AND fo.to_date IS NULL
     ORDER BY fo.from_date DESC, fo.created_at DESC LIMIT 1) t ON true;

REVOKE ALL ON bms.v_flat_people FROM PUBLIC, anon;
GRANT SELECT ON bms.v_flat_people TO authenticated;

-- Resolve "an existing person, or these details for a new one" to an id.
-- Shared by the owner and tenant functions so a person is never half-made.
CREATE OR REPLACE FUNCTION bms._person_for(
    p_person uuid, p_name text, p_mobile text, p_email text, p_alt text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  IF p_person IS NOT NULL THEN
    SELECT id INTO v_id FROM bms.owners WHERE id = p_person;
    IF NOT FOUND THEN RAISE EXCEPTION 'That person no longer exists'; END IF;
    RETURN v_id;
  END IF;
  IF COALESCE(btrim(p_name), '') = '' THEN
    RAISE EXCEPTION 'A name is needed';
  END IF;
  INSERT INTO bms.owners (name, mobile, email, alt_contact, created_by)
  VALUES (btrim(p_name), NULLIF(btrim(COALESCE(p_mobile,'')),''),
          NULLIF(btrim(COALESCE(p_email,'')),''), NULLIF(btrim(COALESCE(p_alt,'')),''),
          auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION bms._person_for(uuid,text,text,text,text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- The flat changes hands.
--
-- The previous owner's row is closed, not deleted, so the history of who
-- owned the flat survives. If the old owner was paying, the new one pays;
-- if a tenant is paying, the tenant carries on paying.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_flat_owner(
    p_flat uuid, p_person uuid DEFAULT NULL,
    p_name text DEFAULT NULL, p_mobile text DEFAULT NULL,
    p_email text DEFAULT NULL, p_alt text DEFAULT NULL,
    p_from date DEFAULT CURRENT_DATE)
RETURNS bms.flat_occupancy
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE cur bms.flat_occupancy; r bms.flat_occupancy; v_person uuid;
        v_billed boolean;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  PERFORM 1 FROM bms.flats WHERE id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;

  v_person := bms._person_for(p_person, p_name, p_mobile, p_email, p_alt);

  SELECT * INTO cur FROM bms.flat_occupancy
   WHERE flat_id = p_flat AND relation_type = 'OWNER' AND to_date IS NULL
   ORDER BY from_date DESC LIMIT 1;

  IF FOUND AND cur.owner_id = v_person THEN
    RETURN cur;                                   -- already the owner
  END IF;

  IF EXISTS (SELECT 1 FROM bms.flat_occupancy
              WHERE flat_id = p_flat AND relation_type = 'TENANT'
                AND to_date IS NULL AND owner_id = v_person) THEN
    RAISE EXCEPTION 'That person is the current tenant. End the tenancy first, then make them the owner.';
  END IF;

  -- The new owner pays if the old owner was paying, or if nobody is.
  v_billed := COALESCE(cur.is_billed, false)
              OR NOT EXISTS (SELECT 1 FROM bms.flat_occupancy
                              WHERE flat_id = p_flat AND to_date IS NULL AND is_billed);

  IF cur.id IS NOT NULL THEN
    UPDATE bms.flat_occupancy
       SET to_date = GREATEST(COALESCE(p_from, CURRENT_DATE) - 1, from_date),
           is_billed = false
     WHERE id = cur.id;
  END IF;

  INSERT INTO bms.flat_occupancy (flat_id, owner_id, relation_type, is_billed, from_date)
  VALUES (p_flat, v_person, 'OWNER', v_billed, COALESCE(p_from, CURRENT_DATE))
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- A tenant moves in.
--
-- The owner stays the owner. If the tenant is to pay (the usual case, and
-- the default), the bill moves to them; the owner's row is untouched apart
-- from no longer being the billed one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_flat_tenant(
    p_flat uuid, p_person uuid DEFAULT NULL,
    p_name text DEFAULT NULL, p_mobile text DEFAULT NULL,
    p_email text DEFAULT NULL, p_alt text DEFAULT NULL,
    p_from date DEFAULT CURRENT_DATE, p_billed boolean DEFAULT true)
RETURNS bms.flat_occupancy
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE cur bms.flat_occupancy; r bms.flat_occupancy; v_person uuid;
        v_billed boolean := COALESCE(p_billed, true);
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  PERFORM 1 FROM bms.flats WHERE id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;

  v_person := bms._person_for(p_person, p_name, p_mobile, p_email, p_alt);

  IF EXISTS (SELECT 1 FROM bms.flat_occupancy
              WHERE flat_id = p_flat AND relation_type = 'OWNER'
                AND to_date IS NULL AND owner_id = v_person) THEN
    RAISE EXCEPTION 'That person is the owner of this flat, so they cannot also be its tenant.';
  END IF;

  SELECT * INTO cur FROM bms.flat_occupancy
   WHERE flat_id = p_flat AND relation_type = 'TENANT' AND to_date IS NULL
   ORDER BY from_date DESC LIMIT 1;

  IF FOUND AND cur.owner_id = v_person THEN
    -- Same tenant: only the billing choice can have changed.
    PERFORM bms.set_billed_party(p_flat, CASE WHEN v_billed THEN 'TENANT' ELSE 'OWNER' END);
    SELECT * INTO r FROM bms.flat_occupancy WHERE id = cur.id;
    RETURN r;
  END IF;

  -- A flat with no owner on record has nobody else to bill.
  IF NOT v_billed AND NOT EXISTS (SELECT 1 FROM bms.flat_occupancy
       WHERE flat_id = p_flat AND relation_type = 'OWNER' AND to_date IS NULL) THEN
    v_billed := true;
  END IF;

  IF cur.id IS NOT NULL THEN
    UPDATE bms.flat_occupancy
       SET to_date = GREATEST(COALESCE(p_from, CURRENT_DATE) - 1, from_date),
           is_billed = false
     WHERE id = cur.id;
  END IF;

  IF v_billed THEN
    -- Release the bill first: at most one current billed row per flat is
    -- enforced by a unique index, checked row by row.
    UPDATE bms.flat_occupancy SET is_billed = false
     WHERE flat_id = p_flat AND to_date IS NULL AND is_billed;
  END IF;

  INSERT INTO bms.flat_occupancy (flat_id, owner_id, relation_type, is_billed, from_date)
  VALUES (p_flat, v_person, 'TENANT', v_billed, COALESCE(p_from, CURRENT_DATE))
  RETURNING * INTO r;

  -- Nobody billed is not a state a flat should be left in.
  IF NOT EXISTS (SELECT 1 FROM bms.flat_occupancy
                  WHERE flat_id = p_flat AND to_date IS NULL AND is_billed) THEN
    UPDATE bms.flat_occupancy SET is_billed = true WHERE id = r.id RETURNING * INTO r;
  END IF;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- The tenant moves out. The bill goes back to the owner.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.end_tenancy(p_flat uuid, p_to date DEFAULT CURRENT_DATE)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE cur bms.flat_occupancy;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  SELECT * INTO cur FROM bms.flat_occupancy
   WHERE flat_id = p_flat AND relation_type = 'TENANT' AND to_date IS NULL
   ORDER BY from_date DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'This flat has no current tenant'; END IF;

  UPDATE bms.flat_occupancy
     SET to_date = GREATEST(COALESCE(p_to, CURRENT_DATE), from_date), is_billed = false
   WHERE id = cur.id;

  IF NOT EXISTS (SELECT 1 FROM bms.flat_occupancy
                  WHERE flat_id = p_flat AND to_date IS NULL AND is_billed) THEN
    UPDATE bms.flat_occupancy SET is_billed = true
     WHERE id = (SELECT id FROM bms.flat_occupancy
                  WHERE flat_id = p_flat AND relation_type = 'OWNER' AND to_date IS NULL
                  ORDER BY from_date DESC LIMIT 1);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Change who pays, without anybody moving.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_billed_party(p_flat uuid, p_relation text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_target uuid;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  IF p_relation NOT IN ('OWNER','TENANT') THEN
    RAISE EXCEPTION 'Billed party must be OWNER or TENANT';
  END IF;
  SELECT id INTO v_target FROM bms.flat_occupancy
   WHERE flat_id = p_flat AND relation_type = p_relation AND to_date IS NULL
   ORDER BY from_date DESC LIMIT 1;
  IF v_target IS NULL THEN
    RAISE EXCEPTION 'This flat has no current %', lower(p_relation);
  END IF;
  UPDATE bms.flat_occupancy SET is_billed = false
   WHERE flat_id = p_flat AND to_date IS NULL AND is_billed AND id <> v_target;
  UPDATE bms.flat_occupancy SET is_billed = true WHERE id = v_target;
END $$;

REVOKE ALL ON FUNCTION bms.set_flat_owner(uuid,uuid,text,text,text,text,date)          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.set_flat_tenant(uuid,uuid,text,text,text,text,date,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.end_tenancy(uuid,date)                                      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.set_billed_party(uuid,text)                                 FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.set_flat_owner(uuid,uuid,text,text,text,text,date)          TO authenticated;
GRANT EXECUTE ON FUNCTION bms.set_flat_tenant(uuid,uuid,text,text,text,text,date,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.end_tenancy(uuid,date)                                      TO authenticated;
GRANT EXECUTE ON FUNCTION bms.set_billed_party(uuid,text)                                 TO authenticated;

-- =====================================================================
-- PART 2 — REMINDERS
-- =====================================================================

-- ---------------------------------------------------------------------
-- The wording. Three tones, two languages, all editable from Settings.
--
-- default_body is the wording as shipped, kept beside the edited one so
-- "Restore the original" always has something to restore. Re-running this
-- file refreshes default_body but NEVER touches body: running an update
-- must not quietly throw away wording someone spent an evening on.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.reminder_templates (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tone          text NOT NULL CHECK (tone IN ('GENTLE','FOLLOW_UP','FIRM')),
  lang          text NOT NULL CHECK (lang IN ('en','bn')),
  body          text NOT NULL CHECK (length(btrim(body)) > 0 AND length(body) <= 2000),
  default_body  text NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid REFERENCES auth.users(id),
  UNIQUE (tone, lang)
);

INSERT INTO bms.reminder_templates (tone, lang, body, default_body)
SELECT tone, lang, txt, txt FROM (VALUES
('GENTLE','en', $t$Dear {name},
A gentle reminder from {building} management: the service charge for Flat {flat} is due.

Amount due: Tk {amount} ({months})

If you have already paid, please ignore this message. Otherwise, we would be grateful if you could pay at your convenience.
{how_to_pay}

Thank you for your cooperation.
— {building} Management$t$),
('GENTLE','bn', $t$সম্মানিত {name},
{building} ব্যবস্থাপনা কমিটির পক্ষ থেকে বিনীত অনুস্মারক: ফ্ল্যাট {flat}-এর সার্ভিস চার্জ বকেয়া রয়েছে।

বকেয়া: {amount} টাকা ({months})

ইতোমধ্যে পরিশোধ করে থাকলে এই বার্তাটি উপেক্ষা করুন। অন্যথায় সুবিধামতো সময়ে পরিশোধ করলে কৃতজ্ঞ থাকব।
{how_to_pay}

আপনার সহযোগিতার জন্য ধন্যবাদ।
— {building} ব্যবস্থাপনা কমিটি$t$),
('FOLLOW_UP','en', $t$Dear {name},
Following up on our earlier reminder, the service charge for Flat {flat} is still outstanding.

Outstanding: Tk {amount} ({months})

We would be grateful if you could clear it at your earliest convenience. If anything is making this difficult, please let us know; we are happy to talk it through.
{how_to_pay}

Thank you.
— {building} Management$t$),
('FOLLOW_UP','bn', $t$সম্মানিত {name},
আগের বার্তার ধারাবাহিকতায় জানাচ্ছি যে, ফ্ল্যাট {flat}-এর সার্ভিস চার্জ এখনো বকেয়া রয়েছে।

বকেয়া: {amount} টাকা ({months})

যত দ্রুত সম্ভব পরিশোধ করলে কৃতজ্ঞ থাকব। কোনো অসুবিধা থাকলে অনুগ্রহ করে জানাবেন — আমরা আলোচনা করতে আগ্রহী।
{how_to_pay}

ধন্যবাদ।
— {building} ব্যবস্থাপনা কমিটি$t$),
('FIRM','en', $t$Dear {name},
Despite our previous reminders, the service charge for Flat {flat} remains outstanding.

Outstanding: Tk {amount} ({months})

This charge pays for what every resident shares: security, cleaning, the lift, the generator and utilities. We kindly ask you to settle it by {deadline}, or contact the management to arrange payment in instalments.
{how_to_pay}

Thank you for your understanding.
— {building} Management$t$),
('FIRM','bn', $t$সম্মানিত {name},
একাধিকবার স্মরণ করিয়ে দেওয়ার পরও ফ্ল্যাট {flat}-এর সার্ভিস চার্জ এখনো বকেয়া রয়েছে।

বকেয়া: {amount} টাকা ({months})

এই চার্জ থেকেই ভবনের সকলের সাধারণ খরচ — নিরাপত্তা, পরিচ্ছন্নতা, লিফট, জেনারেটর ও ইউটিলিটি — বহন করা হয়। অনুগ্রহ করে {deadline}-এর মধ্যে পরিশোধ করুন, অথবা কিস্তিতে পরিশোধের জন্য ব্যবস্থাপনা কমিটির সাথে যোগাযোগ করুন।
{how_to_pay}

আপনার সহযোগিতার জন্য ধন্যবাদ।
— {building} ব্যবস্থাপনা কমিটি$t$)
) AS v(tone, lang, txt)
ON CONFLICT (tone, lang) DO UPDATE SET default_body = EXCLUDED.default_body;

CREATE OR REPLACE FUNCTION bms.reminder_template_touch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  -- Only the stamp. Which columns a user may change is decided by the
  -- column-level grant below (body and nothing else); a trigger doing the
  -- same job would also stop this file refreshing default_body whenever
  -- the session happened to carry a user id.
  NEW.updated_at := now();
  NEW.updated_by := COALESCE(auth.uid(), NEW.updated_by);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_reminder_template_touch ON bms.reminder_templates;
CREATE TRIGGER trg_reminder_template_touch BEFORE UPDATE ON bms.reminder_templates
  FOR EACH ROW EXECUTE FUNCTION bms.reminder_template_touch();

ALTER TABLE bms.reminder_templates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.reminder_templates FROM PUBLIC, anon;
GRANT SELECT ON bms.reminder_templates TO authenticated;
GRANT UPDATE (body) ON bms.reminder_templates TO authenticated;
DROP POLICY IF EXISTS reminder_templates_sel ON bms.reminder_templates;
DROP POLICY IF EXISTS reminder_templates_upd ON bms.reminder_templates;
CREATE POLICY reminder_templates_sel ON bms.reminder_templates FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view') OR bms.has_perm('settings','view'));
CREATE POLICY reminder_templates_upd ON bms.reminder_templates FOR UPDATE TO authenticated
  USING (bms.has_perm('settings','edit')) WITH CHECK (bms.has_perm('settings','edit'));

DROP TRIGGER IF EXISTS trg_audit_reminder_templates ON bms.reminder_templates;
CREATE TRIGGER trg_audit_reminder_templates AFTER INSERT OR UPDATE OR DELETE ON bms.reminder_templates
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('settings', 'tone', 'LOW');

-- ---------------------------------------------------------------------
-- The log.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.charge_reminders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_id         uuid NOT NULL REFERENCES bms.flats(id),
  sent_at         timestamptz NOT NULL DEFAULT now(),
  sent_by         uuid REFERENCES auth.users(id),
  channel         text NOT NULL CHECK (channel IN ('WHATSAPP','SMS','COPY')),
  tone            text NOT NULL CHECK (tone IN ('GENTLE','FOLLOW_UP','FIRM')),
  lang            text NOT NULL CHECK (lang IN ('en','bn')),
  -- Who was asked, as they were at that moment. If the tenant changes or
  -- the number is corrected later, the record still says who was chased.
  recipient_name  text,
  relation        text CHECK (relation IN ('OWNER','TENANT')),
  phone           text,
  phone_sent      text,
  amount_due      bms.money_amount NOT NULL,
  months          text,
  message         text NOT NULL CHECK (length(message) <= 4000)
);
CREATE INDEX IF NOT EXISTS charge_reminders_flat_idx ON bms.charge_reminders (flat_id, sent_at DESC);

ALTER TABLE bms.charge_reminders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.charge_reminders FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.charge_reminders TO authenticated;
DROP POLICY IF EXISTS charge_reminders_sel ON bms.charge_reminders;
CREATE POLICY charge_reminders_sel ON bms.charge_reminders FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view'));

-- Never edited; deleted only by the system reset (block_delete() stands
-- aside for bms.purge and for nothing else).
CREATE OR REPLACE FUNCTION bms.block_reminder_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'A reminder, once recorded, cannot be changed' USING ERRCODE = '42501';
END $$;
DROP TRIGGER IF EXISTS trg_reminders_no_update ON bms.charge_reminders;
CREATE TRIGGER trg_reminders_no_update BEFORE UPDATE ON bms.charge_reminders
  FOR EACH ROW EXECUTE FUNCTION bms.block_reminder_update();
DROP TRIGGER IF EXISTS trg_reminders_no_delete ON bms.charge_reminders;
CREATE TRIGGER trg_reminders_no_delete BEFORE DELETE ON bms.charge_reminders
  FOR EACH ROW EXECUTE FUNCTION bms.block_delete();

-- One row per flat: how many times it has been chased, and how many of
-- those since it last paid — the number that decides the tone.
CREATE OR REPLACE VIEW bms.v_flat_reminders WITH (security_invoker = true) AS
WITH last_pay AS (
  SELECT flat_id, MAX(created_at) AS last_paid_at
    FROM bms.payments WHERE status = 'ACTIVE' GROUP BY flat_id
)
SELECT r.flat_id,
       COUNT(*)::int AS reminders_total,
       COUNT(*) FILTER (WHERE lp.last_paid_at IS NULL OR r.sent_at > lp.last_paid_at)::int
                     AS reminders_since_payment,
       MAX(r.sent_at) AS last_reminded_at
  FROM bms.charge_reminders r
  LEFT JOIN last_pay lp ON lp.flat_id = r.flat_id
 GROUP BY r.flat_id;
REVOKE ALL ON bms.v_flat_reminders FROM PUBLIC, anon;
GRANT SELECT ON bms.v_flat_reminders TO authenticated;

-- ---------------------------------------------------------------------
-- Everything the reminder screen needs, read fresh at the moment it opens.
--
-- Fresh matters: a list loaded an hour ago can still show a flat as unpaid
-- after someone has recorded its payment, and sending a payment reminder
-- to a person who has just paid is the one mistake this feature must not
-- make. So the figures come from here, now, not from the table on screen.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.reminder_context(p_flat uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE d record; ppl record; s bms.building_settings; rm record;
        v_since int; v_tone text; v_months jsonb; v_tpl jsonb;
        v_name text; v_mobile text; v_rel text;
BEGIN
  PERFORM bms.assert_perm('charges','view');

  SELECT * INTO d FROM bms.v_flat_dues WHERE flat_id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;
  SELECT * INTO ppl FROM bms.v_flat_people WHERE flat_id = p_flat;
  SELECT * INTO s FROM bms.building_settings WHERE id;
  SELECT * INTO rm FROM bms.v_flat_reminders WHERE flat_id = p_flat;

  v_rel    := ppl.billed_relation;
  v_name   := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_name   WHEN 'OWNER' THEN ppl.owner_name   END;
  v_mobile := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_mobile WHEN 'OWNER' THEN ppl.owner_mobile END;

  v_since := COALESCE(rm.reminders_since_payment, 0);
  v_tone  := CASE WHEN v_since = 0 THEN 'GENTLE' WHEN v_since = 1 THEN 'FOLLOW_UP' ELSE 'FIRM' END;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'year', period_year, 'month', period_month,
           'source', charge_source, 'due', due_amount)
           ORDER BY period_year, period_month), '[]'::jsonb)
    INTO v_months
    FROM bms.v_flat_charges
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED');

  SELECT COALESCE(jsonb_object_agg(tone || '.' || lang, body), '{}'::jsonb)
    INTO v_tpl FROM bms.reminder_templates;

  RETURN jsonb_build_object(
    'flat_id', p_flat, 'flat_number', d.flat_number,
    'outstanding', d.outstanding, 'advance', d.advance,
    'last_payment_date', d.last_payment_date,
    'recipient_name', v_name, 'relation', v_rel,
    'mobile', v_mobile, 'mobile_wa', bms.normalize_mobile(v_mobile),
    'months', v_months,
    'reminders_total', COALESCE(rm.reminders_total, 0),
    'reminders_since_payment', v_since,
    'last_reminded_at', rm.last_reminded_at,
    'suggested_tone', v_tone,
    'building_name', s.building_name,
    'how_to_pay', s.reminder_how_to_pay,
    'language', COALESCE(s.reminder_language, 'en'),
    'deadline_date', CURRENT_DATE + COALESCE(s.reminder_deadline_days, 7),
    'templates', v_tpl,
    'can_send', bms.has_perm('charges','add'));
END $$;

-- ---------------------------------------------------------------------
-- Record a reminder. Called as the message is handed to WhatsApp.
--
-- The amount is re-read here, not taken from the screen, and a flat that
-- owes nothing is refused: better a refused record than a log that says
-- someone was chased for money they did not owe.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.log_charge_reminder(
    p_flat uuid, p_channel text, p_tone text, p_lang text, p_message text)
RETURNS bms.charge_reminders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE d record; ppl record; r bms.charge_reminders; v_months text;
        v_name text; v_mobile text; v_rel text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_channel NOT IN ('WHATSAPP','SMS','COPY') THEN RAISE EXCEPTION 'Unknown channel %', p_channel; END IF;
  IF p_tone NOT IN ('GENTLE','FOLLOW_UP','FIRM') THEN RAISE EXCEPTION 'Unknown tone %', p_tone; END IF;
  IF p_lang NOT IN ('en','bn') THEN RAISE EXCEPTION 'Unknown language %', p_lang; END IF;
  IF COALESCE(btrim(p_message), '') = '' THEN RAISE EXCEPTION 'The message is empty'; END IF;

  SELECT * INTO d FROM bms.v_flat_dues WHERE flat_id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;
  IF COALESCE(d.outstanding, 0) <= 0 THEN
    RAISE EXCEPTION 'Flat % owes nothing now, so no reminder was recorded.', d.flat_number
      USING ERRCODE = '23514';
  END IF;

  SELECT * INTO ppl FROM bms.v_flat_people WHERE flat_id = p_flat;
  v_rel    := ppl.billed_relation;
  v_name   := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_name   WHEN 'OWNER' THEN ppl.owner_name   END;
  v_mobile := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_mobile WHEN 'OWNER' THEN ppl.owner_mobile END;

  SELECT string_agg(CASE WHEN charge_source = 'OPENING' THEN 'earlier balance'
                         ELSE to_char(make_date(period_year, period_month, 1), 'Mon YYYY') END,
                    ', ' ORDER BY period_year, period_month)
    INTO v_months
    FROM bms.v_flat_charges
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED');

  INSERT INTO bms.charge_reminders (flat_id, sent_by, channel, tone, lang,
                                    recipient_name, relation, phone, phone_sent,
                                    amount_due, months, message)
  VALUES (p_flat, auth.uid(), p_channel, p_tone, p_lang,
          v_name, v_rel, v_mobile, bms.normalize_mobile(v_mobile),
          d.outstanding, v_months, left(p_message, 4000))
  RETURNING * INTO r;
  RETURN r;
END $$;

REVOKE ALL ON FUNCTION bms.normalize_mobile(text)                         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.reminder_context(uuid)                         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text)  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.normalize_mobile(text)                        TO authenticated;
GRANT EXECUTE ON FUNCTION bms.reminder_context(uuid)                        TO authenticated;
GRANT EXECUTE ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) TO authenticated;

-- END 085_people_reminders.sql


-- =====================================================================
-- BEGIN 086_reports_funds.sql
-- =====================================================================

-- =====================================================================
-- 086_reports_funds.sql — the monthly report, and funds that can pay.
--
-- PART 1 — FUNDS THAT PAY FOR THINGS DIRECTLY
-- -------------------------------------------
-- Until now money could leave a fund only by moving to another of our
-- own accounts (a transfer). Real reserves are spent: the lift motor is
-- paid for straight out of the reserve account, and the LPG emergency
-- fund buys a cylinder and is refilled from the next LPG collection.
-- Doing that took two separate entries — an expense in Finance and an
-- earmark withdrawal here — which is exactly the kind of pair that gets
-- half-entered. record_fund_movement can now do both in one step:
-- given a category, a withdrawal becomes a real EXPENSE out of the
-- chosen account and a contribution a real INCOME into it, tied to the
-- fund movement that explains it.
--
-- PART 2 — THE MONTHLY REPORT
-- ---------------------------
-- The figures a finance controller prints and files every month, each
-- computed here so the printed page, the Excel file and the dashboard
-- agree to the taka:
--   report_income_expense   income and expense by department and category
--   report_accounts         every account: opening, money in, money out, closing
--   report_funds            every fund: opening, added, used, closing
--   report_service_charge   billed, collected, collection %, outstanding
-- All read-only, all behind reports.view.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- PART 1
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS bms.record_fund_movement(uuid, date, text, bms.money_amount, boolean, uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION bms.record_fund_movement(
    p_fund uuid, p_date date, p_direction text, p_amount bms.money_amount,
    p_cash_backed boolean DEFAULT false,
    p_from_account uuid DEFAULT NULL, p_to_account uuid DEFAULT NULL,
    p_purpose text DEFAULT NULL, p_notes text DEFAULT NULL,
    p_category uuid DEFAULT NULL, p_method text DEFAULT NULL, p_vendor uuid DEFAULT NULL)
RETURNS bms.fund_movements
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE mv bms.fund_movements; t bms.transactions; f bms.funds; c bms.categories;
        v_balance numeric(14,2); v_dir text; v_account uuid; v_desc text;
BEGIN
  PERFORM bms.assert_perm('reserve','add');
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;

  SELECT * INTO f FROM bms.funds WHERE id = p_fund;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fund not found'; END IF;

  -- You cannot take out more than the fund holds.
  IF p_direction IN ('WITHDRAWAL','TRANSFER_OUT') THEN
    SELECT current_balance INTO v_balance FROM bms.v_fund_balances WHERE fund_id = p_fund;
    IF p_amount > COALESCE(v_balance, 0) THEN
      RAISE EXCEPTION 'The fund only holds %, so % cannot be taken out',
        COALESCE(v_balance,0), p_amount;
    END IF;
  END IF;

  v_desc := format('%s — %s', f.name, COALESCE(NULLIF(btrim(p_purpose),''),
              CASE p_direction WHEN 'CONTRIBUTION' THEN 'reserve contribution'
                               WHEN 'WITHDRAWAL'   THEN 'reserve withdrawal'
                               ELSE lower(replace(p_direction,'_',' ')) END));

  IF p_cash_backed AND p_category IS NOT NULL THEN
    -- Paid straight out of the fund, or received straight into it.
    IF p_direction NOT IN ('CONTRIBUTION','WITHDRAWAL') THEN
      RAISE EXCEPTION 'Only money put in or taken out can be booked as income or expense';
    END IF;
    PERFORM bms.assert_perm('finance','add');
    SELECT * INTO c FROM bms.categories WHERE id = p_category;
    IF NOT FOUND THEN RAISE EXCEPTION 'Category not found'; END IF;
    v_dir     := CASE p_direction WHEN 'WITHDRAWAL' THEN 'EXPENSE' ELSE 'INCOME' END;
    v_account := CASE p_direction WHEN 'WITHDRAWAL' THEN p_from_account ELSE p_to_account END;
    IF v_account IS NULL THEN
      RAISE EXCEPTION '%', CASE v_dir WHEN 'EXPENSE' THEN 'Say which account the money was paid from'
                                      ELSE 'Say which account the money was received into' END;
    END IF;
    IF c.txn_type NOT IN (v_dir, 'BOTH') THEN
      RAISE EXCEPTION 'The category "%" is for %, not %', c.name, lower(c.txn_type), lower(v_dir);
    END IF;
    t := bms.create_transaction(
          p_date, v_dir, c.department_id, c.id, v_desc, p_amount,
          COALESCE(p_method, 'CASH'), v_account, NULL,
          p_vendor, NULL, NULL, p_notes, true, 'reserve', p_fund);

  ELSIF p_cash_backed AND p_direction <> 'INTEREST' THEN
    -- Moved between two of our own accounts.
    IF p_from_account IS NULL OR p_to_account IS NULL THEN
      RAISE EXCEPTION 'A cash-backed movement needs the account it comes from and the account it goes to';
    END IF;
    IF p_from_account = p_to_account THEN
      RAISE EXCEPTION 'A transfer needs two different accounts';
    END IF;
    t := bms.create_transaction(
          p_date, 'TRANSFER', NULL, NULL, v_desc,
          p_amount, 'BANK_TRANSFER', p_from_account, p_to_account,
          NULL, NULL, NULL, p_notes, true, 'reserve', p_fund);
  END IF;

  INSERT INTO bms.fund_movements(fund_id, movement_date, direction, amount,
                                 is_cash_movement, txn_id, purpose, notes, created_by)
  VALUES (p_fund, p_date, p_direction, p_amount, p_cash_backed, t.id, p_purpose, p_notes, auth.uid())
  RETURNING * INTO mv;
  RETURN mv;
END $$;

REVOKE ALL ON FUNCTION bms.record_fund_movement(uuid,date,text,bms.money_amount,boolean,uuid,uuid,text,text,uuid,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.record_fund_movement(uuid,date,text,bms.money_amount,boolean,uuid,uuid,text,text,uuid,text,uuid) TO authenticated;

-- A fund with no account of its own is backed by the cash moved for it.
-- Now that a fund can pay for things directly, that net can go below
-- zero (the money came out of the general account), and a fund cannot
-- hold less than nothing. Same view as 042, with that one floor.
CREATE OR REPLACE VIEW bms.v_fund_balances WITH (security_invoker = true) AS
WITH mv AS (
  SELECT fund_id,
         SUM(CASE WHEN direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN')
                  THEN amount ELSE -amount END)::numeric(14,2) AS movement,
         SUM(CASE WHEN is_cash_movement
                  THEN CASE WHEN direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN')
                            THEN amount ELSE -amount END
                  ELSE 0 END)::numeric(14,2) AS cash_movement,
         MAX(movement_date) AS last_movement
    FROM bms.fund_movements GROUP BY fund_id
)
, bal AS (
  SELECT f.id AS fund_id,
         (f.opening_balance + COALESCE(mv.movement, 0))::numeric(14,2) AS current_balance,
         COALESCE((SELECT SUM(fd.principal) FROM bms.fixed_deposits fd
                    WHERE fd.fund_id = f.id AND fd.status = 'ACTIVE'), 0)::numeric(14,2)
           AS held_in_deposits,
         CASE WHEN f.account_id IS NOT NULL
              THEN COALESCE((SELECT ab.current_balance FROM bms.v_account_balances ab
                              WHERE ab.account_id = f.account_id), 0)
              -- Money paid straight out of a fund with no account of its
              -- own came from the general account; it cannot leave the
              -- fund holding less than nothing.
              ELSE GREATEST(COALESCE(mv.cash_movement, 0), 0)
         END::numeric(14,2) AS held_in_account
    FROM bms.funds f
    LEFT JOIN mv ON mv.fund_id = f.id
)
SELECT f.id AS fund_id, f.code, f.name, f.fund_type, f.purpose,
       f.opening_balance, f.target_amount, f.target_date, f.account_id, f.is_active,
       COALESCE(mv.movement, 0)                                   AS movement,
       b.current_balance,
       b.held_in_deposits,
       b.held_in_account,
       (b.held_in_deposits + b.held_in_account)::numeric(14,2)    AS funded_amount,
       GREATEST(b.current_balance - b.held_in_deposits - b.held_in_account, 0)::numeric(14,2)
            AS unfunded_amount,
       (b.held_in_deposits + b.held_in_account >= b.current_balance) AS is_funded,
       mv.last_movement,
       CASE WHEN f.target_amount > 0
            THEN LEAST(100, ROUND(b.current_balance * 100.0 / f.target_amount, 1))
       END AS progress_pct,
       GREATEST(f.target_amount - b.current_balance, 0)::numeric(14,2) AS remaining_required
  FROM bms.funds f
  JOIN bal b ON b.fund_id = f.id
  LEFT JOIN mv ON mv.fund_id = f.id;


-- ---------------------------------------------------------------------
-- PART 2 — the monthly report
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms._report_range(p_from date, p_to date) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_from IS NULL OR p_to IS NULL THEN RAISE EXCEPTION 'A report needs a start and an end date'; END IF;
  IF p_to < p_from THEN RAISE EXCEPTION 'The end date is before the start date'; END IF;
END $$;

-- Income and expense, one row per department and category. Same rule as
-- every other total: posted, not a transfer, not reversed.
CREATE OR REPLACE FUNCTION bms.report_income_expense(p_from date, p_to date)
RETURNS TABLE (direction text, department_id uuid, department_name text, department_sort int,
               category_id uuid, category_name text, entries bigint, amount numeric(14,2))
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('reports','view');
  PERFORM bms._report_range(p_from, p_to);
  RETURN QUERY
  SELECT t.direction, t.department_id,
         COALESCE(d.name, 'Unclassified'), COALESCE(d.sort_order, 9999),
         t.category_id, COALESCE(c.name, 'Uncategorised'),
         COUNT(*), SUM(t.amount)::numeric(14,2)
    FROM bms.transactions t
    LEFT JOIN bms.departments d ON d.id = t.department_id
    LEFT JOIN bms.categories  c ON c.id = t.category_id
   WHERE t.status = 'POSTED' AND t.direction IN ('INCOME','EXPENSE')
     AND NOT t.is_reversal AND t.reversed_by_txn_id IS NULL
     AND t.txn_date BETWEEN p_from AND p_to
   GROUP BY t.direction, t.department_id, d.name, d.sort_order, t.category_id, c.name
   ORDER BY t.direction DESC, COALESCE(d.sort_order, 9999), COALESCE(d.name,'Unclassified'),
            SUM(t.amount) DESC;
END $$;

-- Every account over the period. Opening and closing follow the same
-- rule as v_account_balances (opening balance + ledger), so the closing
-- figure of a report that ends today is the balance on the dashboard.
CREATE OR REPLACE FUNCTION bms.report_accounts(p_from date, p_to date)
RETURNS TABLE (account_id uuid, code text, name text, kind text, is_active boolean,
               opening numeric(14,2), money_in numeric(14,2), money_out numeric(14,2),
               closing numeric(14,2))
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('reports','view');
  PERFORM bms._report_range(p_from, p_to);
  RETURN QUERY
  WITH le AS (
    SELECT l.account_id,
           SUM(l.signed_amount) FILTER (WHERE l.entry_date <  p_from)                         AS before,
           SUM(l.signed_amount) FILTER (WHERE l.entry_date BETWEEN p_from AND p_to AND l.signed_amount > 0) AS ins,
           -SUM(l.signed_amount) FILTER (WHERE l.entry_date BETWEEN p_from AND p_to AND l.signed_amount < 0) AS outs
      FROM bms.ledger_entries l
     WHERE l.entry_date <= p_to
     GROUP BY l.account_id
  )
  SELECT a.id, a.code, a.name, a.kind, a.is_active,
         (CASE WHEN a.opening_date <= p_to THEN a.opening_balance ELSE 0 END + COALESCE(le.before,0))::numeric(14,2),
         COALESCE(le.ins, 0)::numeric(14,2),
         COALESCE(le.outs, 0)::numeric(14,2),
         (CASE WHEN a.opening_date <= p_to THEN a.opening_balance ELSE 0 END
            + COALESCE(le.before,0) + COALESCE(le.ins,0) - COALESCE(le.outs,0))::numeric(14,2)
    FROM bms.accounts a
    LEFT JOIN le ON le.account_id = a.id
   WHERE a.is_active OR le.account_id IS NOT NULL
   ORDER BY CASE a.kind WHEN 'BANK' THEN 1 WHEN 'MOBILE_WALLET' THEN 2 WHEN 'CASH' THEN 3 ELSE 4 END, a.name;
END $$;

-- Every fund over the period: the earmark at the start, what was added,
-- what was used, the earmark at the end — and, for today, whether the
-- money behind it is really there.
CREATE OR REPLACE FUNCTION bms.report_funds(p_from date, p_to date)
RETURNS TABLE (fund_id uuid, code text, name text, fund_type text, purpose text,
               opening numeric(14,2), added numeric(14,2), used numeric(14,2),
               closing numeric(14,2), target_amount numeric(14,2),
               funded_now numeric(14,2), is_funded_now boolean, is_active boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('reports','view');
  PERFORM bms._report_range(p_from, p_to);
  RETURN QUERY
  WITH m AS (
    SELECT fm.fund_id,
           SUM(CASE WHEN fm.direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN') THEN fm.amount ELSE -fm.amount END)
             FILTER (WHERE fm.movement_date < p_from) AS before,
           SUM(fm.amount) FILTER (WHERE fm.movement_date BETWEEN p_from AND p_to
                                    AND fm.direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN')) AS added,
           SUM(fm.amount) FILTER (WHERE fm.movement_date BETWEEN p_from AND p_to
                                    AND fm.direction IN ('WITHDRAWAL','TRANSFER_OUT')) AS used
      FROM bms.fund_movements fm
     WHERE fm.movement_date <= p_to
     GROUP BY fm.fund_id
  )
  SELECT f.id, f.code, f.name, f.fund_type, f.purpose,
         (CASE WHEN f.opening_date <= p_to THEN f.opening_balance ELSE 0 END + COALESCE(m.before,0))::numeric(14,2),
         COALESCE(m.added,0)::numeric(14,2),
         COALESCE(m.used,0)::numeric(14,2),
         (CASE WHEN f.opening_date <= p_to THEN f.opening_balance ELSE 0 END
            + COALESCE(m.before,0) + COALESCE(m.added,0) - COALESCE(m.used,0))::numeric(14,2),
         f.target_amount::numeric(14,2),
         fb.funded_amount, fb.is_funded, f.is_active
    FROM bms.funds f
    LEFT JOIN m ON m.fund_id = f.id
    LEFT JOIN bms.v_fund_balances fb ON fb.fund_id = f.id
   WHERE f.is_active OR m.fund_id IS NOT NULL
   ORDER BY f.code;
END $$;

-- Service charge over the period. "Billed" is what was charged for the
-- months that fall in the period; "collected against it" is what has been
-- paid of those charges so far; "received" is cash that arrived in the
-- period, whatever month it paid for.
CREATE OR REPLACE FUNCTION bms.report_service_charge(p_from date, p_to date)
RETURNS TABLE (billed numeric(14,2), paid_against_billed numeric(14,2), collection_pct numeric(6,1),
               received_in_period numeric(14,2), receipts_in_period bigint,
               flat_months bigint, paid_full bigint, paid_partial bigint, unpaid bigint,
               outstanding_now numeric(14,2), advance_now numeric(14,2), flats_owing_now bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('reports','view');
  PERFORM bms._report_range(p_from, p_to);
  RETURN QUERY
  WITH ch AS (
    SELECT fc.net_payable, COALESCE(pa.paid, 0) AS paid
      FROM bms.flat_charges fc
      LEFT JOIN (SELECT flat_charge_id, SUM(amount) AS paid
                   FROM bms.payment_allocations GROUP BY flat_charge_id) pa ON pa.flat_charge_id = fc.id
     WHERE NOT fc.is_cancelled AND fc.charge_source <> 'OPENING'
       AND make_date(fc.period_year, fc.period_month, 1) BETWEEN date_trunc('month', p_from)::date AND p_to
  ), rc AS (
    SELECT COALESCE(SUM(p.amount),0) AS amt, COUNT(*) AS n
      FROM bms.payments p
     WHERE p.status = 'ACTIVE' AND p.payment_date BETWEEN p_from AND p_to
  ), du AS (
    SELECT COALESCE(SUM(outstanding),0) AS o, COALESCE(SUM(advance),0) AS a,
           COUNT(*) FILTER (WHERE outstanding > 0) AS n
      FROM bms.v_flat_dues
  )
  SELECT COALESCE(SUM(ch.net_payable),0)::numeric(14,2),
         COALESCE(SUM(LEAST(ch.paid, ch.net_payable)),0)::numeric(14,2),
         CASE WHEN COALESCE(SUM(ch.net_payable),0) > 0
              THEN ROUND(SUM(LEAST(ch.paid, ch.net_payable)) * 100.0 / SUM(ch.net_payable), 1)
              ELSE 0 END::numeric(6,1),
         (SELECT amt FROM rc)::numeric(14,2), (SELECT n FROM rc),
         COUNT(ch.*), COUNT(*) FILTER (WHERE ch.paid >= ch.net_payable),
         COUNT(*) FILTER (WHERE ch.paid > 0 AND ch.paid < ch.net_payable),
         COUNT(*) FILTER (WHERE ch.paid = 0 AND ch.net_payable > 0),
         (SELECT o FROM du)::numeric(14,2), (SELECT a FROM du)::numeric(14,2), (SELECT n FROM du)
    FROM ch;
END $$;

REVOKE ALL ON FUNCTION bms._report_range(date,date)           FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.report_income_expense(date,date)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.report_accounts(date,date)         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.report_funds(date,date)            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.report_service_charge(date,date)   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms._report_range(date,date)          TO authenticated;
GRANT EXECUTE ON FUNCTION bms.report_income_expense(date,date)  TO authenticated;
GRANT EXECUTE ON FUNCTION bms.report_accounts(date,date)        TO authenticated;
GRANT EXECUTE ON FUNCTION bms.report_funds(date,date)           TO authenticated;
GRANT EXECUTE ON FUNCTION bms.report_service_charge(date,date)  TO authenticated;

-- ---------------------------------------------------------------------
-- PART 3 — an LPG department, asked for by the building.
--
-- LPG billing stays in the separate LPG Ledger app. What lives here is
-- only the LPG emergency money: the balance kept to buy a cylinder before
-- the month's meter collection comes in, and refilled from it. Its own
-- department keeps those entries in a line of their own on every report
-- instead of mixed into the building's running costs. Seeded once; it is
-- ordinary data afterwards — rename it, hide it, or add to it in Settings.
-- ---------------------------------------------------------------------
INSERT INTO bms.departments (code, name, sort_order)
VALUES ('LPG', 'LPG fund', 115)
ON CONFLICT (code) DO NOTHING;

-- The first wording ("emergency fund", "repaid") made the fund sound like
-- a loan. It is a standing LPG fund: it buys the cylinder, and the flats'
-- meter bills fill it up again. Bring the original names up to date —
-- only where they are still the original names, so a name the building
-- chose in Settings is never overwritten.
UPDATE bms.departments SET name = 'LPG fund'
 WHERE code = 'LPG' AND name = 'LPG (emergency fund)';
UPDATE bms.categories c SET name = v.new_name
  FROM (VALUES ('Cylinder bought from the emergency fund',   'LPG cylinder bought from LPG fund'),
               ('Emergency fund repaid from LPG collection', 'LPG fund refilled from meter bill collection'))
       AS v(old_name, new_name),
       bms.departments d
 WHERE d.code = 'LPG' AND c.department_id = d.id AND c.parent_id IS NULL AND c.name = v.old_name;

-- One expense and one income category — seeded only if the department
-- has none of that kind yet, so renaming one never brings a duplicate back.
INSERT INTO bms.categories (department_id, name, txn_type, sort_order)
SELECT d.id, v.name, v.txn_type, v.sort_order
  FROM bms.departments d
  CROSS JOIN (VALUES
    ('LPG cylinder bought from LPG fund',            'EXPENSE', 10),
    ('LPG fund refilled from meter bill collection', 'INCOME',  20)
  ) AS v(name, txn_type, sort_order)
 WHERE d.code = 'LPG'
   AND NOT EXISTS (SELECT 1 FROM bms.categories c
                    WHERE c.department_id = d.id AND c.txn_type = v.txn_type AND c.parent_id IS NULL);

-- END 086_reports_funds.sql


-- =====================================================================
-- BEGIN 087_community_backup.sql
-- =====================================================================

-- =====================================================================
-- 087_community_backup.sql — the building's committee, its rules, and
-- a record of every backup taken.
--
-- PART 1 — COMMITTEE & RULES (module "community")
-- -----------------------------------------------
-- Who runs the building (chairman, vice chairman, secretaries, finance,
-- advisors, operations — any position, any order, with a photo), and the
-- rules they run it by: the constitution, building rules, committee
-- decisions, notices and forms. Readable by every signed-in person whose
-- role includes "Committee & Rules", which by default is every role; a
-- new read-only Resident role gives a flat owner or tenant exactly this
-- and nothing else.
--
-- Photos are kept in the row itself, shrunk to a small JPEG (about 30–60
-- KB) by the app. A committee is a dozen faces: storing them inline means
-- no storage bucket to set up, nothing to sign, and the backup carries
-- them. Rule documents can be long PDFs, so those go to the private
-- bms-documents bucket under community/, readable by anyone who may see
-- the rules.
--
-- PART 2 — BACKUP LOG
-- -------------------
-- The Excel backup is made in the browser; this records that it was
-- made — when, by whom, for which dates, how many rows — so the app can
-- say "last backup 34 days ago" and nobody has to remember.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Module, permissions, grants.
-- ---------------------------------------------------------------------
INSERT INTO bms.modules (code, name, icon, sort_order, phase, is_enabled)
VALUES ('community', 'Committee & Rules', 'people', 15, 5, true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO bms.permissions (module_code, action)
SELECT 'community', a FROM unnest(ARRAY['view','add','edit','cancel','export']) a
ON CONFLICT (module_code, action) DO NOTHING;

-- A role for residents: the committee and the rules, nothing about money.
INSERT INTO bms.roles (code, name, description, is_system, is_superuser, approve_limit, auto_post_limit, sort_order)
VALUES ('RESIDENT', 'Resident', 'Flat owners and tenants: sees the committee and the building rules only.',
        true, false, 0, 0, 80)
ON CONFLICT (code) DO NOTHING;

-- Admin manages it; every other built-in role reads it. (Granted once:
-- re-running this file never re-adds a permission someone took away.)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM bms.role_permissions rp JOIN bms.permissions p ON p.id = rp.permission_id
                  WHERE p.module_code = 'community') THEN
    INSERT INTO bms.role_permissions (role_id, permission_id)
    SELECT r.id, p.id FROM bms.roles r JOIN bms.permissions p ON p.module_code = 'community'
     WHERE r.code = 'ADMIN'
        OR (r.code IN ('FINANCE_MANAGER','MANAGER','CARETAKER','COMMITTEE','AUDITOR','RESIDENT') AND p.action = 'view')
    ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- The committee's heading: its name, its term, a line of introduction.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.committee_info (
  id          boolean PRIMARY KEY DEFAULT true CHECK (id),
  title       text NOT NULL DEFAULT 'Management Committee' CHECK (length(btrim(title)) BETWEEN 1 AND 120),
  term        text CHECK (term IS NULL OR length(term) <= 60),
  intro       text CHECK (intro IS NULL OR length(intro) <= 1000),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id)
);
INSERT INTO bms.committee_info (id) VALUES (true) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS bms.board_members (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  position    text NOT NULL CHECK (length(btrim(position)) BETWEEN 1 AND 80),
  sort_order  int  NOT NULL DEFAULT 100,
  flat_id     uuid REFERENCES bms.flats(id) ON DELETE SET NULL,
  phone       text CHECK (phone IS NULL OR length(phone) <= 40),
  show_phone  boolean NOT NULL DEFAULT false,
  email       text CHECK (email IS NULL OR length(email) <= 120),
  about       text CHECK (about IS NULL OR length(about) <= 1000),
  term_from   date,
  term_to     date,
  is_current  boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid REFERENCES auth.users(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id),
  CONSTRAINT board_term_ck CHECK (term_to IS NULL OR term_from IS NULL OR term_to >= term_from)
);
CREATE INDEX IF NOT EXISTS board_members_order_idx ON bms.board_members(is_current, sort_order);

-- The photo sits in a table of its own: the audit log records every
-- change to a member, and a copy of a picture in every entry would make
-- it enormous for no benefit. Changes of name and position are audited;
-- a new picture is simply a new picture.
CREATE TABLE IF NOT EXISTS bms.board_member_photos (
  member_id   uuid PRIMARY KEY REFERENCES bms.board_members(id) ON DELETE CASCADE,
  photo       text NOT NULL CHECK (photo LIKE 'data:image/%' AND length(photo) <= 400000),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS bms.building_documents (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title          text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 200),
  category       text NOT NULL DEFAULT 'RULES'
                 CHECK (category IN ('CONSTITUTION','RULES','DECISION','NOTICE','FORM','OTHER')),
  summary        text CHECK (summary IS NULL OR length(summary) <= 600),
  body           text CHECK (body IS NULL OR length(body) <= 200000),
  effective_date date,
  version_label  text CHECK (version_label IS NULL OR length(version_label) <= 40),
  file_path      text,
  file_name      text,
  file_mime      text,
  file_size      bigint CHECK (file_size IS NULL OR file_size > 0),
  is_published   boolean NOT NULL DEFAULT true,
  is_pinned      boolean NOT NULL DEFAULT false,
  sort_order     int NOT NULL DEFAULT 100,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid REFERENCES auth.users(id),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid REFERENCES auth.users(id),
  CONSTRAINT document_file_ck CHECK ((file_path IS NULL) = (file_name IS NULL)),
  CONSTRAINT document_has_content_ck CHECK (body IS NOT NULL OR file_path IS NOT NULL OR summary IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS building_documents_cat_idx ON bms.building_documents(category, is_pinned DESC, sort_order);

-- Who and when, stamped by the database rather than trusted from the app.
CREATE OR REPLACE FUNCTION bms.community_touch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := COALESCE(auth.uid(), NEW.updated_by);
  IF TG_OP = 'INSERT' AND TG_TABLE_NAME IN ('board_members','building_documents') THEN
    NEW.created_by := COALESCE(auth.uid(), NEW.created_by);
    NEW.created_at := now();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_committee_info_touch ON bms.committee_info;
CREATE TRIGGER trg_committee_info_touch BEFORE INSERT OR UPDATE ON bms.committee_info
  FOR EACH ROW EXECUTE FUNCTION bms.community_touch();
DROP TRIGGER IF EXISTS trg_board_members_touch ON bms.board_members;
CREATE TRIGGER trg_board_members_touch BEFORE INSERT OR UPDATE ON bms.board_members
  FOR EACH ROW EXECUTE FUNCTION bms.community_touch();
DROP TRIGGER IF EXISTS trg_board_member_photos_touch ON bms.board_member_photos;
CREATE TRIGGER trg_board_member_photos_touch BEFORE INSERT OR UPDATE ON bms.board_member_photos
  FOR EACH ROW EXECUTE FUNCTION bms.community_touch();
DROP TRIGGER IF EXISTS trg_building_documents_touch ON bms.building_documents;
CREATE TRIGGER trg_building_documents_touch BEFORE INSERT OR UPDATE ON bms.building_documents
  FOR EACH ROW EXECUTE FUNCTION bms.community_touch();

-- Every change is in the audit log, like everything else.
DROP TRIGGER IF EXISTS trg_audit_board_members ON bms.board_members;
CREATE TRIGGER trg_audit_board_members AFTER INSERT OR UPDATE OR DELETE ON bms.board_members
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('community', 'name', 'NORMAL');
DROP TRIGGER IF EXISTS trg_audit_building_documents ON bms.building_documents;
CREATE TRIGGER trg_audit_building_documents AFTER INSERT OR UPDATE OR DELETE ON bms.building_documents
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('community', 'title', 'NORMAL');
DROP TRIGGER IF EXISTS trg_audit_committee_info ON bms.committee_info;
CREATE TRIGGER trg_audit_committee_info AFTER UPDATE ON bms.committee_info
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('community', 'title', 'LOW');

-- Row level security.
ALTER TABLE bms.committee_info     ENABLE ROW LEVEL SECURITY;
ALTER TABLE bms.board_members      ENABLE ROW LEVEL SECURITY;
ALTER TABLE bms.building_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE bms.board_member_photos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.committee_info, bms.board_members, bms.building_documents, bms.board_member_photos FROM PUBLIC, anon;
GRANT SELECT, UPDATE ON bms.committee_info TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON bms.board_members, bms.building_documents, bms.board_member_photos TO authenticated;

DROP POLICY IF EXISTS board_member_photos_sel ON bms.board_member_photos;
DROP POLICY IF EXISTS board_member_photos_ins ON bms.board_member_photos;
DROP POLICY IF EXISTS board_member_photos_upd ON bms.board_member_photos;
DROP POLICY IF EXISTS board_member_photos_del ON bms.board_member_photos;
CREATE POLICY board_member_photos_sel ON bms.board_member_photos FOR SELECT TO authenticated
  USING (bms.has_perm('community','view'));
CREATE POLICY board_member_photos_ins ON bms.board_member_photos FOR INSERT TO authenticated
  WITH CHECK (bms.has_perm('community','add') OR bms.has_perm('community','edit'));
CREATE POLICY board_member_photos_upd ON bms.board_member_photos FOR UPDATE TO authenticated
  USING (bms.has_perm('community','edit')) WITH CHECK (bms.has_perm('community','edit'));
CREATE POLICY board_member_photos_del ON bms.board_member_photos FOR DELETE TO authenticated
  USING (bms.has_perm('community','edit') OR bms.has_perm('community','cancel'));

DROP POLICY IF EXISTS committee_info_sel ON bms.committee_info;
DROP POLICY IF EXISTS committee_info_upd ON bms.committee_info;
CREATE POLICY committee_info_sel ON bms.committee_info FOR SELECT TO authenticated
  USING (bms.has_perm('community','view'));
CREATE POLICY committee_info_upd ON bms.committee_info FOR UPDATE TO authenticated
  USING (bms.has_perm('community','edit')) WITH CHECK (bms.has_perm('community','edit'));

DROP POLICY IF EXISTS board_members_sel ON bms.board_members;
DROP POLICY IF EXISTS board_members_ins ON bms.board_members;
DROP POLICY IF EXISTS board_members_upd ON bms.board_members;
DROP POLICY IF EXISTS board_members_del ON bms.board_members;
-- The table itself is read only by those who edit it. Everyone else
-- reads v_board_members, which leaves out a phone number or email the
-- member has not agreed to show — left out by the database, so it never
-- reaches a resident's browser at all.
CREATE POLICY board_members_sel ON bms.board_members FOR SELECT TO authenticated
  USING (bms.has_perm('community','edit'));
CREATE POLICY board_members_ins ON bms.board_members FOR INSERT TO authenticated
  WITH CHECK (bms.has_perm('community','add'));
CREATE POLICY board_members_upd ON bms.board_members FOR UPDATE TO authenticated
  USING (bms.has_perm('community','edit')) WITH CHECK (bms.has_perm('community','edit'));
CREATE POLICY board_members_del ON bms.board_members FOR DELETE TO authenticated
  USING (bms.has_perm('community','cancel'));

CREATE OR REPLACE VIEW bms.v_board_members AS
SELECT m.id, m.name, m.position, m.sort_order, m.flat_id, f.flat_number,
       CASE WHEN m.show_phone OR bms.has_perm('community','edit') THEN m.phone END AS phone,
       CASE WHEN m.show_phone OR bms.has_perm('community','edit') THEN m.email END AS email,
       m.show_phone, m.about, m.term_from, m.term_to, m.is_current, m.updated_at,
       EXISTS (SELECT 1 FROM bms.board_member_photos ph WHERE ph.member_id = m.id) AS has_photo
  FROM bms.board_members m
  LEFT JOIN bms.flats f ON f.id = m.flat_id
 WHERE bms.has_perm('community','view');
REVOKE ALL ON bms.v_board_members FROM PUBLIC, anon;
GRANT SELECT ON bms.v_board_members TO authenticated;

-- An unpublished document (a draft) is seen only by those who may edit.
DROP POLICY IF EXISTS building_documents_sel ON bms.building_documents;
DROP POLICY IF EXISTS building_documents_ins ON bms.building_documents;
DROP POLICY IF EXISTS building_documents_upd ON bms.building_documents;
DROP POLICY IF EXISTS building_documents_del ON bms.building_documents;
CREATE POLICY building_documents_sel ON bms.building_documents FOR SELECT TO authenticated
  USING (bms.has_perm('community','view') AND (is_published OR bms.has_perm('community','edit')));
CREATE POLICY building_documents_ins ON bms.building_documents FOR INSERT TO authenticated
  WITH CHECK (bms.has_perm('community','add'));
CREATE POLICY building_documents_upd ON bms.building_documents FOR UPDATE TO authenticated
  USING (bms.has_perm('community','edit')) WITH CHECK (bms.has_perm('community','edit'));
CREATE POLICY building_documents_del ON bms.building_documents FOR DELETE TO authenticated
  USING (bms.has_perm('community','cancel'));

-- Rule files: the private bms-documents bucket, under community/ only.
-- The bucket is created here if it is missing, PRIVATE, so this works
-- without a trip to the Storage dashboard. Nothing else in the bucket
-- becomes readable: these policies match community/ paths alone.
DO $outer$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'No storage schema here — skipping the community file policies.';
    RETURN;
  END IF;
  INSERT INTO storage.buckets (id, name, public) VALUES ('bms-documents', 'bms-documents', false)
  ON CONFLICT (id) DO NOTHING;

  EXECUTE 'DROP POLICY IF EXISTS "bms-documents_community_read"   ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "bms-documents_community_write"  ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "bms-documents_community_delete" ON storage.objects';
  EXECUTE $sql$
    CREATE POLICY "bms-documents_community_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-documents' AND name LIKE 'community/%' AND bms.has_perm('community','view'));
  $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-documents_community_write" ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'bms-documents' AND name LIKE 'community/%'
                  AND (bms.has_perm('community','add') OR bms.has_perm('community','edit')));
  $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-documents_community_delete" ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'bms-documents' AND name LIKE 'community/%'
             AND (bms.has_perm('community','edit') OR bms.has_perm('community','cancel')));
  $sql$;
END $outer$;

-- ---------------------------------------------------------------------
-- PART 2 — the backup log.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.backup_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  made_at     timestamptz NOT NULL DEFAULT now(),
  made_by     uuid REFERENCES auth.users(id),
  made_by_name text,
  scope       text NOT NULL CHECK (scope IN ('ALL','RANGE')),
  date_from   date,
  date_to     date,
  sheets      int  NOT NULL CHECK (sheets >= 0),
  total_rows  int  NOT NULL CHECK (total_rows >= 0),
  CONSTRAINT backup_range_ck CHECK (scope = 'ALL' OR (date_from IS NOT NULL AND date_to IS NOT NULL AND date_to >= date_from))
);
CREATE INDEX IF NOT EXISTS backup_log_made_idx ON bms.backup_log(made_at DESC);

ALTER TABLE bms.backup_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.backup_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.backup_log TO authenticated;
DROP POLICY IF EXISTS backup_log_sel ON bms.backup_log;
CREATE POLICY backup_log_sel ON bms.backup_log FOR SELECT TO authenticated
  USING (bms.has_perm('reports','view'));

DROP TRIGGER IF EXISTS trg_backup_log_no_delete ON bms.backup_log;
CREATE TRIGGER trg_backup_log_no_delete BEFORE DELETE ON bms.backup_log
  FOR EACH ROW EXECUTE FUNCTION bms.block_delete();

CREATE OR REPLACE FUNCTION bms.log_backup(p_scope text, p_from date, p_to date, p_sheets int, p_rows int)
RETURNS bms.backup_log
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.backup_log;
BEGIN
  PERFORM bms.assert_perm('reports','export');
  INSERT INTO bms.backup_log(made_by, made_by_name, scope, date_from, date_to, sheets, total_rows)
  VALUES (auth.uid(), bms.actor_name(), p_scope,
          CASE WHEN p_scope = 'RANGE' THEN p_from END, CASE WHEN p_scope = 'RANGE' THEN p_to END,
          GREATEST(COALESCE(p_sheets, 0), 0), GREATEST(COALESCE(p_rows, 0), 0))
  RETURNING * INTO r;
  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code, detail, severity)
  VALUES (auth.uid(), bms.actor_name(), 'EXPORT', 'reports',
          format('Backup downloaded (%s, %s sheets, %s rows)',
                 CASE WHEN p_scope = 'RANGE' THEN p_from || ' to ' || p_to ELSE 'all records' END, p_sheets, p_rows),
          'HIGH');
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION bms.log_backup(text,date,date,int,int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.log_backup(text,date,date,int,int) TO authenticated;

-- END 087_community_backup.sql


-- =====================================================================
-- BEGIN 088_storage_setup.sql
-- =====================================================================

-- =====================================================================
-- 088_storage_setup.sql — the places pictures and documents are kept.
--
-- WHAT WENT WRONG
-- ---------------
-- A receipt photo attached to an expense goes to a storage "bucket"
-- called bms-receipts. The setup guide asked for the three buckets to be
-- created by hand in the Supabase dashboard; on the live project they
-- never were, so every upload answered "Bucket not found" — after the
-- expense itself had already been saved, with no way to attach the
-- picture afterwards.
--
-- This file creates them, so there is no dashboard step to forget:
--   bms-receipts   receipts, invoices, payment proofs   images + PDF, 10 MB
--   bms-photos     maintenance and work photos          images, 10 MB
--   bms-documents  contracts, certificates, the rules   PDF, Word, images, 20 MB
-- All three PRIVATE. If one was ever made public by mistake, running
-- this makes it private again: a receipt is opened through a link that
-- expires in minutes, never through a permanent public address.
--
-- It also lets the people who record service-charge payments attach a
-- proof of payment (a bKash screenshot, a deposit slip) to the payment,
-- and lets an attachment be taken down — kept, marked removed, with a
-- reason — rather than deleted. Evidence is never destroyed.
-- =====================================================================

SET search_path = bms, public;

DO $outer$
BEGIN
  IF to_regclass('storage.buckets') IS NULL THEN
    RAISE NOTICE 'No storage schema here — skipping bucket creation.';
    RETURN;
  END IF;
  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
    ('bms-receipts',  'bms-receipts',  false, 10485760,
       ARRAY['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf']),
    ('bms-photos',    'bms-photos',    false, 10485760,
       ARRAY['image/jpeg','image/png','image/webp','image/heic','image/heif']),
    ('bms-documents', 'bms-documents', false, 20971520,
       ARRAY['application/pdf','image/jpeg','image/png','image/webp',
             'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
  ON CONFLICT (id) DO UPDATE
    SET public = false,
        file_size_limit = EXCLUDED.file_size_limit,
        allowed_mime_types = EXCLUDED.allowed_mime_types;

  -- A file you attached yourself you can always open — the caretaker who
  -- photographs a receipt has no sight of the ledger, but should see the
  -- picture he just took. Matched through the attachment record, so it
  -- works whichever owner columns this Supabase version keeps.
  EXECUTE 'DROP POLICY IF EXISTS "bms-receipts_own_read" ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "bms-photos_own_read" ON storage.objects';
  EXECUTE $sql$
    CREATE POLICY "bms-receipts_own_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-receipts' AND EXISTS (
        SELECT 1 FROM bms.attachments a
         WHERE a.bucket = 'bms-receipts' AND a.storage_path = storage.objects.name AND a.uploaded_by = auth.uid()));
  $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-photos_own_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-photos' AND EXISTS (
        SELECT 1 FROM bms.attachments a
         WHERE a.bucket = 'bms-photos' AND a.storage_path = storage.objects.name AND a.uploaded_by = auth.uid()));
  $sql$;
END $outer$;

-- ---------------------------------------------------------------------
-- Proof of payment on a service-charge payment. The general attachment
-- rules belong to Finance; whoever records payments may not have
-- Finance, so a payment's own attachments follow the Service Charge
-- permissions as well.
-- ---------------------------------------------------------------------
-- Whoever attached a file can always see it — a caretaker who photographs
-- the receipt for an expense he submitted, without Finance, included.
DROP POLICY IF EXISTS attachments_own_sel ON bms.attachments;
CREATE POLICY attachments_own_sel ON bms.attachments FOR SELECT TO authenticated
  USING (uploaded_by = auth.uid() AND bms.is_active_user());

DROP POLICY IF EXISTS attachments_payments_sel ON bms.attachments;
DROP POLICY IF EXISTS attachments_payments_ins ON bms.attachments;
CREATE POLICY attachments_payments_sel ON bms.attachments FOR SELECT TO authenticated
  USING (entity_table = 'payments' AND bms.has_perm('charges','view'));
CREATE POLICY attachments_payments_ins ON bms.attachments FOR INSERT TO authenticated
  WITH CHECK (entity_table = 'payments' AND bms.has_perm('charges','add'));

-- ---------------------------------------------------------------------
-- Taking an attachment down. The row stays, the file stays; it is only
-- marked removed, by whom, when and why, so a wrong photo can be
-- corrected without anyone being able to make a real receipt vanish.
-- Allowed to whoever may cancel finance entries, and to the person who
-- attached it, on the same day (the "I picked the wrong photo" case).
-- ---------------------------------------------------------------------
ALTER TABLE bms.attachments ADD COLUMN IF NOT EXISTS deleted_reason   text;
ALTER TABLE bms.attachments ADD COLUMN IF NOT EXISTS uploaded_by_name text;
ALTER TABLE bms.attachments ADD COLUMN IF NOT EXISTS deleted_by_name  text;

CREATE OR REPLACE FUNCTION bms.remove_attachment(p_id uuid, p_reason text)
RETURNS bms.attachments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE a bms.attachments;
BEGIN
  SELECT * INTO a FROM bms.attachments WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Attachment not found'; END IF;
  IF a.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'This attachment has already been removed'; END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why it is being removed'; END IF;
  IF NOT (bms.has_perm('finance','cancel')
          OR (a.uploaded_by = auth.uid() AND a.uploaded_at > now() - interval '1 day')) THEN
    RAISE EXCEPTION 'permission denied: only someone who can cancel finance entries may remove an attachment after the day it was added';
  END IF;
  UPDATE bms.attachments
     SET deleted_at = now(), deleted_by = auth.uid(), deleted_reason = btrim(p_reason),
         deleted_by_name = bms.actor_name()
   WHERE id = p_id
  RETURNING * INTO a;
  RETURN a;
END $$;
REVOKE ALL ON FUNCTION bms.remove_attachment(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.remove_attachment(uuid, text) TO authenticated;

-- Who attached it and when, set by the database (the app does not send
-- it, and must not be trusted to). This is what shows a receipt that was
-- added weeks after the entry as exactly that.
CREATE OR REPLACE FUNCTION bms.attachment_stamp() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  NEW.uploaded_by := COALESCE(auth.uid(), NEW.uploaded_by);
  NEW.uploaded_by_name := COALESCE(bms.actor_name(), NEW.uploaded_by_name);
  NEW.uploaded_at := now();
  NEW.deleted_at := NULL; NEW.deleted_by := NULL;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_attachment_stamp ON bms.attachments;
CREATE TRIGGER trg_attachment_stamp BEFORE INSERT ON bms.attachments
  FOR EACH ROW EXECUTE FUNCTION bms.attachment_stamp();

-- END 088_storage_setup.sql


-- =====================================================================
-- BEGIN 089_owners_bills.sql
-- =====================================================================

-- =====================================================================
-- 089_owners_bills.sql — land owners with several flats, temporary rates,
-- one payment and one receipt for many flats, and the monthly bill.
--
-- PART 1 — TEMPORARY RATES
-- A flat still under construction, or let at a concession for a while,
-- pays a different amount for a stated run of months and then goes back
-- to its normal rate by itself. The rate in force is decided in one
-- place, flat_rate_for(), and the monthly generation uses it, so the
-- month's bill line says why it is different.
--
-- PART 2 — ONE PAYMENT, SEVERAL FLATS
-- A land owner pays one sum for his flats. It is recorded as one payment
-- per flat — so every flat's statement, dues and receipts stay exactly
-- right — tied together as a payment group with its own receipt number,
-- and printed as one receipt listing each flat. Reversing the group
-- reverses each part.
--
-- PART 3 — OWNER ACCOUNTS
-- For any person: every flat he owns, which are rented and to whom, who
-- pays each one, its rate, and his total monthly charge and dues across
-- the flats billed to him.
--
-- PART 4 — THE MONTHLY BILL
-- At the start of each month every payer is sent one bill: each flat he
-- pays for, this month's charge, anything still owed from before, the
-- total and the date it is due (charge_due_day, normally the 10th). The
-- wording lives in Settings; every bill sent is recorded.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- PART 1 — temporary rates
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.flat_rate_overrides (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_id       uuid NOT NULL REFERENCES bms.flats(id) ON DELETE CASCADE,
  from_month    date NOT NULL CHECK (from_month = date_trunc('month', from_month)::date),
  to_month      date CHECK (to_month IS NULL OR to_month = date_trunc('month', to_month)::date),
  amount        bms.money_amount NOT NULL CHECK (amount >= 0),
  reason        text NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 200),
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid REFERENCES auth.users(id),
  cancelled_at  timestamptz,
  cancelled_by  uuid REFERENCES auth.users(id),
  cancel_reason text,
  CONSTRAINT rate_override_range_ck CHECK (to_month IS NULL OR to_month >= from_month)
);
CREATE INDEX IF NOT EXISTS rate_override_flat_idx ON bms.flat_rate_overrides(flat_id, from_month);

ALTER TABLE bms.flat_rate_overrides ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.flat_rate_overrides FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.flat_rate_overrides TO authenticated;
DROP POLICY IF EXISTS rate_overrides_sel ON bms.flat_rate_overrides;
CREATE POLICY rate_overrides_sel ON bms.flat_rate_overrides FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view') OR bms.has_perm('flats','view'));
DROP TRIGGER IF EXISTS trg_audit_rate_overrides ON bms.flat_rate_overrides;
CREATE TRIGGER trg_audit_rate_overrides AFTER INSERT OR UPDATE ON bms.flat_rate_overrides
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('charges', 'reason', 'HIGH');

-- The rate in force for a flat in a given month.
CREATE OR REPLACE FUNCTION bms.flat_rate_for(p_flat uuid, p_month date)
RETURNS TABLE (amount numeric(14,2), source text, reason text, until date, override_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT COALESCE(o.amount, f.service_charge, s.default_service_charge, 0)::numeric(14,2),
         CASE WHEN o.id IS NOT NULL THEN 'TEMPORARY'
              WHEN f.service_charge IS NOT NULL THEN 'FLAT' ELSE 'DEFAULT' END,
         o.reason, o.to_month, o.id
    FROM bms.flats f
    CROSS JOIN bms.building_settings s
    LEFT JOIN LATERAL (
      SELECT x.* FROM bms.flat_rate_overrides x
       WHERE x.flat_id = f.id AND x.cancelled_at IS NULL
         AND x.from_month <= date_trunc('month', p_month)::date
         AND (x.to_month IS NULL OR x.to_month >= date_trunc('month', p_month)::date)
       ORDER BY x.from_month DESC LIMIT 1) o ON true
   WHERE f.id = p_flat AND s.id;
$$;
REVOKE ALL ON FUNCTION bms.flat_rate_for(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.flat_rate_for(uuid, date) TO authenticated;

CREATE OR REPLACE FUNCTION bms.set_temporary_rate(
    p_flat uuid, p_from date, p_to date, p_amount bms.money_amount, p_reason text)
RETURNS bms.flat_rate_overrides
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.flat_rate_overrides; v_from date; v_to date; v_flat text; v_billed date;
BEGIN
  PERFORM bms.assert_perm('charges','edit');
  SELECT flat_number INTO v_flat FROM bms.flats WHERE id = p_flat;
  IF v_flat IS NULL THEN RAISE EXCEPTION 'Flat not found'; END IF;
  IF p_from IS NULL THEN RAISE EXCEPTION 'Say from which month the rate applies'; END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'The rate cannot be negative'; END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why (for example: under construction)'; END IF;
  v_from := date_trunc('month', p_from)::date;
  v_to   := CASE WHEN p_to IS NULL THEN NULL ELSE date_trunc('month', p_to)::date END;
  IF v_to IS NOT NULL AND v_to < v_from THEN RAISE EXCEPTION 'The last month is before the first'; END IF;

  -- A month already billed keeps its bill; changing it is a waiver.
  SELECT make_date(fc.period_year, fc.period_month, 1) INTO v_billed
    FROM bms.flat_charges fc
   WHERE fc.flat_id = p_flat AND fc.charge_source = 'MONTHLY' AND NOT fc.is_cancelled
     AND make_date(fc.period_year, fc.period_month, 1) >= v_from
     AND (v_to IS NULL OR make_date(fc.period_year, fc.period_month, 1) <= v_to)
   ORDER BY 1 LIMIT 1;
  IF v_billed IS NOT NULL THEN
    RAISE EXCEPTION 'Flat % is already billed for %. Start the rate from the month after, and use a waiver for months already billed.',
      v_flat, to_char(v_billed, 'FMMonth YYYY');
  END IF;

  IF EXISTS (SELECT 1 FROM bms.flat_rate_overrides x
              WHERE x.flat_id = p_flat AND x.cancelled_at IS NULL
                AND x.from_month <= COALESCE(v_to, 'infinity'::date)
                AND COALESCE(x.to_month, 'infinity'::date) >= v_from) THEN
    RAISE EXCEPTION 'Flat % already has a temporary rate for some of those months. Cancel that one first.', v_flat;
  END IF;

  INSERT INTO bms.flat_rate_overrides(flat_id, from_month, to_month, amount, reason, created_by)
  VALUES (p_flat, v_from, v_to, p_amount, btrim(p_reason), auth.uid())
  RETURNING * INTO r;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION bms.cancel_temporary_rate(p_id uuid, p_reason text)
RETURNS bms.flat_rate_overrides
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.flat_rate_overrides;
BEGIN
  PERFORM bms.assert_perm('charges','edit');
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why it is being cancelled'; END IF;
  UPDATE bms.flat_rate_overrides
     SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = btrim(p_reason)
   WHERE id = p_id AND cancelled_at IS NULL
  RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'That temporary rate does not exist or is already cancelled'; END IF;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION bms.set_temporary_rate(uuid,date,date,bms.money_amount,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.cancel_temporary_rate(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.set_temporary_rate(uuid,date,date,bms.money_amount,text) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.cancel_temporary_rate(uuid,text) TO authenticated;

-- Monthly generation, now using the rate in force for each flat.
CREATE OR REPLACE FUNCTION bms.generate_monthly_charges(p_year int, p_month int)
RETURNS bms.charge_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  run       bms.charge_runs;
  s         bms.building_settings;
  f         record;
  v_amount  numeric(14,2);
  v_due     date;
  v_count   int := 0;
  v_total   numeric(14,2) := 0;
  v_charge  uuid;
  v_rate    record;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_month < 1 OR p_month > 12 THEN RAISE EXCEPTION 'Month must be 1-12'; END IF;

  SELECT * INTO s FROM bms.building_settings WHERE id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building settings have not been configured yet'; END IF;

  IF bms.period_is_closed(make_date(p_year, p_month, 1)) THEN
    RAISE EXCEPTION 'Accounting period % is closed', to_char(make_date(p_year,p_month,1),'Mon YYYY');
  END IF;

  -- Make sure the month exists as an accounting period even if no cash has
  -- moved yet, so it shows up on the settings screen and can be closed.
  PERFORM bms.period_for(make_date(p_year, p_month, 1));

  -- Reuse the month's run if there is one; the charges hang off it either
  -- way, so a flat added in week three belongs to the same monthly run as
  -- the flats billed in week one.
  SELECT * INTO run FROM bms.charge_runs
   WHERE period_year = p_year AND period_month = p_month AND run_type = 'MONTHLY';
  IF NOT FOUND THEN
    INSERT INTO bms.charge_runs(period_year, period_month, run_type, generated_by)
    VALUES (p_year, p_month, 'MONTHLY', auth.uid())
    RETURNING * INTO run;
  END IF;

  v_due := make_date(p_year, p_month, LEAST(s.charge_due_day, 28));

  -- Only the flats that are not billed for this month yet.
  FOR f IN SELECT fl.id, fl.flat_number, fl.service_charge FROM bms.flats fl
            WHERE fl.status = 'ACTIVE'
              AND NOT EXISTS (SELECT 1 FROM bms.flat_charges fc
                               WHERE fc.flat_id = fl.id
                                 AND fc.period_year = p_year
                                 AND fc.period_month = p_month
                                 AND fc.charge_source = 'MONTHLY')
            ORDER BY fl.floor, fl.flat_number
  LOOP
    -- A temporary rate for this month (a flat under construction, say)
    -- wins over the flat's own rate, which wins over the building default.
    SELECT r.amount, r.source, r.reason INTO v_rate
      FROM bms.flat_rate_for(f.id, make_date(p_year, p_month, 1)) r;
    v_amount := v_rate.amount;

    INSERT INTO bms.flat_charges(run_id, flat_id, period_year, period_month,
                                 charge_source, charge_amount, due_date)
    VALUES (run.id, f.id, p_year, p_month, 'MONTHLY', v_amount, v_due)
    RETURNING id INTO v_charge;

    INSERT INTO bms.charge_line_items(flat_charge_id, label, kind, amount, sort_order)
    VALUES (v_charge,
            CASE WHEN v_rate.source = 'TEMPORARY'
                 THEN 'Monthly service charge (temporary rate: ' || v_rate.reason || ')'
                 ELSE 'Monthly service charge' END,
            'SERVICE', v_amount, 10);

    v_count := v_count + 1;
    v_total := v_total + v_amount;
  END LOOP;

  -- The run totals describe the month as a whole, not just this pass, so
  -- they are recounted from the charges rather than incremented. After a
  -- top-up the row still answers "what was billed for September".
  UPDATE bms.charge_runs r
     SET flat_count   = (SELECT COUNT(*) FROM bms.flat_charges fc
                          WHERE fc.period_year = p_year AND fc.period_month = p_month
                            AND fc.charge_source = 'MONTHLY'),
         total_amount = (SELECT COALESCE(SUM(fc.charge_amount),0) FROM bms.flat_charges fc
                          WHERE fc.period_year = p_year AND fc.period_month = p_month
                            AND fc.charge_source = 'MONTHLY')
   WHERE r.id = run.id RETURNING * INTO run;

  -- How many this pass actually added, so the screen can say so instead of
  -- leaving the person guessing whether anything happened. Set on the
  -- returned record only — deliberately NOT written to the row, because it
  -- describes this call, not the month.
  run.notes := CASE WHEN v_count = 0 THEN 'Every active flat was already billed for this month.'
                    ELSE v_count || ' flat' || CASE WHEN v_count = 1 THEN '' ELSE 's' END
                         || ' billed, ' || to_char(v_total, 'FM999,999,990.00') || ' added.'
               END;

  -- Any flat carrying an advance settles the new month immediately.
  FOR f IN SELECT DISTINCT flat_id FROM bms.payments WHERE status = 'ACTIVE' LOOP
    PERFORM bms.allocate_flat_advance(f.flat_id);
  END LOOP;

  RETURN run;
END $$;

-- ---------------------------------------------------------------------
-- PART 2 — one payment, several flats
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.payment_groups (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_no       text NOT NULL UNIQUE,
  payer_owner_id uuid REFERENCES bms.owners(id) ON DELETE RESTRICT,
  payer_name     text,
  payment_date   date NOT NULL,
  total_amount   bms.money_amount NOT NULL CHECK (total_amount > 0),
  method         text NOT NULL,
  account_id     uuid NOT NULL REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  reference_no   text,
  notes          text,
  received_by    uuid REFERENCES auth.users(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE bms.payments ADD COLUMN IF NOT EXISTS group_id uuid REFERENCES bms.payment_groups(id);
CREATE INDEX IF NOT EXISTS payments_group_idx ON bms.payments(group_id) WHERE group_id IS NOT NULL;

ALTER TABLE bms.payment_groups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.payment_groups FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.payment_groups TO authenticated;
DROP POLICY IF EXISTS payment_groups_sel ON bms.payment_groups;
CREATE POLICY payment_groups_sel ON bms.payment_groups FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view'));
DROP TRIGGER IF EXISTS trg_payment_groups_no_delete ON bms.payment_groups;
CREATE TRIGGER trg_payment_groups_no_delete BEFORE DELETE ON bms.payment_groups
  FOR EACH ROW EXECUTE FUNCTION bms.block_delete();
DROP TRIGGER IF EXISTS trg_audit_payment_groups ON bms.payment_groups;
CREATE TRIGGER trg_audit_payment_groups AFTER INSERT ON bms.payment_groups
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('charges', 'group_no', 'HIGH');

-- A combined receipt can carry its proof of payment, like a single one.
DO $$ BEGIN
  ALTER TABLE bms.attachments DROP CONSTRAINT IF EXISTS attachments_entity_ck;
  ALTER TABLE bms.attachments ADD CONSTRAINT attachments_entity_ck CHECK (entity_table IN
    ('transactions','issues','issue_updates','asset_service_logs','asset_inspections',
     'assets','staff','salary_payments','fixed_deposits','bank_statements','work_logs',
     'work_log_items','payments','flats','fuel_purchases','generator_runs','staff_advances',
     'funds','fund_movements','reconciliations','payment_groups'));
END $$;
DROP POLICY IF EXISTS attachments_payments_sel ON bms.attachments;
DROP POLICY IF EXISTS attachments_payments_ins ON bms.attachments;
CREATE POLICY attachments_payments_sel ON bms.attachments FOR SELECT TO authenticated
  USING (entity_table IN ('payments','payment_groups') AND bms.has_perm('charges','view'));
CREATE POLICY attachments_payments_ins ON bms.attachments FOR INSERT TO authenticated
  WITH CHECK (entity_table IN ('payments','payment_groups') AND bms.has_perm('charges','add'));

-- p_lines: [{"flat": "<uuid>", "amount": 5000}, ...] — one line per flat.
CREATE OR REPLACE FUNCTION bms.record_group_payment(
    p_owner uuid, p_lines jsonb, p_date date, p_method text, p_account uuid,
    p_reference text DEFAULT NULL, p_notes text DEFAULT NULL, p_payer_name text DEFAULT NULL)
RETURNS bms.payment_groups
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE g bms.payment_groups; l record; pay bms.payments; s bms.building_settings;
        v_total numeric(14,2); v_n int; v_name text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one flat to the payment';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric)
              WHERE x.flat IS NULL OR x.amount IS NULL OR x.amount <= 0) THEN
    RAISE EXCEPTION 'Every flat in the payment needs an amount greater than zero';
  END IF;
  IF (SELECT COUNT(*) - COUNT(DISTINCT x.flat) FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric)) > 0 THEN
    RAISE EXCEPTION 'The same flat appears twice in the payment';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric)
              WHERE NOT EXISTS (SELECT 1 FROM bms.flats f WHERE f.id = x.flat)) THEN
    RAISE EXCEPTION 'Flat not found';
  END IF;
  IF p_owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM bms.owners WHERE id = p_owner) THEN
    RAISE EXCEPTION 'That person is not on record';
  END IF;

  SELECT SUM(round(x.amount, 2)), COUNT(*) INTO v_total, v_n
    FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric);
  v_name := COALESCE(NULLIF(btrim(p_payer_name), ''), (SELECT name FROM bms.owners WHERE id = p_owner));
  SELECT * INTO s FROM bms.building_settings WHERE id;

  INSERT INTO bms.payment_groups(group_no, payer_owner_id, payer_name, payment_date, total_amount,
                                 method, account_id, reference_no, notes, received_by)
  VALUES (bms.next_doc_no('RECEIPT_GROUP', EXTRACT(YEAR FROM p_date)::int, COALESCE(s.receipt_prefix, 'RCT') || '-G'),
          p_owner, v_name, p_date, v_total, p_method, p_account, p_reference, p_notes, auth.uid())
  RETURNING * INTO g;

  FOR l IN SELECT x.flat, round(x.amount, 2) AS amount
             FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric)
             JOIN bms.flats f ON f.id = x.flat
            ORDER BY f.floor, f.flat_number LOOP
    pay := bms.record_payment(l.flat, l.amount, p_date, p_method, p_account, p_reference,
                              trim(BOTH ' ' FROM COALESCE(p_notes, '') || ' [part of ' || g.group_no || ']'), v_name);
    UPDATE bms.payments SET group_id = g.id WHERE id = pay.id;
  END LOOP;
  RETURN g;
END $$;

CREATE OR REPLACE FUNCTION bms.reverse_group_payment(p_group uuid, p_reason text)
RETURNS bms.payment_groups
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE g bms.payment_groups; p record; v_n int := 0;
BEGIN
  PERFORM bms.assert_perm('charges','cancel');
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;
  SELECT * INTO g FROM bms.payment_groups WHERE id = p_group;
  IF NOT FOUND THEN RAISE EXCEPTION 'Combined receipt not found'; END IF;
  FOR p IN SELECT id FROM bms.payments WHERE group_id = p_group AND status = 'ACTIVE' LOOP
    PERFORM bms.reverse_payment(p.id, 'Combined receipt ' || g.group_no || ' reversed: ' || btrim(p_reason));
    v_n := v_n + 1;
  END LOOP;
  IF v_n = 0 THEN RAISE EXCEPTION 'Every payment on that receipt is already reversed'; END IF;
  RETURN g;
END $$;
REVOKE ALL ON FUNCTION bms.record_group_payment(uuid,jsonb,date,text,uuid,text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.reverse_group_payment(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.record_group_payment(uuid,jsonb,date,text,uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.reverse_group_payment(uuid,text) TO authenticated;

CREATE OR REPLACE VIEW bms.v_payment_groups WITH (security_invoker = true) AS
SELECT g.id, g.group_no, g.payer_owner_id, g.payer_name, g.payment_date, g.total_amount,
       g.method, g.account_id, g.reference_no, g.notes, g.received_by, g.created_at,
       COUNT(p.id)                                                   AS flat_count,
       COUNT(p.id) FILTER (WHERE p.status = 'ACTIVE')                AS active_count,
       COALESCE(SUM(p.amount) FILTER (WHERE p.status = 'ACTIVE'), 0)::numeric(14,2) AS active_total,
       string_agg(f.flat_number, ', ' ORDER BY f.floor, f.flat_number) AS flat_list,
       CASE WHEN COUNT(p.id) FILTER (WHERE p.status = 'ACTIVE') = COUNT(p.id) THEN 'ACTIVE'
            WHEN COUNT(p.id) FILTER (WHERE p.status = 'ACTIVE') = 0       THEN 'REVERSED'
            ELSE 'PARTLY_REVERSED' END                                AS status
  FROM bms.payment_groups g
  LEFT JOIN bms.payments p ON p.group_id = g.id
  LEFT JOIN bms.flats    f ON f.id = p.flat_id
 GROUP BY g.id;
REVOKE ALL ON bms.v_payment_groups FROM PUBLIC, anon;
GRANT SELECT ON bms.v_payment_groups TO authenticated;

-- ---------------------------------------------------------------------
-- PART 3 — owner accounts
-- ---------------------------------------------------------------------
-- One row per person and flat: every flat a person owns, and every flat
-- billed to them (a tenant who pays included).
CREATE OR REPLACE FUNCTION bms.owner_flats(p_owner uuid DEFAULT NULL)
RETURNS TABLE (owner_id uuid, owner_name text, owner_mobile text,
               flat_id uuid, flat_number text, floor int, flat_status text,
               is_owner boolean, pays boolean, payer_id uuid, payer_name text, payer_relation text,
               tenant_name text, current_rate numeric(14,2), rate_source text, rate_reason text,
               rate_until date, outstanding numeric(14,2), advance numeric(14,2), last_payment_date date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM bms.assert_perm('charges','view');
  RETURN QUERY
  SELECT o.id, o.name, o.mobile, f.id, f.flat_number, f.floor, f.status,
         (occ.relation_type = 'OWNER'), COALESCE(bill.owner_id = o.id, false),
         bill.owner_id, bp.name, bill.relation_type,
         ten.name, r.amount, r.source, r.reason, r.until,
         COALESCE(d.outstanding, 0)::numeric(14,2), COALESCE(d.advance, 0)::numeric(14,2), d.last_payment_date
    FROM bms.owners o
    JOIN bms.flat_occupancy occ ON occ.owner_id = o.id AND occ.to_date IS NULL
                               AND (occ.relation_type = 'OWNER' OR occ.is_billed)
    JOIN bms.flats f ON f.id = occ.flat_id
    LEFT JOIN LATERAL (SELECT fo.owner_id, fo.relation_type FROM bms.flat_occupancy fo
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) bill ON true
    LEFT JOIN bms.owners bp ON bp.id = bill.owner_id
    LEFT JOIN LATERAL (SELECT ow.name FROM bms.flat_occupancy fo JOIN bms.owners ow ON ow.id = fo.owner_id
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.relation_type = 'TENANT' LIMIT 1) ten ON true
    LEFT JOIN LATERAL bms.flat_rate_for(f.id, CURRENT_DATE) r ON true
    LEFT JOIN bms.v_flat_dues d ON d.flat_id = f.id
   WHERE p_owner IS NULL OR o.id = p_owner
   ORDER BY o.name, f.floor, f.flat_number;
END $$;

-- One row per person: what they own and what they pay, all flats together.
CREATE OR REPLACE FUNCTION bms.owner_accounts()
RETURNS TABLE (owner_id uuid, owner_name text, owner_mobile text,
               flats_owned int, flats_rented_out int, flats_paid int, flats_owing int,
               monthly_total numeric(14,2), outstanding numeric(14,2), advance numeric(14,2),
               last_payment_date date, owned_list text, paid_list text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT x.owner_id, x.owner_name, x.owner_mobile,
         COUNT(*) FILTER (WHERE x.is_owner)::int,
         COUNT(*) FILTER (WHERE x.is_owner AND x.tenant_name IS NOT NULL)::int,
         COUNT(*) FILTER (WHERE x.pays)::int,
         COUNT(*) FILTER (WHERE x.pays AND x.outstanding > 0)::int,
         COALESCE(SUM(x.current_rate) FILTER (WHERE x.pays AND x.flat_status = 'ACTIVE'), 0)::numeric(14,2),
         COALESCE(SUM(x.outstanding) FILTER (WHERE x.pays), 0)::numeric(14,2),
         COALESCE(SUM(x.advance) FILTER (WHERE x.pays), 0)::numeric(14,2),
         MAX(x.last_payment_date) FILTER (WHERE x.pays),
         string_agg(x.flat_number, ', ' ORDER BY x.floor, x.flat_number) FILTER (WHERE x.is_owner),
         string_agg(x.flat_number, ', ' ORDER BY x.floor, x.flat_number) FILTER (WHERE x.pays)
    FROM bms.owner_flats(NULL) x
   GROUP BY x.owner_id, x.owner_name, x.owner_mobile
   ORDER BY COUNT(*) FILTER (WHERE x.pays) DESC, x.owner_name;
$$;
REVOKE ALL ON FUNCTION bms.owner_flats(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.owner_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.owner_flats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.owner_accounts() TO authenticated;

-- ---------------------------------------------------------------------
-- PART 4 — the monthly bill
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.default_bill_template(p_lang text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_lang = 'bn' THEN
$t$সম্মানিত {name},
{building} — {month} মাসের সার্ভিস চার্জ বিল

{lines}

মোট পরিশোধযোগ্য: {total} টাকা
অনুগ্রহ করে {due_date}-এর মধ্যে পরিশোধ করুন।
{how_to_pay}

ইতোমধ্যে পরিশোধ করে থাকলে ধন্যবাদ — এই বার্তাটি উপেক্ষা করুন।
— {building} ব্যবস্থাপনা কমিটি$t$
  ELSE
$t$Dear {name},
Service charge bill for {month} — {building}

{lines}

Total payable: Tk {total}
Please pay by {due_date}.
{how_to_pay}

If you have already paid, thank you — please ignore this message.
— {building} Management$t$
  END;
$$;

ALTER TABLE bms.building_settings
  ADD COLUMN IF NOT EXISTS bill_template_en text,
  ADD COLUMN IF NOT EXISTS bill_template_bn text;
UPDATE bms.building_settings SET bill_template_en = bms.default_bill_template('en')
 WHERE id AND bill_template_en IS NULL;
UPDATE bms.building_settings SET bill_template_bn = bms.default_bill_template('bn')
 WHERE id AND bill_template_bn IS NULL;

CREATE TABLE IF NOT EXISTS bms.bill_notices (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_id        uuid NOT NULL REFERENCES bms.flats(id) ON DELETE CASCADE,
  period_year    int  NOT NULL,
  period_month   int  NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  sent_at        timestamptz NOT NULL DEFAULT now(),
  sent_by        uuid REFERENCES auth.users(id),
  channel        text NOT NULL CHECK (channel IN ('WHATSAPP','SMS','COPY','IMAGE','PDF','PRINT')),
  recipient_name text,
  phone          text,
  amount_due     bms.money_amount,
  message        text NOT NULL
);
CREATE INDEX IF NOT EXISTS bill_notices_period_idx ON bms.bill_notices(period_year, period_month, flat_id);

ALTER TABLE bms.bill_notices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.bill_notices FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.bill_notices TO authenticated;
DROP POLICY IF EXISTS bill_notices_sel ON bms.bill_notices;
CREATE POLICY bill_notices_sel ON bms.bill_notices FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view'));
DROP TRIGGER IF EXISTS trg_bill_notices_no_delete ON bms.bill_notices;
CREATE TRIGGER trg_bill_notices_no_delete BEFORE DELETE ON bms.bill_notices
  FOR EACH ROW EXECUTE FUNCTION bms.block_delete();

-- Every flat's bill for a month: this month's charge, what is still owed
-- from before, the total, and who it goes to.
CREATE OR REPLACE FUNCTION bms.month_bills(p_year int, p_month int)
RETURNS TABLE (flat_id uuid, flat_number text, floor int,
               payer_id uuid, payer_name text, payer_mobile text, payer_relation text,
               this_month numeric(14,2), this_month_due numeric(14,2), previous_due numeric(14,2),
               total_due numeric(14,2), advance numeric(14,2), rate_source text, rate_reason text,
               due_date date, is_billed boolean, last_sent_at timestamptz, times_sent int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM bms.assert_perm('charges','view');
  IF p_month < 1 OR p_month > 12 THEN RAISE EXCEPTION 'Month must be 1-12'; END IF;
  RETURN QUERY
  SELECT f.id, f.flat_number, f.floor,
         bill.owner_id, bp.name, bp.mobile, bill.relation_type,
         COALESCE(fc.net_payable, 0)::numeric(14,2),
         COALESCE(fc.due_amount, 0)::numeric(14,2),
         GREATEST(COALESCE(d.outstanding, 0) - COALESCE(fc.due_amount, 0), 0)::numeric(14,2),
         COALESCE(d.outstanding, 0)::numeric(14,2),
         COALESCE(d.advance, 0)::numeric(14,2),
         r.source, r.reason,
         COALESCE(fc.due_date, make_date(p_year, p_month, LEAST(s.charge_due_day, 28))),
         fc.id IS NOT NULL, bn.last_sent, COALESCE(bn.n, 0)::int
    FROM bms.flats f
    CROSS JOIN bms.building_settings s
    LEFT JOIN bms.v_flat_charges fc ON fc.flat_id = f.id AND fc.period_year = p_year
                                   AND fc.period_month = p_month AND fc.charge_source = 'MONTHLY'
                                   AND NOT fc.is_cancelled
    LEFT JOIN bms.v_flat_dues d ON d.flat_id = f.id
    LEFT JOIN LATERAL (SELECT fo.owner_id, fo.relation_type FROM bms.flat_occupancy fo
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) bill ON true
    LEFT JOIN bms.owners bp ON bp.id = bill.owner_id
    LEFT JOIN LATERAL bms.flat_rate_for(f.id, make_date(p_year, p_month, 1)) r ON true
    LEFT JOIN LATERAL (SELECT MAX(b.sent_at) AS last_sent, COUNT(*) AS n FROM bms.bill_notices b
                        WHERE b.flat_id = f.id AND b.period_year = p_year AND b.period_month = p_month) bn ON true
   WHERE s.id AND (f.status = 'ACTIVE' OR COALESCE(d.outstanding, 0) > 0)
   ORDER BY bp.name NULLS LAST, f.floor, f.flat_number;
END $$;

-- Record that a bill went out — one row per flat on it.
-- p_flats is a JSON list of flat ids: ["…","…"]. (JSON rather than uuid[]
-- because that is what the app sends, the same way for every RPC.)
DROP FUNCTION IF EXISTS bms.log_bill_notice(uuid[], int, int, text, text);
CREATE OR REPLACE FUNCTION bms.log_bill_notice(p_flats jsonb, p_year int, p_month int, p_channel text, p_message text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_n int; v_ids uuid[];
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_flats IS NOT NULL AND jsonb_typeof(p_flats) = 'array' THEN
    SELECT array_agg(x::uuid) INTO v_ids FROM jsonb_array_elements_text(p_flats) x;
  END IF;
  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN RAISE EXCEPTION 'No flats on the bill'; END IF;
  IF COALESCE(btrim(p_message), '') = '' THEN RAISE EXCEPTION 'The bill is empty'; END IF;
  INSERT INTO bms.bill_notices(flat_id, period_year, period_month, sent_by, channel,
                               recipient_name, phone, amount_due, message)
  SELECT f.id, p_year, p_month, auth.uid(), p_channel, bp.name, bp.mobile, COALESCE(d.outstanding, 0), p_message
    FROM bms.flats f
    LEFT JOIN LATERAL (SELECT fo.owner_id FROM bms.flat_occupancy fo
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) bill ON true
    LEFT JOIN bms.owners bp ON bp.id = bill.owner_id
    LEFT JOIN bms.v_flat_dues d ON d.flat_id = f.id
   WHERE f.id = ANY(v_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'Flat not found'; END IF;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION bms.month_bills(int,int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.log_bill_notice(jsonb,int,int,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.default_bill_template(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.month_bills(int,int) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.log_bill_notice(jsonb,int,int,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.default_bill_template(text) TO authenticated;

-- END 089_owners_bills.sql


-- =====================================================================
-- BEGIN 090_storage.sql
-- =====================================================================

-- =====================================================================
-- 090_storage.sql — access policies for the three private buckets.
--
-- The buckets themselves are created by 088_storage_setup.sql (private,
-- with size and file-type limits), so there is nothing to do by hand in
-- the Supabase dashboard any more.
--
-- The LPG Ledger's own `meter-photos` bucket is not mentioned anywhere
-- in this file and is left exactly as it is.
-- =====================================================================

-- Supabase keeps objects in storage.objects, with the bucket in bucket_id.
-- These policies decide who may read, write and remove them; the app then
-- hands out short-lived signed URLs rather than public links.

-- The whole file is a no-op where there is no storage schema (the local
-- test database), so it can sit in the same migration sequence.
DO $outer$
DECLARE b text;
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'No storage schema here — skipping bucket policies.';
    RETURN;
  END IF;

  FOREACH b IN ARRAY ARRAY['bms-receipts','bms-photos','bms-documents'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_read');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_write');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_delete');
  END LOOP;

  -- Receipts and invoices: anyone who may see the ledger may see them,
  -- and whoever records service-charge payments may attach and see a
  -- payment's proof (a bKash screenshot, a bank deposit slip).
  EXECUTE $sql$
    CREATE POLICY "bms-receipts_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-receipts' AND (bms.has_perm('finance','view') OR bms.has_perm('charges','view')));
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-receipts_write" ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'bms-receipts' AND (bms.has_perm('finance','add') OR bms.has_perm('charges','add')));
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-receipts_delete" ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'bms-receipts' AND bms.has_perm('finance','cancel'));
    $sql$;

  -- Photos: maintenance, work and asset pictures.
  EXECUTE $sql$
    CREATE POLICY "bms-photos_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-photos' AND bms.is_active_user());
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-photos_write" ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'bms-photos' AND bms.is_active_user());
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-photos_delete" ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'bms-photos' AND bms.has_perm('maintenance','cancel'));
    $sql$;

  -- Documents: contracts, licences, FD certificates, minutes.
  EXECUTE $sql$
    CREATE POLICY "bms-documents_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-documents' AND bms.has_perm('bank','view_sensitive'));
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-documents_write" ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'bms-documents' AND bms.has_perm('bank','view_sensitive'));
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-documents_delete" ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'bms-documents' AND bms.has_perm('settings','edit'));
    $sql$;
END $outer$;

-- END 090_storage.sql


-- =====================================================================
-- BEGIN 091_people_fixes.sql
-- =====================================================================

-- =====================================================================
-- 091_people_fixes.sql — putting right who owns and who pays, when the
-- flats were first entered one at a time.
--
-- Entering 36 flats one by one leaves three kinds of mistake behind, and
-- each one quietly breaks the owner totals and the combined receipt:
--
--   1. THE SAME PERSON TWICE. "Nurul Huda" typed as a new person on A9
--      and again on B9 is two people to the database, so his two flats
--      never add up. merge_people() makes them one: every flat, every
--      combined receipt moves to the person kept, missing contact details
--      are filled in from the other, and the other is retired (never
--      deleted — the audit log says who was merged into whom).
--
--   2. A PERSON ON THE WRONG FLAT. A tenant added to A9 who really rents
--      B9. void_occupancy() takes the entry off as "added by mistake":
--      it disappears from the flat and from its history list, the bill
--      goes back to whoever else is there, and the row itself is kept
--      with the reason.
--
--   3. THE WRONG PERSON NAMED. correct_occupant() replaces the person on
--      an entry without inventing a change of ownership: no "past owner"
--      for a typing mistake.
--
-- possible_duplicate_people() finds the likely doubles (same name, or the
-- same mobile number) so the screens can offer the merge.
-- =====================================================================

ALTER TABLE bms.flat_occupancy
  ADD COLUMN IF NOT EXISTS voided_at   timestamptz,
  ADD COLUMN IF NOT EXISTS voided_by   uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS void_reason text;

ALTER TABLE bms.owners
  ADD COLUMN IF NOT EXISTS merged_into uuid REFERENCES bms.owners(id);

-- ---------------------------------------------------------------------
-- After an entry is taken off, someone still current on the flat must
-- receive the bill: the owner first, otherwise the tenant.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms._rebill_flat(p_flat uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM bms.flat_occupancy WHERE flat_id = p_flat AND to_date IS NULL AND is_billed) THEN
    UPDATE bms.flat_occupancy SET is_billed = true
     WHERE id = (SELECT id FROM bms.flat_occupancy
                  WHERE flat_id = p_flat AND to_date IS NULL
                  ORDER BY (relation_type = 'OWNER') DESC, from_date DESC LIMIT 1);
  END IF;
END $$;
REVOKE ALL ON FUNCTION bms._rebill_flat(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Added by mistake.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.void_occupancy(p_occupancy uuid, p_reason text)
RETURNS bms.flat_occupancy
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.flat_occupancy;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why (for example: added to the wrong flat)'; END IF;
  SELECT * INTO r FROM bms.flat_occupancy WHERE id = p_occupancy FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry no longer exists'; END IF;
  IF r.voided_at IS NOT NULL THEN RAISE EXCEPTION 'That entry has already been removed'; END IF;
  IF r.to_date IS NOT NULL THEN RAISE EXCEPTION 'Only a current owner or tenant can be removed as a mistake'; END IF;

  UPDATE bms.flat_occupancy
     SET to_date = from_date, is_billed = false,
         voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
   WHERE id = r.id
  RETURNING * INTO r;
  PERFORM bms._rebill_flat(r.flat_id);
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- 3. The wrong person named on an entry.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.correct_occupant(
    p_occupancy uuid, p_person uuid DEFAULT NULL, p_name text DEFAULT NULL,
    p_mobile text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS bms.flat_occupancy
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.flat_occupancy; v_person uuid;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  SELECT * INTO r FROM bms.flat_occupancy WHERE id = p_occupancy FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry no longer exists'; END IF;
  IF r.voided_at IS NOT NULL OR r.to_date IS NOT NULL THEN
    RAISE EXCEPTION 'Only a current owner or tenant can be corrected';
  END IF;
  v_person := bms._person_for(p_person, p_name, p_mobile, NULL, NULL);
  IF v_person = r.owner_id THEN RETURN r; END IF;
  IF EXISTS (SELECT 1 FROM bms.flat_occupancy
              WHERE flat_id = r.flat_id AND to_date IS NULL AND id <> r.id AND owner_id = v_person) THEN
    RAISE EXCEPTION 'That person is already the % of this flat',
      (SELECT lower(relation_type) FROM bms.flat_occupancy
        WHERE flat_id = r.flat_id AND to_date IS NULL AND id <> r.id AND owner_id = v_person LIMIT 1);
  END IF;
  UPDATE bms.flat_occupancy
     SET owner_id = v_person,
         notes = trim(BOTH ' ' FROM COALESCE(notes, '') || ' Corrected: ' ||
                 COALESCE(NULLIF(btrim(p_reason), ''), 'wrong person entered'))
   WHERE id = r.id
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- 1. The same person entered twice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.merge_people(p_keep uuid, p_drop uuid)
RETURNS bms.owners
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE k bms.owners; d bms.owners; v_flats int; v_groups int; v_clash text;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  IF p_keep IS NULL OR p_drop IS NULL OR p_keep = p_drop THEN
    RAISE EXCEPTION 'Choose two different people';
  END IF;
  SELECT * INTO k FROM bms.owners WHERE id = p_keep FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'The person to keep no longer exists'; END IF;
  SELECT * INTO d FROM bms.owners WHERE id = p_drop FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'The person to merge no longer exists'; END IF;
  IF d.merged_into IS NOT NULL THEN RAISE EXCEPTION '% has already been merged', d.name; END IF;

  -- One person cannot be both the owner and the tenant of the same flat.
  SELECT f.flat_number INTO v_clash
    FROM bms.flat_occupancy a
    JOIN bms.flat_occupancy b ON b.flat_id = a.flat_id AND b.to_date IS NULL AND b.owner_id = p_drop
    JOIN bms.flats f ON f.id = a.flat_id
   WHERE a.owner_id = p_keep AND a.to_date IS NULL AND a.relation_type <> b.relation_type
   LIMIT 1;
  IF v_clash IS NOT NULL THEN
    RAISE EXCEPTION 'They cannot be one person: one is the owner and the other the tenant of flat %. Fix that flat first.', v_clash;
  END IF;

  -- The same flat, same role, both current: keep the earlier entry.
  UPDATE bms.flat_occupancy b
     SET to_date = b.from_date, is_billed = false,
         voided_at = now(), voided_by = auth.uid(), void_reason = 'Duplicate of ' || k.name || ' (people merged)'
   WHERE b.owner_id = p_drop AND b.to_date IS NULL
     AND EXISTS (SELECT 1 FROM bms.flat_occupancy a
                  WHERE a.owner_id = p_keep AND a.flat_id = b.flat_id
                    AND a.relation_type = b.relation_type AND a.to_date IS NULL);

  UPDATE bms.flat_occupancy SET owner_id = p_keep WHERE owner_id = p_drop;
  GET DIAGNOSTICS v_flats = ROW_COUNT;
  UPDATE bms.payment_groups SET payer_owner_id = p_keep WHERE payer_owner_id = p_drop;
  GET DIAGNOSTICS v_groups = ROW_COUNT;

  UPDATE bms.owners
     SET mobile      = COALESCE(NULLIF(btrim(mobile), ''), d.mobile),
         email       = COALESCE(NULLIF(btrim(email), ''), d.email),
         alt_contact = COALESCE(NULLIF(btrim(alt_contact), ''), d.alt_contact,
                                CASE WHEN d.mobile IS DISTINCT FROM mobile THEN d.mobile END),
         address     = COALESCE(NULLIF(btrim(address), ''), d.address)
   WHERE id = p_keep
  RETURNING * INTO k;

  UPDATE bms.owners
     SET is_active = false, merged_into = p_keep,
         notes = trim(BOTH ' ' FROM COALESCE(notes, '') || ' Merged into ' || k.name || ' on ' || to_char(CURRENT_DATE, 'DD Mon YYYY') || '.')
   WHERE id = p_drop;

  PERFORM bms._rebill_flat(fo.flat_id) FROM bms.flat_occupancy fo WHERE fo.owner_id = p_keep AND fo.to_date IS NULL;

  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code, entity_table, entity_id, entity_label, detail, severity)
  VALUES (auth.uid(), bms.actor_name(), 'UPDATE', 'flats', 'owners', p_keep, k.name,
          format('Merged %s%s into %s: %s flat entries and %s combined receipts moved', d.name,
                 COALESCE(' (' || d.mobile || ')', ''), k.name, v_flats, v_groups), 'HIGH');
  RETURN k;
END $$;

-- ---------------------------------------------------------------------
-- Likely doubles: the same name (ignoring case, spaces and dots) or the
-- same mobile number, among people still in use.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.possible_duplicate_people()
RETURNS TABLE (a_id uuid, a_name text, a_mobile text, a_flats text,
               b_id uuid, b_name text, b_mobile text, b_flats text, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM bms.assert_perm('flats','view');
  RETURN QUERY
  WITH p AS (
    SELECT o.id, o.name, o.mobile, o.created_at,
           lower(regexp_replace(o.name, '[\s\.\-]+', '', 'g')) AS nkey,
           bms.normalize_mobile(o.mobile) AS mkey,
           (SELECT string_agg(f.flat_number || CASE WHEN fo.relation_type = 'TENANT' THEN ' (tenant)' ELSE '' END,
                              ', ' ORDER BY f.floor, f.flat_number)
              FROM bms.flat_occupancy fo JOIN bms.flats f ON f.id = fo.flat_id
             WHERE fo.owner_id = o.id AND fo.to_date IS NULL) AS flats
      FROM bms.owners o
     WHERE o.merged_into IS NULL AND o.is_active
  )
  SELECT a.id, a.name, a.mobile, a.flats, b.id, b.name, b.mobile, b.flats,
         CASE WHEN a.nkey = b.nkey AND a.mkey IS NOT DISTINCT FROM b.mkey THEN 'same name and mobile'
              WHEN a.nkey = b.nkey THEN 'same name'
              ELSE 'same mobile number' END
    FROM p a JOIN p b
      ON (a.created_at, a.id) < (b.created_at, b.id)
     AND (a.nkey = b.nkey OR (a.mkey IS NOT NULL AND a.mkey = b.mkey))
   ORDER BY a.name, b.name;
END $$;

REVOKE ALL ON FUNCTION bms.void_occupancy(uuid,text)                       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.correct_occupant(uuid,uuid,text,text,text)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.merge_people(uuid,uuid)                         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.possible_duplicate_people()                     FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.void_occupancy(uuid,text)                    TO authenticated;
GRANT EXECUTE ON FUNCTION bms.correct_occupant(uuid,uuid,text,text,text)   TO authenticated;
GRANT EXECUTE ON FUNCTION bms.merge_people(uuid,uuid)                      TO authenticated;
GRANT EXECUTE ON FUNCTION bms.possible_duplicate_people()                  TO authenticated;

-- END 091_people_fixes.sql


-- =====================================================================
-- BEGIN 092_slip_channels.sql
-- =====================================================================

-- =====================================================================
-- 092_slip_channels.sql — a DUE slip counts as a reminder.
--
-- A flat's DUE slip can now be sent as a picture, a PDF or on paper as
-- well as a WhatsApp or SMS message. Every one of those is a reminder,
-- and must count in "reminded 2× since the last payment", so the reminder
-- log accepts IMAGE, PDF and PRINT as channels.
-- =====================================================================
DO $do$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
            WHERE conrelid = 'bms.charge_reminders'::regclass AND contype = 'c'
              AND pg_get_constraintdef(oid) LIKE '%channel%'
  LOOP
    EXECUTE format('ALTER TABLE bms.charge_reminders DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $do$;
ALTER TABLE bms.charge_reminders ADD CONSTRAINT charge_reminders_channel_ck
  CHECK (channel IN ('WHATSAPP','SMS','COPY','IMAGE','PDF','PRINT'));

CREATE OR REPLACE FUNCTION bms.log_charge_reminder(
    p_flat uuid, p_channel text, p_tone text, p_lang text, p_message text)
RETURNS bms.charge_reminders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE d record; ppl record; r bms.charge_reminders; v_months text;
        v_name text; v_mobile text; v_rel text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_channel NOT IN ('WHATSAPP','SMS','COPY','IMAGE','PDF','PRINT') THEN RAISE EXCEPTION 'Unknown channel %', p_channel; END IF;
  IF p_tone NOT IN ('GENTLE','FOLLOW_UP','FIRM') THEN RAISE EXCEPTION 'Unknown tone %', p_tone; END IF;
  IF p_lang NOT IN ('en','bn') THEN RAISE EXCEPTION 'Unknown language %', p_lang; END IF;
  IF COALESCE(btrim(p_message), '') = '' THEN RAISE EXCEPTION 'The message is empty'; END IF;

  SELECT * INTO d FROM bms.v_flat_dues WHERE flat_id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;
  IF COALESCE(d.outstanding, 0) <= 0 THEN
    RAISE EXCEPTION 'Flat % owes nothing now, so no reminder was recorded.', d.flat_number
      USING ERRCODE = '23514';
  END IF;

  SELECT * INTO ppl FROM bms.v_flat_people WHERE flat_id = p_flat;
  v_rel    := ppl.billed_relation;
  v_name   := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_name   WHEN 'OWNER' THEN ppl.owner_name   END;
  v_mobile := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_mobile WHEN 'OWNER' THEN ppl.owner_mobile END;

  SELECT string_agg(CASE WHEN charge_source = 'OPENING' THEN 'earlier balance'
                         ELSE to_char(make_date(period_year, period_month, 1), 'Mon YYYY') END,
                    ', ' ORDER BY period_year, period_month)
    INTO v_months
    FROM bms.v_flat_charges
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED');

  INSERT INTO bms.charge_reminders (flat_id, sent_by, channel, tone, lang,
                                    recipient_name, relation, phone, phone_sent,
                                    amount_due, months, message)
  VALUES (p_flat, auth.uid(), p_channel, p_tone, p_lang,
          v_name, v_rel, v_mobile, bms.normalize_mobile(v_mobile),
          d.outstanding, v_months, left(p_message, 4000))
  RETURNING * INTO r;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) TO authenticated;

-- END 092_slip_channels.sql


-- =====================================================================
-- BEGIN 093_billed_ahead.sql
-- =====================================================================

-- =====================================================================
-- 093_billed_ahead.sql — a month billed early is not owed yet.
--
-- Reported: November was generated in October as a trial, and every flat
-- then "owed" Tk 10,000 — October's charge plus November's. October's
-- bills and reminders listed November as "earlier dues".
--
-- A month that has not begun yet is now BILLED AHEAD:
--   • v_flat_charges says so (not_due_yet) for each charge;
--   • v_flat_dues.outstanding counts only months that have begun (and
--     the opening balance); the rest is shown apart as billed_ahead;
--   • reminders and DUE slips list only months that have begun;
--   • a month's bill counts as "earlier dues" only months before it.
-- On the 1st of the month the charge simply becomes due — nothing has to
-- be run. Payments are unchanged: they still settle the oldest month
-- first, and anything over stays as the flat's advance.
-- =====================================================================

CREATE OR REPLACE VIEW bms.v_flat_charges WITH (security_invoker = true) AS
SELECT fc.id, fc.flat_id, f.flat_number, f.floor,
       fc.period_year, fc.period_month,
       make_date(fc.period_year, fc.period_month, 1) AS period_start,
       fc.charge_source, fc.charge_amount, fc.adjustment_amount, fc.waiver_amount,
       fc.net_payable, fc.due_date, fc.is_cancelled, fc.run_id,
       COALESCE(p.paid, 0)::numeric(14,2)                            AS paid_amount,
       (fc.net_payable - COALESCE(p.paid, 0))::numeric(14,2)         AS due_amount,
       CASE
         WHEN fc.is_cancelled                              THEN 'CANCELLED'
         WHEN fc.net_payable <= 0 AND fc.waiver_amount > 0 THEN 'WAIVED'
         WHEN COALESCE(p.paid,0) >= fc.net_payable         THEN 'PAID'
         WHEN COALESCE(p.paid,0) > 0                       THEN 'PARTIAL'
         WHEN fc.due_date < CURRENT_DATE                   THEN 'OVERDUE'
         ELSE 'UNPAID'
       END AS status,
       GREATEST(0, CURRENT_DATE - fc.due_date) AS days_overdue,
       (fc.charge_source <> 'OPENING'
        AND make_date(fc.period_year, fc.period_month, 1) > date_trunc('month', CURRENT_DATE)::date) AS not_due_yet
  FROM bms.flat_charges fc
  JOIN bms.flats f ON f.id = fc.flat_id
  LEFT JOIN (
        SELECT flat_charge_id, SUM(amount)::numeric(14,2) AS paid
          FROM bms.payment_allocations GROUP BY flat_charge_id
       ) p ON p.flat_charge_id = fc.id;

CREATE OR REPLACE VIEW bms.v_flat_dues WITH (security_invoker = true) AS
WITH per_charge AS (
  SELECT fc.flat_id, fc.net_payable, COALESCE(p.paid, 0) AS paid,
         (fc.charge_source = 'OPENING'
          OR make_date(fc.period_year, fc.period_month, 1) <= date_trunc('month', CURRENT_DATE)::date) AS due_now
    FROM bms.flat_charges fc
    LEFT JOIN (SELECT flat_charge_id, SUM(amount) AS paid FROM bms.payment_allocations GROUP BY flat_charge_id) p
           ON p.flat_charge_id = fc.id
   WHERE NOT fc.is_cancelled
), charged AS (
  SELECT flat_id,
         SUM(net_payable)::numeric(14,2) AS charged,
         SUM(paid)::numeric(14,2)        AS allocated,
         COALESCE(SUM(GREATEST(net_payable - paid, 0)) FILTER (WHERE due_now), 0)::numeric(14,2)     AS due_now,
         COALESCE(SUM(GREATEST(net_payable - paid, 0)) FILTER (WHERE NOT due_now), 0)::numeric(14,2) AS ahead
    FROM per_charge GROUP BY flat_id
), allocated_all AS (
  SELECT fc.flat_id, SUM(pa.amount)::numeric(14,2) AS allocated
    FROM bms.payment_allocations pa
    JOIN bms.flat_charges fc ON fc.id = pa.flat_charge_id
   GROUP BY fc.flat_id
), paid AS (
  SELECT flat_id, SUM(amount)::numeric(14,2) AS received,
         MAX(payment_date) AS last_payment_date
    FROM bms.payments WHERE status = 'ACTIVE' GROUP BY flat_id
)
SELECT f.id AS flat_id, f.flat_number, f.floor, f.status AS flat_status,
       f.service_charge,
       COALESCE(c.charged, 0)   AS total_charged,
       COALESCE(a.allocated, 0) AS total_allocated,
       COALESCE(p.received, 0)  AS total_received,
       COALESCE(c.due_now, 0)::numeric(14,2) AS outstanding,
       GREATEST(COALESCE(p.received,0) - COALESCE(a.allocated,0), 0)::numeric(14,2) AS advance,
       p.last_payment_date,
       (SELECT o.name FROM bms.flat_occupancy fo JOIN bms.owners o ON o.id = fo.owner_id
         WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) AS billed_to,
       (SELECT o.mobile FROM bms.flat_occupancy fo JOIN bms.owners o ON o.id = fo.owner_id
         WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) AS billed_mobile,
       COALESCE(c.ahead, 0)::numeric(14,2) AS billed_ahead
  FROM bms.flats f
  LEFT JOIN charged       c ON c.flat_id = f.id
  LEFT JOIN allocated_all a ON a.flat_id = f.id
  LEFT JOIN paid          p ON p.flat_id = f.id;

CREATE OR REPLACE FUNCTION bms.reminder_context(p_flat uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE d record; ppl record; s bms.building_settings; rm record;
        v_since int; v_tone text; v_months jsonb; v_tpl jsonb;
        v_name text; v_mobile text; v_rel text;
BEGIN
  PERFORM bms.assert_perm('charges','view');

  SELECT * INTO d FROM bms.v_flat_dues WHERE flat_id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;
  SELECT * INTO ppl FROM bms.v_flat_people WHERE flat_id = p_flat;
  SELECT * INTO s FROM bms.building_settings WHERE id;
  SELECT * INTO rm FROM bms.v_flat_reminders WHERE flat_id = p_flat;

  v_rel    := ppl.billed_relation;
  v_name   := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_name   WHEN 'OWNER' THEN ppl.owner_name   END;
  v_mobile := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_mobile WHEN 'OWNER' THEN ppl.owner_mobile END;

  v_since := COALESCE(rm.reminders_since_payment, 0);
  v_tone  := CASE WHEN v_since = 0 THEN 'GENTLE' WHEN v_since = 1 THEN 'FOLLOW_UP' ELSE 'FIRM' END;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'year', period_year, 'month', period_month,
           'source', charge_source, 'due', due_amount)
           ORDER BY period_year, period_month), '[]'::jsonb)
    INTO v_months
    FROM bms.v_flat_charges
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED')
     AND NOT not_due_yet;

  SELECT COALESCE(jsonb_object_agg(tone || '.' || lang, body), '{}'::jsonb)
    INTO v_tpl FROM bms.reminder_templates;

  RETURN jsonb_build_object(
    'flat_id', p_flat, 'flat_number', d.flat_number,
    'outstanding', d.outstanding, 'advance', d.advance,
    'last_payment_date', d.last_payment_date,
    'recipient_name', v_name, 'relation', v_rel,
    'mobile', v_mobile, 'mobile_wa', bms.normalize_mobile(v_mobile),
    'months', v_months,
    'reminders_total', COALESCE(rm.reminders_total, 0),
    'reminders_since_payment', v_since,
    'last_reminded_at', rm.last_reminded_at,
    'suggested_tone', v_tone,
    'building_name', s.building_name,
    'how_to_pay', s.reminder_how_to_pay,
    'language', COALESCE(s.reminder_language, 'en'),
    'deadline_date', CURRENT_DATE + COALESCE(s.reminder_deadline_days, 7),
    'templates', v_tpl,
    'can_send', bms.has_perm('charges','add'));
END $$;

CREATE OR REPLACE FUNCTION bms.log_charge_reminder(
    p_flat uuid, p_channel text, p_tone text, p_lang text, p_message text)
RETURNS bms.charge_reminders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE d record; ppl record; r bms.charge_reminders; v_months text;
        v_name text; v_mobile text; v_rel text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_channel NOT IN ('WHATSAPP','SMS','COPY','IMAGE','PDF','PRINT') THEN RAISE EXCEPTION 'Unknown channel %', p_channel; END IF;
  IF p_tone NOT IN ('GENTLE','FOLLOW_UP','FIRM') THEN RAISE EXCEPTION 'Unknown tone %', p_tone; END IF;
  IF p_lang NOT IN ('en','bn') THEN RAISE EXCEPTION 'Unknown language %', p_lang; END IF;
  IF COALESCE(btrim(p_message), '') = '' THEN RAISE EXCEPTION 'The message is empty'; END IF;

  SELECT * INTO d FROM bms.v_flat_dues WHERE flat_id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;
  IF COALESCE(d.outstanding, 0) <= 0 THEN
    RAISE EXCEPTION 'Flat % owes nothing now, so no reminder was recorded.', d.flat_number
      USING ERRCODE = '23514';
  END IF;

  SELECT * INTO ppl FROM bms.v_flat_people WHERE flat_id = p_flat;
  v_rel    := ppl.billed_relation;
  v_name   := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_name   WHEN 'OWNER' THEN ppl.owner_name   END;
  v_mobile := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_mobile WHEN 'OWNER' THEN ppl.owner_mobile END;

  SELECT string_agg(CASE WHEN charge_source = 'OPENING' THEN 'earlier balance'
                         ELSE to_char(make_date(period_year, period_month, 1), 'Mon YYYY') END,
                    ', ' ORDER BY period_year, period_month)
    INTO v_months
    FROM bms.v_flat_charges
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED')
     AND NOT not_due_yet;

  INSERT INTO bms.charge_reminders (flat_id, sent_by, channel, tone, lang,
                                    recipient_name, relation, phone, phone_sent,
                                    amount_due, months, message)
  VALUES (p_flat, auth.uid(), p_channel, p_tone, p_lang,
          v_name, v_rel, v_mobile, bms.normalize_mobile(v_mobile),
          d.outstanding, v_months, left(p_message, 4000))
  RETURNING * INTO r;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION bms.month_bills(p_year int, p_month int)
RETURNS TABLE (flat_id uuid, flat_number text, floor int,
               payer_id uuid, payer_name text, payer_mobile text, payer_relation text,
               this_month numeric(14,2), this_month_due numeric(14,2), previous_due numeric(14,2),
               total_due numeric(14,2), advance numeric(14,2), rate_source text, rate_reason text,
               due_date date, is_billed boolean, last_sent_at timestamptz, times_sent int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM bms.assert_perm('charges','view');
  IF p_month < 1 OR p_month > 12 THEN RAISE EXCEPTION 'Month must be 1-12'; END IF;
  RETURN QUERY
  SELECT f.id, f.flat_number, f.floor,
         bill.owner_id, bp.name, bp.mobile, bill.relation_type,
         COALESCE(fc.net_payable, 0)::numeric(14,2),
         COALESCE(fc.due_amount, 0)::numeric(14,2),
         COALESCE(prev.due, 0)::numeric(14,2),
         (COALESCE(prev.due, 0) + GREATEST(COALESCE(fc.due_amount, 0), 0))::numeric(14,2),
         COALESCE(d.advance, 0)::numeric(14,2),
         r.source, r.reason,
         COALESCE(fc.due_date, make_date(p_year, p_month, LEAST(s.charge_due_day, 28))),
         fc.id IS NOT NULL, bn.last_sent, COALESCE(bn.n, 0)::int
    FROM bms.flats f
    CROSS JOIN bms.building_settings s
    LEFT JOIN bms.v_flat_charges fc ON fc.flat_id = f.id AND fc.period_year = p_year
                                   AND fc.period_month = p_month AND fc.charge_source = 'MONTHLY'
                                   AND NOT fc.is_cancelled
    LEFT JOIN bms.v_flat_dues d ON d.flat_id = f.id
    -- Earlier dues are the months BEFORE this one — never a later month
    -- billed ahead of time.
    LEFT JOIN LATERAL (SELECT SUM(GREATEST(x.due_amount, 0)) AS due FROM bms.v_flat_charges x
                        WHERE x.flat_id = f.id AND NOT x.is_cancelled
                          AND (x.charge_source = 'OPENING'
                               OR make_date(x.period_year, x.period_month, 1) < make_date(p_year, p_month, 1))) prev ON true
    LEFT JOIN LATERAL (SELECT fo.owner_id, fo.relation_type FROM bms.flat_occupancy fo
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) bill ON true
    LEFT JOIN bms.owners bp ON bp.id = bill.owner_id
    LEFT JOIN LATERAL bms.flat_rate_for(f.id, make_date(p_year, p_month, 1)) r ON true
    LEFT JOIN LATERAL (SELECT MAX(b.sent_at) AS last_sent, COUNT(*) AS n FROM bms.bill_notices b
                        WHERE b.flat_id = f.id AND b.period_year = p_year AND b.period_month = p_month) bn ON true
   WHERE s.id AND (f.status = 'ACTIVE' OR COALESCE(prev.due, 0) > 0 OR COALESCE(fc.due_amount, 0) > 0)
   ORDER BY bp.name NULLS LAST, f.floor, f.flat_number;
END $$;

REVOKE ALL ON FUNCTION bms.reminder_context(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.reminder_context(uuid) TO authenticated;
REVOKE ALL ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION bms.month_bills(int,int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.month_bills(int,int) TO authenticated;

-- END 093_billed_ahead.sql


-- =====================================================================
-- Done. Run sql/VERIFY.sql next to confirm what landed.
-- =====================================================================
DO $bundle$
DECLARE t int; f int; p int;
BEGIN
  SELECT COUNT(*) INTO t FROM pg_tables  WHERE schemaname = 'bms';
  SELECT COUNT(*) INTO f FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'bms';
  SELECT COUNT(*) INTO p FROM pg_policies WHERE schemaname = 'bms';
  RAISE NOTICE 'Building portal installed: % tables, % functions, % RLS policies.', t, f, p;
END $bundle$;
