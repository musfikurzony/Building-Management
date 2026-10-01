#!/usr/bin/env bash
# Run every SQL test suite against a database built from BUNDLE_all.sql
# instead of from the individual migration files.
#
# Why this exists: the bundle is what actually gets pasted into the
# Supabase SQL Editor, so the bundle is what has to be correct. Passing
# the same 427 checks against a bundle-built database is the proof that
# the one-paste route produces the identical database to the file-by-file
# route — and that a generated file has not drifted from its sources.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGOPTIONS='-c client_min_messages=warning'

"$ROOT/scripts/build-bundle.sh" >/dev/null

TOTAL=0; PASSED=0; SUITES=0; FAILLOG=$(mktemp)

for f in "$ROOT"/sql/test/t[0-9]*.sql; do
  DB="bmsb_$(basename "$f" .sql | tr -cd '[:alnum:]_')"
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" >/dev/null
  psql -q -d postgres -c "CREATE DATABASE $DB;" >/dev/null

  # The shim stands in for the parts of Supabase that exist before any of
  # our SQL runs: the auth schema, auth.uid(), and the anon/authenticated
  # roles. On real Supabase these are already there.
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/test/000_local_shim.sql" >/dev/null

  # THE POINT OF THIS SCRIPT: one file, exactly as pasted.
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/BUNDLE_all.sql" >/dev/null

  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/test/harness.sql"  >/dev/null
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/test/fixtures.sql" >/dev/null

  if ! psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >/dev/null 2>>"$FAILLOG"; then
    echo "ABORTED  $(basename "$f")" >> "$FAILLOG"
  fi

  psql -d "$DB" -X -A -F'  |  ' -P footer=off -t -c "
    SELECT 'FAIL  ' || suite || '  |  ' || name || COALESCE('  |  ' || detail, '')
      FROM t.results WHERE NOT passed ORDER BY id;" >> "$FAILLOG"

  read -r p total <<< "$(psql -d "$DB" -X -A -t -F' ' -c \
    "SELECT COUNT(*) FILTER (WHERE passed), COUNT(*) FROM t.results;")"
  TOTAL=$((TOTAL+total)); PASSED=$((PASSED+p)); SUITES=$((SUITES+1))
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" >/dev/null
done

echo
grep -v '^$' "$FAILLOG" || true
echo
echo "$PASSED of $TOTAL checks passed across $SUITES suites (built from BUNDLE_all.sql)"
rm -f "$FAILLOG"
[ "$PASSED" = "$TOTAL" ]
