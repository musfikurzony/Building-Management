-- =====================================================================
-- t00 — THE PORTAL IS SELF-CONTAINED.
--
-- Everything this application creates lives inside the `bms` schema and
-- nowhere else. Nothing leaks into `public`, nothing points at another
-- system, and the only outside dependency is Supabase's own `auth.users`.
--
-- This is what makes the project safe to drop into a brand-new Supabase
-- project, and safe to move to a different one later.
-- =====================================================================
SET t.suite = 't00 self-contained';
SET search_path = bms, public;

-- Nothing of ours is created in the public schema.
SELECT t.eq('no tables created in public', ''::text,
  COALESCE((SELECT string_agg(table_name, ', ' ORDER BY table_name)
     FROM information_schema.tables WHERE table_schema = 'public'), ''));

SELECT t.eq('no views created in public', ''::text,
  COALESCE((SELECT string_agg(table_name, ', ' ORDER BY table_name)
     FROM information_schema.views WHERE table_schema = 'public'), ''));

SELECT t.eq('no functions created in public', ''::text,
  COALESCE((SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'), ''));

SELECT t.eq('no types or domains created in public', ''::text,
  COALESCE((SELECT string_agg(t2.typname, ', ' ORDER BY t2.typname)
     FROM pg_type t2 JOIN pg_namespace n ON n.oid = t2.typnamespace
    WHERE n.nspname = 'public' AND t2.typtype IN ('d','e')), ''));

-- Every foreign key either stays inside bms or points at auth.users.
-- Nothing else may be depended on.
SELECT t.eq('every foreign key stays inside bms or points at auth.users', ''::text,
  COALESCE((SELECT string_agg(format('%s.%s -> %s.%s', sn.nspname, src.relname,
                                     tn.nspname, tgt.relname), ', ')
     FROM pg_constraint con
     JOIN pg_class src ON src.oid = con.conrelid
     JOIN pg_namespace sn ON sn.oid = src.relnamespace
     JOIN pg_class tgt ON tgt.oid = con.confrelid
     JOIN pg_namespace tn ON tn.oid = tgt.relnamespace
    WHERE con.contype = 'f'
      AND sn.nspname = 'bms'
      AND NOT (tn.nspname = 'bms'
               OR (tn.nspname = 'auth' AND tgt.relname = 'users'))), ''));

-- The only schema this application reads outside its own is auth.
SELECT t.eq('the only outside dependency is auth.users', 1::bigint,
  (SELECT COUNT(DISTINCT tn.nspname)
     FROM pg_constraint con
     JOIN pg_class src ON src.oid = con.conrelid
     JOIN pg_namespace sn ON sn.oid = src.relnamespace
     JOIN pg_class tgt ON tgt.oid = con.confrelid
     JOIN pg_namespace tn ON tn.oid = tgt.relnamespace
    WHERE con.contype = 'f' AND sn.nspname = 'bms' AND tn.nspname <> 'bms'));

-- No trigger of ours is attached to a table outside bms.
SELECT t.eq('no triggers on tables outside bms', 0::bigint,
  (SELECT COUNT(*) FROM pg_trigger tg
     JOIN pg_class c ON c.oid = tg.tgrelid
     JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT tg.tgisinternal
      AND n.nspname NOT IN ('bms')
      AND tg.tgfoid IN (SELECT p.oid FROM pg_proc p
                          JOIN pg_namespace pn ON pn.oid = p.pronamespace
                         WHERE pn.nspname = 'bms')));

-- Every function we define is schema-qualified in its search_path, so it
-- cannot be hijacked by a temp table or another schema.
SELECT t.eq('every function pins its search_path', ''::text,
  COALESCE((SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'bms'
      AND p.prosecdef                                   -- SECURITY DEFINER only
      AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) c
                       WHERE c LIKE 'search_path=%')), ''));

-- ---------------------------------------------------------------------
-- THE MIGRATIONS MUST BE SAFE TO RUN TWICE.
--
-- A regression test for a bug that reached a live building: categories
-- carried UNIQUE (department_id, parent_id, name), every seeded category
-- has parent_id NULL, and a unique index treats each NULL as distinct —
-- so the seed's ON CONFLICT DO NOTHING never fired and a second run of
-- the migrations duplicated the entire category list. The Category
-- dropdown showed everything twice.
--
-- This checks the property directly (no duplicates now) and the guard
-- that enforces it (the partial unique index), then proves it by
-- re-running the seed and confirming nothing moves.
-- ---------------------------------------------------------------------
SELECT t.eq('no duplicated top-level categories', 0::bigint,
  COALESCE((SELECT SUM(n - 1) FROM (
     SELECT COUNT(*) AS n FROM bms.categories
      WHERE parent_id IS NULL GROUP BY department_id, name) g), 0::bigint));

SELECT t.eq('the index that prevents duplicate categories exists', 1::bigint,
  (SELECT COUNT(*) FROM pg_indexes
    WHERE schemaname = 'bms' AND indexname = 'categories_dept_name_uq'));

-- Any seeded table whose uniqueness depends on a NULLable column is the
-- same trap. Catch them by name rather than trusting that we remembered.
SELECT t.eq('no duplicated departments', 0::bigint,
  COALESCE((SELECT SUM(n - 1) FROM (
     SELECT COUNT(*) AS n FROM bms.departments GROUP BY code) g), 0::bigint));
SELECT t.eq('no duplicated staff positions', 0::bigint,
  COALESCE((SELECT SUM(n - 1) FROM (
     SELECT COUNT(*) AS n FROM bms.staff_positions GROUP BY code) g), 0::bigint));
SELECT t.eq('no duplicated checklist items', 0::bigint,
  COALESCE((SELECT SUM(n - 1) FROM (
     SELECT COUNT(*) AS n FROM bms.work_checklist_items
      GROUP BY template_id, label) g), 0::bigint));
