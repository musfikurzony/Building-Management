/* =====================================================================
   reminder.js — asking a flat to pay, politely, and remembering that we
   asked.

   The figures always come from reminder_context(), read at the moment the
   dialog opens — never from the table that was on screen. A list loaded an
   hour ago can still show a flat as unpaid after its payment was recorded,
   and the one thing this feature must not do is chase someone who has
   just paid.

   Sending is one tap. The dialog opens WhatsApp (or the SMS app) with the
   number and message filled in, and records the reminder as it does. A
   browser cannot see whether Send was then pressed, so a record means
   "handed to WhatsApp", which is all that can honestly be claimed.
   ===================================================================== */

import { el, field, select, money, fdate, fdatetime, ok, err, modal, table, emptyState } from './ui.js';
import { rpc, q, isMissingObject, friendly } from './db.js';
import { can, settings } from './store.js';
import { refresh } from './router.js';
import { wireWhatsAppLink } from './whatsapp.js';
import { receiptImage } from './receipt.js';
import { slipPreview } from './slip.js';

export const TONES = [
  { value:'GENTLE',    label:'Gentle — a first reminder' },
  { value:'FOLLOW_UP', label:'Follow-up — the second' },
  { value:'FIRM',      label:'Firm but courteous — third and after' }
];
export const TONE_NAME = { GENTLE:'Gentle', FOLLOW_UP:'Follow-up', FIRM:'Firm' };
export const LANGS = [{ value:'en', label:'English' }, { value:'bn', label:'বাংলা' }];

/* ---------------------------------------------------------------------
   Words and numbers in two languages.
   --------------------------------------------------------------------- */
const EN_MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const BN_MONTHS = ['জানুয়ারি','ফেব্রুয়ারি','মার্চ','এপ্রিল','মে','জুন','জুলাই','আগস্ট',
                   'সেপ্টেম্বর','অক্টোবর','নভেম্বর','ডিসেম্বর'];
const BN_DIGITS = '০১২৩৪৫৬৭৮৯';
const bn = (s) => String(s).replace(/[0-9]/g, d => BN_DIGITS[d]);

/** 5000 → "5,000"; 4500.5 → "4,500.50"; in Bangla digits for Bangla. */
export function amountText(n, lang){
  const v = Number(n || 0);
  const t = v.toLocaleString('en-IN', {
    minimumFractionDigits: Number.isInteger(v) ? 0 : 2, maximumFractionDigits: 2 });
  return lang === 'bn' ? bn(t) : t;
}

export function monthLabel(y, m, lang){
  return lang === 'bn' ? `${BN_MONTHS[m-1]} ${bn(y)}` : `${EN_MONTHS[m-1]} ${y}`;
}

/**
 * The months owed, as a person would say them: "Oct 2026", "Aug–Oct 2026",
 * "Nov 2025–Jan 2026", or a list when there are gaps. A balance carried in
 * from before the system started reads as "earlier balance".
 */
export function monthsText(months, lang){
  const list = (months || []);
  const opening = list.some(m => m.source === 'OPENING');
  const idx = list.filter(m => m.source !== 'OPENING')
                  .map(m => m.year * 12 + (m.month - 1)).sort((a,b) => a - b);
  const runs = [];
  for (const i of idx){
    const last = runs[runs.length - 1];
    if (last && i === last[1] + 1) last[1] = i; else if (!last || i !== last[1]) runs.push([i, i]);
  }
  const ym = (i) => [Math.floor(i / 12), (i % 12) + 1];
  const parts = runs.map(([a, b]) => {
    const [ya, ma] = ym(a), [yb, mb] = ym(b);
    if (a === b) return monthLabel(ya, ma, lang);
    if (ya === yb){
      const ma_ = lang === 'bn' ? BN_MONTHS[ma-1] : EN_MONTHS[ma-1];
      return `${ma_}–${monthLabel(yb, mb, lang)}`;
    }
    return `${monthLabel(ya, ma, lang)}–${monthLabel(yb, mb, lang)}`;
  });
  if (opening) parts.unshift(lang === 'bn' ? 'পূর্বের বকেয়া' : 'earlier balance');
  return parts.join(', ');
}

