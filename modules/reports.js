/* Reports — monthly, yearly and any custom date range, with CSV export.
   Every figure comes from the same SQL views the dashboard uses, so a
   report and the dashboard can never disagree. */

import { el, field, select, money, money0, num, fdate, table, stat, emptyState,
         downloadCSV, todayISO, monthName, letterhead } from '../core/ui.js';
import { q, rpc, logEvent, isMissingObject } from '../core/db.js';
import { downloadXLSX } from '../core/xlsx.js';
import { can, ref, settings, state } from '../core/store.js';

/* The two buttons every report carries. Kept here so the date-range
   statement and the annual summary cannot drift apart. */
function exportBar({ filename, sheets, module = 'reports', detail }){
  const bar = el('span', {});
  if (!can('reports','export')) return bar;
  bar.append(el('button', { class:'btn small', onclick: () => {
    downloadXLSX(filename, sheets());
    logEvent('EXPORT', { module, detail: (detail || filename) + ' (xlsx)' });
  }}, 'Export Excel'));
  bar.append(el('button', { class:'btn small', onclick: () => {
    logEvent('REPORT_VIEW', { module, detail: (detail || filename) + ' (printed)' });
    window.print();
  }}, 'Print / PDF'));
  return bar;
}

/** Building name and address for the printed letterhead. */
const head = (title, period) => {
  const s = settings();
  return letterhead({ name: s.building_name, address: s.address, title, period });
};

const now = new Date();

export async function render({ params }){
  if (params && params[0] === 'annual')  return annual();
  if (params && params[0] === 'entries') return statement();
  if (params && params[0] === 'backup'){
    const { backupPage } = await import('./backup.js');
    return backupPage(tabs);
  }
  return monthly();
}

/** The three report screens, one tap apart. */
function tabs(active){
  const t = (href, key, label) => el('a', { class:'tab' + (active === key ? ' on' : ''), href,
    'aria-current': active === key ? 'page' : null, text: label });
  return el('nav', { class:'tabs', 'aria-label':'Reports' },
    t('#/reports', 'monthly', 'Monthly report'),
    t('#/reports/entries', 'entries', 'Search entries'),
    t('#/reports/annual', 'annual', 'Annual summary'),
    t('#/reports/backup', 'backup', 'Backup'));
}

