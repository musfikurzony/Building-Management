/* Dashboard — two of them, chosen by what the person is allowed to see.
   A caretaker on a phone at 11pm and a finance manager on a laptop are
   doing completely different jobs. */

import { el, html, money0, money, num, fdate, stat, emptyState, monthName } from '../core/ui.js';
import { q, count } from '../core/db.js';
import { can, state } from '../core/store.js';

const now = new Date();
const Y = now.getFullYear(), M = now.getMonth() + 1;

export async function render(){
  const financial = can('finance','view') || can('bank','view') || can('charges','view');
  return financial ? adminDashboard() : caretakerDashboard();
}

/* ------------------------------------------------------------------ */
async function adminDashboard(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: 'Dashboard' }),
    el('p',  { class:'sub', text: `${monthName(Y, M)} · ${state.profile?.full_name || ''}` })));

  const [alerts, balances, ie, collection, dues, funds, position] = await Promise.all([
    q('v_dashboard_alerts').catch(() => []),
    can('bank','view') ? q('v_account_balances', b => b.eq('is_active', true)).catch(() => []) : [],
    can('finance','view') ? q('v_income_expense_monthly', b => b.eq('period_year', Y)).catch(() => []) : [],
    can('charges','view') ? q('v_monthly_collection', b => b.eq('period_year', Y).eq('period_month', M)).catch(() => []) : [],
    can('charges','view') ? q('v_flat_dues').catch(() => []) : [],
    can('reserve','view') ? q('v_fund_balances', b => b.eq('is_active', true)).catch(() => []) : [],
    can('finance','view') ? q('v_financial_position').catch(() => []) : []
  ]);

  /* ---- alerts ---- */
  if (alerts.length){
    const box = el('section', { class:'card' });
    box.append(el('div', { class:'card-head' }, el('h2', { text:'Needs attention' })));
    for (const a of alerts.sort(sevOrder)){
      box.append(el('a', { class:'alert ' + a.severity.toLowerCase(), href: a.link },
        el('div', { class:'a-body' },
          el('div', { class:'a-title', text: a.title }),
          el('div', { class:'a-meta', text:
            `${num(a.item_count)} item${a.item_count === 1 ? '' : 's'}` +
            (a.amount ? ` · ${money0(a.amount)}` : '') }))
      ));
    }
    page.append(box);
  }

  /* ---- money now ---- */
  if (balances.length){
    const sum = (kinds) => balances.filter(b => kinds.includes(b.kind))
      .reduce((t, b) => t + Number(b.current_balance || 0), 0);
    const bank = sum(['BANK']), cash = sum(['CASH','MOBILE_WALLET']), fd = sum(['FD']);
    page.append(section('Money now', el('div', { class:'grid g-stats' },
      stat('Bank', money0(bank)),
      stat('Cash in hand', money0(cash)),
      stat('Fixed deposits', money0(fd)),
      stat('Total held', money0(bank + cash + fd), 'bank + cash + FD'))));
  }

  /* ---- this month ---- */
  if (ie.length || can('finance','view')){
    const thisMonth = ie.find(r => r.period_month === M) || { income:0, expense:0, net:0 };
    const ytdIncome  = ie.reduce((t,r) => t + Number(r.income  || 0), 0);
    const ytdExpense = ie.reduce((t,r) => t + Number(r.expense || 0), 0);
    const net = Number(thisMonth.net || 0);
    page.append(section(`This month — ${monthName(Y, M)}`, el('div', {},
      el('div', { class:'grid g-stats' },
        stat('Income',  money0(thisMonth.income  || 0)),
        stat('Expense', money0(thisMonth.expense || 0)),
        stat(net >= 0 ? 'Surplus' : 'Deficit', money0(Math.abs(net)), null, net >= 0 ? 'good' : 'bad'),
        stat('Year to date', money0(ytdIncome - ytdExpense),
             `${money0(ytdIncome)} in · ${money0(ytdExpense)} out`)),
      ie.length > 1 ? monthlyBars(ie) : null)));
  }

  /* ---- service charge ---- */
  if (can('charges','view')){
    const c = collection[0];
    const outstanding = dues.reduce((t,d) => t + Number(d.outstanding || 0), 0);
    const pct = c ? Number(c.collection_pct) : 0;
    const bar = el('div', { class: 'bar' + (pct < 60 ? ' over' : pct < 85 ? ' warn' : '') },
                   el('span', { style:`width:${Math.min(100, pct)}%` }));

    const body = el('div', {},
      el('div', { class:'grid g-stats' },
        stat('Flats billed', c ? num(c.charge_count) : '0'),
        stat('Paid',    c ? num(c.flats_paid)    : '0', null, 'good'),
        stat('Partial', c ? num(c.flats_partial) : '0'),
        stat('Unpaid',  c ? num(c.flats_unpaid)  : '0', null, 'bad')),
      el('div', { style:'margin-top:.9rem' },
        el('div', { class:'small muted', text: c
          ? `Collected ${money(c.collected)} of ${money(c.charged)} — ${pct}%`
          : `No charges generated for ${monthName(Y, M)} yet.` }),
        c ? bar : null),
      el('p', { class:'small', style:'margin-top:.8rem' },
        el('b', { text: money0(outstanding) }),
        ' outstanding across all months.'));

    const top = dues.filter(d => Number(d.outstanding) > 0)
                    .sort((a,b) => Number(b.outstanding) - Number(a.outstanding)).slice(0,5);
    if (top.length){
      body.append(el('h3', { style:'margin-top:1rem', text:'Largest outstanding' }));
      const list = el('div', { class:'tablewrap' }, el('table', { class:'stack' },
        el('thead', {}, el('tr', {}, el('th', {}, 'Flat'), el('th', {}, 'Billed to'), el('th', { class:'num' }, 'Outstanding'))),
        el('tbody', {}, top.map(d => el('tr', {},
          el('td', { class:'primary', 'data-l':'Flat', text: d.flat_number }),
          el('td', { 'data-l':'Billed to', text: d.billed_to || '—' }),
          el('td', { class:'num', 'data-l':'Outstanding', text: money(d.outstanding) }))))));
      body.append(list);
    }
    body.append(el('a', { class:'btn small', href:'#/charges', text:'Open service charge' }));
    page.append(section('Service charge', body));
  }

  /* ---- reserve ----
     Two figures, never merged: what is earmarked, and what is actually
     behind it. A reserve that is only a resolution should look like one. */
  if (funds.length){
    const earmarked = funds.reduce((t,f) => t + Number(f.current_balance || 0), 0);
    const funded    = funds.reduce((t,f) => t + Number(f.funded_amount   || 0), 0);
    const short     = Math.max(earmarked - funded, 0);
    const body = el('div', {},
      el('div', { class:'grid g-stats' },
        stat('Earmarked', money0(earmarked), `${funds.length} fund${funds.length === 1 ? '' : 's'}`),
        stat('Actually there', money0(funded), 'in an account or a deposit',
             short > 0 ? 'bad' : 'good'),
        stat('Not yet funded', money0(short),
             short > 0 ? 'a promise, not a balance' : 'fully backed',
             short > 0 ? 'bad' : 'good')));
    for (const f of funds.filter(f => f.target_amount)){
      const p = Math.max(0, Math.min(100, Number(f.progress_pct || 0)));
      body.append(el('div', { style:'margin-top:.7rem' },
        el('div', { class:'small muted',
          text: `${f.name} — ${money0(f.current_balance)} of ${money0(f.target_amount)} (${num(p,0)}%)` }),
        el('div', { class:'bar' + (p < 40 ? ' over' : p < 80 ? ' warn' : '') },
          el('span', { style:`width:${p}%` }))));
    }
    body.append(el('a', { class:'btn small', style:'margin-top:.8rem', href:'#/reserve', text:'Open reserve & funds' }));
    page.append(section('Reserve', body));
  }

  /* ---- the whole position, in one place ---- */
  const pos = position[0];
  if (pos)
    page.append(section('Total financial position', el('div', {},
      el('div', { class:'grid g-stats' },
        stat('Cash in hand', money0(pos.cash_in_hand)),
        stat('In the bank', money0(pos.bank_balance)),
        stat('Fixed deposits', money0(pos.fixed_deposits)),
        stat('Total held', money0(pos.total_held), 'cash + bank + deposits')),
      el('div', { class:'grid g-stats', style:'margin-top:.6rem' },
        stat('Owed to us', money0(pos.service_charge_receivable), 'unpaid service charge'),
        stat('Held in advance', money0(pos.advances_held), 'paid ahead by flats'),
        stat('Committed, not paid', money0(pos.committed_expense), 'approved or awaiting approval'),
        stat('Salaries due', money0(pos.salary_due), 'generated but unpaid')),
      el('p', { class:'hint', style:'margin-top:.7rem',
        text:'Held is money that exists. Owed and committed are not money yet — they are what is coming in and going out.' }))));

  /* ---- operations ---- */
  const opsCards = [];
  if (can('maintenance','view')){
    const issues = await q('v_issues', b => b.in('status', ['OPEN','ASSIGNED','IN_PROGRESS','COMPLETED']))
      .catch(() => []);
    opsCards.push(stat('Open jobs', num(issues.filter(i => i.status !== 'COMPLETED').length),
      issues.filter(i => i.is_overdue).length ? issues.filter(i => i.is_overdue).length + ' past target' : null,
      issues.some(i => i.is_overdue) ? 'bad' : ''));
    opsCards.push(stat('Waiting to be checked', num(issues.filter(i => i.status === 'COMPLETED').length)));
  }
  if (can('fire','view') || can('generator','view') || can('lift','view')){
    const assets = await q('v_assets', b => b.neq('status','RETIRED')).catch(() => []);
    const fe = assets.filter(a => a.asset_type === 'FIRE_EXTINGUISHER');
    opsCards.push(stat('Service overdue', num(assets.filter(a => a.service_status === 'OVERDUE').length),
      null, assets.some(a => a.service_status === 'OVERDUE') ? 'bad' : 'good'));
    if (fe.length)
      opsCards.push(stat('Extinguishers to inspect',
        num(fe.filter(a => ['OVERDUE','DUE_SOON','UNKNOWN'].includes(a.inspection_status)).length),
        `${fe.length} on the register`,
        fe.some(a => a.inspection_status === 'OVERDUE') ? 'bad' : ''));
  }
  if (can('staff','view')){
    const staff = await q('v_staff', b => b.eq('status','ACTIVE')).catch(() => []);
    opsCards.push(stat('Staff in today', num(staff.filter(s => s.today_status === 'PRESENT').length),
      `${staff.length} on the books`));
  }
  if (opsCards.length)
    page.append(section('Operations', el('div', { class:'grid g-stats' }, ...opsCards)));

  return page;
}

