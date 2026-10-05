-- =====================================================================
-- t11 — the committee, the rules, and the backup log.
--
-- The things that matter here are who sees what: a resident sees the
-- committee and the published rules and nothing about money; a member's
-- phone number reaches nobody's browser unless the member agreed; a draft
-- is seen only by those who edit; a backup is recorded and can never be
-- unrecorded.
-- =====================================================================
SET t.suite = 't11 community & backup';
SET search_path = bms, public;

-- A resident: a flat owner with a login and the Resident role.
INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000b1', 'resident@test') ON CONFLICT DO NOTHING;
INSERT INTO bms.user_profiles (user_id, full_name, email, is_active)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'Flat Resident', 'resident@test', true) ON CONFLICT DO NOTHING;
INSERT INTO bms.user_roles (user_id, role_id)
SELECT '00000000-0000-0000-0000-0000000000b1', id FROM bms.roles WHERE code = 'RESIDENT' ON CONFLICT DO NOTHING;
SELECT t.remember('resident', '00000000-0000-0000-0000-0000000000b1');

-- ---------------------------------------------------------------------
-- 1. THE MODULE AND WHO HAS IT.
-- ---------------------------------------------------------------------
SELECT t.eq('a Committee & Rules module exists and is switched on', true,
  (SELECT is_enabled FROM bms.modules WHERE code = 'community'));
SELECT t.eq('the Resident role has exactly one permission: reading it', 'community.view',
  (SELECT string_agg(p.module_code || '.' || p.action, ',') FROM bms.role_permissions rp
     JOIN bms.roles r ON r.id = rp.role_id JOIN bms.permissions p ON p.id = rp.permission_id WHERE r.code = 'RESIDENT'));
SELECT t.eq('every built-in role can read it', 0::bigint,
  (SELECT COUNT(*) FROM bms.roles r WHERE NOT r.is_superuser AND r.code <> 'RESIDENT' AND r.is_system
      AND NOT EXISTS (SELECT 1 FROM bms.role_permissions rp JOIN bms.permissions p ON p.id = rp.permission_id
                       WHERE rp.role_id = r.id AND p.module_code = 'community' AND p.action = 'view')));

-- Re-running the file must not hand back a permission someone removed.
DELETE FROM bms.role_permissions WHERE role_id = (SELECT id FROM bms.roles WHERE code = 'CARETAKER')
   AND permission_id = (SELECT id FROM bms.permissions WHERE module_code = 'community' AND action = 'view');
\ir ../087_community_backup.sql
SELECT t.eq('re-running 087 does not re-grant a permission that was taken away', 0::bigint,
  (SELECT COUNT(*) FROM bms.role_permissions rp JOIN bms.roles r ON r.id = rp.role_id
     JOIN bms.permissions p ON p.id = rp.permission_id
    WHERE r.code = 'CARETAKER' AND p.module_code = 'community'));
INSERT INTO bms.role_permissions (role_id, permission_id)
SELECT (SELECT id FROM bms.roles WHERE code = 'CARETAKER'), id FROM bms.permissions WHERE module_code = 'community' AND action = 'view';

-- ---------------------------------------------------------------------
-- 2. THE COMMITTEE.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.runs('the chairman is added, phone kept private', $$
  INSERT INTO bms.board_members (name, position, sort_order, phone, email, show_phone, flat_id)
  VALUES ('Abdul Karim', 'Chairman', 10, '01711000099', 'karim@example.com', false,
          (SELECT id FROM bms.flats WHERE flat_number = 'A-101')) $$);
SELECT t.runs('the finance secretary is added, phone shown', $$
  INSERT INTO bms.board_members (name, position, sort_order, phone, show_phone)
  VALUES ('Nasrin Akter', 'Finance Secretary', 40, '01811000088', true) $$);
SELECT t.remember('chair', (SELECT id::text FROM bms.board_members WHERE name = 'Abdul Karim'));

