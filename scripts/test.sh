#!/usr/bin/env bash
# Rebuild the database and run every SQL test suite.
#
# Each suite runs in its OWN fresh database. A suite that only passes
# because of another suite's leftovers is not a test, and the journey
# suite in particular asserts exact balances that only mean something
# from a known starting point.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGOPTIONS='-c client_min_messages=warning'

TOTAL=0; PASSED=0; SUITES=0; FAILLOG=$(mktemp)

for f in "$ROOT"/sql/test/t[0-9]*.sql; do
  DB="bms_$(basename "$f" .sql | tr -cd '[:alnum:]_')"
  DB=$DB "$ROOT/scripts/localdb.sh" >/dev/null
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
echo "$PASSED of $TOTAL checks passed across $SUITES suites"
rm -f "$FAILLOG"
[ "$PASSED" = "$TOTAL" ]