function sevOrder(a, b){
  const w = { HIGH:0, NORMAL:1, LOW:2 };
  return (w[a.severity] ?? 3) - (w[b.severity] ?? 3);
}

function section(title, body){
  return el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text: title })), body);
}

/** A tiny income/expense bar chart. No library, no external request. */
function monthlyBars(rows){
  const byMonth = new Map(rows.map(r => [r.period_month, r]));
  const max = Math.max(1, ...rows.flatMap(r => [Number(r.income||0), Number(r.expense||0)]));
  const wrap = el('div', { style:'display:flex;gap:.35rem;align-items:flex-end;height:88px;margin-top:1rem' });
  for (let m = 1; m <= 12; m++){
    const r = byMonth.get(m) || { income:0, expense:0 };
    const inc = Number(r.income||0), exp = Number(r.expense||0);
    const col = el('div', { style:'flex:1;display:flex;flex-direction:column;align-items:center;gap:2px',
      title: `${monthName(rows[0]?.period_year || Y, m)} — in ${money0(inc)}, out ${money0(exp)}` },
      el('div', { style:'display:flex;gap:2px;align-items:flex-end;height:70px;width:100%;justify-content:center' },
        el('span', { style:`width:44%;height:${Math.round(inc/max*70)}px;min-height:2px;background:var(--accent);border-radius:2px 2px 0 0` }),
        el('span', { style:`width:44%;height:${Math.round(exp/max*70)}px;min-height:2px;background:var(--red);border-radius:2px 2px 0 0` })),
      el('span', { class:'small muted', style:'font-size:.62rem', text: monthName(Y, m).slice(0,1) + (m===1?'':'') }));
    wrap.append(col);
  }
  return el('div', {}, wrap,
    el('div', { class:'small muted center', style:'margin-top:.3rem' },
      el('span', { style:'color:var(--accent)', text:'▮ income' }), ' ',
      el('span', { style:'color:var(--red)',    text:'▮ expense' })));
}

