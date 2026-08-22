/* Reserve funds and fixed deposits.

   The one idea this screen exists to communicate: a reserve is a LABEL on
   money you already have. Tk 800,000 "set aside" is not Tk 800,000 unless
   Tk 800,000 is sitting in an account or a deposit. So every fund shows
   two figures — what is earmarked, and what is actually behind it — and
   says plainly when they disagree. */

import { el, field, select, money, money0, num, fdate, table, stat, ok, err,
         modal, confirmBox, emptyState, badge, todayISO, downloadCSV } from '../core/ui.js';
import { q, one, insert, update, rpc, logEvent } from '../core/db.js';
import { refresh } from '../core/router.js';
import { can, ref, invalidate } from '../core/store.js';

export async function render({ params }){
  if (params[0] === 'deposits') return deposits();
  if (params[0]) return fundDetail(params[0]);
  return list();
}

const opts = (arr, valueKey, labelFn) =>
  arr.map(o => ({ value: o[valueKey], label: labelFn(o) }));

/* ------------------------------------------------------------------ */
/* FUNDS                                                               */
/* ------------------------------------------------------------------ */
async function list(){
  const [funds, fds] = await Promise.all([
    q('v_fund_balances', b => b.order('code')),
    q('v_fixed_deposits', b => b.eq('status','ACTIVE')).catch(() => [])
  ]);

  const live = funds.filter(f => f.is_active);
  const earmarked = live.reduce((t,f) => t + Number(f.current_balance || 0), 0);
  const funded    = live.reduce((t,f) => t + Number(f.funded_amount   || 0), 0);
  const inFds     = fds.reduce((t,d) => t + Number(d.principal || 0), 0);
  const short     = Math.max(earmarked - funded, 0);

  const cols = [
    { label:'Fund', primary:true, key:'name' },
    { label:'Purpose', fmt: f => f.purpose || '—', csv: f => f.purpose },
    { label:'Earmarked', cls:'num', fmt: f => money(f.current_balance, { bare:true }), csv: f => f.current_balance },
    { label:'Actually there', cls:'num', fmt: f => money(f.funded_amount, { bare:true }), csv: f => f.funded_amount },
    { label:'Backing', fmt: f => backingBadge(f), csv: f => f.is_funded ? 'FUNDED' : 'SHORT' },
    { label:'Target', cls:'num', fmt: f => f.target_amount ? money(f.target_amount, { bare:true }) : '—', csv: f => f.target_amount },
    { label:'Progress', fmt: f => f.target_amount ? progressBar(f.progress_pct) : '—', csv: f => f.progress_pct }
  ];

  const bar = el('div', { class:'toolbar' },
    el('a', { class:'btn', href:'#/reserve/deposits' }, 'Fixed deposits'));
  if (can('reserve','add'))
    bar.append(el('button', { class:'btn primary', onclick: () => fundDialog(null) }, '＋ New fund'));
  bar.append(el('span', { class:'spacer' }));
  if (can('reserve','export'))
    bar.append(el('button', { class:'btn small', onclick: () => {
      downloadCSV('reserve-funds.csv', cols, funds); logEvent('EXPORT', { module:'reserve' }); }}, 'Export CSV'));

  const page = el('div', {},
    el('div', { class:'page-head' }, el('h1', {}, 'Reserve & funds'),
      el('p', { class:'sub' }, 'A fund is a label on money you already hold. The two figures below are deliberately kept apart.')),
    el('div', { class:'grid g-stats' },
      stat('Earmarked', money0(earmarked), 'what the committee has set aside'),
      stat('Actually there', money0(funded), 'held in an account or a deposit',
           funded >= earmarked ? 'good' : 'bad'),
      stat('In fixed deposits', money0(inFds), `${fds.length} active`),
      stat('Not yet funded', money0(short),
           short > 0 ? 'a promise, not a balance' : 'fully backed',
           short > 0 ? 'bad' : 'good')));

  if (short > 0)
    page.append(el('div', { class:'alert high' },
      el('div', { class:'a-body' },
        el('div', { class:'a-title' }, 'Part of the reserve is not real money yet'),
        el('div', { class:'a-meta' },
          `${money(short)} has been set aside on paper but is not sitting in any account or deposit. Either move the money, or lower the earmark so the figure means something.`))));

  page.append(bar);
  page.append(table(cols, funds, { onRow: f => location.hash = '#/reserve/' + f.fund_id,
    empty:'No funds yet. A general reserve and a capital replacement fund are the usual two.' }));
  return page;
}

