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

-- ============================================================
-- 086_reports_funds.sql
-- ============================================================
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

-- ============================================================
-- 087_community_backup.sql
-- ============================================================
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

-- ============================================================
-- 088_storage_setup.sql
-- ============================================================
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

-- ============================================================
-- 089_owners_bills.sql
-- ============================================================
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

-- ============================================================
-- 090_storage.sql
-- ============================================================
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

-- ============================================================
-- 091_people_fixes.sql
-- ============================================================
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

-- ============================================================
-- 092_slip_channels.sql
-- ============================================================
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
