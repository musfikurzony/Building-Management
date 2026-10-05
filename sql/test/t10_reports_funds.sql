-- =====================================================================
-- t10 — the monthly report, and a fund that pays for things.
--
-- The LPG emergency fund as the building actually runs it: Tk 20,000 kept
-- in its own cash box, a cylinder bought out of it before the month's
-- meter collection arrives, and the fund refilled from that collection.
-- Then the month is reported, and every figure on the report is checked
-- against the ledger it was made from.
-- =====================================================================
SET t.suite = 't10 reports & funds';
SET search_path = bms, public;

CREATE OR REPLACE FUNCTION t.pm() RETURNS date
LANGUAGE sql STABLE AS $$ SELECT date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date $$;
CREATE OR REPLACE FUNCTION t.pm_end() RETURNS date
LANGUAGE sql STABLE AS $$ SELECT (date_trunc('month', CURRENT_DATE) - INTERVAL '1 day')::date $$;

-- ---------------------------------------------------------------------
-- 1. THE LPG DEPARTMENT IS THERE, AND IS ORDINARY DATA.
-- ---------------------------------------------------------------------
SELECT t.eq('an LPG department is seeded', 1::bigint,
  (SELECT COUNT(*) FROM bms.departments WHERE code = 'LPG'));
SELECT t.eq('with an expense category and an income category', 2::bigint,
  (SELECT COUNT(DISTINCT c.txn_type) FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id WHERE d.code = 'LPG'));

\ir ../086_reports_funds.sql
SELECT t.eq('re-running the file does not seed it twice', 2::bigint,
  (SELECT COUNT(*) FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id WHERE d.code = 'LPG'));
UPDATE bms.departments SET name = 'Gas (emergency)' WHERE code = 'LPG';
\ir ../086_reports_funds.sql
SELECT t.eq('and a renamed department keeps its new name', 'Gas (emergency)',
  (SELECT name FROM bms.departments WHERE code = 'LPG'));
UPDATE bms.departments SET name = 'LPG fund' WHERE code = 'LPG';

-- A building that ran the first version has the old wording; re-running
-- brings it up to date, without duplicates.
UPDATE bms.categories SET name = 'Emergency fund repaid from LPG collection'
 WHERE txn_type = 'INCOME' AND department_id = (SELECT id FROM bms.departments WHERE code = 'LPG');
UPDATE bms.categories SET name = 'Cylinder bought from the emergency fund'
 WHERE txn_type = 'EXPENSE' AND department_id = (SELECT id FROM bms.departments WHERE code = 'LPG');
UPDATE bms.departments SET name = 'LPG (emergency fund)' WHERE code = 'LPG';
\ir ../086_reports_funds.sql
SELECT t.eq('the old department name becomes "LPG fund"', 'LPG fund', (SELECT name FROM bms.departments WHERE code = 'LPG'));
SELECT t.eq('the income category says what it is', 'LPG fund refilled from meter bill collection',
  (SELECT c.name FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id WHERE d.code = 'LPG' AND c.txn_type = 'INCOME'));
SELECT t.eq('and so does the expense category', 'LPG cylinder bought from LPG fund',
  (SELECT c.name FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id WHERE d.code = 'LPG' AND c.txn_type = 'EXPENSE'));
UPDATE bms.categories SET name = 'Gas cylinder (our own name)'
 WHERE txn_type = 'EXPENSE' AND department_id = (SELECT id FROM bms.departments WHERE code = 'LPG');
\ir ../086_reports_funds.sql
SELECT t.eq('a category the building renamed itself is left alone', 'Gas cylinder (our own name)',
  (SELECT c.name FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id WHERE d.code = 'LPG' AND c.txn_type = 'EXPENSE'));
SELECT t.eq('and no second expense category appears beside it', 2::bigint,
  (SELECT COUNT(*) FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id WHERE d.code = 'LPG'));

SELECT t.remember('cat_lpg_exp', (SELECT c.id::text FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id
                                   WHERE d.code = 'LPG' AND c.txn_type = 'EXPENSE'));
SELECT t.remember('cat_lpg_inc', (SELECT c.id::text FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id
                                   WHERE d.code = 'LPG' AND c.txn_type = 'INCOME'));

-- ---------------------------------------------------------------------
-- 2. THE FUND, WITH THE MONEY IT ALREADY HAS.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

INSERT INTO bms.accounts (code, name, kind, opening_balance, opening_date)
VALUES ('LPGBOX', 'LPG emergency cash', 'CASH', 20000.00, t.pm() - 10);
SELECT t.remember('acct_lpg', (SELECT id::text FROM bms.accounts WHERE code = 'LPGBOX'));

INSERT INTO bms.funds (code, name, fund_type, purpose, opening_balance, opening_date, account_id, target_amount)
VALUES ('LPG', 'LPG emergency fund', 'PROJECT', 'Buy a cylinder before the meter collection',
        20000.00, t.pm() - 10, t.uid('acct_lpg'), 20000.00);
