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
