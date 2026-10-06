/* =====================================================================
   billing.js — owners with several flats, one payment for many flats,
   and the monthly bill.

     #/charges/owners       everyone who owns or pays for a flat; land
                            owners with several flats first
     #/charges/owner/<id>   one person: every flat, who lives there, who
                            pays, its rate, the dues — one payment, one
                            reminder, one bill for all of it
     #/charges/bills        the month's bills: one per payer, every flat
                            on it, due on the building's due day, sent one
                            tap at a time and recorded

   Every amount on these screens comes from the database functions in
   089_owners_bills.sql; the screen lays them out.
   ===================================================================== */

import { el, field, select, money, money0, num, fdate, table, stat, emptyState, ok, err, modal,
         todayISO, monthName, badge, confirmBox } from '../core/ui.js';
import { q, rpc, isMissingObject, friendly, uploadAttachment, BUCKETS, logEvent } from '../core/db.js';
import { can, ref, settings, invalidate } from '../core/store.js';
import { go, refresh } from '../core/router.js';
import { groupReceiptDialog } from '../core/receipts.js';
import { ownerReminderDialog, amountText, monthLabel, dateText, fillTemplate } from '../core/reminder.js';
import { wireWhatsAppLink } from '../core/whatsapp.js';
import { receiptImage, receiptPdf, shareFile } from '../core/receipt.js';

const needsUpdate = (what) => el('div', { class:'alert normal' }, el('div', { class:'a-body' },
  el('div', { class:'a-title', text:`${what} needs a database update` }),
  el('div', { class:'a-meta', text:'In Supabase open the SQL Editor and run sql/PATCH.sql — it is safe to run twice — then reload this page.' })));

async function call(name, args){
  try { return { rows: await rpc(name, args, { silent:true }) }; }
  catch (e){ const o = e.original || e; return isMissingObject(o) ? { missing:true } : { error: friendly(o) }; }
}

/* ==================================================================
   OWNERS & PAYERS
   ================================================================== */
export async function ownersView(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' }, el('h1', { text:'Owners & payers' }),
    el('p', { class:'sub', text:'Everyone who owns a flat or pays for one. Owners with several flats — the land owners — come first, with their flats and dues added together.' })));
  page.append(el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/charges', text:'← Service charge' }),
    el('a', { class:'btn', href:'#/charges/bills', text:'Monthly bills' })));
  const res = await call('owner_accounts', {});
  if (res.missing){ page.append(needsUpdate('Owners & payers')); return page; }
  if (res.error){ page.append(emptyState(res.error)); return page; }
  const rows = res.rows || [];

  const multi = rows.filter(r => r.flats_owned >= 2 || r.flats_paid >= 2);
  page.append(el('div', { class:'grid g-stats' },
    stat('Owners with several flats', num(multi.length), `${num(multi.reduce((t, r) => t + r.flats_owned, 0))} flats between them`),
    stat('Payers owing', num(rows.filter(r => Number(r.outstanding) > 0).length), `of ${num(rows.filter(r => r.flats_paid > 0).length)} who pay`),
    stat('Flats rented out', num(rows.reduce((t, r) => t + r.flats_rented_out, 0)))));

  let filter = multi.length ? 'MULTI' : 'ALL';
  const search = el('input', { type:'search', placeholder:'Search a name or a flat…' });
  const chips = el('div', { class:'chip-row' });
  const host = el('div', {});
  const paintChips = () => chips.replaceChildren(...[
    ['MULTI', `Several flats (${multi.length})`], ['OWING', `Owing (${rows.filter(r => Number(r.outstanding) > 0).length})`], ['ALL', `Everyone (${rows.length})`]
  ].map(([k, label]) => el('button', { type:'button', class:'filter-chip' + (filter === k ? ' on' : ''), text: label,
    'aria-pressed': String(filter === k), onclick: () => { filter = k; paintChips(); paint(); } })));

  const cols = [
    { label:'Name', primary:true, fmt: r => el('span', {}, el('b', { text: r.owner_name }),
        r.owner_mobile ? el('span', { class:'small muted', text:` · ${r.owner_mobile}` }) : null) },
    { label:'Owns', fmt: r => r.flats_owned ? `${r.owned_list}${r.flats_rented_out ? ` (${r.flats_rented_out} rented)` : ''}` : '—' },
    { label:'Pays for', fmt: r => r.paid_list || '—' },
    { label:'Monthly', cls:'num', fmt: r => r.flats_paid ? money(r.monthly_total, { bare:true }) : '—' },
    { label:'Owes', cls:'num', fmt: r => Number(r.outstanding) > 0 ? el('b', { class:'bad-text', text: money(r.outstanding, { bare:true }) }) : '—' },
    { label:'Advance', cls:'num', fmt: r => Number(r.advance) > 0 ? money(r.advance, { bare:true }) : '—' },
    { label:'', fmt: r => {
        const acts = el('span', { class:'row-acts' });
        if (can('charges', 'add') && r.flats_paid > 0)
          acts.append(el('button', { class:'btn small', type:'button', text:'Pay', onclick: (e) => { e.stopPropagation(); groupPaymentDialog(r.owner_id); } }));
        if (can('charges', 'add') && Number(r.outstanding) > 0)
          acts.append(el('button', { class:'btn small', type:'button', text:'Remind', onclick: (e) => { e.stopPropagation(); ownerReminderDialog(r.owner_id); } }));
        return acts;
      } }
  ];
  const paint = () => {
    const t = search.value.trim().toLowerCase();
    const list = rows.filter(r => (filter === 'ALL' || (filter === 'MULTI' ? (r.flats_owned >= 2 || r.flats_paid >= 2) : Number(r.outstanding) > 0))
      && (!t || [r.owner_name, r.owner_mobile, r.owned_list, r.paid_list].some(x => String(x || '').toLowerCase().includes(t))));
    host.replaceChildren(table(cols, list, { onRow: r => go('#/charges/owner/' + r.owner_id),
      empty: rows.length ? 'Nobody matches.' : 'No owners recorded yet. Add owners on each flat’s page.' }));
  };
  search.oninput = paint;
  page.append(el('div', { class:'toolbar' }, el('div', { class:'grow' }, search)), chips, host);
  paintChips(); paint();
  return page;
}

