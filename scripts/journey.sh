#!/usr/bin/env bash
# The first-day walkthrough, driven through the real screens.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGOPTIONS='-c client_min_messages=warning'
DB=bms_journey

DB=$DB "$ROOT/scripts/localdb.sh" >/dev/null
psql -q -d $DB -f "$ROOT/sql/test/harness.sql"  >/dev/null
psql -q -d $DB -f "$ROOT/sql/test/fixtures.sql" >/dev/null

fuser -k 5197/tcp 2>/dev/null || true
PGDATABASE=$DB node "$ROOT/scripts/devserver.mjs" 5197 > /tmp/devserver-journey.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
CHROMIUM=/opt/pw-browsers/chromium-1194/chrome-linux/chrome BASE=http://localhost:5197 \
  node "$ROOT/scripts/journey.mjs"
