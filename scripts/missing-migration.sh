#!/usr/bin/env bash
# Build a database that is deliberately BEHIND the code — every migration
# except the two most recent — and check the app explains itself rather
# than showing a raw Postgres error.
#
# This is the case the other suites cannot see: the frontend deploys on a
# git push, the SQL is pasted in by hand later, and for the gap between
# them the code is newer than the database.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGOPTIONS='-c client_min_messages=warning'
DB=bms_behind

# Which migrations to leave out. Update this when a new one lands.
SKIP="070_reset.sql 080_roles.sql 085_people_reminders.sql 086_reports_funds.sql 087_community_backup.sql 088_storage_setup.sql 089_owners_bills.sql 091_people_fixes.sql 092_slip_channels.sql 093_billed_ahead.sql 094_remove_person.sql 095_correct_entry.sql"

psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" >/dev/null
psql -q -d postgres -c "CREATE DATABASE $DB;" >/dev/null
psql -q -v ON_ERROR_STOP=1 -d $DB -f "$ROOT/sql/test/000_local_shim.sql" >/dev/null
for f in "$ROOT"/sql/[0-9]*.sql; do
  base=$(basename "$f")
  case " $SKIP " in *" $base "*) echo "  skipping $base"; continue;; esac
  psql -q -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null
done
psql -q -d $DB -f "$ROOT/sql/test/harness.sql"  >/dev/null
psql -q -d $DB -f "$ROOT/sql/test/fixtures.sql" >/dev/null
# Something owed, so the Remind button has a flat to appear on.
psql -q -v ON_ERROR_STOP=1 -d $DB >/dev/null <<'SQL'
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT bms.generate_monthly_charges(EXTRACT(year FROM CURRENT_DATE)::int, EXTRACT(month FROM CURRENT_DATE)::int);
SELECT bms.create_transaction(CURRENT_DATE, 'EXPENSE', (SELECT id FROM bms.departments WHERE code = 'CLEANING'),
  (SELECT id FROM bms.categories WHERE name = 'Cleaning supplies'), 'Brooms', 100, 'CASH',
  (SELECT id FROM bms.accounts WHERE code = 'BANK1'));
SQL

fuser -k 5196/tcp 2>/dev/null || true
PGDATABASE=$DB node "$ROOT/scripts/devserver.mjs" 5196 > /tmp/devserver-behind.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
CHROMIUM=/opt/pw-browsers/chromium-1194/chrome-linux/chrome BASE=http://localhost:5196 \
  node "$ROOT/scripts/missing-migration.mjs"
