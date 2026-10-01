-- =====================================================================
-- t05 — OPERATIONS, lived end to end.
--
-- A power cut, a diesel run, a lift service, a fire inspection, a broken
-- lift reported and fixed, a month of attendance, a salary with an
-- absence and an advance recovered from it, and a cleaning round half
-- done. Money is re-checked after every step that should have moved it,
-- and after several that should not.
-- =====================================================================
SET t.suite = 't05 operations';
SET search_path = bms, public;

-- Everything below happens in the month just gone, so the suite reads the
-- same whatever day it is run and never logs anything in the future.
CREATE OR REPLACE FUNCTION t.pm() RETURNS date
LANGUAGE sql STABLE AS $$ SELECT date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date $$;
CREATE OR REPLACE FUNCTION t.pm_year()  RETURNS int
LANGUAGE sql STABLE AS $$ SELECT EXTRACT(YEAR  FROM t.pm())::int $$;
CREATE OR REPLACE FUNCTION t.pm_month() RETURNS int
LANGUAGE sql STABLE AS $$ SELECT EXTRACT(MONTH FROM t.pm())::int $$;
CREATE OR REPLACE FUNCTION t.pm_days()  RETURNS int
LANGUAGE sql STABLE AS $$ SELECT EXTRACT(DAY FROM (t.pm() + INTERVAL '1 month - 1 day'))::int $$;

-- The lift service has to be far enough back that a 30-day interval has
-- definitely lapsed, whatever day the suite runs. Anchoring it to
-- t.pm() + 7 did not: run on the 2nd of a month that is only three weeks
-- past a service, and the lift reads DUE_SOON rather than OVERDUE. The
-- test then passed for most of the month and failed for the first few
-- days, which is worse than failing always.
CREATE OR REPLACE FUNCTION t.svc_date()  RETURNS date
LANGUAGE sql STABLE AS $$ SELECT (CURRENT_DATE - 45) $$;
CREATE OR REPLACE FUNCTION t.svc_year()  RETURNS int
LANGUAGE sql STABLE AS $$ SELECT EXTRACT(YEAR  FROM t.svc_date())::int $$;
CREATE OR REPLACE FUNCTION t.svc_month() RETURNS int
LANGUAGE sql STABLE AS $$ SELECT EXTRACT(MONTH FROM t.svc_date())::int $$;

-- ---------------------------------------------------------------------
-- 1. THE BUILDING'S EQUIPMENT IS REGISTERED.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

INSERT INTO bms.assets (asset_code, asset_type, name, location, floor, capacity,
                        installation_date, service_interval_days, next_service_date,
                        department_id, specs)
VALUES ('GEN-01','GENERATOR','Main generator','Ground floor plant room', 0, '150 kVA',
        DATE '2022-04-01', 180, CURRENT_DATE + 10,
        (SELECT id FROM bms.departments WHERE code='GENERATOR'),
        '{"fuel_type":"diesel","tank_litres":250}'::jsonb),
       ('LIFT-01','LIFT','Passenger lift','Lobby', 0, '8 persons',
        DATE '2022-04-01', 30, CURRENT_DATE + 5,
        (SELECT id FROM bms.departments WHERE code='LIFT'),
        '{"floors_served":9,"brand":"Mitsubishi"}'::jsonb),
       ('FE-0101','FIRE_EXTINGUISHER','Extinguisher 1F-A','Floor 1 landing', 1, '5 kg',
        DATE '2024-01-15', 180, NULL,
        (SELECT id FROM bms.departments WHERE code='MAINTENANCE'),
        '{"class":"ABC","refill_due":"2027-01-15"}'::jsonb),
       ('FE-0102','FIRE_EXTINGUISHER','Extinguisher 1F-B','Floor 1 stairwell', 1, '5 kg',
        DATE '2024-01-15', 180, NULL,
        (SELECT id FROM bms.departments WHERE code='MAINTENANCE'),
        '{"class":"ABC"}'::jsonb)
