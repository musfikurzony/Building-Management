-- =====================================================================
-- BOOTSTRAP_ADMIN.sql — make yourself the first Super Admin.
--
-- WHEN TO RUN THIS
--   After you have signed up inside the portal itself. Sign up first:
--   the app creates your profile, deliberately inactive, and shows you a
--   "waiting for approval" screen. That is correct — nobody can activate
--   their own account from the browser. This file is how the FIRST
--   account gets activated, because there is nobody else to do it.
--
--   Everyone after you is activated from the Users & Roles screen, and
--   you will never need this file again.
--
-- HOW TO RUN IT
--   1. Change the email on the line below to the one you signed up with.
--   2. Paste the whole file into the Supabase SQL Editor and run.
--
-- WHAT IT CHANGES
--   Exactly two things, for one person:
--     - sets is_active = true on that person's bms.user_profiles row
--     - gives that person the SUPER_ADMIN role
--   It creates no user and changes no password. It touches nothing else,
--   and it refuses to do anything at all if the email does not match a
--   signed-up account, rather than half-finishing.
-- =====================================================================

DO $bootstrap$
DECLARE
  -- >>> CHANGE THIS to the email address you signed up with <<<
  v_email    text := 'you@example.com';

  v_user_id  uuid;
  v_role_id  uuid;
  v_name     text;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE lower(email) = lower(v_email);
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION
      'No account with the email %. Sign up in the portal first, then run this again. (Nothing was changed.)',
      v_email;
  END IF;

  SELECT id INTO v_role_id FROM bms.roles WHERE code = 'SUPER_ADMIN';
  IF v_role_id IS NULL THEN
    RAISE EXCEPTION
      'The SUPER_ADMIN role does not exist, so the seed did not run. Run BUNDLE_all.sql first. (Nothing was changed.)';
  END IF;

  -- The profile normally already exists, created by the app on first
  -- sign-in. Insert it if somehow it does not, so this file works even
  -- if you signed up through the Supabase dashboard instead.
  INSERT INTO bms.user_profiles (user_id, full_name, email, is_active)
  VALUES (v_user_id, split_part(v_email, '@', 1), v_email, true)
  ON CONFLICT (user_id) DO UPDATE SET is_active = true;

  INSERT INTO bms.user_roles (user_id, role_id)
  VALUES (v_user_id, v_role_id)
  ON CONFLICT DO NOTHING;

  SELECT full_name INTO v_name FROM bms.user_profiles WHERE user_id = v_user_id;

  RAISE NOTICE '% (%) is now an active Super Admin. Sign out and back in.', v_name, v_email;
END $bootstrap$;

-- Confirm it worked. Expect exactly one row, active, with SUPER_ADMIN.
SELECT up.email,
       up.full_name,
       up.is_active,
       string_agg(r.code, ', ') AS roles
  FROM bms.user_profiles up
  LEFT JOIN bms.user_roles ur ON ur.user_id = up.user_id
  LEFT JOIN bms.roles      r  ON r.id       = ur.role_id
 GROUP BY up.email, up.full_name, up.is_active
 ORDER BY up.email;