function backingBadge(f){
  if (Number(f.current_balance) === 0) return badge('EMPTY');
  return f.is_funded ? badge('OK')
    : el('span', { class:'badge b-overdue' }, 'short ' + money0(f.unfunded_amount));
}

function progressBar(pct){
  const p = Math.max(0, Math.min(100, Number(pct || 0)));
  return el('div', {},
    el('div', { class:'bar' + (p < 40 ? ' over' : p < 80 ? ' warn' : '') },
      el('span', { style:`width:${p}%` })),
    el('span', { class:'small muted' }, num(p,1) + '%'));
}

async function fundDetail(id){
  const fund = await one('v_fund_balances', b => b.eq('fund_id', id));
  if (!fund) return emptyState('That fund does not exist, or you cannot see it.');

  const [raw, moves, fds] = await Promise.all([
    one('funds', b => b.eq('id', id)),
    q('fund_movements', b => b.eq('fund_id', id).order('movement_date', { ascending:false })),
    q('v_fixed_deposits', b => b.eq('fund_id', id)).catch(() => [])
  ]);

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', {}, fund.name),
    el('p', { class:'sub' }, fund.purpose || fund.fund_type.toLowerCase())));

  page.append(el('div', { class:'grid g-stats' },
    stat('Earmarked', money(fund.current_balance)),
    stat('Actually there', money(fund.funded_amount),
         fund.is_funded ? 'fully backed' : money0(fund.unfunded_amount) + ' short',
         fund.is_funded ? 'good' : 'bad'),
    stat('Held in deposits', money(fund.held_in_deposits)),
    fund.target_amount
      ? stat('Target', money(fund.target_amount), money0(fund.remaining_required) + ' to go')
      : stat('Target', 'none set', 'add one to track progress')));

  if (fund.target_amount) page.append(el('div', { class:'card' }, progressBar(fund.progress_pct)));

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/reserve' }, '← Funds'));
  if (can('reserve','add')){
    bar.append(el('button', { class:'btn primary', onclick: () => movementDialog(fund, 'CONTRIBUTION') }, 'Put money in'));
    bar.append(el('button', { class:'btn', onclick: () => movementDialog(fund, 'WITHDRAWAL') }, 'Take money out'));
  }
  if (can('reserve','edit'))
    bar.append(el('button', { class:'btn', onclick: () => fundDialog(raw) }, 'Edit fund'));
  page.append(bar);

  page.append(el('h2', {}, 'Movements'));
  page.append(table([
    { label:'Date', primary:true, fmt: m => fdate(m.movement_date), csv: m => m.movement_date },
    { label:'Direction', fmt: m => m.direction.replace(/_/g,' ').toLowerCase(), csv: m => m.direction },
    { label:'Amount', cls:'num', fmt: m => money(m.amount, { bare:true }), csv: m => m.amount },
    { label:'Money moved?', fmt: m => m.is_cash_movement
        ? badge('OK') : el('span', { class:'badge b-draft' }, 'earmark only'),
      csv: m => m.is_cash_movement ? 'cash' : 'earmark' },
    { label:'Purpose', fmt: m => m.purpose || m.notes || '—', csv: m => m.purpose }
  ], moves, { empty:'Nothing has been put into this fund yet.' }));

  if (fds.length){
    page.append(el('h2', {}, 'Deposits held for this fund'));
    page.append(table(depositCols(), fds, { onRow: d => fdDetail(d) }));
  }
  return page;
}