ON CONFLICT (asset_code) DO NOTHING;

SELECT t.remember('gen',  (SELECT id::text FROM bms.assets WHERE asset_code='GEN-01'));
SELECT t.remember('lift', (SELECT id::text FROM bms.assets WHERE asset_code='LIFT-01'));
SELECT t.remember('fe1',  (SELECT id::text FROM bms.assets WHERE asset_code='FE-0101'));
SELECT t.remember('fe2',  (SELECT id::text FROM bms.assets WHERE asset_code='FE-0102'));

SELECT t.eq('four assets registered', 4::bigint, (SELECT COUNT(*) FROM bms.assets));
SELECT t.eq('one register, three different kinds of thing', 3::bigint,
  (SELECT COUNT(DISTINCT asset_type) FROM bms.assets));
SELECT t.eq('the generator is governed by the generator module', 'generator',
  (SELECT module_code FROM bms.v_assets WHERE asset_code='GEN-01'));
SELECT t.eq('an extinguisher is governed by the fire module', 'fire',
  (SELECT module_code FROM bms.v_assets WHERE asset_code='FE-0101'));
SELECT t.eq('type-specific details are kept without new columns', 'Mitsubishi',
  (SELECT specs->>'brand' FROM bms.assets WHERE asset_code='LIFT-01'));

-- Fire extinguishers have never been inspected, so they are not "OK".
SELECT t.eq('an extinguisher with no inspection reads as unknown, not fine', 'UNKNOWN',
  (SELECT inspection_status FROM bms.v_assets WHERE asset_code='FE-0101'));

SELECT t.remember('cash0', (SELECT current_balance::text FROM bms.v_account_balances WHERE code='CASH'));

-- ---------------------------------------------------------------------
-- 2. A POWER CUT, AND THE CARETAKER LOGS THE RUN.
-- ---------------------------------------------------------------------
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);

SELECT t.remember('run1', (bms.log_generator_run(
    t.uid('gen'),
    (t.pm() + INTERVAL '3 days 18 hours 30 minutes')::timestamptz,  -- generator started
    (t.pm() + INTERVAL '3 days 21 hours')::timestamptz,              -- and stopped
    (t.pm() + INTERVAL '3 days 18 hours 28 minutes')::timestamptz,   -- power went at
    (t.pm() + INTERVAL '3 days 21 hours 2 minutes')::timestamptz,    -- and came back
    'POWER_CUT', 1204.0, 1206.5, 9.5, 'Ran smoothly')).id::text);

SELECT t.eq('the run duration is computed, not typed in', 150,
  (SELECT duration_minutes FROM bms.generator_runs WHERE id = t.uid('run1')));
SELECT t.eq('the hour meter reading was captured too', 1206.50::numeric,
  (SELECT reading_value FROM bms.asset_meter_readings
    WHERE asset_id = t.uid('gen') AND reading_date = (t.pm() + 3)));
SELECT t.eq('two and a half hours show in the monthly summary', 2.50::numeric,
  (SELECT hours_run FROM bms.v_generator_monthly
    WHERE asset_id = t.uid('gen') AND period_year=t.pm_year() AND period_month=t.pm_month()));

SELECT t.throws('the generator log refuses a stop before the start',
  $$SELECT bms.log_generator_run((SELECT id FROM bms.assets WHERE asset_code='GEN-01'),
      (t.pm() + INTERVAL '4 days 20 hours')::timestamptz,
      (t.pm() + INTERVAL '4 days 19 hours')::timestamptz)$$,
  'cannot stop before it started');
SELECT t.throws('and refuses a run logged for next week',
  $$SELECT bms.log_generator_run((SELECT id FROM bms.assets WHERE asset_code='GEN-01'),
      now() + INTERVAL '7 days')$$,
  'future time');
