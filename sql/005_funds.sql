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