async function statement(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Reports' }),
    el('p', { class:'sub', text:'Search and filter every posted entry. Transfers between our own accounts are excluded from income and expense.' })));
  page.append(tabs('entries'));

  const fromI = el('input', { type:'date', value:`${now.getFullYear()}-01-01` });
  const toI   = el('input', { type:'date', value: todayISO() });
  const quick = select([
    { value:'ytd',   label:'This year to date' },
    { value:'month', label:'This month' },
    { value:'last',  label:'Last month' },
    { value:'year',  label:'Last full year' },
    { value:'custom',label:'Custom range' }
  ], { value:'ytd' });

  quick.onchange = () => {
    const y = now.getFullYear(), m = now.getMonth();
    const iso = (d) => d.toISOString().slice(0,10);
    if (quick.value === 'ytd')   { fromI.value = `${y}-01-01`; toI.value = todayISO(); }
    if (quick.value === 'month') { fromI.value = iso(new Date(y, m, 1)); toI.value = todayISO(); }
    if (quick.value === 'last')  { fromI.value = iso(new Date(y, m-1, 1)); toI.value = iso(new Date(y, m, 0)); }
    if (quick.value === 'year')  { fromI.value = `${y-1}-01-01`; toI.value = `${y-1}-12-31`; }
    load();
  };

  page.append(el('div', { class:'toolbar' },
    el('div', { style:'flex:1;min-width:11rem' }, field('Period', quick)),
    el('div', { style:'flex:1;min-width:9rem' }, field('From', fromI)),
    el('div', { style:'flex:1;min-width:9rem' }, field('To', toI))));

  const body = el('div', {});
  page.append(body);
  fromI.onchange = toI.onchange = load;

  async function load(){
    body.replaceChildren(el('p', { class:'muted', text:'Building the report…' }));
    const txns = await q('v_transactions', b => b
      .eq('status','POSTED').gte('txn_date', fromI.value).lte('txn_date', toI.value)
      .order('txn_date')).catch(() => []);

    // The rule for what counts lives in SQL (v_transactions.counts_in_totals),
    // so a report and the dashboard can never disagree about it.
    const real = txns.filter(t => t.counts_in_totals);
    const income  = real.filter(t => t.direction === 'INCOME');
    const expense = real.filter(t => t.direction === 'EXPENSE');
    const sum = (rows) => rows.reduce((t,r) => t + Number(r.amount), 0);
    const net = sum(income) - sum(expense);

    const byDept = (rows) => {
      const map = new Map();
      for (const r of rows){
        const k = r.department_name || 'Unclassified';
        map.set(k, (map.get(k) || 0) + Number(r.amount));
      }
      return [...map.entries()].map(([name, amount]) => ({ name, amount }))
        .sort((a,b) => b.amount - a.amount);
    };
    const incomeRows  = byDept(income);
    const expenseRows = byDept(expense);
    const maxExp = Math.max(1, ...expenseRows.map(r => r.amount));

    const deptCols = [
      { label:'Department', primary:true, key:'name' },
      { label:'Amount', cls:'num', fmt: r => money(r.amount, { bare:true }), csv: r => r.amount },
      { label:'Share', cls:'num', fmt: r => Math.round(r.amount / (sum(expense) || 1) * 100) + '%',
        csv: r => Math.round(r.amount / (sum(expense) || 1) * 100) }
    ];

    const catCols = [
      { label:'Date', fmt: r => fdate(r.txn_date), csv: r => r.txn_date },
      { label:'Number', cls:'mono', key:'txn_no' },
      { label:'Description', primary:true, key:'description' },
      { label:'Department', fmt: r => r.department_name || '', csv: r => r.department_name },
      { label:'Category', fmt: r => r.category_name || '', csv: r => r.category_name },
      { label:'Vendor', fmt: r => r.vendor_name || '', csv: r => r.vendor_name },
      { label:'Direction', key:'direction' },
      { label:'Amount', cls:'num', fmt: r => money(r.amount, { bare:true }), csv: r => r.amount }
    ];

    const period = `${fdate(fromI.value)} to ${fdate(toI.value)}`;
    const out = el('div', {});
    out.append(head('Income & expenditure statement', period));
    out.append(el('div', { class:'toolbar' }, exportBar({
      filename: `statement-${fromI.value}-to-${toI.value}.xlsx`,
      detail: `statement ${fromI.value}..${toI.value}`,
      sheets: () => [
        { name:'Summary', title: settings().building_name || 'Building',
          subtitle: `Income & expenditure — ${period}`,
          columns:[{ label:'Figure', key:'k', width:32 }, { label:'Amount', key:'v', money:true }],
          rows:[
            { k:'Total income',  v: sum(income) },
            { k:'Total expense', v: sum(expense) },
            { k: net >= 0 ? 'Net surplus' : 'Net deficit', v: Math.abs(net) },
            { k:'Entries counted', v: real.length }
          ] },
        { name:'Income by department',
          columns:[{ label:'Department', key:'name', width:30 }, { label:'Amount', key:'amount', money:true }],
          rows: incomeRows, total:{ amount: sum(income) } },
        { name:'Expense by department',
          columns:[{ label:'Department', key:'name', width:30 }, { label:'Amount', key:'amount', money:true }],
          rows: expenseRows, total:{ amount: sum(expense) } },
        { name:'All entries',
          columns:[
            { label:'Date', key:'txn_date', width:13 },
            { label:'Number', key:'txn_no', width:16 },
            { label:'Description', key:'description', width:40 },
            { label:'Department', key:'department_name', width:20 },
            { label:'Category', key:'category_name', width:24 },
            { label:'Vendor', key:'vendor_name', width:22 },
            { label:'Direction', key:'direction', width:12 },
            { label:'Amount', key:'amount', money:true }
          ],
          rows: filtered() }
      ]})));
    out.append(el('div', { class:'grid g-stats' },
      stat('Total income',  money0(sum(income))),
      stat('Total expense', money0(sum(expense))),
      stat(net >= 0 ? 'Net surplus' : 'Net deficit', money0(Math.abs(net)), null, net >= 0 ? 'good' : 'bad'),
      stat('Entries', num(real.length),
           `${txns.length - real.length} transfer(s)/reversed pair(s) excluded`)));

    out.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Income by department' })),
      table(deptCols.slice(0,2), incomeRows, { empty:'No income in this period.',
        foot: [{ label:'Total', value:'Total' }, { cls:'num', value: money(sum(income), { bare:true }) }] })));

    const expCard = el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Expense by department' })));
    for (const r of expenseRows){
      expCard.append(el('div', { style:'margin-bottom:.5rem' },
        el('div', { style:'display:flex;gap:.6rem' },
          el('span', { style:'flex:1', text: r.name }),
          el('span', { class:'num', text: money(r.amount) })),
        el('div', { class:'bar' }, el('span', { style:`width:${Math.round(r.amount / maxExp * 100)}%` }))));
    }
    if (!expenseRows.length) expCard.append(emptyState('No expense in this period.'));
    else expCard.append(el('p', { style:'margin-top:.6rem' }, 'Total: ', el('b', { class:'num', text: money(sum(expense)) })));
    out.append(expCard);

    /* ---- the detail list, with filters ----
       The filters run over the rows already fetched, so narrowing the
       list is instant and cannot disagree with the totals above it. */
    const uniq = (fn) => [...new Set(real.map(fn).filter(Boolean))].sort();
    const fDept   = select(uniq(r => r.department_name).map(v => ({ value:v, label:v })), { placeholder:'All departments' });
    const fCat    = select(uniq(r => r.category_name).map(v => ({ value:v, label:v })),   { placeholder:'All categories' });
    const fVendor = select(uniq(r => r.vendor_name).map(v => ({ value:v, label:v })),     { placeholder:'All vendors' });
    const fMethod = select(uniq(r => r.payment_method).map(v => ({ value:v, label:v.replace(/_/g,' ') })), { placeholder:'Any payment method' });
    const fText   = el('input', { type:'search', placeholder:'Search description or number' });

    const detailHost = el('div', {});
    const summaryLine = el('p', { class:'hint' }, '');
    const filtered = () => real.filter(r =>
      (!fDept.value   || r.department_name === fDept.value) &&
      (!fCat.value    || r.category_name   === fCat.value) &&
      (!fVendor.value || r.vendor_name     === fVendor.value) &&
      (!fMethod.value || r.payment_method  === fMethod.value) &&
      (!fText.value.trim() ||
        `${r.description || ''} ${r.txn_no || ''}`.toLowerCase().includes(fText.value.trim().toLowerCase())));

    const paintDetail = () => {
      const rows = filtered();
      const inc = rows.filter(r => r.direction === 'INCOME');
      const exp = rows.filter(r => r.direction === 'EXPENSE');
      summaryLine.textContent = rows.length === real.length
        ? `All ${real.length} entries.`
        : `${rows.length} of ${real.length} entries — ${money(sum(inc))} in, ${money(sum(exp))} out.`;
      detailHost.replaceChildren(table(catCols, rows, { empty:'Nothing matches those filters.' }));
    };
    for (const c of [fDept, fCat, fVendor, fMethod]) c.onchange = paintDetail;
    fText.oninput = paintDetail;

    const detailCard = el('section', { class:'card page-break' },
      el('div', { class:'card-head' }, el('h2', { text:'All entries' }),
        can('reports','export') ? el('button', { class:'btn small', text:'Export CSV', onclick: () => {
          const rows = filtered();
          downloadCSV(`report-${fromI.value}-to-${toI.value}.csv`, catCols, rows);
          logEvent('EXPORT', { module:'reports', detail:`${rows.length} rows ${fromI.value}..${toI.value}` });
        }}) : null),
      el('div', { class:'toolbar' },
        el('div', { style:'flex:1;min-width:9rem' }, field('Department', fDept)),
        el('div', { style:'flex:1;min-width:9rem' }, field('Category', fCat)),
        el('div', { style:'flex:1;min-width:9rem' }, field('Vendor', fVendor)),
        el('div', { style:'flex:1;min-width:9rem' }, field('Payment method', fMethod)),
        el('div', { style:'flex:2;min-width:11rem' }, field('Search', fText))),
      summaryLine, detailHost);
    paintDetail();
    out.append(detailCard);

    body.replaceChildren(out);
  }

  await load();
  return page;
}

