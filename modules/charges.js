/* Service charge — generation, payments, statements, collection reports.

   flat_charges is the receivable ledger (what is owed).
   transactions is the cash ledger (what arrived).
   record_payment writes both, exactly once, in one database call. */

import { el, html, field, select, money, money0, num, fdate, badge, table, emptyState,
         ok, err, modal, reasonBox, confirmBox, downloadCSV, todayISO, monthName, stat } from '../core/ui.js';
import { q, one, rpc, logEvent } from '../core/db.js';
import { can, ref, state, settings, invalidate } from '../core/store.js';
import { go, refresh } from '../core/router.js';

const now = new Date();

export async function render({ params }){
  const sub = params[0];
  if (sub === 'outstanding') return outstanding();
  if (sub === 'payments')    return paymentList();
  if (sub === 'adjustments') return adjustmentList();
  if (sub === 'flat')        return statement(params[1]);
  return monthsView();
}

/* ==================================================================
   MONTHS + THIS MONTH'S GRID
   ================================================================== */
async function monthsView(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' }, el('h1', { text:'Service charge' })));

  const actions = el('div', { class:'toolbar' });
  if (can('charges','add')){
    const gen = el('button', { class:'btn primary', text:'Generate a month' });
    gen.onclick = () => generateDialog();
    const pay = el('button', { class:'btn primary', text:'＋ Record payment' });
    pay.onclick = () => paymentDialog();
    actions.append(pay, gen);
  }
  actions.append(el('a', { class:'btn', href:'#/charges/outstanding', text:'Outstanding' }));
  actions.append(el('a', { class:'btn', href:'#/charges/payments',    text:'Payments' }));
  if (can('charges','waive')) actions.append(el('a', { class:'btn', href:'#/charges/adjustments', text:'Waivers' }));
  page.append(actions);

  const year = now.getFullYear();
  const rows = await q('v_monthly_collection', b => b.eq('period_year', year)
    .order('period_month', { ascending:false }));

  const totals = rows.reduce((t,r) => ({
    charged: t.charged + Number(r.charged||0),
    collected: t.collected + Number(r.collected||0),
    outstanding: t.outstanding + Number(r.outstanding||0)
  }), { charged:0, collected:0, outstanding:0 });

  page.append(el('div', { class:'grid g-stats' },
    stat(`Charged ${year}`,   money0(totals.charged)),
    stat('Collected',         money0(totals.collected), null, 'good'),
    stat('Outstanding',       money0(totals.outstanding), null, totals.outstanding > 0 ? 'bad' : ''),
    stat('Collection rate',   totals.charged > 0 ? Math.round(totals.collected / totals.charged * 100) + '%' : '—')));

  const cols = [
    { label:'Month', primary:true, fmt: r => monthName(r.period_year, r.period_month), csv: r => monthName(r.period_year, r.period_month) },
    { label:'Flats', cls:'num', fmt: r => num(r.charge_count), csv: r => r.charge_count },
    { label:'Charged', cls:'num', fmt: r => money(r.charged, { bare:true }), csv: r => r.charged },
    { label:'Collected', cls:'num', fmt: r => money(r.collected, { bare:true }), csv: r => r.collected },
    { label:'Outstanding', cls:'num', fmt: r => money(r.outstanding, { bare:true }), csv: r => r.outstanding },
    { label:'Paid / Part / Due', fmt: r => `${r.flats_paid} / ${r.flats_partial} / ${r.flats_unpaid}`,
      csv: r => `${r.flats_paid}/${r.flats_partial}/${r.flats_unpaid}` },
    { label:'%', cls:'num', csv: r => r.collection_pct, fmt: r => {
        const p = Number(r.collection_pct);
        return html`<span style="color:${p >= 85 ? 'var(--accent)' : p >= 60 ? 'var(--amber)' : 'var(--red)'}">${p}%</span>`;
      } }
  ];

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:`Monthly collection — ${year}` }),
      can('charges','export') ? el('button', { class:'btn small', text:'CSV',
        onclick: () => { downloadCSV(`collection-${year}.csv`, cols, rows); logEvent('EXPORT',{module:'charges'}); } }) : null),
    table(cols, rows, { empty:`Nothing generated for ${year} yet. Use “Generate a month”.` })));

  const latest = rows[0];
  if (latest) page.append(await monthGrid(latest.period_year, latest.period_month));
  return page;
}

