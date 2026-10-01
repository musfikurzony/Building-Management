-- =====================================================================
-- t01 — Row Level Security is actually on, and actually bites.
-- =====================================================================
SET t.suite = 't01 security';
SET search_path = bms, public;

-- Every table in bms has RLS enabled. A new table added without it is a hole.
SELECT t.eq('RLS enabled on every bms table', ''::text,
  COALESCE((SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname='bms' AND c.relkind='r' AND NOT c.relrowsecurity), ''));

-- The signed-out role can reach nothing.
SELECT t.eq('anon has no table privileges in bms', 0::bigint,
  (SELECT COUNT(*) FROM information_schema.role_table_grants
    WHERE table_schema='bms' AND grantee='anon'));

-- Every view is security_invoker, so RLS follows through it. There are
-- exactly two exceptions, both in the alert path, and both are checked
-- below rather than merely excused here.
SELECT t.eq('all views are security_invoker except the two alert views', ''::text,
  COALESCE((SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname='bms' AND c.relkind='v'
      AND c.relname NOT IN ('v_alerts_all','v_dashboard_alerts')
      AND NOT COALESCE(c.reloptions::text LIKE '%security_invoker=true%', false)), ''));

-- v_alerts_all reads every table without RLS, so no client may reach it.
SELECT t.eq('v_alerts_all is not granted to any client role', 0::bigint,
  (SELECT COUNT(*) FROM information_schema.role_table_grants
    WHERE table_schema='bms' AND table_name='v_alerts_all'
      AND grantee IN ('authenticated','anon','PUBLIC')));

-- v_dashboard_alerts is granted, but only ever returns counts.
SELECT t.eq('v_dashboard_alerts exposes no row identifiers', ''::text,
  COALESCE((SELECT string_agg(column_name, ', ' ORDER BY column_name)
     FROM information_schema.columns
    WHERE table_schema='bms' AND table_name='v_dashboard_alerts'
      AND column_name NOT IN
        ('alert_type','severity','item_count','amount','title','link')), ''));

-- ---------------------------------------------------------------------
-- A signed-in user with no roles yet sees nothing.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('newbie'), false);

SELECT t.eq('un-activated user sees no flats',        0::bigint, (SELECT COUNT(*) FROM bms.flats));
SELECT t.eq('un-activated user sees no transactions', 0::bigint, (SELECT COUNT(*) FROM bms.transactions));
SELECT t.eq('un-activated user sees no accounts',     0::bigint, (SELECT COUNT(*) FROM bms.accounts));
SELECT t.ok('un-activated user has no permissions',   NOT bms.has_perm('finance','view'));
SELECT t.ok('un-activated user can see own profile',
  EXISTS (SELECT 1 FROM bms.user_profiles WHERE user_id = t.uid('newbie')));