/* ---------------------------------------------------------------------
   ANNUAL SUMMARY

   Twelve months across, and — the part that makes it worth printing — a
   running closing balance down the right. A year of monthly figures does
   not tell you whether the building is getting richer or poorer; the
   cumulative column does.
   --------------------------------------------------------------------- */
async function annual(){
  const page = el('div', {});
  const yearI = select(
    Array.from({ length: 6 }, (_, i) => now.getFullYear() + 1 - i)
      .map(y => ({ value:y, label:String(y) })), { value: now.getFullYear() });

  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Annual summary' }),
    el('p', { class:'sub', text:'Month by month, with the running balance the monthly figures alone will not show you.' })));
  page.append(tabs('annual'));
  page.append(el('div', { class:'toolbar' },
    el('div', { style:'flex:0 0 8rem' }, field('Year', yearI))));

  const body = el('div', {});
  page.append(body);
  yearI.onchange = load;

  async function load(){
    body.replaceChildren(el('p', { class:'muted', text:'Building the report…' }));
    const year = Number(yearI.value);

    const [ie, spend, position, funds] = await Promise.all([
      q('v_income_expense_monthly', b => b.eq('period_year', year).order('period_month')).catch(() => []),
      q('v_department_spend', b => b.eq('period_year', year)).catch(() => []),
      q('v_financial_position').catch(() => []),
      can('reserve','view') ? q('v_fund_balances').catch(() => []) : []
    ]);

    // Every month of the year, whether or not anything happened in it — a
    // gap in the table reads as missing data rather than a quiet month.
    let running = 0;
    const months = [];
    for (let m = 1; m <= 12; m++){
      const r = ie.find(x => x.period_month === m) || { income:0, expense:0 };
      const income = Number(r.income || 0), expense = Number(r.expense || 0);
      running += income - expense;
      months.push({ month:m, label: monthName(year, m), income, expense,
                    net: income - expense, cumulative: running });
    }
    const totalIn  = months.reduce((t,m) => t + m.income, 0);
    const totalOut = months.reduce((t,m) => t + m.expense, 0);

    const cols = [
      { label:'Month', primary:true, key:'label' },
      { label:'Income', cls:'num', fmt: m => money(m.income, { bare:true }), csv: m => m.income },
      { label:'Expense', cls:'num', fmt: m => money(m.expense, { bare:true }), csv: m => m.expense },
      { label:'Surplus / deficit', cls:'num',
        fmt: m => el('span', { class: m.net < 0 ? 'num b-overdue' : 'num' }, money(m.net, { bare:true })),
        csv: m => m.net },
      { label:'Running total', cls:'num', fmt: m => money(m.cumulative, { bare:true }), csv: m => m.cumulative }
    ];

    const out = el('div', {});
    out.append(head('Annual financial summary', `Year ${year}`));
    out.append(el('div', { class:'toolbar' }, exportBar({
      filename: `annual-${year}.xlsx`,
      detail: `annual ${year}`,
      sheets: () => {
        const pos = position[0];
        return [
          { name:'Month by month', title: settings().building_name || 'Building',
            subtitle: `Annual financial summary — ${year}`,
            columns:[
              { label:'Month', key:'label', width:16 },
              { label:'Income', key:'income', money:true },
              { label:'Expense', key:'expense', money:true },
              { label:'Surplus / deficit', key:'net', money:true },
              { label:'Running total', key:'cumulative', money:true }
            ],
            rows: months,
            total:{ income: totalIn, expense: totalOut, net: totalIn - totalOut } },
          { name:'By department',
            columns:[{ label:'Department', key:'name', width:30 }, { label:'Spent', key:'amount', money:true }],
            rows: deptRows, total:{ amount: totalOut } },
          pos ? { name:'Position',
            columns:[{ label:'Figure', key:'k', width:34 }, { label:'Amount', key:'v', money:true }],
            rows:[
              { k:'Cash in hand', v:Number(pos.cash_in_hand) },
              { k:'In the bank', v:Number(pos.bank_balance) },
              { k:'Fixed deposits', v:Number(pos.fixed_deposits) },
              { k:'Total held', v:Number(pos.total_held) },
              { k:'Service charge owed to us', v:Number(pos.service_charge_receivable) },
              { k:'Paid in advance by flats', v:Number(pos.advances_held) },
              { k:'Salaries generated, unpaid', v:Number(pos.salary_due) }
            ] } : null
        ].filter(Boolean);
      }})));
    out.append(el('div', { class:'grid g-stats' },
      stat('Income for the year', money0(totalIn)),
      stat('Expense for the year', money0(totalOut)),
      stat(totalIn >= totalOut ? 'Surplus' : 'Deficit', money0(Math.abs(totalIn - totalOut)),
           null, totalIn >= totalOut ? 'good' : 'bad'),
      stat('Best month', months.reduce((a,b) => b.net > a.net ? b : a, months[0]).label,
           money0(Math.max(...months.map(m => m.net))))));

    out.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:`${year} month by month` }),
        can('reports','export') ? el('button', { class:'btn small', text:'Export CSV', onclick: () => {
          downloadCSV(`annual-${year}.csv`, cols, months);
          logEvent('EXPORT', { module:'reports', detail:`annual ${year}` });
        }}) : null),
      table(cols, months, {
        foot: [{ value:'Total' },
               { cls:'num', value: money(totalIn, { bare:true }) },
               { cls:'num', value: money(totalOut, { bare:true }) },
               { cls:'num', value: money(totalIn - totalOut, { bare:true }) },
               { cls:'num', value: '' }] })));

    /* Department spend for the year, largest first. */
    const byDept = new Map();
    for (const s of spend){
      const k = s.name || 'Unclassified';
      byDept.set(k, (byDept.get(k) || 0) + Number(s.expense || 0));
    }
    const deptRows = [...byDept.entries()].map(([name, amount]) => ({ name, amount }))
      .sort((a,b) => b.amount - a.amount);

    out.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'What each department cost' })),
      table([
        { label:'Department', primary:true, key:'name' },
        { label:'Spent', cls:'num', fmt: r => money(r.amount, { bare:true }), csv: r => r.amount },
        { label:'Share', cls:'num',
          fmt: r => Math.round(r.amount / (totalOut || 1) * 100) + '%',
          csv: r => Math.round(r.amount / (totalOut || 1) * 100) }
      ], deptRows, { empty:'Nothing was spent in this year.',
        foot: [{ value:'Total' }, { cls:'num', value: money(totalOut, { bare:true }) }, { value:'' }] })));

    /* Where the building stands now — the closing position the spec asks
       every report to end with. */
    const pos = position[0];
    if (pos){
      const reserve = funds.filter(f => f.is_active)
        .reduce((t,f) => t + Number(f.current_balance || 0), 0);
      out.append(el('section', { class:'card' },
        el('div', { class:'card-head' }, el('h2', { text:'Position at the end of this report' })),
        el('div', { class:'grid g-stats' },
          stat('Cash in hand', money0(pos.cash_in_hand)),
          stat('In the bank', money0(pos.bank_balance)),
          stat('Fixed deposits', money0(pos.fixed_deposits)),
          stat('Total held', money0(pos.total_held))),
        el('div', { class:'grid g-stats', style:'margin-top:.6rem' },
          stat('Service charge owed to us', money0(pos.service_charge_receivable)),
          stat('Paid in advance by flats', money0(pos.advances_held)),
          funds.length ? stat('Earmarked as reserve', money0(reserve)) : null,
          stat('Salaries generated, unpaid', money0(pos.salary_due))),
        el('p', { class:'hint',
          text:'"Held" is money that exists today. The second row is money owed in either direction, and is not part of the balance.' })));
    }

    body.replaceChildren(out);
  }

  await load();
  return page;
}

