#!/usr/bin/env bash
# Rebuild a clean database, start the dev server, drive the portal in Chromium.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGOPTIONS='-c client_min_messages=warning'
DB=bms_browser

DB=$DB "$ROOT/scripts/localdb.sh" >/dev/null
psql -q -d $DB -f "$ROOT/sql/test/harness.sql" >/dev/null
psql -q -d $DB -f "$ROOT/sql/test/fixtures.sql" >/dev/null
# A resident (Resident role), and more than 1,000 audit rows so the backup
# has to page through the database's 1,000-row answers to get them all.
psql -q -v ON_ERROR_STOP=1 -d $DB >/dev/null <<'SQL'
INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000b1','resident@test') ON CONFLICT DO NOTHING;
INSERT INTO bms.user_profiles (user_id, full_name, email, is_active)
VALUES ('00000000-0000-0000-0000-0000000000b1','Flat Resident','resident@test',true) ON CONFLICT DO NOTHING;
INSERT INTO bms.user_roles (user_id, role_id)
SELECT '00000000-0000-0000-0000-0000000000b1', id FROM bms.roles WHERE code = 'RESIDENT' ON CONFLICT DO NOTHING;
INSERT INTO bms.audit_log (action, module_code, detail, severity)
SELECT 'NOTE', 'reports', 'filler row ' || g, 'LOW' FROM generate_series(1, 1150) g;
SQL

pkill -f "devserver.mjs 5199" 2>/dev/null || true
CSP=${CSP:-} PGDATABASE=$DB node "$ROOT/scripts/devserver.mjs" 5199 > /tmp/devserver-test.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
CHROMIUM=/opt/pw-browsers/chromium-1194/chrome-linux/chrome BASE=http://localhost:5199 node "$ROOT/scripts/browser-test.mjs"
