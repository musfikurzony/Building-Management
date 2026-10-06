-- =====================================================================
-- t14 — putting right owners and tenants entered one flat at a time.
--
-- The case reported: Nurul Huda lives in A-101 and also owns A-102, which
-- he rents out. The flats were entered separately, so he was typed in
-- twice, and the tenant of A-102 was added to A-101 by mistake. His two
-- flats never added up to one total.
-- =====================================================================
SET t.suite = 't14 people fixes';
SET search_path = bms, public;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.remember('a101', (SELECT id::text FROM bms.flats WHERE flat_number = 'A-101'));
SELECT t.remember('a102', (SELECT id::text FROM bms.flats WHERE flat_number = 'A-102'));
SELECT t.remember('a103', (SELECT id::text FROM bms.flats WHERE flat_number = 'A-103'));

-- How it was entered.
SELECT bms.set_flat_owner(t.uid('a101'), NULL, 'Nurul Huda', '01713049096', NULL, NULL, CURRENT_DATE - 120);
SELECT bms.set_flat_tenant(t.uid('a101'), NULL, 'Tenant A102', NULL, NULL, NULL, CURRENT_DATE - 5, false);
SELECT bms.set_flat_owner(t.uid('a102'), NULL, 'Nurul  huda.', '01713-049096', 'nurul@example.com', NULL, CURRENT_DATE - 120);
SELECT t.remember('nurul',  (SELECT id::text FROM bms.owners WHERE name = 'Nurul Huda'));
SELECT t.remember('nurul2', (SELECT id::text FROM bms.owners WHERE name = 'Nurul  huda.'));

SELECT t.eq('as entered, he looks like two people with one flat each', 1,
  (SELECT flats_owned FROM bms.owner_accounts() WHERE owner_id = t.uid('nurul')));

-- ---------------------------------------------------------------------
-- 1. FINDING THE DOUBLE.
-- ---------------------------------------------------------------------
SELECT t.eq('the two Nurul Hudas are offered as a likely double', 1::bigint,
  (SELECT COUNT(*) FROM bms.possible_duplicate_people()
    WHERE t.uid('nurul') IN (a_id, b_id) AND t.uid('nurul2') IN (a_id, b_id)));
SELECT t.eq('because the name and the mobile match, written differently', 'same name and mobile',
  (SELECT reason FROM bms.possible_duplicate_people() WHERE t.uid('nurul') IN (a_id, b_id)));
SELECT t.eq('each with his flats listed', 'A-101',
  (SELECT a_flats FROM bms.possible_duplicate_people() WHERE a_id = t.uid('nurul')));

-- ---------------------------------------------------------------------
-- 2. THE TENANT ON THE WRONG FLAT.
-- ---------------------------------------------------------------------
SELECT t.remember('wrong', (SELECT tenant_occupancy_id::text FROM bms.v_flat_people WHERE flat_id = t.uid('a101')));
SELECT t.throws('removing it needs a reason', $$ SELECT bms.void_occupancy(t.uid('wrong'), ' ') $$, 'Say why');
SELECT t.runs('the tenant added to A-101 by mistake is removed', $$
  SELECT bms.void_occupancy(t.uid('wrong'), 'Added to the wrong flat — he rents A-102') $$);
SELECT t.ok('A-101 has no tenant now', (SELECT tenant_id IS NULL FROM bms.v_flat_people WHERE flat_id = t.uid('a101')));
SELECT t.eq('and Nurul still pays for it', 'OWNER', (SELECT billed_relation FROM bms.v_flat_people WHERE flat_id = t.uid('a101')));
SELECT t.eq('the entry is kept, marked with why', 'Added to the wrong flat — he rents A-102',
  (SELECT void_reason FROM bms.flat_occupancy WHERE id = t.uid('wrong')));
SELECT t.throws('it cannot be removed twice', $$ SELECT bms.void_occupancy(t.uid('wrong'), 'Again') $$, 'already been removed');
SELECT t.runs('he is added where he belongs, paying for A-102 himself', $$
  SELECT bms.set_flat_tenant(t.uid('a102'), (SELECT owner_id FROM bms.flat_occupancy WHERE id = t.uid('wrong')),
                             NULL, NULL, NULL, NULL, CURRENT_DATE - 5, true) $$);

-- Removing the paying tenant gives the bill back to the owner.
SELECT bms.set_flat_tenant(t.uid('a103'), NULL, 'Short Stay', NULL, NULL, NULL, CURRENT_DATE, true);
SELECT bms.set_flat_owner(t.uid('a103'), NULL, 'Owner Of A103', NULL, NULL, NULL, CURRENT_DATE - 300);
SELECT t.runs('a paying tenant entered by mistake is removed', $$
  SELECT bms.void_occupancy((SELECT tenant_occupancy_id FROM bms.v_flat_people WHERE flat_id = t.uid('a103')), 'Test entry') $$);
SELECT t.eq('and the owner receives the bill again', 'OWNER', (SELECT billed_relation FROM bms.v_flat_people WHERE flat_id = t.uid('a103')));

