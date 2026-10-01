-- =====================================================================
-- 011_charge_functions.sql — service charge generation, payment
-- allocation, waivers, opening balances.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- What is still unpaid on a single charge.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.charge_due(p_charge uuid)
RETURNS numeric(14,2)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT GREATEST(fc.net_payable - COALESCE((
           SELECT SUM(a.amount) FROM bms.payment_allocations a
            WHERE a.flat_charge_id = fc.id), 0), 0)
    FROM bms.flat_charges fc WHERE fc.id = p_charge AND NOT fc.is_cancelled
$$;

-- ---------------------------------------------------------------------
-- ALLOCATION ENGINE.
-- Spreads every not-yet-allocated taka a flat has paid across its unpaid
-- charges, oldest charge first, oldest payment first. Anything left over
-- stays as advance and is picked up automatically next month.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.allocate_flat_advance(p_flat uuid)
RETURNS numeric(14,2)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  pay   record;
  chg   record;
  v_free      numeric(14,2);
  v_due       numeric(14,2);
  v_take      numeric(14,2);
  v_allocated numeric(14,2) := 0;
BEGIN
  FOR pay IN
    SELECT p.id,
           p.amount - COALESCE((SELECT SUM(a.amount) FROM bms.payment_allocations a
                                 WHERE a.payment_id = p.id), 0) AS unallocated
      FROM bms.payments p
     WHERE p.flat_id = p_flat AND p.status = 'ACTIVE'
     ORDER BY p.payment_date, p.created_at
  LOOP
    v_free := pay.unallocated;
    CONTINUE WHEN v_free <= 0;

    FOR chg IN
      SELECT fc.id
        FROM bms.flat_charges fc
       WHERE fc.flat_id = p_flat AND NOT fc.is_cancelled
       ORDER BY fc.period_year, fc.period_month,
                CASE fc.charge_source WHEN 'OPENING' THEN 0 ELSE 1 END
    LOOP
      EXIT WHEN v_free <= 0;
      v_due := bms.charge_due(chg.id);
      CONTINUE WHEN v_due <= 0;

      v_take := LEAST(v_free, v_due);
      INSERT INTO bms.payment_allocations(payment_id, flat_charge_id, amount)
      VALUES (pay.id, chg.id, v_take);
      v_free      := v_free - v_take;
      v_allocated := v_allocated + v_take;
    END LOOP;
  END LOOP;

  RETURN v_allocated;
END $$;