/* ==================================================================
   ONE OWNER
   ================================================================== */
export async function ownerPage(ownerId){
  const page = el('div', {});
  const [fr, ar] = await Promise.all([call('owner_flats', { p_owner: ownerId }), call('owner_accounts', {})]);
  if (fr.missing || ar.missing){ page.append(needsUpdate('The owner page')); return page; }
  if (fr.error || ar.error){ page.append(emptyState(fr.error || ar.error)); return page; }
  const flats = fr.rows || [];
  const a = (ar.rows || []).find(r => r.owner_id === ownerId);
  if (!a) return el('div', {}, el('a', { class:'btn', href:'#/charges/owners', text:'← Owners & payers' }),
    emptyState('This person does not own or pay for any flat at the moment.'));

  page.append(el('div', { class:'page-head' }, el('h1', { text: a.owner_name }),
    el('p', { class:'sub', text: [a.owner_mobile, a.flats_owned ? `owns ${a.flats_owned} flat${a.flats_owned === 1 ? '' : 's'}` : null,
      a.flats_rented_out ? `${a.flats_rented_out} rented out` : null].filter(Boolean).join(' · ') })));

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/charges/owners', text:'← Owners & payers' }));
  if (can('charges', 'add') && a.flats_paid > 0)
    bar.append(el('button', { class:'btn primary', type:'button', text:'Record a payment for all flats', onclick: () => groupPaymentDialog(ownerId) }));
  if (can('charges', 'add') && Number(a.outstanding) > 0)
    bar.append(el('button', { class:'btn', type:'button', text:'Send one reminder', onclick: () => ownerReminderDialog(ownerId) }));
  if (a.flats_paid > 0)
    bar.append(el('a', { class:'btn', href:`#/charges/bills?payer=${ownerId}`, text:'This month’s bill' }));
  page.append(bar);

  page.append(el('div', { class:'grid g-stats' },
    stat('Pays for', `${num(a.flats_paid)} flat${a.flats_paid === 1 ? '' : 's'}`, a.paid_list || '—'),
    stat('Monthly total', money0(a.monthly_total), 'at this month’s rates'),
    stat('Owes now', money0(a.outstanding), a.flats_owing ? `on ${a.flats_owing} flat${a.flats_owing === 1 ? '' : 's'}` : 'all paid', Number(a.outstanding) > 0 ? 'bad' : 'good'),
    stat('Advance', money0(a.advance), a.last_payment_date ? `last paid ${fdate(a.last_payment_date)}` : 'never paid')));

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Flats' })),
    table([
      { label:'Flat', primary:true, key:'flat_number' },
      { label:'Lives there', fmt: f => f.tenant_name ? `${f.tenant_name} (tenant)` : (f.is_owner ? 'Owner / empty' : '—') },
      { label:'Pays', fmt: f => f.pays ? el('span', { class:'badge b-active', text: f.is_owner ? 'owner pays' : 'pays (tenant)' })
                                      : `${f.payer_name || 'nobody set'}${f.payer_relation === 'TENANT' ? ' (tenant)' : ''}` },
      { label:'Monthly rate', fmt: f => el('span', {}, money(f.current_rate, { bare:true }),
          f.rate_source === 'TEMPORARY' ? el('span', { class:'small muted', text:` temporary${f.rate_until ? ' until ' + monthName(...String(f.rate_until).slice(0, 7).split('-').map(Number)) : ''} — ${f.rate_reason}` }) : null) },
      { label:'Owes', cls:'num', fmt: f => Number(f.outstanding) > 0 ? money(f.outstanding, { bare:true }) : '—' },
      { label:'Advance', cls:'num', fmt: f => Number(f.advance) > 0 ? money(f.advance, { bare:true }) : '—' }
    ], flats, { onRow: f => go('#/flats/' + f.flat_id) }),
    el('p', { class:'hint', text:'Who pays each flat is set on the flat’s own page (Owner or Tenant). Tap a flat to change it, or to give it a temporary rate.' })));

  const groups = await q('v_payment_groups', b => b.eq('payer_owner_id', ownerId).order('payment_date', { ascending:false }).limit(24), { silent:true }).catch(() => []);
  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Combined receipts' })),
    groups.length ? table([
      { label:'Receipt', primary:true, cls:'mono', key:'group_no' },
      { label:'Date', fmt: g => fdate(g.payment_date) },
      { label:'Flats', key:'flat_list' },
      { label:'Amount', cls:'num', fmt: g => money(g.total_amount, { bare:true }) },
      { label:'Status', fmt: g => badge(g.status) }
    ], groups, { onRow: g => groupReceiptDialog(g.id) }) : emptyState('No combined payments yet.')));
  return page;
}

