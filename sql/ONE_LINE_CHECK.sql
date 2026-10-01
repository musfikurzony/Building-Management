-- Paste this, run it, screenshot the single row it returns. READ-ONLY.
SELECT
  u.email,
  u.id                                                        AS auth_user_id,
  (u.email_confirmed_at IS NOT NULL)                          AS confirmed,
  (up.user_id IS NOT NULL)                                    AS has_profile,
  up.is_active,
  COALESCE((SELECT string_agg(r.code, ',')
              FROM bms.user_roles ur
              JOIN bms.roles r ON r.id = ur.role_id
             WHERE ur.user_id = u.id), '(no role)')           AS roles,
  (SELECT p.prosrc LIKE '%uid() IS NULL%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'bms' AND p.proname = 'guard_user_profile') AS guard_fixed
FROM auth.users u
LEFT JOIN bms.user_profiles up ON up.user_id = u.id
ORDER BY u.created_at;
