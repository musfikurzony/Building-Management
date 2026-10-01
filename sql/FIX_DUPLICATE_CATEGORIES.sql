-- =====================================================================
-- FIX_DUPLICATE_CATEGORIES.sql — remove the duplicated expense categories.
--
-- WHAT WENT WRONG
--   bms.categories carried UNIQUE (department_id, parent_id, name). Every
--   seeded category is top-level, so its parent_id is NULL — and in a
--   unique index NULL is never equal to NULL. The seed's
--   ON CONFLICT DO NOTHING therefore matched nothing, and each run of
--   BUNDLE_all.sql inserted the whole category list again. Running the
--   migrations twice gives you two of everything, which is what the
--   Category dropdown was showing.
--
--   The migrations no longer do this: a partial unique index now enforces
--   one category per name per department, and the seed names that index
--   explicitly. This file cleans up a database that already has the
--   duplicates.
--
-- WHAT THIS FILE DOES
--   1. For each duplicated (department, name), keeps the OLDEST row.
--   2. Repoints anything that referenced a duplicate — transactions,
--      budgets, staff positions, and child categories — at the keeper, so
--      no existing record loses its category.
--   3. Deletes the now-unreferenced duplicates.
--   4. Adds the partial unique index so it cannot happen again.
--
--   No transaction, payment or balance is altered: only which category
--   row a record points at, and duplicates are identical by definition.
--   Safe to run twice. If there are no duplicates it does nothing.
-- =====================================================================

DO $dedupe$
DECLARE
  v_dupes int;
  v_moved int := 0;
  v_deleted int;
BEGIN
  -- The keeper for every duplicated group: oldest row wins.
  CREATE TEMP TABLE _keep ON COMMIT DROP AS
  SELECT c.id                AS dup_id,
         first_value(c.id) OVER (PARTITION BY c.department_id, c.name
                                 ORDER BY c.created_at, c.id) AS keep_id
    FROM bms.categories c
   WHERE c.parent_id IS NULL;

  DELETE FROM _keep WHERE dup_id = keep_id;      -- leave only the losers

  SELECT COUNT(*) INTO v_dupes FROM _keep;
  IF v_dupes = 0 THEN
    RAISE NOTICE 'No duplicate categories found. Nothing to clean up.';
  ELSE
    RAISE NOTICE 'Found % duplicate categories. Repointing records, then removing them.', v_dupes;

    -- Anything pointing at a loser now points at the keeper.
    UPDATE bms.transactions t SET category_id = k.keep_id
      FROM _keep k WHERE t.category_id = k.dup_id;
    GET DIAGNOSTICS v_moved = ROW_COUNT;
    RAISE NOTICE '  transactions repointed: %', v_moved;

    UPDATE bms.budgets b SET category_id = k.keep_id
      FROM _keep k WHERE b.category_id = k.dup_id;
    GET DIAGNOSTICS v_moved = ROW_COUNT;
    RAISE NOTICE '  budgets repointed: %', v_moved;

    UPDATE bms.staff_positions sp SET category_id = k.keep_id
      FROM _keep k WHERE sp.category_id = k.dup_id;
    GET DIAGNOSTICS v_moved = ROW_COUNT;
    RAISE NOTICE '  staff positions repointed: %', v_moved;

    UPDATE bms.categories c SET parent_id = k.keep_id
      FROM _keep k WHERE c.parent_id = k.dup_id;
    GET DIAGNOSTICS v_moved = ROW_COUNT;
    RAISE NOTICE '  child categories repointed: %', v_moved;

    DELETE FROM bms.categories c USING _keep k WHERE c.id = k.dup_id;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RAISE NOTICE '  duplicate categories removed: %', v_deleted;
  END IF;
END $dedupe$;

-- Stop it ever happening again. This is the index the migrations now
-- create; adding it here means an already-installed database gets it too.
CREATE UNIQUE INDEX IF NOT EXISTS categories_dept_name_uq
  ON bms.categories (department_id, name) WHERE parent_id IS NULL;

-- ---------------------------------------------------------------------
-- Proof. Expect duplicates_remaining = 0, and 44 categories on a
-- freshly-seeded building.
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM bms.categories)                       AS categories_now,
  (SELECT COALESCE(SUM(n - 1), 0) FROM (
      SELECT COUNT(*) AS n FROM bms.categories
       WHERE parent_id IS NULL
       GROUP BY department_id, name) g)                       AS duplicates_remaining,
  (SELECT COUNT(*) FROM pg_indexes
    WHERE schemaname='bms' AND indexname='categories_dept_name_uq') AS guard_index_present;