/* =====================================================================
   THE MONTHLY REPORT — what the finance controller prints and files.

   Page 1 is the summary a committee reads: income by department, expense
   by department, the result, every account from opening to closing, every
   reserve fund, the fixed deposits and the service-charge collection,
   with lines to sign. Every page after it is evidence — each income
   entry, each expense entry, each transfer and fund movement, and the
   service charge flat by flat — and each starts on a fresh sheet of
   paper, so the summary can be read on its own and the detail filed
   behind it.

   Every total on it comes from a SQL function (086_reports_funds.sql);
   the screen only lays them out. The detail lists are the rows those
   totals were made from, so their footers match the summary exactly.
   ===================================================================== */
const MONTHS_LONG = ['January','February','March','April','May','June','July',
                     'August','September','October','November','December'];
const isoDate = (d) => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
const methodName = (m) => String(m || '').replace(/_/g, ' ').toLowerCase().replace(/^\w/, c => c.toUpperCase());

async function monthly(){
  const page = el('div', { class:'monthly-report' });
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Reports' }),
    el('p', { class:'sub', text:'The monthly financial report: a summary to read and sign, then every entry behind it on separate pages for filing.' })));
  page.append(tabs('monthly'));

  // In the first ten days of a month the report being made is last
  // month's — it has just closed. After that, this month's.
  const last = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const start = now.getDate() <= 10 ? last : new Date(now.getFullYear(), now.getMonth(), 1);
  const kindI  = select([{ value:'month', label:'A month' }, { value:'range', label:'Date range' }, { value:'year', label:'A whole year' }],
                        { value:'month' });
  const monthI = select(MONTHS_LONG.map((m, i) => ({ value: i + 1, label: m })), { value: start.getMonth() + 1 });
  const years  = Array.from({ length: 6 }, (_, i) => now.getFullYear() + 1 - i).map(y => ({ value:y, label:String(y) }));
  const yearI  = select(years, { value: start.getFullYear() });
  const fromI  = el('input', { type:'date', value: isoDate(start) });
  const toI    = el('input', { type:'date', value: isoDate(new Date(start.getFullYear(), start.getMonth() + 1, 0)) });
  const detailI = el('input', { type:'checkbox' }); detailI.checked = true;

  const fMonth = el('div', { class:'ctl' }, field('Month', monthI));
  const fYear  = el('div', { class:'ctl' }, field('Year', yearI));
  const fFrom  = el('div', { class:'ctl' }, field('From', fromI));
  const fTo    = el('div', { class:'ctl' }, field('To', toI));
  const quick = (label, fn) => el('button', { class:'btn small', type:'button', text: label, onclick: () => { fn(); load(); } });
  const setMonth = (d) => { kindI.value = 'month'; monthI.value = d.getMonth() + 1; yearI.value = d.getFullYear(); };

  const range = () => {
    if (kindI.value === 'month'){
      const y = Number(yearI.value), m = Number(monthI.value);
      return { from: isoDate(new Date(y, m - 1, 1)), to: isoDate(new Date(y, m, 0)),
               label: `${MONTHS_LONG[m - 1]} ${y}`, file: `${y}-${String(m).padStart(2,'0')}` };
    }
    if (kindI.value === 'year'){
      const y = Number(yearI.value);
      return { from: `${y}-01-01`, to: `${y}-12-31`, label: `Year ${y}`, file: String(y) };
    }
    return { from: fromI.value, to: toI.value, label: `${fdate(fromI.value)} to ${fdate(toI.value)}`,
             file: `${fromI.value}-to-${toI.value}` };
  };
  const syncKind = () => {
    fMonth.hidden = kindI.value !== 'month';
    fYear.hidden  = kindI.value === 'range';
    fFrom.hidden = fTo.hidden = kindI.value !== 'range';
  };
  kindI.onchange = () => { syncKind(); load(); };
  for (const c of [monthI, yearI, fromI, toI]) c.onchange = load;
  detailI.onchange = () => page.classList.toggle('no-detail', !detailI.checked);

  const actions = el('span', { class:'report-actions' });
  page.append(el('div', { class:'toolbar report-controls' },
    el('div', { class:'ctl' }, field('Report for', kindI)), fMonth, fYear, fFrom, fTo,
    el('div', { class:'quick' },
      quick('Last month', () => setMonth(last)),
      quick('This month', () => setMonth(now))),
    el('label', { class:'check', style:'min-height:auto' }, detailI, el('span', { text:'Include the detail pages' })),
    el('span', { class:'spacer' }), actions));
  syncKind();

  const body = el('div', {});
  page.append(body);

  async function load(){
    const r = range();
    if (!r.from || !r.to || r.to < r.from){ body.replaceChildren(emptyState('Choose a start date before the end date.')); return; }
    body.replaceChildren(el('p', { class:'muted', text:'Building the report…' }));
    let data;
    try { data = await gather(r); }
    catch (e){
      const o = e.original || e;
      body.replaceChildren(isMissingObject(o)
        ? el('div', { class:'alert normal' }, el('div', { class:'a-body' },
            el('div', { class:'a-title', text:'The monthly report needs a database update' }),
            el('div', { class:'a-meta', text:'In Supabase open the SQL Editor and run sql/PATCH.sql — it is safe to run twice — then reload this page. Until then, "Search entries" and "Annual summary" still work.' })))
        : emptyState('The report could not be built: ' + (o.message || o)));
      actions.replaceChildren();
      return;
    }
    body.replaceChildren(renderReport(r, data));
    actions.replaceChildren(...reportButtons(r, data));
  }

  await load();
  return page;
}

