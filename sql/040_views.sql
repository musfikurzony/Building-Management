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