SELECT t.remember('fund_lpg', (SELECT id::text FROM bms.funds WHERE code = 'LPG'));

SELECT t.eq('the fund starts with its opening balance', 20000.00,
  (SELECT current_balance FROM bms.v_fund_balances WHERE code = 'LPG'));
SELECT t.ok('and it is fully backed by its own cash box',
  (SELECT is_funded FROM bms.v_fund_balances WHERE code = 'LPG'));

-- ---------------------------------------------------------------------
-- 3. A CYLINDER IS BOUGHT STRAIGHT OUT OF THE FUND.
-- ---------------------------------------------------------------------
SELECT t.runs('a cylinder is paid for out of the LPG fund', $$
  SELECT bms.record_fund_movement(t.uid('fund_lpg'), t.pm() + 4, 'WITHDRAWAL', 6000.00, true,
                                  t.uid('acct_lpg'), NULL, 'Cylinder — emergency', NULL,
                                  t.uid('cat_lpg_exp'), 'CASH', NULL)
$$);
SELECT t.eq('the earmark falls by Tk 6,000', 14000.00,
  (SELECT current_balance FROM bms.v_fund_balances WHERE code = 'LPG'));
SELECT t.eq('and so does the cash box', 14000.00,
  (SELECT current_balance FROM bms.v_account_balances WHERE code = 'LPGBOX'));
SELECT t.ok('so the fund is still exactly backed',
  (SELECT is_funded AND unfunded_amount = 0 FROM bms.v_fund_balances WHERE code = 'LPG'));
SELECT t.eq('it is a real, posted expense', 'EXPENSE/POSTED',
  (SELECT t2.direction || '/' || t2.status FROM bms.fund_movements fm JOIN bms.transactions t2 ON t2.id = fm.txn_id
    WHERE fm.fund_id = t.uid('fund_lpg') AND fm.direction = 'WITHDRAWAL'));
SELECT t.eq('filed under the LPG department', 'LPG',
  (SELECT d.code FROM bms.fund_movements fm JOIN bms.transactions t2 ON t2.id = fm.txn_id
     JOIN bms.departments d ON d.id = t2.department_id
    WHERE fm.fund_id = t.uid('fund_lpg') AND fm.direction = 'WITHDRAWAL'));
SELECT t.eq('and the movement and the expense are tied together', 'reserve',
  (SELECT t2.source_module FROM bms.fund_movements fm JOIN bms.transactions t2 ON t2.id = fm.txn_id
    WHERE fm.fund_id = t.uid('fund_lpg') AND fm.direction = 'WITHDRAWAL'));

-- ---------------------------------------------------------------------
-- 4. REFILLED FROM THE LPG COLLECTION.
-- ---------------------------------------------------------------------
SELECT t.runs('the fund is repaid from the month''s LPG collection', $$
  SELECT bms.record_fund_movement(t.uid('fund_lpg'), t.pm() + 20, 'CONTRIBUTION', 6000.00, true,
                                  NULL, t.uid('acct_lpg'), 'Repaid from October collection', NULL,
                                  t.uid('cat_lpg_inc'), 'CASH', NULL)
$$);
SELECT t.eq('the fund is whole again', 20000.00,
  (SELECT current_balance FROM bms.v_fund_balances WHERE code = 'LPG'));
SELECT t.eq('and so is the cash box', 20000.00,
  (SELECT current_balance FROM bms.v_account_balances WHERE code = 'LPGBOX'));

-- ---------------------------------------------------------------------
-- 5. WHAT IT REFUSES.
-- ---------------------------------------------------------------------
SELECT t.throws('income cannot be booked to an expense category', $$
  SELECT bms.record_fund_movement(t.uid('fund_lpg'), t.pm() + 21, 'CONTRIBUTION', 100.00, true,
                                  NULL, t.uid('acct_lpg'), NULL, NULL, t.uid('cat_lpg_exp'), 'CASH', NULL)
$$, 'is for expense');
SELECT t.throws('money spent needs the account it was paid from', $$
  SELECT bms.record_fund_movement(t.uid('fund_lpg'), t.pm() + 21, 'WITHDRAWAL', 100.00, true,
                                  NULL, NULL, NULL, NULL, t.uid('cat_lpg_exp'), 'CASH', NULL)
$$, 'paid from');
SELECT t.throws('a fund cannot spend more than it holds', $$
  SELECT bms.record_fund_movement(t.uid('fund_lpg'), t.pm() + 21, 'WITHDRAWAL', 20000.01, true,
                                  t.uid('acct_lpg'), NULL, NULL, NULL, t.uid('cat_lpg_exp'), 'CASH', NULL)
$$, 'only holds');
SELECT t.throws('interest cannot be booked as an expense', $$
  SELECT bms.record_fund_movement(t.uid('fund_lpg'), t.pm() + 21, 'INTEREST', 10.00, true,
                                  NULL, t.uid('acct_lpg'), NULL, NULL, t.uid('cat_lpg_inc'), 'CASH', NULL)
$$, 'Only money put in or taken out');