async function monthGrid(y, m){
  const rows = await q('v_flat_charges', b => b.eq('period_year', y).eq('period_month', m)
    .order('flat_number'));
  const cols = [
    { label:'Flat', primary:true, key:'flat_number' },
    { label:'Charge', cls:'num', fmt: r => money(r.charge_amount, { bare:true }), csv: r => r.charge_amount },
    { label:'Waived', cls:'num', fmt: r => Number(r.waiver_amount) ? money(r.waiver_amount, { bare:true }) : '—', csv: r => r.waiver_amount },
    { label:'Payable', cls:'num', fmt: r => money(r.net_payable, { bare:true }), csv: r => r.net_payable },
    { label:'Paid', cls:'num', fmt: r => money(r.paid_amount, { bare:true }), csv: r => r.paid_amount },
    { label:'Due', cls:'num', fmt: r => money(r.due_amount, { bare:true }), csv: r => r.due_amount },
    { label:'Status', fmt: r => badge(r.status), csv: r => r.status }
  ];
  return el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:`${monthName(y,m)} — flat by flat` }),
      can('charges','export') ? el('button', { class:'btn small', text:'CSV',
        onclick: () => downloadCSV(`charges-${y}-${String(m).padStart(2,'0')}.csv`, cols, rows) }) : null),
    table(cols, rows, { onRow: r => go('#/charges/flat/' + r.flat_id) }));
}

/* ==================================================================
   GENERATE
   ================================================================== */
async function generateDialog(){
  const y = el('input', { type:'number', value: now.getFullYear(), min:'2000', max:'2200' });
  const m = select(Array.from({length:12}, (_,i) => ({ value:i+1, label: monthName(now.getFullYear(), i+1).split(' ')[0] })),
                   { value: now.getMonth() + 1 });
  const flats = await ref('flats');
  const active = flats.filter(f => f.status === 'ACTIVE');
  const s = settings();
  const preview = active.reduce((t,f) => t + Number(f.service_charge ?? s.default_service_charge ?? 0), 0);

  const body = el('div', {},
    el('p', { class:'muted small', text:
      `${active.length} active flat${active.length === 1 ? '' : 's'} will be billed, each at its own rate. Flats with no rate of their own use the building default of ${money(s.default_service_charge)}.` }),
    el('div', { class:'grid g-form' }, field('Year', y), field('Month', m)),
    el('p', {}, 'Expected total: ', el('b', { class:'num', text: money(preview) })),
    el('p', { class:'hint', text:'Running this twice is refused by the database, so nothing can be double-billed.' }));

  const res = await modal({ title:'Generate monthly charges', body, actions:[
    { label:'Cancel', value:null },
    { label:'Generate', kind:'primary', value:true }
  ]});
  if (!res) return;
  try {
    const run = await rpc('generate_monthly_charges', { p_year: Number(y.value), p_month: Number(m.value) });
    const row = Array.isArray(run) ? run[0] : run;
    ok(`Generated ${row?.flat_count ?? active.length} charges totalling ${money(row?.total_amount ?? preview)}.`);
    go('#/charges');
  } catch { /* the error toast already explains it */ }
}

/* ==================================================================
   RECORD A PAYMENT
   ================================================================== */
