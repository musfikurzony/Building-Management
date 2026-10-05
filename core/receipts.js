/* =====================================================================
   receipts.js — showing, sending and re-sending a service-charge receipt.

   A receipt is never stored as a file. It is drawn again, every time,
   from the payment record — which is permanent, and cannot be edited
   (a mistake is reversed, not changed). So a receipt from last month or
   three years ago looks exactly as it did the day it was issued, costs
   no storage, and is always available to send again. A reversed payment
   still opens, stamped REVERSED, so nobody can pass it off as proof.
   ===================================================================== */

import { el, money, fdate, monthName, ok, err, modal, table, emptyState, badge } from './ui.js';
import { q, one, rpc, logEvent } from './db.js';
import { ref, settings, can } from './store.js';
import { receiptImage, receiptPdf, shareFile } from './receipt.js';
import { wireWhatsAppLink } from './whatsapp.js';
import { attachmentsCard } from './attachments.js';

const methodName = (m) => String(m || '').replace(/_/g, ' ');

/** Everything a receipt shows, read fresh from the database. */
async function receiptData(paymentId){
  const p = await one('payments', b => b.eq('id', paymentId));
  if (!p) return null;
  const [flats, allocs, charges, dues] = await Promise.all([
    ref('flats'),
    q('payment_allocations', b => b.eq('payment_id', paymentId)).catch(() => []),
    q('v_flat_charges', b => b.eq('flat_id', p.flat_id)).catch(() => []),
    q('v_flat_dues', b => b.eq('flat_id', p.flat_id)).catch(() => [])
  ]);
  const flat = flats.find(f => f.id === p.flat_id) || {};
  const d = dues[0] || {};
  const lines = allocs.map(a => {
    const c = charges.find(x => x.id === a.flat_charge_id);
    return { label: c ? (c.charge_source === 'OPENING' ? 'Balance brought forward'
                                                       : monthName(c.period_year, c.period_month)) : 'Applied',
             amount: Number(a.amount) };
  });
  const allocated = lines.reduce((t, l) => t + l.amount, 0);
  const advance = p.status === 'ACTIVE' ? Number(p.amount) - allocated : 0;

  // Who to send it to: the person who pays for the flat now. normalize_mobile
  // arrives with 085; without it WhatsApp simply asks for the contact.
  let digits = null;
  if (d.billed_mobile){
    try { digits = await rpc('normalize_mobile', { p: d.billed_mobile }, { silent: true }); } catch {}
  }
  return { p, flat, lines, advance, to: d.billed_to || p.payer_name || '', mobile: d.billed_mobile || '', digits };
}

/** The picture, with every field the on-screen receipt has. */
async function drawReceipt(r){
  const s = settings();
  return receiptImage({
    building:  s.building_name || 'Building',
    address:   s.address || '',
    title:     'Service charge receipt',
    receiptNo: r.p.receipt_no,
    date:      fdate(r.p.payment_date),
    flat:      r.flat.flat_number || '',
    from:      r.p.payer_name || '',
    method:    methodName(r.p.method),
    reference: r.p.reference_no || '',
    amount:    money(r.p.amount),
    advance:   r.advance > 0.001 ? `Kept as advance: ${money(r.advance)}` : '',
    lines:     r.lines.map(l => ({ label: l.label, value: money(l.amount, { bare:true }) })),
    footer:    'Thank you.',
    stamp:     r.p.status === 'REVERSED' ? 'REVERSED' : ''
  });
}

function receiptText(r){
  const s = settings();
  return [
    `${s.building_name || 'Building'} — service charge receipt`,
    `Receipt: ${r.p.receipt_no}`,
    `Flat: ${r.flat.flat_number || ''}`,
    `Date: ${fdate(r.p.payment_date)}`,
    `Amount received: ${money(r.p.amount)}`,
    r.lines.length ? `For: ${r.lines.map(l => l.label).join(', ')}` : null,
    r.advance > 0.001 ? `Kept as advance: ${money(r.advance)}` : null,
    'Thank you.'
  ].filter(Boolean).join('\n');
}

/**
 * The receipt dialog. Opened right after a payment is recorded, and again
 * from any payment in the Payments list, the flat's page or its statement.
 */
