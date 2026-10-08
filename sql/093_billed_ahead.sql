-- =====================================================================
-- 093_billed_ahead.sql — a month billed early is not owed yet.
--
-- Reported: November was generated in October as a trial, and every flat
-- then "owed" Tk 10,000 — October's charge plus November's. October's
-- bills and reminders listed November as "earlier dues".
--
-- A month that has not begun yet is now BILLED AHEAD:
--   • v_flat_charges says so (not_due_yet) for each charge;
--   • v_flat_dues.outstanding counts only months that have begun (and
--     the opening balance); the rest is shown apart as billed_ahead;
--   • reminders and DUE slips list only months that have begun;
--   • a month's bill counts as "earlier dues" only months before it.
-- On the 1st of the month the charge simply becomes due — nothing has to
-- be run. Payments are unchanged: they still settle the oldest month
-- first, and anything over stays as the flat's advance.
-- =====================================================================

CREATE OR REPLACE VIEW bms.v_flat_charges WITH (security_invoker = true) AS
SELECT fc.id, fc.flat_id, f.flat_number, f.floor,
       fc.period_year, fc.period_month,
       make_date(fc.period_year, fc.period_month, 1) AS period_start,
       fc.charge_source, fc.charge_amount, fc.adjustment_amount, fc.waiver_amount,
       fc.net_payable, fc.due_date, fc.is_cancelled, fc.run_id,
       COALESCE(p.paid, 0)::numeric(14,2)                            AS paid_amount,
       (fc.net_payable - COALESCE(p.paid, 0))::numeric(14,2)         AS due_amount,
       CASE
         WHEN fc.is_cancelled                              THEN 'CANCELLED'
         WHEN fc.net_payable <= 0 AND fc.waiver_amount > 0 THEN 'WAIVED'
         WHEN COALESCE(p.paid,0) >= fc.net_payable         THEN 'PAID'
         WHEN COALESCE(p.paid,0) > 0                       THEN 'PARTIAL'
         WHEN fc.due_date < CURRENT_DATE                   THEN 'OVERDUE'
         ELSE 'UNPAID'
       END AS status,
       GREATEST(0, CURRENT_DATE - fc.due_date) AS days_overdue,
       (fc.charge_source <> 'OPENING'
        AND make_date(fc.period_year, fc.period_month, 1) > date_trunc('month', CURRENT_DATE)::date) AS not_due_yet
  FROM bms.flat_charges fc
  JOIN bms.flats f ON f.id = fc.flat_id
  LEFT JOIN (
        SELECT flat_charge_id, SUM(amount)::numeric(14,2) AS paid
          FROM bms.payment_allocations GROUP BY flat_charge_id
       ) p ON p.flat_charge_id = fc.id;

CREATE OR REPLACE VIEW bms.v_flat_dues WITH (security_invoker = true) AS
WITH per_charge AS (
  SELECT fc.flat_id, fc.net_payable, COALESCE(p.paid, 0) AS paid,
         (fc.charge_source = 'OPENING'
          OR make_date(fc.period_year, fc.period_month, 1) <= date_trunc('month', CURRENT_DATE)::date) AS due_now
    FROM bms.flat_charges fc
    LEFT JOIN (SELECT flat_charge_id, SUM(amount) AS paid FROM bms.payment_allocations GROUP BY flat_charge_id) p
           ON p.flat_charge_id = fc.id
   WHERE NOT fc.is_cancelled
), charged AS (
  SELECT flat_id,
         SUM(net_payable)::numeric(14,2) AS charged,
         SUM(paid)::numeric(14,2)        AS allocated,
         COALESCE(SUM(GREATEST(net_payable - paid, 0)) FILTER (WHERE due_now), 0)::numeric(14,2)     AS due_now,
         COALESCE(SUM(GREATEST(net_payable - paid, 0)) FILTER (WHERE NOT due_now), 0)::numeric(14,2) AS ahead
    FROM per_charge GROUP BY flat_id
), allocated_all AS (
  SELECT fc.flat_id, SUM(pa.amount)::numeric(14,2) AS allocated
    FROM bms.payment_allocations pa
    JOIN bms.flat_charges fc ON fc.id = pa.flat_charge_id
   GROUP BY fc.flat_id
), paid AS (
  SELECT flat_id, SUM(amount)::numeric(14,2) AS received,
         MAX(payment_date) AS last_payment_date
    FROM bms.payments WHERE status = 'ACTIVE' GROUP BY flat_id
)
SELECT f.id AS flat_id, f.flat_number, f.floor, f.status AS flat_status,
       f.service_charge,
       COALESCE(c.charged, 0)   AS total_charged,
       COALESCE(a.allocated, 0) AS total_allocated,
       COALESCE(p.received, 0)  AS total_received,
       COALESCE(c.due_now, 0)::numeric(14,2) AS outstanding,
       GREATEST(COALESCE(p.received,0) - COALESCE(a.allocated,0), 0)::numeric(14,2) AS advance,
       p.last_payment_date,
       (SELECT o.name FROM bms.flat_occupancy fo JOIN bms.owners o ON o.id = fo.owner_id
         WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) AS billed_to,
       (SELECT o.mobile FROM bms.flat_occupancy fo JOIN bms.owners o ON o.id = fo.owner_id
         WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) AS billed_mobile,
       COALESCE(c.ahead, 0)::numeric(14,2) AS billed_ahead
  FROM bms.flats f
  LEFT JOIN charged       c ON c.flat_id = f.id
  LEFT JOIN allocated_all a ON a.flat_id = f.id
  LEFT JOIN paid          p ON p.flat_id = f.id;

