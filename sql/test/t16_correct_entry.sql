-- =====================================================================
-- t16 — correcting a posted entry: reverse and record again, as one step.
--
-- Reported: an LPG cylinder was entered with the wrong date and amount.
-- Found on the way: reversing a fund-paid entry left the fund short.
-- =====================================================================
SET t.suite = 't16 correct entry';
SET search_path = bms, public;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.remember('cash', (SELECT id::text FROM bms.accounts WHERE code = 'CASH'));
INSERT INTO bms.funds (code, name, fund_type, opening_balance) VALUES ('LPG', 'LPG fund', 'PROJECT', 20000);
SELECT t.remember('lpg', (SELECT id::text FROM bms.funds WHERE code = 'LPG'));
SELECT t.remember('mv', (SELECT (bms.record_fund_movement(t.uid('lpg'), CURRENT_DATE - 8, 'WITHDRAWAL', 7000, true,
  t.uid('cash'), NULL, '1x45 cylinder', NULL,
  (SELECT id FROM bms.categories WHERE name = 'LPG cylinder bought from LPG fund'), 'CASH', NULL)).txn_id::text));
SELECT t.eq('the fund is down by the cylinder', 13000.00, (SELECT current_balance FROM bms.v_fund_balances WHERE fund_id = t.uid('lpg')));

SELECT t.throws('a correction needs the right amount', $$
  SELECT bms.correct_transaction(t.uid('mv'), CURRENT_DATE, 0) $$, 'right amount');
SELECT t.runs('the cylinder is corrected to the right date and amount', $$
  SELECT t.remember('new', (bms.correct_transaction(t.uid('mv'), CURRENT_DATE - 3, 6500, NULL, 'Typed 7000 instead of 6500')).id::text) $$);
SELECT t.eq('the original is reversed, not changed', 'REVERSED', (SELECT status FROM bms.transactions WHERE id = t.uid('mv')));
SELECT t.eq('and still shows what was first entered', 7000.00, (SELECT amount FROM bms.transactions WHERE id = t.uid('mv')));
SELECT t.eq('the new entry has the right amount', 6500.00, (SELECT amount FROM bms.transactions WHERE id = t.uid('new')));
SELECT t.eq('and the right date', (CURRENT_DATE - 3)::text, (SELECT txn_date::text FROM bms.transactions WHERE id = t.uid('new')));
SELECT t.eq('and is posted', 'POSTED', (SELECT status FROM bms.transactions WHERE id = t.uid('new')));
SELECT t.ok('and says what it corrects', (SELECT notes LIKE 'Correction of %Typed 7000 instead of 6500%' FROM bms.fund_movements WHERE txn_id = t.uid('new')));
SELECT t.eq('the LPG fund now shows the right cylinder price', 13500.00, (SELECT current_balance FROM bms.v_fund_balances WHERE fund_id = t.uid('lpg')));
SELECT t.eq('with the history kept: bought, reversed, bought again', 3::bigint, (SELECT COUNT(*) FROM bms.fund_movements WHERE fund_id = t.uid('lpg')));
SELECT t.throws('a corrected entry cannot be corrected again', $$
  SELECT bms.correct_transaction(t.uid('mv'), CURRENT_DATE, 100) $$, 'not been reversed');

-- Reversing a fund entry on its own puts the fund back too.
SELECT bms.reverse_transaction(t.uid('new'), 'Cylinder returned');
SELECT t.eq('reversing a fund-paid entry gives the money back to the fund', 20000.00,
  (SELECT current_balance FROM bms.v_fund_balances WHERE fund_id = t.uid('lpg')));

-- An ordinary entry.
SELECT t.remember('ord', (SELECT (bms.create_transaction(CURRENT_DATE - 2, 'EXPENSE',
  (SELECT id FROM bms.departments WHERE code = 'CLEANING'), (SELECT id FROM bms.categories WHERE name = 'Cleaning supplies'),
  'Brooms', 100, 'CASH', t.uid('cash'))).id::text));
SELECT t.remember('ord2', (SELECT (bms.correct_transaction(t.uid('ord'), CURRENT_DATE - 1, 150)).id::text));
SELECT t.eq('an ordinary entry is corrected the same way', 150.00, (SELECT amount FROM bms.transactions WHERE id = t.uid('ord2')));
SELECT t.eq('keeping its department and category', 'Cleaning supplies',
  (SELECT c.name FROM bms.transactions x JOIN bms.categories c ON c.id = x.category_id WHERE x.id = t.uid('ord2')));

-- A service-charge payment is corrected on its own screen.
SELECT t.remember('pay', (SELECT (bms.record_payment((SELECT id FROM bms.flats WHERE flat_number = 'A-101'), 500, CURRENT_DATE,
  'CASH', t.uid('cash'), NULL, NULL, NULL)).txn_id::text));
SELECT t.throws('a service-charge payment is sent to its own screen', $$
  SELECT bms.correct_transaction(t.uid('pay'), CURRENT_DATE, 600) $$, 'service-charge payment');

SELECT set_config('request.jwt.claim.sub', t.recall('committee'), false);
SELECT t.throws('a committee member cannot correct entries', $$
  SELECT bms.correct_transaction(t.uid('ord2'), CURRENT_DATE, 1) $$, 'permission denied');
RESET ROLE;
