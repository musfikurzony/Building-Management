# Backup and restore

A backup you have never restored is a rumour. This page is short on purpose:
do it, do not just read it.

## What has to be backed up

| Thing | Where it lives | How it is lost |
|---|---|---|
| The building's books | `bms` schema in Postgres | a bad migration, a mistaken bulk update, an accidental project deletion |
| Receipts and photos | `bms-receipts`, `bms-photos`, `bms-documents` | the same, plus quota problems |
| The schema itself | `sql/*.sql` in this repository | nothing, as long as the repo is pushed |

The last row is why every change to the database goes into a file here first.

## Free tier — the honest position

**There is no point-in-time recovery on the free tier.** If something damages
the data at 3pm, there is no "restore to 2:55pm". Daily snapshots and PITR
come with the paid plans.

While you are on the free tier, the monthly export below IS your backup, and
it is only as good as the last time you ran it. Before the first real taka is
recorded, move to a paid plan.

Free-tier projects also pause after a period of inactivity. That is survivable
during development and unacceptable once the caretaker needs to log a payment
on a Friday evening.

## The monthly export (do this on the 1st)

1. Supabase → **Database → Backups → Download** (paid plans), or on free tier
   use the SQL Editor:

   ```sql
   -- The whole building ledger, as rows you can read.
   SELECT * FROM bms.transactions ORDER BY txn_date;
   SELECT * FROM bms.ledger_entries ORDER BY entry_date;
   SELECT * FROM bms.flat_charges ORDER BY period_year, period_month;
   SELECT * FROM bms.payments ORDER BY payment_date;
   SELECT * FROM bms.payment_allocations;
   SELECT * FROM bms.flats; SELECT * FROM bms.owners;
   SELECT * FROM bms.accounts; SELECT * FROM bms.audit_log ORDER BY id;
   ```

   Download each as CSV.

2. Or, better, from a machine with `psql` installed:

   ```bash
   pg_dump "postgresql://postgres:PASSWORD@db.YOURPROJECT.supabase.co:5432/postgres" \
     --schema=bms --no-owner --no-privileges \
     -f building-backup-$(date +%Y-%m-%d).sql
   ```

   That one file is the entire building system. Add `--schema=auth` if you
   also want the login accounts; without it you would re-invite people after
   a restore, which is survivable but annoying.

3. From the app, use **Export CSV** on the ledger, the outstanding report and
   the audit log. Those three are what an auditor or a committee would ask for.

4. Put the files somewhere that is not Supabase and not only your laptop.

## The restore drill — do this BEFORE going live, then once a year

1. Create a **new, empty** Supabase project. Call it something obviously
   temporary.
2. Restore into it:

   ```bash
   psql "postgresql://postgres:PASSWORD@db.SCRATCHPROJECT.supabase.co:5432/postgres" \
     -f building-backup-2026-08-01.sql
   ```

3. Point a local copy of `config.js` at the scratch project and open the app.
4. Check three numbers against the real system:
   - the bank balance on the Bank screen,
   - total outstanding on the Outstanding report,
   - the number of rows in the audit log.
5. If all three match, the backup works. Delete the scratch project.
6. Write down the date you did this. That date is the answer to "when did we
   last prove we could recover?"

## What is deliberately not automatic

Nothing in this application deletes anything. There is no purge job, no
retention policy, no "archive old transactions" button. Storage is cheap;
a missing year of a building's accounts is not.
