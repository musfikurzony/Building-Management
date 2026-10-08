/* =====================================================================
   lpg.js — the LPG fund at a glance.

   The building keeps a standing LPG fund: it buys a cylinder, and is
   refilled when the flats pay their LPG meter bills. Billing each flat
   stays in the separate LPG Ledger app; this screen is only the fund —
   what it started with, what it has spent on cylinders, what has come
   back from the collection, and what is left.

   It is a view over the fund already kept in Reserve & Funds (any fund
   whose name or code says LPG), so there is one balance, not two. A
   cylinder bought is a real expense from the fund (category "LPG
   cylinder bought from LPG fund"); a refill is real income into it.
   ===================================================================== */

import { el, field, select, money, money0, num, fdate, table, stat, emptyState, ok, err, modal,
         todayISO, monthName } from '../core/ui.js';
import { q, insert } from '../core/db.js';
import { can, ref, invalidate } from '../core/store.js';
import { refresh } from '../core/router.js';
import { movementDialog } from './reserve.js';

const isLpg = (f) => /lpg/i.test(`${f.code || ''} ${f.name || ''}`);
const IN  = ['CONTRIBUTION','INTEREST','TRANSFER_IN'];
const signed = (m) => (IN.includes(m.direction) ? 1 : -1) * Number(m.amount);

export async function render(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' }, el('h1', { text:'LPG fund' }),
    el('p', { class:'sub', text:'What the LPG fund has spent on cylinders, what has come back from the meter-bill collection, and what is left. Billing each flat stays in the LPG Ledger app.' })));

  const funds = await q('v_fund_balances', b => b.eq('is_active', true)).catch(() => []);
  const fund = funds.find(isLpg);
  if (!fund){ page.append(await setupCard()); return page; }

  const moves = await q('fund_movements', b => b.eq('fund_id', fund.fund_id).order('movement_date', { ascending:true }).order('created_at', { ascending:true }))
    .catch(() => []);

  const now = new Date(), ym = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  const spent    = moves.filter(m => !IN.includes(m.direction)).reduce((t, m) => t + Number(m.amount), 0);
  const refilled = moves.filter(m => IN.includes(m.direction)).reduce((t, m) => t + Number(m.amount), 0);
  const thisSpent = moves.filter(m => !IN.includes(m.direction) && String(m.movement_date).startsWith(ym)).reduce((t, m) => t + Number(m.amount), 0);
  const thisIn    = moves.filter(m => IN.includes(m.direction) && String(m.movement_date).startsWith(ym)).reduce((t, m) => t + Number(m.amount), 0);
  const cylinders = moves.filter(m => m.direction === 'WITHDRAWAL' && m.is_cash_movement).length;
  const bal = Number(fund.current_balance);

  if (can('reserve','add')){
    page.append(el('div', { class:'toolbar' },
      el('button', { class:'btn primary big', type:'button', text:'Bought a cylinder', onclick: () => movementDialog(fund, 'WITHDRAWAL', {
        mode:'DIRECT', title:'Cylinder bought from the LPG fund', amountLabel:'Price paid',
        purposeHint:'e.g. 1 × 12 kg cylinder, Bashundhara, October' }) }),
      el('button', { class:'btn big', type:'button', text:'Refilled from LPG collection', onclick: () => movementDialog(fund, 'CONTRIBUTION', {
        mode:'DIRECT', title:'LPG fund refilled', amountLabel:'Amount put back',
        purposeHint:'e.g. October meter bills collected' }) }),
      el('a', { class:'btn', href:'#/reserve', text:'All funds' })));
  }

  page.append(el('div', { class:'grid g-stats' },
    stat('Balance now', money0(bal), fund.account_id ? 'available to buy the next cylinder' : 'kept with the building\u2019s cash', bal > 0 ? 'good' : 'bad'),
    stat('Started with', money0(fund.opening_balance), fund.opening_date ? `on ${fdate(fund.opening_date)}` : null),
    stat('Spent on cylinders', money0(spent), `${num(cylinders)} purchase${cylinders === 1 ? '' : 's'} in all`),
    stat('Refilled from collection', money0(refilled), 'from the flats’ LPG bills')));
  page.append(el('div', { class:'grid g-stats' },
    stat(`Spent in ${monthName(now.getFullYear(), now.getMonth() + 1)}`, money0(thisSpent)),
    stat('Refilled this month', money0(thisIn)),
    stat('Still to come back', money0(Math.max(Number(fund.opening_balance) - bal, 0)), 'to bring the fund back to where it started',
         Number(fund.opening_balance) - bal > 0 ? 'bad' : 'good')));

  // Month by month, with the balance carried forward.
  const byMonth = new Map();
  for (const m of moves){
    const k = String(m.movement_date).slice(0, 7);
    const r = byMonth.get(k) || { k, spent: 0, refilled: 0 };
    if (IN.includes(m.direction)) r.refilled += Number(m.amount); else r.spent += Number(m.amount);
    byMonth.set(k, r);
  }
  let run = Number(fund.opening_balance);
  const months = [...byMonth.values()].sort((a, b) => a.k.localeCompare(b.k))
    .map(r => { run += r.refilled - r.spent; return { ...r, closing: run }; }).reverse();
  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Month by month' })),
    table([
      { label:'Month', primary:true, fmt: r => { const [y, m] = r.k.split('-').map(Number); return monthName(y, m); } },
      { label:'Spent', cls:'num', fmt: r => r.spent ? money(r.spent, { bare:true }) : '—' },
      { label:'Refilled', cls:'num', fmt: r => r.refilled ? money(r.refilled, { bare:true }) : '—' },
      { label:'Balance at month end', cls:'num', fmt: r => el('b', { text: money(r.closing, { bare:true }) }) }
    ], months, { empty:'Nothing recorded yet. Use "Bought a cylinder" or "Refilled from LPG collection".' })));

  const kind = (m) => m.direction === 'WITHDRAWAL' ? (m.is_cash_movement ? (m.txn_id ? 'Cylinder bought' : 'Moved out') : 'Released (no money moved)')
    : m.direction === 'TRANSFER_OUT' ? 'Moved out' : m.direction === 'INTEREST' ? 'Interest'
    : (m.is_cash_movement ? 'Refilled' : 'Set aside (no money moved)');
  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Every entry' })),
    table([
      { label:'Date', primary:true, fmt: m => fdate(m.movement_date) },
      { label:'What', fmt: m => kind(m) },
      { label:'Details', fmt: m => m.purpose || m.notes || '—' },
      { label:'Amount', cls:'num', fmt: m => el('span', { class: signed(m) < 0 ? 'bad-text' : '', text: (signed(m) < 0 ? '− ' : '+ ') + money(m.amount, { bare:true }) }) }
    ], [...moves].reverse(), { onRow: m => m.txn_id && can('finance','view') ? (location.hash = '#/finance/' + m.txn_id) : null,
      empty:'No entries yet.' }),
    el('p', { class:'hint', text:'Each cylinder bought is an expense in the books under "LPG fund", and each refill is income, so both appear in the monthly report. Tap an entry to see it in the ledger and attach the cylinder bill.' })));
  return page;
}