export function dateText(iso, lang){
  if (!iso) return '';
  const d = new Date(String(iso).slice(0,10) + 'T00:00:00');
  return lang === 'bn'
    ? `${bn(d.getDate())} ${BN_MONTHS[d.getMonth()]} ${bn(d.getFullYear())}`
    : `${d.getDate()} ${EN_MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}

/**
 * Fill a template. {how_to_pay} on a line of its own disappears entirely
 * when there are no payment instructions, rather than leaving a blank
 * line where they would have been.
 */
export function fillTemplate(tpl, v){
  const lines = String(tpl || '').split('\n')
    .filter(line => !(line.trim() === '{how_to_pay}' && !String(v.how_to_pay || '').trim()));
  let out = lines.join('\n').replace(/\{(\w+)\}/g, (all, k) => (k in v ? String(v[k] ?? '') : all));
  return out.replace(/\n{3,}/g, '\n\n').trim();
}

/** The placeholder values for one flat, in one language. */
export function valuesFor(ctx, lang){
  const name = (ctx.recipient_name || '').trim();
  return {
    name:       name || (lang === 'bn' ? 'মহোদয়/মহোদয়া' : 'Sir/Madam'),
    flat:       ctx.flat_number || '',
    amount:     amountText(ctx.outstanding, lang),
    months:     monthsText(ctx.months, lang),
    deadline:   dateText(ctx.deadline_date, lang),
    building:   ctx.building_name || '',
    how_to_pay: ctx.how_to_pay || ''
  };
}

export function composeMessage(ctx, tone, lang){
  const tpl = (ctx.templates || {})[`${tone}.${lang}`] || '';
  return fillTemplate(tpl, valuesFor(ctx, lang));
}

const ordinal = (n) => {
  const s = ['th','st','nd','rd'], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
};

/* ---------------------------------------------------------------------
   The dialog.
   --------------------------------------------------------------------- */
export async function reminderDialog(flatId){
  let ctx;
  try {
    ctx = await rpc('reminder_context', { p_flat: flatId }, { silent: true });
  } catch (e){
    const o = e.original || e;
    if (isMissingObject(o)){
      await modal({ title:'Reminders need a database update', body: el('div', {},
        el('p', { text:'This part of the app needs a database update that has not been run yet.' }),
        el('p', { class:'small muted', text:'In Supabase open the SQL Editor and run sql/PATCH.sql (or sql/085_people_reminders.sql on its own). It is safe to run twice. Then reload this page.' })) });
    } else err(friendly(o));
    return false;
  }

  if (!(Number(ctx.outstanding) > 0)){
    ok(`Flat ${ctx.flat_number} owes nothing now — no reminder needed.`);
    refresh();
    return false;
  }

  const relName = ctx.relation === 'TENANT' ? 'tenant' : ctx.relation === 'OWNER' ? 'owner' : '';
  const since   = Number(ctx.reminders_since_payment || 0);
  const flatLink = el('a', { href:`#/flats/${flatId}`, text:'the flat’s page' });

  // Who it goes to — and, if we cannot send to them, why not, in words.
  const who = el('div', { class:'rem-who' });
  if (!ctx.relation){
    who.append(el('p', { class:'warn-line' },
      'Nobody is set to receive the bill for this flat yet. Add the owner or tenant on ', flatLink, '.'));
  } else {
    who.append(el('p', {},
      el('span', { class:'muted', text:'To ' }),
      el('b', { text: ctx.recipient_name || 'unnamed' }),
      el('span', { class:'muted', text: ` (${relName})` }),
      ctx.mobile ? el('span', { class:'mono', text: ` · ${ctx.mobile}` }) : null));
    if (!ctx.mobile_wa){
      who.append(el('p', { class:'warn-line' },
        ctx.mobile
          ? `“${ctx.mobile}” is not a mobile number WhatsApp can use. Correct it on `
          : 'There is no mobile number on file. Add one on ',
        flatLink, ', or open WhatsApp below and choose the contact yourself.'));
    }
  }

  const owes = el('p', {},
    el('span', { class:'muted', text:'Owes ' }),
    el('b', { class:'num', text: money(ctx.outstanding) }),
    el('span', { class:'muted', text: ` for ${monthsText(ctx.months, 'en') || 'earlier months'}` }));

  const history = el('p', { class:'small muted', text:
    since > 0
      ? `Reminded ${since} time${since === 1 ? '' : 's'} since the last payment` +
        (ctx.last_reminded_at ? `, most recently ${fdatetime(ctx.last_reminded_at)}.` : '.')
      : (Number(ctx.reminders_total) > 0
          ? `Not reminded since the last payment (${ctx.reminders_total} earlier reminder${Number(ctx.reminders_total) === 1 ? '' : 's'} on record).`
          : 'Never reminded before.') });

  const toneI = select(TONES.map(t => ({ value:t.value,
      label: t.label + (t.value === ctx.suggested_tone ? '  (suggested)' : '') })),
    { value: ctx.suggested_tone });
  const langI = select(LANGS, { value: ctx.language || 'en' });
  const text  = el('textarea', { rows: 13, maxlength: '2000', class:'rem-text' });
  let edited = false;
  text.oninput = () => { edited = true; syncLinks(); };

  const rewrite = () => { text.value = composeMessage(ctx, toneI.value, langI.value); edited = false; syncLinks(); };
  toneI.onchange = () => {
    if (edited && !confirm('Changing the tone replaces the text you edited. Continue?')){ return; }
    rewrite();
  };
  langI.onchange = () => {
    if (edited && !confirm('Changing the language replaces the text you edited. Continue?')){ return; }
    rewrite();
  };

  // Real links, not buttons that call window.open after an await: a link
  // the person taps is never blocked as a popup, and on a phone it hands
  // straight over to the WhatsApp or Messages app.
  const wa  = el('a', { class:'btn primary' });
  const sms = el('a', { class:'btn', text:'Send as SMS' });
  const copy = el('button', { class:'btn', type:'button', text:'Copy text' });
  const syncLinks = () => {
    const msg = encodeURIComponent(text.value);
    // On a phone this is whatsapp://, which opens the installed app; on a
    // laptop it is wa.me. See core/whatsapp.js for why.
    wireWhatsAppLink(wa, ctx.mobile_wa, text.value);
    wa.textContent = ctx.mobile_wa ? 'Send on WhatsApp' : 'Open WhatsApp (choose the contact)';
    // "?&body=" is understood by both Android and iPhone messaging apps.
    sms.href = ctx.mobile_wa ? `sms:+${ctx.mobile_wa}?&body=${msg}` : '#';
    sms.hidden = !ctx.mobile_wa;
  };

  const canSend = !!ctx.can_send && can('charges','add');
  // The DUE slip: the same reminder as a stamped picture, PDF or print.
  const slip = el('button', { class:'btn', type:'button', text:'DUE slip — preview & send' });
  // The date on the slip: the month's due day (normally the 10th) while it
  // is still ahead, a week from today, a date of your choosing, or none at
  // all. Remembered per flat on this device.
  const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const dueDayDate = new Date(today.getFullYear(), today.getMonth(), Math.min(Number(settings().charge_due_day || 10), 28));
  const dayAhead = dueDayDate >= today;
  const key = `bms.slipDue.${flatId}`;
  let saved = null; try { saved = JSON.parse(localStorage.getItem(key) || 'null'); } catch {}
  const dueI = select([
    { value:'DAY',  label: `By the ${settings().charge_due_day || 10}th — ${fdate(iso(dueDayDate))}${dayAhead ? '' : ' (already passed)'}` },
    { value:'WEEK', label: `In a week — ${fdate(ctx.deadline_date || iso(new Date(today.getTime() + 7 * 864e5)))}` },
    { value:'DATE', label: 'A date I choose' },
    { value:'NONE', label: 'No due date' }], { value: saved?.mode || (dayAhead ? 'DAY' : 'WEEK') });
  const dateI = el('input', { type:'date', value: saved?.date || iso(dueDayDate) });
  const dateBox = field('Pay by', dateI);
  const slipDue = () => dueI.value === 'NONE' ? null : dueI.value === 'DAY' ? iso(dueDayDate)
                      : dueI.value === 'WEEK' ? (ctx.deadline_date || iso(new Date(today.getTime() + 7 * 864e5))) : (dateI.value || null);
  const role = ctx.relation === 'TENANT' ? 'Tenant' : ctx.relation === 'OWNER' ? 'Owner' : '';
  const drawDue = () => { const due = slipDue(); return receiptImage({
    building: ctx.building_name || 'Building', address: settings().address || '',
    title: 'Service charge due', noLabel: 'Date', receiptNo: fdate(iso(today)),
    flat: ctx.flat_number || '', from: ctx.recipient_name ? `${ctx.recipient_name}${role ? ` (${role})` : ''}` : '', fromLabel: 'Bill to',
    lines: (ctx.months || []).map(m => ({ label: m.source === 'OPENING' ? 'Earlier balance' : monthLabel(m.year, m.month, 'en'),
                                          value: money(m.due, { bare:true }) })),
    amountLabel: 'Total due', amount: money(ctx.outstanding),
    note: due ? `Please pay by ${fdate(due)}` : 'Kindly pay at your convenience',
    footer: ctx.how_to_pay ? String(ctx.how_to_pay).slice(0, 70) : 'Thank you.',
    seal: { text:'DUE', sub: due ? `By ${fdate(due)}` : (ctx.months?.length ? monthLabel(ctx.months[ctx.months.length - 1].year, ctx.months[ctx.months.length - 1].month, 'en') : ''),
            top: ctx.building_name || '', color:'red' } }); };
  slip.onclick = () => {
    const controls = el('div', { class:'grid g-form slip-controls' }, field('Due date on this slip', dueI), dateBox);
    const sync = (redraw) => () => {
      dateBox.hidden = dueI.value !== 'DATE';
      try { localStorage.setItem(key, JSON.stringify({ mode: dueI.value, date: dateI.value })); } catch {}
      redraw && redraw();
    };
    dateBox.hidden = dueI.value !== 'DATE';
    return slipPreview({
      title: `DUE slip — flat ${ctx.flat_number}`, draw: drawDue, controls,
      bindRedraw: (redraw) => { dueI.onchange = sync(redraw); dateI.onchange = sync(redraw); },
      fileBase: `due-${ctx.flat_number}-${iso(today)}`,
      shareText: `${ctx.building_name || ''} — service charge due, flat ${ctx.flat_number}`,
      digits: ctx.mobile_wa, text: text.value, toName: ctx.recipient_name,
      note: ctx.recipient_name ? `Goes to ${ctx.recipient_name}${role ? ` (${role})` : ''}${ctx.mobile ? ' · ' + ctx.mobile : ''}.` : null,
      onSent: (ch) => record(ch === 'DOWNLOAD' ? 'IMAGE' : ch) });
  };
  const actions = el('div', { class:'btn-row' }, wa, sms, slip, copy);
  const note = el('p', { class:'hint', text: canSend
    ? 'Sending records this reminder against the flat — who, when, to which number, and these exact words.'
    : 'You can read this, but sending reminders needs permission to record service-charge entries.' });
  if (!canSend){ wa.hidden = true; sms.hidden = true; copy.hidden = true; slip.hidden = true; }

  const body = el('div', { class:'rem' },
    who, owes, history,
    el('div', { class:'grid g-form' }, field('Tone', toneI), field('Language', langI)),
    field('Message', text, { hint:'You can change anything before sending.' }),
    actions, note);

  rewrite();

  let sent = false;
  const record = async (channel, ev) => {
    if (sent){ if (ev) ev.preventDefault(); return; }
    if (!text.value.trim()){ if (ev) ev.preventDefault(); err('The message is empty.'); return; }
    sent = true;
    try {
      const args = { p_flat: flatId, p_channel: channel, p_tone: toneI.value, p_lang: langI.value, p_message: text.value };
      // Before 092 the log knew only WhatsApp, SMS and copy: a slip still counts.
      try { await rpc('log_charge_reminder', args, { silent: true }); }
      catch (e1){
        if (!['IMAGE','PDF','PRINT'].includes(channel) || !/Unknown channel/i.test((e1.original || e1).message || '')) throw e1;
        await rpc('log_charge_reminder', { ...args, p_channel: 'COPY' }, { silent: true });
      }
      const n = since + 1;
      ok(`Reminder recorded — the ${ordinal(n)} since the last payment.`);
      closeDialog && closeDialog(true);
      refresh();
    } catch (e){
      sent = false;
      const o = e.original || e;
      err(channel === 'COPY'
        ? friendly(o)
        : 'WhatsApp opened, but the reminder could not be recorded: ' + friendly(o));
    }
  };

  // The link navigates on its own; recording runs alongside it. The page
  // stays open because the link opens a new tab or the app, so the
  // request completes normally.
  wa.onclick  = (ev) => record('WHATSAPP', ev);
  sms.onclick = (ev) => record('SMS', ev);
  copy.onclick = async () => {
    try { await navigator.clipboard.writeText(text.value); }
    catch { text.select(); document.execCommand && document.execCommand('copy'); }
    await record('COPY');
  };

  let closeDialog = null;
  return modal({ title: `Remind flat ${ctx.flat_number}`, body,
    actions: [{ label:'Close', value:null }],
    onMount: (box, close) => { closeDialog = close; } });
}

