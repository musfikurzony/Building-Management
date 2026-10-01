-- =====================================================================
-- PATCH.sql — the update, for a database that is already installed.
--
-- It replaces functions, triggers, policies, grants and indexes. Every
-- CREATE TABLE in it is IF NOT EXISTS, so on a database that already has
-- these tables they do nothing at all. Existing rows are not changed.
--
-- Supabase will still show "Potential issues detected", because it reads
-- the text and sees CREATE TABLE and DROP POLICY. Choose **Run without
-- RLS**. That does not mean running with security off — it means "run my
-- SQL as written, do not add statements of your own". This file switches
-- Row Level Security on for every table itself, and sql/VERIFY.sql will
-- confirm it afterwards.
--
-- Safe to run twice, and safe to run whether or not you managed the
-- previous update.
--
-- If you would rather run everything from scratch, sql/BUNDLE_all.sql is
-- the whole schema and is also safe to run twice. This file is the small
-- one.
-- =====================================================================


-- ============================================================
-- 002_finance.sql
-- ============================================================
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

-- ============================================================
-- 010_functions.sql
-- ============================================================
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

-- ============================================================
-- 011_charge_functions.sql
-- ============================================================
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

-- ============================================================
-- 030_rls.sql
-- ============================================================
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

-- ============================================================
-- 070_reset.sql
-- ============================================================
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

-- ============================================================
-- 080_roles.sql
-- ============================================================
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

-- ============================================================
-- 085_people_reminders.sql
-- ============================================================
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
