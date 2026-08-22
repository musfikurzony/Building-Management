/* Mosque.

   There is no mosque table. The mosque is a department, its imam is a
   member of staff, and its electricity bill is a row in the ledger —
   which is exactly what the specification asked for: no separate
   accounting logic per department. This screen is that department,
   gathered into one place. */

import { el, field, money, money0, num, fdate, badge, table, stat, emptyState,
         downloadCSV, monthName } from '../core/ui.js';
import { q, logEvent } from '../core/db.js';
import { can, ref } from '../core/store.js';
import { go } from '../core/router.js';

const now = new Date();

export async function render(){
  const depts = await ref('departments');
  const mosque = depts.find(d => d.code === 'MOSQUE');
  if (!mosque) return emptyState('There is no Mosque department set up.');

  const year = now.getFullYear();
  const [txns, staff, monthly] = await Promise.all([
    q('v_transactions', b => b.eq('department_id', mosque.id)
        .gte('txn_date', `${year}-01-01`).order('txn_date', { ascending:false })).catch(() => []),
    q('v_staff', b => b.eq('department_id', mosque.id).order('name')).catch(() => []),
    q('v_department_spend', b => b.eq('code','MOSQUE').eq('period_year', year)
        .order('period_month')).catch(() => [])
  ]);

  const spend  = txns.filter(t => t.counts_in_totals && t.direction === 'EXPENSE')
                     .reduce((t,r) => t + Number(r.amount), 0);
  const income = txns.filter(t => t.counts_in_totals && t.direction === 'INCOME')
                     .reduce((t,r) => t + Number(r.amount), 0);

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Mosque' }),
    el('p', { class:'sub', text:`Everything charged to the mosque in ${year}. Entries are made in the ledger like any other spending.` })));

  page.append(el('div', { class:'grid g-stats' },
    stat(`Spent in ${year}`, money0(spend)),
    stat('Donations received', money0(income), null, income ? 'good' : ''),
    stat('Net cost', money0(spend - income)),
    stat('Staff', num(staff.length))));

  const bar = el('div', { class:'toolbar' });
  if (can('finance','add'))
    bar.append(el('a', { class:'btn primary', href:'#/finance/new', text:'＋ Record a mosque expense' }));
  page.append(bar);

  if (staff.length){
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Mosque staff' })),
      table([
        { label:'Name', primary:true, key:'name' },
        { label:'Position', key:'position_name' },
        { label:'Mobile', fmt: r => r.mobile || '—', csv: r => r.mobile },
        { label:'Monthly salary', cls:'num', fmt: r => money(r.salary, { bare:true }), csv: r => r.salary },
        { label:'Status', fmt: r => badge(r.status), csv: r => r.status }
      ], staff, { onRow: r => go('#/staff/' + r.id) })));
  }

  if (monthly.length){
    const max = Math.max(1, ...monthly.map(m => Number(m.expense || 0)));
    const card = el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Month by month' })));
    for (const m of monthly){
      card.append(el('div', { style:'margin-bottom:.45rem' },
        el('div', { style:'display:flex;gap:.6rem' },
          el('span', { style:'flex:1', text: monthName(m.period_year, m.period_month) }),
          el('span', { class:'num', text: money(m.expense) })),
        el('div', { class:'bar' }, el('span', { style:`width:${Math.round(Number(m.expense||0)/max*100)}%` }))));
    }
    page.append(card);
  }

  const cols = [
    { label:'Date', primary:true, fmt: r => fdate(r.txn_date), csv: r => r.txn_date },
    { label:'Number', cls:'mono', fmt: r => r.txn_no || '—', csv: r => r.txn_no },
    { label:'What', key:'description' },
    { label:'Category', fmt: r => r.category_name || '—', csv: r => r.category_name },
    { label:'Vendor', fmt: r => r.vendor_name || '—', csv: r => r.vendor_name },
    { label:'Amount', cls:'num', fmt: r => money(r.amount, { bare:true }), csv: r => r.amount },
    { label:'Status', fmt: r => badge(r.status), csv: r => r.status }
  ];
  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Ledger entries' }),
      can('finance','export') ? el('button', { class:'btn small', text:'CSV', onclick: () => {
        downloadCSV(`mosque-${year}.csv`, cols, txns); logEvent('EXPORT', { module:'mosque' }); }}) : null),
    table(cols, txns, { onRow: r => go('#/finance/' + r.id),
      empty:'Nothing charged to the mosque this year.' })));
  return page;
}
