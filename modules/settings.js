/* Building settings — the values the spec insisted must never be
   hard-coded. Flat count, floors, the default charge, the due day, the
   currency: all of it is a row in a table, editable here. */

import { el, field, select, money, ok, err, table, badge, monthName,
         confirmBox, reasonBox, emptyState, modal } from '../core/ui.js';
import { q, update, insert, rpc, isMissingFunction, friendly } from '../core/db.js';
import { refresh } from '../core/router.js';
import { can, ref, state, settings, invalidate, reloadSettings } from '../core/store.js';
import { TONES, TONE_NAME, LANGS, composeMessage } from '../core/reminder.js';

export async function render(){
  const s = settings();
  const editable = can('settings','edit');
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Settings' }),
    el('p', { class:'sub', text: editable ? 'Changing anything here is recorded in the audit log.' : 'You can see these but not change them.' })));

  const f = {};
  const mk = (key, label, attrs, hint) => {
    f[key] = el('input', Object.assign({ value: s[key] ?? '' }, attrs));
    if (!editable) f[key].disabled = true;
    return field(label, f[key], { hint });
  };

  const accounts = await ref('accounts');
  const cashSel = select(accounts.map(a => ({ value:a.id, label:`${a.name} (${a.kind.toLowerCase()})` })),
                         { value: s.default_cash_account_id, placeholder:'None chosen' });
  if (!editable) cashSel.disabled = true;

  const selfApp = el('input', { type:'checkbox' });
  selfApp.checked = !!s.allow_self_approval;
  if (!editable) selfApp.disabled = true;

  const lateOn = el('input', { type:'checkbox' });
  lateOn.checked = !!s.late_fee_enabled;
  if (!editable) lateOn.disabled = true;
  const lateType = select([{ value:'FIXED', label:'Fixed amount' }, { value:'PERCENT', label:'Percentage of the bill' }],
                          { value: s.late_fee_type });
  if (!editable) lateType.disabled = true;

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'The building' })),
    mk('building_name', 'Building name', { type:'text', maxlength:'120' }),
    mk('address', 'Address', { type:'text', maxlength:'200' }),
    el('div', { class:'grid g-form' },
      mk('floor_count', 'Number of floors', { type:'number', min:'1' }),
      mk('timezone', 'Timezone', { type:'text' }))));

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Service charge' })),
    el('div', { class:'grid g-form' },
      mk('default_service_charge', 'Default monthly charge',
         { type:'number', step:'0.01', min:'0' }, 'Used by any flat that has no rate of its own'),
      mk('charge_due_day', 'Due day of the month', { type:'number', min:'1', max:'28' })),
    el('div', { class:'grid g-form' },
      mk('receipt_prefix', 'Receipt number prefix', { type:'text', maxlength:'8' }),
      mk('fiscal_year_start_month', 'Fiscal year starts in month', { type:'number', min:'1', max:'12' })),
    el('fieldset', {}, el('legend', {}, 'Late fee'),
      el('label', { class:'check' }, lateOn, el('span', { text:'Charge a late fee on overdue service charge' })),
      el('div', { class:'grid g-form' },
        field('Type', lateType),
        mk('late_fee_value', 'Amount or percentage', { type:'number', step:'0.01', min:'0' }),
        mk('late_fee_grace_days', 'Grace days', { type:'number', min:'0' })))));

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Money & approvals' })),
    el('div', { class:'grid g-form' },
      mk('currency_symbol', 'Currency symbol', { type:'text', maxlength:'5' }),
      mk('currency_code', 'Currency code', { type:'text', maxlength:'5' })),
    field('Default cash account', cashSel,
      { hint:'Where an entry with no account chosen lands — the caretaker never sees the bank.' }),
    el('label', { class:'check' }, selfApp,
      el('span', {}, el('b', { text:'Allow a person to approve their own expense' }))),
    el('p', { class:'hint', text:'Leave this off wherever possible. With it on, every self-approval is still recorded in the audit log, but the second pair of eyes is gone.' })));

  if (editable){
    const save = el('button', { class:'btn primary', text:'Save settings' });
    save.onclick = async () => {
      save.disabled = true;
      try {
        await update('building_settings', true, {
          building_name: f.building_name.value.trim() || 'Our Building',
          address: f.address.value.trim() || null,
          floor_count: Number(f.floor_count.value) || 1,
          timezone: f.timezone.value.trim() || 'Asia/Dhaka',
          default_service_charge: Number(f.default_service_charge.value || 0),
          charge_due_day: Math.min(28, Math.max(1, Number(f.charge_due_day.value) || 10)),
          receipt_prefix: f.receipt_prefix.value.trim() || 'RCT',
          fiscal_year_start_month: Math.min(12, Math.max(1, Number(f.fiscal_year_start_month.value) || 1)),
          late_fee_enabled: lateOn.checked,
          late_fee_type: lateType.value,
          late_fee_value: Number(f.late_fee_value.value || 0),
          late_fee_grace_days: Number(f.late_fee_grace_days.value || 0),
          currency_symbol: f.currency_symbol.value.trim() || 'Tk',
          currency_code: f.currency_code.value.trim() || 'BDT',
          default_cash_account_id: cashSel.value || null,
          allow_self_approval: selfApp.checked
        }, 'id');
        // Re-read before re-rendering: this screen draws itself from the
        // cached settings, so refreshing without reloading would show the
        // old values back and look like the save failed.
        await reloadSettings();
        ok('Saved'); refresh();
      } catch { save.disabled = false; }
    };
    page.append(el('div', { class:'btn-row' }, save));
  }

  page.append(await remindersCard());
  page.append(await categoriesCard());
  page.append(await periodsCard());
  page.append(await resetCard());
  return page;
}

