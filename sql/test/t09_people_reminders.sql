-- =====================================================================
-- t09 — owners and tenants, and reminding them.
--
-- The first half exists because of one specific fault: linking a tenant
-- used to END the owner's ownership. The very first assertion after a
-- tenant moves in is therefore "the owner is still the owner".
--
-- The second half is about not embarrassing anyone: a reminder must go
-- to whoever actually pays, must never be recorded for a flat that owes
-- nothing, and once recorded must never change.
-- =====================================================================
SET t.suite = 't09 people & reminders';
SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- Phone numbers, the way people actually type them
-- ---------------------------------------------------------------------
SELECT t.eq('a local mobile gains the country code',   '8801913469117', bms.normalize_mobile('01913469117'));
SELECT t.eq('spaces and dashes are ignored',           '8801913469117', bms.normalize_mobile('0191 346-9117'));
SELECT t.eq('a + prefix is understood',                '8801913469117', bms.normalize_mobile('+880 1913 469117'));
SELECT t.eq('a 00 prefix is understood',               '8801913469117', bms.normalize_mobile('008801913469117'));
SELECT t.eq('ten digits without the 0 are understood', '8801913469117', bms.normalize_mobile('1913469117'));
SELECT t.eq('an owner abroad keeps their number',      '447700900123',  bms.normalize_mobile('+44 7700 900123'));
SELECT t.ok('a landline is not a mobile',      bms.normalize_mobile('029876543') IS NULL);
SELECT t.ok('too short is not a number',       bms.normalize_mobile('12345') IS NULL);
SELECT t.ok('letters are not a number',        bms.normalize_mobile('call the guard') IS NULL);
SELECT t.ok('blank is not a number',           bms.normalize_mobile('') IS NULL);
SELECT t.ok('a +880 that is not a mobile is refused', bms.normalize_mobile('+880 2 9876543') IS NULL);

-- ---------------------------------------------------------------------
-- A TENANT MOVES IN — and the owner must still own the flat
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('manager'), false);

SELECT t.remember('owner101', (SELECT owner_id::text FROM bms.v_flat_people WHERE flat_number='A-101'));
SELECT t.ok('A-101 starts with an owner who pays',
  (SELECT owner_billed FROM bms.v_flat_people WHERE flat_number='A-101'));

