-- =====================================================================
-- 090_storage.sql — access policies for the three private buckets.
--
-- The buckets themselves are created by 088_storage_setup.sql (private,
-- with size and file-type limits), so there is nothing to do by hand in
-- the Supabase dashboard any more.
--
-- The LPG Ledger's own `meter-photos` bucket is not mentioned anywhere
-- in this file and is left exactly as it is.
-- =====================================================================

-- Supabase keeps objects in storage.objects, with the bucket in bucket_id.
-- These policies decide who may read, write and remove them; the app then
-- hands out short-lived signed URLs rather than public links.

-- The whole file is a no-op where there is no storage schema (the local
-- test database), so it can sit in the same migration sequence.
DO $outer$
DECLARE b text;
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'No storage schema here — skipping bucket policies.';
    RETURN;
  END IF;

  FOREACH b IN ARRAY ARRAY['bms-receipts','bms-photos','bms-documents'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_read');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_write');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_delete');
  END LOOP;

  -- Receipts and invoices: anyone who may see the ledger may see them,
  -- and whoever records service-charge payments may attach and see a
  -- payment's proof (a bKash screenshot, a bank deposit slip).
  EXECUTE $sql$
    CREATE POLICY "bms-receipts_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-receipts' AND (bms.has_perm('finance','view') OR bms.has_perm('charges','view')));
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-receipts_write" ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'bms-receipts' AND (bms.has_perm('finance','add') OR bms.has_perm('charges','add')));
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-receipts_delete" ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'bms-receipts' AND bms.has_perm('finance','cancel'));
    $sql$;

  -- Photos: maintenance, work and asset pictures.
  EXECUTE $sql$
    CREATE POLICY "bms-photos_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-photos' AND bms.is_active_user());
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-photos_write" ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'bms-photos' AND bms.is_active_user());
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-photos_delete" ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'bms-photos' AND bms.has_perm('maintenance','cancel'));
    $sql$;

  -- Documents: contracts, licences, FD certificates, minutes.
  EXECUTE $sql$
    CREATE POLICY "bms-documents_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-documents' AND bms.has_perm('bank','view_sensitive'));
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-documents_write" ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'bms-documents' AND bms.has_perm('bank','view_sensitive'));
    $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-documents_delete" ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'bms-documents' AND bms.has_perm('settings','edit'));
    $sql$;
END $outer$;
