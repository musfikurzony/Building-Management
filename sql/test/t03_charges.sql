-- =====================================================================
-- t03 — service charge: generation, per-flat rates, the worked example
-- from the proposal, waivers, opening balances, reversal.
-- =====================================================================
SET t.suite = 't03 service charge';
SET search_path = bms, public;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);

-- ---------------------------------------------------------------------
-- Opening balance: A-101 already owed Tk 5,000 at go-live.
-- ---------------------------------------------------------------------
SELECT t.runs('set an opening balance',
  'SELECT bms.set_opening_balance(''' || t.recall('flat_101') || ''', 5000.00, 2026, 5)');
SELECT t.eq('opening balance shows as outstanding', 5000.00::numeric,
            (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='A-101'));

-- ---------------------------------------------------------------------
-- Generate June 2026.
-- ---------------------------------------------------------------------
SELECT t.runs('generate June 2026', 'SELECT bms.generate_monthly_charges(2026, 6)');
SELECT t.eq('one charge per active flat', 3::bigint,
  (SELECT COUNT(*) FROM bms.flat_charges WHERE period_year=2026 AND period_month=6));

-- Per-flat rates, including the NULL fallback to the building default.
SELECT t.eq('A-101 billed at its own rate',      5000.00::numeric,
  (SELECT charge_amount FROM bms.v_flat_charges WHERE flat_number='A-101' AND period_month=6));
SELECT t.eq('A-102 billed at its lower rate',    4500.00::numeric,
  (SELECT charge_amount FROM bms.v_flat_charges WHERE flat_number='A-102' AND period_month=6));
SELECT t.eq('A-103 falls back to the default',   5000.00::numeric,
  (SELECT charge_amount FROM bms.v_flat_charges WHERE flat_number='A-103' AND period_month=6));

-- Pressing the button twice must not double-bill. It used to be refused
-- outright; it is now allowed and bills only what is missing, which is
-- the same protection reached a better way — a flat added later can still
-- be picked up. The assertion that matters is unchanged: three flats,
-- three charges, however many times it is pressed.
SELECT t.runs('generating June twice is allowed',
  'SELECT bms.generate_monthly_charges(2026, 6)');
SELECT t.eq('still exactly 3 charges for June', 3::bigint,
  (SELECT COUNT(*) FROM bms.flat_charges WHERE period_year=2026 AND period_month=6));
SELECT t.eq('and the second press says it added nothing',
  'Every active flat was already billed for this month.',
  (bms.generate_monthly_charges(2026, 6)).notes);

SELECT t.runs('generate July 2026', 'SELECT bms.generate_monthly_charges(2026, 7)');

-- ---------------------------------------------------------------------
-- THE WORKED EXAMPLE — Flat A-102 at Tk 4,500.
-- Jun + Jul generated  -> owes 9,000
-- pays 3,000 on 12 Jul -> Jun partial, owes 6,000
-- pays 12,000 on 28 Jul-> Jun+Jul paid, advance 6,000
-- Aug generated        -> auto-consumes advance, advance 1,500
-- ---------------------------------------------------------------------
SELECT t.eq('A-102 owes 9,000 after two months', 9000.00::numeric,
            (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='A-102'));

SELECT t.runs('record a partial payment of 3,000',
  'SELECT bms.record_payment(''' || t.recall('flat_102') || ''', 3000.00, DATE ''2026-07-12'',
     ''BKASH'', ''' || t.recall('acct_bank') || ''')');

SELECT t.eq('June is now PARTIAL', 'PARTIAL',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='A-102' AND period_month=6));
SELECT t.eq('A-102 now owes 6,000', 6000.00::numeric,
            (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='A-102'));
SELECT t.eq('no advance yet', 0.00::numeric,
            (SELECT advance FROM bms.v_flat_dues WHERE flat_number='A-102'));

SELECT t.runs('record an over-payment of 12,000',
  'SELECT bms.record_payment(''' || t.recall('flat_102') || ''', 12000.00, DATE ''2026-07-28'',
     ''BANK_TRANSFER'', ''' || t.recall('acct_bank') || ''')');

SELECT t.eq('June is PAID',  'PAID',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='A-102' AND period_month=6));
SELECT t.eq('July is PAID',  'PAID',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='A-102' AND period_month=7));
SELECT t.eq('A-102 owes nothing', 0.00::numeric,
            (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='A-102'));
SELECT t.eq('A-102 is 6,000 in advance', 6000.00::numeric,
            (SELECT advance FROM bms.v_flat_dues WHERE flat_number='A-102'));

SELECT t.runs('generate August 2026', 'SELECT bms.generate_monthly_charges(2026, 8)');
SELECT t.eq('August settles itself from the advance', 'PAID',
  (SELECT status FROM bms.v_flat_charges WHERE flat_number='A-102' AND period_month=8));
SELECT t.eq('advance is down to 1,500', 1500.00::numeric,
            (SELECT advance FROM bms.v_flat_dues WHERE flat_number='A-102'));

-- Money in equals money accounted for.
SELECT t.eq('allocations never exceed what was received', true,
  (SELECT SUM(amount) FROM bms.payment_allocations pa
     JOIN bms.flat_charges fc ON fc.id = pa.flat_charge_id
    WHERE fc.flat_id = t.uid('flat_102'))
  <= (SELECT SUM(amount) FROM bms.payments WHERE flat_id = t.uid('flat_102') AND status='ACTIVE'));

-- Each payment posted exactly one income transaction.
SELECT t.eq('each payment posted one income transaction', 2::bigint,
  (SELECT COUNT(*) FROM bms.transactions
    WHERE source_module='charges' AND flat_id = t.uid('flat_102') AND status='POSTED'));
SELECT t.eq('collections reached the bank account', 15000.00::numeric,
  (SELECT SUM(l.signed_amount) FROM bms.ledger_entries l
     JOIN bms.transactions tx ON tx.id = l.txn_id
    WHERE tx.source_module='charges' AND tx.flat_id = t.uid('flat_102')));

-- ---------------------------------------------------------------------
-- Collection reporting.
-- ---------------------------------------------------------------------
SELECT t.eq('June charged total is correct', 14500.00::numeric,
  (SELECT charged FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=6));
SELECT t.eq('June collected is A-102 only', 4500.00::numeric,
  (SELECT collected FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=6));
SELECT t.eq('June collection percentage', 31.0::numeric,
  (SELECT collection_pct FROM bms.v_monthly_collection WHERE period_year=2026 AND period_month=6));

-- ---------------------------------------------------------------------
-- Waivers: requested by one person, approved by another, and they never
-- silently edit the original charge amount.
-- ---------------------------------------------------------------------
SELECT t.remember('adj1', (bms.request_adjustment(
    (SELECT id FROM bms.v_flat_charges WHERE flat_number='A-103' AND period_month=6),
    'WAIVER', 2000.00, 'Flat vacant for half the month')).id::text);

SELECT t.eq('a pending waiver does not change the charge yet', 5000.00::numeric,
  (SELECT net_payable FROM bms.v_flat_charges WHERE flat_number='A-103' AND period_month=6));
SELECT t.throws('you cannot approve your own waiver',
  'SELECT bms.approve_adjustment(''' || t.recall('adj1') || ''')',
  'cannot approve a waiver you requested');
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('an admin approves the waiver',
  'SELECT bms.approve_adjustment(''' || t.recall('adj1') || ''')');
SELECT t.eq('net payable drops by the waiver', 3000.00::numeric,
  (SELECT net_payable FROM bms.v_flat_charges WHERE flat_number='A-103' AND period_month=6));
SELECT t.eq('the original charge amount is untouched', 5000.00::numeric,
  (SELECT charge_amount FROM bms.v_flat_charges WHERE flat_number='A-103' AND period_month=6));
SELECT t.throws('cannot waive more than is outstanding',
  'SELECT bms.request_adjustment((SELECT id FROM bms.v_flat_charges
      WHERE flat_number=''A-103'' AND period_month=6), ''WAIVER'', 99999, ''too much'')',
  'only');

-- ---------------------------------------------------------------------
-- Reversing a payment gives the money back and re-opens the charges.
-- ---------------------------------------------------------------------
SELECT t.remember('pay_small', (SELECT id::text FROM bms.payments
   WHERE flat_id = t.uid('flat_102') AND amount = 3000.00));
SELECT t.runs('reverse the 3,000 payment',
  'SELECT bms.reverse_payment(''' || t.recall('pay_small') || ''', ''Cheque bounced'')');
SELECT t.eq('payment is marked REVERSED', 'REVERSED',
            (SELECT status FROM bms.payments WHERE id = t.uid('pay_small')));
SELECT t.eq('the flat owes 1,500 again', 1500.00::numeric,
            (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='A-102'));
SELECT t.eq('income was reversed on the ledger too', 12000.00::numeric,
  (SELECT SUM(l.signed_amount) FROM bms.ledger_entries l
     JOIN bms.transactions tx ON tx.id = l.txn_id
    WHERE tx.source_module='charges' AND tx.flat_id = t.uid('flat_102')));

-- ---------------------------------------------------------------------
-- The flat statement adds up.
-- ---------------------------------------------------------------------
SELECT t.eq('statement balances against the dues view', true,
  (SELECT COALESCE(SUM(debit) - SUM(credit), 0)
     FROM bms.v_flat_ledger WHERE flat_id = t.uid('flat_102'))
  = (SELECT outstanding - advance FROM bms.v_flat_dues WHERE flat_number='A-102'));

RESET ROLE;

-- =====================================================================
-- TOPPING UP A MONTH AFTER A FLAT IS ADDED
--
-- Reported from the live building: September was generated with two
-- flats, more flats were added, and pressing Generate again refused with
-- "already been generated (2 flats)". The new flats could then never be
-- billed for September, and nothing said so.
--
-- Generation is now a top-up. Everything below is about the two things
-- that must both hold: the new flat gets billed, and the old ones do not
-- get billed twice.
-- =====================================================================
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.remember('tu_y', '2027');
SELECT t.remember('tu_m', '4');

SELECT bms.generate_monthly_charges(2027, 4);
SELECT t.remember('tu_first', (SELECT COUNT(*)::text FROM bms.flat_charges
                                WHERE period_year=2027 AND period_month=4));
SELECT t.ok('the first run bills the flats that exist',
  (SELECT COUNT(*) FROM bms.flat_charges WHERE period_year=2027 AND period_month=4) > 0,
  t.recall('tu_first'));

-- A flat joins after the month was generated.
INSERT INTO bms.flats (flat_number, floor, service_charge, status)
VALUES ('Z-909', 9, 4200, 'ACTIVE');

-- Pressing Generate again must not be refused...
SELECT t.runs('generating the same month again is allowed',
  'SELECT bms.generate_monthly_charges(2027, 4)');

-- ...must bill the newcomer...
SELECT t.eq('the flat added afterwards is now billed', 1::bigint,
  (SELECT COUNT(*) FROM bms.flat_charges fc JOIN bms.flats f ON f.id = fc.flat_id
    WHERE fc.period_year=2027 AND fc.period_month=4 AND f.flat_number='Z-909'));
SELECT t.eq('at its own rate, not the building default', 4200::numeric,
  (SELECT fc.charge_amount FROM bms.flat_charges fc JOIN bms.flats f ON f.id = fc.flat_id
    WHERE fc.period_year=2027 AND fc.period_month=4 AND f.flat_number='Z-909'));

-- ...and must not bill anyone twice.
SELECT t.eq('no flat has two charges for the month', 0::bigint,
  (SELECT COUNT(*) FROM (
     SELECT flat_id FROM bms.flat_charges
      WHERE period_year=2027 AND period_month=4 AND charge_source='MONTHLY'
      GROUP BY flat_id HAVING COUNT(*) > 1) d));
SELECT t.eq('exactly one more charge than before',
  (t.recall('tu_first')::bigint + 1),
  (SELECT COUNT(*) FROM bms.flat_charges WHERE period_year=2027 AND period_month=4));

-- A third press with nothing missing changes nothing at all.
SELECT t.remember('tu_after', (SELECT COUNT(*)::text FROM bms.flat_charges
                                WHERE period_year=2027 AND period_month=4));
SELECT bms.generate_monthly_charges(2027, 4);
SELECT t.eq('a run with nothing missing adds nothing',
  t.recall('tu_after'), (SELECT COUNT(*)::text FROM bms.flat_charges
                          WHERE period_year=2027 AND period_month=4));
SELECT t.ok('and says so rather than reporting a silent success',
  (bms.generate_monthly_charges(2027, 4)).notes LIKE '%already billed%',
  (bms.generate_monthly_charges(2027, 4)).notes);

-- The month's own totals describe the month, not the last pass.
SELECT t.eq('the run row counts every flat billed for the month',
  (SELECT COUNT(*)::int FROM bms.flat_charges
    WHERE period_year=2027 AND period_month=4 AND charge_source='MONTHLY'),
  (SELECT flat_count FROM bms.charge_runs
    WHERE period_year=2027 AND period_month=4 AND run_type='MONTHLY'));
SELECT t.eq('and totals every charge raised for it',
  (SELECT SUM(charge_amount) FROM bms.flat_charges
    WHERE period_year=2027 AND period_month=4 AND charge_source='MONTHLY'),
  (SELECT total_amount FROM bms.charge_runs
    WHERE period_year=2027 AND period_month=4 AND run_type='MONTHLY'));

UPDATE bms.flats SET status='INACTIVE' WHERE flat_number='Z-909';
RESET ROLE;

-- =====================================================================
-- SERVICE CHARGE HAS ONE DOOR
--
-- Also from the live building: the same money was entered twice, once
-- through Record payment and once by hand in the ledger under
-- Service Charge / Monthly service charge. The ledger copy belongs to no
-- flat, so the flat still read as unpaid while the dashboard counted the
-- money twice.
-- =====================================================================
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.remember('svc_cat', (SELECT c.id::text FROM bms.categories c
   JOIN bms.departments d ON d.id = c.department_id
  WHERE d.code='SERVICE_CHARGE' AND c.name='Monthly service charge'));
SELECT t.remember('svc_dept', (SELECT id::text FROM bms.departments WHERE code='SERVICE_CHARGE'));

SELECT t.throws('service charge cannot be typed straight into the ledger',
  'SELECT bms.create_transaction(CURRENT_DATE, ''INCOME'', ''' || t.recall('svc_dept') ||
  ''', ''' || t.recall('svc_cat') || ''', ''hand-typed service charge'', 5000, ''CASH'', ''' ||
  t.recall('acct_cash') || ''')',
  'Record payment');

SELECT t.throws('nor a late fee, for the same reason',
  'SELECT bms.create_transaction(CURRENT_DATE, ''INCOME'', ''' || t.recall('svc_dept') ||
  ''', (SELECT c.id FROM bms.categories c JOIN bms.departments d ON d.id=c.department_id
        WHERE d.code=''SERVICE_CHARGE'' AND c.name=''Late fee''),
       ''hand-typed late fee'', 200, ''CASH'', ''' || t.recall('acct_cash') || ''')',
  'Record payment');

-- The proper door still works, and still produces exactly one income row.
SELECT t.remember('door_before', (SELECT COUNT(*)::text FROM bms.transactions
  WHERE direction='INCOME' AND department_id = t.uid('svc_dept')));
SELECT bms.generate_monthly_charges(2027, 5);
SELECT bms.record_payment(t.uid('flat_102'), 1500, make_date(2027,5,9),
                          'CASH', t.uid('acct_cash'), NULL, NULL, NULL);
SELECT t.eq('recording a payment properly still posts its income',
  (t.recall('door_before')::bigint + 1),
  (SELECT COUNT(*) FROM bms.transactions
    WHERE direction='INCOME' AND department_id = t.uid('svc_dept')));
SELECT t.ok('and that income is attached to the flat, not floating',
  (SELECT flat_id FROM bms.transactions
    WHERE direction='INCOME' AND department_id = t.uid('svc_dept')
    ORDER BY created_at DESC LIMIT 1) = t.uid('flat_102'));

-- Ordinary income elsewhere is untouched by the rule.
SELECT t.runs('other income can still be entered in the ledger by hand',
  'SELECT bms.create_transaction(CURRENT_DATE, ''INCOME'',
     (SELECT id FROM bms.departments WHERE code=''OTHER''),
     (SELECT c.id FROM bms.categories c JOIN bms.departments d ON d.id=c.department_id
       WHERE d.code=''OTHER'' AND c.name=''Other income''),
     ''roof antenna rent'', 5000, ''CASH'', ''' || t.recall('acct_cash') || ''')');
RESET ROLE;