export async function paymentDialog(flatId){
  const [flats, accounts] = await Promise.all([ref('flats'), ref('accounts')]);
  const dues = await q('v_flat_dues').catch(() => []);
  const dueOf = (id) => dues.find(d => d.flat_id === id);

  const flatI = select(flats.filter(f => f.status === 'ACTIVE')
      .map(f => ({ value:f.id, label:f.flat_number })), { value: flatId, placeholder:'Choose the flat' });
  const amtI  = el('input', { type:'number', step:'0.01', min:'0.01', inputmode:'decimal', required:true });
  const dateI = el('input', { type:'date', value: todayISO(), required:true });
  const methI = select(['CASH','BKASH','NAGAD','BANK_TRANSFER','CHEQUE','ROCKET','CARD']
                  .map(x => ({ value:x, label:x.replace(/_/g,' ') })), { value:'CASH' });
  // Pre-selected, because the answer is nearly always the same one and
  // this dialog is used dozens of times a month. Recording 36 payments
  // should not mean choosing the same cash account 36 times. Settings ->
  // "Default cash account" decides it; with only one account on file,
  // that one. It is still a real choice — just one already made.
  const defaultAcct = settings().default_cash_account_id
                   || (accounts.length === 1 ? accounts[0].id : '');
  const acctI = select(accounts.map(a => ({ value:a.id, label:a.name })),
                       { value: defaultAcct, placeholder:'Choose an account' });
  const refI  = el('input', { type:'text', maxlength:'80', placeholder:'bKash trx id, cheque no' });
  const payerI = el('input', { type:'text', maxlength:'120', placeholder:'If not the owner' });

  const info = el('p', { class:'hint' });
  const syncInfo = () => {
    const d = dueOf(flatI.value);
    if (!d){ info.textContent = ''; return; }
    const out = Number(d.outstanding), adv = Number(d.advance);
    info.textContent = out > 0 ? `${d.flat_number} owes ${money(out)}.`
      : adv > 0 ? `${d.flat_number} is up to date and ${money(adv)} in advance.`
      : `${d.flat_number} is up to date.`;
    if (out > 0 && !amtI.value) amtI.value = out;
  };
  flatI.onchange = syncInfo;
  syncInfo();

  const body = el('div', {},
    field('Flat', flatI, { required:true }), info,
    el('div', { class:'grid g-form' },
      field('Amount received', amtI, { required:true }),
      field('Date', dateI, { required:true })),
    el('div', { class:'grid g-form' }, field('Method', methI), field('Into account', acctI, { required:true })),
    el('div', { class:'grid g-form' }, field('Reference', refI), field('Paid by', payerI)),
    el('p', { class:'hint', text:'The money is applied to the oldest unpaid month first. Anything left over is kept as advance and settles next month automatically.' }));

  const res = await modal({ title:'Record a payment', body, actions:[
    { label:'Cancel', value:null },
    { label:'Record payment', kind:'primary',
      validate: () => {
        if (!flatI.value){ err('Choose a flat.'); return false; }
        if (!(Number(amtI.value) > 0)){ err('Enter an amount greater than zero.'); return false; }
        if (!acctI.value){ err('Choose the account the money went into.'); return false; }
        return true;
      }, value:true }
  ]});
  if (!res) return null;

  try {
    const pay = await rpc('record_payment', {
      p_flat: flatI.value, p_amount: Number(amtI.value), p_date: dateI.value,
      p_method: methI.value, p_account: acctI.value,
      p_reference: refI.value.trim() || null, p_notes: null,
      p_payer_name: payerI.value.trim() || null
    });
    const row = Array.isArray(pay) ? pay[0] : pay;
    invalidate('balances');
    ok(`Receipt ${row?.receipt_no || ''} recorded.`);
    if (row) await receiptDialog(row.id);
    return row;
  } catch { return null; }
}