SELECT t.runs('the old way of calling it still works (a transfer)', $$
  SELECT bms.record_fund_movement(t.uid('fund_lpg'), t.pm() + 22, 'CONTRIBUTION', 500.00, true,
                                  t.uid('acct_bank'), t.uid('acct_lpg'), 'Top-up from main account')
$$);
SELECT t.eq('a transfer is not income', 0::bigint,
  (SELECT COUNT(*) FROM bms.transactions WHERE source_module = 'reserve' AND description LIKE '%Top-up%' AND direction <> 'TRANSFER'));

SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('a caretaker cannot spend from a fund', $$
  SELECT bms.record_fund_movement(t.uid('fund_lpg'), t.pm() + 21, 'WITHDRAWAL', 100.00, true,
                                  t.uid('acct_lpg'), NULL, NULL, NULL, t.uid('cat_lpg_exp'), 'CASH', NULL)
$$);
SELECT t.throws('nor read the monthly report', $$ SELECT * FROM bms.report_income_expense(CURRENT_DATE, CURRENT_DATE) $$);
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

-- ---------------------------------------------------------------------
-- 6. SERVICE CHARGE FOR THE MONTH.
-- ---------------------------------------------------------------------
SELECT t.runs('last month is billed', $$
  SELECT bms.generate_monthly_charges(EXTRACT(year FROM t.pm())::int, EXTRACT(month FROM t.pm())::int) $$);
SELECT t.runs('A-101 pays in full', $$
  SELECT bms.record_payment((SELECT id FROM bms.flats WHERE flat_number='A-101'), 5000.00, t.pm() + 6,
                            'CASH', t.uid('acct_bank'), NULL, NULL, 'Rahim Uddin') $$);
SELECT t.runs('A-102 pays part', $$
  SELECT bms.record_payment((SELECT id FROM bms.flats WHERE flat_number='A-102'), 2000.00, t.pm() + 8,
                            'BKASH', t.uid('acct_bank'), 'TRX1', NULL, NULL) $$);

-- ---------------------------------------------------------------------
-- 7. THE REPORT FOR LAST MONTH.
-- ---------------------------------------------------------------------
SELECT t.eq('income by department shows the LPG repayment', 6000.00,
  (SELECT amount FROM bms.report_income_expense(t.pm(), t.pm_end())
    WHERE direction = 'INCOME' AND department_name = 'LPG fund'));
SELECT t.eq('expense by department shows the cylinder', 6000.00,
  (SELECT amount FROM bms.report_income_expense(t.pm(), t.pm_end())
    WHERE direction = 'EXPENSE' AND department_name = 'LPG fund'));
SELECT t.eq('service charge income is the two payments', 7000.00,
  (SELECT SUM(amount) FROM bms.report_income_expense(t.pm(), t.pm_end())
    WHERE direction = 'INCOME' AND department_name = 'Service Charge'));
SELECT t.eq('report income equals every income entry counted for the month',
  (SELECT SUM(amount) FROM bms.v_transactions WHERE counts_in_totals AND direction = 'INCOME'
      AND txn_date BETWEEN t.pm() AND t.pm_end()),
  (SELECT SUM(amount) FROM bms.report_income_expense(t.pm(), t.pm_end()) WHERE direction = 'INCOME'));
SELECT t.eq('report expense equals every expense entry counted for the month',
  (SELECT SUM(amount) FROM bms.v_transactions WHERE counts_in_totals AND direction = 'EXPENSE'
      AND txn_date BETWEEN t.pm() AND t.pm_end()),
  (SELECT SUM(amount) FROM bms.report_income_expense(t.pm(), t.pm_end()) WHERE direction = 'EXPENSE'));

SELECT t.eq('the cash box opens the month at Tk 20,000', 20000.00,
  (SELECT opening FROM bms.report_accounts(t.pm(), t.pm_end()) WHERE code = 'LPGBOX'));
SELECT t.eq('took in 6,500 (repayment + top-up)', 6500.00,
  (SELECT money_in FROM bms.report_accounts(t.pm(), t.pm_end()) WHERE code = 'LPGBOX'));
SELECT t.eq('paid out 6,000', 6000.00,
  (SELECT money_out FROM bms.report_accounts(t.pm(), t.pm_end()) WHERE code = 'LPGBOX'));
SELECT t.eq('and closes at 20,500', 20500.00,
  (SELECT closing FROM bms.report_accounts(t.pm(), t.pm_end()) WHERE code = 'LPGBOX'));
