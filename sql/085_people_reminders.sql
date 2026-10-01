-- =====================================================================
-- 085_people_reminders.sql — who lives in a flat, who pays for it, and
-- reminding them when they have not.
--
-- PART 1 — OWNERS AND TENANTS
-- ---------------------------
-- A flat has an owner. It may also have a tenant. Exactly one of them
-- receives the service-charge bill. In this building that is often the
-- tenant: owners who live elsewhere let the flat, and the tenant pays the
-- building directly.
--
-- The table always allowed that (flat_occupancy keeps owner and tenant
-- rows side by side; the only rule is one CURRENT BILLED person per flat).
-- The screen did not. Linking a tenant through "Add owner" closed the
-- currently billed row — the owner's — by setting its to_date. The owner
-- then no longer owned the flat as far as the system was concerned, and
-- vanished from it. Moving the bill and ending an ownership are different
-- events, so they are now different functions, and every change happens
-- inside one transaction so the flat is never briefly billed to nobody.
--
-- PART 2 — REMINDERS
-- ------------------
-- A record of every time someone was asked to pay: who asked, when, to
-- which number, for how much, and the exact words. The app opens WhatsApp
-- (or SMS) with the message filled in; it cannot see whether Send was then
-- tapped, so a row here means "a reminder was prepared and handed to
-- WhatsApp", which is as much as a browser can honestly know.
--
-- Rows are never edited or deleted. A history you can rewrite is not a
-- history — and the count is what tells you how many times a flat has
-- been chased.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Settings that belong to reminders.
-- ---------------------------------------------------------------------
ALTER TABLE bms.building_settings
  ADD COLUMN IF NOT EXISTS reminder_how_to_pay    text,
  ADD COLUMN IF NOT EXISTS reminder_language      text NOT NULL DEFAULT 'en',
  ADD COLUMN IF NOT EXISTS reminder_deadline_days int  NOT NULL DEFAULT 7;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bs_reminder_language_ck') THEN
    ALTER TABLE bms.building_settings
      ADD CONSTRAINT bs_reminder_language_ck CHECK (reminder_language IN ('en','bn'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bs_reminder_deadline_ck') THEN
    ALTER TABLE bms.building_settings
      ADD CONSTRAINT bs_reminder_deadline_ck CHECK (reminder_deadline_days BETWEEN 1 AND 60);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- A phone number as WhatsApp wants it: digits only, country code first.
--
-- People type numbers every possible way — "01913469117", "+880 1913-
-- 469117", "008801913469117" — and an owner who lives abroad and lets the
-- flat has a foreign number. NULL means "this is not a number we can send
-- to", which the screen turns into a sentence rather than a broken link.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.normalize_mobile(p text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = bms, public, pg_temp AS $$
DECLARE v text; intl boolean := false;
BEGIN
  v := regexp_replace(COALESCE(p, ''), '[\s\-\(\)\.]', '', 'g');
  IF v = '' THEN RETURN NULL; END IF;

  IF v ~ '^\+' THEN v := substr(v, 2); intl := true;
  ELSIF v ~ '^00' THEN v := substr(v, 3); intl := true;
  END IF;
  IF v !~ '^[0-9]+$' THEN RETURN NULL; END IF;

  IF NOT intl THEN
    -- Bangladeshi mobiles: 013-019, eleven digits with the leading zero.
    IF v ~ '^01[3-9][0-9]{8}$'   THEN RETURN '88' || v; END IF;
    IF v ~ '^1[3-9][0-9]{8}$'    THEN RETURN '880' || v; END IF;
    IF v ~ '^8801[3-9][0-9]{8}$' THEN RETURN v; END IF;
    RETURN NULL;
  END IF;

  -- Written with a country code. A Bangladeshi one must still be a real
  -- mobile; anything else is taken as given if it is plausibly long.
  IF v ~ '^880' THEN
    RETURN CASE WHEN v ~ '^8801[3-9][0-9]{8}$' THEN v END;
  END IF;
  IF length(v) BETWEEN 8 AND 15 AND v !~ '^0' THEN RETURN v; END IF;
  RETURN NULL;
END $$;

-- =====================================================================
-- PART 1 — OWNERS AND TENANTS
-- =====================================================================

-- One row per flat: its current owner, its current tenant, and which of
-- them pays. The screens read this rather than re-deriving it.
CREATE OR REPLACE VIEW bms.v_flat_people WITH (security_invoker = true) AS
SELECT f.id AS flat_id, f.flat_number, f.floor, f.status AS flat_status,
       o.occupancy_id AS owner_occupancy_id, o.person_id AS owner_id,
       o.name AS owner_name, o.mobile AS owner_mobile, o.email AS owner_email,
       o.from_date AS owner_since, COALESCE(o.is_billed, false) AS owner_billed,
       t.occupancy_id AS tenant_occupancy_id, t.person_id AS tenant_id,
       t.name AS tenant_name, t.mobile AS tenant_mobile, t.email AS tenant_email,
       t.from_date AS tenant_since, COALESCE(t.is_billed, false) AS tenant_billed,
       CASE WHEN t.is_billed THEN 'TENANT' WHEN o.is_billed THEN 'OWNER' END AS billed_relation
  FROM bms.flats f
  LEFT JOIN LATERAL (
    SELECT fo.id AS occupancy_id, ow.id AS person_id, ow.name, ow.mobile, ow.email,
           fo.from_date, fo.is_billed
      FROM bms.flat_occupancy fo JOIN bms.owners ow ON ow.id = fo.owner_id
     WHERE fo.flat_id = f.id AND fo.relation_type = 'OWNER' AND fo.to_date IS NULL
     ORDER BY fo.from_date DESC, fo.created_at DESC LIMIT 1) o ON true
  LEFT JOIN LATERAL (
    SELECT fo.id AS occupancy_id, ow.id AS person_id, ow.name, ow.mobile, ow.email,
           fo.from_date, fo.is_billed
      FROM bms.flat_occupancy fo JOIN bms.owners ow ON ow.id = fo.owner_id
     WHERE fo.flat_id = f.id AND fo.relation_type = 'TENANT' AND fo.to_date IS NULL
     ORDER BY fo.from_date DESC, fo.created_at DESC LIMIT 1) t ON true;

REVOKE ALL ON bms.v_flat_people FROM PUBLIC, anon;
GRANT SELECT ON bms.v_flat_people TO authenticated;

-- Resolve "an existing person, or these details for a new one" to an id.
-- Shared by the owner and tenant functions so a person is never half-made.
CREATE OR REPLACE FUNCTION bms._person_for(
    p_person uuid, p_name text, p_mobile text, p_email text, p_alt text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  IF p_person IS NOT NULL THEN
    SELECT id INTO v_id FROM bms.owners WHERE id = p_person;
    IF NOT FOUND THEN RAISE EXCEPTION 'That person no longer exists'; END IF;
    RETURN v_id;
  END IF;
  IF COALESCE(btrim(p_name), '') = '' THEN
    RAISE EXCEPTION 'A name is needed';
  END IF;
  INSERT INTO bms.owners (name, mobile, email, alt_contact, created_by)
  VALUES (btrim(p_name), NULLIF(btrim(COALESCE(p_mobile,'')),''),
          NULLIF(btrim(COALESCE(p_email,'')),''), NULLIF(btrim(COALESCE(p_alt,'')),''),
          auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION bms._person_for(uuid,text,text,text,text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- The flat changes hands.
--
-- The previous owner's row is closed, not deleted, so the history of who
-- owned the flat survives. If the old owner was paying, the new one pays;
-- if a tenant is paying, the tenant carries on paying.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_flat_owner(
    p_flat uuid, p_person uuid DEFAULT NULL,
    p_name text DEFAULT NULL, p_mobile text DEFAULT NULL,
    p_email text DEFAULT NULL, p_alt text DEFAULT NULL,
    p_from date DEFAULT CURRENT_DATE)
RETURNS bms.flat_occupancy
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE cur bms.flat_occupancy; r bms.flat_occupancy; v_person uuid;
        v_billed boolean;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  PERFORM 1 FROM bms.flats WHERE id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;

  v_person := bms._person_for(p_person, p_name, p_mobile, p_email, p_alt);

  SELECT * INTO cur FROM bms.flat_occupancy
   WHERE flat_id = p_flat AND relation_type = 'OWNER' AND to_date IS NULL
   ORDER BY from_date DESC LIMIT 1;

  IF FOUND AND cur.owner_id = v_person THEN
    RETURN cur;                                   -- already the owner
  END IF;

  IF EXISTS (SELECT 1 FROM bms.flat_occupancy
              WHERE flat_id = p_flat AND relation_type = 'TENANT'
                AND to_date IS NULL AND owner_id = v_person) THEN
    RAISE EXCEPTION 'That person is the current tenant. End the tenancy first, then make them the owner.';
  END IF;

  -- The new owner pays if the old owner was paying, or if nobody is.
  v_billed := COALESCE(cur.is_billed, false)
              OR NOT EXISTS (SELECT 1 FROM bms.flat_occupancy
                              WHERE flat_id = p_flat AND to_date IS NULL AND is_billed);

  IF cur.id IS NOT NULL THEN
    UPDATE bms.flat_occupancy
       SET to_date = GREATEST(COALESCE(p_from, CURRENT_DATE) - 1, from_date),
           is_billed = false
     WHERE id = cur.id;
  END IF;

  INSERT INTO bms.flat_occupancy (flat_id, owner_id, relation_type, is_billed, from_date)
  VALUES (p_flat, v_person, 'OWNER', v_billed, COALESCE(p_from, CURRENT_DATE))
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- A tenant moves in.
--
-- The owner stays the owner. If the tenant is to pay (the usual case, and
-- the default), the bill moves to them; the owner's row is untouched apart
-- from no longer being the billed one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_flat_tenant(
    p_flat uuid, p_person uuid DEFAULT NULL,
    p_name text DEFAULT NULL, p_mobile text DEFAULT NULL,
    p_email text DEFAULT NULL, p_alt text DEFAULT NULL,
    p_from date DEFAULT CURRENT_DATE, p_billed boolean DEFAULT true)
RETURNS bms.flat_occupancy
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE cur bms.flat_occupancy; r bms.flat_occupancy; v_person uuid;
        v_billed boolean := COALESCE(p_billed, true);
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  PERFORM 1 FROM bms.flats WHERE id = p_flat;
  IF NOT FOUND THEN RAISE EXCEPTION 'That flat does not exist'; END IF;

  v_person := bms._person_for(p_person, p_name, p_mobile, p_email, p_alt);

  IF EXISTS (SELECT 1 FROM bms.flat_occupancy
              WHERE flat_id = p_flat AND relation_type = 'OWNER'
                AND to_date IS NULL AND owner_id = v_person) THEN
    RAISE EXCEPTION 'That person is the owner of this flat, so they cannot also be its tenant.';
  END IF;

  SELECT * INTO cur FROM bms.flat_occupancy
   WHERE flat_id = p_flat AND relation_type = 'TENANT' AND to_date IS NULL
   ORDER BY from_date DESC LIMIT 1;

  IF FOUND AND cur.owner_id = v_person THEN
    -- Same tenant: only the billing choice can have changed.
    PERFORM bms.set_billed_party(p_flat, CASE WHEN v_billed THEN 'TENANT' ELSE 'OWNER' END);
    SELECT * INTO r FROM bms.flat_occupancy WHERE id = cur.id;
    RETURN r;
  END IF;

  -- A flat with no owner on record has nobody else to bill.
  IF NOT v_billed AND NOT EXISTS (SELECT 1 FROM bms.flat_occupancy
       WHERE flat_id = p_flat AND relation_type = 'OWNER' AND to_date IS NULL) THEN
    v_billed := true;
  END IF;

  IF cur.id IS NOT NULL THEN
    UPDATE bms.flat_occupancy
       SET to_date = GREATEST(COALESCE(p_from, CURRENT_DATE) - 1, from_date),
           is_billed = false
     WHERE id = cur.id;
  END IF;

  IF v_billed THEN
    -- Release the bill first: at most one current billed row per flat is
    -- enforced by a unique index, checked row by row.
    UPDATE bms.flat_occupancy SET is_billed = false
     WHERE flat_id = p_flat AND to_date IS NULL AND is_billed;
  END IF;

  INSERT INTO bms.flat_occupancy (flat_id, owner_id, relation_type, is_billed, from_date)
  VALUES (p_flat, v_person, 'TENANT', v_billed, COALESCE(p_from, CURRENT_DATE))
  RETURNING * INTO r;

  -- Nobody billed is not a state a flat should be left in.
  IF NOT EXISTS (SELECT 1 FROM bms.flat_occupancy
                  WHERE flat_id = p_flat AND to_date IS NULL AND is_billed) THEN
    UPDATE bms.flat_occupancy SET is_billed = true WHERE id = r.id RETURNING * INTO r;
  END IF;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- The tenant moves out. The bill goes back to the owner.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.end_tenancy(p_flat uuid, p_to date DEFAULT CURRENT_DATE)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE cur bms.flat_occupancy;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  SELECT * INTO cur FROM bms.flat_occupancy
   WHERE flat_id = p_flat AND relation_type = 'TENANT' AND to_date IS NULL
   ORDER BY from_date DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'This flat has no current tenant'; END IF;

  UPDATE bms.flat_occupancy
     SET to_date = GREATEST(COALESCE(p_to, CURRENT_DATE), from_date), is_billed = false
   WHERE id = cur.id;

  IF NOT EXISTS (SELECT 1 FROM bms.flat_occupancy
                  WHERE flat_id = p_flat AND to_date IS NULL AND is_billed) THEN
    UPDATE bms.flat_occupancy SET is_billed = true
     WHERE id = (SELECT id FROM bms.flat_occupancy
                  WHERE flat_id = p_flat AND relation_type = 'OWNER' AND to_date IS NULL
                  ORDER BY from_date DESC LIMIT 1);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Change who pays, without anybody moving.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_billed_party(p_flat uuid, p_relation text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_target uuid;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  IF p_relation NOT IN ('OWNER','TENANT') THEN
    RAISE EXCEPTION 'Billed party must be OWNER or TENANT';
  END IF;
  SELECT id INTO v_target FROM bms.flat_occupancy
   WHERE flat_id = p_flat AND relation_type = p_relation AND to_date IS NULL
   ORDER BY from_date DESC LIMIT 1;
  IF v_target IS NULL THEN
    RAISE EXCEPTION 'This flat has no current %', lower(p_relation);
  END IF;
  UPDATE bms.flat_occupancy SET is_billed = false
   WHERE flat_id = p_flat AND to_date IS NULL AND is_billed AND id <> v_target;
  UPDATE bms.flat_occupancy SET is_billed = true WHERE id = v_target;
END $$;

REVOKE ALL ON FUNCTION bms.set_flat_owner(uuid,uuid,text,text,text,text,date)          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.set_flat_tenant(uuid,uuid,text,text,text,text,date,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.end_tenancy(uuid,date)                                      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.set_billed_party(uuid,text)                                 FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.set_flat_owner(uuid,uuid,text,text,text,text,date)          TO authenticated;
GRANT EXECUTE ON FUNCTION bms.set_flat_tenant(uuid,uuid,text,text,text,text,date,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.end_tenancy(uuid,date)                                      TO authenticated;
GRANT EXECUTE ON FUNCTION bms.set_billed_party(uuid,text)                                 TO authenticated;

-- =====================================================================
-- PART 2 — REMINDERS
-- =====================================================================

-- ---------------------------------------------------------------------
-- The wording. Three tones, two languages, all editable from Settings.
--
-- default_body is the wording as shipped, kept beside the edited one so
-- "Restore the original" always has something to restore. Re-running this
-- file refreshes default_body but NEVER touches body: running an update
-- must not quietly throw away wording someone spent an evening on.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.reminder_templates (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tone          text NOT NULL CHECK (tone IN ('GENTLE','FOLLOW_UP','FIRM')),
  lang          text NOT NULL CHECK (lang IN ('en','bn')),
  body          text NOT NULL CHECK (length(btrim(body)) > 0 AND length(body) <= 2000),
  default_body  text NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid REFERENCES auth.users(id),
  UNIQUE (tone, lang)
);

INSERT INTO bms.reminder_templates (tone, lang, body, default_body)
SELECT tone, lang, txt, txt FROM (VALUES
('GENTLE','en', $t$Dear {name},
A gentle reminder from {building} management: the service charge for Flat {flat} is due.

Amount due: Tk {amount} ({months})

If you have already paid, please ignore this message. Otherwise, we would be grateful if you could pay at your convenience.
{how_to_pay}

Thank you for your cooperation.
— {building} Management$t$),
('GENTLE','bn', $t$সম্মানিত {name},
{building} ব্যবস্থাপনা কমিটির পক্ষ থেকে বিনীত অনুস্মারক: ফ্ল্যাট {flat}-এর সার্ভিস চার্জ বকেয়া রয়েছে।

বকেয়া: {amount} টাকা ({months})

ইতোমধ্যে পরিশোধ করে থাকলে এই বার্তাটি উপেক্ষা করুন। অন্যথায় সুবিধামতো সময়ে পরিশোধ করলে কৃতজ্ঞ থাকব।
{how_to_pay}

আপনার সহযোগিতার জন্য ধন্যবাদ।
— {building} ব্যবস্থাপনা কমিটি$t$),
('FOLLOW_UP','en', $t$Dear {name},
Following up on our earlier reminder, the service charge for Flat {flat} is still outstanding.

Outstanding: Tk {amount} ({months})

We would be grateful if you could clear it at your earliest convenience. If anything is making this difficult, please let us know; we are happy to talk it through.
{how_to_pay}

Thank you.
— {building} Management$t$),
('FOLLOW_UP','bn', $t$সম্মানিত {name},
আগের বার্তার ধারাবাহিকতায় জানাচ্ছি যে, ফ্ল্যাট {flat}-এর সার্ভিস চার্জ এখনো বকেয়া রয়েছে।

বকেয়া: {amount} টাকা ({months})

যত দ্রুত সম্ভব পরিশোধ করলে কৃতজ্ঞ থাকব। কোনো অসুবিধা থাকলে অনুগ্রহ করে জানাবেন — আমরা আলোচনা করতে আগ্রহী।
{how_to_pay}

ধন্যবাদ।
— {building} ব্যবস্থাপনা কমিটি$t$),
('FIRM','en', $t$Dear {name},
Despite our previous reminders, the service charge for Flat {flat} remains outstanding.

Outstanding: Tk {amount} ({months})

This charge pays for what every resident shares: security, cleaning, the lift, the generator and utilities. We kindly ask you to settle it by {deadline}, or contact the management to arrange payment in instalments.
{how_to_pay}

Thank you for your understanding.
— {building} Management$t$),
('FIRM','bn', $t$সম্মানিত {name},
একাধিকবার স্মরণ করিয়ে দেওয়ার পরও ফ্ল্যাট {flat}-এর সার্ভিস চার্জ এখনো বকেয়া রয়েছে।

বকেয়া: {amount} টাকা ({months})

এই চার্জ থেকেই ভবনের সকলের সাধারণ খরচ — নিরাপত্তা, পরিচ্ছন্নতা, লিফট, জেনারেটর ও ইউটিলিটি — বহন করা হয়। অনুগ্রহ করে {deadline}-এর মধ্যে পরিশোধ করুন, অথবা কিস্তিতে পরিশোধের জন্য ব্যবস্থাপনা কমিটির সাথে যোগাযোগ করুন।
{how_to_pay}

আপনার সহযোগিতার জন্য ধন্যবাদ।
— {building} ব্যবস্থাপনা কমিটি$t$)
) AS v(tone, lang, txt)
ON CONFLICT (tone, lang) DO UPDATE SET default_body = EXCLUDED.default_body;

CREATE OR REPLACE FUNCTION bms.reminder_template_touch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  -- Only the stamp. Which columns a user may change is decided by the
  -- column-level grant below (body and nothing else); a trigger doing the
  -- same job would also stop this file refreshing default_body whenever
  -- the session happened to carry a user id.
  NEW.updated_at := now();
  NEW.updated_by := COALESCE(auth.uid(), NEW.updated_by);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_reminder_template_touch ON bms.reminder_templates;
CREATE TRIGGER trg_reminder_template_touch BEFORE UPDATE ON bms.reminder_templates
  FOR EACH ROW EXECUTE FUNCTION bms.reminder_template_touch();

ALTER TABLE bms.reminder_templates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.reminder_templates FROM PUBLIC, anon;
GRANT SELECT ON bms.reminder_templates TO authenticated;
GRANT UPDATE (body) ON bms.reminder_templates TO authenticated;
DROP POLICY IF EXISTS reminder_templates_sel ON bms.reminder_templates;
DROP POLICY IF EXISTS reminder_templates_upd ON bms.reminder_templates;
CREATE POLICY reminder_templates_sel ON bms.reminder_templates FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view') OR bms.has_perm('settings','view'));
CREATE POLICY reminder_templates_upd ON bms.reminder_templates FOR UPDATE TO authenticated
  USING (bms.has_perm('settings','edit')) WITH CHECK (bms.has_perm('settings','edit'));

DROP TRIGGER IF EXISTS trg_audit_reminder_templates ON bms.reminder_templates;
CREATE TRIGGER trg_audit_reminder_templates AFTER INSERT OR UPDATE OR DELETE ON bms.reminder_templates
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('settings', 'tone', 'LOW');

-- ---------------------------------------------------------------------
-- The log.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.charge_reminders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flat_id         uuid NOT NULL REFERENCES bms.flats(id),
  sent_at         timestamptz NOT NULL DEFAULT now(),
  sent_by         uuid REFERENCES auth.users(id),
  channel         text NOT NULL CHECK (channel IN ('WHATSAPP','SMS','COPY')),
  tone            text NOT NULL CHECK (tone IN ('GENTLE','FOLLOW_UP','FIRM')),
  lang            text NOT NULL CHECK (lang IN ('en','bn')),
  -- Who was asked, as they were at that moment. If the tenant changes or
  -- the number is corrected later, the record still says who was chased.
  recipient_name  text,
  relation        text CHECK (relation IN ('OWNER','TENANT')),
  phone           text,
  phone_sent      text,
  amount_due      bms.money_amount NOT NULL,
  months          text,
  message         text NOT NULL CHECK (length(message) <= 4000)
);
CREATE INDEX IF NOT EXISTS charge_reminders_flat_idx ON bms.charge_reminders (flat_id, sent_at DESC);

ALTER TABLE bms.charge_reminders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.charge_reminders FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.charge_reminders TO authenticated;
DROP POLICY IF EXISTS charge_reminders_sel ON bms.charge_reminders;
CREATE POLICY charge_reminders_sel ON bms.charge_reminders FOR SELECT TO authenticated
  USING (bms.has_perm('charges','view'));

-- Never edited; deleted only by the system reset (block_delete() stands
-- aside for bms.purge and for nothing else).
CREATE OR REPLACE FUNCTION bms.block_reminder_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'A reminder, once recorded, cannot be changed' USING ERRCODE = '42501';
END $$;
DROP TRIGGER IF EXISTS trg_reminders_no_update ON bms.charge_reminders;
CREATE TRIGGER trg_reminders_no_update BEFORE UPDATE ON bms.charge_reminders
  FOR EACH ROW EXECUTE FUNCTION bms.block_reminder_update();
DROP TRIGGER IF EXISTS trg_reminders_no_delete ON bms.charge_reminders;
CREATE TRIGGER trg_reminders_no_delete BEFORE DELETE ON bms.charge_reminders
  FOR EACH ROW EXECUTE FUNCTION bms.block_delete();

-- One row per flat: how many times it has been chased, and how many of
-- those since it last paid — the number that decides the tone.
CREATE OR REPLACE VIEW bms.v_flat_reminders WITH (security_invoker = true) AS
WITH last_pay AS (
  SELECT flat_id, MAX(created_at) AS last_paid_at
    FROM bms.payments WHERE status = 'ACTIVE' GROUP BY flat_id
)
SELECT r.flat_id,
       COUNT(*)::int AS reminders_total,
       COUNT(*) FILTER (WHERE lp.last_paid_at IS NULL OR r.sent_at > lp.last_paid_at)::int
                     AS reminders_since_payment,
       MAX(r.sent_at) AS last_reminded_at
  FROM bms.charge_reminders r
  LEFT JOIN last_pay lp ON lp.flat_id = r.flat_id
 GROUP BY r.flat_id;
REVOKE ALL ON bms.v_flat_reminders FROM PUBLIC, anon;
GRANT SELECT ON bms.v_flat_reminders TO authenticated;

-- ---------------------------------------------------------------------
-- Everything the reminder screen needs, read fresh at the moment it opens.
--
-- Fresh matters: a list loaded an hour ago can still show a flat as unpaid
-- after someone has recorded its payment, and sending a payment reminder
-- to a person who has just paid is the one mistake this feature must not
-- make. So the figures come from here, now, not from the table on screen.
-- ---------------------------------------------------------------------
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
   WHERE flat_id = p_flat AND due_amount > 0 AND status NOT IN ('CANCELLED','WAIVED');

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

-- ---------------------------------------------------------------------
-- Record a reminder. Called as the message is handed to WhatsApp.
--
-- The amount is re-read here, not taken from the screen, and a flat that
-- owes nothing is refused: better a refused record than a log that says
-- someone was chased for money they did not owe.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.log_charge_reminder(
    p_flat uuid, p_channel text, p_tone text, p_lang text, p_message text)
RETURNS bms.charge_reminders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE d record; ppl record; r bms.charge_reminders; v_months text;
        v_name text; v_mobile text; v_rel text;
BEGIN
  PERFORM bms.assert_perm('charges','add');
  IF p_channel NOT IN ('WHATSAPP','SMS','COPY') THEN RAISE EXCEPTION 'Unknown channel %', p_channel; END IF;
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

REVOKE ALL ON FUNCTION bms.normalize_mobile(text)                         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.reminder_context(uuid)                         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text)  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.normalize_mobile(text)                        TO authenticated;
GRANT EXECUTE ON FUNCTION bms.reminder_context(uuid)                        TO authenticated;
GRANT EXECUTE ON FUNCTION bms.log_charge_reminder(uuid,text,text,text,text) TO authenticated;