/* ---------------------------------------------------------------------
   Starting over.

   Every other screen in this application is built to stop data being
   destroyed. This one destroys it on purpose, which is exactly why it is
   at the bottom, behind a preview, behind a typed word, and visible only
   to a Super Admin. The counts are read from the database rather than
   guessed, because "delete everything" is not a decision anyone should
   make against an estimate.
   --------------------------------------------------------------------- */
async function resetCard(){
  const card = el('section', { class:'card danger-zone' },
    el('div', { class:'card-head' }, el('h2', { text:'Start fresh' })));

  let preview;
  try {
    // silent: the two expected failures below are handled here, and a
    // shared red toast for either of them is noise at best and alarming
    // at worst.
    preview = await rpc('reset_preview', {}, { silent: true });
  } catch (e) {
    // Two different failures used to land in the same empty div, which is
    // how this screen came to show a red error and no button at all: the
    // migration had not been run, and the card treated that exactly like
    // "you are not allowed", disappearing without saying why.
    if (isMissingFunction(e.original || e)){
      card.append(el('p', { class:'small', text:
        'This needs a database update that has not been run yet.' }));
      card.append(el('p', { class:'small muted', text:
        'In Supabase open the SQL Editor and run sql/070_reset.sql — or re-run '
      + 'sql/BUNDLE_all.sql, which includes it and is safe to run twice. Then reload this page.' }));
      return card;
    }
    // Genuinely not a Super Admin: no card. An offer you cannot accept is
    // worse than no offer.
    return el('div');
  }

  const n = (v) => Number(v || 0).toLocaleString('en-IN');
  const e = preview.entries || {}, m = preview.masters || {}, k = preview.kept || {};

  card.append(el('p', { class:'small muted', text:
    'For trying the system out with invented numbers and then clearing them before the building starts using it for real. There is no undo.' }));

  card.append(el('div', { class:'grid g-2' },
    el('div', {},
      el('h3', { text:`Entries — ${n(preview.total_entries)} records` }),
      el('ul', { class:'tick' },
        el('li', { text:`${n(e.transactions)} ledger entries` }),
        el('li', { text:`${n(e.service_charges)} service charges, ${n(e.payments)} payments` }),
        el('li', { text:`${n(e.salary_payments)} salary payments, ${n(e.attendance)} attendance records` }),
        el('li', { text:`${n(e.maintenance_issues)} issues, ${n(e.work_logs)} work logs, ${n(e.generator_runs)} generator runs` }),
        el('li', { text:`${n(e.fund_movements)} fund movements, ${n(e.fixed_deposits)} fixed deposits, ${n(e.budgets)} budgets` }))),
    el('div', {},
      el('h3', { text:`Building records — ${n(preview.total_masters)}` }),
      el('ul', { class:'tick' },
        el('li', { text:`${n(m.flats)} flats and ${n(m.owners)} owners` }),
        el('li', { text:`${n(m.staff)} staff` }),
        el('li', { text:`${n(m.assets)} assets (generator, lift, extinguishers)` }),
        el('li', { text:`${n(m.vendors)} vendors` })))));

  // Built from elements rather than a string of markup. `html:` escapes
  // whatever it is given unless it arrives via the html`` tag — which is
  // the right default, and which quietly rendered "<b>Never removed:</b>"
  // as visible characters when this was written as a plain string.
  card.append(el('p', { class:'small' },
    el('b', { text:'Never removed: ' }),
    `your ${n(k.user_accounts)} user accounts and their roles, the building settings, `
  + `${n(k.departments)} departments and ${n(k.categories)} categories, `
  + `${n(k.bank_accounts)} bank/cash accounts, ${n(k.funds)} funds. `
  + `You cannot lock yourself out with this.`));

  const run = async (scope, title, body) => {
    let word;
    const form = el('div', {},
      el('p', { text: body }),
      el('p', { class:'small muted', text:'This cannot be undone. It is recorded in the audit log under your name.' }),
      field('Type RESET to confirm', (word = el('input', { type:'text', autocomplete:'off', placeholder:'RESET' }))));

    const go = await modal({ title, body: form, actions: [
      { label:'Cancel', value:null },
      { label:'Clear it', kind:'danger',
        validate: () => {
          if (word.value === 'RESET') return true;
          err('Type RESET exactly, in capitals'); word.focus(); return false;
        },
        value: true }
    ]});
    if (!go) return;

    try {
      const res = await rpc('reset_system', { p_scope: scope, p_confirm: 'RESET' });
      invalidate();
      ok(`Cleared ${Number(res.rows_deleted || 0).toLocaleString('en-IN')} records`);
      refresh();
    } catch {}
  };

  const b1 = el('button', { class:'btn danger', text:'Clear all entries' });
  b1.onclick = () => run('entries', 'Clear all entries?',
    `Every transaction, service charge, payment, salary, log and budget will be removed — ${n(preview.total_entries)} records. Your flats, owners, staff and assets stay exactly as they are.`);

  const b2 = el('button', { class:'btn danger', text:'Clear everything' });
  b2.onclick = () => run('all', 'Clear everything?',
    `All ${n(preview.total_entries)} entries, and also ${n(m.flats)} flats, ${n(m.owners)} owners, ${n(m.staff)} staff and ${n(m.assets)} assets — plus the audit history. You would be starting the building's setup again from a blank sheet.`);

  card.append(el('div', { class:'btn-row' }, b1, b2));
  return card;
}