/* ==================================================================
   ONE PAYMENT FOR SEVERAL FLATS
   ================================================================== */
export async function groupPaymentDialog(ownerId){
  const [fr, accounts] = await Promise.all([call('owner_flats', { p_owner: ownerId }), ref('accounts')]);
  if (fr.missing) return err('Combined payments need a database update: run sql/PATCH.sql in Supabase.');
  if (fr.error) return err(fr.error);
  const flats = (fr.rows || []).filter(f => f.pays && (f.flat_status === 'ACTIVE' || Number(f.outstanding) > 0));
  if (!flats.length) return err('This person does not pay for any flat.');
  const ownerName = flats[0].owner_name;

  const lines = flats.map(f => {
    const owes = Number(f.outstanding);
    const inc = el('input', { type:'checkbox' }); inc.checked = owes > 0;
    const amt = el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal', value: owes > 0 ? owes : '' , 'aria-label':`Amount for ${f.flat_number}` });
    amt.disabled = !inc.checked;
    inc.onchange = () => { amt.disabled = !inc.checked; if (inc.checked && !amt.value) amt.value = owes > 0 ? owes : f.current_rate; sum(); };
    amt.oninput = () => sum();
    return { f, inc, amt };
  });
  const totalEl = el('b', { class:'num' });
  const sum = () => {
    const t = lines.filter(l => l.inc.checked).reduce((s, l) => s + (Number(l.amt.value) || 0), 0);
    totalEl.textContent = money(t);
    return t;
  };

  const dateI = el('input', { type:'date', value: todayISO() });
  const methI = select(['CASH','BKASH','NAGAD','BANK_TRANSFER','CHEQUE','ROCKET','CARD'].map(x => ({ value:x, label:x.replace(/_/g, ' ') })), { value:'CASH' });
  const defaultAcct = settings().default_cash_account_id || (accounts.length === 1 ? accounts[0].id : '');
  const acctI = select(accounts.map(a => ({ value:a.id, label:a.name })), { value: defaultAcct, placeholder:'Choose an account' });
  const refI = el('input', { type:'text', maxlength:'80', placeholder:'bKash trx id, cheque no' });
  const payerI = el('input', { type:'text', maxlength:'120', value: ownerName });
  const proofI = el('input', { type:'file', accept:'image/*,application/pdf' });

  const body = el('div', {},
    el('p', { class:'muted small', text:`One payment from ${ownerName}, split across the flats they pay for. Each line starts at what that flat owes — change any amount. One receipt lists every flat.` }),
    el('div', { class:'pay-lines' }, lines.map(l => el('label', { class:'pay-line' }, l.inc,
      el('span', { class:'pay-flat' }, el('b', { text:`Flat ${l.f.flat_number}` }),
        el('span', { class:'small muted', text: Number(l.f.outstanding) > 0 ? `owes ${money(l.f.outstanding)}` : (Number(l.f.advance) > 0 ? `${money(l.f.advance)} in advance` : 'up to date') +
          (l.f.rate_source === 'TEMPORARY' ? ` · temporary rate ${money(l.f.current_rate)}` : '') })),
      l.amt))),
    el('p', { class:'pay-total' }, 'Total received: ', totalEl),
    el('div', { class:'grid g-form' }, field('Date', dateI, { required:true }), field('Method', methI)),
    el('div', { class:'grid g-form' }, field('Into account', acctI, { required:true }), field('Reference', refI)),
    field('Received from', payerI),
    field('Proof of payment (optional)', proofI, { hint:'A bKash or bank screenshot, or a deposit slip.' }),
    el('p', { class:'hint', text:'Each flat’s share settles its oldest unpaid month first; anything over is kept as that flat’s advance.' }));
  setTimeout(sum);

  const res = await modal({ title:`Payment from ${ownerName}`, body, actions:[
    { label:'Cancel', value:null },
    { label:'Record payment', kind:'primary', value:true, validate: () => {
        const chosen = lines.filter(l => l.inc.checked);
        if (!chosen.length){ err('Tick at least one flat.'); return false; }
        if (chosen.some(l => !(Number(l.amt.value) > 0))){ err('Every ticked flat needs an amount greater than zero.'); return false; }
        if (!acctI.value){ err('Choose the account the money went into.'); return false; }
        return true;
      } }
  ]});
  if (!res) return null;
  try {
    const g = await rpc('record_group_payment', {
      p_owner: ownerId,
      p_lines: lines.filter(l => l.inc.checked).map(l => ({ flat: l.f.flat_id, amount: Number(l.amt.value) })),
      p_date: dateI.value, p_method: methI.value, p_account: acctI.value,
      p_reference: refI.value.trim() || null, p_notes: null, p_payer_name: payerI.value.trim() || null });
    const row = Array.isArray(g) ? g[0] : g;
    invalidate('balances');
    ok(`Receipt ${row?.group_no || ''} recorded.`);
    if (proofI.files?.[0] && row?.id)
      await uploadAttachment(BUCKETS.receipts, 'payment_groups', row.id, proofI.files[0])
        .catch(e => err(`Payment recorded, but the proof did not upload. ${e.message} You can add it from the receipt.`));
    if (row) await groupReceiptDialog(row.id);
    refresh();
    return row;
  } catch { return null; }
}

