-- =====================================================================
-- t08 — custom roles, and the escalation they would otherwise open.
--
-- The important part of this suite is not that create_role() works. It
-- is that an Admin cannot use it, or the tables underneath it, to become
-- a Super Admin. That was possible before sql/080_roles.sql: the RLS
-- policy on bms.roles asked only for users.add, which ADMIN holds, so
--
--     INSERT INTO roles(code,name,is_superuser) VALUES ('X','X',true);
--     INSERT INTO user_roles(user_id,role_id) VALUES (auth.uid(), X);
--
-- promoted you, and the system reset came with it. Every path to that is
-- attempted below and required to fail.
-- =====================================================================
SET t.suite = 't08 roles';
SET search_path = bms, public;

-- A person with the plain ADMIN role. Not a superuser, but holding
-- users.add, users.edit and users.manage — the most dangerous account
-- that is not already all-powerful.
INSERT INTO auth.users(id, email)
  VALUES ('00000000-0000-0000-0000-0000000000c1','plainadmin@test')
  ON CONFLICT DO NOTHING;
INSERT INTO bms.user_profiles(user_id, full_name, is_active)
  VALUES ('00000000-0000-0000-0000-0000000000c1','Plain Admin', true)
  ON CONFLICT DO NOTHING;
INSERT INTO bms.user_roles(user_id, role_id)
  SELECT '00000000-0000-0000-0000-0000000000c1', id FROM bms.roles WHERE code='ADMIN'
  ON CONFLICT DO NOTHING;
SELECT t.remember('padmin','00000000-0000-0000-0000-0000000000c1');

-- ---------------------------------------------------------------------
-- The escalation, from every direction
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('padmin'), false);

SELECT t.ok('the plain admin does not start as a superuser', NOT bms.is_superuser());
SELECT t.ok('but does hold users.add, so the policy alone would let them in',
            bms.has_perm('users','add'));

SELECT t.throws('an admin cannot create a role with full access',
  'INSERT INTO bms.roles(code,name,is_superuser) VALUES (''ESC1'',''Escalated'',true)',
  'Only a Super Admin');

SELECT t.throws('an admin cannot give themselves the existing Super Admin role',
  'INSERT INTO bms.user_roles(user_id, role_id)
     SELECT ''00000000-0000-0000-0000-0000000000c1'', id FROM bms.roles WHERE code=''SUPER_ADMIN''',
  'Only a Super Admin');

SELECT t.throws('an admin cannot promote an existing ordinary role to full access',
  'UPDATE bms.roles SET is_superuser = true WHERE code = ''CARETAKER''',
  'Only a Super Admin');

SELECT t.throws('an admin cannot mark a role of their own as a system role',
  'INSERT INTO bms.roles(code,name,is_system) VALUES (''ESC2'',''Sneaky'',true)',
  'Only a Super Admin');

SELECT t.ok('and after all of that, still not a superuser', NOT bms.is_superuser());
RESET ROLE;

-- ---------------------------------------------------------------------
-- The system roles are protected
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);   -- a real Super Admin

-- `authenticated` holds no DELETE privilege on bms.roles at all, so a
-- direct DELETE is refused by the grant before RLS or the guard is even
-- consulted. Removal goes through delete_role(), which runs as the owner.
SELECT t.throws('a client cannot DELETE from the roles table directly',
  'DELETE FROM bms.roles WHERE code = ''CARETAKER''', 'permission denied');
SELECT t.eq('so the role survives', 1::bigint,
  (SELECT COUNT(*) FROM bms.roles WHERE code = 'CARETAKER'));
SELECT t.throws('and delete_role() refuses a built-in role with a reason',
  'SELECT bms.delete_role((SELECT id FROM bms.roles WHERE code=''CARETAKER''))',
  'cannot be deleted');
SELECT t.throws('the code of a built-in role cannot be changed',
  'UPDATE bms.roles SET code = ''CARETAKER2'' WHERE code = ''CARETAKER''', 'cannot be changed');
SELECT t.throws('a built-in role cannot be demoted to an ordinary one',
  'UPDATE bms.roles SET is_system = false WHERE code = ''CARETAKER''', 'cannot be turned into');

-- Renaming one is fine — the code is the identity, the name is a label.
SELECT t.runs('a built-in role can still be renamed',
  'UPDATE bms.roles SET name = ''Building Caretaker'' WHERE code = ''CARETAKER''');

-- ---------------------------------------------------------------------
-- Creating one, as a super admin
-- ---------------------------------------------------------------------
SELECT t.remember('newrole',
  (bms.create_role('Generator Operator', 'Logs power cuts and generator runs',
                   (SELECT id FROM bms.roles WHERE code='CARETAKER'), 0, 0)).id::text);

SELECT t.eq('the new role exists', 'Generator Operator',
  (SELECT name FROM bms.roles WHERE id = t.uid('newrole')));
SELECT t.eq('its code is derived from its name', 'GENERATOR_OPERATOR',
  (SELECT code FROM bms.roles WHERE id = t.uid('newrole')));
SELECT t.ok('it is not a system role',
  NOT (SELECT is_system FROM bms.roles WHERE id = t.uid('newrole')));
SELECT t.ok('it is not a superuser role',
  NOT (SELECT is_superuser FROM bms.roles WHERE id = t.uid('newrole')));
SELECT t.eq('its permissions were copied from the caretaker',
  (SELECT COUNT(*) FROM bms.role_permissions rp
     JOIN bms.roles r ON r.id = rp.role_id WHERE r.code = 'CARETAKER'),
  (SELECT COUNT(*) FROM bms.role_permissions WHERE role_id = t.uid('newrole')));

