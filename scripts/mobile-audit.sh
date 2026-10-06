#!/usr/bin/env bash
# Same fixture database as the browser suite, but driven at phone width.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGOPTIONS='-c client_min_messages=warning'
DB=bms_browser

DB=$DB "$ROOT/scripts/localdb.sh" >/dev/null
psql -q -d $DB -f "$ROOT/sql/test/harness.sql" >/dev/null
psql -q -d $DB -f "$ROOT/sql/test/fixtures.sql" >/dev/null
# A month owed, and a flat with both an owner and a paying tenant, so the
# flat page and the Remind dialog are measured with real content in them.
psql -q -v ON_ERROR_STOP=1 -d $DB >/dev/null <<'SQL'
SELECT set_config('request.jwt.claim.sub', t.recall('admin'), false);
SELECT bms.generate_monthly_charges(EXTRACT(year FROM CURRENT_DATE)::int, EXTRACT(month FROM CURRENT_DATE)::int);
SELECT bms.set_flat_owner((SELECT id FROM bms.flats WHERE flat_number='A-101'), NULL,
       'Mohammad Abdur Rahim Chowdhury', '01712345678', 'rahim.chowdhury@example.com', NULL, CURRENT_DATE - 400);
SELECT bms.set_flat_tenant((SELECT id FROM bms.flats WHERE flat_number='A-101'), NULL,
       'Karim Tenant', '+44 7700 900123', NULL, NULL, CURRENT_DATE - 30, true);
-- Rahim owns two more flats: a land owner, for the owner page and the bills.
SELECT bms.set_flat_owner((SELECT id FROM bms.flats WHERE flat_number='A-102'),
       (SELECT id FROM bms.owners WHERE name='Mohammad Abdur Rahim Chowdhury'), NULL, NULL, NULL, NULL, CURRENT_DATE - 400);
SELECT bms.set_flat_owner((SELECT id FROM bms.flats WHERE flat_number='A-103'),
       (SELECT id FROM bms.owners WHERE name='Mohammad Abdur Rahim Chowdhury'), NULL, NULL, NULL, NULL, CURRENT_DATE - 400);
SELECT bms.record_payment((SELECT id FROM bms.flats WHERE flat_number='A-102'), 4500.00, CURRENT_DATE,
       'BKASH', (SELECT id FROM bms.accounts WHERE code='BANK1'), 'TRX-8KD2', NULL, 'Karima Begum');
INSERT INTO bms.board_members (name, position, sort_order, phone, show_phone, about) VALUES
  ('Mohammad Abdur Rahim Chowdhury', 'Chairman', 10, '01711000099', true, 'Chairs the committee and its monthly meeting.'),
  ('Nasrin Akter', 'Vice Chairman', 20, NULL, false, NULL),
  ('Kamal Hossain', 'Finance Secretary', 40, '01811000088', true, 'Service charge, bank and the monthly report.'),
  ('Rafiq Islam', 'Advisor', 70, NULL, false, NULL);
UPDATE bms.committee_info SET term = '2026 – 2028', intro = 'Elected at the annual general meeting, January 2026.' WHERE id;
INSERT INTO bms.building_documents (title, category, summary, body, effective_date, version_label, is_pinned) VALUES
  ('Building rules and regulations for all residents and visitors', 'RULES', 'Applies to every flat owner, tenant and visitor.',
   E'# Part 1 — General
1. Keep the stairs and corridors clear at all times; nothing may be stored on the landings.
1.1 Shoes may be left inside the flat door only.
2. No parking at the gate.
- Visitors sign in at the gate
- Deliveries before 10 pm

# সার্ভিস চার্জ
১. প্রতি মাসের ১০ তারিখের মধ্যে পরিশোধ করুন।',
   CURRENT_DATE - 200, '2026 amendment', true);
SQL

fuser -k 5198/tcp 2>/dev/null || true
PGDATABASE=$DB node "$ROOT/scripts/devserver.mjs" 5198 > /tmp/devserver-mobile.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
CHROMIUM=/opt/pw-browsers/chromium-1194/chrome-linux/chrome BASE=http://localhost:5198 \
  node "$ROOT/scripts/mobile-audit.mjs"