async function receiptDialog(paymentId){
  const p = await one('payments', b => b.eq('id', paymentId));
  if (!p) return;
  const flats = await ref('flats');
  const flat = flats.find(f => f.id === p.flat_id);
  const allocs = await q('payment_allocations', b => b.eq('payment_id', paymentId)).catch(() => []);
  const charges = await q('v_flat_charges', b => b.eq('flat_id', p.flat_id)).catch(() => []);
  const s = settings();

  const lines = allocs.map(a => {
    const c = charges.find(x => x.id === a.flat_charge_id);
    return el('tr', {},
      el('td', { text: c ? (c.charge_source === 'OPENING' ? 'Balance brought forward'
                : monthName(c.period_year, c.period_month)) : 'Applied' }),
      el('td', { class:'num', text: money(a.amount, { bare:true }) }));
  });
  const allocated = allocs.reduce((t,a) => t + Number(a.amount), 0);
  const advance = Number(p.amount) - allocated;

  const body = el('div', { id:'receiptBody' },
    el('div', { class:'center', style:'margin-bottom:.6rem' },
      el('h3', { style:'margin:0', text: s.building_name || 'Building' }),
      el('div', { class:'small muted', text: s.address || '' }),
      el('div', { class:'small', style:'margin-top:.3rem', text:'Service charge receipt' })),
    el('dl', { class:'dl' },
      el('dt', { text:'Receipt no' }), el('dd', { class:'mono', text: p.receipt_no }),
      el('dt', { text:'Date' }),       el('dd', { text: fdate(p.payment_date) }),
      el('dt', { text:'Flat' }),       el('dd', { text: flat?.flat_number || '' }),
      el('dt', { text:'Received' }),   el('dd', { class:'num', style:'font-weight:700', text: money(p.amount) }),
      el('dt', { text:'Method' }),     el('dd', { text: String(p.method).replace(/_/g,' ') }),
      p.reference_no ? el('dt', { text:'Reference' }) : null,
      p.reference_no ? el('dd', { text: p.reference_no }) : null),
    lines.length ? el('div', { class:'tablewrap', style:'margin-top:.8rem' },
      el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Applied to'), el('th', { class:'num' }, 'Amount'))),
        el('tbody', {}, lines))) : null,
    advance > 0.001 ? el('p', { class:'small', text: `Kept as advance: ${money(advance)}` }) : null);

  await modal({ title:'Receipt', body, actions:[
    { label:'Print', value:'print' },
    { label:'Share on WhatsApp', value:'wa' },
    { label:'Done', kind:'primary', value:null }
  ]}).then(async (action) => {
    if (action === 'print') window.print();
    if (action === 'wa'){
      const msg = [
        `${s.building_name || 'Building'} — service charge receipt`,
        `Receipt: ${p.receipt_no}`,
        `Flat: ${flat?.flat_number || ''}`,
        `Date: ${fdate(p.payment_date)}`,
        `Amount: ${money(p.amount)}`,
        advance > 0.001 ? `Advance kept: ${money(advance)}` : null,
        'Thank you.'
      ].filter(Boolean).join('\n');
      window.open('https://wa.me/?text=' + encodeURIComponent(msg), '_blank', 'noopener');
    }
  });
}

/* ==================================================================
   OUTSTANDING
   ================================================================== */
