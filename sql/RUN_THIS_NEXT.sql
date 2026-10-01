-- =====================================================================
-- RUN_THIS_NEXT.sql
--
-- The two migrations your live database is missing, in one file, in the
-- right order. Paste the whole thing into the Supabase SQL Editor and
-- run it once.
--
--   070_reset.sql   the "Start fresh" buttons at the bottom of Settings
--   080_roles.sql   custom roles, the categories usage check, AND a
--                   privilege fix: without it any account holding the
--                   plain Admin role can make itself a Super Admin.
--
-- Safe to run twice. It creates and replaces functions and triggers; it
-- does not touch a single row of your data.
--
-- If you would rather run everything from scratch, sql/BUNDLE_all.sql
-- includes both of these and is also safe to run twice.
-- =====================================================================

-- ============ 070_reset.sql ============
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
DECLARE v_entries bigint; v_masters bigint;
BEGIN
  IF NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can reset the system' USING ERRCODE = '42501';
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
      'notifications',     (SELECT count(*) FROM bms.notifications)),
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

  -- Children before parents, throughout.
  DELETE FROM bms.work_log_items;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.work_logs;             GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.staff_attendance;      GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.staff_leaves;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.staff_advances;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.salary_payments;       GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.salary_runs;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.issue_updates;         GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.issues;                GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.asset_parts;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.asset_service_logs;    GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.asset_inspections;     GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.asset_meter_readings;  GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.generator_runs;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.fuel_purchases;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.reconciliations;       GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.bank_statement_lines;  GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.bank_statements;       GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.fd_events;             GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.fixed_deposits;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.fund_movements;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.budget_lines;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.budgets;               GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.adjustments;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.payment_allocations;   GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.payments;              GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.charge_line_items;     GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.flat_charges;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.charge_runs;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.attachments;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.ledger_entries;        GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.transactions;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.accounting_periods;    GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
  DELETE FROM bms.notifications;         GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;

  -- Document numbers start from 1 again, or the first new voucher would
  -- be numbered as though the deleted ones had happened.
  DELETE FROM bms.doc_counters;

  IF p_scope = 'all' THEN
    DELETE FROM bms.flat_users;      GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.flat_occupancy;  GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.flats;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.owners;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.staff;           GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.assets;          GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.vendors;         GET DIAGNOSTICS n = ROW_COUNT; v_deleted := v_deleted + n;
    DELETE FROM bms.audit_log;
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

-- ============ 080_roles.sql ============
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
