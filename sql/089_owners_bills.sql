-- =====================================================================
-- 089_owners_bills.sql — land owners with several flats, temporary rates,
-- one payment and one receipt for many flats, and the monthly bill.
--
-- PART 1 — TEMPORARY RATES
-- A flat still under construction, or let at a concession for a while,
-- pays a different amount for a stated run of months and then goes back
-- to its normal rate by itself. The rate in force is decided in one
-- place, flat_rate_for(), and the monthly generation uses it, so the
-- month's bill line says why it is different.
--
-- PART 2 — ONE PAYMENT, SEVERAL FLATS
-- A land owner pays one sum for his flats. It is recorded as one payment
-- per flat — so every flat's statement, dues and receipts stay exactly
-- right — tied together as a payment group with its own receipt number,
-- and printed as one receipt listing each flat. Reversing the group
-- reverses each part.
--
-- PART 3 — OWNER ACCOUNTS
-- For any person: every flat he owns, which are rented and to whom, who
-- pays each one, its rate, and his total monthly charge and dues across
-- the flats billed to him.
--
-- PART 4 — THE MONTHLY BILL
-- At the start of each month every payer is sent one bill: each flat he
-- pays for, this month's charge, anything still owed from before, the
-- total and the date it is due (charge_due_day, normally the 10th). The
-- wording lives in Settings; every bill sent is recorded.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- PART 1 — temporary rates
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.flat_rate_overrides (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_id       uuid NOT NULL REFERENCES bms.flats(id) ON DELETE CASCADE,
  from_month    date NOT NULL CHECK (from_month = date_trunc('month', from_month)::date),
  to_month      date CHECK (to_month IS NULL OR to_month = date_trunc('month', to_month)::date),
  amount        bms.money_amount NOT NULL CHECK (amount >= 0),
  reason        text NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 200),
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid REFERENCES auth.users(id),
  cancelled_at  timestamptz,
  cancelled_by  uuid REFERENCES auth.users(id),
  cancel_reason text,
  CONSTRAINT rate_override_range_ck CHECK (to_month IS NULL OR to_month >= from_month)
);
CREATE INDEX IF NOT EXISTS rate_override_flat_idx ON bms.flat_rate_overrides(flat_id, from_month);

ALTER TABLE bms.flat_rate_overrides ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.flat_rate_overrides FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.flat_rate_overrides TO authenticated;
DROP POLICY IF EXISTS rate_overrides_sel ON bms.flat_rate_overrides;
CREATE POLICY rate_overrides_sel ON bms.flat_rate_overrides FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view') OR bms.has_perm('flats','view'));
DROP TRIGGER IF EXISTS trg_audit_rate_overrides ON bms.flat_rate_overrides;
CREATE TRIGGER trg_audit_rate_overrides AFTER INSERT OR UPDATE ON bms.flat_rate_overrides
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('charges', 'reason', 'HIGH');

