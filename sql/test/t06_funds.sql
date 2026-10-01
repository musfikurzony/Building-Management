-- =====================================================================
-- t06 — ADVANCED FINANCE, lived end to end.
--
-- The committee resolves to build a reserve, discovers the resolution is
-- not money, funds it properly, locks Tk 600,000 into a fixed deposit,
-- takes the interest as income, breaks the deposit early when the lift
-- motor dies, sets a budget and goes over it, and finally reconciles the
-- bank — once when the books are wrong and once when they are right.
--
-- Every step re-checks the building's total position, because the whole
-- point of this phase is that the total never stops being true.
-- =====================================================================
SET t.suite = 't06 funds';
SET search_path = bms, public;

CREATE OR REPLACE FUNCTION t.pm() RETURNS date
LANGUAGE sql STABLE AS $$ SELECT date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date $$;

-- ---------------------------------------------------------------------
-- 1. THE OPENING POSITION.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.eq('the building starts with Tk 100,000 in the bank', 100000.00,
  (SELECT bank_balance FROM bms.v_financial_position));
SELECT t.eq('and nothing in fixed deposits', 0.00,
  (SELECT fixed_deposits FROM bms.v_financial_position));
SELECT t.eq('two funds were seeded', 2::bigint, (SELECT COUNT(*) FROM bms.funds));
SELECT t.eq('and both are empty', 0.00,
  (SELECT COALESCE(SUM(current_balance),0) FROM bms.v_fund_balances));

SELECT t.remember('fund_reserve', (SELECT id::text FROM bms.funds WHERE code='RESERVE'));
SELECT t.remember('fund_capex',   (SELECT id::text FROM bms.funds WHERE code='CAPEX'));

-- Give the capital fund a target so progress means something.
UPDATE bms.funds SET target_amount = 2000000.00, target_date = CURRENT_DATE + 1095
 WHERE code = 'CAPEX';

-- ---------------------------------------------------------------------
-- 2. A RESOLUTION IS NOT MONEY.
--
-- The committee minutes Tk 400,000 "set aside for the lift". Nothing
-- moved. The system must show the earmark AND show that it is hollow —
-- this is the single most useful thing this module does.
-- ---------------------------------------------------------------------
SELECT t.runs('the committee earmarks Tk 400,000 for capital replacement', $$
  SELECT bms.record_fund_movement(t.uid('fund_capex'), t.pm(), 'CONTRIBUTION',
                                  400000.00, false, NULL, NULL,
                                  'Board resolution 2026/04 — lift replacement')
$$);

