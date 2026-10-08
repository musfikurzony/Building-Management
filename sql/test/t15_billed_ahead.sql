-- =====================================================================
-- t15 — a month billed early is not owed yet.
--
-- Reported: next month was generated as a trial; every flat then "owed"
-- two months, and this month's bill listed next month as earlier dues.
-- =====================================================================
SET t.suite = 't15 billed ahead';
SET search_path = bms, public;

CREATE OR REPLACE FUNCTION t.ym(k int) RETURNS int[] LANGUAGE sql STABLE AS $$
  SELECT ARRAY[EXTRACT(year FROM d)::int, EXTRACT(month FROM d)::int]
    FROM (SELECT (date_trunc('month', CURRENT_DATE) + make_interval(months => k))::date AS d) x $$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.remember('a101', (SELECT id::text FROM bms.flats WHERE flat_number = 'A-101'));
SELECT bms.set_flat_owner(t.uid('a101'), NULL, 'Owner A101', '01711000101', NULL, NULL, CURRENT_DATE - 60);


SELECT bms.generate_monthly_charges((t.ym(0))[1], (t.ym(0))[2]);
SELECT bms.generate_monthly_charges((t.ym(1))[1], (t.ym(1))[2]);
SELECT t.remember('rate', (SELECT net_payable::text FROM bms.flat_charges WHERE flat_id = t.uid('a101') LIMIT 1));

SELECT t.eq('next month billed early is not counted as owed', t.recall('rate')::numeric,
  (SELECT outstanding FROM bms.v_flat_dues WHERE flat_id = t.uid('a101')));
SELECT t.eq('it is shown apart, as billed ahead', t.recall('rate')::numeric,
  (SELECT billed_ahead FROM bms.v_flat_dues WHERE flat_id = t.uid('a101')));
SELECT t.ok('each charge says whether it is due yet',
  (SELECT bool_and(not_due_yet = (period_month = (t.ym(1))[2])) FROM bms.v_flat_charges WHERE flat_id = t.uid('a101')));

SELECT t.eq('this month''s bill has no "earlier dues" from next month', 0::numeric,
  (SELECT previous_due FROM bms.month_bills((t.ym(0))[1], (t.ym(0))[2]) WHERE flat_id = t.uid('a101')));
SELECT t.eq('and its total is this month only', t.recall('rate')::numeric,
  (SELECT total_due FROM bms.month_bills((t.ym(0))[1], (t.ym(0))[2]) WHERE flat_id = t.uid('a101')));
SELECT t.eq('next month''s bill carries this month as earlier dues', t.recall('rate')::numeric,
  (SELECT previous_due FROM bms.month_bills((t.ym(1))[1], (t.ym(1))[2]) WHERE flat_id = t.uid('a101')));

SELECT t.eq('a reminder lists only the month that has begun', 1,
  (SELECT jsonb_array_length(bms.reminder_context(t.uid('a101'))->'months')));
SELECT t.eq('and asks for this month''s amount', t.recall('rate')::numeric,
  (SELECT (bms.reminder_context(t.uid('a101'))->>'outstanding')::numeric));
SELECT t.eq('the logged reminder names only this month', to_char(make_date((t.ym(0))[1], (t.ym(0))[2], 1), 'Mon YYYY'),
  (SELECT months FROM bms.log_charge_reminder(t.uid('a101'), 'WHATSAPP', 'GENTLE', 'en', 'Dear owner, …')));

-- Paying both months: the oldest first, nothing owed, nothing ahead.
SELECT bms.record_payment(t.uid('a101'), 2 * t.recall('rate')::numeric, CURRENT_DATE, 'CASH', t.uid('acct_bank'), 'R2', NULL, NULL);
SELECT t.eq('paying both settles this month', 0::numeric, (SELECT outstanding FROM bms.v_flat_dues WHERE flat_id = t.uid('a101')));
SELECT t.eq('and next month in advance', 0::numeric, (SELECT billed_ahead FROM bms.v_flat_dues WHERE flat_id = t.uid('a101')));
SELECT t.eq('next month shows as paid', 'PAID',
  (SELECT status FROM bms.v_flat_charges WHERE flat_id = t.uid('a101') AND period_month = (t.ym(1))[2]));
RESET ROLE;
