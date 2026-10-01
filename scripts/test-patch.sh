#!/usr/bin/env bash
# Prove PATCH.sql brings an OLD database fully up to date.
#
# Builds each suite's database from the migrations as they were at the
# deployed commit, applies PATCH.sql, then runs the full suite against it.
# If the patch is missing anything, a test fails here rather than on the
# building's live data.
#
# A migration that did not exist at the old commit is NOT applied in the
# "old" phase. An earlier version of this script fell back to the current
# file in that case, which handed a brand-new migration to the old
# database before the patch ran — so the patch could omit it and still
# pass. New files must arrive through PATCH.sql or not at all.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGOPTIONS='-c client_min_messages=warning'
OLD=${OLD:-fb1f5f0}      # what the live database was built from

TOTAL=0; PASSED=0; SUITES=0; FAILLOG=$(mktemp)
OLDDIR=$(mktemp -d)
git -C "$ROOT" archive "$OLD" sql | tar -x -C "$OLDDIR"

for f in "$ROOT"/sql/test/t[0-9]*.sql; do
  DB="bmspatch_$(basename "$f" .sql | tr -cd '[:alnum:]_')"
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" >/dev/null
  psql -q -d postgres -c "CREATE DATABASE $DB;" >/dev/null
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/test/000_local_shim.sql" >/dev/null

  for m in "$OLDDIR"/sql/[0-9]*.sql; do
    psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$m" >/dev/null
  done
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/PATCH.sql" >/dev/null

  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/test/harness.sql"  >/dev/null
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/test/fixtures.sql" >/dev/null
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >/dev/null 2>>"$FAILLOG" || echo "ABORTED $(basename $f)" >> "$FAILLOG"

  psql -d "$DB" -X -A -F'  |  ' -P footer=off -t -c "
    SELECT 'FAIL  ' || suite || '  |  ' || name || COALESCE('  |  ' || detail, '')
      FROM t.results WHERE NOT passed ORDER BY id;" >> "$FAILLOG"
  read -r p total <<< "$(psql -d "$DB" -X -A -t -F' ' -c \
    "SELECT COUNT(*) FILTER (WHERE passed), COUNT(*) FROM t.results;")"
  TOTAL=$((TOTAL+total)); PASSED=$((PASSED+p)); SUITES=$((SUITES+1))
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" >/dev/null
done

echo; grep -v '^$' "$FAILLOG" || true; echo
echo "$PASSED of $TOTAL checks passed across $SUITES suites (old schema at $OLD + PATCH.sql)"
rm -rf "$FAILLOG" "$OLDDIR"
[ "$PASSED" = "$TOTAL" ]
