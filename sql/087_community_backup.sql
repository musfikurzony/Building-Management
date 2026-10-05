-- =====================================================================
-- 087_community_backup.sql — the building's committee, its rules, and
-- a record of every backup taken.
--
-- PART 1 — COMMITTEE & RULES (module "community")
-- -----------------------------------------------
-- Who runs the building (chairman, vice chairman, secretaries, finance,
-- advisors, operations — any position, any order, with a photo), and the
-- rules they run it by: the constitution, building rules, committee
-- decisions, notices and forms. Readable by every signed-in person whose
-- role includes "Committee & Rules", which by default is every role; a
-- new read-only Resident role gives a flat owner or tenant exactly this
-- and nothing else.
--
-- Photos are kept in the row itself, shrunk to a small JPEG (about 30–60
-- KB) by the app. A committee is a dozen faces: storing them inline means
-- no storage bucket to set up, nothing to sign, and the backup carries
-- them. Rule documents can be long PDFs, so those go to the private
-- bms-documents bucket under community/, readable by anyone who may see
-- the rules.
--
-- PART 2 — BACKUP LOG
-- -------------------
-- The Excel backup is made in the browser; this records that it was
-- made — when, by whom, for which dates, how many rows — so the app can
-- say "last backup 34 days ago" and nobody has to remember.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Module, permissions, grants.
-- ---------------------------------------------------------------------
INSERT INTO bms.modules (code, name, icon, sort_order, phase, is_enabled)
VALUES ('community', 'Committee & Rules', 'people', 15, 5, true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO bms.permissions (module_code, action)
SELECT 'community', a FROM unnest(ARRAY['view','add','edit','cancel','export']) a
ON CONFLICT (module_code, action) DO NOTHING;

-- A role for residents: the committee and the rules, nothing about money.
INSERT INTO bms.roles (code, name, description, is_system, is_superuser, approve_limit, auto_post_limit, sort_order)
VALUES ('RESIDENT', 'Resident', 'Flat owners and tenants: sees the committee and the building rules only.',
        true, false, 0, 0, 80)
ON CONFLICT (code) DO NOTHING;

-- Admin manages it; every other built-in role reads it. (Granted once:
-- re-running this file never re-adds a permission someone took away.)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM bms.role_permissions rp JOIN bms.permissions p ON p.id = rp.permission_id
                  WHERE p.module_code = 'community') THEN
    INSERT INTO bms.role_permissions (role_id, permission_id)
    SELECT r.id, p.id FROM bms.roles r JOIN bms.permissions p ON p.module_code = 'community'
     WHERE r.code = 'ADMIN'
        OR (r.code IN ('FINANCE_MANAGER','MANAGER','CARETAKER','COMMITTEE','AUDITOR','RESIDENT') AND p.action = 'view')
    ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- The committee's heading: its name, its term, a line of introduction.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.committee_info (
  id          boolean PRIMARY KEY DEFAULT true CHECK (id),
  title       text NOT NULL DEFAULT 'Management Committee' CHECK (length(btrim(title)) BETWEEN 1 AND 120),
  term        text CHECK (term IS NULL OR length(term) <= 60),
  intro       text CHECK (intro IS NULL OR length(intro) <= 1000),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id)
);
INSERT INTO bms.committee_info (id) VALUES (true) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS bms.board_members (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  position    text NOT NULL CHECK (length(btrim(position)) BETWEEN 1 AND 80),
  sort_order  int  NOT NULL DEFAULT 100,
  flat_id     uuid REFERENCES bms.flats(id) ON DELETE SET NULL,
  phone       text CHECK (phone IS NULL OR length(phone) <= 40),
  show_phone  boolean NOT NULL DEFAULT false,
  email       text CHECK (email IS NULL OR length(email) <= 120),
  about       text CHECK (about IS NULL OR length(about) <= 1000),
  term_from   date,
  term_to     date,
  is_current  boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid REFERENCES auth.users(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id),
  CONSTRAINT board_term_ck CHECK (term_to IS NULL OR term_from IS NULL OR term_to >= term_from)
);
CREATE INDEX IF NOT EXISTS board_members_order_idx ON bms.board_members(is_current, sort_order);