async function fundDialog(fund){
  const f = fund || {};
  const codeI = el('input', { type:'text', required:true, maxlength:'20', value: f.code || '' });
  const nameI = el('input', { type:'text', required:true, value: f.name || '' });
  const typeI = select([
      { value:'RESERVE',   label:'General reserve' },
      { value:'SINKING',   label:'Sinking / replacement fund' },
      { value:'EMERGENCY', label:'Emergency fund' },
      { value:'PROJECT',   label:'Specific project' }
    ], { value: f.fund_type || 'RESERVE' });
  const purpI = el('input', { type:'text', value: f.purpose || '', maxlength:'200' });
  const targI = el('input', { type:'number', step:'0.01', min:'0', value: f.target_amount ?? '' });
  const tdatI = el('input', { type:'date', value: f.target_date || '' });
  const accounts = await ref('accounts');   // entry_accounts() already excludes FD and inactive
  const acctI = select(opts(accounts, 'id', a => a.name),
                       { value: f.account_id || '', placeholder:'None — it sits in the general account' });
  const noteI = el('textarea', { rows:'2', value: f.notes || '' });
  if (fund) codeI.disabled = true;

  const res = await modal({
    title: fund ? 'Edit fund' : 'New fund',
    body: el('div', {},
      field('Short code', codeI, { required:true, hint:'Used in reports. Cannot be changed later.' }),
      field('Name', nameI, { required:true }),
      field('Type', typeI),
      field('Purpose', purpI, { hint:'What this money is for, in plain words.' }),
      field('Target amount', targI, { hint:'Optional. Leave blank until the committee agrees one.' }),
      field('Target date', tdatI),
      field('Held in account', acctI, { hint:'Give the fund its own account and its backing becomes unambiguous.' }),
      field('Notes', noteI)),
    actions: [{ label: fund ? 'Save' : 'Create fund', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;
  if (!codeI.value.trim() || !nameI.value.trim()) return err('A code and a name are required.');

  const row = {
    name: nameI.value.trim(), fund_type: typeI.value,
    purpose: purpI.value.trim() || null,
    target_amount: targI.value === '' ? null : Number(targI.value),
    target_date: tdatI.value || null, account_id: acctI.value || null,
    notes: noteI.value.trim() || null
  };
  try {
    if (fund) await update('funds', fund.id, row);
    else await insert('funds', { ...row, code: codeI.value.trim().toUpperCase() });
    ok(fund ? 'Fund updated.' : 'Fund created.');
    refresh();
  } catch (e){ err(e.message); }
}

async function movementDialog(fund, direction){
  const isOut = direction === 'WITHDRAWAL';
  const dateI = el('input', { type:'date', value: todayISO(), required:true });
  const amtI  = el('input', { type:'number', step:'0.01', min:'0.01', required:true, inputmode:'decimal' });
  const purpI = el('input', { type:'text', maxlength:'200' });
  const noteI = el('textarea', { rows:'2' });

  const accounts = await ref('accounts');   // entry_accounts() already excludes FD and inactive
  const fromI = select(opts(accounts, 'id', a => a.name),
                       { value: isOut ? (fund.account_id || '') : '', placeholder:'Choose an account' });
  const toI   = select(opts(accounts, 'id', a => a.name),
                       { value: isOut ? '' : (fund.account_id || ''), placeholder:'Choose an account' });

  // The distinction that makes this module honest, put to the user as a
  // question in their own words rather than as a flag called
  // "is_cash_movement".
  const cashI = el('input', { type:'checkbox' });
  cashI.checked = true;
  const accountsBox = el('div', {},
    field(isOut ? 'Out of account' : 'From account', fromI),
    field('Into account', toI));
  const sync = () => { accountsBox.style.display = cashI.checked ? '' : 'none'; };
  cashI.onchange = sync;
  sync();

  const res = await modal({
    title: isOut ? `Take money out of ${fund.name}` : `Put money into ${fund.name}`,
    body: el('div', {},
      field('Date', dateI, { required:true }),
      field('Amount', amtI, { required:true }),
      field('Did money actually move between accounts?',
        el('label', { class:'check' }, cashI,
          el('span', {}, 'Yes — transfer the money as well as recording the decision')),
        { hint: isOut
            ? 'Leave this ticked when the money really leaves the reserve account. Untick it if the committee is only releasing an earmark.'
            : 'Leave this ticked when the money really moves. Untick it if the committee is only minuting a decision — the fund will then show as not funded, which is the truth.' }),
      accountsBox,
      field('Purpose', purpI, { hint:'Board resolution number, or what this is for.' }),
      field('Notes', noteI)),
    actions: [{ label:'Record', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;

  const amt = Number(amtI.value);
  if (!(amt > 0)) return err('Enter an amount greater than zero.');
  if (cashI.checked && (!fromI.value || !toI.value)) return err('Say which account the money comes from and goes to.');
  if (cashI.checked && fromI.value === toI.value) return err('A transfer needs two different accounts.');

  try {
    await rpc('record_fund_movement', {
      p_fund: fund.fund_id, p_date: dateI.value, p_direction: direction,
      p_amount: amt, p_cash_backed: cashI.checked,
      p_from_account: cashI.checked ? fromI.value : null,
      p_to_account:   cashI.checked ? toI.value   : null,
      p_purpose: purpI.value.trim() || null, p_notes: noteI.value.trim() || null
    });
    ok(cashI.checked ? 'Recorded, and the money was transferred.' : 'Earmark recorded. No money moved.');
    invalidate('accounts'); refresh();
  } catch (e){ err(e.message); }
}

/* ------------------------------------------------------------------ */
/* FIXED DEPOSITS                                                      */
/* ------------------------------------------------------------------ */
const depositCols = () => [
  { label:'Deposit', primary:true, key:'fd_no' },
  { label:'Bank', fmt: d => d.bank_name + (d.branch ? ' · ' + d.branch : ''), csv: d => d.bank_name },
  { label:'Principal', cls:'num', fmt: d => money(d.principal, { bare:true }), csv: d => d.principal },
  { label:'Rate', cls:'num', fmt: d => d.interest_rate ? num(d.interest_rate, 2) + '%' : '—', csv: d => d.interest_rate },
  { label:'Matures', fmt: d => d.maturity_date ? fdate(d.maturity_date) : '—', csv: d => d.maturity_date },
  { label:'Status', fmt: d => maturityBadge(d), csv: d => d.maturity_status },
  { label:'Interest so far', cls:'num', fmt: d => money(d.interest_received, { bare:true }), csv: d => d.interest_received },
  { label:'Held for', fmt: d => d.fund_name || d.purpose || '—', csv: d => d.fund_name }
];

function maturityBadge(d){
  const map = {
    ACTIVE:            ['b-active',  'running'],
    MATURING_SOON:     ['b-pending', 'maturing soon'],
    MATURED_UNCLAIMED: ['b-overdue', 'matured — not recorded'],
    MATURED:           ['b-closed',  'matured'],
    ENCASHED:          ['b-closed',  'encashed'],
    RENEWED:           ['b-active',  'renewed']
  };
  const [cls, label] = map[d.maturity_status] || ['b-draft', String(d.maturity_status || '').toLowerCase()];
  return el('span', { class:'badge ' + cls }, label);
}

async function deposits(){
  const rows = await q('v_fixed_deposits', b => b.order('deposit_date', { ascending:false }));
  const active = rows.filter(d => d.status === 'ACTIVE');
  const principal = active.reduce((t,d) => t + Number(d.principal || 0), 0);
  const expected  = active.reduce((t,d) => t + Number(d.expected_interest || 0), 0);
  const received  = rows.reduce((t,d) => t + Number(d.interest_received || 0), 0);
  const due = active.filter(d => ['MATURING_SOON','MATURED_UNCLAIMED'].includes(d.maturity_status));

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/reserve' }, '← Funds'));
  if (can('reserve','add'))
    bar.append(el('button', { class:'btn primary', onclick: () => openFdDialog() }, '＋ Open a deposit'));
  bar.append(el('span', { class:'spacer' }));
  if (can('reserve','export'))
    bar.append(el('button', { class:'btn small', onclick: () => {
      downloadCSV('fixed-deposits.csv', depositCols(), rows); logEvent('EXPORT', { module:'reserve' }); }}, 'Export CSV'));

  const page = el('div', {},
    el('div', { class:'page-head' }, el('h1', {}, 'Fixed deposits'),
      el('p', { class:'sub' }, 'Long-term money. Opening a deposit moves it; it does not spend it.')),
    el('div', { class:'grid g-stats' },
      stat('Held in deposits', money0(principal), `${active.length} active`),
      stat('Interest expected', money0(expected), 'on current deposits'),
      stat('Interest received', money0(received), 'all time'),
      stat('Needing attention', String(due.length),
           due.length ? 'maturing or matured' : 'nothing due',
           due.length ? 'bad' : 'good')));

  for (const d of due)
    page.append(el('div', { class:'alert ' + (d.maturity_status === 'MATURED_UNCLAIMED' ? 'high' : 'normal') },
      el('div', { class:'a-body' },
        el('div', { class:'a-title' }, `Deposit ${d.fd_no} — ${d.maturity_status === 'MATURED_UNCLAIMED' ? 'has already matured' : 'matures ' + fdate(d.maturity_date)}`),
        el('div', { class:'a-meta' }, `${money(d.principal)} at ${d.bank_name}. Record what the bank paid so the books stay right.`))));

  page.append(bar);
  page.append(table(depositCols(), rows, { onRow: d => fdDetail(d),
    empty:'No fixed deposits yet.' }));
  return page;
}

async function fdDetail(d){
  const events = await q('fd_events', b => b.eq('fd_id', d.id).order('event_date')).catch(() => []);
  const body = el('div', {},
    el('dl', { class:'dl' },
      el('dt', {}, 'Bank'),        el('dd', {}, d.bank_name + (d.branch ? ' · ' + d.branch : '')),
      el('dt', {}, 'Principal'),   el('dd', {}, money(d.principal)),
      el('dt', {}, 'Deposited'),   el('dd', {}, fdate(d.deposit_date)),
      el('dt', {}, 'Tenure'),      el('dd', {}, d.tenure_months ? d.tenure_months + ' months' : '—'),
      el('dt', {}, 'Rate'),        el('dd', {}, d.interest_rate ? num(d.interest_rate,2) + '%' : '—'),
      el('dt', {}, 'Matures'),     el('dd', {}, d.maturity_date ? fdate(d.maturity_date) : '—'),
      el('dt', {}, 'Expected at maturity'), el('dd', {}, d.expected_maturity_amount ? money(d.expected_maturity_amount) : '—'),
      el('dt', {}, 'Interest received'),    el('dd', {}, money(d.interest_received)),
      el('dt', {}, 'Held for'),    el('dd', {}, d.fund_name || '—'),
      el('dt', {}, 'Status'),      el('dd', {}, maturityBadge(d))),
    el('h3', {}, 'History'),
    table([
      { label:'Date', primary:true, fmt: e => fdate(e.event_date) },
      { label:'Event', fmt: e => e.event_type.replace(/_/g,' ').toLowerCase() },
      { label:'Amount', cls:'num', fmt: e => e.amount ? money(e.amount, { bare:true }) : '—' }
    ], events, { empty:'No events recorded.' }));

  const actions = [];
  if (d.status === 'ACTIVE' && can('reserve','add'))
    actions.push({ label:'Record interest', value:'interest' });
  if (d.status === 'ACTIVE' && can('reserve','approve'))
    actions.push({ label:'Close / mature', kind:'primary', value:'mature' });

  const res = await modal({ title:'Deposit ' + d.fd_no, body, actions });
  if (res === 'interest') return interestDialog(d);
  if (res === 'mature')   return matureDialog(d);
}

async function openFdDialog(){
  const accounts = await ref('accounts');   // entry_accounts() already excludes FD and inactive
  const funds = await q('funds', b => b.eq('is_active', true).order('name')).catch(() => []);

  const noI    = el('input', { type:'text', required:true, maxlength:'40' });
  const bankI  = el('input', { type:'text', required:true, maxlength:'80' });
  const brI    = el('input', { type:'text', maxlength:'80' });
  const prinI  = el('input', { type:'number', step:'0.01', min:'0.01', required:true, inputmode:'decimal' });
  const dateI  = el('input', { type:'date', value: todayISO(), required:true });
  const srcI   = select(opts(accounts, 'id', a => `${a.name} (${a.kind.toLowerCase()})`), { placeholder:'Choose an account' });
  const tenI   = el('input', { type:'number', min:'1', step:'1', value:'12' });
  const rateI  = el('input', { type:'number', step:'0.001', min:'0' });
  const fundI  = select(opts(funds, 'id', f => f.name), { placeholder:'Not tied to a fund' });
  const purpI  = el('input', { type:'text', maxlength:'200' });

  // Show the expected maturity figure as they type, so a slip in the rate
  // is obvious before the certificate is filed rather than a year later.
  const preview = el('p', { class:'hint' }, '');
  const recalc = () => {
    const p = Number(prinI.value), r = Number(rateI.value), m = Number(tenI.value);
    preview.textContent = (p > 0 && r > 0 && m > 0)
      ? `At ${num(r,3)}% simple interest for ${m} months this matures at about ${money(p * (1 + (r/100) * (m/12)))}.`
      : '';
  };
  [prinI, rateI, tenI].forEach(i => i.oninput = recalc);

  const res = await modal({
    title:'Open a fixed deposit',
    body: el('div', {},
      field('Deposit / certificate number', noI, { required:true }),
      field('Bank', bankI, { required:true }),
      field('Branch', brI),
      field('Principal', prinI, { required:true }),
      field('Deposit date', dateI, { required:true }),
      field('Money comes from', srcI, { required:true, hint:'This account falls by the principal. Nothing is spent.' }),
      field('Tenure (months)', tenI),
      field('Interest rate (%)', rateI),
      preview,
      field('Held for fund', fundI),
      field('Purpose', purpI)),
    actions: [{ label:'Open deposit', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;
  if (!noI.value.trim() || !bankI.value.trim()) return err('A certificate number and a bank are required.');
  if (!(Number(prinI.value) > 0)) return err('Enter the principal.');
  if (!srcI.value) return err('Say which account the money comes from.');

  try {
    await rpc('open_fixed_deposit', {
      p_fd_no: noI.value.trim(), p_bank: bankI.value.trim(),
      p_principal: Number(prinI.value), p_date: dateI.value,
      p_source_account: srcI.value,
      p_tenure_months: tenI.value ? Number(tenI.value) : null,
      p_rate: rateI.value ? Number(rateI.value) : null,
      p_maturity: null, p_fund: fundI.value || null,
      p_purpose: purpI.value.trim() || null, p_branch: brI.value.trim() || null
    });
    ok('Deposit opened. The money moved out of the account, it was not spent.');
    invalidate('accounts'); refresh();
  } catch (e){ err(e.message); }
}

async function interestDialog(d){
  const dateI = el('input', { type:'date', value: todayISO(), required:true });
  const amtI  = el('input', { type:'number', step:'0.01', min:'0.01', required:true, inputmode:'decimal' });
  const res = await modal({
    title:'Interest credited on ' + d.fd_no,
    body: el('div', {},
      field('Date', dateI, { required:true }),
      field('Interest amount', amtI, { required:true,
        hint:'Recorded as income in the Reserve & Funds department, and added to the deposit.' })),
    actions: [{ label:'Record interest', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;
  if (!(Number(amtI.value) > 0)) return err('Enter the interest amount.');
  try {
    await rpc('record_fd_interest', { p_fd: d.id, p_date: dateI.value,
      p_amount: Number(amtI.value), p_to_account: null });
    ok('Interest recorded as income.');
    invalidate('accounts'); refresh();
  } catch (e){ err(e.message); }
}

async function matureDialog(d){
  const accounts = await ref('accounts');   // entry_accounts() already excludes FD and inactive
  const dateI = el('input', { type:'date', value: todayISO(), required:true });
  const amtI  = el('input', { type:'number', step:'0.01', min:'0.01', required:true,
                              inputmode:'decimal', value: d.expected_maturity_amount ?? '' });
  const toI   = select(opts(accounts, 'id', a => a.name),
                       { value: d.source_account_id || '', placeholder:'Choose an account' });
  const earlyI = el('input', { type:'checkbox' });
  earlyI.checked = !!(d.maturity_date && new Date(d.maturity_date) > new Date());

  const res = await modal({
    title:'Close deposit ' + d.fd_no,
    body: el('div', {},
      field('Date', dateI, { required:true }),
      field('Amount the bank actually paid', amtI, { required:true,
        hint:'Enter the bank’s figure, not the expected one. Anything above what the deposit already holds is booked as interest income; anything below is booked as a penalty.' }),
      field('Paid into', toI, { required:true }),
      field('Broken early?', el('label', { class:'check' }, earlyI,
        el('span', {}, 'Yes — encashed before the maturity date')))),
    actions: [{ label:'Continue', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;
  if (!(Number(amtI.value) > 0)) return err('Enter the amount the bank paid.');
  if (!toI.value) return err('Say which account the money went into.');

  const yes = await confirmBox('Close this deposit?',
    `${money(Number(amtI.value))} will be moved into the chosen account and the deposit closed. This cannot be undone from here — it would have to be reversed in the ledger.`,
    'Close deposit');
  if (!yes) return;

  try {
    await rpc('mature_fixed_deposit', { p_fd: d.id, p_date: dateI.value,
      p_actual_amount: Number(amtI.value), p_to_account: toI.value,
      p_premature: earlyI.checked });
    ok('Deposit closed and the money returned.');
    invalidate('accounts'); refresh();
  } catch (e){ err(e.message); }
}