-- Nobody can promote themselves.
SELECT t.throws('user cannot activate their own account',
  'UPDATE bms.user_profiles SET is_active = true WHERE user_id = ''' || t.recall('newbie') || '''',
  'own access level');

RESET ROLE;

-- ---------------------------------------------------------------------
-- Caretaker: may submit an expense, may never approve one, and may not
-- see the bank at all.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);

SELECT t.ok('caretaker can add to finance',      bms.has_perm('finance','add'));
SELECT t.ok('caretaker cannot approve finance',  NOT bms.has_perm('finance','approve'));
SELECT t.ok('caretaker cannot view bank',        NOT bms.has_perm('bank','view'));
SELECT t.ok('caretaker cannot view audit log',   NOT bms.has_perm('audit','view'));
SELECT t.eq('caretaker sees no bank accounts',   0::bigint, (SELECT COUNT(*) FROM bms.accounts));
SELECT t.ok('caretaker can still pick an account to spend from',
            (SELECT COUNT(*) FROM bms.entry_accounts()) > 0,
            'entry_accounts() returns names only, never balances');
SELECT t.eq('caretaker sees no audit rows',      0::bigint, (SELECT COUNT(*) FROM bms.audit_log));
SELECT t.ok('caretaker can see the flat list',   (SELECT COUNT(*) FROM bms.flats) = 3);
-- RLS filters the UPDATE to zero rows rather than raising, so the proof
-- is that nothing changed.
UPDATE bms.flats SET service_charge = 1 WHERE flat_number = 'A-101';
SELECT t.eq('caretaker edit of a flat changes nothing', 5000.00::numeric,
            (SELECT service_charge FROM bms.flats WHERE flat_number = 'A-101'));
SELECT t.throws('caretaker cannot close a period',
  'SELECT bms.close_period(2026, 1)', 'permission denied');

RESET ROLE;

-- ---------------------------------------------------------------------
-- Bank account numbers need their own permission.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('committee'), false);
SELECT t.ok('committee can see account balances', (SELECT COUNT(*) FROM bms.accounts) > 0);
SELECT t.eq('committee cannot see account numbers', 0::bigint,
            (SELECT COUNT(*) FROM bms.account_secrets));
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.eq('finance manager can see account numbers', 1::bigint,
            (SELECT COUNT(*) FROM bms.account_secrets));
RESET ROLE;

-- ---------------------------------------------------------------------
-- Auditor reads everything and changes nothing.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('auditor'), false);
SELECT t.ok('auditor can read the audit log', bms.has_perm('audit','view'));
SELECT t.throws('auditor cannot add a flat',
  'INSERT INTO bms.flats(flat_number, floor) VALUES (''X-999'', 9)',
  'row-level security');
SELECT t.throws('auditor cannot create a transaction',
  'SELECT bms.create_transaction(CURRENT_DATE, ''EXPENSE'', NULL, NULL, ''x'', 10, ''CASH'', '''
  || t.recall('acct_cash') || ''')',
  'permission denied');
RESET ROLE;

-- The audit log cannot be edited or deleted by anyone, including the owner.
SELECT t.throws('audit log rows cannot be updated',
  'UPDATE bms.audit_log SET detail = ''tampered'' WHERE id = (SELECT MIN(id) FROM bms.audit_log)',
  'append-only');
SELECT t.throws('audit log rows cannot be deleted',
  'DELETE FROM bms.audit_log WHERE id = (SELECT MIN(id) FROM bms.audit_log)',
  'append-only');

-- ---------------------------------------------------------------------
-- BOOTSTRAPPING THE FIRST ADMINISTRATOR.
--
-- This is a regression test for a bug that made the product unusable on
-- a brand-new project. The self-edit guard on user_profiles fired even
-- when there was no signed-in user, so BOOTSTRAP_ADMIN.sql failed with
-- "You cannot change your own access level" the moment the profile row
-- already existed — which is precisely what happens when someone follows
-- the documented order and signs up in the app before running it. The
-- first administrator could therefore never be activated.
--
-- Both halves matter. The guard must NOT fire with no session, and it
-- MUST still fire for a signed-in person. Testing only the first half
-- would let the fix quietly become a privilege-escalation hole.
-- ---------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', false);   -- genuinely no session

INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-0000000000b1','bootstrap@test') ON CONFLICT DO NOTHING;
-- The app creates this row, inactive, on first sign-in.
INSERT INTO bms.user_profiles (user_id, full_name, email, is_active)
VALUES ('00000000-0000-0000-0000-0000000000b1','Bootstrap Person','bootstrap@test', false)
ON CONFLICT (user_id) DO NOTHING;

SELECT t.ok('auth.uid() really is null, so the branch under test is the one being taken',
  auth.uid() IS NULL);

SELECT t.runs('the first admin can be activated from the SQL editor when the profile already exists', $$
  UPDATE bms.user_profiles SET is_active = true
   WHERE user_id = '00000000-0000-0000-0000-0000000000b1'
$$);
SELECT t.ok('and the account is genuinely active afterwards',
  (SELECT is_active FROM bms.user_profiles
    WHERE user_id = '00000000-0000-0000-0000-0000000000b1'));

SELECT t.runs('and the role can be granted', $$
  INSERT INTO bms.user_roles (user_id, role_id)
  SELECT '00000000-0000-0000-0000-0000000000b1', id FROM bms.roles WHERE code = 'SUPER_ADMIN'
  ON CONFLICT DO NOTHING
$$);

-- The half that must NOT have been weakened: a signed-in person with no
-- users.edit permission still cannot touch their own access level.
INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-0000000000b2','selfedit@test') ON CONFLICT DO NOTHING;
INSERT INTO bms.user_profiles (user_id, full_name, email, is_active)
VALUES ('00000000-0000-0000-0000-0000000000b2','Self Editor','selfedit@test', true)
ON CONFLICT (user_id) DO NOTHING;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b2', false);
SELECT t.throws('a signed-in user still cannot raise their own approval limit',
  'UPDATE bms.user_profiles SET approval_limit = 999999 WHERE user_id = auth.uid()',
  'own access level');
SELECT t.throws('nor change their own active flag',
  'UPDATE bms.user_profiles SET is_active = false WHERE user_id = auth.uid()',
  'own access level');
SELECT t.runs('but may still correct their own name', $$
  UPDATE bms.user_profiles SET full_name = 'Self Editor Renamed' WHERE user_id = auth.uid()
$$);
RESET ROLE;