/* ------------------------------------------------------------------
   Caretaker view: no money cards at all. Six big targets, each one a
   job that has to be finishable one-handed in under a minute.
   ------------------------------------------------------------------ */
async function caretakerDashboard(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: `Hello, ${(state.profile?.full_name || '').split(' ')[0] || 'there'}` }),
    el('p',  { class:'sub', text: fdate(new Date().toISOString()) })));

  const actions = [];
  if (can('generator','add'))   actions.push(['#/generator','⚡','Log a power cut','Start it now, stop it when power returns']);
  if (can('maintenance','add')) actions.push(['#/maintenance/new','✦','Report a problem','Photo, where, how urgent']);
  if (can('work','add'))        actions.push(['#/work/new','✓','Today’s round','Tick the checklist']);
  if (can('staff','add'))       actions.push(['#/staff/attendance','☺','Staff attendance','One tap per person']);
  if (can('finance','add'))     actions.push(['#/finance/new','＋','Submit an expense','Photo of the bill, amount, done']);
  if (can('fire','add'))        actions.push(['#/fire','△','Fire extinguishers','Which are due for a check']);
  if (can('finance','add'))     actions.push(['#/finance/mine','☰','My submissions','What was approved, what came back']);
  if (can('maintenance','view'))actions.push(['#/maintenance','▤','Open jobs','What is still outstanding']);

  const grid = el('div', { class:'grid g-2' });
  for (const [href, ico, label, sub] of actions){
    grid.append(el('a', { class:'btn btn-big', href },
      el('span', { class:'ico', text: ico }),
      el('span', { text: label }),
      el('span', { class:'sub', text: sub })));
  }
  page.append(grid);

  // A short "what needs doing" strip, from the same alert view the admin
  // dashboard uses — filtered to the things a caretaker can act on.
  const alerts = (await q('v_dashboard_alerts').catch(() => []))
    .filter(a => ['ISSUES_OVERDUE','ISSUES_OPEN','SERVICE_OVERDUE','INSPECTION_OVERDUE',
                  'GENERATOR_RUNNING','RETURNED_TO_ME'].includes(a.alert_type));
  if (alerts.length){
    const box = el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Needs doing' })));
    for (const a of alerts){
      box.append(el('a', { class:'alert ' + a.severity.toLowerCase(), href: a.link },
        el('div', { class:'a-body' },
          el('div', { class:'a-title', text: a.title }),
          el('div', { class:'a-meta', text: `${num(a.item_count)} item${a.item_count === 1 ? '' : 's'}` }))));
    }
    page.append(box);
  }

  const mine = await q('v_transactions', b => b.eq('created_by', state.user.id)
    .order('created_at', { ascending:false }).limit(5)).catch(() => []);
  if (mine.length){
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Your recent entries' })),
      el('div', { class:'tablewrap' }, el('table', { class:'stack' },
        el('thead', {}, el('tr', {}, el('th',{},'Date'), el('th',{},'What'), el('th',{class:'num'},'Amount'), el('th',{},'Status'))),
        el('tbody', {}, mine.map(r => el('tr', {},
          el('td', { 'data-l':'Date', text: fdate(r.txn_date) }),
          el('td', { class:'primary', 'data-l':'What', text: r.description }),
          el('td', { class:'num', 'data-l':'Amount', text: money(r.amount) }),
          el('td', { 'data-l':'Status' }, el('span', { class:'badge b-' + String(r.status).toLowerCase(),
            text: String(r.status).replace(/_/g,' ') })))))))));
  } else {
    page.append(emptyState('Nothing submitted yet. Use “Submit an expense” when you spend building money.'));
  }
  return page;
}
