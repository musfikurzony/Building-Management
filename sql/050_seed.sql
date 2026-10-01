-- =====================================================================
-- 050_seed.sql — reference data: modules, permissions, roles, the role
-- matrix, departments, categories, and a starting settings row.
--
-- Safe to re-run: everything is ON CONFLICT DO NOTHING or an upsert.
-- It creates NO users and NO money.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- MODULES. phase 1 and 2 are enabled; later phases are registered now so
-- permissions can be configured before the screens exist.
-- ---------------------------------------------------------------------
INSERT INTO bms.modules (code, name, icon, sort_order, phase, is_enabled) VALUES
  ('dashboard',  'Dashboard',            'dashboard',  10,  1, true),
  ('flats',      'Flats & Owners',       'home',       20,  1, true),
  ('charges',    'Service Charge',       'receipt',    30,  2, true),
  ('finance',    'Finance / Ledger',     'ledger',     40,  1, true),
  ('bank',       'Bank & Cash',          'bank',       50,  1, true),
  ('reports',    'Reports',              'chart',      60,  2, true),
  ('budget',     'Budget',               'target',     70,  5, false),
  ('reserve',    'Reserve & Deposits',   'vault',      80,  5, false),
  ('generator',  'Generator',            'bolt',       90,  4, false),
  ('lift',       'Lift',                 'lift',      100,  4, false),
  ('fire',       'Fire Safety',          'flame',     110,  4, false),
  ('maintenance','Maintenance',          'wrench',    120,  4, false),
  ('staff',      'Staff',                'users',     130,  4, false),
  ('salary',     'Salary',               'wallet',    140,  4, false),
  ('work',       'Work Monitoring',      'check',     150,  4, false),
  ('mosque',     'Mosque',               'moon',      160,  4, false),
  ('users',      'Users & Roles',        'shield',    900,  1, true),
  ('audit',      'Audit Log',            'history',   910,  1, true),
  ('settings',   'Settings',             'settings',  920,  1, true)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, icon = EXCLUDED.icon,
      sort_order = EXCLUDED.sort_order, phase = EXCLUDED.phase;

-- ---------------------------------------------------------------------
-- PERMISSIONS — which actions each module supports.
-- ---------------------------------------------------------------------
INSERT INTO bms.permissions (module_code, action)
SELECT m.code, a.action
  FROM bms.modules m
  CROSS JOIN LATERAL (
    SELECT unnest(
      CASE m.code
        WHEN 'dashboard' THEN ARRAY['view']
        WHEN 'reports'   THEN ARRAY['view','export']
        WHEN 'audit'     THEN ARRAY['view','export']
        WHEN 'settings'  THEN ARRAY['view','edit']
        WHEN 'users'     THEN ARRAY['view','add','edit','manage']
        WHEN 'bank'      THEN ARRAY['view','add','edit','export','view_sensitive']
        WHEN 'finance'   THEN ARRAY['view','add','edit','approve','export','cancel','close']
        WHEN 'charges'   THEN ARRAY['view','add','edit','approve','export','cancel','waive']
        WHEN 'budget'    THEN ARRAY['view','add','edit','export']
        ELSE ARRAY['view','add','edit','approve','export','cancel']
      END) AS action
  ) a
ON CONFLICT (module_code, action) DO NOTHING;

-- ---------------------------------------------------------------------
-- ROLES
-- ---------------------------------------------------------------------
INSERT INTO bms.roles (code, name, description, is_system, is_superuser, approve_limit, auto_post_limit, sort_order) VALUES
  ('SUPER_ADMIN','Super Admin','Everything, including roles and settings. Keep this to one or two people.', true, true,  NULL,      NULL,  10),
  ('ADMIN','Admin','Full operational and financial access.',                                                true, false, NULL,      NULL,  20),
  ('FINANCE_MANAGER','Finance Manager','Ledger, service charge, bank, approvals and reports.',              true, false, 200000.00, 20000.00, 30),
  ('MANAGER','Manager','Day-to-day management with limited financial authority.',                           true, false,  25000.00,  5000.00, 40),
  ('CARETAKER','Caretaker','Operational logging and expense submission. Cannot approve or post.',           true, false,       0.00,     0.00, 50),
  ('COMMITTEE','Committee Member','Read-only across the building, including reports.',                      true, false,       0.00,     0.00, 60),
  ('AUDITOR','Auditor','Read-only everywhere, including the audit log. Changes nothing.',                   true, false,       0.00,     0.00, 70)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description,
      is_superuser = EXCLUDED.is_superuser,
      approve_limit = EXCLUDED.approve_limit,
      auto_post_limit = EXCLUDED.auto_post_limit;

