# What changed since the version you deployed

Your live site is at commit `fd0de72`. Fourteen of the files it serves
have changed since then.

## The fourteen files

| File | | What changed |
|---|---|---|
| `_headers` | **new** | Security headers: CSP naming your Supabase project, `frame-ancestors 'none'`, `no-cache` on `config.js` and `index.html`. |
| `core/xlsx.js` | **new** | The Excel writer — no dependencies, builds a real multi-sheet `.xlsx` in the browser. |
| `core/layout.js` | **new** | Decides phone layout vs desktop layout, and holds the manual **View** override. |
| `index.html` | edit | The **View: Automatic / Mobile / Desktop** item in the user menu. |
| `assets/app.css` | edit | Phone layout moved off width-only media queries; 44px tap targets; 16px inputs; letterhead and A4 print styles; the red "Start fresh" card. |
| `core/app.js` | edit | Applies the layout before first paint; wires the View toggle; repaints the top bar after a settings save. |
| `core/ui.js` | edit | `letterhead()` for printed reports. |
| `core/store.js` | edit | `reloadSettings()` behind the Settings-save fix. |
| `core/db.js` | edit | Recognises `Invalid schema: bms` and says what to do about it. |
| `modules/reports.js` | edit | Excel export and the printable letterhead. |
| `modules/settings.js` | edit | Re-reads after saving; the **categories** screen; the **Start fresh** reset card. |
| `modules/charges.js` | edit | The payment dialog pre-fills the account from Settings. |
| `modules/users.js` | edit | **New role** button, and Remove on roles you made yourself. |
| `service-worker.js` | edit | Cache bumped to `v8` so browsers take the new code. |

## Do not upload only some of them

`modules/reports.js` imports `core/xlsx.js`; `core/app.js` imports
`core/layout.js`. Upload one without the other and that page loads to a
blank panel — a 404 on a module import produces no error message anywhere
the user can see.

Upload all 39 published files, or push the whole repository and let the
GitHub workflow deploy it. See `DEPLOY.md`.

## Not files — still required

These are database-side or settings-side and no upload will apply them:

1. **`sql/070_reset.sql`** and **`sql/080_roles.sql`** — both new. Run them
   in the Supabase SQL Editor. The first gives you the "Start fresh"
   buttons; the second gives you custom roles **and closes a privilege
   hole that exists in your live database right now** — any Admin can
   currently make themselves a Super Admin. Re-running `sql/BUNDLE_all.sql`
   does both and is still safe to run twice.
2. **`sql/FIX_DUPLICATE_CATEGORIES.sql`** — run once, if you have not
   already. Clears the doubled categories and stops them returning.
3. **Settings → building address.** Empty. The printed report letterhead
   uses it, so your PDFs currently show the name over a blank line.