export async function receiptDialog(paymentId){
  const r = await receiptData(paymentId);
  if (!r) return err('That receipt could not be found.');
  const s = settings();
  const { p } = r;
  const reversed = p.status === 'REVERSED';
  const fileBase = `receipt-${p.receipt_no || 'payment'}`;

  const view = el('div', { id:'receiptBody', class:'receipt-view' + (reversed ? ' is-reversed' : '') },
    el('div', { class:'center', style:'margin-bottom:.6rem' },
      el('h3', { style:'margin:0', text: s.building_name || 'Building' }),
      el('div', { class:'small muted', text: s.address || '' }),
      el('div', { class:'small', style:'margin-top:.3rem', text:'Service charge receipt' })),
    reversed ? el('p', { class:'warn-line', text:`This payment was reversed${p.reversal_reason ? ' — ' + p.reversal_reason : ''}. The receipt is kept for the record and is stamped REVERSED.` }) : null,
    el('dl', { class:'dl' },
      el('dt', { text:'Receipt no' }), el('dd', { class:'mono', text: p.receipt_no }),
      el('dt', { text:'Date' }),       el('dd', { text: fdate(p.payment_date) }),
      el('dt', { text:'Flat' }),       el('dd', { text: r.flat.flat_number || '' }),
      p.payer_name ? el('dt', { text:'Received from' }) : null,
      p.payer_name ? el('dd', { text: p.payer_name }) : null,
      el('dt', { text:'Received' }),   el('dd', { class:'num', style:'font-weight:700', text: money(p.amount) }),
      el('dt', { text:'Method' }),     el('dd', { text: methodName(p.method) }),
      p.reference_no ? el('dt', { text:'Reference' }) : null,
      p.reference_no ? el('dd', { text: p.reference_no }) : null),
    r.lines.length ? el('div', { class:'tablewrap', style:'margin-top:.8rem' },
      el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Applied to'), el('th', { class:'num' }, 'Amount'))),
        el('tbody', {}, r.lines.map(l => el('tr', {}, el('td', { text: l.label }),
                                                  el('td', { class:'num', text: money(l.amount, { bare:true }) })))))) : null,
    r.advance > 0.001 ? el('p', { class:'small', text: `Kept as advance: ${money(r.advance)}` }) : null);

  const note = (how) => logEvent('NOTE', { module:'charges', table:'payments', id: p.id, label: p.receipt_no,
                                          detail: `Receipt ${p.receipt_no} ${how}` });
  const busy = (btn, fn) => async () => {
    if (btn.disabled) return;
    btn.disabled = true;
    try { await fn(); } catch (e){ err('Could not make the receipt: ' + (e.message || e)); }
    finally { btn.disabled = false; }
  };

  const shareText = `${s.building_name || 'Building'} — service charge receipt ${p.receipt_no}`;

  const imgBtn = el('button', { class:'btn primary', type:'button', text:'Send as image' });
  imgBtn.onclick = busy(imgBtn, async () => {
    const how = await shareFile(await drawReceipt(r), `${fileBase}.png`, 'image/png', shareText);
    if (how === 'shared')     { ok('Receipt shared'); note('shared as an image'); }
    if (how === 'downloaded') { ok('Receipt image saved — attach it in WhatsApp'); note('saved as an image'); }
  });

  const pdfBtn = el('button', { class:'btn', type:'button', text:'Receipt PDF' });
  pdfBtn.onclick = busy(pdfBtn, async () => {
    const pdf = await receiptPdf(await drawReceipt(r));
    const how = await shareFile(pdf, `${fileBase}.pdf`, 'application/pdf', shareText);
    if (how === 'shared')     { ok('Receipt PDF shared'); note('shared as a PDF'); }
    if (how === 'downloaded') { ok('Receipt PDF saved'); note('saved as a PDF'); }
  });

  // Text straight into the billed person's chat. A real link, so a phone
  // opens the installed WhatsApp rather than a download page.
  const waText = el('a', { class:'btn', text: r.digits ? `Text to ${r.to.split(' ')[0] || 'WhatsApp'}` : 'Send as text' });
  wireWhatsAppLink(waText, r.digits, receiptText(r));
  waText.addEventListener('click', () => note('sent as WhatsApp text'));

  const printBtn = el('button', { class:'btn', type:'button', text:'Print' });
  printBtn.onclick = () => {
    document.body.classList.add('printing-receipt');
    const done = () => { document.body.classList.remove('printing-receipt'); window.removeEventListener('afterprint', done); };
    window.addEventListener('afterprint', done);
    window.print();
    setTimeout(done, 1500);   // some phones never fire afterprint
  };

  const actions = el('div', { class:'btn-row receipt-actions' });
  if (reversed) actions.append(printBtn);
  else actions.append(imgBtn, pdfBtn, waText, printBtn);

  const who = !reversed && r.to
    ? el('p', { class:'small muted', text: `Bills for this flat go to ${r.to}${r.mobile ? ' · ' + r.mobile : ''}.` +
        (r.digits ? '' : ' There is no WhatsApp-ready number on file, so WhatsApp will ask whom to send to.') })
    : null;

  // The payment's proof (a bKash screenshot, a deposit slip) — for the
  // committee's file, not part of the receipt the flat receives.
  const proof = can('charges', 'view') ? attachmentsCard({
    entityTable: 'payments', entityId: p.id, bucket: 'bms-receipts',
    canAdd: can('charges', 'add') && !reversed, title: 'Proof of payment',
    hint: 'A bKash or bank screenshot, or a deposit slip. Kept with the payment; not sent to the flat.',
    entryDate: p.payment_date }) : null;

  return modal({ title: `Receipt ${p.receipt_no || ''}`, body: el('div', {}, view, who, actions, proof),
                 actions: [{ label:'Done', value:null }] });
}

/**
 * Every receipt for one flat, newest first — for sending one again.
 * Shown on the flat's page and on its statement.
 */
export async function receiptsCard(flatId, { limit = 24 } = {}){
  const card = el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Receipts' })));
  if (!can('charges','view')) return null;
  const rows = await q('payments', b => b.eq('flat_id', flatId)
    .order('payment_date', { ascending:false }).order('created_at', { ascending:false }).limit(limit)).catch(() => []);
  if (!rows.length){ card.append(emptyState('No payments recorded for this flat yet.')); return card; }
  card.append(el('p', { class:'small muted', text:'Tap a receipt to see it and send it again — as a picture, a PDF or a WhatsApp message.' }));
  card.append(table([
    { label:'Receipt', primary:true, cls:'mono', key:'receipt_no' },
    { label:'Date', fmt: r => fdate(r.payment_date) },
    { label:'Amount', cls:'num', fmt: r => money(r.amount, { bare:true }) },
    { label:'Method', fmt: r => methodName(r.method) },
    { label:'Status', fmt: r => badge(r.status) },
    { label:'', fmt: r => el('button', { class:'btn small', text:'Open',
        onclick: (e) => { e.stopPropagation(); receiptDialog(r.id); } }) }
  ], rows, { onRow: r => receiptDialog(r.id) }));
  return card;
}