SELECT t.throws('and refuses to log a run against the lift',
  $$SELECT bms.log_generator_run((SELECT id FROM bms.assets WHERE asset_code='LIFT-01'),
      (t.pm() + INTERVAL '4 days 20 hours')::timestamptz)$$,
  'not a generator');

-- A run left open is a real situation: log the start now, close it later.
SELECT t.remember('run2', (bms.log_generator_run(
    t.uid('gen'), (t.pm() + INTERVAL '5 days 14 hours')::timestamptz)).id::text);
SELECT t.ok('an open run has no duration yet',
  (SELECT duration_minutes IS NULL FROM bms.generator_runs WHERE id = t.uid('run2')));
SELECT t.runs('the caretaker closes it when the power returns',
  'SELECT bms.close_generator_run(''' || t.recall('run2') || ''', (t.pm() + INTERVAL ''5 days 15 hours 30 minutes'')::timestamptz, 1208.0)');
SELECT t.eq('and now it has one', 90,
  (SELECT duration_minutes FROM bms.generator_runs WHERE id = t.uid('run2')));

-- ---------------------------------------------------------------------
-- 3. DIESEL — bought by the caretaker, approved by the manager.
-- ---------------------------------------------------------------------
SELECT t.remember('fuel1', (bms.record_fuel_purchase(
    t.uid('gen'), (t.pm() + 6), 'DIESEL', 40.0, 109.00,
    'LITRE', NULL, 'INV-8823', 1208.0)).id::text);

SELECT t.eq('the total is computed from quantity and price', 4360.00::numeric,
  (SELECT total_amount FROM bms.fuel_purchases WHERE id = t.uid('fuel1')));
SELECT t.eq('the caretaker''s fuel bill waits for approval', 'PENDING_APPROVAL',
  (SELECT status FROM bms.my_submissions()
    WHERE id = (SELECT txn_id FROM bms.fuel_purchases WHERE id = t.uid('fuel1'))));
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('manager'), false);
SELECT t.eq('no money moved while the bill was waiting', t.recall('cash0')::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='CASH'));
SELECT t.runs('the manager approves the fuel bill',
  $$SELECT bms.approve_transaction(
      (SELECT txn_id FROM bms.fuel_purchases WHERE invoice_no = 'INV-8823'))$$);
SELECT t.eq('petty cash falls by the fuel bill', -4360.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='CASH'));
SELECT t.eq('the generator department carries the cost', 4360.00::numeric,
  (SELECT expense FROM bms.v_department_spend
    WHERE code='GENERATOR' AND period_year=t.pm_year() AND period_month=t.pm_month()));
SELECT t.eq('fuel per hour is worked out for the committee', 10.00::numeric,
  (SELECT litres_per_hour FROM bms.v_generator_monthly
    WHERE asset_id = t.uid('gen') AND period_year=t.pm_year() AND period_month=t.pm_month()));

-- ---------------------------------------------------------------------
-- 4. THE LIFT'S MONTHLY SERVICE, WITH A PART.
-- ---------------------------------------------------------------------
SELECT t.remember('svc1', (bms.record_asset_service(
    t.uid('lift'), t.svc_date(), 'ROUTINE',
    'Monthly AMC visit — door sensor replaced',
    5500.00, NULL, 'Rafiq (Mitsubishi)', NULL, NULL, 'BANK_TRANSFER',
    '[{"part_name":"Door sensor","quantity":1,"unit_cost":3200,"warranty_months":12}]'::jsonb)).id::text);

SELECT t.eq('the part is recorded against the service', 3200.00::numeric,
  (SELECT total_cost FROM bms.asset_parts WHERE service_log_id = t.uid('svc1')));
SELECT t.eq('the next service date is set from the lift''s own interval',
  (t.svc_date() + 30), (SELECT next_due_date FROM bms.asset_service_logs WHERE id = t.uid('svc1')));
-- The visit was 45 days ago and the lift is on a 30-day interval, so the
-- register correctly says it is already due again — and says so on any
-- day the suite is run, which is the point of t.svc_date().
SELECT t.eq('the lift is due for service again, and says so', 'OVERDUE',
  (SELECT service_status FROM bms.v_assets WHERE asset_code='LIFT-01'));
SELECT t.ok('and that reaches the dashboard',
  EXISTS (SELECT 1 FROM bms.v_dashboard_alerts WHERE alert_type = 'SERVICE_OVERDUE'));
-- Tk 5,500 is above the manager's Tk 5,000 auto-post limit, so even the
-- person who recorded the service cannot make it real on their own.
SELECT t.eq('the service cost waits for a second person', 'PENDING_APPROVAL',
  (SELECT status FROM bms.transactions
    WHERE id = (SELECT txn_id FROM bms.asset_service_logs WHERE id = t.uid('svc1'))));
SELECT t.eq('so it is not yet in the lift department''s spending', 0::bigint,
  (SELECT COUNT(*) FROM bms.v_department_spend
    WHERE code='LIFT' AND period_year=t.svc_year() AND period_month=t.svc_month()));
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('an admin approves the lift service',
  $$SELECT bms.approve_transaction(
      (SELECT txn_id FROM bms.asset_service_logs
        WHERE description LIKE 'Monthly AMC%'))$$);
SELECT t.eq('now the cost reaches the lift department', 5500.00::numeric,
  (SELECT expense FROM bms.v_department_spend
    WHERE code='LIFT' AND period_year=t.svc_year() AND period_month=t.svc_month()));

-- ---------------------------------------------------------------------
-- 5. FIRE SAFETY — the red/amber/green that the spec asked for.
-- ---------------------------------------------------------------------
SELECT t.runs('extinguisher 1F-A passes inspection',
  $$SELECT bms.record_inspection(
      (SELECT id FROM bms.assets WHERE asset_code='FE-0101'),
      CURRENT_DATE, 'PASS', CURRENT_DATE + 180, 'Fire Safety BD', true, true, true)$$);
SELECT t.eq('a freshly inspected extinguisher is green', 'OK',
  (SELECT inspection_status FROM bms.v_assets WHERE asset_code='FE-0101'));

-- The second one was last inspected long ago.
SELECT t.runs('extinguisher 1F-B was inspected a year ago and is now overdue',
  $$SELECT bms.record_inspection(
      (SELECT id FROM bms.assets WHERE asset_code='FE-0102'),
      CURRENT_DATE - 400, 'PASS', CURRENT_DATE - 40)$$);
SELECT t.eq('an extinguisher past its date is red', 'OVERDUE',
  (SELECT inspection_status FROM bms.v_assets WHERE asset_code='FE-0102'));
SELECT t.ok('and it reaches the dashboard as an alert',
  EXISTS (SELECT 1 FROM bms.v_dashboard_alerts
           WHERE alert_type = 'INSPECTION_OVERDUE' AND severity = 'HIGH'));

-- A failed inspection downgrades the extinguisher's condition.
SELECT t.runs('a failed inspection is recorded',
  $$SELECT bms.record_inspection(
      (SELECT id FROM bms.assets WHERE asset_code='FE-0102'),
      CURRENT_DATE, 'FAIL', CURRENT_DATE + 30, 'Fire Safety BD', false, true, true,
      'Pressure gauge in the red — needs refilling')$$);
SELECT t.eq('the extinguisher''s condition follows the inspection', 'POOR',
  (SELECT condition FROM bms.assets WHERE asset_code='FE-0102'));

-- ---------------------------------------------------------------------
-- 6. THE LIFT BREAKS. Reported, assigned, fixed, checked.
-- ---------------------------------------------------------------------
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
-- (the caretaker is back at the wheel)

SELECT t.remember('iss1', (bms.create_issue(
    'Lift stopping between floors 3 and 4',
    'Passengers had to be helped out this morning.',
    'CRITICAL',
    (SELECT id FROM bms.departments WHERE code='LIFT'),
    t.uid('lift'), NULL, 'Lift shaft', 3)).id::text);

SELECT t.ok('the issue gets a readable number',
  (SELECT issue_no FROM bms.v_issues WHERE id = t.uid('iss1')) LIKE 'ISS-%');
SELECT t.eq('a critical issue gets the shortest target time', true,
  (SELECT due_at <= reported_at + INTERVAL '4 hours' FROM bms.issues WHERE id = t.uid('iss1')));
SELECT t.eq('it starts as open', 'OPEN',
  (SELECT status FROM bms.v_issues WHERE id = t.uid('iss1')));
SELECT t.eq('reporting it is the first line of its history', 1::bigint,
  (SELECT COUNT(*) FROM bms.issue_updates WHERE issue_id = t.uid('iss1')));
-- The caretaker may report and progress work, but signing off that it is
-- genuinely fixed needs maintenance.approve, which the role does not hold.
SELECT t.ok('a caretaker cannot verify work at all',
  NOT bms.has_perm('maintenance','approve'));
SELECT t.throws('and the database refuses if they try',
  'SELECT bms.update_issue(''' || t.recall('iss1') || ''', ''VERIFIED'')',
  'permission denied');
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('manager'), false);
SELECT t.runs('the manager assigns it to the lift company',
  'SELECT bms.update_issue(''' || t.recall('iss1') || ''', ''ASSIGNED'', ''Called Mitsubishi'')');
SELECT t.throws('it cannot jump straight to verified',
  'SELECT bms.update_issue(''' || t.recall('iss1') || ''', ''VERIFIED'')',
  'Only a completed issue can be verified');
SELECT t.runs('the work is done and the cost recorded',
  'SELECT bms.update_issue(''' || t.recall('iss1') || ''', ''COMPLETED'',
      ''Controller board replaced'', NULL, NULL, 18000.00, ''Board replaced under call-out'')');
SELECT t.throws('the person who marked it complete cannot also verify it',
  'SELECT bms.update_issue(''' || t.recall('iss1') || ''', ''VERIFIED'', ''Looks fine'')',
  'someone else must verify');
SELECT t.eq('the repair cost became a real expense', 18000.00::numeric,
  (SELECT amount FROM bms.transactions
    WHERE id = (SELECT txn_id FROM bms.issues WHERE id = t.uid('iss1'))));
SELECT t.eq('and it is waiting for approval, being over the manager''s limit', 'PENDING_APPROVAL',
  (SELECT status FROM bms.transactions
    WHERE id = (SELECT txn_id FROM bms.issues WHERE id = t.uid('iss1'))));
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('so the admin checks the work instead',
  'SELECT bms.update_issue(''' || t.recall('iss1') || ''', ''VERIFIED'', ''Rode it to every floor'')');
SELECT t.eq('the issue is closed out', 'VERIFIED',
  (SELECT status FROM bms.v_issues WHERE id = t.uid('iss1')));
SELECT t.eq('its whole history is on record', 4::bigint,
  (SELECT COUNT(*) FROM bms.issue_updates WHERE issue_id = t.uid('iss1')));
SELECT t.ok('and the time it took is worked out',
  (SELECT hours_to_complete IS NOT NULL FROM bms.v_issues WHERE id = t.uid('iss1')));

-- ---------------------------------------------------------------------
-- 7. STAFF, ATTENDANCE AND A SALARY WITH AN ABSENCE IN IT.
-- ---------------------------------------------------------------------
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

INSERT INTO bms.staff (staff_code, name, position_id, mobile, joining_date, salary, shift)
VALUES ('S-001','Abdul Karim', (SELECT id FROM bms.staff_positions WHERE code='SECURITY'),
        '01712000001', DATE '2024-01-01', 12000.00, 'NIGHT'),
       ('S-002','Rina Akter',  (SELECT id FROM bms.staff_positions WHERE code='CLEANER'),
        '01712000002', DATE '2024-03-01', 9000.00, 'MORNING')
ON CONFLICT (staff_code) DO NOTHING;

SELECT t.remember('guard',   (SELECT id::text FROM bms.staff WHERE staff_code='S-001'));
SELECT t.remember('cleaner', (SELECT id::text FROM bms.staff WHERE staff_code='S-002'));

SELECT t.eq('the guard sits under the security department', 'Security',
  (SELECT department_name FROM bms.v_staff WHERE staff_code='S-001'));
SELECT t.eq('the cleaner sits under cleaning', 'Cleaning',
  (SELECT department_name FROM bms.v_staff WHERE staff_code='S-002'));

-- Two days of attendance: everyone in on the 1st, the cleaner absent on the 2nd.
SELECT t.eq('attendance is marked for both staff', 2,
  bms.mark_attendance(t.pm(), format(
    '[{"staff_id":"%s","status":"PRESENT"},{"staff_id":"%s","status":"PRESENT"}]',
    t.recall('guard'), t.recall('cleaner'))::jsonb));
SELECT t.eq('and again the next day, with one absence', 2,
  bms.mark_attendance(t.pm() + 1, format(
    '[{"staff_id":"%s","status":"PRESENT"},{"staff_id":"%s","status":"ABSENT"}]',
    t.recall('guard'), t.recall('cleaner'))::jsonb));

SELECT t.eq('marking the same day twice corrects it rather than duplicating', 2::bigint,
  (SELECT COUNT(*) FROM bms.staff_attendance WHERE work_date = t.pm() + 1));
SELECT t.eq('the cleaner has one absence that month', 1::bigint,
  (SELECT absent_days FROM bms.v_attendance_monthly
    WHERE staff_id = t.uid('cleaner')
      AND period_year=t.pm_year() AND period_month=t.pm_month()));
SELECT t.throws('attendance cannot be marked for a future date',
  $$SELECT bms.mark_attendance(CURRENT_DATE + 1, '[]'::jsonb)$$, 'future date');

-- An advance, to be recovered from the salary.
SELECT t.runs('the cleaner takes a Tk 2,000 advance',
  $$SELECT bms.record_staff_advance(
      (SELECT id FROM bms.staff WHERE staff_code='S-002'), t.pm() + 4, 2000.00,
      (SELECT id FROM bms.accounts WHERE code='CASH'), 'Medical')$$);
SELECT t.eq('the advance shows against the cleaner', 2000.00::numeric,
  (SELECT advance_outstanding FROM bms.v_staff WHERE staff_code='S-002'));

SELECT t.runs('last month''s salary is generated',
  'SELECT bms.generate_salary_run(t.pm_year(), t.pm_month())');
SELECT t.eq('both staff are on the run', 2::bigint,
  (SELECT COUNT(*) FROM bms.v_salary_payments
    WHERE period_year=t.pm_year() AND period_month=t.pm_month()));
SELECT t.eq('the guard, who was never absent, is paid in full', 12000.00::numeric,
  (SELECT net_payable FROM bms.v_salary_payments
    WHERE staff_code='S-001' AND period_year=t.pm_year()));

-- One absent day costs one day's pay, worked out from that month's length.
SELECT t.eq('one absent day costs exactly one day''s pay',
  ROUND(9000.0 / t.pm_days(), 2),
  (SELECT deduction FROM bms.v_salary_payments
    WHERE staff_code='S-002' AND period_year=t.pm_year()));
SELECT t.eq('the advance is recovered from the same payslip', 2000.00::numeric,
  (SELECT advance_recovery FROM bms.v_salary_payments
    WHERE staff_code='S-002' AND period_year=t.pm_year()));
SELECT t.eq('and the net is what is left',
  ROUND(9000.0 - ROUND(9000.0 / t.pm_days(), 2) - 2000.00, 2),
  (SELECT net_payable FROM bms.v_salary_payments
    WHERE staff_code='S-002' AND period_year=t.pm_year()));
SELECT t.throws('a month cannot be generated twice',
  'SELECT bms.generate_salary_run(t.pm_year(), t.pm_month())', 'already been generated');

SELECT t.remember('bank_before_salary',
  (SELECT current_balance::text FROM bms.v_account_balances WHERE code='BANK1'));

SELECT t.runs('the cleaner is paid',
  $$SELECT bms.pay_salary(
      (SELECT sp.id FROM bms.salary_payments sp JOIN bms.staff s ON s.id = sp.staff_id
        WHERE s.staff_code='S-002'), CURRENT_DATE,
      (SELECT id FROM bms.accounts WHERE code='BANK1'), 'BANK_TRANSFER')$$);

SELECT t.eq('the bank falls by the net pay, not the gross',
  (t.recall('bank_before_salary')::numeric - ROUND(9000.0 - ROUND(9000.0 / t.pm_days(), 2) - 2000.00, 2)),
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));
SELECT t.eq('the advance is now fully recovered', 0.00::numeric,
  (SELECT advance_outstanding FROM bms.v_staff WHERE staff_code='S-002'));
SELECT t.eq('the salary landed in the cleaning department',
  ROUND(9000.0 - ROUND(9000.0 / t.pm_days(), 2) - 2000.00, 2),
  (SELECT expense FROM bms.v_department_spend
    WHERE code='CLEANING'
      AND period_year=EXTRACT(YEAR FROM CURRENT_DATE)::int
      AND period_month=EXTRACT(MONTH FROM CURRENT_DATE)::int));
SELECT t.throws('the same salary cannot be paid twice',
  $$SELECT bms.pay_salary(
      (SELECT sp.id FROM bms.salary_payments sp JOIN bms.staff s ON s.id = sp.staff_id
        WHERE s.staff_code='S-002'), CURRENT_DATE,
      (SELECT id FROM bms.accounts WHERE code='BANK1'))$$, 'already been paid');

-- ---------------------------------------------------------------------
-- 8. THE CLEANING ROUND — four of six items done.
-- ---------------------------------------------------------------------
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);

SELECT t.remember('wl1', (bms.save_work_log(
    (SELECT id FROM bms.work_checklist_templates WHERE code='CLEAN_DAILY'),
    t.uid('cleaner'), t.pm() + 1,
    (SELECT jsonb_agg(jsonb_build_object('item_id', i.id, 'is_done', i.sort_order <= 40))
       FROM bms.work_checklist_items i
       JOIN bms.work_checklist_templates tp ON tp.id = i.template_id
      WHERE tp.code = 'CLEAN_DAILY'),
    'Roof left for tomorrow')).id::text);

SELECT t.eq('four of the six items were ticked', 4::bigint,
  (SELECT done_count FROM bms.v_work_logs WHERE id = t.uid('wl1')));
SELECT t.eq('so the round counts as partial, not done', 'PARTIAL',
  (SELECT overall_status FROM bms.v_work_logs WHERE id = t.uid('wl1')));
SELECT t.eq('the checklist itself is data, not code', 6::bigint,
  (SELECT COUNT(*) FROM bms.work_checklist_items i
     JOIN bms.work_checklist_templates tp ON tp.id = i.template_id
    WHERE tp.code = 'CLEAN_DAILY'));

-- Saving the same day again corrects it instead of creating a second log.
SELECT t.runs('the caretaker finishes the roof and saves again',
  format($$SELECT bms.save_work_log(
      (SELECT id FROM bms.work_checklist_templates WHERE code='CLEAN_DAILY'),
      '%s'::uuid, t.pm() + 1,
      (SELECT jsonb_agg(jsonb_build_object('item_id', i.id, 'is_done', true))
         FROM bms.work_checklist_items i
         JOIN bms.work_checklist_templates tp ON tp.id = i.template_id
        WHERE tp.code = 'CLEAN_DAILY'), 'All done')$$, t.recall('cleaner')));
SELECT t.eq('there is still only one log for that day', 1::bigint,
  (SELECT COUNT(*) FROM bms.work_logs WHERE log_date = t.pm() + 1));
SELECT t.eq('and it now reads as done', 'DONE',
  (SELECT overall_status FROM bms.v_work_logs WHERE id = t.uid('wl1')));
SELECT t.throws('a work log cannot be dated in the future',
  format($$SELECT bms.save_work_log(
      (SELECT id FROM bms.work_checklist_templates WHERE code='CLEAN_DAILY'),
      '%s'::uuid, CURRENT_DATE + 1, '[]'::jsonb)$$, t.recall('cleaner')),
  'future');

-- ---------------------------------------------------------------------
-- 9. WHO CAN SEE AND DO WHAT.
-- ---------------------------------------------------------------------
SELECT t.ok('the caretaker can see the equipment', (SELECT COUNT(*) FROM bms.assets) = 4);
SELECT t.eq('but cannot see salaries', 0::bigint, (SELECT COUNT(*) FROM bms.salary_payments));
SELECT t.eq('nor staff advances',     0::bigint, (SELECT COUNT(*) FROM bms.staff_advances));
SELECT t.ok('and cannot pay one',     NOT bms.has_perm('salary','edit'));

-- A caretaker may record that the lift is in poor condition — that is
-- day-to-day work — but may not take it off the register.
SELECT t.runs('a caretaker can record the lift''s condition',
  $$UPDATE bms.assets SET condition = 'FAIR' WHERE asset_code = 'LIFT-01'$$);
SELECT t.throws('but cannot retire it',
  $$UPDATE bms.assets SET status = 'RETIRED' WHERE asset_code = 'LIFT-01'$$,
  'needs approval rights');
SELECT t.eq('so the lift is still on the register', 'ACTIVE',
  (SELECT status FROM bms.assets WHERE asset_code='LIFT-01'));
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('committee'), false);
SELECT t.ok('a committee member can see the equipment', (SELECT COUNT(*) FROM bms.assets) > 0);
SELECT t.eq('but sees no salary lines', 0::bigint, (SELECT COUNT(*) FROM bms.salary_payments));
SELECT t.throws('and cannot log a generator run',
  format($$SELECT bms.log_generator_run('%s'::uuid, now())$$, t.recall('gen')),
  'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------
-- 10. WHAT THE BUILDING'S EQUIPMENT COST THIS MONTH.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.eq('generator: fuel only, so far', 4360.00::numeric,
  (SELECT fuel_cost FROM bms.v_generator_monthly
    WHERE asset_id = t.uid('gen') AND period_year=t.pm_year() AND period_month=t.pm_month()));
SELECT t.eq('the lift''s service cost shows against the lift', 5500.00::numeric,
  (SELECT service_cost_ytd FROM bms.v_assets WHERE asset_code='LIFT-01'));
SELECT t.ok('the Tk 18,000 lift repair is still not counted — nobody has approved it',
  (SELECT COALESCE(SUM(expense),0) FROM bms.v_department_spend WHERE code='LIFT') = 5500.00);
SELECT t.eq('and it is visible as a pending approval on the dashboard', true,
  EXISTS (SELECT 1 FROM bms.v_dashboard_alerts WHERE alert_type = 'PENDING_APPROVAL'));

SELECT t.ok('every operations action is in the audit log, with a name',
  EXISTS (SELECT 1 FROM bms.audit_log WHERE entity_table='generator_runs')
  AND EXISTS (SELECT 1 FROM bms.audit_log WHERE entity_table='issues')
  AND EXISTS (SELECT 1 FROM bms.audit_log WHERE entity_table='salary_payments'
                AND actor_name_snapshot IS NOT NULL));

RESET ROLE;