/* ---------------------------------------------------------------------
   Summaries for the tables, and the history for one flat.
   --------------------------------------------------------------------- */

/** flat_id → { total, since, last }. Empty, quietly, before 085 is run. */
export async function reminderSummaries(){
  try {
    const rows = await q('v_flat_reminders', b => b, { silent: true });
    return new Map(rows.map(r => [r.flat_id, {
      total: Number(r.reminders_total || 0),
      since: Number(r.reminders_since_payment || 0),
      last:  r.last_reminded_at }]));
  } catch { return new Map(); }
}

/** "2× · 28 Sep" — chased twice since paying, most recently on the 28th. */
export function reminderCell(sum){
  if (!sum || !sum.total) return el('span', { class:'muted', text:'—' });
  const d = sum.last ? new Date(sum.last) : null;
  const when = d ? `${d.getDate()} ${EN_MONTHS[d.getMonth()]}` : '';
  return el('span', { class: sum.since >= 2 ? 'rem-count hot' : 'rem-count',
    title: `${sum.total} reminder${sum.total === 1 ? '' : 's'} in all; ${sum.since} since the last payment`,
    text: `${sum.since}×${when ? ' · ' + when : ''}` });
}

export function remindButton(flatId){
  if (!can('charges','add')) return null;
  return el('button', { class:'btn small', text:'Remind',
    onclick: (e) => { e.stopPropagation(); reminderDialog(flatId); } });
}

