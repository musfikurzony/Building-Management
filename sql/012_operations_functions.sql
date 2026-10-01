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
