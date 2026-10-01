#!/usr/bin/env bash
# Rebuild the local test database from scratch and apply every migration
# in order. Used by the test suite; never touches Supabase.
set -euo pipefail

PGHOST=${PGHOST:-127.0.0.1}
PGPORT=${PGPORT:-5433}
PGUSER=${PGUSER:-postgres}
DB=${DB:-bms_test}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PGHOST PGPORT PGUSER
psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" >/dev/null
psql -q -d postgres -c "CREATE DATABASE $DB;" >/dev/null

run() {
  echo "  -> $(basename "$1")"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$1"
}

echo "Applying local Supabase shim"
run "$ROOT/sql/test/000_local_shim.sql"

echo "Applying migrations"
for f in "$ROOT"/sql/[0-9]*.sql; do run "$f"; done

echo "Database $DB is ready."