/* ==================================================================
   THE MONTHLY BILL
   ================================================================== */
/** Fill the bill template for one payer. `tpl` overrides the saved wording (Settings preview). */
export function billMessage(payer, y, m, lang, tplOverride){
  const s = settings();
  const tk = (n) => lang === 'bn' ? `${amountText(n, lang)} টাকা` : `Tk ${amountText(n, lang)}`;
  const month = monthLabel(y, m, lang);
  const lines = payer.flats.map(f => {
    const parts = [];
    const label = lang === 'bn' ? `ফ্ল্যাট ${f.flat_number}` : `Flat ${f.flat_number}`;
    if (Number(f.this_month) > 0){
      let x = `${label} — ${month}: ${tk(f.this_month)}`;
      if (f.rate_source === 'TEMPORARY') x += lang === 'bn' ? ' (অস্থায়ী হার)' : ' (temporary rate)';
      if (Number(f.this_month_due) < Number(f.this_month))
        x += Number(f.this_month_due) === 0 ? (lang === 'bn' ? ' — অগ্রিম থেকে পরিশোধিত' : ' — paid from advance')
                                            : (lang === 'bn' ? ` — বাকি ${tk(f.this_month_due)}` : ` — ${tk(f.this_month_due)} still to pay`);
      parts.push(x);
    }
    if (Number(f.previous_due) > 0)
      parts.push(`${Number(f.this_month) > 0 ? '   + ' : label + ' — '}${lang === 'bn' ? 'পূর্বের বকেয়া' : 'earlier dues'}: ${tk(f.previous_due)}`);
    return parts.join('\n');
  }).filter(Boolean).join('\n');
  const tpl = tplOverride ?? ((lang === 'bn' ? s.bill_template_bn : s.bill_template_en) || '');
  return fillTemplate(tpl, {
    name: payer.name || (lang === 'bn' ? 'মহোদয়/মহোদয়া' : 'Sir/Madam'),
    month, lines, total: amountText(payer.total, lang),
    due_date: dateText(payer.due_date, lang), building: s.building_name || '',
    how_to_pay: s.reminder_how_to_pay || '',
    flats: payer.flats.map(f => f.flat_number).join(', ')
  });
}

