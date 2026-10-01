-- =====================================================================
-- DIAGNOSE_LOGIN.sql — why does the portal say "Waiting for access"?
--
-- READ-ONLY. Every statement is a SELECT. It inserts nothing, updates
-- nothing, deletes nothing and migrates nothing.
--
-- Paste into the Supabase SQL Editor, run, and send back the results.
-- Section F gives a one-line verdict; the sections above it are the
-- evidence behind that verdict.
-- =====================================================================


-- ---------------------------------------------------------------------
-- A. Supabase Auth: does the account exist, and is the email confirmed?
--
--    The dashboard's "Total: N users (estimated)" is read from table
--    statistics and is frequently stale. This is the real answer.
-- ---------------------------------------------------------------------
SELECT
  'A. auth.users'                    AS section,
  u.id::text                         AS user_id,
  u.email,
  (u.email_confirmed_at IS NOT NULL) AS email_confirmed,
  u.created_at,
  u.last_sign_in_at
FROM auth.users u
ORDER BY u.created_at;


-- ---------------------------------------------------------------------
-- B. The portal's profile for that same user id, and whether it is active.
--
--    is_active = false is the direct cause of the "Waiting for access"
--    screen. The app checks this before it looks at roles at all.
-- ---------------------------------------------------------------------
SELECT
  'B. bms.user_profiles' AS section,
  up.user_id::text       AS user_id,
  up.email,
  up.full_name,
  up.is_active,
  EXISTS (SELECT 1 FROM auth.users u WHERE u.id = up.user_id) AS auth_account_exists,
  up.created_at
FROM bms.user_profiles up
ORDER BY up.created_at;


-- ---------------------------------------------------------------------
-- C. Roles held by that user id, and whether SUPER_ADMIN is among them.
-- ---------------------------------------------------------------------
SELECT
  'C. bms.user_roles'  AS section,
  ur.user_id::text     AS user_id,
  r.code               AS role_code,
  r.name               AS role_name,
  r.is_superuser,
  (r.code = 'SUPER_ADMIN') AS is_super_admin,
  ur.assigned_at
FROM bms.user_roles ur
JOIN bms.roles r ON r.id = ur.role_id
ORDER BY ur.assigned_at;


-- ---------------------------------------------------------------------
-- D. Do the RLS policies let a signed-in person read their own rows?
--
--    Checked by inspecting the policies themselves rather than by
--    guessing. The SQL Editor has no session, so auth.uid() is null here
--    and the policies cannot be exercised directly — but their existence
--    and their predicates can be read from the catalogue.
--
--    Expect: profiles_own_row_readable = true, and roles readable.
-- ---------------------------------------------------------------------
SELECT
  'D. RLS policies' AS section,
  (SELECT COUNT(*) > 0 FROM pg_policies
    WHERE schemaname='bms' AND tablename='user_profiles'
      AND cmd='SELECT' AND qual LIKE '%uid()%')             AS profiles_own_row_readable,
  (SELECT COUNT(*) FROM pg_policies
    WHERE schemaname='bms' AND tablename='user_profiles')   AS profile_policies,
  (SELECT COUNT(*) FROM pg_policies
    WHERE schemaname='bms' AND tablename='user_roles')      AS role_policies,
  (SELECT relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='bms' AND c.relname='user_profiles')    AS rls_on_profiles,
  (SELECT has_table_privilege('authenticated','bms.user_profiles','SELECT')) AS authenticated_may_select;


-- ---------------------------------------------------------------------
-- E. The self-edit guard — the thing that actually broke this.
--
--    bms.guard_user_profile() blocks a SIGNED-IN person from raising
--    their own access level. In its first version it also fired when
--    there was NO signed-in person, which is the case in the SQL Editor.
--    BOOTSTRAP_ADMIN.sql therefore failed with
--
--        "You cannot change your own access level"
--
--    whenever the profile row already existed — which is exactly what
--    happens if you sign up in the app first, as the instructions say to.
--    The INSERT path worked, the UPDATE path did not, so whether the
--    bootstrap succeeded depended on whether you had ever signed in.
--
--    guard_is_fixed = false means you have the broken version.
-- ---------------------------------------------------------------------
SELECT
  'E. self-edit guard' AS section,
  (prosrc LIKE '%uid() IS NULL%')                       AS guard_is_fixed,
  (prosrc LIKE '%own access level%')                    AS guard_present
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'bms' AND p.proname = 'guard_user_profile';