export async function reminderHistory(flatId){
  const card = el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Reminders' })));
  let rows;
  try {
    rows = await q('charge_reminders', b => b.eq('flat_id', flatId).order('sent_at', { ascending:false }),
                   { silent: true });
  } catch (e){
    if (isMissingObject(e.original || e)){
      card.append(el('p', { class:'small muted',
        text:'Reminder history appears here once sql/PATCH.sql (or 085_people_reminders.sql) has been run.' }));
      return card;
    }
    card.append(el('p', { class:'small muted', text: friendly(e.original || e) }));
    return card;
  }
  if (!rows.length){ card.append(emptyState('No reminders sent to this flat yet.')); return card; }

  card.append(el('p', { class:'small muted',
    text:`${rows.length} reminder${rows.length === 1 ? '' : 's'} on record. Tap one to read exactly what was sent.` }));
  card.append(table([
    { label:'Sent', primary:true, fmt: r => fdatetime(r.sent_at) },
    { label:'To', fmt: r => r.recipient_name
        ? `${r.recipient_name}${r.relation ? ' (' + r.relation.toLowerCase() + ')' : ''}` : '—' },
    { label:'Number', fmt: r => r.phone || '—' },
    { label:'By', fmt: r => r.channel === 'WHATSAPP' ? 'WhatsApp' : r.channel === 'SMS' ? 'SMS' : 'Copied' },
    { label:'Tone', fmt: r => `${TONE_NAME[r.tone] || r.tone} · ${r.lang === 'bn' ? 'বাংলা' : 'English'}` },
    { label:'Owed then', cls:'num', fmt: r => money(r.amount_due, { bare:true }) },
    { label:'For', fmt: r => r.months || '—' }
  ], rows, { onRow: r => modal({ title:`Sent ${fdatetime(r.sent_at)}`,
      body: el('pre', { class:'rem-sent', text: r.message }) }) }));
  return card;
}

