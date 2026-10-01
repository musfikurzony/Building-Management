-- Test fixtures: six users covering every role, a bank account,
-- and three flats with deliberately different service charges.
SET search_path = bms, public;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a1','admin@test'),
  ('00000000-0000-0000-0000-0000000000a2','finance@test'),
  ('00000000-0000-0000-0000-0000000000a3','manager@test'),
  ('00000000-0000-0000-0000-0000000000a4','caretaker@test'),
  ('00000000-0000-0000-0000-0000000000a5','committee@test'),
  ('00000000-0000-0000-0000-0000000000a6','auditor@test'),
  ('00000000-0000-0000-0000-0000000000a7','newbie@test')
ON CONFLICT DO NOTHING;

INSERT INTO bms.user_profiles (user_id, full_name, email, is_active) VALUES
  ('00000000-0000-0000-0000-0000000000a1','Admin User','admin@test',true),
  ('00000000-0000-0000-0000-0000000000a2','Finance Manager','finance@test',true),
  ('00000000-0000-0000-0000-0000000000a3','Building Manager','manager@test',true),
  ('00000000-0000-0000-0000-0000000000a4','Caretaker','caretaker@test',true),
  ('00000000-0000-0000-0000-0000000000a5','Committee Member','committee@test',true),
  ('00000000-0000-0000-0000-0000000000a6','Auditor','auditor@test',true),
  ('00000000-0000-0000-0000-0000000000a7','Not Yet Approved','newbie@test',false)
ON CONFLICT DO NOTHING;

INSERT INTO bms.user_roles (user_id, role_id)
SELECT u.uid::uuid, r.id FROM (VALUES
  ('00000000-0000-0000-0000-0000000000a1','SUPER_ADMIN'),
  ('00000000-0000-0000-0000-0000000000a2','FINANCE_MANAGER'),
  ('00000000-0000-0000-0000-0000000000a3','MANAGER'),
  ('00000000-0000-0000-0000-0000000000a4','CARETAKER'),
  ('00000000-0000-0000-0000-0000000000a5','COMMITTEE'),
  ('00000000-0000-0000-0000-0000000000a6','AUDITOR')
) AS u(uid, role) JOIN bms.roles r ON r.code = u.role
ON CONFLICT DO NOTHING;

SELECT t.remember('admin',    '00000000-0000-0000-0000-0000000000a1');
SELECT t.remember('finance',  '00000000-0000-0000-0000-0000000000a2');
SELECT t.remember('manager',  '00000000-0000-0000-0000-0000000000a3');
SELECT t.remember('caretaker','00000000-0000-0000-0000-0000000000a4');
SELECT t.remember('committee','00000000-0000-0000-0000-0000000000a5');
SELECT t.remember('auditor',  '00000000-0000-0000-0000-0000000000a6');
SELECT t.remember('newbie',   '00000000-0000-0000-0000-0000000000a7');

INSERT INTO bms.accounts (code, name, kind, opening_balance, opening_date)
VALUES ('BANK1','Main bank account','BANK', 100000.00, DATE '2026-01-01'),
       ('RESV1','Reserve account','BANK', 0, DATE '2026-01-01')
ON CONFLICT (code) DO NOTHING;

INSERT INTO bms.account_secrets (account_id, account_number)
SELECT id, '1234567890123' FROM bms.accounts WHERE code = 'BANK1'
ON CONFLICT DO NOTHING;

-- Three flats, three different charges — the case the spec calls out.
INSERT INTO bms.flats (flat_number, floor, area_sqft, service_charge) VALUES
  ('A-101', 1, 1400, 5000.00),
  ('A-102', 1, 1150, 4500.00),
  ('A-103', 1, 1400, NULL)          -- NULL falls back to the building default
ON CONFLICT (flat_number) DO NOTHING;

INSERT INTO bms.owners (name, mobile) VALUES
  ('Rahim Uddin','01711000001'),
  ('Karima Begum','01711000002'),
  ('Jamal Hossain','01711000003')
ON CONFLICT DO NOTHING;

INSERT INTO bms.flat_occupancy (flat_id, owner_id, relation_type, from_date)
SELECT f.id, o.id, 'OWNER', DATE '2026-01-01'
  FROM (VALUES ('A-101','Rahim Uddin'),('A-102','Karima Begum'),('A-103','Jamal Hossain')) v(fl, ow)
  JOIN bms.flats  f ON f.flat_number = v.fl
  JOIN bms.owners o ON o.name = v.ow
ON CONFLICT DO NOTHING;

SELECT t.remember('acct_bank', (SELECT id::text FROM bms.accounts WHERE code='BANK1'));
SELECT t.remember('acct_resv', (SELECT id::text FROM bms.accounts WHERE code='RESV1'));
SELECT t.remember('acct_cash', (SELECT id::text FROM bms.accounts WHERE code='CASH'));
SELECT t.remember('flat_101',  (SELECT id::text FROM bms.flats WHERE flat_number='A-101'));
SELECT t.remember('flat_102',  (SELECT id::text FROM bms.flats WHERE flat_number='A-102'));
SELECT t.remember('flat_103',  (SELECT id::text FROM bms.flats WHERE flat_number='A-103'));
SELECT t.remember('dept_gen',  (SELECT id::text FROM bms.departments WHERE code='GENERATOR'));
SELECT t.remember('cat_fuel',  (SELECT c.id::text FROM bms.categories c
                                  JOIN bms.departments d ON d.id=c.department_id
                                 WHERE d.code='GENERATOR' AND c.name='Diesel / fuel'));
