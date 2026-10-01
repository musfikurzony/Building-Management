-- =====================================================================
-- t02 — the ledger rules: approval, immutability, reversal, balances,
-- transfers, period locking, and money precision.
-- =====================================================================
SET t.suite = 't02 ledger';
SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Caretaker submits an expense. It must NOT post.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);

SELECT t.remember('txn1', (bms.create_transaction(
    DATE '2026-03-05', 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'Diesel 40 litres', 4800.00, 'CASH', t.uid('acct_cash'))).id::text);

SELECT t.eq('caretaker entry goes to PENDING_APPROVAL', 'PENDING_APPROVAL',
            (SELECT status FROM bms.transactions WHERE id = t.uid('txn1')));
SELECT t.ok('no ledger entry written before approval',
            NOT EXISTS (SELECT 1 FROM bms.ledger_entries WHERE txn_id = t.uid('txn1')));
SELECT t.ok('a document number was assigned on submit',
            (SELECT txn_no FROM bms.transactions WHERE id = t.uid('txn1')) LIKE 'EXP-2026-%');

SELECT t.throws('caretaker cannot approve it',
  'SELECT bms.approve_transaction(''' || t.recall('txn1') || ''')',
  'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------
-- Finance manager approves it. Self-approval is separately blocked.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);

SELECT t.runs('finance manager approves',
  'SELECT bms.approve_transaction(''' || t.recall('txn1') || ''')');
SELECT t.eq('transaction is now POSTED', 'POSTED',
            (SELECT status FROM bms.transactions WHERE id = t.uid('txn1')));
SELECT t.eq('exactly one ledger entry', 1::bigint,
            (SELECT COUNT(*) FROM bms.ledger_entries WHERE txn_id = t.uid('txn1')));
SELECT t.eq('expense moves the account down', -4800.00::numeric,
            (SELECT signed_amount FROM bms.ledger_entries WHERE txn_id = t.uid('txn1')));

-- Rule 3: posted is frozen.
SELECT t.throws('posted amount cannot be edited',
  'UPDATE bms.transactions SET amount = 1 WHERE id = ''' || t.recall('txn1') || '''',
  'cannot be edited');
SELECT t.throws('posted date cannot be edited',
  'UPDATE bms.transactions SET txn_date = CURRENT_DATE WHERE id = ''' || t.recall('txn1') || '''',
  'cannot be edited');
-- Rule 4: nothing is deleted.
-- Two layers: the client role has no DELETE grant at all...
SELECT t.throws('client role cannot delete a transaction',
  'DELETE FROM bms.transactions WHERE id = ''' || t.recall('txn1') || '''',
  'permission denied');
SELECT t.throws('client role cannot edit a ledger entry',
  'UPDATE bms.ledger_entries SET signed_amount = 1 WHERE txn_id = ''' || t.recall('txn1') || '''',
  'permission denied');

-- Rule 1: an approver may not approve their own entry.
SELECT t.remember('txn2', (bms.create_transaction(
    DATE '2026-03-06', 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'Generator servicing', 45000.00, 'BANK_TRANSFER', t.uid('acct_bank'))).id::text);
SELECT t.eq('large entry needs approval', 'PENDING_APPROVAL',
            (SELECT status FROM bms.transactions WHERE id = t.uid('txn2')));
SELECT t.throws('self-approval is blocked',
  'SELECT bms.approve_transaction(''' || t.recall('txn2') || ''')',
  'cannot approve a transaction you created');

-- Rule 2: approval limits are enforced.
SELECT t.remember('txn3', (bms.create_transaction(
    DATE '2026-03-07', 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'Major overhaul', 500000.00, 'BANK_TRANSFER', t.uid('acct_bank'))).id::text);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('manager'), false);
SELECT t.throws('manager cannot approve above their limit',
  'SELECT bms.approve_transaction(''' || t.recall('txn3') || ''')',
  'above your approval limit');
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('admin approves the large entry',
  'SELECT bms.approve_transaction(''' || t.recall('txn3') || ''')');
SELECT t.runs('admin approves the manager-blocked entry',
  'SELECT bms.approve_transaction(''' || t.recall('txn2') || ''')');

-- ---------------------------------------------------------------------
-- Reversal, not deletion.
-- ---------------------------------------------------------------------
SELECT t.remember('rev1', (bms.reverse_transaction(
    t.uid('txn1'), 'Fuel invoice was a duplicate')).id::text);
SELECT t.eq('original is marked REVERSED', 'REVERSED',
            (SELECT status FROM bms.transactions WHERE id = t.uid('txn1')));
SELECT t.ok('original still exists and is readable',
            EXISTS (SELECT 1 FROM bms.transactions WHERE id = t.uid('txn1')));
SELECT t.eq('the two are linked both ways', t.uid('rev1'),
            (SELECT reversed_by_txn_id FROM bms.transactions WHERE id = t.uid('txn1')));
SELECT t.eq('reversal is the opposite direction', 'INCOME',
            (SELECT direction FROM bms.transactions WHERE id = t.uid('rev1')));
SELECT t.eq('the pair nets to zero on the ledger', 0.00::numeric,
            (SELECT SUM(signed_amount) FROM bms.ledger_entries
              WHERE txn_id IN (t.uid('txn1'), t.uid('rev1'))));
SELECT t.throws('a reversed transaction cannot be reversed again',
  'SELECT bms.reverse_transaction(''' || t.recall('txn1') || ''', ''again'')',
  'only a posted transaction');

-- ...and the trigger still refuses even for a privileged connection.
RESET ROLE;
SELECT t.throws('even the table owner cannot delete a transaction',
  'DELETE FROM bms.transactions WHERE id = ''' || t.recall('txn1') || '''',
  'never deleted');
SELECT t.throws('even the table owner cannot edit a ledger entry',
  'UPDATE bms.ledger_entries SET signed_amount = 1 WHERE txn_id = ''' || t.recall('txn1') || '''',
  'immutable');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

-- ---------------------------------------------------------------------
-- Transfers move money without creating income or expense.
-- ---------------------------------------------------------------------
SELECT t.remember('trf1', (bms.create_transaction(
    DATE '2026-03-10', 'TRANSFER', NULL, NULL, 'Monthly reserve contribution',
    30000.00, 'BANK_TRANSFER', t.uid('acct_bank'), t.uid('acct_resv'))).id::text);
SELECT t.eq('transfer writes two ledger entries', 2::bigint,
            (SELECT COUNT(*) FROM bms.ledger_entries WHERE txn_id = t.uid('trf1')));
SELECT t.eq('transfer nets to zero across accounts', 0.00::numeric,
            (SELECT SUM(signed_amount) FROM bms.ledger_entries WHERE txn_id = t.uid('trf1')));
SELECT t.eq('reserve account received the money', 30000.00::numeric,
            (SELECT current_balance FROM bms.v_account_balances WHERE code = 'RESV1'));
SELECT t.eq('transfer is excluded from income', 0::bigint,
  (SELECT COUNT(*) FROM bms.v_income_expense_monthly v
    WHERE v.period_year=2026 AND v.period_month=3 AND v.income = 30000.00));

SELECT t.throws('a transfer to the same account is rejected',
  'SELECT bms.create_transaction(CURRENT_DATE, ''TRANSFER'', NULL, NULL, ''bad'', 10,
      ''BANK_TRANSFER'', ''' || t.recall('acct_bank') || ''', ''' || t.recall('acct_bank') || ''')',
  'txn_transfer_ck');

-- ---------------------------------------------------------------------
-- Balances are derived, and money keeps its precision.
-- ---------------------------------------------------------------------
-- Bank: 100000 opening - 45000 service - 500000 overhaul - 30000 transfer out
SELECT t.eq('bank balance is derived from the ledger', -475000.00::numeric,
            (SELECT current_balance FROM bms.v_account_balances WHERE code = 'BANK1'));

SELECT t.remember('txn4', (bms.create_transaction(
    DATE '2026-03-11', 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'Odd amount', 0.10, 'CASH', t.uid('acct_cash'))).id::text);
SELECT t.eq('a 0.10 expense is stored exactly', -0.10::numeric,
            (SELECT signed_amount FROM bms.ledger_entries WHERE txn_id = t.uid('txn4')));
SELECT t.throws('a zero amount is rejected',
  'SELECT bms.create_transaction(CURRENT_DATE, ''EXPENSE'', NULL, NULL, ''zero'', 0, ''CASH'', '''
  || t.recall('acct_cash') || ''')', 'greater than zero');
SELECT t.throws('a negative amount is rejected',
  'SELECT bms.create_transaction(CURRENT_DATE, ''EXPENSE'', NULL, NULL, ''neg'', -5, ''CASH'', '''
  || t.recall('acct_cash') || ''')', 'greater than zero');

-- ---------------------------------------------------------------------
-- Closing a month locks it.
-- ---------------------------------------------------------------------
-- A caretaker entry left waiting must block the month from closing.
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.remember('txn5', (bms.create_transaction(
    DATE '2026-03-15', 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'Unapproved March spend', 900.00, 'CASH', NULL)).id::text);
SELECT t.eq('an entry with no account falls back to petty cash', 'CASH',
  (SELECT a.kind FROM bms.entry_accounts() a
     JOIN bms.my_submissions() ms ON ms.account_id = a.id
    WHERE ms.id = t.uid('txn5')));
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.throws('cannot close a month with entries still waiting',
  'SELECT bms.close_period(2026, 3)', 'still unposted');

SELECT t.runs('clear the waiting entry first',
  'SELECT bms.approve_transaction(''' || t.recall('txn5') || ''')');
SELECT t.runs('close March 2026', 'SELECT bms.close_period(2026, 3)');
SELECT t.throws('no new transaction can be dated into a closed month',
  'SELECT bms.create_transaction(DATE ''2026-03-20'', ''EXPENSE'', NULL, NULL, ''late'', 100,
     ''CASH'', ''' || t.recall('acct_cash') || ''')',
  'is closed');
SELECT t.runs('reopen March 2026 with a reason',
  'SELECT bms.reopen_period(2026, 3, ''correction needed'')');

-- ---------------------------------------------------------------------
-- The audit trail recorded all of it.
-- ---------------------------------------------------------------------
SELECT t.ok('transaction inserts are audited',
  (SELECT COUNT(*) FROM bms.audit_log
    WHERE entity_table='transactions' AND action='INSERT') >= 4);
SELECT t.ok('approvals are audited as HIGH severity',
  EXISTS (SELECT 1 FROM bms.audit_log
           WHERE entity_table='transactions' AND severity='HIGH'
             AND 'status' = ANY(changed_fields)));
SELECT t.ok('the audit log names the actor',
  EXISTS (SELECT 1 FROM bms.audit_log WHERE actor_name_snapshot = 'Admin User'));
SELECT t.ok('bank account numbers never enter the audit log',
  NOT EXISTS (SELECT 1 FROM bms.audit_log
               WHERE new_values::text LIKE '%1234567890123%'
                  OR old_values::text LIKE '%1234567890123%'));

RESET ROLE;