SELECT t.runs('a photo can be added', $$
  INSERT INTO bms.board_member_photos (member_id, photo) VALUES (t.uid('chair'), 'data:image/jpeg;base64,/9j/4AAQSkZJRg==') $$);
SELECT t.throws('a photo must be a picture, not a link', $$
  INSERT INTO bms.board_member_photos (member_id, photo) VALUES ((SELECT id FROM bms.board_members WHERE name = 'Nasrin Akter'), 'https://example.com/x.jpg') $$);
SELECT t.throws('and cannot be enormous', $$
  INSERT INTO bms.board_member_photos (member_id, photo)
  VALUES ((SELECT id FROM bms.board_members WHERE name = 'Nasrin Akter'), 'data:image/jpeg;base64,' || repeat('A', 400001)) $$);
SELECT t.throws('a term cannot end before it starts', $$
  UPDATE bms.board_members SET term_from = '2026-05-01', term_to = '2026-01-01' WHERE id = t.uid('chair') $$);

SELECT t.eq('adding a member is in the audit log', 1::bigint,
  (SELECT COUNT(*) FROM bms.audit_log WHERE entity_table = 'board_members' AND entity_label = 'Abdul Karim' AND action = 'INSERT'));
SELECT t.eq('the photo is not copied into the audit log', 0::bigint,
  (SELECT COUNT(*) FROM bms.audit_log WHERE entity_table = 'board_member_photos'));
SELECT t.eq('the view knows the chairman has a photo', true,
  (SELECT has_photo FROM bms.v_board_members WHERE id = t.uid('chair')));
SELECT t.eq('and his flat', 'A-101', (SELECT flat_number FROM bms.v_board_members WHERE id = t.uid('chair')));
SELECT t.eq('an editor sees the private phone', '01711000099',
  (SELECT phone FROM bms.v_board_members WHERE id = t.uid('chair')));

UPDATE bms.committee_info SET title = 'Executive Committee', term = '2026 – 2028' WHERE id;
SELECT t.eq('the committee heading can be changed', 'Executive Committee', (SELECT title FROM bms.committee_info));

-- ---------------------------------------------------------------------
-- 3. RULES & DOCUMENTS.
-- ---------------------------------------------------------------------
SELECT t.runs('the building rules are published as text', $$
  INSERT INTO bms.building_documents (title, category, body, effective_date)
  VALUES ('Building rules', 'RULES', E'# General\n1. Keep the stairs clear.\n2. No parking at the gate.', '2026-01-01') $$);
SELECT t.runs('a draft notice is saved', $$
  INSERT INTO bms.building_documents (title, category, summary, is_published)
  VALUES ('Lift closure (draft)', 'NOTICE', 'The lift will be closed for servicing.', false) $$);
SELECT t.throws('a document needs some content', $$
  INSERT INTO bms.building_documents (title, category) VALUES ('Empty', 'OTHER') $$, 'document_has_content_ck');
SELECT t.throws('a file needs its name with it', $$
  INSERT INTO bms.building_documents (title, category, summary, file_path) VALUES ('Half', 'OTHER', 'x', 'community/x.pdf') $$, 'document_file_ck');
SELECT t.throws('the kind must be one of the six', $$
  INSERT INTO bms.building_documents (title, category, summary) VALUES ('Odd', 'GOSSIP', 'x') $$);
SELECT t.eq('an editor sees the draft', 2::bigint, (SELECT COUNT(*) FROM bms.building_documents));

-- ---------------------------------------------------------------------
-- 4. WHAT A RESIDENT SEES.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('resident'), false);
SELECT t.eq('a resident sees both committee members', 2::bigint, (SELECT COUNT(*) FROM bms.v_board_members));
SELECT t.eq('but not the phone the chairman kept private', NULL::text,
  (SELECT phone FROM bms.v_board_members WHERE name = 'Abdul Karim'));