async function periodsCard(){
  const rows = await q('accounting_periods', b => b
    .order('period_year', { ascending:false }).order('period_month', { ascending:false }).limit(24)).catch(() => []);

  const card = el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Accounting periods' })),
    el('p', { class:'small muted', text:'Closing a month freezes it: nothing can be created, edited or dated into it afterwards. That is what makes last year’s report stay the same as last year’s report.' }));

  if (!rows.length){ card.append(emptyState('No periods yet — they appear as soon as the first transaction is recorded.')); return card; }

  card.append(table([
    { label:'Period', primary:true, fmt: r => monthName(r.period_year, r.period_month) },
    { label:'Status', fmt: r => badge(r.status) },
    { label:'Closed', fmt: r => r.closed_at ? new Date(r.closed_at).toLocaleDateString() : '—' },
    { label:'', fmt: r => {
        if (!can('finance','close')) return '';
        if (r.status === 'OPEN'){
          const b = el('button', { class:'btn small', text:'Close' });
          b.onclick = async () => {
            const yes = await confirmBox('Close this month?',
              `${monthName(r.period_year, r.period_month)} will be frozen. Everything in it must already be posted.`, 'Close month');
            if (!yes) return;
            try { await rpc('close_period', { p_year:r.period_year, p_month:r.period_month }); ok('Closed'); refresh(); } catch {}
          };
          return b;
        }
        const b = el('button', { class:'btn small danger', text:'Reopen' });
        b.onclick = async () => {
          const reason = await reasonBox('Reopen this month', 'Why does it need reopening? This is recorded.', 'Reopen');
          if (!reason) return;
          try { await rpc('reopen_period', { p_year:r.period_year, p_month:r.period_month, p_reason:reason }); ok('Reopened'); refresh(); } catch {}
        };
        return b;
      } }
  ], rows));
  return card;
}