/** Everything the report needs, fetched at once. */
async function gather(r){
  const args = { p_from: r.from, p_to: r.to };
  const [ie, accts, funds, sc] = await Promise.all([
    rpc('report_income_expense', args, { silent:true }),
    rpc('report_accounts', args, { silent:true }),
    rpc('report_funds', args, { silent:true }),
    rpc('report_service_charge', args, { silent:true })
  ]);
  const [entries, transfers, moves, fds, flatCharges] = await Promise.all([
    q('v_transactions', b => b.eq('counts_in_totals', true).gte('txn_date', r.from).lte('txn_date', r.to)
      .order('txn_date').order('txn_no'), { silent:true }).catch(() => []),
    q('v_transactions', b => b.eq('status', 'POSTED').eq('direction', 'TRANSFER').gte('txn_date', r.from).lte('txn_date', r.to)
      .order('txn_date'), { silent:true }).catch(() => []),
    q('fund_movements', b => b.gte('movement_date', r.from).lte('movement_date', r.to).order('movement_date'), { silent:true }).catch(() => []),
    q('v_fixed_deposits', b => b.eq('status', 'ACTIVE').order('maturity_date'), { silent:true }).catch(() => null),
    q('v_flat_charges', b => b.neq('charge_source', 'OPENING')
      .gte('period_start', r.from.slice(0, 8) + '01').lte('period_start', r.to)
      .order('period_year').order('period_month').order('flat_number'), { silent:true }).catch(() => [])
  ]);
  return { ie: ie || [], accts: accts || [], funds: funds || [], sc: (Array.isArray(sc) ? sc[0] : sc) || {},
           entries, transfers, moves, fds, flatCharges };
}

/** Department → its categories, with the department subtotal from the SQL rows. */
function byDepartment(rows){
  const out = [];
  for (const row of rows){
    let d = out.find(x => x.name === row.department_name);
    if (!d){ d = { name: row.department_name, lines: [], subtotal: 0 }; out.push(d); }
    d.lines.push(row);
  }
  return out;
}

function deptTable(rows, total, emptyText){
  if (!rows.length) return emptyState(emptyText);
  const tbody = el('tbody');
  for (const d of byDepartment(rows)){
    const sub = d.lines.reduce((t, l) => t + Number(l.amount), 0);
    tbody.append(el('tr', { class:'dept-row' },
      el('td', { 'data-l':'Department', text: d.name }),
      el('td', { class:'num', 'data-l':'Entries', text: num(d.lines.reduce((t, l) => t + Number(l.entries), 0)) }),
      el('td', { class:'num', 'data-l':'Amount', text: money(sub, { bare:true }) })));
    for (const l of d.lines){
      tbody.append(el('tr', { class:'cat-row' },
        el('td', { 'data-l':'Category', text: l.category_name }),
        el('td', { class:'num', 'data-l':'Entries', text: num(l.entries) }),
        el('td', { class:'num', 'data-l':'Amount', text: money(l.amount, { bare:true }) })));
    }
  }
  return el('div', { class:'tablewrap' }, el('table', { class:'stack report-table' },
    el('thead', {}, el('tr', {}, el('th', {}, 'Department / category'), el('th', { class:'num' }, 'Entries'), el('th', { class:'num' }, 'Amount'))),
    tbody,
    el('tfoot', {}, el('tr', {}, el('td', { text:'Total' }), el('td', {}), el('td', { class:'num', text: money(total, { bare:true }) })))));
}

