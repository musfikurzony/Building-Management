#!/usr/bin/env bash
# Build the one-paste migration bundle from the individual SQL files.
#
# The bundle is GENERATED, never hand-edited: the numbered files under sql/
# stay the source of truth, and this script guarantees the bundle cannot
# drift away from them. Run it after changing any migration.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/sql/BUNDLE_all.sql"

{
  cat <<'HEADER'
-- =====================================================================
-- BUNDLE_all.sql — every migration, in order, in one file.
--
-- GENERATED FILE. Do not edit. Run scripts/build-bundle.sh instead.
--
-- HOW TO USE
--   1. Open your Supabase project -> SQL Editor -> New query.
--   2. Paste this whole file.
--   3. Run.
--
-- It is safe to run more than once: every statement is written to be
-- repeatable (CREATE ... IF NOT EXISTS, CREATE OR REPLACE, DROP POLICY
-- IF EXISTS before CREATE POLICY, ON CONFLICT DO NOTHING on seed rows).
-- Running it twice does not duplicate seed data and does not reset
-- anything you have entered.
--
-- WHAT IT TOUCHES
--   Everything it creates lives in the `bms` schema, which it creates.
--   It reads auth.users (Supabase's own table) by foreign key only, and
--   never writes to it. It does not read, alter or drop anything in
--   `public`. sql/test/t00_self_contained.sql exists to fail the build
--   if that ever stops being true.
--
-- STORAGE
--   The last section attaches policies to three storage buckets. If the
--   buckets do not exist yet it prints a notice and skips that part —
--   create them, then run this file again, or run sql/090_storage.sql
--   on its own.
-- =====================================================================

HEADER

  for f in "$ROOT"/sql/0*.sql; do
    name="$(basename "$f")"
    printf '\n\n-- =====================================================================\n'
    printf -- '-- BEGIN %s\n' "$name"
    printf -- '-- =====================================================================\n\n'
    cat "$f"
    printf '\n-- END %s\n' "$name"
  done

  cat <<'FOOTER'


-- =====================================================================
-- Done. Run sql/VERIFY.sql next to confirm what landed.
-- =====================================================================
DO $bundle$
DECLARE t int; f int; p int;
BEGIN
  SELECT COUNT(*) INTO t FROM pg_tables  WHERE schemaname = 'bms';
  SELECT COUNT(*) INTO f FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'bms';
  SELECT COUNT(*) INTO p FROM pg_policies WHERE schemaname = 'bms';
  RAISE NOTICE 'Building portal installed: % tables, % functions, % RLS policies.', t, f, p;
END $bundle$;
FOOTER
} > "$OUT"

echo "Wrote $OUT ($(wc -c < "$OUT") bytes, from $(ls "$ROOT"/sql/0*.sql | wc -l) migration files)"