-- The rate in force for a flat in a given month.
CREATE OR REPLACE FUNCTION bms.flat_rate_for(p_flat uuid, p_month date)
RETURNS TABLE (amount numeric(14,2), source text, reason text, until date, override_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT COALESCE(o.amount, f.service_charge, s.default_service_charge, 0)::numeric(14,2),
         CASE WHEN o.id IS NOT NULL THEN 'TEMPORARY'
              WHEN f.service_charge IS NOT NULL THEN 'FLAT' ELSE 'DEFAULT' END,
         o.reason, o.to_month, o.id
    FROM bms.flats f
    CROSS JOIN bms.building_settings s
    LEFT JOIN LATERAL (
      SELECT x.* FROM bms.flat_rate_overrides x
       WHERE x.flat_id = f.id AND x.cancelled_at IS NULL
         AND x.from_month <= date_trunc('month', p_month)::date
         AND (x.to_month IS NULL OR x.to_month >= date_trunc('month', p_month)::date)
       ORDER BY x.from_month DESC LIMIT 1) o ON true
   WHERE f.id = p_flat AND s.id;
$$;
REVOKE ALL ON FUNCTION bms.flat_rate_for(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.flat_rate_for(uuid, date) TO authenticated;

CREATE OR REPLACE FUNCTION bms.set_temporary_rate(
    p_flat uuid, p_from date, p_to date, p_amount bms.money_amount, p_reason text)
RETURNS bms.flat_rate_overrides
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.flat_rate_overrides; v_from date; v_to date; v_flat text; v_billed date;
BEGIN
  PERFORM bms.assert_perm('charges','edit');
  SELECT flat_number INTO v_flat FROM bms.flats WHERE id = p_flat;
  IF v_flat IS NULL THEN RAISE EXCEPTION 'Flat not found'; END IF;
  IF p_from IS NULL THEN RAISE EXCEPTION 'Say from which month the rate applies'; END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'The rate cannot be negative'; END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why (for example: under construction)'; END IF;
  v_from := date_trunc('month', p_from)::date;
  v_to   := CASE WHEN p_to IS NULL THEN NULL ELSE date_trunc('month', p_to)::date END;
  IF v_to IS NOT NULL AND v_to < v_from THEN RAISE EXCEPTION 'The last month is before the first'; END IF;

  -- A month already billed keeps its bill; changing it is a waiver.
  SELECT make_date(fc.period_year, fc.period_month, 1) INTO v_billed
    FROM bms.flat_charges fc
   WHERE fc.flat_id = p_flat AND fc.charge_source = 'MONTHLY' AND NOT fc.is_cancelled
     AND make_date(fc.period_year, fc.period_month, 1) >= v_from
     AND (v_to IS NULL OR make_date(fc.period_year, fc.period_month, 1) <= v_to)
   ORDER BY 1 LIMIT 1;
  IF v_billed IS NOT NULL THEN
    RAISE EXCEPTION 'Flat % is already billed for %. Start the rate from the month after, and use a waiver for months already billed.',
      v_flat, to_char(v_billed, 'FMMonth YYYY');
  END IF;

  IF EXISTS (SELECT 1 FROM bms.flat_rate_overrides x
              WHERE x.flat_id = p_flat AND x.cancelled_at IS NULL
                AND x.from_month <= COALESCE(v_to, 'infinity'::date)
                AND COALESCE(x.to_month, 'infinity'::date) >= v_from) THEN
    RAISE EXCEPTION 'Flat % already has a temporary rate for some of those months. Cancel that one first.', v_flat;
  END IF;

  INSERT INTO bms.flat_rate_overrides(flat_id, from_month, to_month, amount, reason, created_by)
  VALUES (p_flat, v_from, v_to, p_amount, btrim(p_reason), auth.uid())
  RETURNING * INTO r;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION bms.cancel_temporary_rate(p_id uuid, p_reason text)
RETURNS bms.flat_rate_overrides
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.flat_rate_overrides;
BEGIN
  PERFORM bms.assert_perm('charges','edit');
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why it is being cancelled'; END IF;
  UPDATE bms.flat_rate_overrides
     SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = btrim(p_reason)
   WHERE id = p_id AND cancelled_at IS NULL
  RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'That temporary rate does not exist or is already cancelled'; END IF;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION bms.set_temporary_rate(uuid,date,date,bms.money_amount,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.cancel_temporary_rate(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.set_temporary_rate(uuid,date,date,bms.money_amount,text) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.cancel_temporary_rate(uuid,text) TO authenticated;

-- Monthly generation, now using the rate in force for each flat.
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
  v_rate    record;
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
    -- A temporary rate for this month (a flat under construction, say)
    -- wins over the flat's own rate, which wins over the building default.
    SELECT r.amount, r.source, r.reason INTO v_rate
      FROM bms.flat_rate_for(f.id, make_date(p_year, p_month, 1)) r;
    v_amount := v_rate.amount;

    INSERT INTO bms.flat_charges(run_id, flat_id, period_year, period_month,
                                 charge_source, charge_amount, due_date)
    VALUES (run.id, f.id, p_year, p_month, 'MONTHLY', v_amount, v_due)
    RETURNING id INTO v_charge;

    INSERT INTO bms.charge_line_items(flat_charge_id, label, kind, amount, sort_order)
    VALUES (v_charge,
            CASE WHEN v_rate.source = 'TEMPORARY'
                 THEN 'Monthly service charge (temporary rate: ' || v_rate.reason || ')'
                 ELSE 'Monthly service charge' END,
            'SERVICE', v_amount, 10);

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
-- PART 2 — one payment, several flats
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.payment_groups (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_no       text NOT NULL UNIQUE,
  payer_owner_id uuid REFERENCES bms.owners(id) ON DELETE RESTRICT,
  payer_name     text,
  payment_date   date NOT NULL,
  total_amount   bms.money_amount NOT NULL CHECK (total_amount > 0),
  method         text NOT NULL,
  account_id     uuid NOT NULL REFERENCES bms.accounts(id) ON DELETE RESTRICT,
  reference_no   text,
  notes          text,
  received_by    uuid REFERENCES auth.users(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE bms.payments ADD COLUMN IF NOT EXISTS group_id uuid REFERENCES bms.payment_groups(id);
CREATE INDEX IF NOT EXISTS payments_group_idx ON bms.payments(group_id) WHERE group_id IS NOT NULL;

ALTER TABLE bms.payment_groups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.payment_groups FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.payment_groups TO authenticated;
DROP POLICY IF EXISTS payment_groups_sel ON bms.payment_groups;
CREATE POLICY payment_groups_sel ON bms.payment_groups FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view'));
DROP TRIGGER IF EXISTS trg_payment_groups_no_delete ON bms.payment_groups;
CREATE TRIGGER trg_payment_groups_no_delete BEFORE DELETE ON bms.payment_groups
  FOR EACH ROW EXECUTE FUNCTION bms.block_delete();
DROP TRIGGER IF EXISTS trg_audit_payment_groups ON bms.payment_groups;
CREATE TRIGGER trg_audit_payment_groups AFTER INSERT ON bms.payment_groups
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('charges', 'group_no', 'HIGH');

-- A combined receipt can carry its proof of payment, like a single one.
DO $$ BEGIN
  ALTER TABLE bms.attachments DROP CONSTRAINT IF EXISTS attachments_entity_ck;
  ALTER TABLE bms.attachments ADD CONSTRAINT attachments_entity_ck CHECK (entity_table IN
    ('transactions','issues','issue_updates','asset_service_logs','asset_inspections',
     'assets','staff','salary_payments','fixed_deposits','bank_statements','work_logs',
     'work_log_items','payments','flats','fuel_purchases','generator_runs','staff_advances',
     'funds','fund_movements','reconciliations','payment_groups'));
END $$;
DROP POLICY IF EXISTS attachments_payments_sel ON bms.attachments;
DROP POLICY IF EXISTS attachments_payments_ins ON bms.attachments;
CREATE POLICY attachments_payments_sel ON bms.attachments FOR SELECT TO authenticated
  USING (entity_table IN ('payments','payment_groups') AND bms.has_perm('charges','view'));
CREATE POLICY attachments_payments_ins ON bms.attachments FOR INSERT TO authenticated
  WITH CHECK (entity_table IN ('payments','payment_groups') AND bms.has_perm('charges','add'));

-- p_lines: [{"flat": "<uuid>", "amount": 5000}, ...] — one line per flat.
CREATE OR REPLACE FUNCTION bms.record_group_payment(
    p_owner uuid, p_lines jsonb, p_date date, p_method text, p_account uuid,
    p_reference text DEFAULT NULL, p_notes text DEFAULT NULL, p_payer_name text DEFAULT NULL)
RETURNS bms.payment_groups
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE g bms.payment_groups; l record; pay bms.payments; s bms.building_settings;
        v_total numeric(14,2); v_n int; v_name text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one flat to the payment';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric)
              WHERE x.flat IS NULL OR x.amount IS NULL OR x.amount <= 0) THEN
    RAISE EXCEPTION 'Every flat in the payment needs an amount greater than zero';
  END IF;
  IF (SELECT COUNT(*) - COUNT(DISTINCT x.flat) FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric)) > 0 THEN
    RAISE EXCEPTION 'The same flat appears twice in the payment';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric)
              WHERE NOT EXISTS (SELECT 1 FROM bms.flats f WHERE f.id = x.flat)) THEN
    RAISE EXCEPTION 'Flat not found';
  END IF;
  IF p_owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM bms.owners WHERE id = p_owner) THEN
    RAISE EXCEPTION 'That person is not on record';
  END IF;

  SELECT SUM(round(x.amount, 2)), COUNT(*) INTO v_total, v_n
    FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric);
  v_name := COALESCE(NULLIF(btrim(p_payer_name), ''), (SELECT name FROM bms.owners WHERE id = p_owner));
  SELECT * INTO s FROM bms.building_settings WHERE id;

  INSERT INTO bms.payment_groups(group_no, payer_owner_id, payer_name, payment_date, total_amount,
                                 method, account_id, reference_no, notes, received_by)
  VALUES (bms.next_doc_no('RECEIPT_GROUP', EXTRACT(YEAR FROM p_date)::int, COALESCE(s.receipt_prefix, 'RCT') || '-G'),
          p_owner, v_name, p_date, v_total, p_method, p_account, p_reference, p_notes, auth.uid())
  RETURNING * INTO g;

  FOR l IN SELECT x.flat, round(x.amount, 2) AS amount
             FROM jsonb_to_recordset(p_lines) x(flat uuid, amount numeric)
             JOIN bms.flats f ON f.id = x.flat
            ORDER BY f.floor, f.flat_number LOOP
    pay := bms.record_payment(l.flat, l.amount, p_date, p_method, p_account, p_reference,
                              trim(BOTH ' ' FROM COALESCE(p_notes, '') || ' [part of ' || g.group_no || ']'), v_name);
    UPDATE bms.payments SET group_id = g.id WHERE id = pay.id;
  END LOOP;
  RETURN g;