SELECT t.eq('the main bank: 100,000 + 7,000 received − 500 moved to the LPG box', 106500.00,
  (SELECT closing FROM bms.report_accounts(t.pm(), t.pm_end()) WHERE code = 'BANK1'));
SELECT t.eq('a report ending today closes at every account''s balance on the dashboard', 0::bigint,
  (SELECT COUNT(*) FROM bms.report_accounts(DATE '2026-01-01', CURRENT_DATE) r
     JOIN bms.v_account_balances b ON b.account_id = r.account_id
    WHERE r.closing <> b.current_balance));
SELECT t.eq('money in minus money out is the change in every account', 0::bigint,
  (SELECT COUNT(*) FROM bms.report_accounts(t.pm(), t.pm_end()) WHERE opening + money_in - money_out <> closing));

SELECT t.eq('the fund: opening 20,000', 20000.00,
  (SELECT opening FROM bms.report_funds(t.pm(), t.pm_end()) WHERE code = 'LPG'));
SELECT t.eq('added 6,500', 6500.00, (SELECT added FROM bms.report_funds(t.pm(), t.pm_end()) WHERE code = 'LPG'));
SELECT t.eq('used 6,000', 6000.00,  (SELECT used  FROM bms.report_funds(t.pm(), t.pm_end()) WHERE code = 'LPG'));
SELECT t.eq('closing 20,500', 20500.00, (SELECT closing FROM bms.report_funds(t.pm(), t.pm_end()) WHERE code = 'LPG'));
SELECT t.eq('a fund''s closing on a report ending today is its balance now', 0::bigint,
  (SELECT COUNT(*) FROM bms.report_funds(DATE '2026-01-01', CURRENT_DATE) r
     JOIN bms.v_fund_balances b ON b.fund_id = r.fund_id WHERE r.closing <> b.current_balance));

SELECT t.eq('billed for the month: 5,000 + 4,500 + the default rate',
  (SELECT 9500.00 + default_service_charge FROM bms.building_settings),
  (SELECT billed FROM bms.report_service_charge(t.pm(), t.pm_end())));
SELECT t.eq('paid of it: 7,000', 7000.00,
  (SELECT paid_against_billed FROM bms.report_service_charge(t.pm(), t.pm_end())));
SELECT t.eq('received in the month, in two receipts', '7000.00/2',
  (SELECT received_in_period || '/' || receipts_in_period FROM bms.report_service_charge(t.pm(), t.pm_end())));
SELECT t.eq('one flat paid, one part, one not', '1/1/1',
  (SELECT paid_full || '/' || paid_partial || '/' || unpaid FROM bms.report_service_charge(t.pm(), t.pm_end())));
SELECT t.eq('outstanding now matches the dues view',
  (SELECT SUM(outstanding) FROM bms.v_flat_dues),
  (SELECT outstanding_now FROM bms.report_service_charge(t.pm(), t.pm_end())));

-- The month before: nothing happened yet, but the fund's opening money
-- (dated ten days before last month) is already there.
SELECT t.eq('the month before shows no income', 0::bigint,
  (SELECT COUNT(*) FROM bms.report_income_expense((t.pm() - INTERVAL '1 month')::date, t.pm() - 1)));
SELECT t.eq('a fund that did not exist yet is not on the report', 0::bigint,
  (SELECT COUNT(*) FROM bms.report_funds(DATE '2020-01-01', DATE '2020-01-31') WHERE code = 'LPG' AND closing <> 0));

-- A fund with no account of its own, spending straight from the general account.
INSERT INTO bms.funds (code, name, fund_type, opening_balance, opening_date)
VALUES ('FEST', 'Festival fund', 'PROJECT', 5000.00, t.pm());
SELECT t.runs('a paper fund pays for something from the main account', $$
  SELECT bms.record_fund_movement((SELECT id FROM bms.funds WHERE code='FEST'), t.pm() + 3, 'WITHDRAWAL', 1200.00, true,
                                  t.uid('acct_bank'), NULL, 'Decorations', NULL,
                                  (SELECT c.id FROM bms.categories c JOIN bms.departments d ON d.id = c.department_id
                                    WHERE d.code = 'OTHER' AND c.txn_type IN ('EXPENSE','BOTH') LIMIT 1), 'CASH', NULL) $$);
SELECT t.eq('its earmark falls', 3800.00, (SELECT current_balance FROM bms.v_fund_balances WHERE code = 'FEST'));
SELECT t.eq('and it never shows less than nothing actually there', 0.00,
  (SELECT funded_amount FROM bms.v_fund_balances WHERE code = 'FEST'));

SELECT t.throws('an end date before the start is refused', $$
  SELECT * FROM bms.report_accounts(CURRENT_DATE, CURRENT_DATE - 1) $$, 'before the start');

RESET ROLE;