/* No LPG fund yet: one small form makes it. */
async function setupCard(){
  const card = el('section', { class:'card' },
    el('h2', { text:'Set up the LPG fund' }),
    el('p', { class:'muted', text:'Enter what the fund holds today. From then on, record each cylinder bought and each refill from the meter-bill collection here, and the balance keeps itself.' }));
  if (!can('reserve','add')){ card.append(emptyState('Ask an administrator to set up the LPG fund.')); return card; }
  const accounts = (await ref('accounts')).filter(a => a.kind !== 'FD');
  const openI = el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal', placeholder:'e.g. 25000' });
  const dateI = el('input', { type:'date', value: todayISO() });
  const acctI = select(accounts.map(a => ({ value:a.id, label:a.name })), { placeholder:'Kept with the building’s cash (no separate account)' });
  const btn = el('button', { class:'btn primary', type:'button', text:'Create the LPG fund' });
  btn.onclick = async () => {
    const amt = openI.value === '' ? 0 : Number(openI.value);
    if (!(amt >= 0)) return err('The amount cannot be negative.');
    btn.disabled = true;
    try {
      await insert('funds', { code:'LPG', name:'LPG fund', fund_type:'PROJECT', purpose:'Buys LPG cylinders; refilled from the flats’ LPG meter bills.',
        opening_balance: amt, opening_date: dateI.value || todayISO(), account_id: acctI.value || null });
      invalidate('balances'); ok('LPG fund created.'); refresh();
    } catch (e){ btn.disabled = false; err(e.message); }
  };
  card.append(el('div', { class:'grid g-form' }, field('Amount in the fund today', openI), field('As of', dateI)),
    field('Where the money is kept', acctI, { hint:'If the LPG money is kept apart (a separate cash box or account), choose it. Otherwise leave it with the building’s cash.' }),
    el('div', { class:'btn-row' }, btn));
  return card;
}