/** month_bills rows → one entry per payer. */
function byPayer(rows){
  const out = new Map();
  for (const r of rows){
    const key = r.payer_id || `none-${r.flat_id}`;
    if (!out.has(key)) out.set(key, { id: r.payer_id, name: r.payer_name, mobile: r.payer_mobile, flats: [], due_date: r.due_date });
    out.get(key).flats.push(r);
  }
  for (const p of out.values()){
    p.total = p.flats.reduce((t, f) => t + Number(f.total_due), 0);
    p.thisMonth = p.flats.reduce((t, f) => t + Number(f.this_month), 0);
    p.sent = p.flats.every(f => f.times_sent > 0);
    p.lastSent = p.flats.map(f => f.last_sent_at).filter(Boolean).sort().pop() || null;
  }
  return [...out.values()];
}

export async function billsView(query){
  const now = new Date();
  const y = Number(query?.get('y')) || now.getFullYear();
  const m = Number(query?.get('m')) || now.getMonth() + 1;
  const onlyPayer = query?.get('payer') || null;
  const page = el('div', {});
  page.append(el('div', { class:'page-head' }, el('h1', { text:`Bills — ${monthName(y, m)}` }),
    el('p', { class:'sub', text:`One bill per payer: every flat they pay for, this month’s charge, anything owed from before, and the total — due by ${fdate(`${y}-${String(m).padStart(2,'0')}-${String(settings().charge_due_day || 10).padStart(2,'0')}`)}.` })));

  const monthI = select(Array.from({ length: 12 }, (_, i) => ({ value: i + 1, label: monthName(y, i + 1).split(' ')[0] })), { value: m });
  const yearI = select(Array.from({ length: 5 }, (_, i) => now.getFullYear() + 1 - i).map(v => ({ value:v, label:String(v) })), { value: y });
  const goMonth = () => go(`#/charges/bills?y=${yearI.value}&m=${monthI.value}`);
  monthI.onchange = yearI.onchange = goMonth;
  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/charges', text:'← Service charge' }),
    el('div', { class:'ctl' }, field('Month', monthI)), el('div', { class:'ctl' }, field('Year', yearI)));
  page.append(bar);

  const res = await call('month_bills', { p_year: y, p_month: m });
  if (res.missing){ page.append(needsUpdate('Monthly bills')); return page; }
  if (res.error){ page.append(emptyState(res.error)); return page; }
  const rows = res.rows || [];

  if (!rows.some(r => r.is_billed)){
    const box = el('div', { class:'alert high' }, el('div', { class:'a-body' },
      el('div', { class:'a-title', text:`${monthName(y, m)} has not been billed yet` }),
      el('div', { class:'a-meta', text:'Generate the month first; the bills are made from it.' })));
    if (can('charges', 'add')) box.append(el('button', { class:'btn primary', type:'button', text:`Generate ${monthName(y, m)}`, onclick: async () => {
      try { const run = await rpc('generate_monthly_charges', { p_year: y, p_month: m }); ok((Array.isArray(run) ? run[0] : run)?.notes || 'Billed.'); refresh(); } catch {}
    } }));
    page.append(box);
    if (!rows.length) return page;
  }

  let payers = byPayer(rows);
  if (onlyPayer) payers = payers.filter(p => p.id === onlyPayer);
  const toSend = payers.filter(p => p.id && p.total > 0 && !p.sent);
  page.append(el('div', { class:'grid g-stats' },
    stat('Payers', num(payers.length), `${num(rows.length)} flats`),
    stat('Bills to send', num(toSend.length), toSend.length ? 'not sent yet' : 'all sent', toSend.length ? 'bad' : 'good'),
    stat('Sent', num(payers.filter(p => p.sent).length)),
    stat('Billed this month', money0(payers.reduce((t, p) => t + p.thisMonth, 0)))));

  if (can('charges', 'add') && toSend.length){
    page.append(el('div', { class:'toolbar' },
      el('button', { class:'btn primary big', type:'button', text:`Send the next bill (${toSend.length} left)`,
        onclick: () => billDialog(toSend[0], y, m, { queue: true }) }),
      el('span', { class:'hint', text:'Opens WhatsApp with the bill written; after each one the next is ready.' })));
  }
  if (onlyPayer) page.append(el('p', {}, el('a', { href:`#/charges/bills?y=${y}&m=${m}`, text:'Show every payer' })));

  const host = el('div', { class:'bill-list' });
  for (const p of payers){
    const card = el('section', { class:'card bill-card' + (p.sent ? ' sent' : '') },
      el('div', { class:'bill-head' },
        el('div', {}, el('h3', { text: p.name || 'Nobody set to pay' }),
          el('div', { class:'small muted', text: [p.mobile, p.flats.map(f => f.flat_number).join(', ')].filter(Boolean).join(' · ') })),
        el('div', { class:'bill-total' }, el('span', { class:'small muted', text:'Total payable' }), el('b', { class:'num', text: money(p.total) }))),
      el('table', { class:'bill-lines' },
        el('thead', {}, el('tr', {}, el('th', {}), el('th', { class:'num', text:'This month' }), el('th', {}), el('th', { class:'num', text:'To pay' }))),
        el('tbody', {}, p.flats.map(f => el('tr', {},
        el('td', { text:`Flat ${f.flat_number}` + (f.rate_source === 'TEMPORARY' ? ' (temporary rate)' : '') }),
        el('td', { class:'num', text: Number(f.this_month) ? money(f.this_month, { bare:true }) : '—' }),
        el('td', { class:'num small muted', text: Number(f.previous_due) > 0 ? `+ ${money(f.previous_due, { bare:true })} earlier` : '' }),
        el('td', { class:'num', text: Number(f.total_due) > 0 ? money(f.total_due, { bare:true }) : 'paid' }))))),
      el('div', { class:'bill-foot' },
        p.sent ? el('span', { class:'badge b-active', text:`sent ${fdate(String(p.lastSent).slice(0, 10))}` })
               : (p.total > 0 ? el('span', { class:'badge b-overdue', text:'not sent' }) : el('span', { class:'badge b-draft', text:'nothing to pay' })),
        p.id && can('charges', 'add') ? el('button', { class:'btn small', type:'button', text: p.sent ? 'Send again' : 'Send bill',
          onclick: () => billDialog(p, y, m) }) : null,
        !p.id ? el('span', { class:'small muted', text:'Set who pays on the flat’s page to send its bill.' }) : null));
    host.append(card);
  }
  page.append(host);
  return page;
}