/* ---------------------------------------------------------------------
   Categories.

   Until now the 44 seeded categories were all there could ever be: no
   way to add one for something this building actually spends money on,
   and no way to retire one it never will.

   Deleting is deliberately not offered. A category that has been used is
   attached to real transactions, and removing it would either orphan
   them or quietly rewrite what a past month was spent on. Hiding is the
   honest operation — it disappears from every dropdown, and the history
   that used it stays true. The usage count is shown so the difference
   between "never used" and "attached to 60 entries" is visible before
   anyone decides.
   --------------------------------------------------------------------- */
async function categoriesCard(){
  if (!can('settings','view')) return el('div');

  const [depts, cats] = await Promise.all([
    q('departments', b => b.order('sort_order')).catch(() => []),
    q('categories',  b => b.order('name')).catch(() => [])
  ]);
  const editable = can('settings','edit');
  const addable  = can('settings','add');

  const card = el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Income & expense categories' })),
    el('p', { class:'small muted', text:
      'What every entry in the ledger is filed under. Hiding one keeps it off the dropdowns without touching the entries already filed under it.' }));

  const deptName = (id) => (depts.find(d => d.id === id) || {}).name || '—';

  if (addable){
    const b = el('button', { class:'btn primary', text:'＋ New category' });
    b.onclick = () => categoryDialog(null, depts);
    const d = el('button', { class:'btn', text:'＋ New department' });
    d.onclick = () => departmentDialog(depts);
    card.append(el('div', { class:'toolbar' }, b, d));
  }
  card.append(el('p', { class:'small muted', text:
    'Departments are the headings of the monthly report: ' + depts.filter(x => x.is_active).map(x => x.name).join(', ') + '.' }));

  if (!cats.length){ card.append(emptyState('No categories yet.')); return card; }

  card.append(table([
    { label:'Category', primary:true, key:'name' },
    { label:'Department', fmt: c => deptName(c.department_id) },
    { label:'Direction', fmt: c => badge(c.txn_type) },
    { label:'Status', fmt: c => c.is_active
        ? el('span', { class:'badge b-active', text:'in use' })
        : el('span', { class:'badge b-draft',  text:'hidden' }) },
    { label:'', fmt: c => {
        if (!editable) return '';
        const row = el('span', { class:'chips' });
        row.append(el('button', { class:'btn small', text:'Edit',
          onclick: () => categoryDialog(c, depts) }));
        row.append(el('button', { class:'btn small', text: c.is_active ? 'Hide' : 'Show',
          onclick: () => toggleCategory(c) }));
        return row;
      } }
  ], cats.filter(c => c.is_active).concat(cats.filter(c => !c.is_active))));

  return card;
}

