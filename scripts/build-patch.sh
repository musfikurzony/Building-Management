#!/usr/bin/env bash
# Build the smallest file that brings an already-installed database up to
# date: the migrations that change functions, triggers, policies and
# indexes, plus any new ones since the deployed version.
#
# Generated rather than hand-assembled, for the same reason BUNDLE_all.sql
# is: a copy edited by hand drifts from the file the tests actually run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/sql/PATCH.sql"
# In numeric order, because 010 depends on tables from 002 and 030 must
# come after the functions it references.
#
# 002 and 030 are here because building an OLD database and applying only
# the function files left three tests failing: the partial unique index
# that stops categories duplicating (002) and the self-edit guard that
# lets the first admin be activated (030). Both were shipped as separate
# hand-run fixes earlier, so a database MIGHT have had them — "might" is
# not good enough for a file whose job is to make a database current.
FILES="002_finance.sql 010_functions.sql 011_charge_functions.sql 030_rls.sql 070_reset.sql 080_roles.sql 085_people_reminders.sql"

{
cat <<'HDR'
-- =====================================================================
-- PATCH.sql — the update, for a database that is already installed.
--
-- It replaces functions, triggers, policies, grants and indexes. Every
-- CREATE TABLE in it is IF NOT EXISTS, so on a database that already has
-- these tables they do nothing at all. Existing rows are not changed.
--
-- Supabase will still show "Potential issues detected", because it reads
-- the text and sees CREATE TABLE and DROP POLICY. Choose **Run without
-- RLS**. That does not mean running with security off — it means "run my
-- SQL as written, do not add statements of your own". This file switches
-- Row Level Security on for every table itself, and sql/VERIFY.sql will
-- confirm it afterwards.
--
-- Safe to run twice, and safe to run whether or not you managed the
-- previous update.
--
-- If you would rather run everything from scratch, sql/BUNDLE_all.sql is
-- the whole schema and is also safe to run twice. This file is the small
-- one.
-- =====================================================================

HDR
for f in $FILES; do
  echo ""
  echo "-- ============================================================"
  echo "-- $f"
  echo "-- ============================================================"
  cat "$ROOT/sql/$f"
done
} > "$OUT"

echo "Wrote $OUT ($(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes)"
