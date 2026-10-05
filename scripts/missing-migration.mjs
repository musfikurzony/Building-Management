/* =====================================================================
   missing-migration.mjs — how the app behaves when the code is newer
   than the database.

   WHY THIS EXISTS
   ---------------
   Every other suite runs against a database built from every migration
   file, so all of them are blind to the single most likely thing to go
   wrong in real use: the frontend deploys (a git push, automatically)
   and the SQL does not (a human, pasting into the Supabase SQL Editor,
   later). The two are not applied together and never will be.

   That happened. The Settings screen called a function the database had
   never heard of, showed a red "could not find the function
   bms.reset_preview" and no button — because the card caught every error
   the same way and returned nothing, so a missing migration was
   indistinguishable from "you are not a Super Admin".

   The rule this enforces: when the database is behind, the app says
   which file to run. It never shows a raw Postgres error, and it never
   silently omits the thing the person came looking for.

   Run: ./scripts/missing-migration.sh
   ===================================================================== */

import { chromium } from 'playwright';

const BASE = process.env.BASE || 'http://localhost:5196';
const results = [];
const check = (name, pass, detail) => {
  results.push({ name, pass: !!pass, detail });
  console.log(`${pass ? 'ok  ' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
};

async function signIn(page, email){
  await page.goto(BASE + '/index.html', { waitUntil:'domcontentloaded' });
  await page.evaluate(() => { try { localStorage.clear(); } catch {} });
  await page.reload({ waitUntil:'domcontentloaded' });
  await page.waitForSelector('.auth-card', { timeout:15000 });
  await page.fill('input[type=email]', email);
  await page.fill('input[type=password]', 'devpassword');
  await page.click('button[type=submit]');
  await page.waitForFunction(() => !document.querySelector('.auth-card'), { timeout:15000 });
  await page.waitForTimeout(700);
}
const toasts = (page) => page.evaluate(() =>
  [...document.querySelectorAll('#toasts .toast')].map(t => ({ kind: t.className, text: t.textContent })));

const run = async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM || undefined,
    args: ['--no-sandbox','--disable-dev-shm-usage'] });
  const page = await (await browser.newContext({ viewport:{ width:1280, height:950 } })).newPage();

  await signIn(page, 'admin@test');
  await page.evaluate(() => { location.hash = '#/settings'; });
  await page.waitForTimeout(2600);

  /* ---- the exact symptom that was reported ---- */
  const t = await toasts(page);
  const raw = t.filter(x => /toast err/.test(x.kind) &&
                            /does not exist|schema cache|PGRST/i.test(x.text));
  check('no raw database error is shown on the settings screen',
        raw.length === 0, raw.map(x => x.text).join(' | '));

  const card = await page.evaluate(() => {
    const c = document.querySelector('.danger-zone');
    return c ? c.innerText : null;
  });
  check('the Start fresh card is still on the page', card !== null);
  check('and it names the file to run',
        card && /070_reset\.sql/.test(card), (card || '').slice(0, 90).replace(/\s+/g,' '));
  check('in words rather than as an error',
        card && !/does not exist|schema cache/i.test(card));

  /* ---- the rest of Settings must still work ---- */
  check('the building settings form still renders',
        await page.isVisible('main input[type=text]'));
  const catCard = await page.evaluate(() =>
    [...document.querySelectorAll('main h2')].some(h => /categories/i.test(h.textContent)));
  check('the categories list still renders without 080_roles.sql', catCard);

  // Editing a category must not silently allow the direction to change:
  // without category_usage the app cannot tell whether anything is filed
  // under it, and guessing would flip the sign of past entries.
  await page.evaluate(() => {
    const b = [...document.querySelectorAll('main button')].find(x => /^Edit$/.test(x.textContent.trim()));
    b && b.click();
  });
  await page.waitForTimeout(1200);
  const locked = await page.evaluate(() => {
    const f = [...document.querySelectorAll('.modal label.field')]
      .find(x => /Income or expense/.test(x.querySelector('span')?.textContent || ''));
    const sel = f?.querySelector('select');
    return { present: !!sel, disabled: !!sel?.disabled,
             hint: f?.querySelector('.hint')?.textContent || '' };
  });
  check('a category direction cannot be changed while usage is unknown',
        locked.present && locked.disabled, JSON.stringify(locked));
  check('and the reason names the missing file',
        /080_roles\.sql/.test(locked.hint), locked.hint.slice(0, 70));
  await page.keyboard.press('Escape');
  await page.waitForTimeout(400);

  /* ---- and a role that cannot be created says why ---- */
  await page.evaluate(() => { location.hash = '#/users/roles'; });
  await page.waitForTimeout(1800);
  await page.evaluate(() => {
    const b = document.querySelector('main button.btn.primary');
    b && b.click();
  });
  await page.waitForTimeout(900);
  if (await page.isVisible('.modal')){
    await page.fill('.modal input[type=text]', 'Generator Operator');
    await page.evaluate(() => {
      const b = [...document.querySelectorAll('.modal button')].find(x => /Create role/.test(x.textContent));
      b && b.click();
    });
    await page.waitForTimeout(1800);
    const t2 = await toasts(page);
    const named = t2.some(x => /080_roles\.sql/.test(x.text));
    const rawer = t2.some(x => /does not exist|schema cache/i.test(x.text));
    check('creating a role without its migration names the file', named,
          t2.map(x => x.text).join(' | ').slice(0, 110));
    check('and does not show the raw Postgres message', !rawer);
  } else {
    check('the New role dialog opens', false, 'no modal');
  }

  /* ---- 085: owners, tenants and reminders ---- */
  const remCard = await page.evaluate(async () => {
    location.hash = '#/settings';
    await new Promise(r => setTimeout(r, 2200));
    const c = document.querySelector('#reminder-settings');
    return c ? c.innerText : null;
  });
  check('Settings still shows a Reminder messages card without 085', remCard !== null);
  check('and it says to run PATCH.sql', remCard && /PATCH\.sql/.test(remCard), (remCard || '').slice(0, 90).replace(/\s+/g,' '));
  let lastToasts = [];
  check('the building settings still save without 085', await (async () => {
    await page.evaluate(() => {
      document.querySelector('#toasts')?.replaceChildren();
      [...document.querySelectorAll('main button')].find(b => b.textContent.trim() === 'Save settings')?.click();
    });
    await page.waitForTimeout(1500);
    const t3 = lastToasts = await toasts(page);
    return t3.some(x => /toast ok/.test(x.kind) && /Saved/.test(x.text)) && !t3.some(x => /toast err/.test(x.kind));
  })(), JSON.stringify(lastToasts).slice(0, 160));

  await page.evaluate(() => { document.querySelector('#toasts')?.replaceChildren(); location.hash = '#/flats'; });
  await page.waitForTimeout(2000);
  const flatsOk = await page.evaluate(() => ({
    rows: document.querySelectorAll('main tbody tr').length,
    edit: [...document.querySelectorAll('main tbody button')].filter(b => b.textContent.trim() === 'Edit').length,
    text: document.querySelector('main').innerText }));
  check('the flats list renders without 085', flatsOk.rows > 0, `${flatsOk.rows} rows`);
  check('with an Edit button on each flat', flatsOk.edit === flatsOk.rows, `${flatsOk.edit} buttons`);
  check('and says tenants need the update', /PATCH\.sql/.test(flatsOk.text));

  await page.evaluate(() => document.querySelector('main tbody tr')?.click());
  await page.waitForTimeout(2000);
  const flatPage = await page.evaluate(() => document.querySelector('main').innerText);
  check('a flat page opens without 085', /^Flat /m.test(flatPage) && /Edit flat/.test(flatPage), flatPage.slice(0, 60).replace(/\s+/g,' '));
  check('and explains owners and tenants need the update', /Managing owners and tenants needs a database update/.test(flatPage));

  await page.evaluate(() => { location.hash = '#/charges/outstanding'; });
  await page.waitForTimeout(2000);
  const remBtn = await page.evaluate(() => {
    const b = [...document.querySelectorAll('main button')].find(x => x.textContent.trim() === 'Remind');
    if (b) b.click();
    return !!b;
  });
  check('the outstanding list still offers Remind', remBtn);
  await page.waitForTimeout(1500);
  const remModal = await page.evaluate(() => document.querySelector('.modal')?.innerText || '');
  check('and Remind explains which file to run instead of failing', /085_people_reminders\.sql|PATCH\.sql/.test(remModal), remModal.slice(0, 80).replace(/\s+/g,' '));
  await page.keyboard.press('Escape');

  const tAll = await toasts(page);
  const rawAll = tAll.filter(x => /toast err/.test(x.kind) && /does not exist|schema cache|PGRST/i.test(x.text));
  check('no raw database error anywhere in the 085 screens', rawAll.length === 0, rawAll.map(x => x.text).join(' | '));

  /* ---- 086: the monthly report ---- */
  await page.evaluate(() => { document.querySelector('#toasts')?.replaceChildren(); location.hash = '#/reports'; });
  await page.waitForTimeout(2200);
  const rep = await page.textContent('main');
  check('the monthly report says it needs the update, without 086', /needs a database update/.test(rep) && /PATCH\.sql/.test(rep), rep.slice(0, 120).replace(/\s+/g,' '));
  check('and does not show a raw error', !/does not exist|schema cache|PGRST/.test(rep));
  await page.evaluate(() => { location.hash = '#/reports/entries'; });
  await page.waitForTimeout(2000);
  check('"Search entries" still works without 086', /All entries|Income by department/.test(await page.textContent('main')));
  await page.evaluate(() => { location.hash = '#/charges/payments'; });
  await page.waitForTimeout(1500);
  check('the payments list renders without 085/086', /Payments received/.test(await page.textContent('main')));
  const t9 = await toasts(page);
  check('no raw database error on the 086 screens',
        !t9.some(x => /toast err/.test(x.kind) && /does not exist|schema cache|PGRST/i.test(x.text)), JSON.stringify(t9).slice(0, 160));

  await browser.close();
  const failed = results.filter(r => !r.pass);
  console.log(`\n${results.length - failed.length} of ${results.length} degraded-mode checks passed`);
  process.exit(failed.length ? 1 : 0);
};

run().catch(e => { console.error(e); process.exit(2); });