async function categoryDialog(cat, depts){
  const name = el('input', { type:'text', maxlength:'60', required:true,
                             value: cat?.name || '', placeholder:'Lift annual maintenance contract' });
  const dept = select(depts.map(d => ({ value:d.id, label:d.name })),
                      { value: cat?.department_id, placeholder:'Choose a department' });
  const kind = select([{ value:'EXPENSE', label:'Expense — money going out' },
                       { value:'INCOME',  label:'Income — money coming in' }],
                      { value: cat?.txn_type || 'EXPENSE' });

  // Changing the direction of a category that is already in use would
  // flip the sign of past entries in every report that groups by it.
  // If category_usage is unavailable — 080_roles.sql not run — we cannot
  // tell a fresh category from one with sixty entries behind it. Lock the
  // direction rather than guess: changing it on a used category flips the
  // sign of past entries in every report that groups by it, and being
  // unable to edit a field is a far smaller problem than that.
  let used = 0, usageKnown = true;
  if (cat){
    try {
      used = await rpc('category_usage', { p_category: cat.id }, { silent: true });
    } catch { usageKnown = false; }
    if (!usageKnown || Number(used) > 0) kind.disabled = true;
  }

  const body = el('div', {},
    field('Name', name, { required:true }),
    field('Department', dept, { required:true,
      hint:'Which part of the building this belongs to. It decides where the cost lands in the reports.' }),
    field('Income or expense', kind,
      !usageKnown
        ? { hint:'Locked until sql/080_roles.sql has been run — without it the app cannot check whether anything is already filed under this category.' }
      : Number(used) > 0
        ? { hint:`Fixed — ${used} entr${Number(used) === 1 ? 'y is' : 'ies are'} already filed under this. Hide it and make a new one instead.` }
        : {}));

  const go = await modal({ title: cat ? 'Edit category' : 'A new category', body, actions:[
    { label:'Cancel', value:null },
    { label: cat ? 'Save' : 'Create', kind:'primary',
      validate: () => {
        if (!name.value.trim()){ err('Give the category a name'); name.focus(); return false; }
        if (!dept.value){ err('Choose a department'); dept.focus(); return false; }
        return true;
      },
      value: true }
  ]});
  if (!go) return;

  const row = { name: name.value.trim(), department_id: dept.value };
  if (!kind.disabled) row.txn_type = kind.value;

  try {
    if (cat) await update('categories', cat.id, row);
    else     await insert('categories', Object.assign({ is_active:true, parent_id:null }, row));
    invalidate('categories');
    ok(cat ? 'Saved' : 'Category created');
    refresh();
  } catch { /* toast shown */ }
}

async function toggleCategory(cat){
  try {
    await update('categories', cat.id, { is_active: !cat.is_active });
    invalidate('categories');
    ok(cat.is_active ? `${cat.name} hidden` : `${cat.name} back in use`);
    refresh();
  } catch { /* toast shown */ }
}

/* ---------------------------------------------------------------------
   Reminder messages — what the Remind button on an unpaid flat sends.

   The settings save on their own button, and only their own columns, so
   this card can never stop the rest of Settings saving (or the other way
   round) — including on a database that has not had 085 yet.
   --------------------------------------------------------------------- */
const PLACEHOLDERS = [
  ['{name}', 'the person who pays (owner or tenant)'],
  ['{flat}', 'flat number'],
  ['{amount}', 'amount owed, e.g. 10,000'],
  ['{months}', 'the months owed, e.g. Aug–Sep 2026'],
  ['{deadline}', 'today plus the days to pay'],
  ['{building}', 'building name'],
  ['{how_to_pay}', 'your payment instructions — the line disappears if they are empty']
];