-- A name that collides gets a suffix rather than an error.
SELECT t.remember('newrole2', (bms.create_role('Generator Operator')).id::text);
SELECT t.eq('a second role of the same name gets its own code', 'GENERATOR_OPERATOR_1',
  (SELECT code FROM bms.roles WHERE id = t.uid('newrole2')));
SELECT t.eq('and starts with no permissions when nothing was copied', 0::bigint,
  (SELECT COUNT(*) FROM bms.role_permissions WHERE role_id = t.uid('newrole2')));

SELECT t.throws('a role cannot be copied from Super Admin, which holds no list',
  'SELECT bms.create_role(''Clone'', NULL, (SELECT id FROM bms.roles WHERE code=''SUPER_ADMIN''))',
  'no permission list');
SELECT t.throws('a role needs a name',
  'SELECT bms.create_role(''   '')', 'needs a name');

-- ---------------------------------------------------------------------
-- Removing one
-- ---------------------------------------------------------------------
INSERT INTO bms.user_roles(user_id, role_id)
  VALUES (t.uid('padmin'), t.uid('newrole2'));
SELECT t.throws('a role still held by someone cannot be removed',
  'SELECT bms.delete_role(''' || t.recall('newrole2') || ''')', 'still has');

DELETE FROM bms.user_roles WHERE role_id = t.uid('newrole2');
SELECT t.runs('once nobody holds it, it can be removed',
  'SELECT bms.delete_role(''' || t.recall('newrole2') || ''')');
SELECT t.eq('and it is gone', 0::bigint,
  (SELECT COUNT(*) FROM bms.roles WHERE id = t.uid('newrole2')));
RESET ROLE;

-- ---------------------------------------------------------------------
-- You cannot grant a permission you do not hold
--
-- Without this, users.manage was a master key: tick finance.approve onto
-- your own role and the approval limits stop meaning anything.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('padmin'), false);

SELECT t.ok('the plain admin can create an ordinary role',
  (bms.create_role('Test Role By Admin')).id IS NOT NULL);
SELECT t.remember('adminrole', (SELECT id::text FROM bms.roles WHERE code='TEST_ROLE_BY_ADMIN'));

-- ADMIN holds finance.view, so granting that is allowed.
SELECT t.runs('an admin can grant a permission they hold themselves',
  'INSERT INTO bms.role_permissions(role_id, permission_id)
     SELECT ''' || t.recall('adminrole') || ''', id FROM bms.permissions
      WHERE module_code=''finance'' AND action=''view''');

-- Take one away from ADMIN, then prove they can no longer pass it on.
RESET ROLE;
DELETE FROM bms.role_permissions rp
 USING bms.roles r, bms.permissions p
 WHERE rp.role_id = r.id AND rp.permission_id = p.id
   AND r.code = 'ADMIN' AND p.module_code = 'reserve' AND p.action = 'approve';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('padmin'), false);
SELECT t.ok('the admin genuinely no longer holds reserve.approve',
  NOT bms.has_perm('reserve','approve'));
SELECT t.throws('so they cannot grant it to a role either',
  'INSERT INTO bms.role_permissions(role_id, permission_id)
     SELECT ''' || t.recall('adminrole') || ''', id FROM bms.permissions
      WHERE module_code=''reserve'' AND action=''approve''',
  'do not have it yourself');

-- Taking access away is always allowed, whoever you are.
SELECT t.runs('removing a permission is always allowed',
  'DELETE FROM bms.role_permissions rp USING bms.permissions p
    WHERE rp.permission_id = p.id AND rp.role_id = ''' || t.recall('adminrole') || '''
      AND p.module_code = ''finance'' AND p.action = ''view''');
RESET ROLE;

-- A super admin is exempt from that rule, because they hold everything.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.runs('a super admin can grant anything',
  'INSERT INTO bms.role_permissions(role_id, permission_id)
     SELECT ''' || t.recall('newrole') || ''', id FROM bms.permissions
      WHERE module_code=''reserve'' AND action=''approve''');
RESET ROLE;

-- ---------------------------------------------------------------------
-- Who may create a role at all
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('a caretaker cannot create a role',
  'SELECT bms.create_role(''Caretaker Role Grab'')', 'permission denied');
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.throws('a finance manager cannot create a role',
  'SELECT bms.create_role(''Finance Role Grab'')', 'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------
-- Categories: usage counting, which is what the screen shows before it
-- lets anyone change a category's direction.
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);

SELECT t.eq('an unused category reports no usage', 0::bigint,
  bms.category_usage((SELECT c.id FROM bms.categories c
                        JOIN bms.departments d ON d.id = c.department_id
                       WHERE d.code='UTILITIES' AND c.name LIKE 'Water%')));

SELECT bms.create_transaction(CURRENT_DATE, 'EXPENSE', t.uid('dept_gen'), t.uid('cat_fuel'),
                              'usage counter test', 900, 'CASH', t.uid('acct_cash'));
SELECT t.eq('a used category reports its usage', 1::bigint,
  bms.category_usage(t.uid('cat_fuel')));

SELECT t.runs('a category can be created from the app',
  'INSERT INTO bms.categories(department_id, name, txn_type, is_active)
     VALUES (''' || t.recall('dept_gen') || ''', ''Test category'', ''EXPENSE'', true)');
SELECT t.runs('a category can be hidden rather than deleted',
  'UPDATE bms.categories SET is_active = false WHERE name = ''Test category''');
SELECT t.eq('hiding it does not remove it', 1::bigint,
  (SELECT COUNT(*) FROM bms.categories WHERE name = 'Test category'));
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('a caretaker cannot invent a category',
  'INSERT INTO bms.categories(department_id, name, txn_type)
     VALUES (''' || t.recall('dept_gen') || ''', ''Caretaker category'', ''EXPENSE'')',
  'row-level security');
RESET ROLE;
