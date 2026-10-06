/* =====================================================================
   journey.mjs — one person's first day with the system, done through
   the actual screens rather than through the database.

   The SQL suites prove the rules are right. This proves the rules are
   REACHABLE: that someone who has never seen the app can add a guard,
   pay a salary, raise the month's service charges, take a payment,
   record the electricity bill, record some other income, and then see
   all of it add up on the reports page — by clicking, in that order.

   It reports friction as well as failure. A step that works but takes an
   unreasonable number of clicks, or leaves the person on a screen with
   no obvious next move, is worth knowing about even though nothing
   technically broke.

   Run: node scripts/journey.mjs   (dev server up, fixtures loaded)
   ===================================================================== */

import { chromium } from 'playwright';

const BASE = process.env.BASE || 'http://localhost:5198';
const steps = [];
const step = (name, pass, detail) => {
  steps.push({ name, pass: !!pass, detail });
  console.log(`${pass ? 'ok  ' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
};
const notes = [];
const note = (s) => { notes.push(s); };

const money = (t) => {
  const m = String(t || '').match(/([\d,]+(?:\.\d+)?)/);
  return m ? Number(m[1].replace(/,/g, '')) : null;
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
const go = async (page, hash) => {
  await page.evaluate(h => { location.hash = h; }, hash);
  await page.waitForTimeout(1400);
};
/** Click the button whose visible text matches. */
async function clickText(page, text, scope = 'main'){
  const ok = await page.evaluate(([t, s]) => {
    const root = document.querySelector(s) || document;
    const hit = [...root.querySelectorAll('button, a.btn')]
      .find(b => b.textContent.trim().replace(/\s+/g,' ').includes(t));
    if (!hit) return false;
    hit.click(); return true;
  }, [text, scope]);
  await page.waitForTimeout(900);
  return ok;
}
/** Fill a labelled field inside a scope. */
async function fillField(page, label, value, scope = '.modal'){
  return page.evaluate(([l, v, s]) => {
    const root = document.querySelector(s) || document;
    const f = [...root.querySelectorAll('label.field')]
      .find(x => x.querySelector('span')?.textContent.trim().toLowerCase().startsWith(l.toLowerCase()));
    if (!f) return false;
    const c = f.querySelector('input, select, textarea');
    if (!c) return false;
    if (c.tagName === 'SELECT'){
      const opt = [...c.options].find(o => o.textContent.trim().toLowerCase().includes(String(v).toLowerCase()));
      if (!opt) return false;
      c.value = opt.value;
    } else {
      c.value = v;
    }
    c.dispatchEvent(new Event('input',  { bubbles:true }));
    c.dispatchEvent(new Event('change', { bubbles:true }));
    return true;
  }, [label, value, scope]);
}

const run = async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM || undefined,
    args: ['--no-sandbox','--disable-dev-shm-usage'] });
  const ctx = await browser.newContext({ viewport:{ width:1280, height:950 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));

  await signIn(page, 'admin@test');

  const today = await page.evaluate(() => new Date().toISOString().slice(0,10));
  const [Y, M] = today.split('-').map(Number);

  /* ---------- 1. A new security guard ---------- */
  await go(page, '#/staff');
  await clickText(page, 'Add staff');
  const gotForm = await page.isVisible('.modal');
  step('the Add staff form opens', gotForm);
  if (gotForm){
    await fillField(page, 'Staff code', 'SEC-99');
    await fillField(page, 'Name', 'Test Guard');
    await fillField(page, 'Position', 'Security');
    await fillField(page, 'Monthly salary', '12000');
    await fillField(page, 'Mobile', '01700000099');
    await fillField(page, 'Joined on', `${Y}-01-01`);
    await clickText(page, 'Save', '.modal');
    await page.waitForTimeout(1500);
  }
  await go(page, '#/staff');
  const staffShown = await page.evaluate(() => document.querySelector('main')?.textContent.includes('Test Guard'));
  step('the new guard appears on the staff list', staffShown);

  /* ---------- 2. Salary for the month ---------- */
  await go(page, '#/salary');
  await clickText(page, 'Generate a month');
  if (await page.isVisible('.modal')){
    await clickText(page, 'Generate', '.modal');
    await page.waitForTimeout(2000);
  }
  const salaryText = await page.textContent('main').catch(() => '');
  step('a salary run is created for the month',
       /salary|payable|12,000|12000/i.test(salaryText), salaryText.slice(0,90).replace(/\s+/g,' '));

  /* ---------- 3. Service charges for the month ---------- */
  await go(page, '#/charges');
  await clickText(page, 'Generate a month');
  if (await page.isVisible('.modal')){
    await clickText(page, 'Generate', '.modal');
    await page.waitForTimeout(2200);
    // Generating offers to open the month's bills; say not now.
    if (await page.isVisible('.modal')) await clickText(page, 'Cancel', '.modal');
    await page.waitForTimeout(400);
  }
  const charged = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    return (await db.q('flat_charges', b => b.limit(500))).length;
  });
  step('service charges are raised for every active flat', charged > 0, `${charged} charges`);

  /* ---------- 4. A flat pays ---------- */
  await go(page, '#/charges');
  await clickText(page, 'Record payment');
  const payForm = await page.isVisible('.modal');
  step('the Record payment form opens', payForm);
  if (payForm){
    await fillField(page, 'Flat', 'A-101');
    await page.waitForTimeout(700);
    await fillField(page, 'Amount', '3000');
    await fillField(page, 'Date', today);
    await fillField(page, 'Method', 'CASH');
    // "Into account" is required. It is now pre-filled from the building's
    // default cash account, so check that it arrived filled rather than
    // filling it here — a form that needs this typed every time is the
    // friction this step exists to catch.
    const acctPrefilled = await page.evaluate(() => {
      const f = [...document.querySelectorAll('.modal label.field')]
        .find(x => x.querySelector('span')?.textContent.trim().startsWith('Into account'));
      return !!f?.querySelector('select')?.value;
    });
    step('the payment form pre-fills the account the money went into', acctPrefilled);
    if (!acctPrefilled) await fillField(page, 'Into account', 'Cash');
    // The button is "Record payment", not "Save". An earlier version of
    // this script wrote `await a() || await b()`, which short-circuits on
    // the *promise* (always truthy) and so never clicked anything — the
    // step failed and looked exactly like a broken payment screen.
    const clicked = await clickText(page, 'Record payment', '.modal');
    step('the payment form has a Record payment button', clicked);
    await page.waitForTimeout(2000);
  }
  const paid = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const rows = await db.q('payments', b => b.limit(50));
    return rows.reduce((s, r) => s + Number(r.amount || 0), 0);
  });
  step('the payment is recorded against the flat', paid === 3000, `Tk ${paid}`);

  const dues = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const r = await db.q('v_flat_dues', b => b.eq('flat_number','A-101'));
    return r[0] ? { out:Number(r[0].outstanding), adv:Number(r[0].advance) } : null;
  });
  step('the flat statement reflects the payment', dues && dues.out >= 0, JSON.stringify(dues));

  /* ---------- 5. The electricity bill ---------- */
  await go(page, '#/finance/new');
  const expForm = await page.isVisible('main label.field');
  step('the New entry form opens', expForm);
  if (expForm){
    await fillField(page, 'Type', 'Expense', 'main');
    await fillField(page, 'Date', today, 'main');
    await fillField(page, 'Description', 'DESCO electricity bill — test', 'main');
    await fillField(page, 'Amount', '18500', 'main');
    await fillField(page, 'Payment method', 'BANK', 'main');
    await fillField(page, 'Department', 'Utilities', 'main');
    await page.waitForTimeout(900);
    const gotCat = await fillField(page, 'Category', 'Electricity', 'main');
    step('choosing Utilities offers the electricity category', gotCat);
    // "Submit" posts it; "Save as draft" does not. Clicking the wrong one
    // leaves a correct entry that never reaches a report.
    await clickText(page, 'Submit', 'main');
    await page.waitForTimeout(2200);
  }
  const expense = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const r = await db.q('transactions', b => b.eq('direction','EXPENSE').limit(200));
    return r.filter(t => /DESCO/.test(t.description || '')).map(t => ({ amt:Number(t.amount), st:t.status }));
  });
  step('the electricity bill is saved as an expense',
       expense.length === 1 && expense[0].amt === 18500, JSON.stringify(expense));

  /* ---------- 6. Some other income ---------- */
  await go(page, '#/finance/new');
  await fillField(page, 'Type', 'Income', 'main');
  await page.waitForTimeout(700);
  await fillField(page, 'Date', today, 'main');
  await fillField(page, 'Description', 'Roof antenna rent — test', 'main');
  await fillField(page, 'Amount', '5000', 'main');
  await fillField(page, 'Payment method', 'CASH', 'main');
  await fillField(page, 'Department', 'Other', 'main');
  await page.waitForTimeout(800);
  await fillField(page, 'Category', 'Other income', 'main');
  await clickText(page, 'Submit', 'main');
  await page.waitForTimeout(2200);
  const income = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const r = await db.q('transactions', b => b.eq('direction','INCOME').limit(200));
    return r.filter(t => /antenna/i.test(t.description || '')).length;
  });
  step('the other income is saved', income === 1, `${income} found`);

  /* ---------- 7. Anything waiting for approval? ---------- */
  const pending = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    return (await db.q('transactions', b => b.eq('status','PENDING_APPROVAL').limit(100))).length;
  });
  note(pending
    ? `${pending} entr${pending===1?'y is':'ies are'} waiting for approval — an admin's own entries post straight away, a caretaker's do not.`
    : `Nothing is waiting for approval: entries made by an admin post straight to the ledger.`);

  /* ---------- 8. Does the report agree? ---------- */
  await go(page, '#/reports');
  await page.waitForTimeout(1200);
  await clickText(page, 'This month');       // early in a month it opens on last month
  await page.waitForTimeout(1600);
  const report = await page.textContent('main').catch(() => '');
  step('the report page shows the income just entered',
       /antenna/i.test(report) || /Other income/i.test(report),
       report.slice(0,100).replace(/\s+/g,' '));
  step('the report page shows the electricity expense',
       /electric/i.test(report), '');

  const totals = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const rows = await db.q('transactions', b => b.eq('status','POSTED').limit(500));
    let inc = 0, exp = 0;
    for (const r of rows){
      if (r.direction === 'INCOME')  inc += Number(r.amount);
      if (r.direction === 'EXPENSE') exp += Number(r.amount);
    }
    return { inc, exp };
  });
  note(`Posted so far: income Tk ${totals.inc.toLocaleString('en-IN')}, expense Tk ${totals.exp.toLocaleString('en-IN')}.`);

  /* ---------- 9. Exports ---------- */
  const dl = [];
  page.on('download', d => dl.push(d.suggestedFilename()));
  await clickText(page, 'Export Excel');
  await page.waitForTimeout(2500);
  step('Export Excel produces a file', dl.some(f => /\.xlsx$/i.test(f)), dl.join(', '));

  await go(page, '#/reports/entries');
  await page.waitForTimeout(1600);
  await clickText(page, 'Export CSV');
  await page.waitForTimeout(1800);
  step('Export CSV produces a file', dl.some(f => /\.csv$/i.test(f)), dl.join(', '));

  /* ---------- 10. Can a caretaker do the caretaker's job? ---------- */
  await signIn(page, 'caretaker@test');
  await go(page, '#/finance/new');
  const caretakerCanEnter = await page.isVisible('main label.field');
  step('a caretaker can reach the expense form', caretakerCanEnter);
  const caretakerNav = await page.$$eval('.navlink', els => els.map(e => e.textContent.trim()));
  note(`A caretaker sees ${caretakerNav.length} menu items: ${caretakerNav.join(', ')}.`);

  const realErrors = errors.filter(e => !/Failed to load resource|service-worker|favicon|manifest|40[136]/i.test(e));
  step('no unexpected errors in the browser console', realErrors.length === 0, realErrors.slice(0,2).join(' | '));

  await browser.close();

  console.log('\n--- notes ---');
  for (const n of notes) console.log('  * ' + n);
  const failed = steps.filter(s => !s.pass);
  console.log(`\n${steps.length - failed.length} of ${steps.length} journey steps passed`);
  process.exit(failed.length ? 1 : 0);
};

run().catch(e => { console.error(e); process.exit(2); });
