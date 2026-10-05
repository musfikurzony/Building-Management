-- =====================================================================
-- 088_storage_setup.sql — the places pictures and documents are kept.
--
-- WHAT WENT WRONG
-- ---------------
-- A receipt photo attached to an expense goes to a storage "bucket"
-- called bms-receipts. The setup guide asked for the three buckets to be
-- created by hand in the Supabase dashboard; on the live project they
-- never were, so every upload answered "Bucket not found" — after the
-- expense itself had already been saved, with no way to attach the
-- picture afterwards.
--
-- This file creates them, so there is no dashboard step to forget:
--   bms-receipts   receipts, invoices, payment proofs   images + PDF, 10 MB
--   bms-photos     maintenance and work photos          images, 10 MB
--   bms-documents  contracts, certificates, the rules   PDF, Word, images, 20 MB
-- All three PRIVATE. If one was ever made public by mistake, running
-- this makes it private again: a receipt is opened through a link that
-- expires in minutes, never through a permanent public address.
--
-- It also lets the people who record service-charge payments attach a
-- proof of payment (a bKash screenshot, a deposit slip) to the payment,
-- and lets an attachment be taken down — kept, marked removed, with a
-- reason — rather than deleted. Evidence is never destroyed.
-- =====================================================================

SET search_path = bms, public;

DO $outer$
BEGIN
  IF to_regclass('storage.buckets') IS NULL THEN
    RAISE NOTICE 'No storage schema here — skipping bucket creation.';
    RETURN;
  END IF;
  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
    ('bms-receipts',  'bms-receipts',  false, 10485760,
       ARRAY['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf']),
    ('bms-photos',    'bms-photos',    false, 10485760,
       ARRAY['image/jpeg','image/png','image/webp','image/heic','image/heif']),
    ('bms-documents', 'bms-documents', false, 20971520,
       ARRAY['application/pdf','image/jpeg','image/png','image/webp',
             'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
  ON CONFLICT (id) DO UPDATE
    SET public = false,
        file_size_limit = EXCLUDED.file_size_limit,
        allowed_mime_types = EXCLUDED.allowed_mime_types;

  -- A file you attached yourself you can always open — the caretaker who
  -- photographs a receipt has no sight of the ledger, but should see the
  -- picture he just took. Matched through the attachment record, so it
  -- works whichever owner columns this Supabase version keeps.
  EXECUTE 'DROP POLICY IF EXISTS "bms-receipts_own_read" ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "bms-photos_own_read" ON storage.objects';
  EXECUTE $sql$
    CREATE POLICY "bms-receipts_own_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-receipts' AND EXISTS (
        SELECT 1 FROM bms.attachments a
         WHERE a.bucket = 'bms-receipts' AND a.storage_path = storage.objects.name AND a.uploaded_by = auth.uid()));
  $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-photos_own_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-photos' AND EXISTS (
        SELECT 1 FROM bms.attachments a
         WHERE a.bucket = 'bms-photos' AND a.storage_path = storage.objects.name AND a.uploaded_by = auth.uid()));
  $sql$;
END $outer$;

-- ---------------------------------------------------------------------
-- Proof of payment on a service-charge payment. The general attachment
-- rules belong to Finance; whoever records payments may not have
-- Finance, so a payment's own attachments follow the Service Charge
-- permissions as well.
-- ---------------------------------------------------------------------
-- Whoever attached a file can always see it — a caretaker who photographs
-- the receipt for an expense he submitted, without Finance, included.
DROP POLICY IF EXISTS attachments_own_sel ON bms.attachments;
CREATE POLICY attachments_own_sel ON bms.attachments FOR SELECT TO authenticated
  USING (uploaded_by = auth.uid() AND bms.is_active_user());

DROP POLICY IF EXISTS attachments_payments_sel ON bms.attachments;
DROP POLICY IF EXISTS attachments_payments_ins ON bms.attachments;
CREATE POLICY attachments_payments_sel ON bms.attachments FOR SELECT TO authenticated
  USING (entity_table = 'payments' AND bms.has_perm('charges','view'));
CREATE POLICY attachments_payments_ins ON bms.attachments FOR INSERT TO authenticated
  WITH CHECK (entity_table = 'payments' AND bms.has_perm('charges','add'));

-- ---------------------------------------------------------------------
-- Taking an attachment down. The row stays, the file stays; it is only
-- marked removed, by whom, when and why, so a wrong photo can be
-- corrected without anyone being able to make a real receipt vanish.
-- Allowed to whoever may cancel finance entries, and to the person who
-- attached it, on the same day (the "I picked the wrong photo" case).
-- ---------------------------------------------------------------------
ALTER TABLE bms.attachments ADD COLUMN IF NOT EXISTS deleted_reason   text;
ALTER TABLE bms.attachments ADD COLUMN IF NOT EXISTS uploaded_by_name text;
ALTER TABLE bms.attachments ADD COLUMN IF NOT EXISTS deleted_by_name  text;

CREATE OR REPLACE FUNCTION bms.remove_attachment(p_id uuid, p_reason text)
RETURNS bms.attachments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE a bms.attachments;
BEGIN
  SELECT * INTO a FROM bms.attachments WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Attachment not found'; END IF;
  IF a.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'This attachment has already been removed'; END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why it is being removed'; END IF;
  IF NOT (bms.has_perm('finance','cancel')
          OR (a.uploaded_by = auth.uid() AND a.uploaded_at > now() - interval '1 day')) THEN
    RAISE EXCEPTION 'permission denied: only someone who can cancel finance entries may remove an attachment after the day it was added';
  END IF;
  UPDATE bms.attachments
     SET deleted_at = now(), deleted_by = auth.uid(), deleted_reason = btrim(p_reason),
         deleted_by_name = bms.actor_name()
   WHERE id = p_id
  RETURNING * INTO a;
  RETURN a;
END $$;
REVOKE ALL ON FUNCTION bms.remove_attachment(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.remove_attachment(uuid, text) TO authenticated;

-- Who attached it and when, set by the database (the app does not send
-- it, and must not be trusted to). This is what shows a receipt that was
-- added weeks after the entry as exactly that.
CREATE OR REPLACE FUNCTION bms.attachment_stamp() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  NEW.uploaded_by := COALESCE(auth.uid(), NEW.uploaded_by);
  NEW.uploaded_by_name := COALESCE(bms.actor_name(), NEW.uploaded_by_name);
  NEW.uploaded_at := now();
  NEW.deleted_at := NULL; NEW.deleted_by := NULL;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_attachment_stamp ON bms.attachments;
CREATE TRIGGER trg_attachment_stamp BEFORE INSERT ON bms.attachments
  FOR EACH ROW EXECUTE FUNCTION bms.attachment_stamp();