async function remindersCard(){
  const editable = can('settings','edit');
  const card = el('section', { class:'card', id:'reminder-settings' },
    el('div', { class:'card-head' }, el('h2', { text:'Reminder messages' })),
    el('p', { class:'muted small', text:'What the Remind button sends to a flat that owes service charge. The first reminder after a payment uses the gentle message, the second the follow-up, and every one after that the firm one. The tone and language can still be changed for any single reminder before it is sent.' }));

  let templates;
  try {
    templates = await q('reminder_templates', b => b.order('tone').order('lang'), { silent:true });
  } catch (e){
    if (isMissingFunction(e.original || e)){
      card.append(el('div', { class:'alert normal' }, el('div', { class:'a-body' },
        el('div', { class:'a-title', text:'Reminders need a database update' }),
        el('div', { class:'a-meta', text:'In Supabase open the SQL Editor and run sql/PATCH.sql — it is safe to run twice — then reload this page.' }))));
      return card;
    }
    card.append(el('p', { class:'small muted', text: friendly(e.original || e) }));
    return card;
  }
  const s = settings();

  /* --- the three settings --- */
  const howI = el('textarea', { rows:3, maxlength:'500',
    placeholder:'e.g. bKash 01XXXXXXXXX (Payment), or deposit to the building account at the bank, or pay the manager in cash.' });
  howI.value = s.reminder_how_to_pay || '';
  const langI = select(LANGS, { value: s.reminder_language || 'en' });
  const daysI = el('input', { type:'number', min:'1', max:'60', value: s.reminder_deadline_days ?? 7 });
  for (const i of [howI, langI, daysI]) if (!editable) i.disabled = true;

  card.append(
    field('How to pay', howI, { hint:'Added to every message where {how_to_pay} appears. Leave empty to leave it out.' }),
    el('div', { class:'grid g-form' },
      field('Language to start in', langI),
      field('Days to pay', daysI, { hint:'The firm message asks for payment by today plus this many days.' })));

  if (editable){
    const save = el('button', { class:'btn', text:'Save reminder settings' });
    save.onclick = async () => {
      const days = Number(daysI.value);
      if (!Number.isInteger(days) || days < 1 || days > 60) return err('Days to pay must be a whole number from 1 to 60.');
      save.disabled = true;
      try {
        await update('building_settings', true, {
          reminder_how_to_pay: howI.value.trim() || null,
          reminder_language: langI.value,
          reminder_deadline_days: days
        }, 'id');
        await reloadSettings();
        ok('Reminder settings saved');
        refresh();
      } catch { save.disabled = false; }
    };
    card.append(el('div', { class:'btn-row' }, save));
  }

  /* --- the six messages --- */
  const byKey = new Map(templates.map(t => [`${t.tone}.${t.lang}`, t]));
  const choices = [];
  for (const t of TONES) for (const l of LANGS)
    if (byKey.has(`${t.value}.${l.value}`))
      choices.push({ value:`${t.value}.${l.value}`,
        label:`${TONE_NAME[t.value]} — ${l.value === 'bn' ? 'Bangla' : 'English'}${byKey.get(`${t.value}.${l.value}`).body !== byKey.get(`${t.value}.${l.value}`).default_body ? ' (edited)' : ''}` });

  const pick = select(choices, { value: choices[0]?.value });
  const body = el('textarea', { rows:12, class:'rem-text', maxlength:'2000' });
  if (!editable) body.readOnly = true;
  const state_ = el('span', { class:'small muted' });
  const preview = el('pre', { class:'rem-sent' });

  // A pretend flat, so the preview reads like a real message.
  const now_ = new Date();
  const ym = (k) => { const d = new Date(now_.getFullYear(), now_.getMonth() - k, 1); return { year:d.getFullYear(), month:d.getMonth()+1, source:'MONTHLY', due:5000 }; };
  const deadline = new Date(now_.getTime() + (Number(daysI.value) || 7) * 86400000);
  const sampleCtx = () => ({
    recipient_name: 'Mr. Karim', flat_number: 'A-101', outstanding: 10000,
    months: [ym(1), ym(0)], deadline_date: deadline.toISOString().slice(0,10),
    building_name: s.building_name || 'Our Building', how_to_pay: howI.value.trim(),
    templates: { [pick.value]: body.value }
  });
  const paintPreview = () => {
    const [tone, lang] = pick.value.split('.');
    preview.textContent = composeMessage(sampleCtx(), tone, lang);
    const t = byKey.get(pick.value);
    state_.textContent = body.value === t.default_body ? 'Original wording' : (body.value === t.body ? 'Your edited wording' : 'Not saved yet');
  };
  const load = () => { body.value = byKey.get(pick.value)?.body || ''; paintPreview(); };
  pick.onchange = load;
  body.oninput = paintPreview;
  howI.addEventListener('input', paintPreview);

  const chips = el('div', { class:'chips' },
    PLACEHOLDERS.map(([tok, what]) => el('button', { type:'button', class:'chip', title: what, text: tok, disabled: !editable,
      onclick: () => {
        const a = body.selectionStart ?? body.value.length, b = body.selectionEnd ?? a;
        body.value = body.value.slice(0, a) + tok + body.value.slice(b);
        body.focus(); body.selectionStart = body.selectionEnd = a + tok.length;
        paintPreview();
      } })));

  card.append(el('h3', { text:'The messages', style:'margin:1.4rem 0 .5rem;padding-top:1rem;border-top:1px solid var(--line-soft)' }),
    field('Message', pick),
    el('div', { class:'field' }, el('span', {}, 'Wording ', state_), body),
    el('p', { class:'hint', text:'Tap a word in braces to insert it where the cursor is. It is replaced with the real value when a reminder is sent.' }),
    chips,
    el('details', { class:'ph-help' }, el('summary', { text:'What each one becomes' }),
      el('ul', {}, PLACEHOLDERS.map(([tok, what]) => el('li', {}, el('code', { text: tok }), ` — ${what}`)))),
    el('div', { class:'field' }, el('span', { text:'Preview (a made-up flat owing two months)' }), preview));

  if (editable){
    const saveMsg = el('button', { class:'btn primary', text:'Save this message' });
    saveMsg.onclick = async () => {
      const text = body.value.replace(/\r\n/g, '\n');
      if (!text.trim()) return err('A message cannot be empty. Use "Restore original" to go back to the wording it came with.');
      if (!text.includes('{amount}') &&
          !await confirmBox('No amount in the message', 'This message does not contain {amount}, so it will not say how much is owed. Save it anyway?', 'Save anyway'))
        return;
      const t = byKey.get(pick.value);
      saveMsg.disabled = true;
      try {
        await update('reminder_templates', t.id, { body: text });
        t.body = text;
        ok(`${pick.selectedOptions[0].textContent.replace(' (edited)', '')} message saved`);
        refresh();
      } catch { saveMsg.disabled = false; }
    };
    const restore = el('button', { class:'btn', text:'Restore original' });
    restore.onclick = async () => {
      const t = byKey.get(pick.value);
      if (t.body === t.default_body && body.value === t.default_body) return ok('This message already has its original wording.');
      if (!await confirmBox('Restore the original wording?', 'Your wording for this message will be replaced with the one it came with.', 'Restore')) return;
      try {
        await update('reminder_templates', t.id, { body: t.default_body });
        ok('Original wording restored');
        refresh();
      } catch { /* toast */ }
    };
    card.append(el('div', { class:'btn-row' }, saveMsg, restore));
  }
  load();
  return card;
}