-- The photo sits in a table of its own: the audit log records every
-- change to a member, and a copy of a picture in every entry would make
-- it enormous for no benefit. Changes of name and position are audited;
-- a new picture is simply a new picture.
CREATE TABLE IF NOT EXISTS bms.board_member_photos (
  member_id   uuid PRIMARY KEY REFERENCES bms.board_members(id) ON DELETE CASCADE,
  photo       text NOT NULL CHECK (photo LIKE 'data:image/%' AND length(photo) <= 400000),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS bms.building_documents (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title          text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 200),
  category       text NOT NULL DEFAULT 'RULES'
                 CHECK (category IN ('CONSTITUTION','RULES','DECISION','NOTICE','FORM','OTHER')),
  summary        text CHECK (summary IS NULL OR length(summary) <= 600),
  body           text CHECK (body IS NULL OR length(body) <= 200000),
  effective_date date,
  version_label  text CHECK (version_label IS NULL OR length(version_label) <= 40),
  file_path      text,
  file_name      text,
  file_mime      text,
  file_size      bigint CHECK (file_size IS NULL OR file_size > 0),
  is_published   boolean NOT NULL DEFAULT true,
  is_pinned      boolean NOT NULL DEFAULT false,
  sort_order     int NOT NULL DEFAULT 100,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid REFERENCES auth.users(id),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid REFERENCES auth.users(id),
  CONSTRAINT document_file_ck CHECK ((file_path IS NULL) = (file_name IS NULL)),
  CONSTRAINT document_has_content_ck CHECK (body IS NOT NULL OR file_path IS NOT NULL OR summary IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS building_documents_cat_idx ON bms.building_documents(category, is_pinned DESC, sort_order);

-- Who and when, stamped by the database rather than trusted from the app.
CREATE OR REPLACE FUNCTION bms.community_touch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := COALESCE(auth.uid(), NEW.updated_by);
  IF TG_OP = 'INSERT' AND TG_TABLE_NAME IN ('board_members','building_documents') THEN
    NEW.created_by := COALESCE(auth.uid(), NEW.created_by);
    NEW.created_at := now();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_committee_info_touch ON bms.committee_info;
CREATE TRIGGER trg_committee_info_touch BEFORE INSERT OR UPDATE ON bms.committee_info
  FOR EACH ROW EXECUTE FUNCTION bms.community_touch();
DROP TRIGGER IF EXISTS trg_board_members_touch ON bms.board_members;
CREATE TRIGGER trg_board_members_touch BEFORE INSERT OR UPDATE ON bms.board_members
  FOR EACH ROW EXECUTE FUNCTION bms.community_touch();
DROP TRIGGER IF EXISTS trg_board_member_photos_touch ON bms.board_member_photos;
CREATE TRIGGER trg_board_member_photos_touch BEFORE INSERT OR UPDATE ON bms.board_member_photos
  FOR EACH ROW EXECUTE FUNCTION bms.community_touch();
DROP TRIGGER IF EXISTS trg_building_documents_touch ON bms.building_documents;
CREATE TRIGGER trg_building_documents_touch BEFORE INSERT OR UPDATE ON bms.building_documents
  FOR EACH ROW EXECUTE FUNCTION bms.community_touch();

-- Every change is in the audit log, like everything else.
DROP TRIGGER IF EXISTS trg_audit_board_members ON bms.board_members;
CREATE TRIGGER trg_audit_board_members AFTER INSERT OR UPDATE OR DELETE ON bms.board_members
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('community', 'name', 'NORMAL');
DROP TRIGGER IF EXISTS trg_audit_building_documents ON bms.building_documents;
CREATE TRIGGER trg_audit_building_documents AFTER INSERT OR UPDATE OR DELETE ON bms.building_documents
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('community', 'title', 'NORMAL');
DROP TRIGGER IF EXISTS trg_audit_committee_info ON bms.committee_info;
CREATE TRIGGER trg_audit_committee_info AFTER UPDATE ON bms.committee_info
  FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger('community', 'title', 'LOW');

-- Row level security.
ALTER TABLE bms.committee_info     ENABLE ROW LEVEL SECURITY;
ALTER TABLE bms.board_members      ENABLE ROW LEVEL SECURITY;
ALTER TABLE bms.building_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE bms.board_member_photos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.committee_info, bms.board_members, bms.building_documents, bms.board_member_photos FROM PUBLIC, anon;
GRANT SELECT, UPDATE ON bms.committee_info TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON bms.board_members, bms.building_documents, bms.board_member_photos TO authenticated;

DROP POLICY IF EXISTS board_member_photos_sel ON bms.board_member_photos;
DROP POLICY IF EXISTS board_member_photos_ins ON bms.board_member_photos;
DROP POLICY IF EXISTS board_member_photos_upd ON bms.board_member_photos;
DROP POLICY IF EXISTS board_member_photos_del ON bms.board_member_photos;
CREATE POLICY board_member_photos_sel ON bms.board_member_photos FOR SELECT TO authenticated
  USING (bms.has_perm('community','view'));
CREATE POLICY board_member_photos_ins ON bms.board_member_photos FOR INSERT TO authenticated
  WITH CHECK (bms.has_perm('community','add') OR bms.has_perm('community','edit'));
CREATE POLICY board_member_photos_upd ON bms.board_member_photos FOR UPDATE TO authenticated
  USING (bms.has_perm('community','edit')) WITH CHECK (bms.has_perm('community','edit'));
CREATE POLICY board_member_photos_del ON bms.board_member_photos FOR DELETE TO authenticated
  USING (bms.has_perm('community','edit') OR bms.has_perm('community','cancel'));

DROP POLICY IF EXISTS committee_info_sel ON bms.committee_info;
DROP POLICY IF EXISTS committee_info_upd ON bms.committee_info;
CREATE POLICY committee_info_sel ON bms.committee_info FOR SELECT TO authenticated
  USING (bms.has_perm('community','view'));
CREATE POLICY committee_info_upd ON bms.committee_info FOR UPDATE TO authenticated
  USING (bms.has_perm('community','edit')) WITH CHECK (bms.has_perm('community','edit'));

DROP POLICY IF EXISTS board_members_sel ON bms.board_members;
DROP POLICY IF EXISTS board_members_ins ON bms.board_members;
DROP POLICY IF EXISTS board_members_upd ON bms.board_members;
DROP POLICY IF EXISTS board_members_del ON bms.board_members;
-- The table itself is read only by those who edit it. Everyone else
-- reads v_board_members, which leaves out a phone number or email the
-- member has not agreed to show — left out by the database, so it never
-- reaches a resident's browser at all.
CREATE POLICY board_members_sel ON bms.board_members FOR SELECT TO authenticated
  USING (bms.has_perm('community','edit'));
CREATE POLICY board_members_ins ON bms.board_members FOR INSERT TO authenticated
  WITH CHECK (bms.has_perm('community','add'));
CREATE POLICY board_members_upd ON bms.board_members FOR UPDATE TO authenticated
  USING (bms.has_perm('community','edit')) WITH CHECK (bms.has_perm('community','edit'));
CREATE POLICY board_members_del ON bms.board_members FOR DELETE TO authenticated
  USING (bms.has_perm('community','cancel'));

CREATE OR REPLACE VIEW bms.v_board_members AS
SELECT m.id, m.name, m.position, m.sort_order, m.flat_id, f.flat_number,
       CASE WHEN m.show_phone OR bms.has_perm('community','edit') THEN m.phone END AS phone,
       CASE WHEN m.show_phone OR bms.has_perm('community','edit') THEN m.email END AS email,
       m.show_phone, m.about, m.term_from, m.term_to, m.is_current, m.updated_at,
       EXISTS (SELECT 1 FROM bms.board_member_photos ph WHERE ph.member_id = m.id) AS has_photo
  FROM bms.board_members m
  LEFT JOIN bms.flats f ON f.id = m.flat_id
 WHERE bms.has_perm('community','view');
REVOKE ALL ON bms.v_board_members FROM PUBLIC, anon;
GRANT SELECT ON bms.v_board_members TO authenticated;

-- An unpublished document (a draft) is seen only by those who may edit.
DROP POLICY IF EXISTS building_documents_sel ON bms.building_documents;
DROP POLICY IF EXISTS building_documents_ins ON bms.building_documents;
DROP POLICY IF EXISTS building_documents_upd ON bms.building_documents;
DROP POLICY IF EXISTS building_documents_del ON bms.building_documents;
CREATE POLICY building_documents_sel ON bms.building_documents FOR SELECT TO authenticated
  USING (bms.has_perm('community','view') AND (is_published OR bms.has_perm('community','edit')));
CREATE POLICY building_documents_ins ON bms.building_documents FOR INSERT TO authenticated
  WITH CHECK (bms.has_perm('community','add'));
CREATE POLICY building_documents_upd ON bms.building_documents FOR UPDATE TO authenticated
  USING (bms.has_perm('community','edit')) WITH CHECK (bms.has_perm('community','edit'));
CREATE POLICY building_documents_del ON bms.building_documents FOR DELETE TO authenticated
  USING (bms.has_perm('community','cancel'));

-- Rule files: the private bms-documents bucket, under community/ only.
-- The bucket is created here if it is missing, PRIVATE, so this works
-- without a trip to the Storage dashboard. Nothing else in the bucket
-- becomes readable: these policies match community/ paths alone.
DO $outer$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'No storage schema here — skipping the community file policies.';
    RETURN;
  END IF;
  INSERT INTO storage.buckets (id, name, public) VALUES ('bms-documents', 'bms-documents', false)
  ON CONFLICT (id) DO NOTHING;

  EXECUTE 'DROP POLICY IF EXISTS "bms-documents_community_read"   ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "bms-documents_community_write"  ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "bms-documents_community_delete" ON storage.objects';
  EXECUTE $sql$
    CREATE POLICY "bms-documents_community_read" ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'bms-documents' AND name LIKE 'community/%' AND bms.has_perm('community','view'));
  $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-documents_community_write" ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'bms-documents' AND name LIKE 'community/%'
                  AND (bms.has_perm('community','add') OR bms.has_perm('community','edit')));
  $sql$;
  EXECUTE $sql$
    CREATE POLICY "bms-documents_community_delete" ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'bms-documents' AND name LIKE 'community/%'
             AND (bms.has_perm('community','edit') OR bms.has_perm('community','cancel')));
  $sql$;
