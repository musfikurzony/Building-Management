-- =====================================================================
-- t12 — receipts, photos and documents: where they are kept, and who
-- may put them there, open them and take them down.
--
-- The local shim recreates Supabase's storage.buckets and storage.objects,
-- so the bucket set-up and every storage policy below run exactly as they
-- will on Supabase. An "upload" here is the row Supabase writes into
-- storage.objects, attempted as each role.
-- =====================================================================
SET t.suite = 't12 storage';
SET search_path = bms, public;

-- A resident, and a collector who may record service charge but has no Finance.
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000b1','resident@test'),
  ('00000000-0000-0000-0000-0000000000b2','collector@test') ON CONFLICT DO NOTHING;
INSERT INTO bms.user_profiles (user_id, full_name, email, is_active) VALUES
  ('00000000-0000-0000-0000-0000000000b1','Flat Resident','resident@test',true),
  ('00000000-0000-0000-0000-0000000000b2','Charge Collector','collector@test',true) ON CONFLICT DO NOTHING;
INSERT INTO bms.roles (code, name, description, is_system, is_superuser, approve_limit, auto_post_limit, sort_order)
VALUES ('COLLECTOR','Collector','Records service charge only.', false, false, 0, 0, 95) ON CONFLICT DO NOTHING;
INSERT INTO bms.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM bms.roles r, bms.permissions p
 WHERE r.code = 'COLLECTOR' AND p.module_code = 'charges' AND p.action IN ('view','add') ON CONFLICT DO NOTHING;
INSERT INTO bms.user_roles (user_id, role_id)
SELECT '00000000-0000-0000-0000-0000000000b1', id FROM bms.roles WHERE code = 'RESIDENT' ON CONFLICT DO NOTHING;
INSERT INTO bms.user_roles (user_id, role_id)
SELECT '00000000-0000-0000-0000-0000000000b2', id FROM bms.roles WHERE code = 'COLLECTOR' ON CONFLICT DO NOTHING;
SELECT t.remember('resident',  '00000000-0000-0000-0000-0000000000b1');
SELECT t.remember('collector', '00000000-0000-0000-0000-0000000000b2');

-- ---------------------------------------------------------------------
-- 1. THE BUCKETS.
-- ---------------------------------------------------------------------
SELECT t.eq('all three buckets exist', 3::bigint,
  (SELECT COUNT(*) FROM storage.buckets WHERE id IN ('bms-receipts','bms-photos','bms-documents')));
SELECT t.eq('and every one is private', 0::bigint,
  (SELECT COUNT(*) FROM storage.buckets WHERE id LIKE 'bms-%' AND public));
SELECT t.eq('receipts are limited to 10 MB', 10485760::bigint, (SELECT file_size_limit FROM storage.buckets WHERE id = 'bms-receipts'));
SELECT t.ok('receipts take photos and PDFs', (SELECT allowed_mime_types @> ARRAY['image/jpeg','application/pdf'] FROM storage.buckets WHERE id = 'bms-receipts'));
SELECT t.ok('documents take Word files too', (SELECT 'application/msword' = ANY(allowed_mime_types) FROM storage.buckets WHERE id = 'bms-documents'));

UPDATE storage.buckets SET public = true WHERE id = 'bms-receipts';
\ir ../088_storage_setup.sql
SELECT t.eq('a bucket made public by mistake is made private again', false,
  (SELECT public FROM storage.buckets WHERE id = 'bms-receipts'));

-- A transaction to attach things to.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.remember('txn', (SELECT (bms.create_transaction(CURRENT_DATE, 'EXPENSE',
  (SELECT id FROM bms.departments WHERE code = 'CLEANING'),
  (SELECT id FROM bms.categories WHERE name = 'Cleaning supplies'), 'Brooms', 100, 'CASH', NULL)).id::text));
SELECT t.remember('pay', (SELECT (bms.record_payment((SELECT id FROM bms.flats WHERE flat_number = 'A-101'), 5000, CURRENT_DATE,
  'BKASH', t.uid('acct_bank'), 'TRX1', NULL, NULL)).id::text));

-- ---------------------------------------------------------------------
-- 2. WHO MAY UPLOAD A RECEIPT.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.runs('the caretaker can upload a receipt photo', $$
  INSERT INTO storage.objects (bucket_id, name) VALUES ('bms-receipts', '2026/10/transactions/x/caretaker.jpg') $$);
SELECT t.runs('and record it against the expense', $$
  INSERT INTO bms.attachments (bucket, storage_path, entity_table, entity_id, file_name, mime_type, size_bytes, uploaded_by)
  VALUES ('bms-receipts', '2026/10/transactions/x/caretaker.jpg', 'transactions', t.uid('txn'), 'brooms.jpg', 'image/jpeg', 2048,
          t.uid('admin')) $$);
SELECT t.eq('the database records who really attached it, whatever the app sent', 'Caretaker',
  (SELECT uploaded_by_name FROM bms.attachments WHERE file_name = 'brooms.jpg'));
SELECT t.eq('by id as well', t.uid('caretaker'), (SELECT uploaded_by FROM bms.attachments WHERE file_name = 'brooms.jpg'));
SELECT t.eq('the caretaker, who cannot see the ledger, can still open the photo he attached', 1::bigint,
  (SELECT COUNT(*) FROM storage.objects WHERE bucket_id = 'bms-receipts' AND name = '2026/10/transactions/x/caretaker.jpg'));

SELECT set_config('request.jwt.claim.sub', t.recall('resident'), false);
SELECT t.throws('a resident cannot upload into the receipts', $$
  INSERT INTO storage.objects (bucket_id, name) VALUES ('bms-receipts', 'sneaky.jpg') $$);
