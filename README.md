# Building Management & Finance Portal

A relational, auditable financial system for a residential building — service
charge, a single general ledger, bank and cash, roles and permissions, and a
full audit trail. Designed to become the building's official book of record.

**Completely self-contained.** Its own Supabase project, its own database, its
own authentication, its own storage, its own deployment. It is not connected to
any other system, and a test fails the build if anything it creates ever leaks
outside its own `bms` schema.

- **No build step.** Static files plus PostgreSQL. Deploys to Cloudflare
  Workers or GitHub Pages by pushing the repository.
- **The database is the security boundary.** Row Level Security on every table
  and `SECURITY DEFINER` functions for every state change. Hiding a button in
  the browser is decoration.
- **Money lives in `numeric(14,2)` and is added up in SQL.** No JavaScript
  floating point ever touches an amount.
- **Nothing financial is deleted.** Corrections happen through linked reversals,
  and a closed month stays closed.

## Getting started

| I want to… | Read |
|---|---|
| set this up on Supabase | `docs/SETUP.md` — or paste `sql/BUNDLE_all.sql`, which is all of it in one file |
| check the install worked | `sql/VERIFY.sql` — read-only, PASS/FAIL per check |
| create the first admin account | `sql/BOOTSTRAP_ADMIN.sql` |
| put it on the web | `docs/DEPLOY.md` |
| work on the code | `docs/DEVELOPMENT.md` |
| be able to recover from a mistake | `docs/BACKUP.md` |

## What is built

**Phase 1 — foundation.** Authentication, users, roles and a module-by-action
permission grid, building settings, flat and owner master, bank and cash
accounts, the central ledger with its approval workflow, accounting periods,
the audit log, and a role-aware dashboard.

**Phase 2 — service charge.** Monthly generation at each flat's own rate,
payment recording with oldest-first allocation, partial and advance payments,
waivers and adjustments with a second-person approval, opening balances, flat
statements with a printable and WhatsApp-shareable receipt, and collection and
outstanding reports.

**Phase 3 — operations.** One asset register serving the generator, the lift
and the fire extinguishers, with service and inspection due-dates that go
red on their own. Generator run logs and fuel purchases, lift servicing and
parts, fire inspections, a maintenance issue tracker where the person who
did the work cannot be the person who signs it off, staff records,
attendance, leave, advances and salary runs, and daily work checklists for
the cleaner, the gardener and the guards.

**Phase 4/5 — advanced finance.** Reserve funds that keep the earmark and
the money visibly apart, so a reserve that is only a committee resolution
looks like one. Fixed deposits that move money without spending it and split
interest out as income. Bank reconciliation with statement import and
cautious auto-matching. Budget against actual, paced by months elapsed
rather than the whole year. In-app notifications generated from the same
alert list the dashboard uses, filtered by what each person is allowed to
act on. Annual reports with a running balance and the building's total
position.

Still to come: attaching receipt images through Supabase Storage from the
browser, a flat-owner portal, and visitor management. All three are already
provided for in the schema and the permission grid.

## Tests

```bash
./scripts/test.sh          # SQL: rules, permissions, money, full journey
./scripts/browser-test.sh  # the real UI in Chromium against a real database
```

---

Developed by Musfikur Rahman | Copyright © 2026
