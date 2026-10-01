-- =====================================================================
-- 051_operations_seed.sql — Phase 3 reference data.
-- Safe to re-run. Creates no assets, no staff and no money.
-- =====================================================================

SET search_path = bms, public;

-- Turn the Phase 3 modules on. Permissions for them were already seeded.
UPDATE bms.modules SET is_enabled = true
 WHERE code IN ('generator','lift','fire','maintenance','staff','salary','work','mosque');

-- ---------------------------------------------------------------------
-- STAFF POSITIONS — each one knows which department it belongs to and
-- which ledger category its salary posts to, so payroll classifies
-- itself instead of asking the person entering it.
-- ---------------------------------------------------------------------
INSERT INTO bms.staff_positions (code, name, department_id, category_id, sort_order)
SELECT v.code, v.name, d.id,
       (SELECT c.id FROM bms.categories c
         WHERE c.department_id = d.id AND c.name = v.category LIMIT 1),
       v.sort_order
  FROM (VALUES
    ('CARETAKER',    'Caretaker',            'ADMIN',    'Caretaker salary',      10),
    ('MANAGER',      'Building Manager',     'ADMIN',    'Manager salary',        20),
    ('SECURITY',     'Security Guard',       'SECURITY', 'Guard salary',          30),
    ('CLEANER',      'Cleaner',              'CLEANING', 'Cleaner salary',        40),
    ('GARDENER',     'Gardener',             'GARDEN',   'Gardener salary',       50),
    ('IMAM',         'Imam',                 'MOSQUE',   'Imam salary',           60),
    ('ASST_IMAM',    'Assistant Imam',       'MOSQUE',   'Assistant Imam salary', 70),
    ('OTHER_STAFF',  'Other',                'ADMIN',    'Office & printing',    900)
  ) AS v(code, name, dept, category, sort_order)
  JOIN bms.departments d ON d.code = v.dept
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, department_id = EXCLUDED.department_id,
      category_id = EXCLUDED.category_id;

-- ---------------------------------------------------------------------
-- WORK CHECKLISTS — the caretaker's daily rounds. Every item is data,
-- so the committee can change the list without a developer.
-- ---------------------------------------------------------------------
INSERT INTO bms.work_checklist_templates (code, name, position_id, frequency, sort_order)
SELECT v.code, v.name, p.id, v.frequency, v.sort_order
  FROM (VALUES
    ('CLEAN_DAILY',  'Daily cleaning round',   'CLEANER',  'DAILY',  10),
    ('GARDEN_WEEK',  'Weekly garden care',     'GARDENER', 'WEEKLY', 20),
    ('SECURITY_SHIFT','Security shift check',  'SECURITY', 'DAILY',  30)
  ) AS v(code, name, position, frequency, sort_order)
  JOIN bms.staff_positions p ON p.code = v.position
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, frequency = EXCLUDED.frequency;

INSERT INTO bms.work_checklist_items (template_id, label, requires_photo, sort_order)
SELECT t.id, v.label, v.photo, v.sort_order
  FROM (VALUES
    ('CLEAN_DAILY', 'Staircase swept and mopped',        false, 10),
    ('CLEAN_DAILY', 'Lobby and entrance cleaned',        false, 20),
    ('CLEAN_DAILY', 'Lift floor and mirror cleaned',     false, 30),
    ('CLEAN_DAILY', 'Common toilets cleaned',            false, 40),
    ('CLEAN_DAILY', 'Rubbish removed from all floors',   true,  50),
    ('CLEAN_DAILY', 'Roof and car park tidy',            false, 60),

    ('GARDEN_WEEK', 'All plants watered',                false, 10),
    ('GARDEN_WEEK', 'Dead leaves and weeds cleared',     false, 20),
    ('GARDEN_WEEK', 'Trees and hedges trimmed',          false, 30),
    ('GARDEN_WEEK', 'Fertiliser applied where needed',   false, 40),
    ('GARDEN_WEEK', 'Pots and beds tidy',                true,  50),

    ('SECURITY_SHIFT','Main gate register up to date',   false, 10),
    ('SECURITY_SHIFT','All floors patrolled',            false, 20),
    ('SECURITY_SHIFT','Roof and basement doors locked',  false, 30),
    ('SECURITY_SHIFT','CCTV screens working',            false, 40),
    ('SECURITY_SHIFT','Nothing unusual to report',       false, 50)
  ) AS v(tpl, label, photo, sort_order)
  JOIN bms.work_checklist_templates t ON t.code = v.tpl
 WHERE NOT EXISTS (
   SELECT 1 FROM bms.work_checklist_items i
    WHERE i.template_id = t.id AND i.label = v.label);

-- ---------------------------------------------------------------------
-- A few extra ledger categories that Phase 3 needs.
-- ---------------------------------------------------------------------
INSERT INTO bms.categories (department_id, name, txn_type, sort_order)
SELECT d.id, c.name, c.txn_type, c.sort_order
  FROM (VALUES
    ('LIFT',        'Annual licence & inspection', 'EXPENSE', 30),
    ('MAINTENANCE', 'Lift repair',                 'EXPENSE', 50),
    ('MAINTENANCE', 'Generator repair',            'EXPENSE', 60),
    ('SECURITY',    'Festival bonus',              'EXPENSE', 30),
    ('CLEANING',    'Festival bonus',              'EXPENSE', 30),
    ('GARDEN',      'Pest control',                'EXPENSE', 30),
    ('MOSQUE',      'Electricity share',           'EXPENSE', 35)
  ) AS c(dept, name, txn_type, sort_order)
  JOIN bms.departments d ON d.code = c.dept
ON CONFLICT DO NOTHING;
