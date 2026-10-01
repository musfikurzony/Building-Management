/* =====================================================================
   mobile-audit.mjs — measures the portal at phone width.

   The existing browser suite runs at 1280x900. 136 checks, not one of
   them narrower than a laptop, which is exactly why a phone-layout
   problem could survive all of them. This script does one thing: load
   every screen at phone width and report anything wider than the screen,
   naming the element responsible.

   Run: node scripts/mobile-audit.mjs   (dev server must already be up)
   ===================================================================== */

import { chromium } from 'playwright';

const BASE = process.env.BASE || 'http://localhost:5173';
const SHOT = process.env.SHOT || '';

const DEVICES = [
  { name: 'Android 360', width: 360, height: 800, dpr: 3 },
  { name: 'iPhone 390',  width: 390, height: 844, dpr: 3 },
];

const ROUTES = [
  '#/dashboard', '#/flats', '#/charges', '#/finance', '#/bank',
  '#/budget', '#/reserve', '#/staff', '#/salary', '#/generator',
  '#/lift', '#/mosque', '#/maintenance', '#/fire', '#/work',
  '#/assets', '#/reconcile', '#/reports', '#/users', '#/audit',
  '#/settings', '#/flats/owners', '#/charges/outstanding', '@flat',
];

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

/**
 * Horizontal overflow, and who caused it.
 *
 * scrollWidth > clientWidth on the document is the condition that forces
 * a phone to zoom out. Knowing THAT it happens is not enough to fix it,
 * so we also walk every element and report the ones sticking out past
 * the viewport, which is the actual culprit list.
 */
async function overflow(page, width){
  return page.evaluate((vw) => {
    const doc = document.documentElement;
    const over = doc.scrollWidth - doc.clientWidth;
    const culprits = [];
    if (over > 0){
      for (const el of document.querySelectorAll('body *')){
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue;
        const cs = getComputedStyle(el);
        if (cs.position === 'fixed') continue;
        if (r.right > vw + 1){
          // Only report the element itself, not every ancestor of it.
          const parent = el.parentElement;
          const pr = parent ? parent.getBoundingClientRect() : null;
          if (pr && pr.right > vw + 1) continue;
          culprits.push({
            tag: el.tagName.toLowerCase(),
            cls: (el.className && String(el.className).slice(0, 60)) || '',
            right: Math.round(r.right),
            width: Math.round(r.width),
            text: (el.textContent || '').trim().slice(0, 40),
          });
        }
      }
    }
    return { over, scrollWidth: doc.scrollWidth, clientWidth: doc.clientWidth, culprits: culprits.slice(0, 6) };
  }, width);
}

/** Tap targets below 44px are hard to hit accurately on a phone. */
async function smallTargets(page){
  return page.evaluate(() => {
    const bad = [];
    for (const el of document.querySelectorAll('button, a, input, select, textarea')){
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (el.closest('.tabbar')) continue;          // its own sizing, already 56px
      if (r.height < 44 - 0.5){
        bad.push({ tag: el.tagName.toLowerCase(),
                   cls: String(el.className || '').slice(0, 40),
                   h: Math.round(r.height),
                   text: (el.textContent || el.value || '').trim().slice(0, 24) });
      }
    }
    return bad.slice(0, 8);
  });
}

/** Is the phone chrome actually on screen? */
async function chrome(page){
  return page.evaluate(() => ({
    narrowClass: document.documentElement.classList.contains('is-narrow'),
    phoneClass:  document.documentElement.classList.contains('is-phone'),
    tabbar:  document.querySelector('.tabbar') &&
             getComputedStyle(document.querySelector('.tabbar')).display !== 'none',
    burger:  document.querySelector('#navToggle') &&
             getComputedStyle(document.querySelector('#navToggle')).display !== 'none',
    drawer:  document.querySelector('.sidenav') &&
             getComputedStyle(document.querySelector('.sidenav')).position === 'fixed',
  }));
}

