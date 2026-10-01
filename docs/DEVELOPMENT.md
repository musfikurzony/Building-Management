# Working on the portal

There is no build step. Edit a file, reload the page.

## Running it locally, with a real database

The dev server is a small stand-in for Supabase: it serves the app's files and
speaks enough of the PostgREST and GoTrue wire format that the real
`supabase-js` client works against a local PostgreSQL database. Because every
query runs as the `authenticated` role with the caller's user id in
`request.jwt.claim.sub`, **Row Level Security applies exactly as it does in
production** — a permission bug shows up here rather than in front of the
committee.

```bash
# once: a local PostgreSQL 15+ on port 5433
./scripts/localdb.sh                 # builds bms_test and applies every migration
psql -d bms_test -f sql/test/harness.sql
psql -d bms_test -f sql/test/fixtures.sql

node scripts/devserver.mjs 5173      # then open http://localhost:5173
```

Sign in as any fixture account — `admin@test`, `finance@test`, `manager@test`,
`caretaker@test`, `committee@test`, `auditor@test`. The dev server does not
check passwords; type anything.

The dev server is a development tool. It has no TLS, no password hashing and
no rate limiting, and must never be exposed to a network.

## The tests

```bash
./scripts/test.sh            # SQL: rules, permissions, money, full journey
./scripts/browser-test.sh    # the real UI in Chromium against the real database
```

Each SQL suite runs in its own fresh database. A suite that only passes because
of another suite's leftovers is not a test.

| Suite | What it holds the line on |
|---|---|
| `t00_self_contained` | everything lives in `bms`; the only outside dependency is `auth.users` |
| `t01_security` | RLS is on everywhere and actually bites, per role |
| `t02_ledger` | approval, immutability, reversal, transfers, period locking, precision |
| `t03_charges` | generation, allocation, partial and advance payments, waivers |
| `t04_journey` | one continuous month lived end to end, balances checked at every step |

## Where things live

```
index.html            the shell
config.js             your Supabase URL and anon key
core/                 db access, session, permissions, router, DOM helpers
modules/              one file per screen
sql/                  migrations, in the order they must run
sql/test/             the test suites and their fixtures
scripts/              dev server, database rebuild, test runners
vendor/supabase.js    the Supabase client, vendored rather than from a CDN
```

## House rules

1. **Money never touches JavaScript arithmetic.** Amounts arrive from Postgres
   as strings and are formatted for display. Every total, balance, allocation
   and variance is computed in SQL. If you find yourself adding two amounts in
   a module file, the sum belongs in a view.
2. **The browser is untrusted.** `can()` decides what to *show*. What is
   *allowed* is decided by RLS and the RPC functions. Never add a rule to a
   module file that does not also exist in the database.
3. **Never build HTML from a string with user data in it.** Use `el()`, or the
   `html` tagged template, which escapes every interpolation. A flat owner
   called `<img src=x onerror=...>` must show up as text, not run as code —
   there is a browser test for exactly that.
4. **Every schema change is a numbered file in `sql/`**, and every rule that
   file introduces gets a test.
5. **Nothing financial is ever deleted.** Cancel, reverse, or supersede.
