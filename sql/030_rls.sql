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