async function outstanding(){
  const rows = (await q('v_flat_dues')).filter(d => Number(d.outstanding) > 0)
    .sort((a,b) => Number(b.outstanding) - Number(a.outstanding));

  const aged = await q('v_flat_charges', b => b.gt('due_amount', 0)).catch(() => []);
  const bucketOf = (days) => days <= 0 ? 'current' : days <= 30 ? 'd30' : days <= 60 ? 'd60' : days <= 90 ? 'd90' : 'd90p';
  const buckets = { current:0, d30:0, d60:0, d90:0, d90p:0 };
  for (const c of aged) buckets[bucketOf(Number(c.days_overdue))] += Number(c.due_amount);

  const total = rows.reduce((t,r) => t + Number(r.outstanding), 0);
  const cols = [
    { label:'Flat', primary:true, key:'flat_number' },
    { label:'Floor', cls:'num', key:'floor' },
    { label:'Billed to', fmt: r => r.billed_to || '—', csv: r => r.billed_to },
    { label:'Mobile', fmt: r => r.billed_mobile || '—', csv: r => r.billed_mobile },
    { label:'Last payment', fmt: r => r.last_payment_date ? fdate(r.last_payment_date) : 'never', csv: r => r.last_payment_date },
    { label:'Outstanding', cls:'num', fmt: r => money(r.outstanding, { bare:true }), csv: r => r.outstanding }
  ];

  return el('div', {},
    el('div', { class:'page-head' },
      el('h1', { text:'Outstanding service charge' }),
      el('p', { class:'sub', text:`${rows.length} flat${rows.length === 1 ? '' : 's'} owing ${money(total)} in total` })),
    el('div', { class:'grid g-stats' },
      stat('Not yet due', money0(buckets.current)),
      stat('1–30 days',   money0(buckets.d30)),
      stat('31–60 days',  money0(buckets.d60), null, buckets.d60 ? 'bad' : ''),
      stat('61–90 days',  money0(buckets.d90), null, buckets.d90 ? 'bad' : ''),
      stat('Over 90 days',money0(buckets.d90p), null, buckets.d90p ? 'bad' : '')),
    el('div', { class:'toolbar' },
      el('a', { class:'btn', href:'#/charges', text:'← Service charge' }),
      el('span', { class:'spacer' }),
      can('charges','export') ? el('button', { class:'btn small', text:'Export CSV',
        onclick: () => { downloadCSV('outstanding.csv', cols, rows); logEvent('EXPORT', { module:'charges', detail:'outstanding list' }); } }) : null),
    table(cols, rows, { onRow: r => go('#/charges/flat/' + r.flat_id), empty:'Every flat is up to date.' }));
}

/* ==================================================================
   FLAT STATEMENT
   ================================================================== */
async function statement(flatId){
  if (!flatId) return emptyState('No flat chosen.');
  const flat = await one('flats', b => b.eq('id', flatId));
  if (!flat) return emptyState('That flat does not exist.');

  const [ledger, dues, charges] = await Promise.all([
    q('v_flat_ledger', b => b.eq('flat_id', flatId).order('entry_date')),
    q('v_flat_dues',   b => b.eq('flat_id', flatId)),
    q('v_flat_charges',b => b.eq('flat_id', flatId).order('period_year').order('period_month'))
  ]);
  const d = dues[0] || {};

  let running = 0;
  const rows = ledger.map(r => {
    running += Number(r.debit) - Number(r.credit);
    return { ...r, running };
  });

  const cols = [
    { label:'Date', fmt: r => fdate(r.entry_date), csv: r => r.entry_date },
    { label:'Description', primary:true, key:'description' },
    { label:'Reference', fmt: r => r.ref_no || '—', cls:'mono', csv: r => r.ref_no },
    { label:'Charge', cls:'num', fmt: r => Number(r.debit) ? money(r.debit, { bare:true }) : '', csv: r => r.debit },
    { label:'Paid',   cls:'num', fmt: r => Number(r.credit) ? money(r.credit, { bare:true }) : '', csv: r => r.credit },
    { label:'Balance',cls:'num', fmt: r => money(r.running, { bare:true }), csv: r => r.running }
  ];

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: `Flat ${flat.flat_number}` }),
    el('p', { class:'sub', text: `Floor ${flat.floor}${flat.area_sqft ? ` · ${num(flat.area_sqft)} sq ft` : ''} · billed to ${d.billed_to || 'nobody yet'}` })));

  page.append(el('div', { class:'grid g-stats' },
    stat('Monthly charge', money(flat.service_charge ?? settings().default_service_charge),
         flat.service_charge ? 'set for this flat' : 'building default'),
    stat('Outstanding', money(d.outstanding || 0), null, Number(d.outstanding) > 0 ? 'bad' : 'good'),
    stat('Advance held', money(d.advance || 0)),
    stat('Last payment', d.last_payment_date ? fdate(d.last_payment_date) : 'never')));

  const bar = el('div', { class:'toolbar' },
    el('a', { class:'btn', href:'#/charges', text:'← Service charge' }));
  if (can('charges','add')){
    const p = el('button', { class:'btn primary', text:'Record a payment' });
    p.onclick = async () => { const r = await paymentDialog(flatId); if (r) refresh(); };
    bar.append(p);
  }
  bar.append(el('span', { class:'spacer' }),
    el('button', { class:'btn small', text:'Print', onclick: () => window.print() }));
  if (can('charges','export'))
    bar.append(el('button', { class:'btn small', text:'CSV',
      onclick: () => downloadCSV(`statement-${flat.flat_number}.csv`, cols, rows) }));
  page.append(bar);

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Statement' })),
    table(cols, rows, { empty:'Nothing has been billed to this flat yet.' })));

  const open = charges.filter(c => Number(c.due_amount) > 0);
  if (open.length && can('charges','add')){
    const waivable = el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Open months' })));
    for (const c of open){
      const row = el('div', { style:'display:flex;gap:.6rem;align-items:center;flex-wrap:wrap;padding:.35rem 0;border-bottom:1px solid var(--line-soft)' },
        el('span', { style:'flex:1;min-width:8rem',
          text: c.charge_source === 'OPENING' ? 'Balance brought forward' : monthName(c.period_year, c.period_month) }),
        el('span', { class:'num', text: money(c.due_amount) }),
        badgeEl(c.status));
      if (can('charges','waive')){
        const w = el('button', { class:'btn small', text:'Request waiver' });
        w.onclick = () => waiverDialog(c);
        row.append(w);
      }
      waivable.append(row);
    }
    page.append(waivable);
  }
  return page;
}