END $outer$;

-- ---------------------------------------------------------------------
-- PART 2 — the backup log.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.backup_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  made_at     timestamptz NOT NULL DEFAULT now(),
  made_by     uuid REFERENCES auth.users(id),
  made_by_name text,
  scope       text NOT NULL CHECK (scope IN ('ALL','RANGE')),
  date_from   date,
  date_to     date,
  sheets      int  NOT NULL CHECK (sheets >= 0),
  total_rows  int  NOT NULL CHECK (total_rows >= 0),
  CONSTRAINT backup_range_ck CHECK (scope = 'ALL' OR (date_from IS NOT NULL AND date_to IS NOT NULL AND date_to >= date_from))
);
CREATE INDEX IF NOT EXISTS backup_log_made_idx ON bms.backup_log(made_at DESC);

ALTER TABLE bms.backup_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bms.backup_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON bms.backup_log TO authenticated;
DROP POLICY IF EXISTS backup_log_sel ON bms.backup_log;
CREATE POLICY backup_log_sel ON bms.backup_log FOR SELECT TO authenticated
  USING (bms.has_perm('reports','view'));

DROP TRIGGER IF EXISTS trg_backup_log_no_delete ON bms.backup_log;
CREATE TRIGGER trg_backup_log_no_delete BEFORE DELETE ON bms.backup_log
  FOR EACH ROW EXECUTE FUNCTION bms.block_delete();

CREATE OR REPLACE FUNCTION bms.log_backup(p_scope text, p_from date, p_to date, p_sheets int, p_rows int)
RETURNS bms.backup_log
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.backup_log;
BEGIN
  PERFORM bms.assert_perm('reports','export');
  INSERT INTO bms.backup_log(made_by, made_by_name, scope, date_from, date_to, sheets, total_rows)
  VALUES (auth.uid(), bms.actor_name(), p_scope,
          CASE WHEN p_scope = 'RANGE' THEN p_from END, CASE WHEN p_scope = 'RANGE' THEN p_to END,
          GREATEST(COALESCE(p_sheets, 0), 0), GREATEST(COALESCE(p_rows, 0), 0))
  RETURNING * INTO r;
  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code, detail, severity)
  VALUES (auth.uid(), bms.actor_name(), 'EXPORT', 'reports',
          format('Backup downloaded (%s, %s sheets, %s rows)',
                 CASE WHEN p_scope = 'RANGE' THEN p_from || ' to ' || p_to ELSE 'all records' END, p_sheets, p_rows),
          'HIGH');
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION bms.log_backup(text,date,date,int,int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.log_backup(text,date,date,int,int) TO authenticated;
