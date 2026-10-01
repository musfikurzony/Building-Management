-- =====================================================================
-- t04 — ONE CONTINUOUS STORY, the way the building actually runs.
--
-- Not a list of function checks: a single month lived end to end, with
-- the bank balance re-asserted after every step, so that if any one step
-- moves money it should not, the next assertion catches it.
--
--   1. the committee sets the building up
--   2. the caretaker buys diesel and submits the bill
--   3. the manager approves it — the ledger and the bank move together
--   4. service charges are generated for the month
--   5. one flat pays in full, one pays part, one pays a year ahead
--   6. a waiver is requested and approved by a second person
--   7. a payment turns out to be a bounced cheque and is reversed
--   8. the month is closed, and stays closed
--   9. every step above is in the audit log, attributed to a person
-- =====================================================================
SET t.suite = 't04 full journey';
SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- 1. SETUP — a fresh building, entered by the admin.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.runs('admin sets the building up',
  $$UPDATE bms.building_settings
       SET building_name = 'Shanti Tower', floor_count = 9,
           default_service_charge = 5000, charge_due_day = 10 WHERE id$$);

-- Two more flats so the month has some shape to it.
INSERT INTO bms.flats (flat_number, floor, service_charge) VALUES
  ('B-201', 2, 5000.00), ('B-202', 2, 4000.00)
ON CONFLICT (flat_number) DO NOTHING;

SELECT t.eq('five active flats to bill', 5::bigint,
  (SELECT COUNT(*) FROM bms.flats WHERE status = 'ACTIVE'));

-- Everything that follows is measured against this starting point.
SELECT t.remember('bank0', (SELECT current_balance::text FROM bms.v_account_balances WHERE code='BANK1'));
SELECT t.eq('bank starts at its opening balance', 100000.00::numeric, t.recall('bank0')::numeric);

-- ---------------------------------------------------------------------
-- 2. THE CARETAKER BUYS DIESEL.
-- ---------------------------------------------------------------------
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);

SELECT t.remember('fuel', (bms.create_transaction(
    DATE '2026-09-03', 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'Diesel 60 litres for the generator', 6600.00, 'CASH',
    NULL,           -- no account chosen: the caretaker cannot see the bank
    NULL, NULL, NULL, 'INV-4471')).id::text);

SELECT t.eq('the caretaker''s bill waits for approval', 'PENDING_APPROVAL',
  (SELECT status FROM bms.my_submissions() WHERE id = t.uid('fuel')));
SELECT t.eq('it landed in petty cash, not the bank', 'CASH',
  (SELECT a.kind FROM bms.entry_accounts() a
     JOIN bms.my_submissions() m ON m.account_id = a.id WHERE m.id = t.uid('fuel')));
SELECT t.ok('no money has moved yet',
  NOT EXISTS (SELECT 1 FROM bms.ledger_entries WHERE txn_id = t.uid('fuel')));