END $$;

CREATE OR REPLACE FUNCTION bms.reverse_group_payment(p_group uuid, p_reason text)
RETURNS bms.payment_groups
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE g bms.payment_groups; p record; v_n int := 0;
BEGIN
  PERFORM bms.assert_perm('charges','cancel');
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;
  SELECT * INTO g FROM bms.payment_groups WHERE id = p_group;
  IF NOT FOUND THEN RAISE EXCEPTION 'Combined receipt not found'; END IF;
  FOR p IN SELECT id FROM bms.payments WHERE group_id = p_group AND status = 'ACTIVE' LOOP
    PERFORM bms.reverse_payment(p.id, 'Combined receipt ' || g.group_no || ' reversed: ' || btrim(p_reason));
    v_n := v_n + 1;
  END LOOP;
  IF v_n = 0 THEN RAISE EXCEPTION 'Every payment on that receipt is already reversed'; END IF;
  RETURN g;
END $$;
REVOKE ALL ON FUNCTION bms.record_group_payment(uuid,jsonb,date,text,uuid,text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.reverse_group_payment(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.record_group_payment(uuid,jsonb,date,text,uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.reverse_group_payment(uuid,text) TO authenticated;

CREATE OR REPLACE VIEW bms.v_payment_groups WITH (security_invoker = true) AS
SELECT g.id, g.group_no, g.payer_owner_id, g.payer_name, g.payment_date, g.total_amount,
       g.method, g.account_id, g.reference_no, g.notes, g.received_by, g.created_at,
       COUNT(p.id)                                                   AS flat_count,
       COUNT(p.id) FILTER (WHERE p.status = 'ACTIVE')                AS active_count,
       COALESCE(SUM(p.amount) FILTER (WHERE p.status = 'ACTIVE'), 0)::numeric(14,2) AS active_total,
       string_agg(f.flat_number, ', ' ORDER BY f.floor, f.flat_number) AS flat_list,
       CASE WHEN COUNT(p.id) FILTER (WHERE p.status = 'ACTIVE') = COUNT(p.id) THEN 'ACTIVE'
            WHEN COUNT(p.id) FILTER (WHERE p.status = 'ACTIVE') = 0       THEN 'REVERSED'
            ELSE 'PARTLY_REVERSED' END                                AS status
  FROM bms.payment_groups g
  LEFT JOIN bms.payments p ON p.group_id = g.id
  LEFT JOIN bms.flats    f ON f.id = p.flat_id
 GROUP BY g.id;
REVOKE ALL ON bms.v_payment_groups FROM PUBLIC, anon;
GRANT SELECT ON bms.v_payment_groups TO authenticated;

-- ---------------------------------------------------------------------
-- PART 3 — owner accounts
-- ---------------------------------------------------------------------
-- One row per person and flat: every flat a person owns, and every flat
-- billed to them (a tenant who pays included).
CREATE OR REPLACE FUNCTION bms.owner_flats(p_owner uuid DEFAULT NULL)
RETURNS TABLE (owner_id uuid, owner_name text, owner_mobile text,
               flat_id uuid, flat_number text, floor int, flat_status text,
               is_owner boolean, pays boolean, payer_id uuid, payer_name text, payer_relation text,
               tenant_name text, current_rate numeric(14,2), rate_source text, rate_reason text,
               rate_until date, outstanding numeric(14,2), advance numeric(14,2), last_payment_date date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM bms.assert_perm('charges','view');
  RETURN QUERY
  SELECT o.id, o.name, o.mobile, f.id, f.flat_number, f.floor, f.status,
         (occ.relation_type = 'OWNER'), COALESCE(bill.owner_id = o.id, false),
         bill.owner_id, bp.name, bill.relation_type,
         ten.name, r.amount, r.source, r.reason, r.until,
         COALESCE(d.outstanding, 0)::numeric(14,2), COALESCE(d.advance, 0)::numeric(14,2), d.last_payment_date
    FROM bms.owners o
    JOIN bms.flat_occupancy occ ON occ.owner_id = o.id AND occ.to_date IS NULL
                               AND (occ.relation_type = 'OWNER' OR occ.is_billed)
    JOIN bms.flats f ON f.id = occ.flat_id
    LEFT JOIN LATERAL (SELECT fo.owner_id, fo.relation_type FROM bms.flat_occupancy fo
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) bill ON true
    LEFT JOIN bms.owners bp ON bp.id = bill.owner_id
    LEFT JOIN LATERAL (SELECT ow.name FROM bms.flat_occupancy fo JOIN bms.owners ow ON ow.id = fo.owner_id
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.relation_type = 'TENANT' LIMIT 1) ten ON true
    LEFT JOIN LATERAL bms.flat_rate_for(f.id, CURRENT_DATE) r ON true
    LEFT JOIN bms.v_flat_dues d ON d.flat_id = f.id
   WHERE p_owner IS NULL OR o.id = p_owner
   ORDER BY o.name, f.floor, f.flat_number;
END $$;

-- One row per person: what they own and what they pay, all flats together.
CREATE OR REPLACE FUNCTION bms.owner_accounts()
RETURNS TABLE (owner_id uuid, owner_name text, owner_mobile text,
               flats_owned int, flats_rented_out int, flats_paid int, flats_owing int,
               monthly_total numeric(14,2), outstanding numeric(14,2), advance numeric(14,2),
               last_payment_date date, owned_list text, paid_list text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT x.owner_id, x.owner_name, x.owner_mobile,
         COUNT(*) FILTER (WHERE x.is_owner)::int,
         COUNT(*) FILTER (WHERE x.is_owner AND x.tenant_name IS NOT NULL)::int,
         COUNT(*) FILTER (WHERE x.pays)::int,
         COUNT(*) FILTER (WHERE x.pays AND x.outstanding > 0)::int,
         COALESCE(SUM(x.current_rate) FILTER (WHERE x.pays AND x.flat_status = 'ACTIVE'), 0)::numeric(14,2),
         COALESCE(SUM(x.outstanding) FILTER (WHERE x.pays), 0)::numeric(14,2),
         COALESCE(SUM(x.advance) FILTER (WHERE x.pays), 0)::numeric(14,2),
         MAX(x.last_payment_date) FILTER (WHERE x.pays),
         string_agg(x.flat_number, ', ' ORDER BY x.floor, x.flat_number) FILTER (WHERE x.is_owner),
         string_agg(x.flat_number, ', ' ORDER BY x.floor, x.flat_number) FILTER (WHERE x.pays)
    FROM bms.owner_flats(NULL) x
   GROUP BY x.owner_id, x.owner_name, x.owner_mobile
   ORDER BY COUNT(*) FILTER (WHERE x.pays) DESC, x.owner_name;
$$;
REVOKE ALL ON FUNCTION bms.owner_flats(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.owner_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.owner_flats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.owner_accounts() TO authenticated;

-- ---------------------------------------------------------------------
-- PART 4 — the monthly bill
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.default_bill_template(p_lang text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_lang = 'bn' THEN
$t$সম্মানিত {name},
{building} — {month} মাসের সার্ভিস চার্জ বিল

{lines}

মোট পরিশোধযোগ্য: {total} টাকা
অনুগ্রহ করে {due_date}-এর মধ্যে পরিশোধ করুন।
{how_to_pay}

ইতোমধ্যে পরিশোধ করে থাকলে ধন্যবাদ — এই বার্তাটি উপেক্ষা করুন।
— {building} ব্যবস্থাপনা কমিটি$t$
  ELSE
$t$Dear {name},
Service charge bill for {month} — {building}

{lines}

Total payable: Tk {total}
Please pay by {due_date}.
{how_to_pay}

If you have already paid, thank you — please ignore this message.
— {building} Management$t$
  END;
$$;

ALTER TABLE bms.building_settings
  ADD COLUMN IF NOT EXISTS bill_template_en text,
  ADD COLUMN IF NOT EXISTS bill_template_bn text;
UPDATE bms.building_settings SET bill_template_en = bms.default_bill_template('en')
 WHERE id AND bill_template_en IS NULL;
UPDATE bms.building_settings SET bill_template_bn = bms.default_bill_template('bn')
 WHERE id AND bill_template_bn IS NULL;

CREATE TABLE IF NOT EXISTS bms.bill_notices (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_id        uuid NOT NULL REFERENCES bms.flats(id) ON DELETE CASCADE,
  period_year    int  NOT NULL,
  period_month   int  NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  sent_at        timestamptz NOT NULL DEFAULT now(),
  sent_by        uuid REFERENCES auth.users(id),
  channel        text NOT NULL CHECK (channel IN ('WHATSAPP','SMS','COPY','IMAGE','PDF','PRINT')),
  recipient_name text,
  phone          text,
  amount_due     bms.money_amount,
  message        text NOT NULL
);
CREATE INDEX IF NOT EXISTS bill_notices_period_idx ON bms.bill_notices(period_year, period_month, flat_id);

ALTER TABLE bms.bill_notices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.bill_notices FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.bill_notices TO authenticated;
DROP POLICY IF EXISTS bill_notices_sel ON bms.bill_notices;
CREATE POLICY bill_notices_sel ON bms.bill_notices FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view'));
DROP TRIGGER IF EXISTS trg_bill_notices_no_delete ON bms.bill_notices;
CREATE TRIGGER trg_bill_notices_no_delete BEFORE DELETE ON bms.bill_notices
  FOR EACH ROW EXECUTE FUNCTION bms.block_delete();

-- Every flat's bill for a month: this month's charge, what is still owed
-- from before, the total, and who it goes to.
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
         GREATEST(COALESCE(d.outstanding, 0) - COALESCE(fc.due_amount, 0), 0)::numeric(14,2),
         COALESCE(d.outstanding, 0)::numeric(14,2),
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
    LEFT JOIN LATERAL (SELECT fo.owner_id, fo.relation_type FROM bms.flat_occupancy fo
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) bill ON true
    LEFT JOIN bms.owners bp ON bp.id = bill.owner_id
    LEFT JOIN LATERAL bms.flat_rate_for(f.id, make_date(p_year, p_month, 1)) r ON true
    LEFT JOIN LATERAL (SELECT MAX(b.sent_at) AS last_sent, COUNT(*) AS n FROM bms.bill_notices b
                        WHERE b.flat_id = f.id AND b.period_year = p_year AND b.period_month = p_month) bn ON true
   WHERE s.id AND (f.status = 'ACTIVE' OR COALESCE(d.outstanding, 0) > 0)
   ORDER BY bp.name NULLS LAST, f.floor, f.flat_number;
END $$;

-- Record that a bill went out — one row per flat on it.
-- p_flats is a JSON list of flat ids: ["…","…"]. (JSON rather than uuid[]
-- because that is what the app sends, the same way for every RPC.)
DROP FUNCTION IF EXISTS bms.log_bill_notice(uuid[], int, int, text, text);
CREATE OR REPLACE FUNCTION bms.log_bill_notice(p_flats jsonb, p_year int, p_month int, p_channel text, p_message text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_n int; v_ids uuid[];
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_flats IS NOT NULL AND jsonb_typeof(p_flats) = 'array' THEN
    SELECT array_agg(x::uuid) INTO v_ids FROM jsonb_array_elements_text(p_flats) x;
  END IF;
  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN RAISE EXCEPTION 'No flats on the bill'; END IF;
  IF COALESCE(btrim(p_message), '') = '' THEN RAISE EXCEPTION 'The bill is empty'; END IF;
  INSERT INTO bms.bill_notices(flat_id, period_year, period_month, sent_by, channel,
                               recipient_name, phone, amount_due, message)
  SELECT f.id, p_year, p_month, auth.uid(), p_channel, bp.name, bp.mobile, COALESCE(d.outstanding, 0), p_message
    FROM bms.flats f
    LEFT JOIN LATERAL (SELECT fo.owner_id FROM bms.flat_occupancy fo
                        WHERE fo.flat_id = f.id AND fo.to_date IS NULL AND fo.is_billed LIMIT 1) bill ON true
    LEFT JOIN bms.owners bp ON bp.id = bill.owner_id
    LEFT JOIN bms.v_flat_dues d ON d.flat_id = f.id
   WHERE f.id = ANY(v_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'Flat not found'; END IF;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION bms.month_bills(int,int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.log_bill_notice(jsonb,int,int,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.default_bill_template(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.month_bills(int,int) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.log_bill_notice(jsonb,int,int,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.default_bill_template(text) TO authenticated;
