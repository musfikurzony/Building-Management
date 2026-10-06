-- =====================================================================
-- t13 — a land owner with several flats, a flat under construction, one
-- payment for many flats, and the monthly bill.
--
-- Haji Karim owns A-101, A-102 and A-103. A-101 is let to Rafiq, who pays
-- for it himself. A-102 is empty and Karim pays. A-103 is still being
-- finished: it pays a temporary Tk 1,000 for two months, then the normal
-- rate again without anyone remembering to change it back.
-- =====================================================================
SET t.suite = 't13 owners & bills';
SET search_path = bms, public;

CREATE OR REPLACE FUNCTION t.nm(k int DEFAULT 0) RETURNS date
LANGUAGE sql STABLE AS $$ SELECT (date_trunc('month', CURRENT_DATE) + make_interval(months => 1 + k))::date $$;

INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000b1','resident@test') ON CONFLICT DO NOTHING;
INSERT INTO bms.user_profiles (user_id, full_name, email, is_active)
VALUES ('00000000-0000-0000-0000-0000000000b1','Flat Resident','resident@test',true) ON CONFLICT DO NOTHING;
INSERT INTO bms.user_roles (user_id, role_id)
SELECT '00000000-0000-0000-0000-0000000000b1', id FROM bms.roles WHERE code = 'RESIDENT' ON CONFLICT DO NOTHING;
SELECT t.remember('resident', '00000000-0000-0000-0000-0000000000b1');

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.remember('a101', (SELECT id::text FROM bms.flats WHERE flat_number = 'A-101'));
SELECT t.remember('a102', (SELECT id::text FROM bms.flats WHERE flat_number = 'A-102'));
SELECT t.remember('a103', (SELECT id::text FROM bms.flats WHERE flat_number = 'A-103'));

-- ---------------------------------------------------------------------
-- 1. ONE OWNER, THREE FLATS.
-- ---------------------------------------------------------------------
SELECT t.runs('Haji Karim becomes the owner of A-101', $$
  SELECT bms.set_flat_owner(t.uid('a101'), NULL, 'Haji Karim', '01711999000', NULL, NULL, CURRENT_DATE - 30) $$);
SELECT t.remember('karim', (SELECT id::text FROM bms.owners WHERE name = 'Haji Karim'));
SELECT t.runs('and of A-102 and A-103', $$
  SELECT bms.set_flat_owner(t.uid('a102'), t.uid('karim'), NULL, NULL, NULL, NULL, CURRENT_DATE - 30),
         bms.set_flat_owner(t.uid('a103'), t.uid('karim'), NULL, NULL, NULL, NULL, CURRENT_DATE - 30) $$);
SELECT t.runs('A-101 is let to Rafiq, who pays for it', $$
  SELECT bms.set_flat_tenant(t.uid('a101'), NULL, 'Rafiq Tenant', '01811000777', NULL, NULL, CURRENT_DATE - 10, true) $$);

SELECT t.eq('Karim owns three flats', 3, (SELECT flats_owned FROM bms.owner_accounts() WHERE owner_name = 'Haji Karim'));
SELECT t.eq('one of them is rented out', 1, (SELECT flats_rented_out FROM bms.owner_accounts() WHERE owner_name = 'Haji Karim'));
SELECT t.eq('he pays for two', 2, (SELECT flats_paid FROM bms.owner_accounts() WHERE owner_name = 'Haji Karim'));
SELECT t.eq('his monthly total is A-102 plus A-103 at the default rate',
  (SELECT 4500.00 + default_service_charge FROM bms.building_settings),
  (SELECT monthly_total FROM bms.owner_accounts() WHERE owner_name = 'Haji Karim'));
SELECT t.eq('the owner''s flat list says who rents A-101', 'Rafiq Tenant',
  (SELECT tenant_name FROM bms.owner_flats(t.uid('karim')) WHERE flat_number = 'A-101'));
SELECT t.eq('and that Rafiq pays for it', 'Rafiq Tenant',
  (SELECT payer_name FROM bms.owner_flats(t.uid('karim')) WHERE flat_number = 'A-101'));
SELECT t.eq('Rafiq has an account too, for the one flat he pays', 1,
  (SELECT flats_paid FROM bms.owner_accounts() WHERE owner_name = 'Rafiq Tenant'));

-- ---------------------------------------------------------------------
-- 2. A TEMPORARY RATE THAT ENDS BY ITSELF.
-- ---------------------------------------------------------------------
SELECT t.runs('A-103 pays Tk 1,000 for two months while it is finished', $$
  SELECT bms.set_temporary_rate(t.uid('a103'), t.nm(0), t.nm(1), 1000, 'Under construction') $$);
SELECT t.eq('the rate for next month is the temporary one', 1000.00,
  (SELECT amount FROM bms.flat_rate_for(t.uid('a103'), t.nm(0))));
SELECT t.eq('and says why', 'Under construction', (SELECT reason FROM bms.flat_rate_for(t.uid('a103'), t.nm(1))));
SELECT t.eq('the month after, it is back to normal by itself', 'DEFAULT',
  (SELECT source FROM bms.flat_rate_for(t.uid('a103'), t.nm(2))));