SELECT t.runs('a tenant can be moved into A-101',
  'SELECT bms.set_flat_tenant(''' || t.recall('flat_101') || ''', NULL,
     ''Tanvir Hossain'', ''01811000009'', NULL, NULL, CURRENT_DATE, true)');

-- The regression this file is named for.
SELECT t.eq('THE OWNER IS STILL THE OWNER after a tenant moves in',
  t.recall('owner101'),
  (SELECT owner_id::text FROM bms.v_flat_people WHERE flat_number='A-101'));
SELECT t.ok('and the owner''s ownership row is still open',
  (SELECT to_date IS NULL FROM bms.flat_occupancy
    WHERE owner_id = t.uid('owner101') AND flat_id = t.uid('flat_101') AND relation_type='OWNER'));

SELECT t.eq('the tenant is recorded', 'Tanvir Hossain',
  (SELECT tenant_name FROM bms.v_flat_people WHERE flat_number='A-101'));
SELECT t.eq('the tenant now pays', 'TENANT',
  (SELECT billed_relation FROM bms.v_flat_people WHERE flat_number='A-101'));
SELECT t.eq('and the bill shows the tenant''s name', 'Tanvir Hossain',
  (SELECT billed_to FROM bms.v_flat_dues WHERE flat_number='A-101'));
SELECT t.eq('exactly one person is billed', 1::bigint,
  (SELECT COUNT(*) FROM bms.flat_occupancy
    WHERE flat_id = t.uid('flat_101') AND to_date IS NULL AND is_billed));

-- Who pays can change without anybody moving.
SELECT t.runs('the bill can move back to the owner',
  'SELECT bms.set_billed_party(''' || t.recall('flat_101') || ''', ''OWNER'')');
SELECT t.eq('the owner pays again', 'OWNER',
  (SELECT billed_relation FROM bms.v_flat_people WHERE flat_number='A-101'));
SELECT t.eq('still exactly one person billed', 1::bigint,
  (SELECT COUNT(*) FROM bms.flat_occupancy
    WHERE flat_id = t.uid('flat_101') AND to_date IS NULL AND is_billed));
SELECT bms.set_billed_party(t.uid('flat_101'), 'TENANT');

-- One person cannot be both.
SELECT t.throws('the owner cannot also be the tenant',
  'SELECT bms.set_flat_tenant(''' || t.recall('flat_101') || ''', ''' || t.recall('owner101') || ''')',
  'cannot also be its tenant');
SELECT t.throws('nor the tenant become owner while still the tenant',
  'SELECT bms.set_flat_owner(''' || t.recall('flat_101') || ''',
     (SELECT tenant_id FROM bms.v_flat_people WHERE flat_number=''A-101''))',
  'End the tenancy first');
RESET ROLE;

-- Only someone allowed to edit flats can move people around.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('a caretaker cannot move a tenant in',
  'SELECT bms.set_flat_tenant(''' || t.recall('flat_102') || ''', NULL, ''Someone'')',
  'Permission denied');
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT t.throws('nor can the finance manager, who only views flats',
  'SELECT bms.end_tenancy(''' || t.recall('flat_101') || ''')',
  'Permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------
-- REMINDERS go to whoever pays
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);

SELECT bms.generate_monthly_charges(2026, 6);

SELECT t.remember('ctx101', bms.reminder_context(t.uid('flat_101'))::text);
SELECT t.eq('A-101''s reminder goes to the tenant', 'Tanvir Hossain',
  t.recall('ctx101')::jsonb ->> 'recipient_name');
SELECT t.eq('at the tenant''s number, ready for WhatsApp', '8801811000009',
  t.recall('ctx101')::jsonb ->> 'mobile_wa');
SELECT t.eq('marked as the tenant', 'TENANT', t.recall('ctx101')::jsonb ->> 'relation');

SELECT t.remember('ctx102', bms.reminder_context(t.uid('flat_102'))::text);
SELECT t.eq('A-102''s goes to its owner, who pays', 'OWNER', t.recall('ctx102')::jsonb ->> 'relation');
SELECT t.eq('the outstanding figure is the flat''s real one', 4500::numeric,
  (t.recall('ctx102')::jsonb ->> 'outstanding')::numeric);
SELECT t.eq('June is listed as the month owed', 1::int,
  jsonb_array_length(t.recall('ctx102')::jsonb -> 'months'));
SELECT t.eq('a first reminder is the gentle one', 'GENTLE',
  t.recall('ctx102')::jsonb ->> 'suggested_tone');
SELECT t.eq('all six templates come with it', 6::int,
  (SELECT COUNT(*)::int FROM jsonb_object_keys(t.recall('ctx102')::jsonb -> 'templates')));
SELECT t.ok('the finance manager may send it', (t.recall('ctx102')::jsonb ->> 'can_send')::boolean);

-- Send one, then another: the tone should firm up.
SELECT bms.log_charge_reminder(t.uid('flat_102'), 'WHATSAPP', 'GENTLE', 'en', 'Dear Karima, a gentle reminder...');
SELECT t.eq('after one reminder the next is a follow-up', 'FOLLOW_UP',
  bms.reminder_context(t.uid('flat_102')) ->> 'suggested_tone');
SELECT bms.log_charge_reminder(t.uid('flat_102'), 'WHATSAPP', 'FOLLOW_UP', 'bn', 'সম্মানিত Karima...');
SELECT t.eq('after two the next is firm', 'FIRM',
  bms.reminder_context(t.uid('flat_102')) ->> 'suggested_tone');
SELECT bms.log_charge_reminder(t.uid('flat_102'), 'SMS', 'FIRM', 'en', 'Despite our previous reminders...');
SELECT t.eq('and stays firm', 'FIRM',
  bms.reminder_context(t.uid('flat_102')) ->> 'suggested_tone');

SELECT t.eq('the count is kept', 3::int,
  (SELECT reminders_total FROM bms.v_flat_reminders WHERE flat_id = t.uid('flat_102')));

-- What was recorded is what was true at the time.
SELECT t.eq('the reminder records who was asked', 'Karima Begum',
  (SELECT recipient_name FROM bms.charge_reminders WHERE flat_id = t.uid('flat_102') ORDER BY sent_at LIMIT 1));
SELECT t.eq('the number it went to', '8801711000002',
  (SELECT phone_sent FROM bms.charge_reminders WHERE flat_id = t.uid('flat_102') ORDER BY sent_at LIMIT 1));
SELECT t.eq('the amount owed at that moment', 4500::numeric,
  (SELECT amount_due FROM bms.charge_reminders WHERE flat_id = t.uid('flat_102') ORDER BY sent_at LIMIT 1));
SELECT t.eq('the months it was for', 'Jun 2026',
  (SELECT months FROM bms.charge_reminders WHERE flat_id = t.uid('flat_102') ORDER BY sent_at LIMIT 1));
SELECT t.eq('and the exact words', 'Dear Karima, a gentle reminder...',
  (SELECT message FROM bms.charge_reminders WHERE flat_id = t.uid('flat_102') ORDER BY sent_at LIMIT 1));
SELECT t.eq('and who sent it', t.recall('finance'),
  (SELECT sent_by::text FROM bms.charge_reminders WHERE flat_id = t.uid('flat_102') ORDER BY sent_at LIMIT 1));

-- Paying resets the tone, but not the history.
SELECT bms.record_payment(t.uid('flat_102'), 1000, CURRENT_DATE, 'CASH', t.uid('acct_cash'), NULL, NULL, NULL);
SELECT t.eq('after a payment, the next reminder is gentle again', 'GENTLE',
  bms.reminder_context(t.uid('flat_102')) ->> 'suggested_tone');
SELECT t.eq('though all three earlier reminders are still on record', 3::int,
  (SELECT reminders_total FROM bms.v_flat_reminders WHERE flat_id = t.uid('flat_102')));
SELECT t.eq('none of them counted as since the payment', 0::int,
  (SELECT reminders_since_payment FROM bms.v_flat_reminders WHERE flat_id = t.uid('flat_102')));

-- The mistake this feature must never make.
SELECT bms.record_payment(t.uid('flat_102'), 3500, CURRENT_DATE, 'CASH', t.uid('acct_cash'), NULL, NULL, NULL);
SELECT t.eq('A-102 now owes nothing', 0::numeric,
  (SELECT outstanding FROM bms.v_flat_dues WHERE flat_number='A-102'));
SELECT t.throws('no reminder can be recorded for a flat that owes nothing',
  'SELECT bms.log_charge_reminder(''' || t.recall('flat_102') || ''', ''WHATSAPP'', ''GENTLE'', ''en'', ''pay up'')',
  'owes nothing');

SELECT t.throws('an empty message is refused',
  'SELECT bms.log_charge_reminder(''' || t.recall('flat_101') || ''', ''WHATSAPP'', ''GENTLE'', ''en'', ''   '')',
  'empty');
SELECT t.throws('an unknown channel is refused',
  'SELECT bms.log_charge_reminder(''' || t.recall('flat_101') || ''', ''PIGEON'', ''GENTLE'', ''en'', ''hello'')',
  'Unknown channel');
RESET ROLE;

-- ---------------------------------------------------------------------
-- A reminder, once recorded, never changes
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.throws('nobody can insert a reminder except through the function',
  'INSERT INTO bms.charge_reminders (flat_id, channel, tone, lang, amount_due, message)
     VALUES (''' || t.recall('flat_101') || ''', ''WHATSAPP'', ''GENTLE'', ''en'', 1, ''forged'')',
  'permission denied');
SELECT t.throws('nobody can edit one, even a super admin',
  'UPDATE bms.charge_reminders SET message = ''rewritten'' WHERE true',
  'permission denied');
SELECT t.throws('nobody can delete one, even a super admin',
  'DELETE FROM bms.charge_reminders WHERE true',
  'permission denied');
RESET ROLE;
-- Not even with table privileges: the trigger is the second line.
SELECT t.throws('even the table owner cannot rewrite one',
  'UPDATE bms.charge_reminders SET message = ''rewritten'' WHERE true',
  'cannot be changed');
SELECT t.throws('or delete one outside a system reset',
  'DELETE FROM bms.charge_reminders WHERE true',
  'never deleted');

-- Who may send, and who may only look.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('committee'), false);
SELECT t.ok('the committee can see a flat''s reminder figures',
  (bms.reminder_context(t.uid('flat_101')) ->> 'flat_number') = 'A-101');
SELECT t.ok('but is told it cannot send',
  NOT (bms.reminder_context(t.uid('flat_101')) ->> 'can_send')::boolean);
SELECT t.throws('and cannot record a reminder',
  'SELECT bms.log_charge_reminder(''' || t.recall('flat_101') || ''', ''WHATSAPP'', ''GENTLE'', ''en'', ''hello'')',
  'Permission denied');
SELECT set_config('request.jwt.claim.sub', t.recall('caretaker'), false);
SELECT t.throws('a caretaker cannot even read reminder figures',
  'SELECT bms.reminder_context(''' || t.recall('flat_101') || ''')', 'Permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------
-- A reminder records the person as they were
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
SELECT bms.log_charge_reminder(t.uid('flat_101'), 'WHATSAPP', 'GENTLE', 'en', 'Dear Tanvir...');
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('manager'), false);
SELECT t.runs('the tenant moves out',
  'SELECT bms.end_tenancy(''' || t.recall('flat_101') || ''')');
SELECT t.eq('the bill returns to the owner', 'OWNER',
  (SELECT billed_relation FROM bms.v_flat_people WHERE flat_number='A-101'));
SELECT t.ok('the flat has no current tenant',
  (SELECT tenant_id IS NULL FROM bms.v_flat_people WHERE flat_number='A-101'));
SELECT t.eq('but the tenancy is kept as history', 1::bigint,
  (SELECT COUNT(*) FROM bms.flat_occupancy
    WHERE flat_id = t.uid('flat_101') AND relation_type='TENANT' AND to_date IS NOT NULL));
SELECT t.throws('a flat with no tenant cannot end a tenancy',
  'SELECT bms.end_tenancy(''' || t.recall('flat_101') || ''')', 'no current tenant');
RESET ROLE;

SELECT t.eq('the earlier reminder still names the tenant it went to', 'Tanvir Hossain',
  (SELECT recipient_name FROM bms.charge_reminders WHERE flat_id = t.uid('flat_101')
    ORDER BY sent_at DESC LIMIT 1));
SELECT t.eq('and says they were the tenant', 'TENANT',
  (SELECT relation FROM bms.charge_reminders WHERE flat_id = t.uid('flat_101')
    ORDER BY sent_at DESC LIMIT 1));

-- ---------------------------------------------------------------------
-- A TENANT WHO DOES NOT PAY, and a SALE
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('manager'), false);

SELECT bms.set_flat_tenant(t.uid('flat_103'), NULL, 'Nusrat Jahan', '01911000011',
                           NULL, NULL, CURRENT_DATE, false);
SELECT t.eq('a tenant who does not pay leaves the bill with the owner', 'OWNER',
  (SELECT billed_relation FROM bms.v_flat_people WHERE flat_number='A-103'));
SELECT t.eq('though the tenant is recorded', 'Nusrat Jahan',
  (SELECT tenant_name FROM bms.v_flat_people WHERE flat_number='A-103'));

SELECT t.remember('old_owner103', (SELECT owner_id::text FROM bms.v_flat_people WHERE flat_number='A-103'));
SELECT t.runs('the flat is sold to a new owner',
  'SELECT bms.set_flat_owner(''' || t.recall('flat_103') || ''', NULL, ''Farhan Ahmed'', ''+8801511000012'')');
SELECT t.eq('the new owner is recorded', 'Farhan Ahmed',
  (SELECT owner_name FROM bms.v_flat_people WHERE flat_number='A-103'));
SELECT t.eq('and takes over the bill the old owner paid', 'OWNER',
  (SELECT billed_relation FROM bms.v_flat_people WHERE flat_number='A-103'));
SELECT t.ok('the old ownership is closed, not deleted',
  (SELECT to_date IS NOT NULL FROM bms.flat_occupancy
    WHERE owner_id = t.uid('old_owner103') AND flat_id = t.uid('flat_103') AND relation_type='OWNER'));
SELECT t.eq('the tenant was not disturbed by the sale', 'Nusrat Jahan',
  (SELECT tenant_name FROM bms.v_flat_people WHERE flat_number='A-103'));
SELECT t.eq('still exactly one person billed', 1::bigint,
  (SELECT COUNT(*) FROM bms.flat_occupancy
    WHERE flat_id = t.uid('flat_103') AND to_date IS NULL AND is_billed));
RESET ROLE;

-- A flat nobody pays for is never left that way.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
INSERT INTO bms.flats (flat_number, floor, status) VALUES ('Q-001', 1, 'ACTIVE');
SELECT bms.set_flat_tenant((SELECT id FROM bms.flats WHERE flat_number='Q-001'),
                           NULL, 'Only Tenant', NULL, NULL, NULL, CURRENT_DATE, false);
SELECT t.eq('a tenant in a flat with no owner on record has to be the one billed', 'TENANT',
  (SELECT billed_relation FROM bms.v_flat_people WHERE flat_number='Q-001'));
RESET ROLE;

-- ---------------------------------------------------------------------
-- The wording, and what survives an update
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('finance'), false);
-- Finance can read but not change it: RLS filters the row out of the
-- UPDATE, so the statement runs and changes nothing.
UPDATE bms.reminder_templates SET body = 'hijacked' WHERE tone='GENTLE' AND lang='en';
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.ok('the finance manager cannot change the wording',
  (SELECT body FROM bms.reminder_templates WHERE tone='GENTLE' AND lang='en') <> 'hijacked');

SELECT t.runs('a super admin can',
  'UPDATE bms.reminder_templates SET body = ''Dear {name}, our own wording for {flat}.''
     WHERE tone=''GENTLE'' AND lang=''en''');