/** A department is a heading on every report. Adding one is cheap; they
    are never deleted, because entries already filed under one keep it. */
async function departmentDialog(depts){
  const name = el('input', { type:'text', maxlength:'60', required:true, placeholder:'e.g. Water pump, Community hall' });
  const res = await modal({ title:'New department', body: el('div', {},
      field('Name', name, { required:true, hint:'Appears as its own heading in Income and Expense by department.' })),
    actions:[{ label:'Cancel', value:null }, { label:'Create', kind:'primary', value:true,
      validate: () => { if (!name.value.trim()){ err('A name is required.'); return false; } return true; } }] });
  if (!res) return;
  const n = name.value.trim();
  if (depts.some(d => d.name.toLowerCase() === n.toLowerCase())) return err(`There is already a department called ${n}.`);
  let code = n.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 24) || 'DEPT';
  if (depts.some(d => d.code === code)) code = (code.slice(0, 20) + '_' + Date.now().toString(36).slice(-3)).toUpperCase();
  const sort = Math.max(0, ...depts.filter(d => d.sort_order < 900).map(d => d.sort_order)) + 10;
  try {
    await insert('departments', { code, name: n, sort_order: sort });
    invalidate('departments', 'categories');
    ok(`Department ${n} created. Add its categories next.`);
    refresh();
  } catch { /* toast */ }
}