async function billDialog(payer, y, m, { queue = false } = {}){
  const s = settings();
  let digits = null;
  if (payer.mobile){ try { digits = await rpc('normalize_mobile', { p: payer.mobile }, { silent:true }); } catch {} }
  const langI = select([{ value:'en', label:'English' }, { value:'bn', label:'বাংলা' }], { value: s.reminder_language || 'en' });
  const text = el('textarea', { rows: 14, maxlength:'3000', class:'rem-text' });
  const wa = el('a', { class:'btn primary' });
  const sms = el('a', { class:'btn', text:'Send as SMS' });
  const img = el('button', { class:'btn', type:'button', text:'Bill as picture' });
  const copy = el('button', { class:'btn', type:'button', text:'Copy text' });
  const sync = () => {
    wireWhatsAppLink(wa, digits, text.value);
    wa.textContent = digits ? 'Send on WhatsApp' : 'Open WhatsApp (choose the contact)';
    sms.href = digits ? `sms:+${digits}?&body=${encodeURIComponent(text.value)}` : '#';
    sms.textContent = 'Send as SMS'; sms.hidden = !digits;
  };
  const write = () => { text.value = billMessage(payer, y, m, langI.value); sync(); };
  text.oninput = sync; langI.onchange = write; write();

  let closeDialog = null, sent = false;
  const record = async (channel, ev) => {
    if (sent){ if (ev) ev.preventDefault(); return; }
    sent = true;
    try {
      await rpc('log_bill_notice', { p_flats: payer.flats.map(f => f.flat_id), p_year: y, p_month: m,
                                     p_channel: channel, p_message: text.value }, { silent:true });
      ok(`Bill for ${payer.name} recorded as sent.`);
      closeDialog && closeDialog(true);
      if (queue){
        setTimeout(async () => {
          const rows = (await rpc('month_bills', { p_year: y, p_month: m }, { silent:true })) || [];
          const next = byPayer(rows).find(p => p.id && p.total > 0 && !p.sent);
          refresh();
          if (next && await confirmBox('Next bill', `Send the bill for ${next.name} (${money(next.total)})?`, 'Next bill'))
            billDialog(next, y, m, { queue: true });
        }, 900);
      } else refresh();
    } catch (e){ sent = false; err('The bill could not be recorded: ' + friendly(e.original || e)); }
  };
  wa.onclick = (ev) => record('WHATSAPP', ev);
  sms.onclick = (ev) => record('SMS', ev);
  copy.onclick = async () => {
    try { await navigator.clipboard.writeText(text.value); } catch { text.select(); document.execCommand && document.execCommand('copy'); }
    await record('COPY');
  };
  img.onclick = async () => {
    const blob = await receiptImage({
      building: s.building_name || 'Building', address: s.address || '',
      title: `Service charge bill — ${monthName(y, m)}`, noLabel: 'Bill for', receiptNo: monthName(y, m),
      date: '', flat: payer.flats.map(f => f.flat_number).join(', '), from: payer.name || '',
      lines: payer.flats.flatMap(f => [
        ...(Number(f.this_month) ? [{ label:`${f.flat_number} · ${monthName(y, m)}`, value: money(f.this_month_due, { bare:true }) }] : []),
        ...(Number(f.previous_due) > 0 ? [{ label:`${f.flat_number} · earlier dues`, value: money(f.previous_due, { bare:true }) }] : [])]),
      amountLabel: `Pay by ${fdate(payer.due_date)}`, amount: money(payer.total),
      footer: s.reminder_how_to_pay ? String(s.reminder_how_to_pay).slice(0, 70) : 'Thank you.'
    });
    const how = await shareFile(blob, `bill-${y}-${String(m).padStart(2,'0')}-${(payer.name || 'payer').replace(/\W+/g, '-')}.png`, 'image/png',
                                `${s.building_name || ''} — service charge bill ${monthName(y, m)}`);
    if (how !== 'cancelled') await record('IMAGE');
  };
  const canSend = can('charges', 'add');
  if (!canSend){ wa.hidden = true; sms.hidden = true; copy.hidden = true; img.hidden = true; }
  const body = el('div', { class:'rem' },
    el('div', { class:'rem-who' }, el('p', {}, el('span', { class:'muted', text:'To ' }), el('b', { text: payer.name || '' }),
      payer.mobile ? el('span', { class:'mono', text:` · ${payer.mobile}` }) : null),
      !digits ? el('p', { class:'warn-line', text:'No WhatsApp-ready number on file; WhatsApp will ask whom to send to.' }) : null),
    el('p', {}, el('span', { class:'muted', text:'Total payable ' }), el('b', { class:'num', text: money(payer.total) }),
      el('span', { class:'muted', text:` by ${fdate(payer.due_date)}` })),
    field('Language', langI),
    field('Bill', text, { hint:'Written from Settings → Monthly bill message. You can change anything before sending.' }),
    el('div', { class:'btn-row' }, wa, sms, img, copy));
  return modal({ title:`Bill — ${payer.name || ''} — ${monthName(y, m)}`, body, actions:[{ label:'Close', value:null }],
                 onMount: (box, close) => { closeDialog = close; } });
}
