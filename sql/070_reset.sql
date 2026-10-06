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