-- ---------------------------------------------------------------------
-- GENERATE A MONTH.
-- Idempotent by construction: charge_runs is UNIQUE on (year, month, type)
-- and flat_charges is UNIQUE on (flat, year, month, source).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.generate_monthly_charges(p_year int, p_month int)
RETURNS bms.charge_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  run       bms.charge_runs;
  s         bms.building_settings;
  f         record;
  v_amount  numeric(14,2);
  v_due     date;
  v_count   int := 0;
  v_total   numeric(14,2) := 0;
  v_charge  uuid;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_month < 1 OR p_month > 12 THEN RAISE EXCEPTION 'Month must be 1-12'; END IF;

  SELECT * INTO s FROM bms.building_settings WHERE id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building settings have not been configured yet'; END IF;

  IF bms.period_is_closed(make_date(p_year, p_month, 1)) THEN
    RAISE EXCEPTION 'Accounting period % is closed', to_char(make_date(p_year,p_month,1),'Mon YYYY');
  END IF;

  -- Make sure the month exists as an accounting period even if no cash has
  -- moved yet, so it shows up on the settings screen and can be closed.
  PERFORM bms.period_for(make_date(p_year, p_month, 1));

  -- Reuse the month's run if there is one; the charges hang off it either
  -- way, so a flat added in week three belongs to the same monthly run as
  -- the flats billed in week one.
  SELECT * INTO run FROM bms.charge_runs
   WHERE period_year = p_year AND period_month = p_month AND run_type = 'MONTHLY';
  IF NOT FOUND THEN
    INSERT INTO bms.charge_runs(period_year, period_month, run_type, generated_by)
    VALUES (p_year, p_month, 'MONTHLY', auth.uid())
    RETURNING * INTO run;
  END IF;

  v_due := make_date(p_year, p_month, LEAST(s.charge_due_day, 28));

  -- Only the flats that are not billed for this month yet.
  FOR f IN SELECT fl.id, fl.flat_number, fl.service_charge FROM bms.flats fl
            WHERE fl.status = 'ACTIVE'
              AND NOT EXISTS (SELECT 1 FROM bms.flat_charges fc
                               WHERE fc.flat_id = fl.id
                                 AND fc.period_year = p_year
                                 AND fc.period_month = p_month
                                 AND fc.charge_source = 'MONTHLY')
            ORDER BY fl.floor, fl.flat_number
  LOOP
    v_amount := COALESCE(f.service_charge, s.default_service_charge);

    INSERT INTO bms.flat_charges(run_id, flat_id, period_year, period_month,
                                 charge_source, charge_amount, due_date)
    VALUES (run.id, f.id, p_year, p_month, 'MONTHLY', v_amount, v_due)
    RETURNING id INTO v_charge;

    INSERT INTO bms.charge_line_items(flat_charge_id, label, kind, amount, sort_order)
    VALUES (v_charge, 'Monthly service charge', 'SERVICE', v_amount, 10);

    v_count := v_count + 1;
    v_total := v_total + v_amount;
  END LOOP;

  -- The run totals describe the month as a whole, not just this pass, so
  -- they are recounted from the charges rather than incremented. After a
  -- top-up the row still answers "what was billed for September".
  UPDATE bms.charge_runs r
     SET flat_count   = (SELECT COUNT(*) FROM bms.flat_charges fc
                          WHERE fc.period_year = p_year AND fc.period_month = p_month
                            AND fc.charge_source = 'MONTHLY'),
         total_amount = (SELECT COALESCE(SUM(fc.charge_amount),0) FROM bms.flat_charges fc
                          WHERE fc.period_year = p_year AND fc.period_month = p_month
                            AND fc.charge_source = 'MONTHLY')
   WHERE r.id = run.id RETURNING * INTO run;

  -- How many this pass actually added, so the screen can say so instead of
  -- leaving the person guessing whether anything happened. Set on the
  -- returned record only — deliberately NOT written to the row, because it
  -- describes this call, not the month.
  run.notes := CASE WHEN v_count = 0 THEN 'Every active flat was already billed for this month.'
                    ELSE v_count || ' flat' || CASE WHEN v_count = 1 THEN '' ELSE 's' END
                         || ' billed, ' || to_char(v_total, 'FM999,999,990.00') || ' added.'
               END;

  -- Any flat carrying an advance settles the new month immediately.
  FOR f IN SELECT DISTINCT flat_id FROM bms.payments WHERE status = 'ACTIVE' LOOP
    PERFORM bms.allocate_flat_advance(f.flat_id);
  END LOOP;

  RETURN run;
END $$;

-- ---------------------------------------------------------------------
-- OPENING BALANCE — what a flat already owed on go-live day.
-- Stored as a flat_charges row dated the month before go-live, so all the
-- normal arithmetic applies to it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_opening_balance(
    p_flat uuid, p_amount bms.money_amount, p_year int, p_month int)
