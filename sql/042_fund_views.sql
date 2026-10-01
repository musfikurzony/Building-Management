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