-- ---------------------------------------------------------------------
-- E2. Is the bms schema published to the API at all?
--
--     The portal keeps every table in `bms`. Supabase serves only the
--     schemas on its exposed list, so if `bms` is missing from it, every
--     query fails with "Invalid schema: bms" before it reaches a single
--     row — and the portal, unable to read a profile, reports it as
--     "waiting for an administrator". The database can be entirely
--     correct and the app still show nothing.
--
--     Fix: Project Settings -> API -> Exposed schemas -> add `bms`.
--     Do NOT run the blanket GRANTs from Supabase's custom-schema guide:
--     they hand the signed-out `anon` role access to every table, which
--     this project deliberately revokes.
-- ---------------------------------------------------------------------
SELECT
  'E2. API exposure' AS section,
  COALESCE(
    (SELECT s.setconfig::text FROM pg_db_role_setting s
       JOIN pg_roles r ON r.oid = s.setrole
      WHERE r.rolname = 'authenticator' LIMIT 1),
    '(could not read — check the dashboard by hand)') AS authenticator_settings,
  COALESCE(
    (SELECT bool_or(c LIKE '%bms%')
       FROM pg_db_role_setting s
       JOIN pg_roles r ON r.oid = s.setrole,
            unnest(s.setconfig) AS c
      WHERE r.rolname = 'authenticator' AND c LIKE 'pgrst.db_schemas%'),
    false) AS bms_is_exposed;


-- ---------------------------------------------------------------------
-- F. The verdict.
-- ---------------------------------------------------------------------
SELECT 'F. verdict' AS section,
  CASE
    WHEN NOT COALESCE((SELECT bool_or(c LIKE '%bms%')
                         FROM pg_db_role_setting s
                         JOIN pg_roles r ON r.oid = s.setrole,
                              unnest(s.setconfig) AS c
                        WHERE r.rolname = 'authenticator'
                          AND c LIKE 'pgrst.db_schemas%'), true)
      THEN 'The bms schema is NOT exposed to the API. Project Settings -> API -> Exposed schemas -> add bms. Nothing is wrong with the database or the account.'

    WHEN (SELECT COUNT(*) FROM auth.users) = 0
      THEN 'No Supabase account exists at all. Sign up in the portal first.'

    WHEN NOT EXISTS (SELECT 1 FROM bms.user_profiles)
      THEN 'The account exists but the portal has no profile row for it. Sign in to the portal once, then run the fix.'

    WHEN EXISTS (SELECT 1 FROM bms.user_profiles up WHERE NOT up.is_active)
     AND NOT (SELECT prosrc LIKE '%uid() IS NULL%' FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname='bms' AND p.proname='guard_user_profile')
      THEN 'CONFIRMED: the profile is inactive AND the self-edit guard is the broken version, so BOOTSTRAP_ADMIN could not activate it. Run FIX_ADMIN_ACTIVATION.sql.'

    WHEN EXISTS (SELECT 1 FROM bms.user_profiles up WHERE NOT up.is_active)
      THEN 'The guard is already fixed but the profile is still inactive. Re-run BOOTSTRAP_ADMIN.sql with the right email.'

    WHEN NOT EXISTS (SELECT 1 FROM bms.user_roles ur
                       JOIN bms.roles r ON r.id = ur.role_id WHERE r.code = 'SUPER_ADMIN')
      THEN 'Profile is active but nobody holds SUPER_ADMIN. Re-run BOOTSTRAP_ADMIN.sql.'

    WHEN EXISTS (SELECT 1 FROM auth.users WHERE email_confirmed_at IS NULL)
      THEN 'Database is correct, but the email is unconfirmed so Supabase will not issue a session.'

    ELSE 'Database is fully correct. If the portal still refuses, sign out and clear site data — the browser is holding an old token.'
  END AS what_this_means;
