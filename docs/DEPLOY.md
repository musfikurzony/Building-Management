# Deploying the portal

The application is plain HTML, CSS and ES modules. There is no build step,
no bundler, no server-side code. Every rule that matters — permissions,
approvals, immutability, period locking — runs inside PostgreSQL, so the
thing you deploy is a folder of static files and nothing else.

That means any static host will do. Three are described below; pick one.

---

## Before you deploy: the database must be ready

Deploying the site does not create the database. In your Supabase project's
SQL Editor, in this order:

1. `sql/BUNDLE_all.sql` — creates everything. Safe to run twice.
2. `sql/VERIFY.sql` — read-only. Expect PASS on every row except the
   storage one until you have made the buckets.
3. Sign up inside the deployed app, then edit the email at the top of
   `sql/BOOTSTRAP_ADMIN.sql` and run it. That activates the first account.

You can deploy first and do the database afterwards. The app will show a
"waiting for approval" screen until step 3 is done, which is correct.

---

## What gets published

`wrangler.toml` serves the repository root. `.assetsignore` keeps out
everything that should not be on a public web server:

```
index.html  manifest.json  service-worker.js  config.js  _headers
assets/     core/          modules/           vendor/
```

39 files, about 574 KB. No `node_modules`, no `sql/`, no `scripts/`, no
`docs/`, no `.github/`, no `wrangler.toml`.

`_headers` is read by Cloudflare and never served. It sets a Content
Security Policy, `frame-ancestors 'none'` so the portal cannot be framed
by another site, and `no-cache` on `config.js`, `index.html` and the
service worker so a redeploy actually reaches people. The policy is
exercised by the browser suite: `CSP=1 ./scripts/browser-test.sh` runs all
155 checks with it enforced.

**The CSP names your Supabase project.** If you ever move projects, change
the two `supabase.co` hosts in `_headers` as well as `config.js`, or the
app will load and then fail to reach the database.

`config.js` holds the Supabase URL and the anon key. Both are public by
design: the anon key is a JWT whose only claim is `role: anon`, every table
is behind Row Level Security, and the `anon` role holds no grant on any of
them. **A service-role key or database password must never appear in any
deployed file.** Neither is used anywhere in this application.

---

## Option 0 — GitHub, deploying itself (recommended once you have a repo)

`.github/workflows/deploy.yml` is in the repository. Push to `main` and
Cloudflare updates. Nothing to choose, nothing to upload by hand.

Two secrets, added once in **GitHub -> Settings -> Secrets and variables ->
Actions**:

| Secret | Where to get it |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare -> My Profile -> API Tokens -> Create Token -> "Edit Cloudflare Workers" |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare -> Workers & Pages, in the right sidebar |

The token is a secret and belongs only in GitHub Secrets — never in a file
in the repository.

Before deploying, the workflow refuses to publish a `config.js` that still
has placeholder values, or one that appears to contain a service-role key.
Both take a second to check and are expensive to get wrong.

**Why this is worth setting up rather than uploading files:** the modules
import each other. `modules/reports.js` imports `core/xlsx.js`; upload the
first without the second and the Reports page dies with nothing on screen
to explain it. Deploying the whole repository every time removes that
possibility entirely.

---

## Option 1 — Cloudflare Workers (recommended, and already configured)

`wrangler.toml` is in the repository, so this is one command.

```bash
npm install -g wrangler     # once
wrangler login              # opens a browser
wrangler deploy
```

That prints a URL like `https://building-portal.<your-subdomain>.workers.dev`.

To use your own domain, add it in the Cloudflare dashboard under the
Worker's **Settings -> Domains & Routes**, or add a route to `wrangler.toml`.

Redeploying after a change is `wrangler deploy` again. There is nothing to
rebuild.

---

## Option 2 — Cloudflare Pages (drag and drop, no command line)

1. Cloudflare dashboard -> **Workers & Pages** -> **Create** -> **Pages**
   -> **Upload assets**.
2. Delete `node_modules`, `sql`, `scripts`, `docs` and `.git` from your
   copy of the folder first — Pages upload does not read `.assetsignore`.
3. Drag the remaining folder in.
4. Framework preset: **None**. Build command: **leave empty**. Output
   directory: **/**.

---

## Option 3 — Netlify, Vercel, GitHub Pages, or any static host

Upload the same file set. Settings for all of them:

| Setting | Value |
|---|---|
| Build command | *(leave empty)* |
| Output / publish directory | the repository root |
| Framework | None / Other / Static |
| Node version | not used |

For **GitHub Pages**, push to a repository and enable Pages on the branch
root. Note that GitHub Pages is always public — the site is, but so is
anything in the repository, so keep the repository private if you would
rather the schema were not readable.

---

## After the first deploy: three things to check

**0. Expose the `bms` schema.** **Project Settings → API → Exposed schemas →
add `bms`.** Supabase serves only the schemas on that list, and `bms` is not on
it by default.

This is the step most likely to cost you an evening. Without it the site loads,
sign-in works, the database is flawless — and every query is refused with
`Invalid schema: bms` before it reaches a row. The app, unable to read your
profile, reports it as *"Waiting for access — an administrator needs to
activate it"*, which sends you looking for a permissions problem that does not
exist.

Do **not** also run the blanket `GRANT ALL ... TO anon` statements from
Supabase's custom-schema guide — they would give the signed-out role access to
every table. `sql/030_rls.sql` has already granted exactly what is needed.

**1. Does it connect?** Open the site. If you see "Not connected yet", then
`config.js` did not upload or still has the placeholder values.

**2. Add your site to Supabase.** Supabase must be told your site is
allowed to sign people in, or sign-up emails will point at the wrong place:

- **Authentication -> URL Configuration -> Site URL**: your deployed URL.
- **Redirect URLs**: add the same URL.

**3. Decide about email confirmation.** By default Supabase emails a
confirmation link on sign-up. For a building of 36 flats where you are
creating the handful of staff accounts yourself, **Authentication ->
Providers -> Email -> Confirm email = off** is usually the sensible choice
— an account is useless until you activate it in Users & Roles anyway, so
the confirmation adds a step without adding a control. Leave it on if you
would rather have the address verified.

---

## Storage buckets (only needed for receipt and photo attachments)

**Storage -> New bucket**, three times, all **Private**:

| Bucket | Holds |
|---|---|
| `bms-receipts` | invoices and receipts against transactions |
| `bms-photos` | maintenance and fire-extinguisher photos |
| `bms-documents` | FD certificates, bank statements |

Then run `sql/090_storage.sql` on its own to attach the access policies.
Private is not optional: the policies are what make a receipt readable only
by someone with `finance.view`, and a public bucket bypasses them.

---

## Updating the app later

1. Change the files.
2. `wrangler deploy` (or re-upload).
3. Bump `CACHE` in `service-worker.js` if you changed anything under
   `core/`, `modules/` or `assets/` — it is at the top of the file and is
   currently `bms-shell-v4`. The service worker caches static files only,
   never API responses, so data is never stale; but a stale *script* is
   possible if the cache name does not change.

## Rolling the anon key

If you ever rotate it in Supabase: change the one line in `config.js` and
redeploy. Nothing else refers to it.
