/* Reports — monthly, yearly and any custom date range, with CSV export.
   Every figure comes from the same SQL views the dashboard uses, so a
   report and the dashboard can never disagree. */

import { el, field, select, money, money0, num, fdate, table, stat, emptyState,
         downloadCSV, todayISO, monthName } from '../core/ui.js';
import { q, logEvent } from '../core/db.js';
import { can, ref, settings } from '../core/store.js';

const now = new Date();

export async function render({ params }){
  if (params && params[0] === 'annual') return annual();
  return statement();
}

async function statement(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Reports' }),
    el('p', { class:'sub', text:'Posted transactions only. Transfers between our own accounts are excluded from income and expense.' })));
  page.append(el('div', { class:'toolbar' },
    el('a', { class:'btn', href:'#/reports/annual', text:'Annual summary' })));

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

    const out = el('div', {});
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

    const detailCard = el('section', { class:'card' },
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
  page.append(el('div', { class:'toolbar' },
    el('a', { class:'btn', href:'#/reports', text:'← Date-range report' }),
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