SELECT t.eq('nor see any receipt', 0::bigint, (SELECT COUNT(*) FROM storage.objects WHERE bucket_id = 'bms-receipts'));
SELECT t.eq('nor read the attachment list', 0::bigint, (SELECT COUNT(*) FROM bms.attachments));

SELECT set_config('request.jwt.claim.sub', t.recall('committee'), false);
SELECT t.eq('a committee member can see the receipts', 1::bigint, (SELECT COUNT(*) FROM storage.objects WHERE bucket_id = 'bms-receipts'));
SELECT t.throws('but cannot upload', $$
  INSERT INTO storage.objects (bucket_id, name) VALUES ('bms-receipts', 'committee.jpg') $$);

-- ---------------------------------------------------------------------
-- 3. PROOF OF PAYMENT, BY SOMEONE WHO ONLY COLLECTS SERVICE CHARGE.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('collector'), false);
SELECT t.runs('a collector can upload a bKash screenshot', $$
  INSERT INTO storage.objects (bucket_id, name) VALUES ('bms-receipts', '2026/10/payments/x/bkash.png') $$);
SELECT t.runs('and attach it to the payment', $$
  INSERT INTO bms.attachments (bucket, storage_path, entity_table, entity_id, file_name, mime_type, size_bytes)
  VALUES ('bms-receipts', '2026/10/payments/x/bkash.png', 'payments', t.uid('pay'), 'bkash.png', 'image/png', 4096) $$);
SELECT t.throws('but not to a finance entry', $$
  INSERT INTO bms.attachments (bucket, storage_path, entity_table, entity_id, file_name, mime_type, size_bytes)
  VALUES ('bms-receipts', 'x/y.png', 'transactions', t.uid('txn'), 'y.png', 'image/png', 1) $$);
SELECT t.eq('sees the payment''s proof', 1::bigint, (SELECT COUNT(*) FROM bms.attachments WHERE entity_table = 'payments'));
SELECT t.eq('and not the finance receipts', 0::bigint, (SELECT COUNT(*) FROM bms.attachments WHERE entity_table = 'transactions'));

-- ---------------------------------------------------------------------
-- 4. THE RULES DOCUMENTS.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
INSERT INTO storage.objects (bucket_id, name) VALUES ('bms-documents', 'community/doc1/rules.pdf'),
                                                     ('bms-documents', '2026/10/fixed_deposits/fd1/certificate.pdf');
SELECT set_config('request.jwt.claim.sub', t.recall('resident'), false);
SELECT t.eq('a resident can open the building rules', 1::bigint,
  (SELECT COUNT(*) FROM storage.objects WHERE bucket_id = 'bms-documents' AND name = 'community/doc1/rules.pdf'));
SELECT t.eq('but not a deposit certificate in the same bucket', 0::bigint,
  (SELECT COUNT(*) FROM storage.objects WHERE name LIKE '%certificate%'));
SELECT t.throws('nor upload a document', $$
  INSERT INTO storage.objects (bucket_id, name) VALUES ('bms-documents', 'community/mine.pdf') $$);

-- ---------------------------------------------------------------------
-- 5. TAKING AN ATTACHMENT DOWN — WITHOUT DESTROYING IT.
-- ---------------------------------------------------------------------
RESET ROLE;
SELECT t.remember('att_brooms', (SELECT id::text FROM bms.attachments WHERE file_name = 'brooms.jpg'));
SELECT t.remember('att_bkash',  (SELECT id::text FROM bms.attachments WHERE file_name = 'bkash.png'));
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.eq('the caretaker can see the receipt he attached to his expense', 1::bigint,
  (SELECT COUNT(*) FROM bms.attachments WHERE file_name = 'brooms.jpg'));
SELECT t.throws('a reason is required', $$
  SELECT bms.remove_attachment(t.uid('att_brooms'), '  ') $$, 'Say why');
SELECT t.runs('the caretaker can take down his own wrong photo the same day', $$
  SELECT bms.remove_attachment(t.uid('att_brooms'), 'Wrong photo') $$);
SELECT t.eq('it is marked removed, with the reason and by whom', 'Wrong photo/Caretaker',
  (SELECT deleted_reason || '/' || deleted_by_name FROM bms.attachments WHERE file_name = 'brooms.jpg'));
SELECT t.throws('it cannot be removed twice', $$
  SELECT bms.remove_attachment(t.uid('att_brooms'), 'Again') $$, 'already been removed');
SELECT t.throws('nor can he remove someone else''s', $$
  SELECT bms.remove_attachment(t.uid('att_bkash'), 'Not mine') $$, 'permission denied');

RESET ROLE;
UPDATE bms.attachments SET deleted_at = NULL, deleted_by = NULL, deleted_reason = NULL, deleted_by_name = NULL,
       uploaded_at = now() - interval '3 days' WHERE file_name = 'brooms.jpg';
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('after the day it was added, the caretaker can no longer remove it', $$
  SELECT bms.remove_attachment(t.uid('att_brooms'), 'Late') $$, 'permission denied');

SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.runs('the finance manager can', $$
  SELECT bms.remove_attachment(t.uid('att_brooms'), 'Duplicate of the invoice') $$);
SELECT t.throws('nobody can delete an attachment record outright', $$
  DELETE FROM bms.attachments WHERE file_name = 'bkash.png' $$, 'permission denied');
SELECT t.eq('attaching and removing are both in the audit log', 2::bigint,
  (SELECT COUNT(DISTINCT action) FROM bms.audit_log WHERE entity_table = 'attachments' AND entity_label = 'brooms.jpg'));

RESET ROLE;