-- Helper: give a role a set of actions on a module.
CREATE OR REPLACE FUNCTION bms.seed_grant(p_role text, p_module text, p_actions text[])
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO bms.role_permissions (role_id, permission_id)
  SELECT r.id, p.id
    FROM bms.roles r, bms.permissions p
   WHERE r.code = p_role AND p.module_code = p_module AND p.action = ANY(p_actions)
  ON CONFLICT DO NOTHING;
END $$;

DO $$
DECLARE
  ALL_OPS text[] := ARRAY['view','add','edit','approve','export','cancel'];
  m record;
BEGIN
  -- SUPER_ADMIN is is_superuser and needs no explicit rows.

  -- ADMIN: everything except the superuser flag.
  FOR m IN SELECT code FROM bms.modules LOOP
    INSERT INTO bms.role_permissions (role_id, permission_id)
    SELECT r.id, p.id FROM bms.roles r, bms.permissions p
     WHERE r.code = 'ADMIN' AND p.module_code = m.code
    ON CONFLICT DO NOTHING;
  END LOOP;

  -- FINANCE MANAGER
  PERFORM bms.seed_grant('FINANCE_MANAGER','dashboard', ARRAY['view']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','finance',   ARRAY['view','add','edit','approve','export','cancel','close']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','charges',   ARRAY['view','add','edit','approve','export','cancel','waive']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','bank',      ARRAY['view','add','edit','export','view_sensitive']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','budget',    ARRAY['view','add','edit','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','reserve',   ARRAY['view','add','edit','approve','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','flats',     ARRAY['view','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','reports',   ARRAY['view','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','audit',     ARRAY['view','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','salary',    ARRAY['view','add','edit','export']);
  PERFORM bms.seed_grant('FINANCE_MANAGER','settings',  ARRAY['view']);
  -- Read-only sight of the operational modules: someone approving a
  -- Tk 18,000 lift repair should be able to open the job it came from.
  FOR m IN SELECT code FROM bms.modules
            WHERE code IN ('generator','lift','fire','maintenance','staff','work','mosque') LOOP
    PERFORM bms.seed_grant('FINANCE_MANAGER', m.code, ARRAY['view','export']);
  END LOOP;

  -- MANAGER
  PERFORM bms.seed_grant('MANAGER','dashboard', ARRAY['view']);
  PERFORM bms.seed_grant('MANAGER','finance',   ARRAY['view','add','approve','export']);
  PERFORM bms.seed_grant('MANAGER','charges',   ARRAY['view','add','export']);
  PERFORM bms.seed_grant('MANAGER','bank',      ARRAY['view']);
  PERFORM bms.seed_grant('MANAGER','flats',     ARRAY['view','add','edit','export']);
  PERFORM bms.seed_grant('MANAGER','reports',   ARRAY['view','export']);
  PERFORM bms.seed_grant('MANAGER','budget',    ARRAY['view','export']);
  PERFORM bms.seed_grant('MANAGER','reserve',   ARRAY['view']);
  PERFORM bms.seed_grant('MANAGER','settings',  ARRAY['view']);
  FOR m IN SELECT code FROM bms.modules
            WHERE code IN ('generator','lift','fire','maintenance','staff','work','mosque') LOOP
    PERFORM bms.seed_grant('MANAGER', m.code, ALL_OPS);
  END LOOP;

  -- CARETAKER: may submit an expense, never approve or post one.
  PERFORM bms.seed_grant('CARETAKER','dashboard', ARRAY['view']);
  PERFORM bms.seed_grant('CARETAKER','finance',   ARRAY['add']);
  PERFORM bms.seed_grant('CARETAKER','flats',     ARRAY['view']);
  FOR m IN SELECT code FROM bms.modules
            WHERE code IN ('generator','lift','fire','maintenance','work') LOOP
    PERFORM bms.seed_grant('CARETAKER', m.code, ARRAY['view','add','edit']);
  END LOOP;
  PERFORM bms.seed_grant('CARETAKER','staff', ARRAY['view']);

  -- COMMITTEE: read-only, no bank account numbers.
  PERFORM bms.seed_grant('COMMITTEE','dashboard', ARRAY['view']);
  FOR m IN SELECT code FROM bms.modules
            WHERE code NOT IN ('users','audit','settings','salary') LOOP
    PERFORM bms.seed_grant('COMMITTEE', m.code, ARRAY['view','export']);
  END LOOP;

  -- AUDITOR: read-only everywhere, including the audit log.
  FOR m IN SELECT code FROM bms.modules LOOP
    PERFORM bms.seed_grant('AUDITOR', m.code, ARRAY['view','export']);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- BUILDING SETTINGS — one row, editable in the UI.
-- ---------------------------------------------------------------------
INSERT INTO bms.building_settings (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPARTMENTS
-- ---------------------------------------------------------------------
INSERT INTO bms.departments (code, name, sort_order) VALUES
  ('SERVICE_CHARGE','Service Charge',  10),
  ('GENERATOR',     'Generator',       20),
  ('LIFT',          'Lift',            30),
  ('SECURITY',      'Security',        40),
  ('CLEANING',      'Cleaning',        50),
  ('GARDEN',        'Garden',          60),
  ('MOSQUE',        'Mosque',          70),
  ('MAINTENANCE',   'Maintenance',     80),
  ('UTILITIES',     'Utilities',       90),
  ('ADMIN',         'Administration', 100),
  ('RESERVE',       'Reserve & Funds',110),
  ('OTHER',         'Other',          900)
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name;

-- ---------------------------------------------------------------------
-- CATEGORIES
-- ---------------------------------------------------------------------
INSERT INTO bms.categories (department_id, name, txn_type, sort_order)
SELECT d.id, c.name, c.txn_type, c.sort_order
  FROM (VALUES
    ('SERVICE_CHARGE','Monthly service charge',  'INCOME',  10),
    ('SERVICE_CHARGE','Opening balance received','INCOME',  20),
    ('SERVICE_CHARGE','Late fee',                'INCOME',  30),
    ('GENERATOR',     'Diesel / fuel',           'EXPENSE', 10),
    ('GENERATOR',     'Engine oil & coolant',    'EXPENSE', 20),
    ('GENERATOR',     'Servicing',               'EXPENSE', 30),
    ('GENERATOR',     'Repair & parts',          'EXPENSE', 40),
    ('LIFT',          'Monthly servicing (AMC)', 'EXPENSE', 10),
    ('LIFT',          'Repair & parts',          'EXPENSE', 20),
    ('SECURITY',      'Guard salary',            'EXPENSE', 10),
    ('SECURITY',      'Uniform & equipment',     'EXPENSE', 20),
    ('CLEANING',      'Cleaner salary',          'EXPENSE', 10),
    ('CLEANING',      'Cleaning supplies',       'EXPENSE', 20),
    ('GARDEN',        'Gardener salary',         'EXPENSE', 10),
    ('GARDEN',        'Plants & fertiliser',     'EXPENSE', 20),
    ('MOSQUE',        'Imam salary',             'EXPENSE', 10),
    ('MOSQUE',        'Assistant Imam salary',   'EXPENSE', 20),
    ('MOSQUE',        'Supplies & repairs',      'EXPENSE', 30),
    ('MOSQUE',        'Donation received',       'INCOME',  40),
    ('MAINTENANCE',   'Plumbing',                'EXPENSE', 10),
    ('MAINTENANCE',   'Electrical',              'EXPENSE', 20),
    ('MAINTENANCE',   'Building repair',         'EXPENSE', 30),
    ('MAINTENANCE',   'Fire safety',             'EXPENSE', 40),
    ('UTILITIES',     'Electricity (DESCO)',     'EXPENSE', 10),
    ('UTILITIES',     'Water (WASA)',            'EXPENSE', 20),
    ('UTILITIES',     'Gas (Titas)',             'EXPENSE', 30),
    ('UTILITIES',     'Internet & phone',        'EXPENSE', 40),
    ('ADMIN',         'Caretaker salary',        'EXPENSE', 10),
    ('ADMIN',         'Manager salary',          'EXPENSE', 20),
    ('ADMIN',         'Office & printing',       'EXPENSE', 30),
    ('ADMIN',         'Bank charges',            'EXPENSE', 40),
    ('ADMIN',         'Festival bonus',          'EXPENSE', 50),
    ('RESERVE',       'Reserve contribution',    'EXPENSE', 10),
    ('RESERVE',       'Bank interest',           'INCOME',  20),
    ('RESERVE',       'Deposit penalty',         'EXPENSE', 30),
    ('OTHER',         'Other income',            'INCOME',  10),
    ('OTHER',         'Other expense',           'EXPENSE', 20)
  ) AS c(dept, name, txn_type, sort_order)
  JOIN bms.departments d ON d.code = c.dept
-- Named target, not a bare ON CONFLICT. The bare form matched the
-- (department_id, parent_id, name) constraint, which never fires for a
-- top-level category because parent_id is NULL — so re-running this file
-- used to duplicate every category.
ON CONFLICT (department_id, name) WHERE parent_id IS NULL DO NOTHING;

-- ---------------------------------------------------------------------
-- A cash account so the very first payment has somewhere to land.
-- The real bank account is added through the UI.
-- ---------------------------------------------------------------------
INSERT INTO bms.accounts (code, name, kind, opening_balance, opening_date)
VALUES ('CASH', 'Cash in hand', 'CASH', 0, CURRENT_DATE)
ON CONFLICT (code) DO NOTHING;

UPDATE bms.building_settings
   SET default_cash_account_id = (SELECT id FROM bms.accounts WHERE code = 'CASH')
 WHERE default_cash_account_id IS NULL;

DROP FUNCTION IF EXISTS bms.seed_grant(text, text, text[]);
