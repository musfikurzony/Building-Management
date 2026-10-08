-- =====================================================================
-- 092_slip_channels.sql — a DUE slip counts as a reminder.
--
-- A flat's DUE slip can now be sent as a picture, a PDF or on paper as
-- well as a WhatsApp or SMS message. Every one of those is a reminder,
-- and must count in "reminded 2× since the last payment", so the reminder
-- log accepts IMAGE, PDF and PRINT as channels.
-- =====================================================================
DO $do$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
            WHERE conrelid = 'bms.charge_reminders'::regclass AND contype = 'c'
              AND pg_get_constraintdef(oid) LIKE '%channel%'
  LOOP
    EXECUTE format('ALTER TABLE bms.charge_reminders DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $do$;
ALTER TABLE bms.charge_reminders ADD CONSTRAINT charge_reminders_channel_ck
  CHECK (channel IN ('WHATSAPP','SMS','COPY','IMAGE','PDF','PRINT'));

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
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED');

  INSERT INTO bms.charge_reminders (flat_id, sent_by, channel, tone, lang,
                                    recipient_name, relation, phone, phone_sent,
                                    amount_due, months, message)
  VALUES (p_flat, auth.uid(), p_channel, p_tone, p_lang,
          v_name, v_rel, v_mobile, bms.normalize_mobile(v_mobile),
          d.outstanding, v_months, left(p_message, 4000))
  RETURNING * INTO r;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) TO authenticated;