function badgeEl(status){
  return el('span', { class:'badge b-' + String(status).toLowerCase(), text:String(status).replace(/_/g,' ') });
}

async function waiverDialog(charge){
  const amt = el('input', { type:'number', step:'0.01', min:'0.01', max:String(charge.due_amount), value: charge.due_amount });
  const kind = select([{ value:'WAIVER', label:'Waiver' }, { value:'DISCOUNT', label:'Discount' },
                       { value:'PENALTY', label:'Penalty (increases the bill)' }], { value:'WAIVER' });
  const why = el('textarea', { rows:3, required:true, placeholder:'Why is this being adjusted?' });
  const body = el('div', {},
    el('p', { class:'muted small', text:`${monthName(charge.period_year, charge.period_month)} — ${money(charge.due_amount)} outstanding.` }),
    field('Type', kind), field('Amount', amt, { required:true }), field('Reason', why, { required:true }),
    el('p', { class:'hint', text:'This does not change the original charge. It is recorded separately and must be approved by someone else.' }));

  const res = await modal({ title:'Request an adjustment', body, actions:[
    { label:'Cancel', value:null },
    { label:'Submit request', kind:'primary',
      validate: () => { if (!why.value.trim()){ err('A reason is required.'); return false; } return true; }, value:true }
  ]});
  if (!res) return;
  try {
    await rpc('request_adjustment', { p_charge: charge.id, p_type: kind.value,
      p_amount: Number(amt.value), p_reason: why.value.trim() });
    ok('Requested. Someone else needs to approve it.');
    refresh();
  } catch { /* toast already shown */ }
}

/* ==================================================================
   PAYMENTS
   ================================================================== */
