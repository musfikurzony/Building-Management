/* Budget versus actual.

   Two figures are shown for every department, and the distinction matters
   more than it looks:

     Annual   — what the whole year is allowed.
     To date  — what the year is allowed SO FAR, months elapsed only.

   A department three months into the year that has spent 40% of its annual
   budget is not over budget on the year, but it IS ahead of where it should
   be — and that is the warning worth acting on, so it is the one the page
   leads with. */

import { el, field, select, money, money0, num, table, stat, ok, err,
         modal, emptyState, downloadCSV } from '../core/ui.js';
import { q, rpc, logEvent } from '../core/db.js';
import { refresh } from '../core/router.js';
import { can, ref } from '../core/store.js';

const thisYear = () => new Date().getFullYear();

export async function render({ query }){
  const year = Number(query.get('year')) || thisYear();
  const rows = await q('v_budget_vs_actual', b => b.eq('fiscal_year', year)
    .order('department_name'));

  const annual = rows.reduce((t,r) => t + Number(r.annual_amount || 0), 0);
  const actual = rows.reduce((t,r) => t + Number(r.actual || 0), 0);
  const toDate = rows.reduce((t,r) => t + Number(r.budget_to_date || 0), 0);
  const over   = rows.filter(r => r.over_budget_to_date);

  const cols = [
    { label:'Department', primary:true, key:'department_name' },
    { label:'Category', fmt: r => r.category_name || 'all', csv: r => r.category_name },
    { label:'Annual budget', cls:'num', fmt: r => money(r.annual_amount, { bare:true }), csv: r => r.annual_amount },
    { label:'Allowed to date', cls:'num', fmt: r => money(r.budget_to_date, { bare:true }), csv: r => r.budget_to_date },
    { label:'Actually spent', cls:'num', fmt: r => money(r.actual, { bare:true }), csv: r => r.actual },
    { label:'Left for the year', cls:'num',
      fmt: r => el('span', { class: Number(r.remaining) < 0 ? 'num b-overdue' : 'num' },
                   money(r.remaining, { bare:true })),
      csv: r => r.remaining },
    { label:'Against the year', fmt: r => usageBar(r), csv: r => r.annual_amount > 0
        ? Math.round(Number(r.actual) * 100 / Number(r.annual_amount)) : null },
    { label:'Pace', fmt: r => paceBadge(r), csv: r => r.variance_pct_to_date }
  ];

  const years = [];
  for (let y = thisYear() + 1; y >= thisYear() - 4; y--) years.push(y);
  const yearI = select(years.map(y => ({ value:y, label:String(y) })), { value: year });
  yearI.onchange = () => { location.hash = '#/budget?year=' + yearI.value; };

  const bar = el('div', { class:'toolbar' },
    el('label', { class:'field' }, el('span', {}, 'Year'), yearI));
  if (can('budget','add'))
    bar.append(el('button', { class:'btn primary', onclick: () => budgetDialog(year) }, '＋ Set a budget'));
  bar.append(el('span', { class:'spacer' }));
  if (can('budget','export'))
    bar.append(el('button', { class:'btn small', onclick: () => {
      downloadCSV(`budget-${year}.csv`, cols, rows); logEvent('EXPORT', { module:'budget' }); }}, 'Export CSV'));

  const page = el('div', {},
    el('div', { class:'page-head' }, el('h1', {}, 'Budget vs actual'),
      el('p', { class:'sub' }, `Fiscal year ${year}. "Allowed to date" counts only the months that have happened.`)),
    el('div', { class:'grid g-stats' },
      stat('Budgeted for the year', money0(annual), `${rows.length} budget${rows.length === 1 ? '' : 's'}`),
      stat('Allowed to date', money0(toDate), 'months elapsed'),
      stat('Actually spent', money0(actual),
           toDate > 0 ? num(actual * 100 / toDate, 0) + '% of what was allowed' : '',
           actual > toDate ? 'bad' : 'good'),
      stat('Over budget', String(over.length),
           over.length ? 'departments ahead of pace' : 'nothing over pace',
           over.length ? 'bad' : 'good')));

  for (const r of over)
    page.append(el('div', { class:'alert normal' },
      el('div', { class:'a-body' },
        el('div', { class:'a-title' }, `${r.department_name} is ahead of budget`),
        el('div', { class:'a-meta' },
          `${money(r.actual)} spent against ${money(r.budget_to_date)} allowed so far` +
          (Number(r.remaining) < 0
            ? ` — the annual budget is already exceeded by ${money(Math.abs(Number(r.remaining)))}.`
            : ` — ${money(r.remaining)} of the year is left.`)))));

  page.append(bar);

  if (!rows.length)
    page.append(emptyState(
      `No budgets have been set for ${year}. Set one per department and the dashboard will start warning you before the money runs out, not after.`,
      can('budget','add')
        ? el('button', { class:'btn primary', onclick: () => budgetDialog(year) }, 'Set the first budget')
        : null));
  else
    page.append(table(cols, rows, { onRow: r => can('budget','edit') ? budgetDialog(year, r) : null }));

  return page;
}