SELECT t.eq('this month is untouched', 'DEFAULT', (SELECT source FROM bms.flat_rate_for(t.uid('a103'), CURRENT_DATE)));
SELECT t.throws('two temporary rates cannot overlap', $$
  SELECT bms.set_temporary_rate(t.uid('a103'), t.nm(1), t.nm(3), 500, 'Again') $$, 'already has a temporary rate');
SELECT t.throws('a reason is required', $$
  SELECT bms.set_temporary_rate(t.uid('a102'), t.nm(0), t.nm(0), 500, ' ') $$, 'Say why');
SELECT t.throws('the end cannot be before the start', $$
  SELECT bms.set_temporary_rate(t.uid('a102'), t.nm(2), t.nm(0), 500, 'Backwards') $$, 'before the first');

SELECT t.runs('next month is billed', $$
  SELECT bms.generate_monthly_charges(EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int) $$);
SELECT t.eq('A-103 is billed the temporary amount', 1000.00,
  (SELECT charge_amount FROM bms.flat_charges WHERE flat_id = t.uid('a103')
      AND make_date(period_year, period_month, 1) = t.nm(0)));
SELECT t.ok('and the bill line says why',
  (SELECT label FROM bms.charge_line_items li JOIN bms.flat_charges fc ON fc.id = li.flat_charge_id
    WHERE fc.flat_id = t.uid('a103') AND make_date(fc.period_year, fc.period_month, 1) = t.nm(0)) LIKE '%temporary rate: Under construction%');
SELECT t.eq('the other flats are billed as usual', 4500.00,
  (SELECT charge_amount FROM bms.flat_charges WHERE flat_id = t.uid('a102')
      AND make_date(period_year, period_month, 1) = t.nm(0)));
SELECT t.throws('a month already billed cannot be given a temporary rate', $$
  SELECT bms.set_temporary_rate(t.uid('a102'), t.nm(0), t.nm(0), 100, 'Late change') $$, 'already billed');

SELECT t.runs('the month after the rate ends is billed', $$
  SELECT bms.generate_monthly_charges(EXTRACT(year FROM t.nm(2))::int, EXTRACT(month FROM t.nm(2))::int) $$);
SELECT t.eq('and A-103 is back at the normal rate', (SELECT default_service_charge FROM bms.building_settings),
  (SELECT charge_amount FROM bms.flat_charges WHERE flat_id = t.uid('a103')
      AND make_date(period_year, period_month, 1) = t.nm(2)));

SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('a caretaker cannot set a rate', $$
  SELECT bms.set_temporary_rate(t.uid('a102'), t.nm(5), t.nm(5), 1, 'No') $$);
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('a second temporary rate is set for later', $$
  SELECT bms.set_temporary_rate(t.uid('a102'), t.nm(6), t.nm(7), 100, 'Repairs') $$);
SELECT t.runs('and can be cancelled, with a reason', $$
  SELECT bms.cancel_temporary_rate((SELECT id FROM bms.flat_rate_overrides WHERE reason = 'Repairs'), 'Repairs finished early') $$);
SELECT t.eq('and then no longer applies', 'FLAT', (SELECT source FROM bms.flat_rate_for(t.uid('a102'), t.nm(6))));

-- ---------------------------------------------------------------------
-- 3. ONE PAYMENT FOR SEVERAL FLATS.
-- ---------------------------------------------------------------------
SELECT t.remember('dues_before', (SELECT outstanding::text FROM bms.owner_accounts() WHERE owner_name = 'Haji Karim'));
SELECT t.runs('Karim pays one sum for A-102 and A-103', $$
  SELECT t.remember('grp', (bms.record_group_payment(t.uid('karim'),
    jsonb_build_array(jsonb_build_object('flat', t.uid('a102'), 'amount', 4500),
                      jsonb_build_object('flat', t.uid('a103'), 'amount', 1000)),
    CURRENT_DATE, 'BKASH', t.uid('acct_bank'), 'TRX-99')).id::text) $$);
SELECT t.eq('one combined receipt for the total', 5500.00, (SELECT total_amount FROM bms.payment_groups WHERE id = t.uid('grp')));
SELECT t.ok('with its own receipt number', (SELECT group_no FROM bms.payment_groups WHERE id = t.uid('grp')) ~ '^RCT-G-\d{4}-0001$');
SELECT t.eq('in Karim''s name', 'Haji Karim', (SELECT payer_name FROM bms.payment_groups WHERE id = t.uid('grp')));
SELECT t.eq('made of one payment per flat', 2::bigint, (SELECT COUNT(*) FROM bms.payments WHERE group_id = t.uid('grp')));
SELECT t.eq('each flat''s own statement shows its own share', 4500.00,
  (SELECT amount FROM bms.payments WHERE group_id = t.uid('grp') AND flat_id = t.uid('a102')));
SELECT t.eq('Karim''s dues fall by exactly the sum', t.recall('dues_before')::numeric - 5500,
  (SELECT outstanding FROM bms.owner_accounts() WHERE owner_name = 'Haji Karim'));
