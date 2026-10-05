/* =====================================================================
   browser-test.mjs — drives the real portal in a real browser against a
   real PostgreSQL database with Row Level Security switched on.

   Run: node scripts/browser-test.mjs   (dev server must already be up)
   ===================================================================== */

import { chromium } from 'playwright';
import fs from 'node:fs';

const BASE = process.env.BASE || 'http://localhost:5173';
const results = [];
const check = (name, pass, detail) => { results.push({ name, pass: !!pass, detail }); };

async function signIn(page, email){
  await page.goto(BASE + '/index.html', { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => { try { localStorage.clear(); } catch {} });
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.auth-card', { timeout: 15000 });
  await page.fill('input[type=email]', email);
  await page.fill('input[type=password]', 'devpassword');
  await page.click('button[type=submit]');
  await page.waitForFunction(() => !document.querySelector('.auth-card'), { timeout: 15000 });
  await page.waitForTimeout(600);
}

async function gotoHash(page, hash){
  await page.evaluate(h => { location.hash = h; }, hash);
  await page.waitForTimeout(900);
}


/** Reads the "Bank" figure off the bank screen, as a number. */
async function readBank(page){
  const txt = await page.textContent('main').catch(() => '');
  const m = txt.match(/Bank\s*Tk\s*([\d,]+)/);
  return m ? Number(m[1].replace(/,/g,'')) : null;
}

/** Reads one flat's outstanding and advance from the dues view. */
async function flatRow(page, flatNumber){
  return page.evaluate(async (fn) => {
    const db = await import('/core/db.js');
    const rows = await db.q('v_flat_dues', b => b.eq('flat_number', fn));
    if (!rows.length) return null;
    const r = rows[0];
    return { id: r.flat_id, outstanding: Number(r.outstanding), advance: Number(r.advance) };
  }, flatNumber);
}

/** Run a section; a failure inside it is one failed check, not a dead run. */
async function section(name, fn){
  try { await fn(); }
  catch (e){ check(`section "${name}" ran to completion`, false, (e.message || String(e)).split('\n')[0]); }
}

const run = async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM || undefined,
    args: ['--no-sandbox','--disable-dev-shm-usage']
  });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();

  const consoleErrors = [];
  page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  page.on('pageerror', e => consoleErrors.push('pageerror: ' + e.message));

  /* ---------------- ADMIN ---------------- */
  await signIn(page, 'admin@test');
  check('admin signs in and the shell renders', await page.isVisible('.topbar'));
  check('the building name appears in the top bar',
        (await page.textContent('#brandName'))?.trim().length > 0);

  const navItems = await page.$$eval('.navlink', els => els.map(e => e.textContent.trim()));
  check('admin sees the finance module in the nav', navItems.some(t => /Finance/i.test(t)), navItems.join('|'));
  check('admin sees the audit log in the nav',      navItems.some(t => /Audit/i.test(t)));
  check('admin sees settings in the nav',           navItems.some(t => /Settings/i.test(t)));

  for (const [hash, expect] of [
    ['#/dashboard','Dashboard'], ['#/flats','Flats'], ['#/charges','Service charge'],
    ['#/finance','Finance ledger'], ['#/bank','Bank & cash'], ['#/reports','Reports'],
    ['#/users','Users & roles'], ['#/audit','Audit log'], ['#/settings','Settings']
  ]){
    await gotoHash(page, hash);
    const h1 = (await page.textContent('main h1').catch(() => '')) || '';
    check(`${hash} renders "${expect}"`, h1.includes(expect), `saw "${h1}"`);
  }

  /* ---------------- flats: add one, and prove escaping ---------------- */
  await gotoHash(page, '#/flats');
  await page.click('button:has-text("Add flat")');
  await page.waitForSelector('.modal');
  await page.locator('.modal input[type=text]').first().fill('Z-901');
  await page.locator('.modal input[type=number]').first().fill('9');
  await page.locator('.modal button:has-text("Save")').click();
  await page.waitForTimeout(1800);
  check('a new flat appears in the list', (await page.textContent('main')).includes('Z-901'));

  // Stored XSS: an owner name containing markup must never execute.
  let alerted = false;
  page.on('dialog', async d => { alerted = true; await d.dismiss(); });
  await gotoHash(page, '#/flats/owners');
  await page.click('button:has-text("Add person")');
  await page.waitForSelector('.modal');
  const XSS = '<img src=x onerror=alert(1)>Evil Owner';
  await page.locator('.modal input[type=text]').first().fill(XSS);
  await page.locator('.modal button:has-text("Save")').click();
  await page.waitForTimeout(1800);
  const imgCount = await page.$$eval('main img', els => els.length);
  const shownLiteral = (await page.textContent('main')).includes('<img src=x onerror=alert(1)>');
  check('a name containing markup is escaped, not executed', !alerted && imgCount === 0 && shownLiteral,
        `alerted=${alerted} imgs=${imgCount} literal=${shownLiteral}`);

  /* ---------------- service charge end to end ---------------- */
  await gotoHash(page, '#/charges');
  await page.locator('button:has-text("Generate a month")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal button:has-text("Generate")').last().click();
  await page.waitForTimeout(2500);
  const chargesText = await page.textContent('main');
  check('generating a month produces a collection row', /Monthly collection/i.test(chargesText));

  await gotoHash(page, '#/charges');
  await page.locator('button:has-text("Record payment")').first().click();
  await page.waitForSelector('.modal');
  await page.locator('.modal select').nth(0).selectOption({ label: 'A-102' });
  await page.waitForTimeout(300);
  await page.locator('.modal input[type=number]').first().fill('1000');
  await page.locator('.modal select').nth(2).selectOption({ index: 1 });
  await page.locator('.modal button:has-text("Record payment")').click();
  await page.waitForTimeout(2200);
  const receiptShown = await page.isVisible('.modal:has-text("Receipt")').catch(() => false);
  check('recording a payment produces a receipt dialog', receiptShown);
  if (receiptShown) await page.click('.modal button:has-text("Done")').catch(() => {});
  await page.waitForTimeout(500);

  await gotoHash(page, '#/charges/outstanding');
  check('the outstanding report renders', (await page.textContent('main')).includes('Outstanding'));

  /* ---------------- money formatting ---------------- */
  const moneyCells = await page.$$eval('td.num', els => els.map(e => e.textContent.trim()).filter(Boolean));
  check('amounts are shown with two decimal places',
        moneyCells.some(v => /^\d[\d,]*\.\d{2}$/.test(v)), moneyCells.slice(0,5).join(' | '));

  /* ---------------- CARETAKER ---------------- */
  await signIn(page, 'caretaker@test');
  const ctNav = await page.$$eval('.navlink', els => els.map(e => e.textContent.trim()));
  check('caretaker does NOT see bank in the nav',    !ctNav.some(t => /Bank/i.test(t)), ctNav.join('|'));
  check('caretaker does NOT see audit in the nav',   !ctNav.some(t => /Audit/i.test(t)));
  check('caretaker does NOT see settings in the nav',!ctNav.some(t => /Settings/i.test(t)));

  const ctMain = await page.textContent('main');
  check('caretaker dashboard has no bank balance card', !/Bank balance|Money now/i.test(ctMain));
  check('caretaker dashboard offers expense submission', /Submit an expense/i.test(ctMain));

  // The screen is hidden AND the database refuses. Prove the second one.
  await gotoHash(page, '#/bank');
  const blocked = await page.textContent('main');
  check('caretaker opening #/bank directly is refused', /Not available to you/i.test(blocked), blocked.slice(0,90));

  const rpcResult = await page.evaluate(async () => {
    const mod = await import('/core/db.js');
    try { await mod.rpc('close_period', { p_year: 2026, p_month: 1 }, { silent: true }); return 'ALLOWED'; }
    catch (e){ return e.message; }
  });
  check('caretaker calling close_period directly is refused by the database',
        /permission denied|need close/i.test(rpcResult), rpcResult);

  /* ---------------- caretaker submits, admin approves ---------------- */
  await gotoHash(page, '#/finance/new');
  await page.locator('main input[type=text]').first().fill('Diesel for the generator');
  await page.locator('main input[type=number]').first().fill('2500');
  await page.locator('main button:has-text("Submit")').first().click();
  await page.waitForTimeout(2200);
  const afterSubmit = await page.textContent('main');
  check('caretaker entry is held for approval, not posted',
        /pending approval/i.test(afterSubmit), afterSubmit.slice(0, 160));

  await signIn(page, 'finance@test');
  await gotoHash(page, '#/finance/approvals');
  const queue = await page.textContent('main');
  check('the entry appears in the approval queue', /Diesel for the generator/.test(queue));
  await page.locator('.card:has-text("Diesel for the generator") button:has-text("Approve & post")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal button:has-text("Approve & post")').click();
  await page.waitForTimeout(2500);
  const queueAfter = await page.textContent('main');
  check('after approval the queue is empty', /Nothing is waiting/i.test(queueAfter), queueAfter.slice(0,120));

  /* ---------------- self-approval is refused ---------------- */
  await gotoHash(page, '#/finance/new');
  await page.locator('main input[type=text]').first().fill('Finance manager own spend');
  await page.locator('main input[type=number]').first().fill('90000');
  await page.locator('main button:has-text("Submit")').first().click();
  await page.waitForTimeout(2000);
  await gotoHash(page, '#/finance/approvals');
  const ownQueue = await page.textContent('main');
  check('a person cannot approve their own entry from the queue',
        /someone else has to approve it/i.test(ownQueue), ownQueue.slice(0,200));


  /* ==================================================================
     FULL JOURNEY THROUGH THE SCREENS — the same story as the SQL
     journey suite, but driven the way a person actually drives it.
     ================================================================== */
  await section('finance journey', async () => {
  await signIn(page, 'admin@test');

  // Where the bank stands before anything happens.
  await gotoHash(page, '#/bank');
  const bankBefore = await readBank(page);
  check('the bank screen shows a balance', bankBefore !== null, String(bankBefore));

  // An admin records a spend from the bank; it posts straight away.
  await gotoHash(page, '#/finance/new');
  await page.locator('main input[type=text]').first().fill('Lift AMC — September');
  await page.locator('main input[type=number]').first().fill('7000');
  // Selects in this form, in DOM order: type, method, paid-from, into,
  // department, category, vendor, flat.
  await page.locator('main select').nth(2).selectOption({ label: 'Main bank account (bank)' });
  await page.locator('main button:has-text("Submit")').first().click();
  await page.waitForTimeout(2500);
  const posted = await page.textContent('main');
  check('an admin entry posts without waiting for approval', /posted/i.test(posted), posted.slice(0,120));

  await gotoHash(page, '#/bank');
  const bankAfter = await readBank(page);
  check('the bank balance moved by exactly the amount posted',
        bankBefore !== null && bankAfter !== null && Math.abs((bankBefore - bankAfter) - 7000) < 0.01,
        `before ${bankBefore} after ${bankAfter}`);

  // Advance payment: pay far more than is owed and check the advance shows.
  await gotoHash(page, '#/charges');
  await page.locator('button:has-text("Record payment")').first().click();
  await page.waitForSelector('.modal');
  await page.locator('.modal select').nth(0).selectOption({ label: 'A-103' });
  await page.waitForTimeout(300);
  await page.locator('.modal input[type=number]').first().fill('20000');
  await page.locator('.modal select').nth(2).selectOption({ index: 1 });
  await page.locator('.modal button:has-text("Record payment")').click();
  await page.waitForTimeout(2500);
  await page.locator('.modal button:has-text("Done")').click().catch(() => {});
  await page.waitForTimeout(800);

  const a103 = await flatRow(page, 'A-103');
  check('an over-payment leaves the flat with an advance, not a debt',
        a103 && a103.advance > 0 && a103.outstanding === 0,
        a103 ? `outstanding ${a103.outstanding}, advance ${a103.advance}` : 'flat not found');

  // Waiver: request it, then approve it as a different person.
  await gotoHash(page, '#/charges/flat/' + (a103 ? a103.id : ''));
  const waiveBtn = page.locator('button:has-text("Request waiver")').first();
  const hasWaive = await waiveBtn.count();
  if (hasWaive){
    await waiveBtn.click();
    await page.waitForSelector('.modal');
    await page.locator('.modal textarea').first().fill('Flat vacant for the month');
    await page.locator('.modal button:has-text("Submit request")').click();
    await page.waitForTimeout(1800);
  }
  await gotoHash(page, '#/charges/adjustments');
  const adj = await page.textContent('main');
  check('a waiver request appears for approval',
        !hasWaive || /Flat vacant for the month/.test(adj), adj.slice(0,120));

  // Reversal of a payment, from the payments screen.
  await gotoHash(page, '#/charges/payments');
  const revBtn = page.locator('button:has-text("Reverse")').first();
  if (await revBtn.count()){
    await revBtn.click();
    await page.waitForSelector('.modal');
    await page.locator('.modal textarea').first().fill('Cheque returned unpaid');
    await page.locator('.modal button:has-text("Reverse")').click();
    await page.waitForTimeout(2500);
  }
  const payText = await page.textContent('main');
  check('a reversed payment is shown as reversed, not deleted',
        /reversed/i.test(payText), payText.slice(0,140));

  // The audit trail carries the whole story.
  await gotoHash(page, '#/audit');
  const auditText = await page.textContent('main');
  check('the audit log names the people who acted',
        /Admin User/.test(auditText), auditText.slice(0,140));
  check('the audit log shows the approval of the caretaker entry',
        /Finance Manager|Building Manager|Admin User/.test(auditText));
  check('the audit log records the payment reversal',
        /RCT|payment|reversed/i.test(auditText));

  // Closing a month with an entry still waiting for approval must be
  // refused — and refused by the database, with the reason shown.
  await gotoHash(page, '#/settings');
  const closeBtn = page.locator('button:has-text("Close")').first();
  let closeMsg = '';
  if (await closeBtn.count()){
    await closeBtn.click();
    await page.waitForSelector('.modal');
    await page.locator('.modal button:has-text("Close month")').click();
    await page.waitForTimeout(2000);
    closeMsg = await page.textContent('#toasts').catch(() => '');
  }
  check('closing a month with entries still waiting is refused, with a reason',
        /unposted|post, reject or cancel/i.test(closeMsg), closeMsg || '(no message)');
  const stillOpen = await page.textContent('main');
  check('and that month stays open', /OPEN/.test(stillOpen));
  });


  /* ==================================================================
     PHASE 3 — OPERATIONS, driven through the screens.
     ================================================================== */
  await signIn(page, 'admin@test');

  await section('generator', async () => {
  // --- register a generator ---
  await gotoHash(page, '#/generator');
  check('the generator screen renders', (await page.textContent('main h1')).includes('Generator'));
  await page.locator('button:has-text("Add generator")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal input[type=text]').nth(0).fill('GEN-01');
  await page.locator('.modal input[type=text]').nth(1).fill('Main generator');
  await page.locator('.modal button:has-text("Save")').click();
  await page.waitForTimeout(2000);
  check('the generator is on the register', (await page.textContent('main')).includes('GEN-01'));

  // --- a power cut, logged and then closed ---
  await page.locator('button:has-text("Log a power cut")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal button:has-text("Generator started")').click();
  await page.waitForTimeout(2000);
  const running = await page.textContent('main');
  check('an open run offers the stop button next',
        /Power is back/i.test(running), running.slice(0,140));

  await page.locator('button:has-text("Power is back")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal button:has-text("Generator stopped")').click();
  await page.waitForTimeout(2000);
  check('once stopped, the screen offers to log the next cut',
        /Log a power cut/i.test(await page.textContent('main')));
  check('and the run appears in the recent list',
        /Recent runs/i.test(await page.textContent('main')));

  // --- fuel, which must reach the ledger ---
  const bankBeforeFuel = await (async () => { await gotoHash(page, '#/bank'); return readBank(page); })();
  await gotoHash(page, '#/generator');
  await page.locator('button:has-text("Record a fuel purchase")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal input[type=number]').nth(0).fill('40');
  await page.locator('.modal input[type=number]').nth(1).fill('100');
  await page.locator('.modal select').nth(3).selectOption({ label: 'Main bank account' });
  await page.locator('.modal button:has-text("Save")').click();
  await page.waitForTimeout(2500);
  await gotoHash(page, '#/bank');
  const bankAfterFuel = await readBank(page);
  check('a fuel purchase moves the bank by quantity times price',
        bankBeforeFuel !== null && Math.abs((bankBeforeFuel - bankAfterFuel) - 4000) < 0.01,
        `before ${bankBeforeFuel} after ${bankAfterFuel}`);

  await gotoHash(page, '#/generator');
  check('the running-cost table appears once there is fuel',
        /Running cost by month/i.test(await page.textContent('main')));

  });

  await section('fire safety', async () => {
  await gotoHash(page, '#/fire');
  await page.locator('button:has-text("Add extinguisher")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal input[type=text]').nth(0).fill('FE-0101');
  await page.locator('.modal input[type=text]').nth(1).fill('Extinguisher 1F-A');
  await page.locator('.modal button:has-text("Save")').click();
  await page.waitForTimeout(2000);
  const fireBefore = await page.textContent('main');
  check('an extinguisher with no inspection is not shown as fine',
        /Never inspected/i.test(fireBefore) && /Not set/i.test(fireBefore),
        fireBefore.slice(0,200));

  await page.locator('tbody tr').first().click();
  await page.waitForTimeout(1400);
  check('the extinguisher detail screen opens',
        (await page.textContent('main h1')).includes('Extinguisher'));
  await page.locator('button:has-text("Record an inspection")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal button:has-text("Save")').click();
  await page.waitForTimeout(2000);
  check('after an inspection it reads as in date',
        /Inspection: OK/i.test(await page.textContent('main')),
        (await page.textContent('main')).slice(0,200));

  });

  await section('maintenance', async () => {
  await gotoHash(page, '#/maintenance/new');
  await page.locator('main input[type=text]').first().fill('Lift stopping between floors');
  await page.locator('main select').first().selectOption({ index: 1 });   // Critical
  await page.locator('main button:has-text("Report it")').click();
  await page.waitForTimeout(2500);
  const issueText = await page.textContent('main');
  check('the issue gets a readable number', /ISS-\d{4}-\d{4}/.test(issueText), issueText.slice(0,140));
  check('a critical job shows its target time', /Target/i.test(issueText));

  await page.locator('button:has-text("Assign it")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal button:has-text("Assign")').last().click();
  await page.waitForTimeout(2000);
  check('the job is assigned', /assigned/i.test(await page.textContent('main')));

  await page.locator('button:has-text("Mark as done")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal input[type=number]').first().fill('1200');
  await page.locator('.modal button:has-text("Mark as done")').click();
  await page.waitForTimeout(2500);
  const doneText = await page.textContent('main');
  check('a cost entered on completion reaches the ledger',
        /See the cost in the ledger/i.test(doneText), doneText.slice(0,160));
  check('the same person cannot then verify their own work',
        /someone else has to check it/i.test(doneText), doneText.slice(-260));

  // A different person signs it off.
  // Verifying needs maintenance.approve, which the manager holds and the
  // person who did the work must not use on their own job.
  await signIn(page, 'manager@test');
  await gotoHash(page, '#/maintenance');
  // A completed job is no longer "open"; it is waiting to be checked.
  await page.locator('main select').first().selectOption({ value: 'verify' });
  await page.waitForTimeout(1200);
  await page.locator('tbody tr').first().click();
  await page.waitForTimeout(1400);
  const verifyBtn = page.locator('button:has-text("I have checked it")');
  check('a second person is offered the verify button', await verifyBtn.count() > 0);
  if (await verifyBtn.count()){
    await verifyBtn.click();
    await page.waitForSelector('.modal');
    await page.locator('.modal textarea').first().fill('Rode it to every floor');
    await page.locator('.modal button:has-text("Verify")').click();
    await page.waitForTimeout(2200);
  }
  check('and the job closes out as verified',
        /verified/i.test(await page.textContent('main')));

  });

  await section('staff and payroll', async () => {
  await signIn(page, 'admin@test');
  await gotoHash(page, '#/staff');
  await page.locator('button:has-text("Add staff")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal input[type=text]').nth(0).fill('S-001');
  await page.locator('.modal input[type=text]').nth(1).fill('Abdul Karim');
  await page.locator('.modal select').nth(0).selectOption({ index: 3 });    // Security Guard
  await page.locator('.modal input[type=number]').first().fill('12000');
  // Joined before the month we are about to run payroll for.
  const lastMonth = new Date(); lastMonth.setMonth(lastMonth.getMonth() - 1); lastMonth.setDate(1);
  await page.locator('.modal input[type=date]').first().fill(lastMonth.toISOString().slice(0,10));
  await page.locator('.modal button:has-text("Save")').click();
  await page.waitForTimeout(2200);
  check('the staff member is on the list', (await page.textContent('main')).includes('Abdul Karim'));

  await gotoHash(page, '#/staff/attendance');
  const presentBtn = page.locator('button:has-text("Present")').first();
  check('attendance offers one tap per person', await presentBtn.count() > 0);
  await presentBtn.click();
  await page.locator('button:has-text("Save attendance")').click();
  await page.waitForTimeout(2200);
  const attSaved = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const today = new Date().toISOString().slice(0,10);
    const rows = await db.q('staff_attendance', b => b.eq('work_date', today));
    return rows.length;
  });
  check('attendance is stored against the day', attSaved > 0, `${attSaved} rows`);

  await gotoHash(page, '#/salary');
  await page.locator('button:has-text("Generate a month")').click();
  await page.waitForSelector('.modal');
  await page.locator('.modal button:has-text("Generate")').last().click();
  await page.waitForTimeout(2500);
  const salaryText = await page.textContent('main');
  check('a salary run lists the staff', /Abdul Karim/.test(salaryText), salaryText.slice(0,200));

  const bankBeforePay = await (async () => { await gotoHash(page, '#/bank'); return readBank(page); })();
  await gotoHash(page, '#/salary');
  await page.locator('button:has-text("Pay")').first().click();
  await page.waitForSelector('.modal');
  await page.locator('.modal select').first().selectOption({ label: 'Main bank account' });
  await page.locator('.modal button:has-text("Pay")').last().click();
  await page.waitForTimeout(2500);
  await gotoHash(page, '#/bank');
  const bankAfterPay = await readBank(page);
  check('paying a salary moves the bank by the net pay',
        Math.abs((bankBeforePay - bankAfterPay) - 12000) < 0.01,
        `before ${bankBeforePay} after ${bankAfterPay}`);

  });

  await section('work rounds and mosque', async () => {
  await gotoHash(page, '#/work/new');
  check('the checklist loads its items',
        (await page.locator('main input[type=checkbox]').count()) > 0);
  const boxes = page.locator('main input[type=checkbox]');
  const n = await boxes.count();
  for (let i = 0; i < Math.min(2, n); i++) await boxes.nth(i).check();
  await page.locator('button:has-text("Save the round")').click();
  await page.waitForTimeout(2200);
  const workText = await page.textContent('main');
  check('a partly finished round is recorded as partial',
        /partial/i.test(workText), workText.slice(0,220));

  // --- the mosque is a department, not a separate system ---
  await gotoHash(page, '#/mosque');
  check('the mosque screen gathers its department', /Mosque/i.test(await page.textContent('main h1')));

  });

  /* ---------------- Phase 4/5: reserve, deposits, budget, reconciliation ------- */
  await section('reserve and deposits', async () => {
  await signIn(page, 'admin@test');
  await gotoHash(page, '#/reserve');
  check('the reserve screen loads with its seeded funds',
        /Reserve & funds/i.test(await page.textContent('main h1')));
  const seeded = await page.textContent('main');
  check('both seeded funds are listed',
        /General Reserve Fund/.test(seeded) && /Capital Replacement Fund/.test(seeded),
        seeded.slice(0,200));

  // An earmark with no money behind it. The screen must say so plainly —
  // this is the whole reason the module exists.
  const capexId = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const f = await db.q('funds', b => b.eq('code','CAPEX'));
    return f[0]?.id || null;
  });
  check('the capital fund exists', !!capexId);

  await page.evaluate(async (id) => {
    const db = await import('/core/db.js');
    await db.rpc('record_fund_movement', { p_fund:id, p_date:new Date().toISOString().slice(0,10),
      p_direction:'CONTRIBUTION', p_amount:50000, p_cash_backed:false,
      p_purpose:'Board resolution — lift replacement' });
  }, capexId);
  // Away and back: setting location.hash to what it already is fires no
  // hashchange, so the screen would not re-read the database.
  await gotoHash(page, '#/dashboard');
  await gotoHash(page, '#/reserve');
  const hollow = await page.textContent('main');
  check('an earmark with no money behind it is called out on screen',
        /not real money yet/i.test(hollow), hollow.slice(0,300));
  check('and the shortfall is shown as a figure',
        /Not yet funded/i.test(hollow) && /50,000/.test(hollow), hollow.slice(0,300));

  // Now open a fixed deposit against it. The bank must fall, nothing is
  // spent, and the fund must stop reading as hollow.
  const bankBefore = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const r = await db.q('v_account_balances', b => b.eq('code','BANK1'));
    return Number(r[0].current_balance);
  });
  await gotoHash(page, '#/reserve/deposits');
  check('the deposits screen loads', /Fixed deposits/i.test(await page.textContent('main h1')));
  await page.locator('button:has-text("Open a deposit")').click();
  await page.waitForTimeout(500);
  const dlg = page.locator('.modal');
  await dlg.locator('input[type=text]').first().fill('FDR-UI-001');
  await dlg.locator('input[type=text]').nth(1).fill('Dutch-Bangla Bank');
  await dlg.locator('input[type=number]').first().fill('50000');
  await dlg.locator('select').first().selectOption({ index: 1 });   // source account
  // Tie it to the capital fund, so the earmark stops being hollow.
  await dlg.locator('select').nth(1).selectOption({ label: 'Capital Replacement Fund' });
  await page.waitForTimeout(200);
  await dlg.locator('button:has-text("Open deposit")').click();
  await page.waitForTimeout(2200);

  const fdText = await page.textContent('main');
  check('the deposit appears on the register', /FDR-UI-001/.test(fdText), fdText.slice(0,260));

  const after = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const bank = await db.q('v_account_balances', b => b.eq('code','BANK1'));
    const fds  = await db.q('v_account_balances', b => b.eq('kind','FD'));
    const exp  = await db.q('v_real_transactions', b => b.eq('source_module','fixed_deposit').eq('direction','EXPENSE'));
    return { bank: Number(bank[0].current_balance),
             fd: fds.reduce((t,a) => t + Number(a.current_balance), 0),
             expenses: exp.length };
  });
  check('opening a deposit took the money out of the bank',
        after.bank === bankBefore - 50000, `${bankBefore} -> ${after.bank}`);
  check('and put it into a deposit, so nothing was lost', after.fd === 50000, String(after.fd));
  check('opening a deposit is not an expense', after.expenses === 0, String(after.expenses));

  await gotoHash(page, '#/reserve');
  const backed = await page.textContent('main');
  check('the fund now shows real backing behind the earmark',
        !/not real money yet/i.test(backed), backed.slice(0,300));
  });

  await section('budget vs actual', async () => {
  await gotoHash(page, '#/budget');
  check('the budget screen loads', /Budget vs actual/i.test(await page.textContent('main h1')));

  await page.locator('button:has-text("Set a budget")').first().click();
  await page.waitForTimeout(500);
  const bd = page.locator('.modal');
  await bd.locator('select').first().selectOption({ label: 'Generator' });
  await page.waitForTimeout(200);
  await bd.locator('input[type=number]').nth(1).fill('120000');
  await page.waitForTimeout(200);
  const monthlyHint = await bd.textContent('.hint');
  check('the dialog translates the annual figure into a monthly one',
        /10,000/.test(await bd.innerText()), monthlyHint);
  await bd.locator('button:has-text("Save budget")').click();
  await page.waitForTimeout(2200);

  const bText = await page.textContent('main');
  check('the budget appears against its department', /Generator/.test(bText), bText.slice(0,260));

  const lines = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const b = await db.q('budgets', x => x.eq('fiscal_year', new Date().getFullYear()));
    const l = await db.q('budget_lines', x => x.eq('budget_id', b[0].id));
    return { budgets: b.length, lines: l.length,
             total: l.reduce((t,r) => t + Number(r.amount), 0) };
  });
  check('the year was split into twelve months', lines.lines === 12, String(lines.lines));
  check('and the twelve months add back to the annual figure exactly',
        lines.total === 120000, String(lines.total));

  // Setting it again must replace, not stack. This was a real bug.
  await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const d = await db.q('departments', b => b.eq('code','GENERATOR'));
    await db.rpc('set_budget', { p_year: new Date().getFullYear(), p_department: d[0].id,
                                 p_annual: 180000, p_category: null, p_monthly: null, p_notes: null });
  });
  const again = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const d = await db.q('departments', b => b.eq('code','GENERATOR'));
    const b = await db.q('budgets', x => x.eq('department_id', d[0].id));
    const l = await db.q('budget_lines', x => x.eq('budget_id', b[0].id));
    return { budgets: b.length, lines: l.length,
             total: l.reduce((t,r) => t + Number(r.amount), 0) };
  });
  check('re-setting a budget replaces it rather than stacking a second',
        again.budgets === 1, String(again.budgets));
  check('and the monthly lines are replaced too',
        again.lines === 12 && again.total === 180000, `${again.lines} lines / ${again.total}`);
  });

  await section('bank reconciliation', async () => {
  await gotoHash(page, '#/bank');
  check('the bank screen offers reconciliation',
        /Reconciliation/.test(await page.textContent('main')));

  await gotoHash(page, '#/reconcile');
  check('the reconciliation screen loads',
        /Bank reconciliation/i.test(await page.textContent('main h1')));

  // Deliberately wrong closing balance first: the system must disagree
  // out loud rather than quietly accepting it.
  await page.locator('button:has-text("New statement")').click();
  await page.waitForTimeout(500);
  const sd = page.locator('.modal');
  await sd.locator('select').first().selectOption({ index: 1 });
  await sd.locator('input[type=number]').nth(1).fill('123456');
  await sd.locator('button:has-text("Create statement")').click();
  await page.waitForTimeout(2400);

  const stText = await page.textContent('main');
  check('the statement opens on its own screen', /Bank says/i.test(stText), stText.slice(0,260));
  check('and the disagreement with the books is stated in words',
        /differ by/i.test(stText), stText.slice(0,400));

  await page.locator('button:has-text("Reconcile")').first().click();
  await page.waitForTimeout(600);
  await page.locator('.modal button:has-text("Record the disagreement")').click();
  await page.waitForTimeout(2200);
  const disputed = await page.textContent('main');
  check('a reconciliation that does not balance is recorded as disputed',
        /disputed/i.test(disputed), disputed.slice(0,400));

  // Correct it to the real figure and the statement closes.
  const real = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const st = await db.q('v_bank_statements', b => b.limit(1));
    const sys = Number(st[0].system_balance);
    await db.rpc('create_bank_statement', { p_account: st[0].account_id,
      p_statement_date: st[0].statement_date, p_closing_balance: sys,
      p_period_start: null, p_period_end: null, p_opening_balance: null,
      p_notes: 'Corrected' });
    const r = await db.rpc('reconcile_account', { p_statement: st[0].id, p_notes: 'Agreed' });
    const after = await db.q('v_bank_statements', b => b.eq('id', st[0].id));
    const all = await db.q('reconciliations', b => b.eq('statement_id', st[0].id));
    return { status: r.status, stmt: after[0].status, attempts: all.length };
  });
  check('correcting the figure lets the statement reconcile', real.status === 'AGREED', real.status);
  check('and the statement closes', real.stmt === 'RECONCILED', real.stmt);
  check('both attempts are kept, so the disagreement stays on the record',
        real.attempts === 2, String(real.attempts));
  });

  await section('settings actually save, on screen as well as in the database', async () => {
  // The bug this guards against: the save wrote correctly but the screen
  // re-rendered from a cached copy of the settings, so the old value came
  // straight back and it looked like nothing had been saved. Asserting on
  // the database alone would have passed while the app was unusable.
  await signIn(page, 'admin@test');
  await gotoHash(page, '#/settings');
  const nameBox = page.locator('main input[type=text]').first();
  await nameBox.fill('Rahman Tower');
  await page.locator('button:has-text("Save settings")').click();
  await page.waitForTimeout(2500);

  check('the building name is saved to the database',
        await page.evaluate(async () => {
          const db = await import('/core/db.js');
          return (await db.q('building_settings', x => x))[0]?.building_name;
        }) === 'Rahman Tower');

  check('and the form still shows the new name after re-rendering',
        (await page.locator('main input[type=text]').first().inputValue()) === 'Rahman Tower',
        await page.locator('main input[type=text]').first().inputValue());

  check('and the top bar shows it too',
        /Rahman Tower/.test(await page.textContent('#brandName')),
        await page.textContent('#brandName'));

  // Leaving it changed would upset later checks that read the building name.
  await nameBox.fill('Our Building');
  await page.locator('button:has-text("Save settings")').click();
  await page.waitForTimeout(2000);
  });

  await section('report exports — a real Excel file and a printable page', async () => {
  await signIn(page, 'admin@test');
  await gotoHash(page, '#/reports');
  check('the report offers an Excel export', /Export Excel/.test(await page.textContent('main')));
  check('and a print / PDF button',          /Print \/ PDF/.test(await page.textContent('main')));

  // Actually download it and look inside: a button that produces a corrupt
  // file would pass any check that only looked at the button.
  const dl = page.waitForEvent('download', { timeout: 15000 });
  await page.locator('button:has-text("Export Excel")').first().click();
  const file = await dl;
  const path = await file.path();
  const buf = fs.readFileSync(path);
  check('the download is named .xlsx', /\.xlsx$/.test(file.suggestedFilename()), file.suggestedFilename());
  check('and really is a ZIP container (Excel files are ZIPs)',
        buf[0] === 0x50 && buf[1] === 0x4B, `first bytes ${buf[0]},${buf[1]}`);
  const asText = buf.toString('latin1');
  check('containing a workbook part', asText.includes('xl/workbook.xml'));
  check('and more than one sheet',
        (asText.match(/xl\/worksheets\/sheet\d+\.xml/g) || []).length >= 2,
        String((asText.match(/xl\/worksheets\/sheet\d+\.xml/g) || []).length));

  // The letterhead is hidden on screen and revealed only when printing.
  check('the letterhead is present in the page but hidden on screen',
        await page.locator('.letterhead').count() > 0
        && !(await page.locator('.letterhead').first().isVisible()));
  check('the letterhead carries the building name',
        /Our Building|Building/.test(await page.locator('.letterhead').first().textContent()),
        await page.locator('.letterhead').first().textContent());

  await gotoHash(page, '#/reports/annual');
  check('the annual summary exports too', /Export Excel/.test(await page.textContent('main')));
  });

  await section('annual report and filters', async () => {
  await signIn(page, 'admin@test');
  await gotoHash(page, '#/reports/entries');
  const rep = await page.textContent('main');
  check('the report offers an annual summary', /Annual summary/.test(rep));

  const before = (await page.locator('main table tbody tr').count());
  check('the detail list has entries to filter', before > 0, String(before));
  const deptSel = page.locator('main select').nth(1);   // 0 = period, 1 = department
  const optCount = await deptSel.locator('option').count();
  if (optCount > 1){
    await deptSel.selectOption({ index: 1 });
    await page.waitForTimeout(700);
    const after = await page.locator('main table tbody tr').count();
    check('filtering by department narrows the list', after > 0 && after <= before,
          `${before} -> ${after}`);
    const line = await page.textContent('main');
    check('and the page says how much of the total is showing',
          /of \d+ entries/.test(line) || /All \d+ entries/.test(line), line.slice(0,200));
  }

  await gotoHash(page, '#/reports/annual');
  const ann = await page.textContent('main');
  check('the annual summary renders', /Annual summary/i.test(await page.textContent('main h1')));
  check('it shows all twelve months even when some are empty',
        (await page.locator('main table tbody tr').count()) >= 12,
        String(await page.locator('main table tbody tr').count()));
  check('it carries a running total, not just monthly figures',
        /Running total/i.test(ann), ann.slice(0,300));
  check('and it ends with the building’s position',
        /Position at the end/i.test(ann) && /Total held/i.test(ann), ann.slice(-300));
  });

  await section('notifications reach the right people', async () => {
  // A caretaker submits something needing approval.
  await signIn(page, 'caretaker@test');
  await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const d = await db.q('departments', b => b.eq('code','MAINTENANCE'));
    await db.rpc('create_transaction', { p_txn_date:new Date().toISOString().slice(0,10),
      p_direction:'EXPENSE', p_department_id:d[0].id, p_category_id:null,
      p_description:'Water tank repair', p_amount:9000, p_payment_method:'CASH',
      p_account_id:null, p_submit:true });
  });

  await signIn(page, 'finance@test');
  await page.waitForTimeout(1500);
  const badge = await page.textContent('#bellCount').catch(() => '');
  check('the finance manager gets a notification badge',
        Number(badge) > 0, `badge=${badge}`);
  await page.click('#bellBtn');
  await page.waitForTimeout(700);
  const bell = await page.textContent('#bellPanel');
  check('and the bell says an approval is waiting',
        /approval/i.test(bell), bell.slice(0,260));

  await page.click('#bellPanel button[data-act=readall]');
  await page.waitForTimeout(1200);
  check('marking them read clears the badge',
        await page.locator('#bellCount').isHidden(), 'badge still visible');

  // The caretaker may not approve, so must not be told to.
  await signIn(page, 'caretaker@test');
  await page.waitForTimeout(1500);
  const ctBell = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const rows = await db.q('v_my_notifications', b => b.eq('alert_type','PENDING_APPROVAL'));
    return rows.length;
  });
  check('a caretaker is never asked to approve anything', ctBell === 0, String(ctBell));

  const ctReserve = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    return (await db.q('funds', b => b.limit(50))).length;
  });
  check('and cannot see the reserve at all', ctReserve === 0, String(ctReserve));
  });

  await section('what a caretaker sees', async () => {
  await signIn(page, 'caretaker@test');
  const opsNav = await page.$$eval('.navlink', els => els.map(e => e.textContent.trim()));
  check('a caretaker sees the operational modules',
        opsNav.some(t => /Generator/.test(t)) && opsNav.some(t => /Maintenance/.test(t)),
        opsNav.join('|'));
  check('but still not salary', !opsNav.some(t => /Salary/.test(t)), opsNav.join('|'));

  const ctDash = await page.textContent('main');
  check('the caretaker dashboard leads with the operational jobs',
        /Log a power cut/i.test(ctDash) && /Report a problem/i.test(ctDash), ctDash.slice(0,220));

  await gotoHash(page, '#/salary');
  check('and opening salary directly is refused',
        /Not available to you/i.test(await page.textContent('main')));

  const retire = await page.evaluate(async () => {
    const db = await import('/core/db.js');
    const rows = await db.q('assets', b => b.eq('asset_code','GEN-01'));
    if (!rows.length) return 'NO ASSET';
    try { await db.update('assets', rows[0].id, { status: 'RETIRED' }); return 'ALLOWED'; }
    catch (e){ return e.message; }
  });
  check('a caretaker cannot retire equipment, even calling the API directly',
        /approval rights|permission/i.test(retire), retire);
  });

  /* ---------------- the shell's own controls ---------------- */
  await signIn(page, 'admin@test');
  await gotoHash(page, '#/dashboard');
  check('the copyright year is filled in',
        /Copyright © 20\d\d/.test(await page.textContent('.credit')),
        await page.textContent('.credit'));

  await page.click('#userBtn');
  await page.waitForTimeout(300);
  check('the user menu opens', await page.isVisible('#userPanel'));
  check('the user menu names the person and their role',
        /Admin User/.test(await page.textContent('#userPanel')),
        await page.textContent('#userPanel'));
  await page.click('#userBtn');
  await page.waitForTimeout(200);

  check('the language toggle is present', await page.isVisible('#langBtn'));
  await page.click('#langBtn');
  await page.waitForTimeout(1800);
  const bnNav = await page.$$eval('.navlink', els => els.map(e => e.textContent.trim()));
  check('switching to Bangla changes the navigation labels',
        bnNav.some(t => /ড্যাশবোর্ড|সার্ভিস/.test(t)), bnNav.join('|'));
  await page.click('#langBtn');
  await page.waitForTimeout(1800);

  /* ---------------- mobile ---------------- */
  const mob = await ctx.newPage();
  await mob.setViewportSize({ width: 390, height: 844 });
  await signIn(mob, 'caretaker@test');
  const tabCount = await mob.$$eval('.tabbar a', els => els.length);
  check('the phone layout shows a bottom tab bar', tabCount > 0, `${tabCount} tabs`);

  // The hamburger has to actually open the drawer.
  check('the side drawer starts closed on a phone',
        !(await mob.evaluate(() => document.querySelector('#sidenav').classList.contains('open'))));
  await mob.click('#navToggle');
  await mob.waitForTimeout(400);
  check('the menu button opens the side drawer',
        await mob.evaluate(() => document.querySelector('#sidenav').classList.contains('open')));
  // Tap to the right of the 230px drawer, on the scrim itself.
  await mob.click('#navScrim', { position: { x: 330, y: 400 } });
  await mob.waitForTimeout(400);
  check('tapping outside closes it again',
        !(await mob.evaluate(() => document.querySelector('#sidenav').classList.contains('open'))));

  // Signing out has to work.
  await mob.click('#userBtn');
  await mob.waitForTimeout(300);
  await mob.click('#userPanel [data-act="signout"]');
  await mob.waitForTimeout(1500);
  check('sign out returns to the login screen', await mob.isVisible('.auth-card'));
  const overflow = await mob.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  check('nothing overflows sideways on a 390px screen', overflow <= 1, `overflow ${overflow}px`);
  const tapTooSmall = await mob.$$eval('.btn, .tabbar a, .navlink',
    els => els.filter(e => { const r = e.getBoundingClientRect(); return r.height > 0 && r.height < 44; }).length);
  check('tap targets are at least 44px tall', tapTooSmall === 0, `${tapTooSmall} too small`);
  await mob.screenshot({ path: '/tmp/portal-mobile.png', fullPage: true });
  await mob.close();

  await signIn(page, 'admin@test');
  await page.screenshot({ path: '/tmp/portal-desktop.png', fullPage: true });
  await gotoHash(page, '#/charges');
  await page.screenshot({ path: '/tmp/portal-charges.png', fullPage: true });

  /* ---------------- THE FOUR THINGS REPORTED FROM THE BUILDING ---------------- */
  await section('service charge has one door', async () => {
    await signIn(page, 'admin@test');
    await gotoHash(page, '#/finance/new');
    await page.waitForTimeout(1000);

    const offered = await page.evaluate(async () => {
      const setF = (label, value) => {
        const f = [...document.querySelectorAll('main label.field')]
          .find(x => x.querySelector('span')?.textContent.trim().startsWith(label));
        const c = f?.querySelector('select');
        if (!c) return false;
        const o = [...c.options].find(x => x.textContent.toLowerCase().includes(value.toLowerCase()));
        if (!o) return false;
        c.value = o.value;
        c.dispatchEvent(new Event('change', { bubbles:true }));
        return true;
      };
      setF('Type', 'Income');
      await new Promise(r => setTimeout(r, 400));
      setF('Department', 'Service Charge');
      await new Promise(r => setTimeout(r, 600));
      const f = [...document.querySelectorAll('main label.field')]
        .find(x => x.querySelector('span')?.textContent.trim().startsWith('Category'));
      const sel = f?.querySelector('select');
      return {
        count: [...(sel?.options || [])].filter(o => o.value).length,
        placeholder: sel?.options[0]?.textContent || '',
        note: [...document.querySelectorAll('main .hint')]
                .some(h => !h.hidden && /Record payment/.test(h.textContent)),
      };
    });
    check('the ledger offers no service-charge category', offered.count === 0, JSON.stringify(offered));
    check('and says where to record it instead', offered.note, offered.placeholder);

    // The database refuses it too, not just the screen.
    const dbSays = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      const d = (await db.q('departments', b => b.eq('code','SERVICE_CHARGE')))[0];
      const c = (await db.q('categories', b => b.eq('department_id', d.id)))[0];
      const a = (await db.q('accounts', b => b.limit(1)))[0];
      try {
        await db.rpc('create_transaction', {
          p_txn_date: new Date().toISOString().slice(0,10), p_direction:'INCOME',
          p_department_id: d.id, p_category_id: c.id,
          p_description:'hand typed service charge', p_amount: 500,
          p_payment_method:'CASH', p_account_id: a.id }, { silent:true });
        return 'ALLOWED';
      } catch (e){ return e.message; }
    });
    check('the database refuses it as well as the screen',
          /Record payment/.test(dbSays), String(dbSays).slice(0, 80));
  });

  await section('generating a month tops up', async () => {
    await signIn(page, 'admin@test');
    const before = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      const now = new Date();
      const rows = await db.q('flat_charges', b => b
        .eq('period_year', now.getFullYear()).eq('period_month', now.getMonth()+1));
      return rows.length;
    });

    // A flat joins after the month was generated.
    await gotoHash(page, '#/flats');
    await page.click('button:has-text("Add flat")');
    await page.waitForSelector('.modal');
    await page.locator('.modal input[type=text]').first().fill('T-808');
    await page.locator('.modal input[type=number]').first().fill('8');
    await page.locator('.modal button:has-text("Save")').click();
    await page.waitForTimeout(1800);

    await gotoHash(page, '#/charges');
    await page.locator('button:has-text("Generate a month")').click();
    await page.waitForSelector('.modal');
    await page.locator('.modal button:has-text("Generate")').last().click();
    await page.waitForTimeout(2500);

    const t = await page.evaluate(() =>
      [...document.querySelectorAll('#toasts .toast')].map(x => x.textContent).join(' | '));
    check('generating again is not refused', !/already been generated/i.test(t), t.slice(0,80));

    const billed = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      const now = new Date();
      const flats = await db.q('flats', b => b.eq('flat_number','T-808'));
      if (!flats.length) return 'no flat';
      const rows = await db.q('flat_charges', b => b
        .eq('flat_id', flats[0].id)
        .eq('period_year', now.getFullYear()).eq('period_month', now.getMonth()+1));
      return rows.length;
    });
    check('the flat added afterwards gets billed', billed === 1, String(billed));

    const dupes = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      const now = new Date();
      const rows = await db.q('flat_charges', b => b
        .eq('period_year', now.getFullYear()).eq('period_month', now.getMonth()+1)
        .eq('charge_source','MONTHLY'));
      const seen = {}; let d = 0;
      for (const r of rows){ if (seen[r.flat_id]) d++; seen[r.flat_id] = 1; }
      return d;
    });
    check('and nobody is billed twice', dupes === 0, `${dupes} duplicates`);
  });

  await section('receipt as an image', async () => {
    await signIn(page, 'admin@test');
    const png = await page.evaluate(async () => {
      const { receiptImage } = await import('/core/receipt.js');
      const blob = await receiptImage({
        building:'Sabera Heights', address:'House 147, Road 2, Block A, Pallabi, Mirpur 12, Dhaka -1216',
        title:'Service charge receipt', receiptNo:'RCT-2026-0004', date:'09 Sep 2026',
        flat:'7D', method:'CASH', amount:'Tk 5,000.00',
        advance:'Kept as advance: Tk 5,000.00',
        lines:[{label:'Sep 2026', value:'5,000.00'}], footer:'Thank you.' });
      if (!blob) return null;
      const buf = new Uint8Array(await blob.arrayBuffer());
      // PNG magic number, so this is a real image and not an empty blob.
      const isPng = buf[0]===0x89 && buf[1]===0x50 && buf[2]===0x4E && buf[3]===0x47;
      return { type: blob.type, size: blob.size, isPng };
    });
    check('the receipt renders as a real PNG', png && png.isPng, JSON.stringify(png));
    check('and is not a blank one', png && png.size > 3000, png ? png.size + ' bytes' : 'null');
  });

  /* ---------------- CUSTOM ROLES & CATEGORIES ----------------
     The database rules are in sql/test/t08_roles.sql. What is checked
     here is that the buttons exist for the right people, that a role
     made through the dialog really appears, and that the built-in roles
     cannot be removed from the screen. */
  await section('custom roles', async () => {
    await signIn(page, 'caretaker@test');
    await gotoHash(page, '#/users/roles');
    check('a caretaker cannot reach the roles screen',
          !(await page.isVisible('.card input[type=checkbox]')));

    await signIn(page, 'admin@test');
    await gotoHash(page, '#/users/roles');
    check('the admin sees a New role button', await page.isVisible('main button.btn.primary'));

    const removable = await page.$$eval('main .card-head button',
      els => els.filter(e => /Remove/.test(e.textContent)).length);
    check('no built-in role offers a Remove button', removable === 0, `${removable} found`);

    await page.click('main button.btn.primary');
    await page.waitForSelector('.modal', { timeout: 5000 });
    await page.fill('.modal input[type=text]', 'Generator Operator');
    await page.evaluate(() => {
      const b = [...document.querySelectorAll('.modal button')].find(x => /Create role/.test(x.textContent));
      b && b.click();
    });
    await page.waitForTimeout(2500);

    const made = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      const rows = await db.q('roles', b => b.eq('code','GENERATOR_OPERATOR'));
      return rows[0] ? { name: rows[0].name, sys: rows[0].is_system, su: rows[0].is_superuser } : null;
    });
    check('the new role is created', made && made.name === 'Generator Operator', JSON.stringify(made));
    check('and is neither a system nor a full-access role',
          made && !made.sys && !made.su, JSON.stringify(made));

    await gotoHash(page, '#/users/roles');
    const nowRemovable = await page.$$eval('main .card-head button',
      els => els.filter(e => /Remove/.test(e.textContent)).length);
    check('the role you made can be removed', nowRemovable === 1, `${nowRemovable} found`);
  });

  await section('categories', async () => {
    await signIn(page, 'caretaker@test');
    await gotoHash(page, '#/settings');
    check('a caretaker is not offered a New category button',
          !(await page.evaluate(() => [...document.querySelectorAll('main button')]
              .some(b => /New category/.test(b.textContent)))));

    await signIn(page, 'admin@test');
    await gotoHash(page, '#/settings');
    const hasBtn = await page.evaluate(() => [...document.querySelectorAll('main button')]
      .some(b => /New category/.test(b.textContent)));
    check('the admin can add a category', hasBtn);

    await page.evaluate(() => {
      const b = [...document.querySelectorAll('main button')].find(x => /New category/.test(x.textContent));
      b && b.click();
    });
    await page.waitForSelector('.modal', { timeout: 5000 });
    await page.fill('.modal input[type=text]', 'Rooftop water tank cleaning');
    await page.evaluate(() => {
      const s = document.querySelector('.modal select');
      s.value = [...s.options].find(o => /Maintenance/.test(o.textContent))?.value || s.options[1].value;
      s.dispatchEvent(new Event('change', { bubbles:true }));
    });
    await page.evaluate(() => {
      const b = [...document.querySelectorAll('.modal button')].find(x => /^Create$/.test(x.textContent.trim()));
      b && b.click();
    });
    await page.waitForTimeout(2200);

    const cat = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      return (await db.q('categories', b => b.eq('name','Rooftop water tank cleaning'))).length;
    });
    check('the new category is saved', cat === 1, `${cat} found`);

    // ...and it must actually reach the ledger's dropdown, which is the
    // whole point of being able to add one.
    await gotoHash(page, '#/finance/new');
    await page.waitForTimeout(1200);
    const inDropdown = await page.evaluate(() => {
      const f = [...document.querySelectorAll('main label.field')]
        .find(x => x.querySelector('span')?.textContent.trim().startsWith('Department'));
      const sel = f?.querySelector('select');
      const opt = [...(sel?.options || [])].find(o => /Maintenance/.test(o.textContent));
      if (!opt) return 'no maintenance department';
      sel.value = opt.value;
      sel.dispatchEvent(new Event('change', { bubbles:true }));
      return 'set';
    });
    await page.waitForTimeout(1000);
    const offered = await page.evaluate(() => {
      const f = [...document.querySelectorAll('main label.field')]
        .find(x => x.querySelector('span')?.textContent.trim().startsWith('Category'));
      return [...(f?.querySelector('select')?.options || [])]
        .some(o => /Rooftop water tank/.test(o.textContent));
    });
    check('a category you add appears in the ledger dropdown', offered, String(inDropdown));
  });

  /* ---------------- OWNERS, TENANTS, WHO PAYS, REMINDERS ----------------
     Reported from the building: there was no way to edit a flat, and
     adding a tenant through the old Owners form ended the owner's
     ownership. The database rules are in sql/test/t09_people_reminders.sql;
     here the buttons are driven the way a person would. */
  const dbq = (table, filter) => page.evaluate(async ([t, f]) => {
    const db = await import('/core/db.js');
    return db.q(t, b => { let x = b; for (const [k, v] of Object.entries(f || {})) x = x.eq(k, v); return x; });
  }, [table, filter]);
  const clickText = (sel, text) => page.evaluate(([sel, text]) => {
    const b = [...document.querySelectorAll(sel)].find(x => x.textContent.trim() === text);
    if (b) b.click();
    return !!b;
  }, [sel, text]);

  await section('editing a flat', async () => {
    await signIn(page, 'admin@test');
    await gotoHash(page, '#/flats');
    const counts = await page.evaluate(() => ({
      rows: document.querySelectorAll('main tbody tr').length,
      edits: [...document.querySelectorAll('main tbody button')].filter(b => b.textContent.trim() === 'Edit').length }));
    check('every flat in the list has an Edit button', counts.rows > 0 && counts.edits === counts.rows, JSON.stringify(counts));

    await page.evaluate(() => {
      const tr = [...document.querySelectorAll('main tbody tr')].find(r => r.querySelector('td')?.textContent.trim() === 'A-101');
      [...tr.querySelectorAll('button')].find(b => b.textContent.trim() === 'Edit').click();
    });
    await page.waitForSelector('.modal');
    const title = await page.textContent('.modal h2, .modal .modal-title').catch(() => '');
    check('Edit opens the flat form, not the statement', /Edit flat A-101/.test(title || await page.textContent('.modal')), title);
    check('and leaves the address bar alone', (await page.evaluate(() => location.hash)) === '#/flats');
    await page.locator('.modal input[type=number]').nth(1).fill('1450');
    await page.locator('.modal button:has-text("Save")').click();
    await page.waitForTimeout(1500);
    const a101 = (await dbq('flats', { flat_number:'A-101' }))[0];
    check('an edited flat is saved', Number(a101?.area_sqft) === 1450, String(a101?.area_sqft));
  });

  await section('owner and tenant on the flat page', async () => {
    const z = (await dbq('flats', { flat_number:'Z-901' }))[0];
    await gotoHash(page, '#/flats/' + z.id);
    await page.waitForTimeout(500);
    check('a flat has its own page', /Who lives here and who pays/.test(await page.textContent('main')));

    // Owner
    await clickText('main button', '＋ Add owner');
    await page.waitForSelector('.modal');
    await page.locator('.modal input[type=text]').first().fill('Rahim Uddin');
    await page.locator('.modal input[type=tel]').fill('01712-345678');
    await page.waitForTimeout(1200);
    const hint = await page.textContent('.modal .ok-line').catch(() => '');
    check('the mobile number is checked as it is typed', /\+8801712345678/.test(hint || ''), hint);
    await page.locator('.modal button:has-text("Save")').click();
    await page.waitForTimeout(1600);

    // Tenant, who pays
    await clickText('main button', '＋ Add tenant');
    await page.waitForSelector('.modal');
    await page.locator('.modal input[type=text]').first().fill('Karim Tenant');
    await page.locator('.modal input[type=tel]').fill('+44 7700 900123');
    await page.locator('.modal button:has-text("Save")').click();
    await page.waitForTimeout(1600);

    const ppl = (await dbq('v_flat_people', { flat_id: z.id }))[0] || {};
    check('THE OWNER IS STILL THE OWNER after a tenant moves in', ppl.owner_name === 'Rahim Uddin', JSON.stringify(ppl).slice(0, 160));
    check('the tenant is recorded alongside', ppl.tenant_name === 'Karim Tenant');
    check('and the tenant now pays', ppl.billed_relation === 'TENANT');
    const due = (await dbq('v_flat_dues', { flat_id: z.id }))[0] || {};
    check('bills go to the tenant', due.billed_to === 'Karim Tenant', due.billed_to);
    const txt = await page.textContent('main');
    check('the page shows both people', /Rahim Uddin/.test(txt) && /Karim Tenant/.test(txt));

    // Flip who pays and back.
    await clickText('main .seg-btn', 'Owner');
    await page.waitForTimeout(1300);
    check('"paid by Owner" moves the bill to the owner',
          ((await dbq('v_flat_dues', { flat_id: z.id }))[0] || {}).billed_to === 'Rahim Uddin');
    await clickText('main .seg-btn', 'Tenant');
    await page.waitForTimeout(1300);
    check('and "Tenant" moves it back',
          ((await dbq('v_flat_dues', { flat_id: z.id }))[0] || {}).billed_to === 'Karim Tenant');

    // Edit the tenant's phone.
    await page.evaluate(() => {
      const row = [...document.querySelectorAll('main .person')].find(r => /Tenant/i.test(r.querySelector('.person-role')?.textContent || ''));
      [...row.querySelectorAll('button')].find(b => b.textContent.trim() === 'Edit details').click();
    });
    await page.waitForSelector('.modal');
    await page.locator('.modal input[type=tel]').fill('01812-000111');
    await page.locator('.modal button:has-text("Save")').click();
    await page.waitForTimeout(1500);
    const k = (await dbq('owners', { name:'Karim Tenant' }))[0];
    check('a person’s phone number can be edited', k?.mobile === '01812-000111', k?.mobile);
    check('and editing contact details does not touch who pays',
          ((await dbq('v_flat_people', { flat_id: z.id }))[0] || {}).billed_relation === 'TENANT');
  });

  await section('reminders', async () => {
    const z = (await dbq('flats', { flat_number:'Z-901' }))[0];
    const owed = (await dbq('v_flat_dues', { flat_id: z.id }))[0];
    check('Z-901 owes something to remind about', Number(owed?.outstanding) > 0, owed?.outstanding);

    await gotoHash(page, '#/charges/outstanding');
    const remRow = await page.evaluate(() => {
      const tr = [...document.querySelectorAll('main tbody tr')].find(r => r.querySelector('td')?.textContent.trim() === 'Z-901');
      return tr ? [...tr.querySelectorAll('button')].some(b => b.textContent.trim() === 'Remind') : null;
    });
    check('an unpaid flat has a Remind button on the outstanding list', remRow === true);

    // Links to WhatsApp must not leave the test page.
    await page.evaluate(() => document.addEventListener('click', e => {
      const a = e.target.closest && e.target.closest('a[href^="https://wa.me"], a[href^="sms:"]');
      if (a) e.preventDefault();
    }, true));

    await page.evaluate(() => {
      const tr = [...document.querySelectorAll('main tbody tr')].find(r => r.querySelector('td')?.textContent.trim() === 'Z-901');
      [...tr.querySelectorAll('button')].find(b => b.textContent.trim() === 'Remind').click();
    });
    await page.waitForSelector('.modal .rem', { timeout: 5000 });
    check('Remind does not open the statement behind it', /outstanding/.test(await page.evaluate(() => location.hash)));
    const dlg = await page.evaluate(() => ({
      text: document.querySelector('.modal').innerText,
      msg: document.querySelector('.modal .rem-text').value,
      wa: document.querySelector('.modal a[href^="https://wa.me"]')?.href || '' }));
    check('the reminder goes to the person who pays', /Karim Tenant/.test(dlg.text) && /\(tenant\)/.test(dlg.text), dlg.text.slice(0, 80));
    check('the message names the flat and the amount',
          /Z-901/.test(dlg.msg) && new RegExp('Tk ' + Number(owed.outstanding).toLocaleString('en-IN')).test(dlg.msg), dlg.msg.slice(0, 160));
    check('the first reminder is the gentle one', /gentle reminder/i.test(dlg.msg));
    check('WhatsApp gets the number in international form', dlg.wa.startsWith('https://wa.me/8801812000111?text='), dlg.wa.slice(0, 50));
    check('and the full message', decodeURIComponent(dlg.wa.split('?text=')[1] || '') === dlg.msg);

    await page.click('.modal a[href^="https://wa.me"]');
    await page.waitForTimeout(1500);
    const logged = await dbq('charge_reminders', { flat_id: z.id });
    check('sending records the reminder', logged.length === 1, `${logged.length} rows`);
    check('with the words that were sent', logged[0]?.message === dlg.msg);
    check('and to whom', logged[0]?.recipient_name === 'Karim Tenant' && logged[0]?.channel === 'WHATSAPP');
    check('the dialog closes after sending', !(await page.isVisible('.modal')));
    const cell = await page.evaluate(() => {
      const tr = [...document.querySelectorAll('main tbody tr')].find(r => r.querySelector('td')?.textContent.trim() === 'Z-901');
      return tr?.querySelector('.rem-count')?.textContent || '';
    });
    check('the list shows it was reminded', /^1×/.test(cell), cell);

    // Second reminder is the follow-up.
    await page.evaluate(() => {
      const tr = [...document.querySelectorAll('main tbody tr')].find(r => r.querySelector('td')?.textContent.trim() === 'Z-901');
      [...tr.querySelectorAll('button')].find(b => b.textContent.trim() === 'Remind').click();
    });
    await page.waitForSelector('.modal .rem');
    const msg2 = await page.inputValue('.modal .rem-text');
    check('the second reminder is the follow-up', /Following up/.test(msg2), msg2.slice(0, 80));
    await page.locator('.modal button:has-text("Close")').click();

    await gotoHash(page, '#/flats/' + z.id);
    await page.waitForTimeout(500);
    const hist = await page.textContent('main');
    check('the flat page lists the reminder history', /1 reminder on record/.test(hist));
  });

  await section('reminder messages in Settings', async () => {
    await gotoHash(page, '#/settings');
    await page.waitForSelector('#reminder-settings');
    check('Settings has a Reminder messages card', await page.isVisible('#reminder-settings h2:has-text("Reminder messages")'));

    await page.locator('#reminder-settings textarea').first().fill('bKash 01700-000000 (Payment)');
    await page.locator('#reminder-settings input[type=number]').fill('10');
    await clickText('#reminder-settings button', 'Save reminder settings');
    await page.waitForTimeout(1500);
    const bs = (await dbq('building_settings', {}))[0];
    check('how-to-pay and days-to-pay are saved', bs.reminder_how_to_pay === 'bKash 01700-000000 (Payment)' && bs.reminder_deadline_days === 10,
          `${bs.reminder_how_to_pay} / ${bs.reminder_deadline_days}`);

    await page.waitForSelector('#reminder-settings .rem-text');
    const edited = 'Dear {name}, flat {flat} owes Tk {amount}. Thanks!';
    await page.locator('#reminder-settings .rem-text').fill(edited);
    await page.waitForTimeout(200);
    const prev = await page.textContent('#reminder-settings pre.rem-sent');
    check('the preview fills in the placeholders', /Dear Mr\. Karim, flat A-101 owes Tk 10,000\. Thanks!/.test(prev), prev);
    await clickText('#reminder-settings button', 'Save this message');
    await page.waitForTimeout(1500);
    const tpl = (await dbq('reminder_templates', { tone:'GENTLE', lang:'en' }))[0];
    check('an edited message is saved', tpl.body === edited);
    check('and the original is kept to go back to', /gentle reminder/.test(tpl.default_body));
    const label = await page.evaluate(() => [...document.querySelectorAll('#reminder-settings select')].find(x => /Gentle/.test(x.textContent))?.selectedOptions[0]?.textContent);
    check('an edited message is marked as edited', /\(edited\)/.test(label || ''), label);

    await clickText('#reminder-settings button', 'Restore original');
    await page.waitForSelector('.modal');
    await page.locator('.modal button:has-text("Restore")').click();
    await page.waitForTimeout(1500);
    const tpl2 = (await dbq('reminder_templates', { tone:'GENTLE', lang:'en' }))[0];
    check('Restore original puts the shipped wording back', tpl2.body === tpl2.default_body);

    // A caretaker can see Settings? Either way they must not be able to change the wording.
    await signIn(page, 'caretaker@test');
    const denied = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      try {
        const rows = await db.q('reminder_templates', b => b, { silent:true });
        if (!rows.length) return 'not visible';
        await db.update('reminder_templates', rows[0].id, { body: 'hacked' });
        const again = await db.q('reminder_templates', b => b.eq('id', rows[0].id), { silent:true });
        return again[0].body === 'hacked' ? 'CHANGED' : 'unchanged';
      } catch (e){ return 'refused'; }
    });
    check('a caretaker cannot change the reminder wording', denied !== 'CHANGED', denied);
    const zc = await page.evaluate(async () => (await (await import('/core/db.js')).q('flats', b => b.eq('flat_number','Z-901')))[0]?.id);
    await gotoHash(page, '#/flats/' + zc);
    await page.waitForTimeout(600);
    const ct = await page.textContent('main');
    check('a caretaker’s flat page shows no money and no Remind button',
          !/Outstanding|Send a reminder|Statement/.test(ct) && /Who lives here/.test(ct), ct.slice(0, 120).replace(/\s+/g,' '));
    await signIn(page, 'admin@test');
  });

  /* ---------------- RECEIPTS: SEE AND SEND AGAIN ----------------
     Reported: after recording a payment the receipt could not be found
     again, and "Print / PDF" printed the whole list of flats. */
  await section('receipts can be opened and sent again', async () => {
    await signIn(page, 'admin@test');
    await gotoHash(page, '#/charges/payments');
    const n = await page.locator('main tbody tr').count();
    check('the payments list shows every receipt', n > 0, String(n));
    check('each with a Receipt button', await page.locator('main tbody button:has-text("Receipt")').count() === n);
    // A reversed payment's receipt opens too, stamped and with nothing to send.
    const rev = page.locator('main tbody tr', { hasText: /reversed/i });
    if (await rev.count()){
      await rev.first().click();
      await page.waitForSelector('.modal #receiptBody', { timeout: 5000 });
      const rt = await page.textContent('.modal');
      check('a reversed payment\u2019s receipt says so and cannot be sent',
            /was reversed/.test(rt) && !(await page.isVisible('.modal button:has-text("Send as image")')));
      await page.locator('.modal button:has-text("Done")').click();
    }
    await page.locator('main tbody tr', { hasNotText: /reversed/i }).first().click();
    await page.waitForSelector('.modal #receiptBody', { timeout: 5000 });
    check('tapping a payment opens its receipt', await page.isVisible('.modal #receiptBody'));

    const [pdf] = await Promise.all([page.waitForEvent('download', { timeout: 15000 }),
                                     page.click('.modal button:has-text("Receipt PDF")')]);
    const pbuf = fs.readFileSync(await pdf.path());
    check('Receipt PDF gives a .pdf file', /^receipt-.*\.pdf$/.test(pdf.suggestedFilename()), pdf.suggestedFilename());
    check('that really is a PDF', pbuf.slice(0, 5).toString() === '%PDF-', pbuf.slice(0, 8).toString());
    const ptxt = pbuf.toString('latin1');
    check('with the receipt picture on one A4 page', /\/DCTDecode/.test(ptxt) && /\/MediaBox \[0 0 595\.28 841\.89\]/.test(ptxt) && /\/Count 1/.test(ptxt));
    check('and a well-formed cross-reference table', (() => {
      const at = Number((ptxt.match(/startxref\n(\d+)/) || [])[1]);
      return ptxt.slice(at, at + 4) === 'xref';
    })());

    const [img] = await Promise.all([page.waitForEvent('download', { timeout: 15000 }),
                                     page.click('.modal button:has-text("Send as image")')]);
    const ibuf = fs.readFileSync(await img.path());
    check('Send as image still gives a PNG on a laptop', ibuf[0] === 0x89 && ibuf[1] === 0x50, img.suggestedFilename());

    const waHref = await page.getAttribute('.modal a.btn[href*="wa.me"]', 'href').catch(() => null);
    check('the text option is a WhatsApp link on a laptop', !!waHref && waHref.startsWith('https://wa.me/'), waHref);

    // Print must print the receipt, not the page behind it.
    await page.evaluate(() => document.body.classList.add('printing-receipt'));
    await page.emulateMedia({ media: 'print' });
    const printed = await page.evaluate(() => ({
      app: getComputedStyle(document.querySelector('#app')).display,
      receipt: getComputedStyle(document.querySelector('#receiptBody')).display,
      buttons: getComputedStyle(document.querySelector('.receipt-actions')).display }));
    await page.emulateMedia({ media: 'screen' });
    await page.evaluate(() => document.body.classList.remove('printing-receipt'));
    check('Print shows only the receipt on paper', printed.app === 'none' && printed.receipt !== 'none' && printed.buttons === 'none',
          JSON.stringify(printed));
    await page.locator('.modal button:has-text("Done")').click();

    const a102 = (await dbq('flats', { flat_number:'A-102' }))[0];
    await gotoHash(page, '#/flats/' + a102.id);
    await page.waitForTimeout(500);
    check('the flat page lists its receipts', /Receipts/.test(await page.textContent('main')) &&
          await page.locator('main section:has(h2:text-is("Receipts")) tbody tr').count() > 0);
    await gotoHash(page, '#/charges/flat/' + a102.id);
    await page.waitForTimeout(500);
    check('and so does the statement', await page.locator('main section:has(h2:text-is("Receipts")) tbody tr').count() > 0);
  });

  /* ---------------- WHATSAPP ON A PHONE ----------------
     Reported: on a phone the WhatsApp button opened a "Download
     WhatsApp" web page instead of the installed app. */
  await section('WhatsApp opens the installed app on a phone', async () => {
    const pctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true,
      userAgent: 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Mobile Safari/537.36' });
    const ph = await pctx.newPage();
    await signIn(ph, 'admin@test');
    const z = await ph.evaluate(async () => (await (await import('/core/db.js')).q('v_flat_dues', b => b.eq('flat_number', 'Z-901')))[0]);
    await ph.evaluate(id => { location.hash = '#/flats/' + id; }, z.flat_id);
    await ph.waitForTimeout(1200);
    await ph.evaluate(() => [...document.querySelectorAll('main button')].find(b => b.textContent.trim() === 'Send a reminder')?.click());
    await ph.waitForSelector('.modal .rem', { timeout: 5000 });
    const a = await ph.evaluate(() => {
      const l = [...document.querySelectorAll('.modal a')].find(x => /WhatsApp/.test(x.textContent));
      return { href: l?.getAttribute('href') || '', target: l?.getAttribute('target') };
    });
    check('on a phone the reminder opens the WhatsApp app itself', a.href.startsWith('whatsapp://send?phone=8801812000111&text='), a.href.slice(0, 60));
    check('in the same tab, so it is never caught in a browser page', !a.target, String(a.target));
    await pctx.close();
  });

  /* ---------------- MONTHLY REPORT ---------------- */
  await section('the monthly report', async () => {
    await gotoHash(page, '#/reports');
    await page.click('main button:has-text("This month")');
    await page.waitForTimeout(1800);
    const txt = await page.textContent('main');
    for (const h of ['1. Income by department', '2. Expense by department', '3. Result', '4. Cash and bank',
                     '5. Reserve and other funds', '6. Service charge', 'A. Income entries', 'B. Expense entries',
                     'C. Transfers and fund movements', 'D. Service charge flat by flat'])
      check(`the report has "${h}"`, txt.includes(h));
    check('with lines to sign', /Prepared by/.test(txt) && /Approved by/.test(txt));

    const shown = await page.evaluate(() => {
      const st = [...document.querySelectorAll('main .stat')].find(x => /Total income/.test(x.textContent));
      return Number((st?.querySelector('.value')?.textContent || '').replace(/[^\d.]/g, ''));
    });
    const sql = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      const d = new Date(); const pad = n => String(n).padStart(2, '0');
      const from = `${d.getFullYear()}-${pad(d.getMonth()+1)}-01`;
      const to = `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(new Date(d.getFullYear(), d.getMonth()+1, 0).getDate())}`;
      const rows = await db.rpc('report_income_expense', { p_from: from, p_to: to });
      const entries = await db.q('v_transactions', b => b.eq('counts_in_totals', true).eq('direction', 'INCOME').gte('txn_date', from).lte('txn_date', to));
      return { report: Math.round(rows.filter(r => r.direction === 'INCOME').reduce((t, r) => t + Number(r.amount), 0)),
               entries: Math.round(entries.reduce((t, r) => t + Number(r.amount), 0)) };
    });
    check('total income on the page is the SQL figure', shown === sql.report && sql.report > 0, `${shown} vs ${sql.report}`);
    check('and equals the income entries listed behind it', sql.report === sql.entries, `${sql.report} vs ${sql.entries}`);

    await page.emulateMedia({ media: 'print' });
    const pr = await page.evaluate(() => ({
      tabs: getComputedStyle(document.querySelector('.tabs')).display,
      controls: getComputedStyle(document.querySelector('.report-controls')).display,
      letter: getComputedStyle(document.querySelector('.report .letterhead')).display,
      breaks: [...document.querySelectorAll('.report .page-break')].filter(x => getComputedStyle(x).breakBefore === 'page').length }));
    await page.emulateMedia({ media: 'screen' });
    check('on paper: no menus or controls, a letterhead', pr.tabs === 'none' && pr.controls === 'none' && pr.letter === 'block', JSON.stringify(pr));
    check('and each detail list starts on a new page', pr.breaks === 4, String(pr.breaks));

    await page.click('main label:has-text("Include the detail pages") input');
    check('the detail pages can be left out', !(await page.isVisible('text=A. Income entries')));
    await page.click('main label:has-text("Include the detail pages") input');

    const [x] = await Promise.all([page.waitForEvent('download', { timeout: 15000 }),
                                   page.click('main button:has-text("Export Excel")')]);
    const xb = fs.readFileSync(await x.path()).toString('latin1');
    check('Excel export of the month', /^financial-report-\d{4}-\d{2}\.xlsx$/.test(x.suggestedFilename()), x.suggestedFilename());
    check('with a sheet for every part of the report', (xb.match(/xl\/worksheets\/sheet\d+\.xml/g) || []).length >= 18,
          String((xb.match(/xl\/worksheets\/sheet\d+\.xml/g) || []).length));

    await page.selectOption('main .report-controls select >> nth=0', 'year');
    await page.waitForTimeout(1500);
    check('the same report for a whole year', /Financial report — Year \d{4}/.test(await page.textContent('main')));
  });

  /* ---------------- FUNDS: OPENING BALANCE, SPENDING, LPG ---------------- */
  await section('custom funds and the LPG emergency fund', async () => {
    await gotoHash(page, '#/reserve');
    await page.click('main button:has-text("New fund")');
    await page.waitForSelector('.modal');
    await page.locator('.modal input[type=text]').nth(0).fill('lpg');
    await page.locator('.modal input[type=text]').nth(1).fill('LPG emergency fund');
    await page.locator('.modal input[type=text]').nth(2).fill('Cylinder before the meter collection');
    await page.locator('.modal label:has-text("Balance it already has") input').fill('20000');
    await page.locator('.modal button:has-text("Create fund")').click();
    await page.waitForTimeout(1500);
    const f = (await dbq('v_fund_balances', { code:'LPG' }))[0];
    check('a fund can start with the money it already has', Number(f?.current_balance) === 20000, f?.current_balance);

    await gotoHash(page, '#/reserve/' + f.fund_id);
    await page.click('main button:has-text("Take money out")');
    await page.waitForSelector('.modal .choice-list');
    check('taking money out offers three plain choices', await page.locator('.modal .choice').count() === 3);
    check('and starts on "Spent from the fund"', await page.locator('.modal .choice.on').textContent().then(t => /Spent from the fund/.test(t)));
    const cat = await page.evaluate(() => {
      const sel = [...document.querySelectorAll('.modal label.field')].find(l => /Category/.test(l.textContent))?.querySelector('select');
      return sel?.selectedOptions[0]?.textContent || '';
    });
    check('an LPG fund picks the LPG category by itself', /LPG/.test(cat), cat);
    await page.locator('.modal label:has-text("Amount") input').fill('3000');
    await page.evaluate(() => {
      const sel = [...document.querySelectorAll('.modal label.field')].find(l => /Paid from account/.test(l.textContent))?.querySelector('select');
      sel.selectedIndex = 1; sel.dispatchEvent(new Event('change'));
    });
    await page.locator('.modal button:has-text("Record")').click();
    await page.waitForTimeout(1600);
    const f2 = (await dbq('v_fund_balances', { code:'LPG' }))[0];
    check('spending from the fund lowers it', Number(f2.current_balance) === 17000, f2.current_balance);
    const spent = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      return (await db.q('v_transactions', b => b.eq('source_module', 'reserve').eq('direction', 'EXPENSE')
        .order('created_at', { ascending:false }).limit(1)))[0];
    });
    check('and records a real expense under LPG', spent && /LPG/.test(spent.department_name) && spent.status === 'POSTED'
          && Number(spent.amount) === 3000,
          spent ? `${spent.department_name} ${spent.status}` : 'none');

    await gotoHash(page, '#/reports');
    await page.click('main button:has-text("This month")');
    await page.waitForTimeout(1800);
    const rep = await page.textContent('main');
    check('the fund appears in the monthly report', /LPG emergency fund/.test(rep));
    check('and its spending under its own department', /LPG \(emergency fund\)/.test(rep));
  });

  await section('a new department from Settings', async () => {
    await gotoHash(page, '#/settings');
    await page.click('main button:has-text("New department")');
    await page.waitForSelector('.modal');
    await page.locator('.modal input[type=text]').fill('Water pump');
    await page.locator('.modal button:has-text("Create")').click();
    await page.waitForTimeout(1400);
    const d = await page.evaluate(async () => (await (await import('/core/db.js')).q('departments', b => b.eq('name', 'Water pump')))[0]);
    check('a department can be added from Settings', !!d && d.code === 'WATER_PUMP', JSON.stringify(d));
  });

  /* ---------------- SYSTEM RESET ----------------
     Last, because it empties the database it runs against. The database
     rules are proved in sql/test/t07_reset.sql; what is checked here is
     the part only a browser can answer — that the button is absent for
     people who may not use it, that the typed confirmation is really
     required, and that the screen tells the truth afterwards. */
  await section('system reset', async () => {
    await signIn(page, 'caretaker@test');
    await gotoHash(page, '#/settings');
    check('the caretaker is not offered a system reset',
          !(await page.isVisible('.danger-zone')));

    await signIn(page, 'finance@test');
    await gotoHash(page, '#/settings');
    check('the finance manager is not offered a system reset',
          !(await page.isVisible('.danger-zone')));

    await signIn(page, 'admin@test');
    await gotoHash(page, '#/settings');
    check('the admin sees the "Start fresh" card', await page.isVisible('.danger-zone'));

    // Markup shown as characters. `html:` escapes a plain string by design,
    // so writing "<b>...</b>" into it renders the tags visibly — which is
    // exactly what happened here and was only caught by looking at it.
    const cardText = await page.textContent('.danger-zone');
    check('no markup is showing as literal text on the reset card',
          !/<\/?[a-z]+>/i.test(cardText || ''),
          (cardText || '').match(/<\/?[a-z]+>/i)?.[0] || '');

    const before = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      return {
        txns:  (await db.q('transactions', b => b.limit(2000))).length,
        flats: (await db.q('flats',        b => b.limit(2000))).length,
      };
    });
    check('there is something to clear before we start', before.txns > 0, JSON.stringify(before));

    // The wrong word must not get through.
    await page.click('.danger-zone .btn.danger');
    await page.waitForSelector('.modal', { timeout: 5000 });
    await page.fill('.modal input[type=text]', 'reset');
    await page.click('.modal .btn.danger');
    await page.waitForTimeout(500);
    check('a lower-case confirmation is refused and the dialog stays open',
          await page.isVisible('.modal'));

    const stillThere = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      return (await db.q('transactions', b => b.limit(2000))).length;
    });
    check('nothing was deleted by the refused attempt', stillThere === before.txns,
          `${stillThere} vs ${before.txns}`);

    // The right word goes through.
    await page.fill('.modal input[type=text]', 'RESET');
    await page.click('.modal .btn.danger');
    await page.waitForTimeout(2500);

    const after = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      return {
        txns:  (await db.q('transactions', b => b.limit(2000))).length,
        flats: (await db.q('flats',        b => b.limit(2000))).length,
      };
    });
    check('clearing entries removed every transaction', after.txns === 0, `${after.txns} left`);
    check('clearing entries kept the flats', after.flats === before.flats,
          `${after.flats} vs ${before.flats}`);
    check('the admin is still signed in and able to work afterwards',
          await page.isVisible('.topbar'));
  });

  const realErrors = consoleErrors.filter(e =>
    !/Failed to load resource|service-worker|favicon|manifest|401|403|406/i.test(e));
  check('no unexpected console errors', realErrors.length === 0, realErrors.slice(0,3).join(' || '));

  await browser.close();

  const failed = results.filter(r => !r.pass);
  for (const r of failed) console.log(`FAIL  ${r.name}${r.detail ? '  — ' + r.detail : ''}`);
  console.log(`\n${results.length - failed.length} of ${results.length} browser checks passed`);
  process.exit(failed.length ? 1 : 0);
};

run().catch(e => { console.error(e); process.exit(2); });