const run = async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM || undefined,
    args: ['--no-sandbox','--disable-dev-shm-usage']
  });

  let problems = 0;

  for (const dev of DEVICES){
    const ctx = await browser.newContext({
      viewport: { width: dev.width, height: dev.height },
      deviceScaleFactor: 1,
      isMobile: true,
      hasTouch: true,
      userAgent: 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
    });
    const page = await ctx.newPage();
    await signIn(page, 'admin@test');

    console.log(`\n=== ${dev.name} (${dev.width}x${dev.height}) ===`);

    const flatId = await page.evaluate(async () => {
      const db = await import('/core/db.js');
      return (await db.q('flats', b => b.eq('flat_number', 'A-101')))[0]?.id;
    });
    for (const r of ROUTES){
      const route = r === '@flat' ? `#/flats/${flatId}` : r;
      await page.evaluate(h => { location.hash = h; }, route);
      await page.waitForTimeout(850);

      const o = await overflow(page, dev.width);
      if (o.over > 0){
        problems++;
        console.log(`OVERFLOW ${route.padEnd(16)} +${o.over}px  (${o.scrollWidth} > ${o.clientWidth})`);
        for (const c of o.culprits){
          console.log(`         <${c.tag} class="${c.cls}"> w=${c.width} right=${c.right}  "${c.text}"`);
        }
      } else {
        console.log(`ok       ${route}`);
      }

      if (SHOT && route === SHOT){
        await page.screenshot({ path: `/tmp/shot-${dev.width}${route.replace(/[#/]/g,'-')}.png`, fullPage: true });
      }
    }

    // The Remind dialog, opened the way a person would, at phone width.
    await page.evaluate(() => { location.hash = '#/charges/outstanding'; });
    await page.waitForTimeout(900);
    await page.evaluate(() => [...document.querySelectorAll('main button')].find(b => b.textContent.trim() === 'Remind')?.click());
    await page.waitForTimeout(1200);
    if (await page.isVisible('.modal .rem')){
      const o = await overflow(page, dev.width);
      const small = (await smallTargets(page)).filter(x => !/^$/.test(x.text) || x.tag !== 'a');
      const inModal = await page.evaluate(() => {
        const bad = [];
        for (const el of document.querySelectorAll('.modal button, .modal a, .modal select, .modal textarea')){
          const r = el.getBoundingClientRect();
          if (r.width && r.height && r.height < 43.5) bad.push(`${el.tagName.toLowerCase()} h=${Math.round(r.height)} "${(el.textContent||'').trim().slice(0,20)}"`);
          if (r.right > innerWidth + 1) bad.push(`${el.tagName.toLowerCase()} sticks out to ${Math.round(r.right)}`);
        }
        return bad;
      });
      if (o.over > 0 || inModal.length){
        problems++;
        console.log(`PROBLEM  Remind dialog: overflow +${o.over}px; ${inModal.join('; ')}`);
      } else console.log(`ok       Remind dialog fits, every control >= 44px`);
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
    } else {
      problems++;
      console.log(`PROBLEM  Remind dialog did not open`);
    }

    // The flat page's own buttons, where the owner and tenant are managed.
    await page.evaluate(h => { location.hash = h; }, `#/flats/${flatId}`);
    await page.waitForTimeout(1000);
    const flatSmall = await page.evaluate(() => {
      const bad = [];
      for (const el of document.querySelectorAll('main .person button, main .seg button, main .toolbar .btn')){
        const r = el.getBoundingClientRect();
        if (r.width && r.height && r.height < 43.5) bad.push(`${Math.round(r.height)}px "${el.textContent.trim()}"`);
      }
      return bad;
    });
    if (flatSmall.length){ problems++; console.log(`SMALL    flat page: ${flatSmall.join(', ')}`); }
    else console.log(`ok       flat page buttons >= 44px`);

    await page.evaluate(() => { location.hash = '#/finance'; });
    await page.waitForTimeout(800);

    const c = await chrome(page);
    if (!(c.narrowClass && c.tabbar && c.burger && c.drawer)){
      problems++;
      console.log(`  PHONE CHROME MISSING: ${JSON.stringify(c)}`);
    } else {
      console.log(`  phone chrome present (tab bar, burger, drawer)`);
    }

    const small = await smallTargets(page);
    if (small.length){
      problems++;
      console.log(`  SMALL TAP TARGETS on #/finance (<44px tall):`);
      for (const s of small) console.log(`    <${s.tag} class="${s.cls}"> h=${s.h} "${s.text}"`);
    } else {
      console.log(`  all tap targets >= 44px`);
    }

    await ctx.close();
  }

  /* -------------------------------------------------------------------
     The case the width media queries could never handle: a phone whose
     browser reports a desktop-sized viewport. Simulated here by using a
     980px viewport — what Chrome's "Desktop site" actually lays out at —
     and checking that the manual override still produces the phone
     layout. This is the guarantee the toggle exists to give.
     ------------------------------------------------------------------- */
  {
    const ctx = await browser.newContext({ viewport: { width: 980, height: 800 } });
    const page = await ctx.newPage();
    await signIn(page, 'admin@test');

    const before = await chrome(page);
    console.log(`\n=== forced-desktop viewport (980px), as Chrome "Desktop site" ===`);
    if (before.narrowClass){
      problems++;
      console.log(`  UNEXPECTED: 980px got the phone layout without being asked`);
    } else {
      console.log(`  980px defaults to the desktop layout, as it should`);
    }

    await page.evaluate(() => localStorage.setItem('bms.layout','mobile'));
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(1200);
    const after = await chrome(page);
    if (after.narrowClass && after.tabbar && after.burger && after.drawer){
      console.log(`  "Mobile view" forces the phone layout at 980px  <- the fix`);
    } else {
      problems++;
      console.log(`  FAILED: forcing mobile did not produce the phone layout: ${JSON.stringify(after)}`);
    }
    await ctx.close();
  }

  await browser.close();
  console.log(`\n${problems === 0 ? 'Phone layout audit passed.' : problems + ' problem(s) found.'}`);
  process.exit(problems === 0 ? 0 : 1);
};

run().catch(e => { console.error(e); process.exit(2); });
