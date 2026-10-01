# Setting the portal up

Follow this once, in order. It takes about twenty minutes.

This application is **completely self-contained**. It needs its own Supabase
project, its own database, its own storage and its own login accounts. It is
not connected to any other system, and nothing in this repository reads or
writes anything outside its own `bms` schema.

---

## 0. Create a new Supabase project

Go to [supabase.com](https://supabase.com) → **New project**.

- **Name**: something like `building-portal`
- **Region**: Singapore is the closest to Bangladesh
- **Database password**: generate one and store it in a password manager — you
  will need it for backups, and it cannot be recovered

Wait for the project to finish provisioning before going further.

> Use a **new, empty project**. Do not reuse a project that is already serving
> another application: separate projects mean separate quotas, separate
> backups, and no chance of one system's problem becoming the other's.

---

## 1. Create the schema

In the Supabase SQL Editor, run these files **in order**, one at a time,
checking each one succeeds before the next:

The order is the filename order — that is not a coincidence, it is the rule.
`scripts/localdb.sh` applies `sql/*.sql` sorted by name, so if it works locally
it works here.

| Order | File | What it does |
|---|---|---|
| 1 | `sql/001_core.sql` | schema, money type, roles, permissions, building settings |
| 2 | `sql/002_finance.sql` | departments, categories, vendors, accounts, transactions, ledger, budgets |
| 3 | `sql/003_flats_charges.sql` | flats, owners, occupancy, charges, payments, adjustments |
| 4 | `sql/004_operations.sql` | assets, generator runs, fuel, issues, staff, salary, work logs |
| 5 | `sql/005_funds.sql` | reserve funds, fixed deposits, bank statements, notifications |
| 6 | `sql/010_functions.sql` | approval, posting, reversal, period locking |
| 7 | `sql/011_charge_functions.sql` | charge generation, payment allocation, waivers |
| 8 | `sql/012_operations_functions.sql` | generator/lift/fire logging, issues, attendance, salary |
| 9 | `sql/013_fund_functions.sql` | fund movements, deposits, budgets, reconciliation, notifications |
| 10 | `sql/020_audit.sql` | the audit log and its triggers |
| 11 | `sql/030_rls.sql` | **Row Level Security — the security boundary** |
| 12 | `sql/040_views.sql` | finance and service-charge views |
| 13 | `sql/041_operations_views.sql` | asset, issue, staff and work views |
| 14 | `sql/042_fund_views.sql` | fund, deposit, reconciliation and alert views |
| 15 | `sql/050_seed.sql` | modules, roles, departments, categories |
| 16 | `sql/051_operations_seed.sql` | staff positions, work checklists |
| 17 | `sql/052_funds_seed.sql` | default funds and the notification rules |
| 18 | `sql/090_storage.sql` | storage bucket policies (after the buckets exist) |

Every file is safe to run twice. Everything they create lives in the `bms`
schema; `sql/test/t00_self_contained.sql` fails the build if that ever stops
being true.

## 2. Expose the schema to the API — DO NOT SKIP THIS

Supabase serves only the schemas on its exposed list, and `bms` is not on it
by default.

**Project Settings → API → Exposed schemas** — add `bms`.

Skipping this produces the single most confusing failure in the whole setup.
The site loads, sign-in succeeds, the database is perfect — and every query
comes back `Invalid schema: bms`. Because the app cannot read your profile, it
concludes you have not been activated and shows **"Waiting for access — an
administrator needs to activate it"**. There is no administrator who can help:
nobody can read anything. The portal now detects this case and says so, but
older builds do not.

**Do NOT also run the blanket `GRANT ALL ... TO anon, authenticated` statements
from Supabase's custom-schema guide.** They hand the signed-out `anon` role
access to every table in the schema. This project deliberately revokes that —
`anon` holds zero grants — and Row Level Security is what protects the data.
`sql/030_rls.sql` has already issued the correct, minimal grants. The dashboard
setting is the only thing you need.

## 3. Create the storage buckets

**Storage → New bucket**, three times. All three **private** (leave
"Public bucket" off):

- `bms-receipts`
- `bms-photos`
- `bms-documents`

Then run `sql/090_storage.sql` to attach the access policies.

## 4. Point the app at your project

Edit `config.js`:

```js
window.BMS_CONFIG = {
  SUPABASE_URL: 'https://YOURPROJECT.supabase.co',
  SUPABASE_ANON_KEY: 'eyJhbGciOi...'
};
```

The anon key belongs in this file. It is designed to be public and grants
nothing by itself — every table is behind Row Level Security. **The
service-role key must never appear in any file the browser downloads.**
If you ever find one there, treat it as a leaked credential and rotate it.

## 5. Make yourself the administrator

1. Open the portal and **create an account** with your email.
2. You will land on "Waiting for access" — that is correct. Nobody, including
   you, can activate their own account from the browser.
3. In the Supabase SQL Editor, run:

   ```sql
   UPDATE bms.user_profiles SET is_active = true
    WHERE email = 'your@email';

   INSERT INTO bms.user_roles (user_id, role_id)
   SELECT up.user_id, r.id
     FROM bms.user_profiles up, bms.roles r
    WHERE up.email = 'your@email' AND r.code = 'SUPER_ADMIN'
   ON CONFLICT DO NOTHING;
   ```

4. Reload the portal. You are in.

From here on, everyone else is activated from **Users & Roles** inside the
app — this SQL step is only needed for the very first administrator.

## 6. Set the building up

In the app, in this order:

1. **Settings** — building name, floors, the default service charge, the due
   day, and the currency symbol.
2. **Bank & Cash** — add the real bank account with its true opening balance
   and opening date, and a petty-cash account. Set the petty-cash account as
   the default cash account in Settings.
3. **Flats & Owners** — add the flats. With none yet, the screen offers a bulk
   box: paste one flat per line as `A-101, 1, 5000`. Leave the amount off to
   use the building default.
4. **Owners** — add each owner and link them to their flat. Whoever is linked
   receives the bill and appears on the outstanding report.
5. **Opening balances** — for any flat that already owes money, record what
   it owed on the day you go live. Without this, day one starts everyone at
   zero and the history is gone.
6. **Users & Roles** — activate the other people and give them roles.

## 7. Before you record real money

Read `BACKUP.md` and actually do the restore drill. A backup you have never
restored is a rumour, and this system is about to become the building's book
of record.

---

## Deploying

The repository is the site: there is no build step.

**Cloudflare Workers**:

```
npx wrangler deploy
```

**GitHub Pages**: push to the repo and enable Pages on the branch root.

`config.js` is deployed with everything else, so the URL and anon key are in
the published site. That is correct and expected.