RETURNS bms.flat_charges
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE run bms.charge_runs; fc bms.flat_charges; v_paid numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('charges','edit');
  IF p_amount < 0 THEN RAISE EXCEPTION 'Opening balance cannot be negative'; END IF;

  SELECT * INTO run FROM bms.charge_runs
   WHERE period_year = p_year AND period_month = p_month AND run_type = 'OPENING';
  IF NOT FOUND THEN
    INSERT INTO bms.charge_runs(period_year, period_month, run_type, generated_by,
                                notes)
    VALUES (p_year, p_month, 'OPENING', auth.uid(),
            'Opening balances carried in at go-live')
    RETURNING * INTO run;
  END IF;

  SELECT * INTO fc FROM bms.flat_charges
   WHERE flat_id = p_flat AND period_year = p_year AND period_month = p_month
     AND charge_source = 'OPENING';

  IF FOUND THEN
    SELECT COALESCE(SUM(amount),0) INTO v_paid
      FROM bms.payment_allocations WHERE flat_charge_id = fc.id;
    IF v_paid > 0 THEN
      RAISE EXCEPTION 'This opening balance has already been paid against and cannot be changed';
    END IF;
    UPDATE bms.flat_charges SET charge_amount = p_amount WHERE id = fc.id RETURNING * INTO fc;
    DELETE FROM bms.charge_line_items WHERE flat_charge_id = fc.id;
  ELSE
    INSERT INTO bms.flat_charges(run_id, flat_id, period_year, period_month,
                                 charge_source, charge_amount, due_date)
    VALUES (run.id, p_flat, p_year, p_month, 'OPENING', p_amount,
            make_date(p_year, p_month, 28))
    RETURNING * INTO fc;
  END IF;

  INSERT INTO bms.charge_line_items(flat_charge_id, label, kind, amount, sort_order)
  VALUES (fc.id, 'Balance brought forward', 'OPENING', p_amount, 1);

  UPDATE bms.charge_runs cr
     SET flat_count   = (SELECT COUNT(*)            FROM bms.flat_charges WHERE run_id = cr.id),
         total_amount = (SELECT COALESCE(SUM(charge_amount),0) FROM bms.flat_charges WHERE run_id = cr.id)
   WHERE cr.id = run.id;

  PERFORM bms.allocate_flat_advance(p_flat);
  RETURN fc;
END $$;

-- ---------------------------------------------------------------------
-- RECORD A PAYMENT — one atomic operation.
-- payment row -> allocate oldest first -> post INCOME -> receipt number.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.record_payment(
    p_flat uuid, p_amount bms.money_amount, p_date date, p_method text,
    p_account uuid, p_reference text DEFAULT NULL, p_notes text DEFAULT NULL,
    p_payer_name text DEFAULT NULL)
RETURNS bms.payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  pay bms.payments; t bms.transactions; s bms.building_settings;
  v_dept uuid; v_cat uuid; v_flat_no text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF bms.period_is_closed(p_date) THEN RAISE EXCEPTION 'That accounting period is closed'; END IF;

  SELECT flat_number INTO v_flat_no FROM bms.flats WHERE id = p_flat;
  IF v_flat_no IS NULL THEN RAISE EXCEPTION 'Flat not found'; END IF;
  SELECT * INTO s FROM bms.building_settings WHERE id;

  INSERT INTO bms.payments(receipt_no, flat_id, payer_name, payment_date, amount,
                           method, account_id, reference_no, notes, received_by)
  VALUES (bms.next_doc_no('RECEIPT', EXTRACT(YEAR FROM p_date)::int, COALESCE(s.receipt_prefix,'RCT')),
          p_flat, p_payer_name, p_date, p_amount, p_method, p_account, p_reference, p_notes, auth.uid())
  RETURNING * INTO pay;

  PERFORM bms.allocate_flat_advance(p_flat);

  -- Money received is income, and posts immediately: collecting a service
  -- charge is not a spend that needs a second person's approval.
  SELECT id INTO v_dept FROM bms.departments WHERE code = 'SERVICE_CHARGE';
  SELECT id INTO v_cat  FROM bms.categories
    WHERE department_id = v_dept AND name = 'Monthly service charge' LIMIT 1;

  INSERT INTO bms.transactions(
      txn_date, direction, department_id, category_id, description, amount,
      payment_method, account_id, flat_id, reference_no, status, created_by,
      source_module, source_ref)
  VALUES (p_date, 'INCOME', v_dept, v_cat,
          'Service charge received — flat ' || v_flat_no || ' (' || pay.receipt_no || ')',
          p_amount, p_method, p_account, p_flat, p_reference, 'DRAFT', auth.uid(),
          'charges', pay.id)
  RETURNING * INTO t;

  UPDATE bms.transactions SET status = 'APPROVED', approved_by = NULL, approved_at = now()
   WHERE id = t.id;
  t := bms.post_transaction(t.id);

  UPDATE bms.payments SET txn_id = t.id WHERE id = pay.id RETURNING * INTO pay;
  RETURN pay;