SELECT t.eq('the fund now shows Tk 400,000 set aside', 400000.00,
  (SELECT current_balance FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.eq('but none of it is actually funded', 0.00,
  (SELECT funded_amount FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.eq('the whole Tk 400,000 is a promise, not a balance', 400000.00,
  (SELECT unfunded_amount FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.ok('and the fund reports itself as not funded',
  NOT (SELECT is_funded FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.eq('an earmark moved no money, so the bank has not changed', 100000.00,
  (SELECT bank_balance FROM bms.v_financial_position));
SELECT t.eq('and it wrote no transaction', 0::bigint,
  (SELECT COUNT(*) FROM bms.transactions WHERE source_module = 'reserve'));
SELECT t.eq('progress towards the Tk 2,000,000 target is 20%', 20.0,
  (SELECT progress_pct FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.eq('with Tk 1,600,000 still to find', 1600000.00,
  (SELECT remaining_required FROM bms.v_fund_balances WHERE code='CAPEX'));

-- ---------------------------------------------------------------------
-- 3. MONEY ARRIVES, AND THE RESERVE IS FUNDED PROPERLY.
--
-- Three years of service-charge surplus is transferred into the reserve
-- account. This time real money moves.
-- ---------------------------------------------------------------------
-- Put enough in the bank to be worth moving.
SELECT t.runs('a year of accumulated surplus is banked', $$
  SELECT bms.create_transaction(
    t.pm(), 'INCOME',
    (SELECT id FROM bms.departments WHERE code='SERVICE_CHARGE'),
    NULL, 'Accumulated surplus brought forward', 900000.00,
    'BANK_TRANSFER', t.uid('acct_bank'), NULL, NULL, NULL, NULL, NULL, true)
$$);
SELECT t.eq('the bank now holds Tk 1,000,000', 1000000.00,
  (SELECT bank_balance FROM bms.v_financial_position));

-- The reserve fund is given its own account, so backing is unambiguous.
UPDATE bms.funds SET account_id = t.uid('acct_resv') WHERE code = 'RESERVE';

SELECT t.runs('Tk 300,000 is moved into the reserve account', $$
  SELECT bms.record_fund_movement(t.uid('fund_reserve'), t.pm() + 2, 'CONTRIBUTION',
                                  300000.00, true, t.uid('acct_bank'), t.uid('acct_resv'),
                                  'Quarterly reserve contribution')
$$);

SELECT t.eq('the reserve is earmarked at Tk 300,000', 300000.00,
  (SELECT current_balance FROM bms.v_fund_balances WHERE code='RESERVE'));
SELECT t.eq('and this time the money is really there', 300000.00,
  (SELECT funded_amount FROM bms.v_fund_balances WHERE code='RESERVE'));
SELECT t.ok('so the fund reports itself funded',
  (SELECT is_funded FROM bms.v_fund_balances WHERE code='RESERVE'));
SELECT t.eq('nothing is unfunded', 0.00,
  (SELECT unfunded_amount FROM bms.v_fund_balances WHERE code='RESERVE'));

-- A transfer is not an expense. This is the mistake that makes a
-- building's accounts look like it spent its own savings.
SELECT t.eq('moving money into the reserve is not an expense', 0.00,
  (SELECT COALESCE(SUM(amount),0) FROM bms.v_real_transactions
    WHERE direction = 'EXPENSE' AND source_module = 'reserve'));
SELECT t.eq('nor is it income', 0.00,
  (SELECT COALESCE(SUM(amount),0) FROM bms.v_real_transactions
    WHERE direction = 'INCOME' AND source_module = 'reserve'));
SELECT t.eq('the main account is down Tk 300,000', 700000.00,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));
SELECT t.eq('the reserve account is up Tk 300,000', 300000.00,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='RESV1'));
SELECT t.eq('and the building holds exactly as much as before', 1000000.00,
  (SELECT bank_balance FROM bms.v_financial_position));

-- ---------------------------------------------------------------------
-- 4. YOU CANNOT SPEND WHAT THE FUND DOES NOT HOLD.
-- ---------------------------------------------------------------------
SELECT t.throws('taking Tk 500,000 out of a Tk 300,000 reserve is refused', $$
  SELECT bms.record_fund_movement(t.uid('fund_reserve'), t.pm() + 3, 'WITHDRAWAL',
                                  500000.00, true, t.uid('acct_resv'), t.uid('acct_bank'))
$$);
SELECT t.throws('a cash-backed move with only one account named is refused', $$
  SELECT bms.record_fund_movement(t.uid('fund_reserve'), t.pm() + 3, 'CONTRIBUTION',
                                  1000.00, true, t.uid('acct_bank'), NULL)
$$);
SELECT t.throws('a transfer between an account and itself is refused', $$
  SELECT bms.record_fund_movement(t.uid('fund_reserve'), t.pm() + 3, 'CONTRIBUTION',
                                  1000.00, true, t.uid('acct_bank'), t.uid('acct_bank'))
$$);
SELECT t.throws('a movement of zero is refused', $$
  SELECT bms.record_fund_movement(t.uid('fund_reserve'), t.pm() + 3, 'CONTRIBUTION', 0)
$$);
SELECT t.eq('and after four refusals the reserve is untouched', 300000.00,
  (SELECT current_balance FROM bms.v_fund_balances WHERE code='RESERVE'));

-- ---------------------------------------------------------------------
-- 5. A FIXED DEPOSIT.
--
-- Tk 600,000 for 12 months at 9%. Opening it must not look like spending
-- Tk 600,000, and the money must remain visible.
-- ---------------------------------------------------------------------
SELECT t.runs('Tk 600,000 is locked into a 12-month deposit', $$
  SELECT bms.open_fixed_deposit('FDR-2026-001','Dutch-Bangla Bank', 600000.00,
                                t.pm() + 5, t.uid('acct_bank'), 12, 9.000, NULL,
                                t.uid('fund_capex'), 'Lift replacement reserve','Uttara')
$$);
SELECT t.remember('fd1', (SELECT id::text FROM bms.fixed_deposits WHERE fd_no='FDR-2026-001'));

SELECT t.eq('the deposit is active', 'ACTIVE',
  (SELECT status FROM bms.v_fixed_deposits WHERE fd_no='FDR-2026-001'));
SELECT t.eq('maturity is twelve months out', (t.pm() + 5 + INTERVAL '12 months')::date,
  (SELECT maturity_date FROM bms.v_fixed_deposits WHERE fd_no='FDR-2026-001'));
-- 600,000 x 9% x 1 year = 54,000 simple interest.
SELECT t.eq('the certificate is expected to be worth Tk 654,000', 654000.00,
  (SELECT expected_maturity_amount FROM bms.v_fixed_deposits WHERE fd_no='FDR-2026-001'));
SELECT t.eq('so Tk 54,000 of interest is expected', 54000.00,
  (SELECT expected_interest FROM bms.v_fixed_deposits WHERE fd_no='FDR-2026-001'));

SELECT t.eq('the main account paid for it', 100000.00,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));
SELECT t.eq('the money is now shown as a fixed deposit', 600000.00,
  (SELECT fixed_deposits FROM bms.v_financial_position));
SELECT t.eq('and the building still holds Tk 1,000,000 in total', 1000000.00,
  (SELECT total_held FROM bms.v_financial_position));
SELECT t.eq('opening a deposit is not an expense', 0.00,
  (SELECT COALESCE(SUM(amount),0) FROM bms.v_real_transactions
    WHERE direction='EXPENSE' AND source_module='fixed_deposit'));

-- The capital fund's Tk 400,000 promise is now backed by a Tk 600,000
-- deposit, so it stops being hollow.
SELECT t.eq('the capital fund is now backed by the deposit', 600000.00,
  (SELECT funded_amount FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.ok('so it is funded at last',
  (SELECT is_funded FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.eq('the earmark itself did not change', 400000.00,
  (SELECT current_balance FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.eq('and no fund movement was invented to make that happen', 1::bigint,
  (SELECT COUNT(*) FROM bms.fund_movements WHERE fund_id = t.uid('fund_capex')));

-- ---------------------------------------------------------------------
-- 6. INTEREST IS INCOME.
-- ---------------------------------------------------------------------
SELECT t.runs('the bank credits Tk 13,500 of quarterly interest', $$
  SELECT bms.record_fd_interest(t.uid('fd1'), t.pm() + 90, 13500.00)
$$);

SELECT t.eq('interest is recorded as income, not as a mysterious balance', 13500.00,
  (SELECT COALESCE(SUM(amount),0) FROM bms.v_real_transactions
    WHERE direction='INCOME' AND source_module='fixed_deposit'));
SELECT t.eq('it landed in the Reserve & Funds department', 'Reserve & Funds',
  (SELECT d.name FROM bms.transactions tx JOIN bms.departments d ON d.id = tx.department_id
    WHERE tx.source_module='fixed_deposit' AND tx.direction='INCOME'));
SELECT t.eq('the deposit account grew by the interest', 613500.00,
  (SELECT fixed_deposits FROM bms.v_financial_position));
SELECT t.eq('and the deposit shows the interest received so far', 13500.00,
  (SELECT interest_received FROM bms.v_fixed_deposits WHERE fd_no='FDR-2026-001'));

-- ---------------------------------------------------------------------
-- 7. THE LIFT MOTOR DIES AND THE DEPOSIT IS BROKEN EARLY.
--
-- The bank pays Tk 618,000 — principal plus reduced interest. The
-- Tk 18,000 above principal is income; the Tk 600,000 is not.
-- ---------------------------------------------------------------------
-- Breaking a deposit needs approval authority, not merely entry rights.
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('a caretaker cannot break a fixed deposit', $$
  SELECT bms.mature_fixed_deposit(t.uid('fd1'), t.pm() + 100, 618000.00, t.uid('acct_bank'), true)
$$);
SELECT set_config('request.jwt.claim.sub', t.recall('manager'), false);
SELECT t.throws('nor can a manager, who has no reserve authority', $$
  SELECT bms.mature_fixed_deposit(t.uid('fd1'), t.pm() + 100, 618000.00, t.uid('acct_bank'), true)
$$);

SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('the administrator breaks the deposit early', $$
  SELECT bms.mature_fixed_deposit(t.uid('fd1'), t.pm() + 100, 618000.00,
                                  t.uid('acct_bank'), true)
$$);

SELECT t.eq('the deposit is marked encashed', 'ENCASHED',
  (SELECT status FROM bms.fixed_deposits WHERE fd_no='FDR-2026-001'));
SELECT t.eq('the bank has the money back', 718000.00,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));
SELECT t.eq('nothing is left sitting in a deposit', 0.00,
  (SELECT fixed_deposits FROM bms.v_financial_position));
-- 13,500 quarterly + 4,500 on encashment = 18,000 total interest income.
SELECT t.eq('only the interest above principal became income', 18000.00,
  (SELECT COALESCE(SUM(amount),0) FROM bms.v_real_transactions
    WHERE direction='INCOME' AND source_module='fixed_deposit'));
SELECT t.eq('the building is richer by exactly the interest earned', 1018000.00,
  (SELECT total_held FROM bms.v_financial_position));
SELECT t.eq('the closed deposit account is retired', false,
  (SELECT is_active FROM bms.accounts a
     JOIN bms.fixed_deposits fd ON fd.account_id = a.id WHERE fd.fd_no='FDR-2026-001'));
SELECT t.throws('and it cannot be matured twice', $$
  SELECT bms.mature_fixed_deposit(t.uid('fd1'), t.pm() + 101, 618000.00, t.uid('acct_bank'))
$$);

-- With the deposit gone, the capital fund's promise is hollow again, and
-- the system says so rather than quietly keeping the old figure.
SELECT t.eq('the capital fund is unbacked once more', 0.00,
  (SELECT funded_amount FROM bms.v_fund_balances WHERE code='CAPEX'));
SELECT t.eq('and its Tk 400,000 is unfunded again', 400000.00,
  (SELECT unfunded_amount FROM bms.v_fund_balances WHERE code='CAPEX'));

-- ---------------------------------------------------------------------
-- 8. BUDGET VERSUS ACTUAL.
-- ---------------------------------------------------------------------
SELECT t.runs('the generator department is budgeted Tk 300,000 for the year', $$
  SELECT bms.set_budget(EXTRACT(YEAR FROM t.pm())::int, t.uid('dept_gen'), 300000.00)
$$);

SELECT t.eq('the annual budget is split across twelve months', 12::bigint,
  (SELECT COUNT(*) FROM bms.budget_lines bl JOIN bms.budgets b ON b.id = bl.budget_id
    WHERE b.department_id = t.uid('dept_gen')));
SELECT t.eq('and the twelve months add back to exactly Tk 300,000', 300000.00,
  (SELECT SUM(bl.amount) FROM bms.budget_lines bl JOIN bms.budgets b ON b.id = bl.budget_id
    WHERE b.department_id = t.uid('dept_gen')));
SELECT t.eq('a month carries Tk 25,000', 25000.00,
  (SELECT bl.amount FROM bms.budget_lines bl JOIN bms.budgets b ON b.id = bl.budget_id
    WHERE b.department_id = t.uid('dept_gen') AND bl.period_month = 1));

-- An uneven annual figure must still add back exactly.
SELECT t.runs('an amount that does not divide by twelve is budgeted', $$
  SELECT bms.set_budget(EXTRACT(YEAR FROM t.pm())::int,
                        (SELECT id FROM bms.departments WHERE code='LIFT'), 100000.00)
$$);
SELECT t.eq('and it still adds back to the taka', 100000.00,
  (SELECT SUM(bl.amount) FROM bms.budget_lines bl JOIN bms.budgets b ON b.id = bl.budget_id
    WHERE b.department_id = (SELECT id FROM bms.departments WHERE code='LIFT')));

-- Spend most of the generator budget in one go.
SELECT t.runs('Tk 280,000 of diesel is bought and posted', $$
  SELECT bms.create_transaction(
    t.pm(), 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
    'Annual diesel purchase', 280000.00, 'BANK_TRANSFER',
    t.uid('acct_bank'), NULL, NULL, NULL, NULL, NULL, true)
$$);

SELECT t.eq('the budget shows Tk 280,000 spent', 280000.00,
  (SELECT actual FROM bms.v_budget_vs_actual
    WHERE department_code='GENERATOR' AND fiscal_year = EXTRACT(YEAR FROM t.pm())::int));
SELECT t.eq('leaving Tk 20,000 of the year', 20000.00,
  (SELECT remaining FROM bms.v_budget_vs_actual
    WHERE department_code='GENERATOR' AND fiscal_year = EXTRACT(YEAR FROM t.pm())::int));
SELECT t.ok('and the department is flagged as over budget to date',
  (SELECT over_budget_to_date FROM bms.v_budget_vs_actual
    WHERE department_code='GENERATOR' AND fiscal_year = EXTRACT(YEAR FROM t.pm())::int));
SELECT t.ok('which reaches the dashboard as an alert',
  EXISTS (SELECT 1 FROM bms.v_dashboard_alerts WHERE alert_type='OVER_BUDGET'));

-- Re-setting a budget must replace it, not stack a second one on top.
SELECT t.runs('the committee raises the generator budget to Tk 360,000', $$
  SELECT bms.set_budget(EXTRACT(YEAR FROM t.pm())::int, t.uid('dept_gen'), 360000.00)
$$);
SELECT t.eq('there is still exactly one generator budget for the year', 1::bigint,
  (SELECT COUNT(*) FROM bms.budgets WHERE department_id = t.uid('dept_gen')
     AND fiscal_year = EXTRACT(YEAR FROM t.pm())::int));
SELECT t.eq('and still exactly twelve monthly lines', 12::bigint,
  (SELECT COUNT(*) FROM bms.budget_lines bl JOIN bms.budgets b ON b.id = bl.budget_id
    WHERE b.department_id = t.uid('dept_gen')));
SELECT t.eq('with Tk 80,000 now left for the year', 80000.00,
  (SELECT remaining FROM bms.v_budget_vs_actual
    WHERE department_code='GENERATOR' AND fiscal_year = EXTRACT(YEAR FROM t.pm())::int));

-- ---------------------------------------------------------------------
-- 9. BANK RECONCILIATION.
--
-- The bank statement is the truth. The first attempt disagrees with the
-- books, and the system must say so instead of quietly agreeing.
-- ---------------------------------------------------------------------
SELECT t.runs('the accountant uploads the month-end statement', $$
  SELECT bms.create_bank_statement(t.uid('acct_bank'), t.pm() + 120, 999999.00,
                                   t.pm(), t.pm() + 120, 100000.00,
                                   'Downloaded from internet banking')
$$);
SELECT t.remember('stmt1', (SELECT id::text FROM bms.bank_statements
                             WHERE account_id = t.uid('acct_bank')));

SELECT t.runs('the first reconciliation is attempted', $$
  SELECT bms.reconcile_account(t.uid('stmt1'), 'First pass')
$$);
SELECT t.eq('the books and the bank do not agree', 'DISPUTED',
  (SELECT status FROM bms.reconciliations WHERE statement_id = t.uid('stmt1')));
-- The books say Tk 438,000: Tk 718,000 after the deposit came back, less
-- the Tk 280,000 of diesel bought above.
SELECT t.eq('the books say Tk 438,000', 438000.00,
  (SELECT current_balance FROM bms.v_account_balances WHERE code='BANK1'));
SELECT t.eq('and the difference is stated exactly', (999999.00 - 438000.00),
  (SELECT difference FROM bms.reconciliations WHERE statement_id = t.uid('stmt1')));
SELECT t.eq('a disputed reconciliation does not close the statement', 'OPEN',
  (SELECT status FROM bms.bank_statements WHERE id = t.uid('stmt1')));
SELECT t.ok('and the dashboard still says the bank is unreconciled',
  EXISTS (SELECT 1 FROM bms.v_dashboard_alerts WHERE alert_type='BANK_UNRECONCILED'));

-- The real closing balance, with the statement's own lines.
SELECT t.runs('a corrected statement replaces the wrong one', $$
  SELECT bms.create_bank_statement(t.uid('acct_bank'), t.pm() + 120, 438000.00,
                                   t.pm(), t.pm() + 120, 100000.00, 'Corrected download')
$$);
SELECT t.eq('re-uploading did not create a second statement', 1::bigint,
  (SELECT COUNT(*) FROM bms.bank_statements WHERE account_id = t.uid('acct_bank')));

SELECT t.eq('six statement lines are imported', 6,
  bms.import_statement_lines(t.uid('stmt1'), jsonb_build_array(
    jsonb_build_object('line_date', (t.pm())::text,     'description','Surplus b/f',      'credit', 900000.00),
    jsonb_build_object('line_date', (t.pm())::text,     'description','Diesel — annual',  'debit',  280000.00),
    jsonb_build_object('line_date', (t.pm()+2)::text,   'description','TFR to reserve',   'debit',  300000.00),
    jsonb_build_object('line_date', (t.pm()+5)::text,   'description','FD FDR-2026-001',  'debit',  600000.00),
    jsonb_build_object('line_date', (t.pm()+100)::text, 'description','FD encashed',      'credit', 618000.00),
    jsonb_build_object('line_date', (t.pm()+120)::text, 'description','Cheque not shown', 'debit',  1200.00)
  )));
SELECT t.eq('all six start unmatched', 6::bigint,
  (SELECT COUNT(*) FROM bms.bank_statement_lines
    WHERE statement_id = t.uid('stmt1') AND match_status='UNMATCHED'));

SELECT t.eq('five of them match a posted transaction automatically', 5,
  bms.auto_match_statement(t.uid('stmt1'), 3));
SELECT t.eq('the line the books have never seen is left for a person', 1::bigint,
  (SELECT COUNT(*) FROM bms.bank_statement_lines
    WHERE statement_id = t.uid('stmt1') AND match_status='UNMATCHED'));
SELECT t.eq('and it is the unexplained cheque', 'Cheque not shown',
  (SELECT description FROM bms.bank_statement_lines
    WHERE statement_id = t.uid('stmt1') AND match_status='UNMATCHED'));
SELECT t.eq('running the matcher again finds nothing new', 0,
  bms.auto_match_statement(t.uid('stmt1'), 3));

-- A person decides the unexplained line is a bank fee they had not
-- recorded, and sets it aside rather than forcing a false match.
SELECT t.runs('the unexplained line is set aside for investigation', $$
  SELECT bms.match_statement_line(
    (SELECT id FROM bms.bank_statement_lines
      WHERE statement_id = t.uid('stmt1') AND match_status='UNMATCHED'),
    NULL, true)
$$);
SELECT t.eq('no line is left unmatched', 0::bigint,
  (SELECT COUNT(*) FROM bms.bank_statement_lines
    WHERE statement_id = t.uid('stmt1') AND match_status='UNMATCHED'));

-- One transaction may not answer for two bank lines.
SELECT t.throws('a transaction already matched cannot be matched again', $$
  SELECT bms.match_statement_line(
    (SELECT id FROM bms.bank_statement_lines
      WHERE statement_id = t.uid('stmt1') AND match_status='IGNORED'),
    (SELECT matched_txn_id FROM bms.bank_statement_lines
      WHERE statement_id = t.uid('stmt1') AND match_status='AUTO_MATCHED' LIMIT 1))
$$);

SELECT t.runs('the corrected statement is reconciled', $$
  SELECT bms.reconcile_account(t.uid('stmt1'), 'Agreed')
$$);
SELECT t.eq('the books and the bank now agree', 'AGREED',
  (SELECT status FROM bms.reconciliations WHERE statement_id = t.uid('stmt1')
    ORDER BY reconciled_at DESC LIMIT 1));
SELECT t.eq('to the taka', 0.00,
  (SELECT difference FROM bms.reconciliations WHERE statement_id = t.uid('stmt1')
    ORDER BY reconciled_at DESC LIMIT 1));
SELECT t.eq('and the statement closes', 'RECONCILED',
  (SELECT status FROM bms.bank_statements WHERE id = t.uid('stmt1')));
SELECT t.ok('so the dashboard stops nagging about it',
  NOT EXISTS (SELECT 1 FROM bms.v_dashboard_alerts WHERE alert_type='BANK_UNRECONCILED'));
SELECT t.throws('and a reconciled statement cannot be quietly replaced', $$
  SELECT bms.create_bank_statement(t.uid('acct_bank'), t.pm() + 120, 5.00)
$$);
SELECT t.eq('both attempts are kept, so the disagreement is on record', 2::bigint,
  (SELECT COUNT(*) FROM bms.reconciliations WHERE statement_id = t.uid('stmt1')));

-- ---------------------------------------------------------------------
-- 10. NOTIFICATIONS REACH THE RIGHT PEOPLE AND NOBODY ELSE.
-- ---------------------------------------------------------------------
-- Something for a finance person to approve.
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.runs('the caretaker submits a Tk 9,000 repair bill', $$
  SELECT bms.create_transaction(
    t.pm() + 121, 'EXPENSE',
    (SELECT id FROM bms.departments WHERE code='MAINTENANCE'), NULL,
    'Roof water tank repair', 9000.00, 'CASH',
    NULL, NULL, NULL, NULL, NULL, NULL, true)
$$);

SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.ok('notifications are generated', bms.generate_notifications() > 0);

-- The finance manager may approve, so they are told.
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.ok('the finance manager is told an approval is waiting',
  EXISTS (SELECT 1 FROM bms.v_my_notifications WHERE alert_type='PENDING_APPROVAL'));
SELECT t.ok('and sees the same thing on the dashboard',
  EXISTS (SELECT 1 FROM bms.v_dashboard_alerts WHERE alert_type='PENDING_APPROVAL'));

-- The caretaker may not, so they are not.
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.ok('the caretaker is not asked to approve anything',
  NOT EXISTS (SELECT 1 FROM bms.v_my_notifications WHERE alert_type='PENDING_APPROVAL'));
SELECT t.ok('and the approval alert is absent from their dashboard too',
  NOT EXISTS (SELECT 1 FROM bms.v_dashboard_alerts WHERE alert_type='PENDING_APPROVAL'));
SELECT t.ok('nor are they told about the bank',
  NOT EXISTS (SELECT 1 FROM bms.v_my_notifications WHERE alert_type='BANK_UNRECONCILED'));
-- But they do see their own submission come back to them.
SELECT t.ok('the caretaker can still see the entry they made themselves',
  EXISTS (SELECT 1 FROM bms.my_submissions()));

-- One person's inbox is not another's.
SELECT t.eq('a caretaker reads only their own notifications', 0::bigint,
  (SELECT COUNT(*) FROM bms.notifications WHERE user_id <> t.uid('caretaker')));

-- Running the generator twice on the same day must not double the inbox.
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.remember('notif_count', (SELECT COUNT(*)::text FROM bms.v_my_notifications));
SET ROLE postgres;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.eq('a second run on the same day tells nobody anything twice', 0,
  bms.generate_notifications());
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.eq('so the inbox is exactly as it was', t.recall('notif_count')::bigint,
  (SELECT COUNT(*) FROM bms.v_my_notifications));

SELECT t.ok('marking them read clears the unread count',
  bms.mark_notifications_read() > 0);
SELECT t.eq('and nothing is left unread', 0::bigint,
  (SELECT COUNT(*) FROM bms.v_my_notifications WHERE NOT is_read));

-- ---------------------------------------------------------------------
-- 11. PERMISSIONS ON THE NEW MODULES.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.eq('a caretaker sees no funds at all', 0::bigint,
  (SELECT COUNT(*) FROM bms.funds));
SELECT t.eq('nor any fixed deposits', 0::bigint,
  (SELECT COUNT(*) FROM bms.fixed_deposits));
SELECT t.eq('nor any bank statements', 0::bigint,
  (SELECT COUNT(*) FROM bms.bank_statements));
SELECT t.throws('and cannot set money aside', $$
  SELECT bms.record_fund_movement(t.uid('fund_reserve'), CURRENT_DATE, 'CONTRIBUTION', 100)
$$);
SELECT t.throws('nor set a budget', $$
  SELECT bms.set_budget(EXTRACT(YEAR FROM CURRENT_DATE)::int, t.uid('dept_gen'), 1000)
$$);
SELECT t.throws('nor upload a bank statement', $$
  SELECT bms.create_bank_statement(t.uid('acct_bank'), CURRENT_DATE, 1.00)
$$);

SELECT set_config('request.jwt.claim.sub', t.recall('committee'), false);
SELECT t.eq('a committee member can see the reserve', 2::bigint,
  (SELECT COUNT(*) FROM bms.funds));
SELECT t.throws('but cannot move money in or out of it', $$
  SELECT bms.record_fund_movement(t.uid('fund_reserve'), CURRENT_DATE, 'WITHDRAWAL', 100)
$$);

SELECT set_config('request.jwt.claim.sub', t.recall('auditor'), false);
SELECT t.ok('an auditor can read the reserve and the deposits',
  (SELECT COUNT(*) FROM bms.v_fund_balances) = 2
  AND (SELECT COUNT(*) FROM bms.v_fixed_deposits) = 1);
SELECT t.throws('but changes nothing', $$
  SELECT bms.record_fund_movement(t.uid('fund_reserve'), CURRENT_DATE, 'CONTRIBUTION', 100)
$$);

-- ---------------------------------------------------------------------
-- 12. IT IS ALL IN THE AUDIT LOG.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('auditor'), false);
SELECT t.ok('the fund movements were logged',
  EXISTS (SELECT 1 FROM bms.v_audit_log WHERE entity_table='fund_movements'));
SELECT t.ok('the fixed deposit was logged',
  EXISTS (SELECT 1 FROM bms.v_audit_log WHERE entity_table='fixed_deposits'));
SELECT t.ok('and it names the deposit',
  EXISTS (SELECT 1 FROM bms.v_audit_log
           WHERE entity_table='fixed_deposits' AND entity_label='FDR-2026-001'));
SELECT t.ok('the reconciliation was logged',
  EXISTS (SELECT 1 FROM bms.v_audit_log WHERE entity_table='reconciliations'));
SELECT t.ok('and every one of them names who did it',
  NOT EXISTS (SELECT 1 FROM bms.v_audit_log
               WHERE entity_table IN ('fund_movements','fixed_deposits','reconciliations')
                 AND actor_name_snapshot IS NULL));

RESET ROLE;