async function paymentList(){
  const rows = await q('payments', b => b.order('payment_date', { ascending:false }).limit(300));
  const flats = await ref('flats');
  const flatNo = (id) => flats.find(f => f.id === id)?.flat_number || '—';

  const cols = [
    { label:'Receipt', primary:true, cls:'mono', key:'receipt_no' },
    { label:'Date', fmt: r => fdate(r.payment_date), csv: r => r.payment_date },
    { label:'Flat', fmt: r => flatNo(r.flat_id), csv: r => flatNo(r.flat_id) },
    { label:'Amount', cls:'num', fmt: r => money(r.amount, { bare:true }), csv: r => r.amount },
    { label:'Method', fmt: r => String(r.method).replace(/_/g,' '), csv: r => r.method },
    { label:'Reference', fmt: r => r.reference_no || '—', csv: r => r.reference_no },
    { label:'Status', fmt: r => badge(r.status), csv: r => r.status },
    { label:'', fmt: r => {
        if (r.status !== 'ACTIVE' || !can('charges','cancel')) return '';
        const b = el('button', { class:'btn small danger', text:'Reverse' });
        b.onclick = async (e) => {
          e.stopPropagation();
          const reason = await reasonBox('Reverse this payment',
            'Why? A cheque bounced, wrong flat, duplicate entry…', 'Reverse');
          if (!reason) return;
          try { await rpc('reverse_payment', { p_payment: r.id, p_reason: reason });
                ok('Reversed. The charges it settled are open again.'); refresh(); } catch {}
        };
        return b;
      } }
  ];

  return el('div', {},
    el('div', { class:'page-head' }, el('h1', { text:'Payments received' })),
    el('div', { class:'toolbar' },
      el('a', { class:'btn', href:'#/charges', text:'← Service charge' }),
      el('span', { class:'spacer' }),
      can('charges','export') ? el('button', { class:'btn small', text:'Export CSV',
        onclick: () => downloadCSV('payments.csv', cols, rows) }) : null),
    table(cols, rows, { empty:'No payments recorded yet.' }));
}

/* ==================================================================
   ADJUSTMENTS / WAIVERS
   ================================================================== */
async function adjustmentList(){
  const rows = await q('adjustments', b => b.order('requested_at', { ascending:false }).limit(200));
  const flats = await ref('flats');
  const users = await ref('users');
  const nameOf = (id) => users.find(u => u.user_id === id)?.full_name || '—';
  const flatNo = (id) => flats.find(f => f.id === id)?.flat_number || '—';

  const body = el('div', {});
  if (!rows.length) body.append(emptyState('No waivers or adjustments have been requested.'));

  for (const a of rows){
    const card = el('div', { class:'card' },
      el('div', { class:'card-head' },
        el('h3', { text: `${a.adj_type} — flat ${flatNo(a.flat_id)}` }),
        el('span', { class:'num', style:'font-weight:700', text: money(a.amount) }),
        badgeEl(a.status)),
      el('p', { style:'white-space:pre-wrap', text: a.reason }),
      el('p', { class:'small muted', text: `Requested by ${nameOf(a.requested_by)} on ${fdate(a.requested_at)}` +
        (a.approved_by ? ` · decided by ${nameOf(a.approved_by)} on ${fdate(a.approved_at)}` : '') }));

    if (a.status === 'PENDING' && can('charges','waive')){
      const mine = a.requested_by === state.user.id;
      if (mine){
        card.append(el('p', { class:'hint', text:'You requested this, so someone else has to approve it.' }));
      } else {
        const yes = el('button', { class:'btn primary', text:'Approve' });
        const no  = el('button', { class:'btn danger', text:'Reject' });
        yes.onclick = async () => {
          const okay = await confirmBox('Approve this adjustment?',
            `${a.adj_type} of ${money(a.amount)} on flat ${flatNo(a.flat_id)}.`, 'Approve');
          if (!okay) return;
          try { await rpc('approve_adjustment', { p_adj: a.id }); ok('Approved'); refresh(); } catch {}
        };
        no.onclick = async () => {
          const reason = await reasonBox('Reject this adjustment', 'Why?', 'Reject');
          if (!reason) return;
          try { await rpc('reject_adjustment', { p_adj: a.id, p_reason: reason }); ok('Rejected'); refresh(); } catch {}
        };
        card.append(el('div', { class:'btn-row' }, yes, no));
      }
    }
    body.append(card);
  }

  return el('div', {},
    el('div', { class:'page-head' }, el('h1', { text:'Waivers & adjustments' })),
    el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/charges', text:'← Service charge' })),
    body);
}