CREATE OR REPLACE FUNCTION bms.reminder_context(p_flat uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE d record; ppl record; s bms.building_settings; rm record;
        v_since int; v_tone text; v_months jsonb; v_tpl jsonb;
        v_name text; v_mobile text; v_rel text;
BEGIN
  PERFORM bms.assert_perm('charges','view');

  SELECT * INTO d FROM bms.v_flat_dues WHERE flat_id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;
  SELECT * INTO ppl FROM bms.v_flat_people WHERE flat_id = p_flat;
  SELECT * INTO s FROM bms.building_settings WHERE id;
  SELECT * INTO rm FROM bms.v_flat_reminders WHERE flat_id = p_flat;

  v_rel    := ppl.billed_relation;
  v_name   := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_name   WHEN 'OWNER' THEN ppl.owner_name   END;
  v_mobile := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_mobile WHEN 'OWNER' THEN ppl.owner_mobile END;

  v_since := COALESCE(rm.reminders_since_payment, 0);
  v_tone  := CASE WHEN v_since = 0 THEN 'GENTLE' WHEN v_since = 1 THEN 'FOLLOW_UP' ELSE 'FIRM' END;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'year', period_year, 'month', period_month,
           'source', charge_source, 'due', due_amount)
           ORDER BY period_year, period_month), '[]'::jsonb)
    INTO v_months
    FROM bms.v_flat_charges
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED')
     AND NOT not_due_yet;

  SELECT COALESCE(jsonb_object_agg(tone || '.' || lang, body), '{}'::jsonb)
    INTO v_tpl FROM bms.reminder_templates;

  RETURN jsonb_build_object(
    'flat_id', p_flat, 'flat_number', d.flat_number,
    'outstanding', d.outstanding, 'advance', d.advance,
    'last_payment_date', d.last_payment_date,
    'recipient_name', v_name, 'relation', v_rel,
    'mobile', v_mobile, 'mobile_wa', bms.normalize_mobile(v_mobile),
    'months', v_months,
    'reminders_total', COALESCE(rm.reminders_total, 0),
    'reminders_since_payment', v_since,
    'last_reminded_at', rm.last_reminded_at,
    'suggested_tone', v_tone,
    'building_name', s.building_name,
    'how_to_pay', s.reminder_how_to_pay,
    'language', COALESCE(s.reminder_language, 'en'),
    'deadline_date', CURRENT_DATE + COALESCE(s.reminder_deadline_days, 7),
    'templates', v_tpl,
    'can_send', bms.has_perm('charges','add'));
END $$;

CREATE OR REPLACE FUNCTION bms.log_charge_reminder(
    p_flat uuid, p_channel text, p_tone text, p_lang text, p_message text)