/* ---------------------------------------------------------------------
   One reminder for an owner who pays for several flats.

   A land owner with three unpaid flats gets one message, not three: each
   flat and the months it owes on a line of its own, and the total. The
   reminder is recorded against every flat on it, so each flat's history
   still says how many times it has been chased.
   --------------------------------------------------------------------- */
export async function ownerReminderDialog(ownerId){
  let flats, account;
  try {
    [flats, account] = await Promise.all([
      rpc('owner_flats', { p_owner: ownerId }, { silent:true }),
      rpc('owner_accounts', {}, { silent:true }).then(rows => (rows || []).find(r => r.owner_id === ownerId))
    ]);
  } catch (e){
    const o = e.original || e;
    return err(isMissingObject(o) ? 'Owner reminders need a database update: run sql/PATCH.sql in Supabase.' : friendly(o));
  }
  const owing = (flats || []).filter(f => f.pays && Number(f.outstanding) > 0);
  if (!owing.length){ ok('Nothing is owed on the flats this person pays for.'); return; }

  let ctxs;
  try { ctxs = await Promise.all(owing.map(f => rpc('reminder_context', { p_flat: f.flat_id }, { silent:true }))); }
  catch (e){ return err(friendly(e.original || e)); }
  const first = ctxs[0];
  const order = ['GENTLE','FOLLOW_UP','FIRM'];
  const suggested = ctxs.map(c => c.suggested_tone).sort((a, b) => order.indexOf(b) - order.indexOf(a))[0] || 'GENTLE';
  const since = Math.max(...ctxs.map(c => Number(c.reminders_since_payment || 0)));

  const values = (lang) => {
    const base = valuesFor({ ...first, recipient_name: account?.owner_name || first.recipient_name }, lang);
    const join = (arr) => arr.length < 2 ? arr.join('') :
      arr.slice(0, -1).join(', ') + (lang === 'bn' ? ' ও ' : ' and ') + arr[arr.length - 1];
    return { ...base,
      flat: join(ctxs.map(c => c.flat_number)),
      amount: amountText(account?.outstanding ?? owing.reduce((t, f) => t + Number(f.outstanding), 0), lang),
      months: ctxs.map(c => `${lang === 'bn' ? 'ফ্ল্যাট' : 'Flat'} ${c.flat_number}: ${monthsText(c.months, lang)} — ` +
                            (lang === 'bn' ? `${amountText(c.outstanding, lang)} টাকা` : `Tk ${amountText(c.outstanding, lang)}`)).join('; ') };
  };

  const toneI = select(TONES.map(t => ({ value:t.value, label: t.label + (t.value === suggested ? '  (suggested)' : '') })), { value: suggested });
  const langI = select(LANGS, { value: first.language || 'en' });
  const text  = el('textarea', { rows: 13, maxlength: '2000', class:'rem-text' });
  const wa = el('a', { class:'btn primary' });
  const sms = el('a', { class:'btn', text:'Send as SMS' });
  const copy = el('button', { class:'btn', type:'button', text:'Copy text' });
  const sync = () => {
    wireWhatsAppLink(wa, first.mobile_wa, text.value);
    wa.textContent = first.mobile_wa ? 'Send on WhatsApp' : 'Open WhatsApp (choose the contact)';
    sms.href = first.mobile_wa ? `sms:+${first.mobile_wa}?&body=${encodeURIComponent(text.value)}` : '#';
    sms.textContent = 'Send as SMS'; sms.hidden = !first.mobile_wa;
  };
  const rewrite = () => {
    const tpl = (first.templates || {})[`${toneI.value}.${langI.value}`] || '';
    text.value = fillTemplate(tpl, values(langI.value)); sync();
  };
  text.oninput = sync; toneI.onchange = rewrite; langI.onchange = rewrite;
  rewrite();

  let closeDialog = null, sent = false;
  const record = async (channel, ev) => {
    if (sent){ if (ev) ev.preventDefault(); return; }
    sent = true;
    try {
      for (const c of owing)
        await rpc('log_charge_reminder', { p_flat: c.flat_id, p_channel: channel, p_tone: toneI.value,
                                          p_lang: langI.value, p_message: text.value }, { silent:true });
      ok(`Reminder recorded against ${owing.length} flat${owing.length === 1 ? '' : 's'}.`);
      closeDialog && closeDialog(true);
      refresh();
    } catch (e){ sent = false; err('The reminder could not be recorded: ' + friendly(e.original || e)); }
  };
  wa.onclick = (ev) => record('WHATSAPP', ev);
  sms.onclick = (ev) => record('SMS', ev);
  copy.onclick = async () => {
    try { await navigator.clipboard.writeText(text.value); } catch { text.select(); document.execCommand && document.execCommand('copy'); }
    await record('COPY');
  };

  const canSend = can('charges','add') && ctxs.every(c => c.can_send);
  if (!canSend){ wa.hidden = true; sms.hidden = true; copy.hidden = true; }
  const body = el('div', { class:'rem' },
    el('div', { class:'rem-who' },
      el('p', {}, el('span', { class:'muted', text:'To ' }), el('b', { text: account?.owner_name || first.recipient_name || '' }),
        first.mobile ? el('span', { class:'mono', text:` · ${first.mobile}` }) : null),
      !first.mobile_wa ? el('p', { class:'warn-line', text:'There is no WhatsApp-ready number on file; WhatsApp will ask whom to send to.' }) : null),
    el('ul', { class:'owe-list' }, owing.map(f => el('li', {},
      el('span', { text:`Flat ${f.flat_number}` }), el('b', { class:'num', text: money(f.outstanding) })))),
    el('p', {}, el('span', { class:'muted', text:'Total owed ' }), el('b', { class:'num', text: money(account?.outstanding ?? 0) })),
    el('p', { class:'small muted', text: since > 0 ? `The most-chased of these flats has been reminded ${since} time${since === 1 ? '' : 's'} since its last payment.` : 'None of these flats has been reminded since its last payment.' }),
    el('div', { class:'grid g-form' }, field('Tone', toneI), field('Language', langI)),
    field('Message', text, { hint:'One message for all the flats. You can change anything before sending.' }),
    el('div', { class:'btn-row' }, wa, sms, copy));
  return modal({ title:`Remind ${account?.owner_name || 'owner'} — ${owing.length} flat${owing.length === 1 ? '' : 's'}`, body,
    actions:[{ label:'Close', value:null }], onMount: (box, close) => { closeDialog = close; } });
}