END $$;

-- Reverse a payment: undo its allocations, reverse its income transaction,
-- and re-run allocation so later payments settle the freed-up charges.
CREATE OR REPLACE FUNCTION bms.reverse_payment(p_payment uuid, p_reason text)
RETURNS bms.payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE pay bms.payments;
BEGIN
  PERFORM bms.assert_perm('charges','cancel');
  IF COALESCE(btrim(p_reason),'') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO pay FROM bms.payments WHERE id = p_payment FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF pay.status = 'REVERSED' THEN RAISE EXCEPTION 'That payment is already reversed'; END IF;

  DELETE FROM bms.payment_allocations WHERE payment_id = pay.id;

  IF pay.txn_id IS NOT NULL THEN
    PERFORM bms.reverse_transaction(pay.txn_id, 'Payment reversed: ' || p_reason);
  END IF;

  UPDATE bms.payments SET status = 'REVERSED', reversal_reason = p_reason
   WHERE id = pay.id RETURNING * INTO pay;

  PERFORM bms.allocate_flat_advance(pay.flat_id);
  RETURN pay;
END $$;

-- ---------------------------------------------------------------------
-- WAIVERS AND ADJUSTMENTS — requested by one person, approved by another.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.request_adjustment(
    p_charge uuid, p_type text, p_amount bms.money_amount, p_reason text)
RETURNS bms.adjustments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE a bms.adjustments; v_flat uuid; v_net numeric(14,2); v_paid numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF COALESCE(btrim(p_reason),'') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;

  SELECT flat_id, net_payable INTO v_flat, v_net FROM bms.flat_charges WHERE id = p_charge;
  IF v_flat IS NULL THEN RAISE EXCEPTION 'Charge not found'; END IF;

  IF p_type IN ('WAIVER','DISCOUNT') THEN
    SELECT COALESCE(SUM(amount),0) INTO v_paid
      FROM bms.payment_allocations WHERE flat_charge_id = p_charge;
    IF p_amount > v_net - v_paid THEN
      RAISE EXCEPTION 'Cannot waive % — only % is still outstanding on that charge',
        p_amount, v_net - v_paid;
    END IF;
  END IF;

  INSERT INTO bms.adjustments(flat_id, flat_charge_id, adj_type, amount, reason, requested_by)
  VALUES (v_flat, p_charge, p_type, p_amount, p_reason, auth.uid())
  RETURNING * INTO a;
  RETURN a;
END $$;

CREATE OR REPLACE FUNCTION bms.approve_adjustment(p_adj uuid)
RETURNS bms.adjustments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE a bms.adjustments; v_allow_self boolean;
BEGIN
  PERFORM bms.assert_perm('charges','waive');
  SELECT * INTO a FROM bms.adjustments WHERE id = p_adj FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Adjustment not found'; END IF;
  IF a.status <> 'PENDING' THEN RAISE EXCEPTION 'That adjustment is already %', a.status; END IF;

  IF a.requested_by = auth.uid() THEN
    SELECT allow_self_approval INTO v_allow_self FROM bms.building_settings WHERE id;
    IF NOT COALESCE(v_allow_self, false) THEN
      RAISE EXCEPTION 'You cannot approve a waiver you requested yourself' USING ERRCODE = '42501';
    END IF;
  END IF;

  UPDATE bms.adjustments SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now()
   WHERE id = a.id RETURNING * INTO a;

  PERFORM bms.allocate_flat_advance(a.flat_id);
  RETURN a;
END $$;

CREATE OR REPLACE FUNCTION bms.reject_adjustment(p_adj uuid, p_reason text)
RETURNS bms.adjustments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE a bms.adjustments;
BEGIN
  PERFORM bms.assert_perm('charges','waive');
  UPDATE bms.adjustments
     SET status = 'REJECTED', rejected_reason = p_reason,
         approved_by = auth.uid(), approved_at = now()
   WHERE id = p_adj AND status = 'PENDING'
  RETURNING * INTO a;
  IF NOT FOUND THEN RAISE EXCEPTION 'That adjustment is not pending'; END IF;
  RETURN a;
END $$;