SELECT t.throws('but only the words — not what kind of template it is',
  'UPDATE bms.reminder_templates SET tone = ''FIRM'' WHERE tone=''GENTLE'' AND lang=''en''',
  'permission denied');
SELECT t.throws('and not the original it can be restored to',
  'UPDATE bms.reminder_templates SET default_body = ''x'' WHERE tone=''GENTLE'' AND lang=''en''',
  'permission denied');
RESET ROLE;

SELECT set_config('request.jwt.claim.sub', '', false);
\ir ../085_people_reminders.sql
SET search_path = bms, public;

SELECT t.eq('re-running the update keeps wording someone edited',
  'Dear {name}, our own wording for {flat}.',
  (SELECT body FROM bms.reminder_templates WHERE tone='GENTLE' AND lang='en'));
SELECT t.ok('while the original is still there to restore',
  (SELECT default_body LIKE 'Dear {name},%gentle reminder%' FROM bms.reminder_templates
    WHERE tone='GENTLE' AND lang='en'));
SELECT t.eq('and there are still exactly six', 6::bigint, (SELECT COUNT(*) FROM bms.reminder_templates));

-- ---------------------------------------------------------------------
-- A fresh start clears reminders too
-- ---------------------------------------------------------------------
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT t.ok('there are reminders to clear', (SELECT COUNT(*) FROM bms.charge_reminders) > 0);
SELECT t.ok('the reset preview counts them',
  ((bms.reset_preview() -> 'entries' ->> 'reminders')::int) > 0);
SELECT bms.reset_system('entries', 'RESET');
SELECT t.eq('clearing entries clears the reminder history', 0::bigint,
  (SELECT COUNT(*) FROM bms.charge_reminders));
SELECT t.ok('but keeps the people and who pays',
  (SELECT COUNT(*) FROM bms.v_flat_people WHERE billed_relation IS NOT NULL) > 0);
RESET ROLE;
