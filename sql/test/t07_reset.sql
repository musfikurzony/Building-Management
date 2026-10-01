-- =====================================================================
-- t07 — the system reset.
--
-- This is the one function in the schema allowed to destroy financial
-- history, so it gets the most hostile suite. The questions that matter
-- are not "does it delete things" but:
--
--   who is allowed to run it, can the confirmation be skipped, does the
--   narrow scope really stay narrow, does the permission to delete leak
--   out of the function afterwards, and can a reset be run without
--   leaving a trace.
--
-- It runs LAST because it empties the database it runs against.
-- =====================================================================
SET t.suite = 't07 reset';
SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Something worth destroying.
--
-- The fixtures give a configured building but no history, and a reset
-- tested against an empty database proves nothing at all — it would pass
-- just as happily if the function deleted nothing. So: post real money,
-- raise real service charges, take a real payment.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.remember('r_txn1', (bms.create_transaction(
    CURRENT_DATE, 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'Diesel for the reset test', 5000.00, 'CASH', t.uid('acct_cash'))).id::text);
SELECT t.remember('r_txn2', (bms.create_transaction(
    CURRENT_DATE, 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'More diesel', 2500.00, 'BANK_TRANSFER', t.uid('acct_bank'))).id::text);

SELECT bms.generate_monthly_charges(
  EXTRACT(YEAR FROM CURRENT_DATE)::int, EXTRACT(MONTH FROM CURRENT_DATE)::int);

SELECT bms.record_payment(
  t.uid('flat_101'), 3000.00, CURRENT_DATE, 'CASH', t.uid('acct_cash'), NULL, NULL, NULL);

RESET ROLE;

SELECT t.ok('the suite starts with transactions to destroy',
  (SELECT COUNT(*) FROM bms.transactions) > 0);
SELECT t.ok('the suite starts with service charges to destroy',
  (SELECT COUNT(*) FROM bms.flat_charges) > 0);
SELECT t.ok('the suite starts with ledger entries to destroy',
  (SELECT COUNT(*) FROM bms.ledger_entries) > 0);

-- ---------------------------------------------------------------------
-- Who may run it
-- ---------------------------------------------------------------------

-- The caretaker submits expenses. They must not be able to erase them.
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('caretaker cannot preview a reset',
  'SELECT bms.reset_preview()', 'Super Admin');
SELECT t.throws('caretaker cannot run a reset',
  'SELECT bms.reset_system(''entries'',''RESET'')', 'Super Admin');

-- Finance holds the money permissions and an approval limit. Still not enough:
-- this is deliberately gated on the role, not on a permission bit.
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.throws('finance manager cannot run a reset',
  'SELECT bms.reset_system(''entries'',''RESET'')', 'Super Admin');

-- Signed out.
SELECT set_config('request.jwt.claim.sub', '', false);
SELECT t.throws('a signed-out caller cannot run a reset',
  'SELECT bms.reset_system(''entries'',''RESET'')', 'Super Admin');