SELECT t.eq('nor his email', NULL::text, (SELECT email FROM bms.v_board_members WHERE name = 'Abdul Karim'));
SELECT t.eq('and does see the phone the finance secretary chose to show', '01811000088',
  (SELECT phone FROM bms.v_board_members WHERE name = 'Nasrin Akter'));
SELECT t.eq('cannot read the members table directly (where the private phone is)', 0::bigint,
  (SELECT COUNT(*) FROM bms.board_members));
SELECT t.eq('sees the photos', 1::bigint, (SELECT COUNT(*) FROM bms.board_member_photos));
SELECT t.eq('sees the published rules but not the draft', 'Building rules',
  (SELECT string_agg(title, ',') FROM bms.building_documents));
SELECT t.eq('sees the committee heading', 'Executive Committee', (SELECT title FROM bms.committee_info));
SELECT t.eq('sees nothing of the ledger', 0::bigint, (SELECT COUNT(*) FROM bms.transactions));
SELECT t.eq('nor the flats and their dues', 0::bigint, (SELECT COUNT(*) FROM bms.flats));
SELECT t.eq('nor the owners'' phone numbers', 0::bigint, (SELECT COUNT(*) FROM bms.owners));
SELECT t.throws('cannot add a committee member', $$
  INSERT INTO bms.board_members (name, position) VALUES ('Me', 'Chairman') $$);
UPDATE bms.building_documents SET title = 'Changed by a resident' WHERE true;
SELECT t.eq('cannot change a rule', 0::bigint, (SELECT COUNT(*) FROM bms.building_documents WHERE title = 'Changed by a resident'));
UPDATE bms.committee_info SET title = 'Taken over' WHERE id;
SELECT t.eq('cannot change the committee heading', 'Executive Committee', (SELECT title FROM bms.committee_info));
SELECT t.throws('cannot download a backup', $$ SELECT bms.log_backup('ALL', NULL, NULL, 1, 1) $$);

-- A caretaker reads, and changes nothing either.
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.eq('a caretaker sees the committee', 2::bigint, (SELECT COUNT(*) FROM bms.v_board_members));
SELECT t.eq('and not a draft', 1::bigint, (SELECT COUNT(*) FROM bms.building_documents));
DELETE FROM bms.building_documents WHERE title = 'Building rules';
SELECT t.eq('and cannot delete a rule', 1::bigint, (SELECT COUNT(*) FROM bms.building_documents));

-- ---------------------------------------------------------------------
-- 5. THE BACKUP LOG.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('a full backup is recorded', $$ SELECT bms.log_backup('ALL', NULL, NULL, 34, 1250) $$);
SELECT t.runs('so is a date-range one', $$ SELECT bms.log_backup('RANGE', '2026-09-01', '2026-09-30', 34, 210) $$);
SELECT t.eq('with who made it', 'Admin User', (SELECT made_by_name FROM bms.backup_log ORDER BY made_at LIMIT 1));
SELECT t.eq('a full backup stores no dates', NULL::date, (SELECT date_from FROM bms.backup_log WHERE scope = 'ALL'));
SELECT t.throws('a range needs its dates', $$ SELECT bms.log_backup('RANGE', NULL, NULL, 1, 1) $$, 'backup_range_ck');
SELECT t.eq('every backup is in the audit log, marked important', 2::bigint,
  (SELECT COUNT(*) FROM bms.audit_log WHERE action = 'EXPORT' AND detail LIKE 'Backup downloaded%' AND severity = 'HIGH'));
SELECT t.throws('the record of a backup cannot be deleted', $$ DELETE FROM bms.backup_log WHERE scope = 'ALL' $$);

SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.eq('the finance manager can see the backups taken', 2::bigint, (SELECT COUNT(*) FROM bms.backup_log));
SELECT t.runs('and take one', $$ SELECT bms.log_backup('ALL', NULL, NULL, 34, 1300) $$);

RESET ROLE;