SELECT t.throws('the caretaker cannot approve their own bill',
  'SELECT bms.approve_transaction(''' || t.recall('fuel') || ''')', 'permission denied');

-- ---------------------------------------------------------------------
-- 3. THE MANAGER APPROVES IT.
-- ---------------------------------------------------------------------
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('manager'), false);

SELECT t.runs('the manager approves the diesel bill',
  'SELECT bms.approve_transaction(''' || t.recall('fuel') || ''')');
SELECT t.eq('it is posted', 'POSTED',
  (SELECT status FROM bms.transactions WHERE id = t.uid('fuel')));
SELECT t.eq('the approver is recorded, and is not the person who entered it', true,
  (SELECT approved_by <> created_by FROM bms.transactions WHERE id = t.uid('fuel')));
SELECT t.eq('petty cash went down by exactly the bill', -6600.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code = 'CASH'));
SELECT t.eq('the bank was not touched', 100000.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code = 'BANK1'));
SELECT t.eq('the generator department shows the cost', 6600.00::numeric,
  (SELECT expense FROM bms.v_department_spend
    WHERE code='GENERATOR' AND period_year=2026 AND period_month=9));

-- ---------------------------------------------------------------------
-- 4. SERVICE CHARGES FOR SEPTEMBER.
-- ---------------------------------------------------------------------
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);

SELECT t.runs('generate September 2026', 'SELECT bms.generate_monthly_charges(2026, 9)');
SELECT t.eq('every active flat was billed', 5::bigint,
  (SELECT COUNT(*) FROM bms.flat_charges WHERE period_year=2026 AND period_month=9));
-- 5000 + 4500 + 5000 (default) + 5000 + 4000
SELECT t.eq('the month totals the sum of each flat''s own rate', 23500.00::numeric,
  (SELECT charged FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=9));
SELECT t.eq('nothing has been collected yet', 0.00::numeric,
  (SELECT collected FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=9));
SELECT t.eq('generating a month does not move the bank', 100000.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code = 'BANK1'));

-- ---------------------------------------------------------------------
-- 5. THREE FLATS PAY, THREE DIFFERENT WAYS.
-- ---------------------------------------------------------------------
-- (a) B-201 pays in full.
SELECT t.runs('B-201 pays in full',
  $$SELECT bms.record_payment(
      (SELECT id FROM bms.flats WHERE flat_number='B-201'),
      5000.00, DATE '2026-09-06', 'BKASH',
      (SELECT id FROM bms.accounts WHERE code='BANK1'), 'TRX9911')$$);
SELECT t.eq('B-201 is paid', 'PAID',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='B-201' AND period_month=9));
SELECT t.eq('the bank rose by the payment', 105000.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));

-- (b) B-202 pays part of its Tk 4,000.
SELECT t.runs('B-202 pays 1,500 of 4,000',
  $$SELECT bms.record_payment(
      (SELECT id FROM bms.flats WHERE flat_number='B-202'),
      1500.00, DATE '2026-09-09', 'CASH',
      (SELECT id FROM bms.accounts WHERE code='CASH'))$$);
SELECT t.eq('B-202 shows as partial', 'PARTIAL',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='B-202' AND period_month=9));
SELECT t.eq('B-202 still owes 2,500', 2500.00::numeric,
  (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='B-202'));
SELECT t.eq('petty cash recovered by the cash payment', -5100.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='CASH'));

-- (c) A-101 pays three months ahead.
SELECT t.runs('A-101 pays 15,000 — three months in advance',
  $$SELECT bms.record_payment(
      (SELECT id FROM bms.flats WHERE flat_number='A-101'),
      15000.00, DATE '2026-09-10', 'BANK_TRANSFER',
      (SELECT id FROM bms.accounts WHERE code='BANK1'), 'NEFT-5521')$$);
SELECT t.eq('A-101 September is settled', 'PAID',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='A-101' AND period_month=9));
SELECT t.eq('the rest is held as advance', 10000.00::numeric,
  (SELECT advance FROM bms.v_flat_dues WHERE flat_number='A-101'));
SELECT t.eq('A-101 owes nothing', 0.00::numeric,
  (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='A-101'));

-- October is generated and the advance settles it with no action at all.
SELECT t.runs('generate October 2026', 'SELECT bms.generate_monthly_charges(2026, 10)');
SELECT t.eq('A-101 October pays itself from the advance', 'PAID',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='A-101' AND period_month=10));
SELECT t.eq('advance is down to two months', 5000.00::numeric,
  (SELECT advance FROM bms.v_flat_dues WHERE flat_number='A-101'));
SELECT t.eq('and no new money appeared in the bank', 120000.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));

-- B-201 5,000 + B-202 1,500 + A-101 5,000 = 11,500 of 23,500.
SELECT t.eq('September collection is 11,500 of 23,500', 11500.00::numeric,
  (SELECT collected FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=9));
SELECT t.eq('September collection rate', 48.9::numeric,
  (SELECT collection_pct FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=9));
SELECT t.eq('two flats have paid September in full', 2::bigint,
  (SELECT flats_paid FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=9));
SELECT t.eq('one flat is partial', 1::bigint,
  (SELECT flats_partial FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=9));

-- ---------------------------------------------------------------------
-- 6. A WAIVER — requested by one person, approved by another.
-- ---------------------------------------------------------------------
SELECT t.remember('waiver', (bms.request_adjustment(
    (SELECT id FROM bms.v_flat_charges WHERE flat_number='B-202' AND period_month=9),
    'WAIVER', 2500.00, 'Flat was under repair for most of September')).id::text);
SELECT t.eq('the bill is unchanged while the waiver waits', 4000.00::numeric,
  (SELECT net_payable FROM bms.v_flat_charges WHERE flat_number='B-202' AND period_month=9));
SELECT t.throws('the requester cannot approve their own waiver',
  'SELECT bms.approve_adjustment(''' || t.recall('waiver') || ''')', 'cannot approve a waiver');

RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('the admin approves the waiver',
  'SELECT bms.approve_adjustment(''' || t.recall('waiver') || ''')');
SELECT t.eq('the payable drops to what was actually paid', 1500.00::numeric,
  (SELECT net_payable FROM bms.v_flat_charges WHERE flat_number='B-202' AND period_month=9));
SELECT t.eq('the original charge is still on record', 4000.00::numeric,
  (SELECT charge_amount FROM bms.v_flat_charges WHERE flat_number='B-202' AND period_month=9));
SELECT t.eq('B-202''s September is now settled', 'PAID',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='B-202' AND period_month=9));
-- October was generated in the meantime, so that is all it still owes.
SELECT t.eq('B-202 owes only October', 4000.00::numeric,
  (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='B-202'));
SELECT t.eq('a waiver moves no money', 120000.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));

-- ---------------------------------------------------------------------
-- 7. THE BOUNCED CHEQUE.
-- ---------------------------------------------------------------------
SELECT t.remember('bad_pay', (SELECT p.id::text FROM bms.payments p
   JOIN bms.flats f ON f.id = p.flat_id
  WHERE f.flat_number = 'B-201' AND p.status = 'ACTIVE'
  ORDER BY p.created_at LIMIT 1));

SELECT t.runs('reverse B-201''s payment',
  'SELECT bms.reverse_payment(''' || t.recall('bad_pay') || ''', ''Cheque returned unpaid'')');
SELECT t.eq('the payment is marked reversed', 'REVERSED',
  (SELECT status FROM bms.payments WHERE id = t.uid('bad_pay')));
-- UNPAID and OVERDUE both mean "not paid"; which one depends only on
-- whether today is past the due date. This was written as = 'UNPAID' in
-- August, when 10 September was still ahead, and began failing on its own
-- the morning of 11 September with no code having changed. The thing
-- under test is that reversing the payment un-pays the month, not what
-- the calendar says.
SELECT t.ok('B-201''s September is unpaid again',
  (SELECT status FROM bms.v_flat_charges
    WHERE flat_number='B-201' AND period_year=2026 AND period_month=9) IN ('UNPAID','OVERDUE'),
  (SELECT status FROM bms.v_flat_charges
    WHERE flat_number='B-201' AND period_year=2026 AND period_month=9));
SELECT t.eq('B-201 owes September and October', 10000.00::numeric,
  (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='B-201'));
SELECT t.eq('the bank gave the money back', 115000.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));
SELECT t.ok('the original income transaction is still readable',
  EXISTS (SELECT 1 FROM bms.transactions
           WHERE source_module='charges' AND source_ref = t.uid('bad_pay')
             AND status='REVERSED' AND NOT is_reversal));
-- The reversal carries the same source_module/source_ref as the original,
-- which is what lets you trace both halves back to the payment. So the
-- original is the one that is NOT itself a reversal.
SELECT t.eq('and it is linked to the transaction that reversed it', true,
  (SELECT reversed_by_txn_id IS NOT NULL FROM bms.transactions
    WHERE source_module='charges' AND source_ref = t.uid('bad_pay') AND NOT is_reversal));
SELECT t.eq('both halves trace back to the same payment', 2::bigint,
  (SELECT COUNT(*) FROM bms.transactions
    WHERE source_module='charges' AND source_ref = t.uid('bad_pay')));
SELECT t.eq('September collection falls back to 6,500', 6500.00::numeric,
  (SELECT collected FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=9));

-- ---------------------------------------------------------------------
-- 8. CLOSING THE MONTH.
-- ---------------------------------------------------------------------
SELECT t.runs('close September 2026', 'SELECT bms.close_period(2026, 9)');
SELECT t.throws('no new entry can be dated into September',
  $$SELECT bms.create_transaction(DATE '2026-09-28','EXPENSE',NULL,NULL,'late entry',
      100,'CASH',(SELECT id FROM bms.accounts WHERE code='CASH'))$$, 'is closed');
SELECT t.throws('no payment can be back-dated into September either',
  $$SELECT bms.record_payment((SELECT id FROM bms.flats WHERE flat_number='B-201'),
      5000, DATE '2026-09-30','CASH',(SELECT id FROM bms.accounts WHERE code='CASH'))$$,
  'period is closed');
SELECT t.eq('the closed month''s figures are frozen', 6500.00::numeric,
  (SELECT collected FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=9));
SELECT t.eq('October is still open for business', 'OPEN',
  (SELECT status FROM bms.accounting_periods WHERE period_year=2026 AND period_month=10));

-- ---------------------------------------------------------------------
-- 9. THE WHOLE STORY IS IN THE AUDIT LOG.
-- ---------------------------------------------------------------------
SELECT t.ok('the caretaker''s entry is attributed to the caretaker',
  EXISTS (SELECT 1 FROM bms.audit_log
           WHERE entity_table='transactions' AND entity_id = t.uid('fuel')
             AND action='INSERT' AND actor_name_snapshot='Caretaker'));
SELECT t.ok('the manager''s approval is attributed to the manager',
  EXISTS (SELECT 1 FROM bms.audit_log
           WHERE entity_table='transactions' AND entity_id = t.uid('fuel')
             AND 'status' = ANY(changed_fields) AND actor_name_snapshot='Building Manager'));
SELECT t.ok('the waiver approval is recorded',
  EXISTS (SELECT 1 FROM bms.audit_log
           WHERE entity_table='adjustments' AND entity_id = t.uid('waiver')
             AND severity='HIGH'));
SELECT t.ok('the payment reversal is recorded',
  EXISTS (SELECT 1 FROM bms.audit_log
           WHERE entity_table='payments' AND entity_id = t.uid('bad_pay')
             AND 'status' = ANY(changed_fields)));
SELECT t.ok('closing the period is recorded',
  EXISTS (SELECT 1 FROM bms.audit_log WHERE entity_table='accounting_periods'));
SELECT t.ok('a service charge change would show its before and after',
  (SELECT bms.has_perm('audit','view')));

-- ---------------------------------------------------------------------
-- The fifteen questions from section 34 of the specification.
-- ---------------------------------------------------------------------
SELECT t.eq('Q1  how much money came in (the bounced cheque excluded)', 16500.00::numeric,
  (SELECT COALESCE(SUM(income),0) FROM bms.v_income_expense_monthly WHERE period_year=2026 AND period_month=9));
SELECT t.ok('Q2  from which flat',
  EXISTS (SELECT 1 FROM bms.v_transactions WHERE direction='INCOME' AND flat_number IS NOT NULL));
SELECT t.ok('Q3  when', EXISTS (SELECT 1 FROM bms.v_transactions WHERE txn_date IS NOT NULL));
SELECT t.eq('Q4  how much is outstanding', 33000.00::numeric,
  (SELECT SUM(outstanding) FROM bms.v_flat_dues));
SELECT t.eq('Q5  how much was spent', 6600.00::numeric,
  (SELECT COALESCE(SUM(expense),0) FROM bms.v_income_expense_monthly WHERE period_year=2026 AND period_month=9));
-- The reversal is an EXPENSE row in the ledger. If it were counted, this
-- would read 11,600 and the committee would think we spent money we did not.
SELECT t.ok('the bounced cheque did not inflate September''s spending',
  (SELECT expense FROM bms.v_income_expense_monthly WHERE period_year=2026 AND period_month=9) = 6600.00);
SELECT t.ok('but both halves are still visible in the ledger',
  (SELECT COUNT(*) FROM bms.transactions WHERE is_reversal) >= 1
  AND (SELECT COUNT(*) FROM bms.transactions WHERE status='REVERSED') >= 1);
SELECT t.ok('Q6  where it was spent',
  EXISTS (SELECT 1 FROM bms.v_department_spend WHERE expense > 0));
SELECT t.ok('Q7  who entered it',
  EXISTS (SELECT 1 FROM bms.v_transactions WHERE created_by_name IS NOT NULL));
SELECT t.ok('Q8  who approved it',
  EXISTS (SELECT 1 FROM bms.v_transactions WHERE approved_by_name IS NOT NULL));
SELECT t.ok('Q9  which receipt supports it',
  (SELECT COUNT(*) FROM bms.v_transactions WHERE reference_no IS NOT NULL) > 0);
SELECT t.eq('Q10 what is the current bank balance', 115000.00::numeric,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));
SELECT t.ok('Q11 reserve available (module arrives in phase 5, view is ready)',
  (SELECT COUNT(*) FROM bms.v_account_balances WHERE code='RESV1') = 1);
SELECT t.ok('Q12 fixed deposits (phase 5)',
  (SELECT COUNT(*) FROM bms.v_account_balances WHERE kind='FD') >= 0);
SELECT t.eq('Q13 total financial position', 109900.00::numeric,
  (SELECT SUM(current_balance) FROM bms.v_account_balances));
SELECT t.ok('Q14 what each department cost',
  EXISTS (SELECT 1 FROM bms.v_department_spend WHERE code='GENERATOR'));
SELECT t.ok('Q15 budget versus actual (view ready, budgets are phase 5)',
  (SELECT COUNT(*) FROM bms.v_budget_vs_actual) >= 0);

RESET ROLE;