-- ---------------------------------------------------------------------
-- The confirmation is enforced in SQL, not in the browser
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.throws('an empty confirmation is refused',
  'SELECT bms.reset_system(''entries'','''')', 'Type RESET');
SELECT t.throws('a null confirmation is refused',
  'SELECT bms.reset_system(''entries'', NULL)', 'Type RESET');
SELECT t.throws('the wrong word is refused',
  'SELECT bms.reset_system(''entries'',''reset'')', 'Type RESET');
SELECT t.throws('a made-up scope is refused',
  'SELECT bms.reset_system(''everything'',''RESET'')', 'Unknown reset scope');

-- A refused reset must not have deleted anything on its way to refusing.
SELECT t.ok('the refused attempts left the ledger untouched',
  (SELECT COUNT(*) FROM bms.transactions) > 0,
  (SELECT COUNT(*)::text FROM bms.transactions));

-- ---------------------------------------------------------------------
-- The preview describes the database that is actually there
-- ---------------------------------------------------------------------
SELECT t.eq('preview counts transactions correctly',
  (SELECT COUNT(*) FROM bms.transactions),
  ((bms.reset_preview() -> 'entries' ->> 'transactions')::bigint));
SELECT t.eq('preview counts flats correctly',
  (SELECT COUNT(*) FROM bms.flats),
  ((bms.reset_preview() -> 'masters' ->> 'flats')::bigint));
SELECT t.ok('preview reports something to delete before we start',
  ((bms.reset_preview() ->> 'total_entries')::bigint) > 0);

-- Remember the shape of the world before the narrow reset.
SELECT t.remember('pre_flats',    (SELECT COUNT(*)::text FROM bms.flats));
SELECT t.remember('pre_staff',    (SELECT COUNT(*)::text FROM bms.staff));
SELECT t.remember('pre_users',    (SELECT COUNT(*)::text FROM bms.user_profiles));
SELECT t.remember('pre_roles',    (SELECT COUNT(*)::text FROM bms.user_roles));
SELECT t.remember('pre_cats',     (SELECT COUNT(*)::text FROM bms.categories));
SELECT t.remember('pre_accounts', (SELECT COUNT(*)::text FROM bms.accounts));
SELECT t.remember('pre_name',     (SELECT building_name FROM bms.building_settings LIMIT 1));

-- ---------------------------------------------------------------------
-- Scope 'entries' — clears the entries, keeps the building
-- ---------------------------------------------------------------------
SELECT t.runs('a super admin can run the narrow reset',
  'SELECT bms.reset_system(''entries'',''RESET'')');

SELECT t.eq('every transaction is gone',      0::bigint, (SELECT COUNT(*) FROM bms.transactions));
SELECT t.eq('every ledger entry is gone',     0::bigint, (SELECT COUNT(*) FROM bms.ledger_entries));
SELECT t.eq('every payment is gone',          0::bigint, (SELECT COUNT(*) FROM bms.payments));
SELECT t.eq('every service charge is gone',   0::bigint, (SELECT COUNT(*) FROM bms.flat_charges));
SELECT t.eq('every allocation is gone',       0::bigint, (SELECT COUNT(*) FROM bms.payment_allocations));
SELECT t.eq('every fund movement is gone',    0::bigint, (SELECT COUNT(*) FROM bms.fund_movements));
SELECT t.eq('every fixed deposit is gone',    0::bigint, (SELECT COUNT(*) FROM bms.fixed_deposits));
SELECT t.eq('every salary payment is gone',   0::bigint, (SELECT COUNT(*) FROM bms.salary_payments));
SELECT t.eq('every issue is gone',            0::bigint, (SELECT COUNT(*) FROM bms.issues));
SELECT t.eq('every work log is gone',         0::bigint, (SELECT COUNT(*) FROM bms.work_logs));
SELECT t.eq('every generator run is gone',    0::bigint, (SELECT COUNT(*) FROM bms.generator_runs));
SELECT t.eq('every budget is gone',           0::bigint, (SELECT COUNT(*) FROM bms.budgets));
SELECT t.eq('document numbering restarts',    0::bigint, (SELECT COUNT(*) FROM bms.doc_counters));

-- ...and the things that must survive, did.
SELECT t.eq('the flats survive the narrow reset',
  t.recall('pre_flats'), (SELECT COUNT(*)::text FROM bms.flats));
SELECT t.eq('the staff survive the narrow reset',
  t.recall('pre_staff'), (SELECT COUNT(*)::text FROM bms.staff));
SELECT t.eq('the user accounts survive',
  t.recall('pre_users'), (SELECT COUNT(*)::text FROM bms.user_profiles));
SELECT t.eq('the role assignments survive',
  t.recall('pre_roles'), (SELECT COUNT(*)::text FROM bms.user_roles));
SELECT t.eq('the categories survive',
  t.recall('pre_cats'), (SELECT COUNT(*)::text FROM bms.categories));
SELECT t.eq('the bank accounts survive',
  t.recall('pre_accounts'), (SELECT COUNT(*)::text FROM bms.accounts));
SELECT t.eq('the building name survives',
  t.recall('pre_name'), (SELECT building_name FROM bms.building_settings LIMIT 1));

-- The reset is on the record.
SELECT t.eq('the reset wrote one audit row', 1::bigint,
  (SELECT COUNT(*) FROM bms.audit_log WHERE action = 'SYSTEM_RESET'));
SELECT t.eq('the audit row names the person who did it',
  t.recall('admin'),
  (SELECT actor_user_id::text FROM bms.audit_log WHERE action='SYSTEM_RESET' ORDER BY id DESC LIMIT 1));
SELECT t.eq('the audit row records the scope', 'entries',
  (SELECT new_values ->> 'scope' FROM bms.audit_log WHERE action='SYSTEM_RESET' ORDER BY id DESC LIMIT 1));
SELECT t.ok('the audit row keeps the counts that were destroyed',
  (SELECT (old_values -> 'entries' ->> 'transactions')::bigint > 0
     FROM bms.audit_log WHERE action='SYSTEM_RESET' ORDER BY id DESC LIMIT 1));
SELECT t.eq('the reset is logged as high severity', 'HIGH',
  (SELECT severity FROM bms.audit_log WHERE action='SYSTEM_RESET' ORDER BY id DESC LIMIT 1));

-- ---------------------------------------------------------------------
-- The permission to delete does not leak out of the function
--
-- This is the check that matters most. reset_system() lifts block_delete()
-- through a transaction-local setting. If that setting outlived the call,
-- every immutability guarantee in the system would be off for the rest of
-- the session — and nothing else would report it.
-- ---------------------------------------------------------------------
SELECT t.eq('the purge flag is not set after the reset returns', '',
  COALESCE(current_setting('bms.purge', true), ''));

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT bms.create_transaction(
  CURRENT_DATE, 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
  'A row created after the reset', 100.00, 'CASH', t.uid('acct_cash'));
RESET ROLE;

-- WHERE true so that pg_safeupdate lets the statement through and the
-- trigger is the thing doing the refusing. Without it these passed for
-- the wrong reason: safeupdate rejected them first and block_delete()
-- was never reached, so the guard could have been missing entirely.
SELECT t.throws('deletion is blocked again immediately after a reset',
  'DELETE FROM bms.transactions WHERE true', 'never deleted');
SELECT t.throws('the audit log is append-only again after a reset',
  'DELETE FROM bms.audit_log WHERE true', 'append-only');
SELECT t.throws('setting the purge flag by hand does not enable deletion',
  'SELECT set_config(''bms.purge'',''on'',false); DELETE FROM bms.transactions WHERE true',
  NULL);

-- ---------------------------------------------------------------------
-- Scope 'all' — takes the master records too, and still not the people
-- ---------------------------------------------------------------------
SELECT set_config('bms.purge', '', false);       -- undo the hand-set flag above
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.runs('a super admin can run the full reset',
  'SELECT bms.reset_system(''all'',''RESET'')');

SELECT t.eq('the flats are gone',   0::bigint, (SELECT COUNT(*) FROM bms.flats));
SELECT t.eq('the owners are gone',  0::bigint, (SELECT COUNT(*) FROM bms.owners));
SELECT t.eq('the staff are gone',   0::bigint, (SELECT COUNT(*) FROM bms.staff));
SELECT t.eq('the assets are gone',  0::bigint, (SELECT COUNT(*) FROM bms.assets));
SELECT t.eq('the vendors are gone', 0::bigint, (SELECT COUNT(*) FROM bms.vendors));

-- Nobody loses their login. This is the line the reset must never cross:
-- an admin who wipes the data and cannot then sign in has no way back.
SELECT t.eq('every user account still exists',
  t.recall('pre_users'), (SELECT COUNT(*)::text FROM bms.user_profiles));
SELECT t.eq('every role assignment still exists',
  t.recall('pre_roles'), (SELECT COUNT(*)::text FROM bms.user_roles));
SELECT t.ok('the person who ran it is still a super admin', bms.is_superuser());
SELECT t.eq('the building settings still exist',
  t.recall('pre_name'), (SELECT building_name FROM bms.building_settings LIMIT 1));
SELECT t.eq('the chart of categories still exists',
  t.recall('pre_cats'), (SELECT COUNT(*)::text FROM bms.categories));
SELECT t.ok('the departments still exist', (SELECT COUNT(*) FROM bms.departments) > 0);
SELECT t.ok('the funds still exist',       (SELECT COUNT(*) FROM bms.funds) > 0);
SELECT t.ok('the bank accounts still exist',(SELECT COUNT(*) FROM bms.accounts) > 0);

-- The full reset clears the old audit history, so the trail must begin
-- with the reset that cleared it — otherwise the wipe is the one event in
-- the system's life with no record.
SELECT t.eq('the audit log holds exactly the reset that cleared it', 1::bigint,
  (SELECT COUNT(*) FROM bms.audit_log));
SELECT t.eq('and that row is the reset', 'SYSTEM_RESET',
  (SELECT action FROM bms.audit_log ORDER BY id DESC LIMIT 1));
SELECT t.eq('recording the full scope', 'all',
  (SELECT new_values ->> 'scope' FROM bms.audit_log ORDER BY id DESC LIMIT 1));

-- An empty system previews as empty rather than failing.
SELECT t.eq('a preview on an empty system reports nothing to delete', 0::bigint,
  ((bms.reset_preview() ->> 'total_entries')::bigint));
SELECT t.runs('a reset on an already-empty system is harmless',
  'SELECT bms.reset_system(''entries'',''RESET'')');