function totals(data){
  const sumOf = (rows, k) => rows.reduce((t, x) => t + Number(x[k] || 0), 0);
  const income  = data.ie.filter(x => x.direction === 'INCOME');
  const expense = data.ie.filter(x => x.direction === 'EXPENSE');
  const money_ = data.accts.filter(a => a.kind !== 'FD');
  const fdAcc  = data.accts.filter(a => a.kind === 'FD');
  return {
    income, expense,
    inc: sumOf(income, 'amount'), exp: sumOf(expense, 'amount'),
    money_, fdAcc,
    open: sumOf(money_, 'opening'), close: sumOf(money_, 'closing'),
    mIn: sumOf(money_, 'money_in'), mOut: sumOf(money_, 'money_out'),
    fdClose: sumOf(fdAcc, 'closing'),
    fOpen: sumOf(data.funds, 'opening'), fAdd: sumOf(data.funds, 'added'),
    fUsed: sumOf(data.funds, 'used'), fClose: sumOf(data.funds, 'closing')
  };
}

function renderReport(r, data){
  const s = settings();
  const t = totals(data);
  const net = t.inc - t.exp;
  const out = el('div', { class:'report' });

  /* ---------------- PAGE 1: SUMMARY ---------------- */
  out.append(letterhead({ name: s.building_name, address: s.address,
    title: 'Monthly financial report', period: r.label }));
  out.append(el('h2', { class:'report-title', text:`Financial report — ${r.label}` }),
             el('p', { class:'small muted report-period', text:`${fdate(r.from)} to ${fdate(r.to)} · posted entries only` }));

  out.append(el('div', { class:'grid g-stats' },
    stat('Total income', money0(t.inc)),
    stat('Total expense', money0(t.exp)),
    stat(net >= 0 ? 'Surplus' : 'Deficit', money0(Math.abs(net)), null, net >= 0 ? 'good' : 'bad'),
    stat('Cash & bank at the end', money0(t.close), `${money0(t.open)} at the start`)));

  out.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'1. Income by department' })),
    deptTable(t.income, t.inc, 'No income in this period.')));

  out.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'2. Expense by department' })),
    deptTable(t.expense, t.exp, 'No expense in this period.')));

  out.append(el('section', { class:'card result-card' },
    el('div', { class:'card-head' }, el('h2', { text:'3. Result' })),
    el('dl', { class:'dl result' },
      el('dt', { text:'Total income' }),  el('dd', { class:'num', text: money(t.inc) }),
      el('dt', { text:'Total expense' }), el('dd', { class:'num', text: money(t.exp) }),
      el('dt', { text: net >= 0 ? 'Surplus for the period' : 'Deficit for the period' }),
      el('dd', { class:'num ' + (net >= 0 ? 'good' : 'bad'), text: money(Math.abs(net)) }))));

  // Accounts: where the money is.
  const acctCols = [
    { label:'Account', primary:true, key:'name' },
    { label:'Opening', cls:'num', fmt: a => money(a.opening, { bare:true }) },
    { label:'Money in', cls:'num', fmt: a => money(a.money_in, { bare:true }) },
    { label:'Money out', cls:'num', fmt: a => money(a.money_out, { bare:true }) },
    { label:'Closing', cls:'num', fmt: a => money(a.closing, { bare:true }) }
  ];
  out.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'4. Cash and bank' })),
    table(acctCols, t.money_, { empty:'No accounts.', stack:true,
      foot: [{ value:'Total' }, { cls:'num', value: money(t.open, { bare:true }) }, { cls:'num', value: money(t.mIn, { bare:true }) },
             { cls:'num', value: money(t.mOut, { bare:true }) }, { cls:'num', value: money(t.close, { bare:true }) }] }),
    el('p', { class:'hint', text:'Money in and out include transfers between our own accounts, so they are larger than income and expense; the totals of the two always agree.' })));

  // Reserve funds.
  const fundCols = [
    { label:'Fund', primary:true, fmt: f => f.purpose ? `${f.name} — ${f.purpose}` : f.name },
    { label:'Opening', cls:'num', fmt: f => money(f.opening, { bare:true }) },
    { label:'Added', cls:'num', fmt: f => money(f.added, { bare:true }) },
    { label:'Used', cls:'num', fmt: f => money(f.used, { bare:true }) },
    { label:'Closing', cls:'num', fmt: f => money(f.closing, { bare:true }) },
    { label:'Target', cls:'num', fmt: f => f.target_amount ? money(f.target_amount, { bare:true }) : '—' }
  ];
  const fundCard = el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'5. Reserve and other funds' })),
    table(fundCols, data.funds, { empty:'No funds set up yet. Add them under Reserve & Deposits.',
      foot: data.funds.length ? [{ value:'Total' }, { cls:'num', value: money(t.fOpen, { bare:true }) },
        { cls:'num', value: money(t.fAdd, { bare:true }) }, { cls:'num', value: money(t.fUsed, { bare:true }) },
        { cls:'num', value: money(t.fClose, { bare:true }) }, { value:'' }] : null }));
  const shortNow = data.funds.filter(f => f.is_active && f.is_funded_now === false);
  if (shortNow.length) fundCard.append(el('p', { class:'warn-line', text:
    `Not fully backed by money today: ${shortNow.map(f => `${f.name} (${money0(Number(f.funded_now || 0))} held)`).join(', ')}.` }));
  if (data.fds && data.fds.length){
    fundCard.append(el('h3', { text:'Fixed deposits held' }), table([
      { label:'Deposit', primary:true, fmt: d => `${d.fd_no} · ${d.bank_name}` },
      { label:'Principal', cls:'num', fmt: d => money(d.principal, { bare:true }) },
      { label:'Rate', cls:'num', fmt: d => d.interest_rate ? num(d.interest_rate, 2) + '%' : '—' },
      { label:'Matures', fmt: d => d.maturity_date ? fdate(d.maturity_date) : '—' },
      { label:'Held for', fmt: d => d.fund_name || d.purpose || '—' }
    ], data.fds, { foot: [{ value:'In deposits at the end' }, { cls:'num', value: money(t.fdClose, { bare:true }) }, { value:'' }, { value:'' }, { value:'' }] }));
  }
  out.append(fundCard);

  // Service charge.
  const sc = data.sc;
  out.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'6. Service charge' })),
    el('dl', { class:'dl' },
      el('dt', { text:'Billed for the period' }), el('dd', { class:'num', text: money(sc.billed || 0) }),
      el('dt', { text:'Paid of that so far' }), el('dd', { class:'num', text: `${money(sc.paid_against_billed || 0)} (${num(sc.collection_pct || 0, 1)}%)` }),
      el('dt', { text:'Flats paid / part / unpaid' }), el('dd', { text: `${num(sc.paid_full || 0)} / ${num(sc.paid_partial || 0)} / ${num(sc.unpaid || 0)}` +
        (r.from.slice(0, 7) !== r.to.slice(0, 7) ? ' (counted per flat per month)' : '') }),
      el('dt', { text:'Received in the period' }), el('dd', { class:'num', text: `${money(sc.received_in_period || 0)} · ${num(sc.receipts_in_period || 0)} receipts` }),
      el('dt', { text:'Outstanding today' }), el('dd', { class:'num', text: `${money(sc.outstanding_now || 0)} · ${num(sc.flats_owing_now || 0)} flats` }),
      el('dt', { text:'Advances held today' }), el('dd', { class:'num', text: money(sc.advance_now || 0) }))));

  // Sign-off.
  const me = state.profile?.full_name || '';
  out.append(el('section', { class:'card signoff' },
    el('div', { class:'sign' }, el('div', { class:'sign-line' }), el('div', { text:'Prepared by' }), el('div', { class:'small muted', text: me })),
    el('div', { class:'sign' }, el('div', { class:'sign-line' }), el('div', { text:'Checked by' })),
    el('div', { class:'sign' }, el('div', { class:'sign-line' }), el('div', { text:'Approved by' }))));

  /* ---------------- DETAIL PAGES ---------------- */
  const detail = (title, intro, node) => el('section', { class:'card page-break detail-page' },
    el('div', { class:'card-head' }, el('h2', { text: title })),
    el('p', { class:'small muted', text: `${r.label} · ${intro}` }), node);

  const inc = data.entries.filter(e => e.direction === 'INCOME');
  const exp = data.entries.filter(e => e.direction === 'EXPENSE');
  // Eight columns at most, so an entry list reads on portrait A4.
  const entryCols = (who) => [
    { label:'Date', cls:'nowrap', fmt: e => fdate(e.txn_date) },
    { label:'No.', cls:'mono nowrap', key:'txn_no' },
    { label:'Description', primary:true, key:'description' },
    { label:'Filed under', fmt: e => [e.department_name, e.category_name].filter(Boolean).join(' · ') },
    { label: who, fmt: e => (who === 'Paid to' ? e.vendor_name : e.flat_number ? 'Flat ' + e.flat_number : '') || '' },
    { label:'Via', fmt: e => [methodName(e.payment_method), e.account_name].filter(Boolean).join(' · ') },
    ...(who === 'Paid to' ? [{ label:'Approved by', fmt: e => e.approved_by_name || '' }] : []),
    { label:'Amount', cls:'num nowrap', fmt: e => money(e.amount, { bare:true }) }
  ];
  const foot = (cols, n, total) => cols.map((c, i) =>
    i === 0 ? { value:`${n} entries` } : i === cols.length - 2 ? { value:'Total' }
    : i === cols.length - 1 ? { cls:'num nowrap', value: money(total, { bare:true }) } : { value:'' });

  const incCols = entryCols('From'), expCols = entryCols('Paid to');
  out.append(detail('A. Income entries', 'every income entry counted in section 1',
    table(incCols, inc, { empty:'No income entries.', foot: inc.length ? foot(incCols, inc.length, t.inc) : null })));
  out.append(detail('B. Expense entries', 'every expense entry counted in section 2',
    table(expCols, exp, { empty:'No expense entries.', foot: exp.length ? foot(expCols, exp.length, t.exp) : null })));

  const fundName = (id) => (data.funds.find(f => f.fund_id === id) || {}).name || '—';
  const moveLabel = { CONTRIBUTION:'Put in', WITHDRAWAL:'Taken out', INTEREST:'Interest', TRANSFER_IN:'Transfer in', TRANSFER_OUT:'Transfer out' };
  out.append(detail('C. Transfers and fund movements', 'money moved between our own accounts, and every change to a fund',
    el('div', {},
      el('h3', { text:'Transfers between accounts' }),
      table([
        { label:'Date', fmt: e => fdate(e.txn_date) },
        { label:'No.', cls:'mono', key:'txn_no' },
        { label:'Description', primary:true, key:'description' },
        { label:'From', fmt: e => e.account_name || '' },
        { label:'To', fmt: e => e.counter_account_name || '' },
        { label:'Amount', cls:'num', fmt: e => money(e.amount, { bare:true }) }
      ], data.transfers, { empty:'No transfers.' }),
      el('h3', { text:'Fund movements' }),
      table([
        { label:'Date', fmt: m => fdate(m.movement_date) },
        { label:'Fund', primary:true, fmt: m => fundName(m.fund_id) },
        { label:'Movement', fmt: m => moveLabel[m.direction] || m.direction },
        { label:'Money moved', fmt: m => m.is_cash_movement ? 'Yes' : 'Decision only' },
        { label:'Purpose', fmt: m => m.purpose || m.notes || '' },
        { label:'Amount', cls:'num', fmt: m => money(m.amount, { bare:true }) }
      ], data.moves, { empty:'No fund movements.' }))));

  out.append(detail('D. Service charge flat by flat', 'what each flat was billed for the period and what it has paid of it',
    table([
      { label:'Flat', primary:true, key:'flat_number' },
      { label:'Month', fmt: c => monthName(c.period_year, c.period_month) },
      { label:'Billed', cls:'num', fmt: c => money(c.net_payable, { bare:true }) },
      { label:'Paid', cls:'num', fmt: c => money(c.paid_amount, { bare:true }) },
      { label:'Still due', cls:'num', fmt: c => money(c.due_amount, { bare:true }) },
      { label:'Status', fmt: c => c.status }
    ], data.flatCharges, { empty:'Nothing was billed for this period.',
      foot: data.flatCharges.length ? [{ value:'Total' }, { value:'' }, { cls:'num', value: money(sc.billed || 0, { bare:true }) },
        { cls:'num', value: money(sc.paid_against_billed || 0, { bare:true }) },
        { cls:'num', value: money(Number(sc.billed || 0) - Number(sc.paid_against_billed || 0), { bare:true }) }, { value:'' }] : null })));

  out.append(el('p', { class:'small muted report-end', text:
    `End of report · ${s.building_name || ''} · ${r.label} · produced ${fdate(todayISO())}` }));
  return out;
}