RETURNS bms.charge_reminders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE d record; ppl record; r bms.charge_reminders; v_months text;
        v_name text; v_mobile text; v_rel text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_channel NOT IN ('WHATSAPP','SMS','COPY','IMAGE','PDF','PRINT') THEN RAISE EXCEPTION 'Unknown channel %', p_channel; END IF;
  IF p_tone NOT IN ('GENTLE','FOLLOW_UP','FIRM') THEN RAISE EXCEPTION 'Unknown tone %', p_tone; END IF;
  IF p_lang NOT IN ('en','bn') THEN RAISE EXCEPTION 'Unknown language %', p_lang; END IF;
  IF COALESCE(btrim(p_message), '') = '' THEN RAISE EXCEPTION 'The message is empty'; END IF;

  SELECT * INTO d FROM bms.v_flat_dues WHERE flat_id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;
  IF COALESCE(d.outstanding, 0) <= 0 THEN
    RAISE EXCEPTION 'Flat % owes nothing now, so no reminder was recorded.', d.flat_number
      USING ERRCODE = '23514';
  END IF;

  SELECT * INTO ppl FROM bms.v_flat_people WHERE flat_id = p_flat;
  v_rel    := ppl.billed_relation;
  v_name   := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_name   WHEN 'OWNER' THEN ppl.owner_name   END;
  v_mobile := CASE v_rel WHEN 'TENANT' THEN ppl.tenant_mobile WHEN 'OWNER' THEN ppl.owner_mobile END;

  SELECT string_agg(CASE WHEN charge_source = 'OPENING' THEN 'earlier balance'
                         ELSE to_char(make_date(period_year, period_month, 1), 'Mon YYYY') END,
                    ', ' ORDER BY period_year, period_month)
    INTO v_months
    FROM bms.v_flat_charges
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED')
     AND NOT not_due_yet;

  INSERT INTO bms.charge_reminders (flat_id, sent_by, channel, tone, lang,
                                    recipient_name, relation, phone, phone_sent,
                                    amount_due, months, message)
  VALUES (p_flat, auth.uid(), p_channel, p_tone, p_lang,
          v_name, v_rel, v_mobile, bms.normalize_mobile(v_mobile),
          d.outstanding, v_months, left(p_message, 4000))
  RETURNING * INTO r;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION bms.month_bills(p_year int, p_month int)
RETURNS TABLE (flat_id uuid, flat_number text, floor int,
               payer_id uuid, payer_name text, payer_mobile text, payer_relation text,
               this_month numeric(14,2), this_month_due numeric(14,2), previous_due numeric(14,2),
               total_due numeric(14,2), advance numeric(14,2), rate_source text, rate_reason text,
               due_date date, is_billed boolean, last_sent_at timestamptz, times_sent int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM bms.assert_perm('charges','view');
  IF p_month < 1 OR p_month > 12 THEN RAISE EXCEPTION 'Month must be 1-12'; END IF;
  RETURN QUERY
  SELECT f.id, f.flat_number, f.floor,
         bill.owner_id, bp.name, bp.mobile, bill.relation_type,
         COALESCE(fc.net_payable, 0)::numeric(14,2),
         COALESCE(fc.due_amount, 0)::numeric(14,2),
         COALESCE(prev.due, 0)::numeric(14,2),
         (COALESCE(prev.due, 0) + GREATEST(COALESCE(fc.due_amount, 0), 0))::numeric(14,2),
         COALESCE(d.advance, 0)::numeric(14,2),
         r.source, r.reason,
         COALESCE(fc.due_date, make_date(p_year, p_month, LEAST(s.charge_due_day, 28))),
         fc.id IS NOT NULL, bn.last_sent, COALESCE(bn.n, 0)::int
    FROM bms.flats f
    CROSS JOIN bms.building_settings s
    LEFT JOIN bms.v_flat_charges fc ON fc.flat_id = f.id AND fc.period_year = p_year
                                   AND fc.period_month = p_month AND fc.charge_source = 'MONTHLY'
                                   AND NOT fc.is_cancelled
    LEFT JOIN bms.v_flat_dues d ON d.flat_id = f.id
    -- Earlier dues are the months BEFORE this one — never a later month
    -- billed ahead of time.
    LEFT JOIN LATERAL (SELECT SUM(GREATEST(x.due_amount, 0)) AS due FROM bms.v_flat_charges x
                        WHERE x.flat_id = f.id AND NOT x.is_cancelled
                          AND (x.charge_source = 'OPENING'
                               OR make_date(x.period_year, x.period_month, 1) < make_date(p_year, p_month, 1))) prev ON true
    LEFT JOIN LATERAL (SELECT fo.owner_id, fo.relation_type FROM bms.flat_occupancy fo
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) bill ON true
    LEFT JOIN bms.owners bp ON bp.id = bill.owner_id
    LEFT JOIN LATERAL bms.flat_rate_for(f.id, make_date(p_year, p_month, 1)) r ON true
    LEFT JOIN LATERAL (SELECT MAX(b.sent_at) AS last_sent, COUNT(*) AS n FROM bms.bill_notices b
                        WHERE b.flat_id = f.id AND b.period_year = p_year AND b.period_month = p_month) bn ON true
   WHERE s.id AND (f.status = 'ACTIVE' OR COALESCE(prev.due, 0) > 0 OR COALESCE(fc.due_amount, 0) > 0)
   ORDER BY bp.name NULLS LAST, f.floor, f.flat_number;
END $$;

REVOKE ALL ON FUNCTION bms.reminder_context(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.reminder_context(uuid) TO authenticated;
REVOKE ALL ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION bms.month_bills(int,int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.month_bills(int,int) TO authenticated;