function usageBar(r){
  const annual = Number(r.annual_amount || 0);
  const pct = annual > 0 ? (Number(r.actual || 0) * 100 / annual) : 0;
  const shown = Math.max(0, Math.min(100, pct));
  return el('div', {},
    el('div', { class:'bar' + (pct > 100 ? ' over' : pct > 85 ? ' warn' : '') },
      el('span', { style:`width:${shown}%` })),
    el('span', { class:'small muted' }, num(pct, 0) + '%'));
}

function paceBadge(r){
  if (r.variance_pct_to_date === null || r.variance_pct_to_date === undefined)
    return el('span', { class:'badge b-draft' }, 'no pace yet');
  const v = Number(r.variance_pct_to_date);
  if (v > 10)  return el('span', { class:'badge b-overdue' }, `${num(v,0)}% ahead`);
  if (v > 0)   return el('span', { class:'badge b-pending' }, `${num(v,0)}% ahead`);
  return el('span', { class:'badge b-ok' }, `${num(Math.abs(v),0)}% under`);
}

async function budgetDialog(year, existing){
  const [depts, cats] = await Promise.all([ref('departments'), ref('categories')]);

  const yearI = el('input', { type:'number', min:'2000', max:'2200', step:'1', value: year, required:true });
  const deptI = select(depts.map(d => ({ value:d.id, label:d.name })),
                       { value: existing?.department_id || '', placeholder:'Choose a department' });
  const catI  = select([], { placeholder:'The whole department' });
  const amtI  = el('input', { type:'number', step:'0.01', min:'0', required:true,
                              inputmode:'decimal', value: existing?.annual_amount ?? '' });
  const noteI = el('textarea', { rows:'2' });

  // Categories follow the chosen department, and "whole department" stays
  // the default — a per-category budget is the exception, not the rule.
  const fillCats = () => {
    catI.replaceChildren(el('option', { value:'' }, 'The whole department'));
    for (const c of cats.filter(c => c.department_id === deptI.value && c.is_active !== false))
      catI.append(el('option', { value:c.id }, c.name));
    catI.value = existing?.category_id || '';
  };
  deptI.onchange = fillCats;
  fillCats();

  // Show the monthly figure, because Tk 300,000 a year is easier to argue
  // about when you can see it is Tk 25,000 a month.
  const monthly = el('p', { class:'hint' }, '');
  const recalc = () => {
    const a = Number(amtI.value);
    monthly.textContent = a > 0
      ? `That is about ${money(a / 12)} a month. The year is split evenly, with the rounding remainder placed in December.`
      : '';
  };
  amtI.oninput = recalc; recalc();

  const res = await modal({
    title: existing ? `Budget for ${existing.department_name}` : 'Set a budget',
    body: el('div', {},
      field('Fiscal year', yearI, { required:true }),
      field('Department', deptI, { required:true }),
      field('Category', catI, { hint:'Leave as the whole department unless you genuinely track one line separately.' }),
      field('Annual budget', amtI, { required:true }),
      monthly,
      field('Notes', noteI)),
    actions: [{ label:'Save budget', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;
  if (!deptI.value) return err('Choose a department.');
  if (!(Number(amtI.value) >= 0)) return err('Enter the annual budget.');

  try {
    await rpc('set_budget', {
      p_year: Number(yearI.value), p_department: deptI.value,
      p_annual: Number(amtI.value), p_category: catI.value || null,
      p_monthly: null, p_notes: noteI.value.trim() || null
    });
    ok('Budget saved and split across the twelve months.');
    if (Number(yearI.value) !== year) location.hash = '#/budget?year=' + yearI.value;
    else refresh();
  } catch (e){ err(e.message); }
}