-- ---------------------------------------------------------------------
-- 3. ONE PERSON AGAIN.
-- ---------------------------------------------------------------------
SELECT t.throws('a person cannot be merged with himself', $$
  SELECT bms.merge_people(t.uid('nurul'), t.uid('nurul')) $$, 'two different people');
SELECT t.runs('the two Nurul Hudas are merged', $$ SELECT bms.merge_people(t.uid('nurul'), t.uid('nurul2')) $$);
SELECT t.eq('he now owns both flats', 2, (SELECT flats_owned FROM bms.owner_accounts() WHERE owner_id = t.uid('nurul')));
SELECT t.eq('one of them rented out', 1, (SELECT flats_rented_out FROM bms.owner_accounts() WHERE owner_id = t.uid('nurul')));
SELECT t.eq('the email from the second entry is kept', 'nurul@example.com', (SELECT email FROM bms.owners WHERE id = t.uid('nurul')));
SELECT t.ok('the second entry is retired, not deleted, and says where it went',
  (SELECT NOT is_active AND merged_into = t.uid('nurul') AND notes LIKE '%Merged into Nurul Huda%' FROM bms.owners WHERE id = t.uid('nurul2')));
SELECT t.eq('and is no longer offered as a double', 0::bigint,
  (SELECT COUNT(*) FROM bms.possible_duplicate_people() WHERE t.uid('nurul2') IN (a_id, b_id)));
SELECT t.eq('the merge is in the audit log as a HIGH entry', 1::bigint,
  (SELECT COUNT(*) FROM bms.audit_log WHERE entity_id = t.uid('nurul') AND severity = 'HIGH' AND detail LIKE 'Merged Nurul  huda.%'));
SELECT t.throws('a retired entry cannot be merged again', $$
  SELECT bms.merge_people(t.uid('nurul'), t.uid('nurul2')) $$, 'already been merged');

-- With the tenant paying A-102, Nurul owes A-101 only; tick "owner pays" and both add up.
SELECT t.eq('while the tenant pays A-102, Nurul is billed for one flat', 1,
  (SELECT flats_paid FROM bms.owner_accounts() WHERE owner_id = t.uid('nurul')));
SELECT bms.set_billed_party(t.uid('a102'), 'OWNER');
SELECT t.eq('switched to "paid by Owner", both flats are on his account', 2,
  (SELECT flats_paid FROM bms.owner_accounts() WHERE owner_id = t.uid('nurul')));

-- A merge that would make one person owner and tenant of the same flat.
SELECT bms.set_flat_tenant(t.uid('a103'), NULL, 'Tenant Of A103', NULL, NULL, NULL, CURRENT_DATE, true);
SELECT t.throws('owner and tenant of the same flat cannot be merged', $$
  SELECT bms.merge_people((SELECT id FROM bms.owners WHERE name = 'Owner Of A103'),
                          (SELECT id FROM bms.owners WHERE name = 'Tenant Of A103')) $$, 'cannot be one person');

-- ---------------------------------------------------------------------
-- 4. THE WRONG NAME — CORRECTED, NOT "SOLD".
-- ---------------------------------------------------------------------
SELECT t.remember('owner_rows', (SELECT COUNT(*)::text FROM bms.flat_occupancy WHERE flat_id = t.uid('a103') AND relation_type = 'OWNER'));
SELECT t.runs('the owner of A-103 is corrected to the right person', $$
  SELECT bms.correct_occupant((SELECT owner_occupancy_id FROM bms.v_flat_people WHERE flat_id = t.uid('a103')),
                              NULL, 'Real Owner A103', '01819000111', 'Typed the wrong name') $$);
SELECT t.eq('the flat shows the right owner', 'Real Owner A103', (SELECT owner_name FROM bms.v_flat_people WHERE flat_id = t.uid('a103')));
SELECT t.eq('with no invented "past owner"', t.recall('owner_rows')::bigint,
  (SELECT COUNT(*) FROM bms.flat_occupancy WHERE flat_id = t.uid('a103') AND relation_type = 'OWNER'));
SELECT t.eq('and the same "owner since" date', (CURRENT_DATE - 300)::text,
  (SELECT owner_since::text FROM bms.v_flat_people WHERE flat_id = t.uid('a103')));
SELECT t.throws('the tenant cannot be named as the owner', $$
  SELECT bms.correct_occupant((SELECT owner_occupancy_id FROM bms.v_flat_people WHERE flat_id = t.uid('a103')),
                              (SELECT id FROM bms.owners WHERE name = 'Tenant Of A103')) $$, 'already the tenant');

-- ---------------------------------------------------------------------
-- 5. WHO MAY.
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', t.recall('committee'), false);
SELECT t.throws('a committee member cannot merge people', $$
  SELECT bms.merge_people((SELECT id FROM bms.owners WHERE name = 'Owner Of A103'), t.uid('nurul')) $$, 'permission denied');
SELECT t.throws('nor remove an entry', $$
  SELECT bms.void_occupancy((SELECT owner_occupancy_id FROM bms.v_flat_people WHERE flat_id = t.uid('a101')), 'x') $$, 'permission denied');
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('a caretaker cannot correct an owner', $$
  SELECT bms.correct_occupant(t.uid('wrong'), NULL, 'Someone') $$, 'permission denied');

RESET ROLE;