SELECT t.eq('the combined receipt lists both flats', 'A-102, A-103', (SELECT flat_list FROM bms.v_payment_groups WHERE id = t.uid('grp')));
SELECT t.eq('and is whole', 'ACTIVE', (SELECT status FROM bms.v_payment_groups WHERE id = t.uid('grp')));
SELECT t.eq('the income is booked once per flat', 2::bigint,
  (SELECT COUNT(*) FROM bms.transactions t2 JOIN bms.payments p ON p.txn_id = t2.id WHERE p.group_id = t.uid('grp') AND t2.status = 'POSTED'));

SELECT t.throws('the same flat cannot appear twice', $$
  SELECT bms.record_group_payment(t.uid('karim'), jsonb_build_array(
    jsonb_build_object('flat', t.uid('a102'), 'amount', 10), jsonb_build_object('flat', t.uid('a102'), 'amount', 10)),
    CURRENT_DATE, 'CASH', t.uid('acct_bank')) $$, 'appears twice');
SELECT t.throws('every line needs an amount', $$
  SELECT bms.record_group_payment(t.uid('karim'), jsonb_build_array(jsonb_build_object('flat', t.uid('a102'), 'amount', 0)),
    CURRENT_DATE, 'CASH', t.uid('acct_bank')) $$, 'greater than zero');
SELECT t.throws('an empty payment is refused', $$
  SELECT bms.record_group_payment(t.uid('karim'), '[]'::jsonb, CURRENT_DATE, 'CASH', t.uid('acct_bank')) $$, 'at least one flat');

SELECT t.runs('the whole combined receipt can be reversed', $$
  SELECT bms.reverse_group_payment(t.uid('grp'), 'Cheque bounced') $$);
SELECT t.eq('every part is reversed', 'REVERSED', (SELECT status FROM bms.v_payment_groups WHERE id = t.uid('grp')));
SELECT t.eq('and Karim owes what he owed before', t.recall('dues_before')::numeric,
  (SELECT outstanding FROM bms.owner_accounts() WHERE owner_name = 'Haji Karim'));
SELECT t.throws('it cannot be reversed twice', $$ SELECT bms.reverse_group_payment(t.uid('grp'), 'Again') $$, 'already reversed');

-- ---------------------------------------------------------------------
-- 4. THE MONTHLY BILL.
-- ---------------------------------------------------------------------
SELECT t.eq('next month''s bill for A-103 shows the temporary charge', 1000.00,
  (SELECT this_month FROM bms.month_bills(EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int) WHERE flat_number = 'A-103'));
SELECT t.eq('A-101''s bill goes to the tenant who pays', 'Rafiq Tenant',
  (SELECT payer_name FROM bms.month_bills(EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int) WHERE flat_number = 'A-101'));
SELECT t.eq('a bill''s total is this month plus what was owed before', 0::bigint,
  (SELECT COUNT(*) FROM bms.month_bills(EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int)
    WHERE total_due <> previous_due + this_month_due));
SELECT t.eq('and matches the dues on record', 0::bigint,
  (SELECT COUNT(*) FROM bms.month_bills(EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int) b
     JOIN bms.v_flat_dues d ON d.flat_id = b.flat_id WHERE b.total_due <> d.outstanding));
SELECT t.eq('it is due on the building''s due day',
  (SELECT make_date(EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int, charge_due_day) FROM bms.building_settings),
  (SELECT due_date FROM bms.month_bills(EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int) WHERE flat_number = 'A-102'));
SELECT t.ok('the bill wording is ready in English and Bangla',
  (SELECT bill_template_en LIKE '%{lines}%' AND bill_template_bn LIKE '%{lines}%' FROM bms.building_settings));

SELECT t.eq('sending Karim one bill for his two flats records both', 2,
  bms.log_bill_notice(jsonb_build_array(t.uid('a102'), t.uid('a103')), EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int,
                      'WHATSAPP', 'Dear Haji Karim, your bill…'));
SELECT t.eq('the month''s list shows them as sent', 2::bigint,
  (SELECT COUNT(*) FROM bms.month_bills(EXTRACT(year FROM t.nm(0))::int, EXTRACT(month FROM t.nm(0))::int) WHERE times_sent = 1));
SELECT t.eq('to Karim', 'Haji Karim', (SELECT DISTINCT recipient_name FROM bms.bill_notices));
SELECT t.throws('a sent bill cannot be deleted', $$ DELETE FROM bms.bill_notices WHERE true $$);

-- ---------------------------------------------------------------------
-- 5. WHO MAY SEE IT.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('resident'), false);
SELECT t.throws('a resident cannot see owners'' accounts', $$ SELECT * FROM bms.owner_accounts() $$);
SELECT t.throws('nor the month''s bills', $$ SELECT * FROM bms.month_bills(2026, 1) $$);
SELECT set_config('request.jwt.claim.sub', t.recall('committee'), false);
SELECT t.throws('a committee member can read but not take a combined payment', $$
  SELECT bms.record_group_payment(NULL, jsonb_build_array(jsonb_build_object('flat', t.uid('a102'), 'amount', 1)),
    CURRENT_DATE, 'CASH', t.uid('acct_bank')) $$);

RESET ROLE;
