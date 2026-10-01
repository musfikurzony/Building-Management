-- =====================================================================
-- FIX_ADMIN_ACTIVATION.sql
--
-- Fixes the bug that stops the first administrator being activated, then
-- activates your account.
--
-- WHAT WENT WRONG
--   bms.guard_user_profile() is a trigger that stops a signed-in person
--   raising their own access level. It fired even when there was no
--   signed-in person — which is the case in the Supabase SQL Editor — so
--   BOOTSTRAP_ADMIN.sql failed with "You cannot change your own access
--   level" whenever the profile row already existed.
--
--   The profile row already exists as soon as you have signed in to the
--   portal once. So following the documented order — sign up, then run
--   the bootstrap — was exactly the path that failed. Running the
--   bootstrap BEFORE ever signing in took the INSERT path instead of the
--   UPDATE path and appeared to work, which is why it succeeded the
--   first time and then stopped.
--
-- WHAT THIS FILE CHANGES
--   1. Replaces one function, bms.guard_user_profile(), adding a single
--      branch: if there is no signed-in user, do not treat the change as
--      self-editing. Nothing else about the guard changes.
--   2. Sets is_active = true and grants SUPER_ADMIN for ONE email, the
--      one you put on the line below.
--
--   It creates no user, changes no password, and touches no other table.
--   Safe to run twice.
--
-- IS THE GUARD STILL DOING ITS JOB?
--   Yes. A browser client always carries a JWT, so auth.uid() is never
--   null on the path the guard defends. The new branch only applies to
--   the SQL Editor, migrations and scheduled jobs — all of which already
--   run as the database owner and could drop the trigger outright. There
--   is now a test (t01) that a signed-in user with no users.edit
--   permission still cannot change their own is_active or approval_limit,
--   so the guard cannot quietly become a hole later.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The corrected guard.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.guard_user_profile() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  -- No signed-in user means this is not somebody editing themselves.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF (NEW.is_active      IS DISTINCT FROM OLD.is_active
   OR NEW.approval_limit IS DISTINCT FROM OLD.approval_limit)
     AND NOT bms.has_perm('users','edit') THEN
    RAISE EXCEPTION 'You cannot change your own access level' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 2. Activate the first administrator.
-- ---------------------------------------------------------------------
DO $fix$
DECLARE
  -- >>> CHANGE THIS if your sign-in email is different <<<
  v_email   text := 'musfikurrahman@gmail.com';

  v_user_id uuid;
  v_role_id uuid;
BEGIN
  SELECT id INTO v_user_id
    FROM auth.users
   WHERE lower(email) = lower(v_email)
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION
      'No account with the email %. Sign up in the portal first. (Nothing was changed.)', v_email;
  END IF;

  SELECT id INTO v_role_id FROM bms.roles WHERE code = 'SUPER_ADMIN';
  IF v_role_id IS NULL THEN
    RAISE EXCEPTION 'The SUPER_ADMIN role is missing, so the seed did not run. (Nothing was changed.)';
  END IF;

  INSERT INTO bms.user_profiles (user_id, full_name, email, is_active)
  VALUES (v_user_id, split_part(v_email, '@', 1), v_email, true)
  ON CONFLICT (user_id) DO UPDATE SET is_active = true;

  INSERT INTO bms.user_roles (user_id, role_id)
  VALUES (v_user_id, v_role_id)
  ON CONFLICT DO NOTHING;

  RAISE NOTICE '% is now an active Super Admin. Sign out of the portal and sign in again.', v_email;
END $fix$;

-- ---------------------------------------------------------------------
-- 3. Proof. Expect one row: is_active = true, roles = SUPER_ADMIN,
--    guard_is_fixed = true.
-- ---------------------------------------------------------------------
SELECT
  up.email,
  up.full_name,
  up.is_active,
  COALESCE((SELECT string_agg(r.code, ', ' ORDER BY r.code)
              FROM bms.user_roles ur
              JOIN bms.roles r ON r.id = ur.role_id
             WHERE ur.user_id = up.user_id), '(none)') AS roles,
  (SELECT prosrc LIKE '%uid() IS NULL%' FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='bms' AND p.proname='guard_user_profile')  AS guard_is_fixed
FROM bms.user_profiles up
ORDER BY up.email;
