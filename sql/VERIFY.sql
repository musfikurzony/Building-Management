-- =====================================================================
-- VERIFY.sql — did the install actually work?
--
-- Paste into the Supabase SQL Editor and run. It changes NOTHING: every
-- statement is a read. It returns one row per check with a PASS or FAIL,
-- so you can see at a glance whether anything is missing.
--
-- Expect every row to say PASS. Any FAIL tells you which file to re-run.
-- =====================================================================

WITH checks AS (

  -- ---- schema and tables ----
  SELECT 1 AS ord, 'Schema' AS area, 'the bms schema exists' AS check_name,
         (SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'bms')::text AS found,
         '1' AS expected
  UNION ALL
  SELECT 2, 'Schema', 'tables created',
         (SELECT COUNT(*)::text FROM pg_tables WHERE schemaname = 'bms'), '>= 55'
  UNION ALL
  SELECT 3, 'Schema', 'views created',
         (SELECT COUNT(*)::text FROM pg_views WHERE schemaname = 'bms'), '>= 25'
  UNION ALL
  SELECT 4, 'Schema', 'functions created',
         (SELECT COUNT(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'bms'), '>= 50'
  UNION ALL
  SELECT 5, 'Schema', 'indexes created',
         (SELECT COUNT(*)::text FROM pg_indexes WHERE schemaname = 'bms'), '>= 60'

  -- ---- the tables that carry money, named individually ----
  UNION ALL
  SELECT 10, 'Core tables', 'every expected table is present',
         (SELECT COUNT(*)::text FROM unnest(ARRAY[
            'modules','permissions','roles','role_permissions','user_profiles','user_roles',
            'building_settings','departments','categories','vendors','accounts','account_secrets',
            'accounting_periods','transactions','ledger_entries','attachments','budgets','budget_lines',
            'owners','flats','flat_occupancy','flat_users','charge_runs','flat_charges',
            'charge_line_items','payments','payment_allocations','adjustments','doc_counters',
            'assets','asset_service_logs','asset_parts','asset_inspections','asset_meter_readings',
            'generator_runs','fuel_purchases','issues','issue_updates','staff_positions','staff',
            'staff_attendance','staff_leaves','staff_advances','salary_runs','salary_payments',
            'work_checklist_templates','work_checklist_items','work_logs','work_log_items',
            'funds','fund_movements','fixed_deposits','fd_events','bank_statements',
            'bank_statement_lines','reconciliations','notification_rules','notifications','audit_log'
          ]) AS n WHERE to_regclass('bms.' || n) IS NOT NULL), '59'

  -- ---- RLS: the security boundary ----
  UNION ALL
  SELECT 20, 'Security', 'tables WITHOUT row level security (must be zero)',
         (SELECT COUNT(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'bms' AND c.relkind = 'r' AND NOT c.relrowsecurity), '0'
  UNION ALL
  SELECT 21, 'Security', 'RLS policies defined',
         (SELECT COUNT(*)::text FROM pg_policies WHERE schemaname = 'bms'), '>= 90'
  UNION ALL
  SELECT 22, 'Security', 'the signed-out role has no access at all',
         (SELECT COUNT(*)::text FROM information_schema.role_table_grants
           WHERE table_schema = 'bms' AND grantee = 'anon'), '0'
  UNION ALL
  -- Stated as the complement, so it stays true as views are added: only
  -- the two alert views may bypass the caller's permissions, and they are
  -- revoked from clients (checked on the next line).
  SELECT 23, 'Security', 'views bypassing the caller''s permissions (only the 2 alert views may)',
         (SELECT COUNT(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname='bms' AND c.relkind='v'
             AND NOT COALESCE(c.reloptions::text LIKE '%security_invoker=true%', false)), '2'
  UNION ALL
  SELECT 24, 'Security', 'the alert view is not readable by signed-in users',
         (SELECT COUNT(*)::text FROM information_schema.role_table_grants
           WHERE table_schema='bms' AND table_name='v_alerts_all'
             AND grantee IN ('authenticated','anon','PUBLIC')), '0'
  UNION ALL
  SELECT 25, 'Security', 'the permission function exists',
         (SELECT COUNT(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname='bms' AND p.proname='has_perm'), '1'

  -- ---- triggers ----
  UNION ALL
  SELECT 30, 'Triggers', 'audit triggers attached',
         (SELECT COUNT(*)::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname='bms' AND t.tgname LIKE 'trg_audit_%'), '>= 35'
  UNION ALL
  SELECT 31, 'Triggers', 'the transaction guard is on the ledger',
         (SELECT COUNT(*)::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname='bms' AND c.relname='transactions' AND NOT t.tgisinternal), '>= 2'
  UNION ALL
  SELECT 32, 'Triggers', 'deletion is blocked on transactions, ledger and payments',
         (SELECT COUNT(*)::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'bms' AND NOT t.tgisinternal
             AND t.tgname IN ('trg_txn_no_delete','trg_ledger_no_delete','trg_pay_no_delete')), '3'
  UNION ALL
  SELECT 33, 'Triggers', 'a posted ledger entry cannot be edited',
         (SELECT COUNT(*)::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname='bms' AND t.tgname = 'trg_ledger_no_update'), '1'

  -- ---- seed data ----
  UNION ALL
  SELECT 40, 'Seed data', 'modules registered',
         (SELECT COUNT(*)::text FROM bms.modules), '>= 19'
  UNION ALL
  SELECT 41, 'Seed data', 'permissions defined',
         (SELECT COUNT(*)::text FROM bms.permissions), '>= 90'
  UNION ALL
  SELECT 42, 'Seed data', 'roles created',
         (SELECT COUNT(*)::text FROM bms.roles), '7'
  UNION ALL
  SELECT 43, 'Seed data', 'the super admin role exists and is a superuser',
         (SELECT COUNT(*)::text FROM bms.roles WHERE code='SUPER_ADMIN' AND is_superuser), '1'
  UNION ALL
  SELECT 44, 'Seed data', 'role permissions granted',
         (SELECT COUNT(*)::text FROM bms.role_permissions), '>= 200'
  UNION ALL
  SELECT 45, 'Seed data', 'building settings row exists',
         (SELECT COUNT(*)::text FROM bms.building_settings), '1'
  UNION ALL
  SELECT 46, 'Seed data', 'departments created',
         (SELECT COUNT(*)::text FROM bms.departments), '>= 10'
  UNION ALL
  SELECT 47, 'Seed data', 'expense categories created',
         (SELECT COUNT(*)::text FROM bms.categories), '>= 30'
  UNION ALL
  SELECT 48, 'Seed data', 'a petty cash account exists',
         (SELECT COUNT(*)::text FROM bms.accounts WHERE kind='CASH'), '>= 1'
  UNION ALL
  SELECT 49, 'Seed data', 'the default cash account is set in settings',
         (SELECT COUNT(*)::text FROM bms.building_settings WHERE default_cash_account_id IS NOT NULL), '1'
  UNION ALL
  SELECT 50, 'Seed data', 'staff positions created',
         (SELECT COUNT(*)::text FROM bms.staff_positions), '>= 5'
  UNION ALL
  SELECT 51, 'Seed data', 'work checklists created',
         (SELECT COUNT(*)::text FROM bms.work_checklist_templates), '>= 3'
  UNION ALL
  SELECT 52, 'Seed data', 'notification rules created',
         (SELECT COUNT(*)::text FROM bms.notification_rules), '>= 16'
  UNION ALL
  SELECT 53, 'Seed data', 'reserve funds created',
         (SELECT COUNT(*)::text FROM bms.funds), '>= 2'

  -- ---- storage ----
  -- Asked of the catalogue rather than of storage.buckets, so this check
  -- reports "0" instead of erroring when the buckets do not exist yet.
  UNION ALL
  SELECT 60, 'Storage', 'bucket access policies attached (0 = create the 3 buckets, then re-run 090_storage.sql)',
         (SELECT COUNT(*)::text FROM pg_policies
           WHERE schemaname = 'storage' AND tablename = 'objects'
             AND policyname LIKE 'bms-%'), '9'

  -- ---- your account ----
  UNION ALL
  SELECT 70, 'Your account', 'people signed up',
         (SELECT COUNT(*)::text FROM bms.user_profiles), '>= 1'
  UNION ALL
  SELECT 71, 'Your account', 'people activated',
         (SELECT COUNT(*)::text FROM bms.user_profiles WHERE is_active), '>= 1'
  UNION ALL
  SELECT 72, 'Your account', 'someone holds the Super Admin role',
         (SELECT COUNT(*)::text FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
           WHERE r.code = 'SUPER_ADMIN'), '>= 1'
)
SELECT
  CASE
    WHEN expected LIKE '>= %' THEN
      CASE WHEN found::int >= replace(expected,'>= ','')::int THEN 'PASS' ELSE 'FAIL' END
    ELSE
      CASE WHEN found = expected THEN 'PASS' ELSE 'FAIL' END
  END AS result,
  area, check_name, found, expected
FROM checks
ORDER BY ord;
