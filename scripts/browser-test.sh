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

pkill -f "devserver.mjs 5199" 2>/dev/null || true
CSP=${CSP:-} PGDATABASE=$DB node "$ROOT/scripts/devserver.mjs" 5199 > /tmp/devserver-test.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
CHROMIUM=/opt/pw-browsers/chromium-1194/chrome-linux/chrome BASE=http://localhost:5199 node "$ROOT/scripts/browser-test.mjs"