function reportButtons(r, data){
  if (!can('reports','export') && !can('reports','view')) return [];
  const t = totals(data);
  const s = settings();
  const btns = [];
  btns.push(el('button', { class:'btn primary', type:'button', onclick: () => {
    logEvent('REPORT_VIEW', { module:'reports', detail:`monthly report ${r.file} (printed)` });
    window.print();
  }}, 'Print / PDF'));
  if (!can('reports','export')) return btns;
  btns.push(el('button', { class:'btn', type:'button', onclick: () => {
    const flat = (rows) => rows.map(x => ({ ...x, amount: Number(x.amount) }));
    downloadXLSX(`financial-report-${r.file}.xlsx`, [
      { name:'Summary', title: s.building_name || 'Building', subtitle:`Financial report — ${r.label} (${r.from} to ${r.to})`,
        columns:[{ label:'Figure', key:'k', width:38 }, { label:'Amount', key:'v', money:true }],
        rows:[
          { k:'Total income', v: t.inc }, { k:'Total expense', v: t.exp },
          { k: t.inc - t.exp >= 0 ? 'Surplus' : 'Deficit', v: Math.abs(t.inc - t.exp) },
          { k:'Cash & bank at the start', v: t.open }, { k:'Cash & bank at the end', v: t.close },
          { k:'Funds (earmarked) at the end', v: t.fClose }, { k:'Fixed deposits at the end', v: t.fdClose },
          { k:'Service charge billed', v: Number(data.sc.billed || 0) },
          { k:'Service charge paid of that', v: Number(data.sc.paid_against_billed || 0) },
          { k:'Service charge received in period', v: Number(data.sc.received_in_period || 0) },
          { k:'Outstanding today', v: Number(data.sc.outstanding_now || 0) }
        ] },
      { name:'Income by department', columns:[{ label:'Department', key:'department_name', width:28 },
          { label:'Category', key:'category_name', width:36 }, { label:'Entries', key:'entries' }, { label:'Amount', key:'amount', money:true }],
        rows: flat(t.income), total:{ amount: t.inc } },
      { name:'Expense by department', columns:[{ label:'Department', key:'department_name', width:28 },
          { label:'Category', key:'category_name', width:36 }, { label:'Entries', key:'entries' }, { label:'Amount', key:'amount', money:true }],
        rows: flat(t.expense), total:{ amount: t.exp } },
      { name:'Cash and bank', columns:[{ label:'Account', key:'name', width:28 }, { label:'Opening', key:'opening', money:true },
          { label:'Money in', key:'money_in', money:true }, { label:'Money out', key:'money_out', money:true }, { label:'Closing', key:'closing', money:true }],
        rows: t.money_, total:{ opening: t.open, money_in: t.mIn, money_out: t.mOut, closing: t.close } },
      { name:'Funds', columns:[{ label:'Fund', key:'name', width:30 }, { label:'Purpose', key:'purpose', width:30 },
          { label:'Opening', key:'opening', money:true }, { label:'Added', key:'added', money:true }, { label:'Used', key:'used', money:true },
          { label:'Closing', key:'closing', money:true }, { label:'Target', key:'target_amount', money:true }],
        rows: data.funds, total:{ opening: t.fOpen, added: t.fAdd, used: t.fUsed, closing: t.fClose } },
      { name:'Income entries', columns: entrySheetCols(), rows: data.entries.filter(e => e.direction === 'INCOME'), total:{ amount: t.inc } },
      { name:'Expense entries', columns: entrySheetCols(true), rows: data.entries.filter(e => e.direction === 'EXPENSE'), total:{ amount: t.exp } },
      { name:'Transfers', columns:[{ label:'Date', key:'txn_date', width:12 }, { label:'Number', key:'txn_no', width:16 },
          { label:'Description', key:'description', width:40 }, { label:'From', key:'account_name', width:22 },
          { label:'To', key:'counter_account_name', width:22 }, { label:'Amount', key:'amount', money:true }], rows: data.transfers },
      { name:'Service charge by flat', columns:[{ label:'Flat', key:'flat_number' }, { label:'Year', key:'period_year' },
          { label:'Month', key:'period_month' }, { label:'Billed', key:'net_payable', money:true }, { label:'Paid', key:'paid_amount', money:true },
          { label:'Due', key:'due_amount', money:true }, { label:'Status', key:'status' }], rows: data.flatCharges,
        total:{ net_payable: Number(data.sc.billed || 0), paid_amount: Number(data.sc.paid_against_billed || 0),
                due_amount: Number(data.sc.billed || 0) - Number(data.sc.paid_against_billed || 0) } }
    ]);
    logEvent('EXPORT', { module:'reports', detail:`monthly report ${r.file} (xlsx)` });
  }}, 'Export Excel'));
  return btns;
}

const entrySheetCols = (expense) => [
  { label:'Date', key:'txn_date', width:12 }, { label:'Number', key:'txn_no', width:16 },
  { label:'Description', key:'description', width:40 }, { label:'Department', key:'department_name', width:22 },
  { label:'Category', key:'category_name', width:26 },
  expense ? { label:'Paid to', key:'vendor_name', width:22 } : { label:'Flat', key:'flat_number', width:10 },
  { label:'Method', key:'payment_method', width:14 }, { label:'Account', key:'account_name', width:20 },
  ...(expense ? [{ label:'Approved by', key:'approved_by_name', width:20 }] : []),
  { label:'Amount', key:'amount', money:true }
];
