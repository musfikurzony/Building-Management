/* Flats, the people in them, and who pays.

   A flat has an owner and may have a tenant; exactly one of them receives
   the service-charge bill. In this building that is often the tenant —
   owners who live elsewhere let the flat and the tenant pays the building
   directly — so "who lives here" and "who pays" are separate questions,
   answered separately on screen.

   Every change of person goes through a database function
   (set_flat_owner, set_flat_tenant, end_tenancy, set_billed_party). The
   screen used to write occupancy rows itself, and in doing so it ended the
   owner's ownership whenever a tenant was linked. */

import { el, field, select, money, num, fdate, table, emptyState, ok, err, modal,
         confirmBox, reasonBox, monthName, downloadCSV, todayISO, badge, stat } from '../core/ui.js';
import { q, one, insert, update, rpc, logEvent, isMissingObject, friendly } from '../core/db.js';
import { can, ref, invalidate, settings } from '../core/store.js';
import { go, refresh } from '../core/router.js';
import { reminderDialog, reminderHistory, reminderSummaries } from '../core/reminder.js';
import { receiptsCard } from '../core/receipts.js';
import { groupPaymentDialog } from './billing.js';
import { activePeople, personSelect, newPersonDialog, duplicatesCard, fixDialog } from '../core/people.js';

export async function render({ params }){
  if (params[0] === 'owners') return peopleView();
  if (params[0] === 'setup')  return setupView();
  if (params[0]){
    if (!/^[0-9a-f-]{36}$/i.test(params[0])) return emptyState('That link does not point to a flat.');
    return flatPage(params[0]);
  }
  return flatsView();
}

/** v_flat_people arrives with 085. Before that, an empty list and a flag,
    so the rest of the screen keeps working and says what to run. */
async function peopleRows(build = (b) => b){
  try { return { rows: await q('v_flat_people', build, { silent:true }), missing:false }; }
  catch (e){ if (isMissingObject(e.original || e)) return { rows: [], missing: true }; throw e; }
}

const needsUpdate = (what) => el('div', { class:'alert normal' }, el('div', { class:'a-body' },
  el('div', { class:'a-title', text:`${what} needs a database update` }),
  el('div', { class:'a-meta', text:'In Supabase open the SQL Editor and run sql/PATCH.sql — it is safe to run twice — then reload this page.' })));

/* ==================================================================
   THE LIST
   ================================================================== */
async function flatsView(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' }, el('h1', { text:'Flats & owners' })));

  const [flats, dues, people] = await Promise.all([
    ref('flats', true), q('v_flat_dues').catch(() => []), peopleRows()]);
  const dueOf = (id) => dues.find(d => d.flat_id === id) || {};
  const pplOf = (id) => people.rows.find(p => p.flat_id === id) || {};
  const s = settings();

  const active = flats.filter(f => f.status === 'ACTIVE');
  const monthly = active.reduce((t,f) => t + Number(f.service_charge ?? s.default_service_charge ?? 0), 0);
  const let_ = people.rows.filter(p => p.tenant_id).length;

  page.append(el('div', { class:'grid g-stats' },
    stat('Flats', num(flats.length), `${active.length} active`),
    stat('Let to tenants', people.missing ? '—' : num(let_), people.missing ? '' : `${num(active.length - let_)} lived in by owners`),
    stat('Monthly billing', money(monthly), 'if every active flat is billed'),
    stat('Default rate', money(s.default_service_charge), 'used when a flat has none')));
  if (people.missing) page.append(needsUpdate('Showing tenants'));

  const bar = el('div', { class:'toolbar' });
  if (can('flats','add')){
    bar.append(el('button', { class:'btn primary', text:'＋ Add flat', onclick: () => flatDialog(null) }));
  }
  bar.append(el('a', { class:'btn', href:'#/flats/setup', text:'Who owns & who pays' }));
  bar.append(el('a', { class:'btn', href:'#/flats/owners', text:'People' }));
  const search = el('input', { type:'search', placeholder:'Search flat, owner or tenant…' });
  bar.append(el('div', { class:'grow' }, search));
  bar.append(el('span', { class:'spacer' }));

  // Who pays, with the relationship said out loud: "Rahim (tenant)".
  const billedName = (f) => {
    const p = pplOf(f.id);
    if (p.billed_relation === 'TENANT') return `${p.tenant_name} (tenant)`;
    if (p.billed_relation === 'OWNER')  return p.owner_name;
    return dueOf(f.id).billed_to || '';
  };
  const billedMobile = (f) => {
    const p = pplOf(f.id);
    if (p.billed_relation === 'TENANT') return p.tenant_mobile;
    if (p.billed_relation === 'OWNER')  return p.owner_mobile;
    return dueOf(f.id).billed_mobile;
  };

  const cols = [
    { label:'Flat', primary:true, key:'flat_number' },
    { label:'Floor', cls:'num', key:'floor' },
    { label:'Monthly charge', cls:'num', csv: f => f.service_charge ?? s.default_service_charge,
      fmt: f => money(f.service_charge ?? s.default_service_charge, { bare:true }) + (f.service_charge ? '' : ' *') },
    { label:'Owner', fmt: f => pplOf(f.id).owner_name || '—', csv: f => pplOf(f.id).owner_name },
    { label:'Pays', fmt: f => billedName(f) || '—', csv: f => billedName(f) },
    { label:'Mobile', fmt: f => billedMobile(f) || '—', csv: f => billedMobile(f) },
    { label:'Outstanding', cls:'num', csv: f => dueOf(f.id).outstanding || 0,
      fmt: f => money(dueOf(f.id).outstanding || 0, { bare:true }) },
    { label:'Status', fmt: f => badge(f.status), csv: f => f.status },
    { label:'', fmt: f => can('flats','edit')
        ? el('button', { class:'btn small', text:'Edit',
            onclick: (e) => { e.stopPropagation(); flatDialog(f); } })
        : '' }
  ];

  if (can('flats','export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV('flats.csv', cols.slice(0, -1), flats); logEvent('EXPORT', { module:'flats' });
    }}));
  page.append(bar);

  const host = el('div', {});
  const paint = () => {
    const term = search.value.trim().toLowerCase();
    const list = term ? flats.filter(f => {
      const p = pplOf(f.id);
      return [f.flat_number, p.owner_name, p.tenant_name, dueOf(f.id).billed_to]
        .some(x => String(x || '').toLowerCase().includes(term));
    }) : flats;
    host.replaceChildren(
      table(cols, list, {
        onRow: f => go('#/flats/' + f.id),
        empty: flats.length ? 'No flat matches that search.'
                            : 'No flats yet. Add them one at a time, or paste the list below.' }),
      el('p', { class:'hint', text:'* uses the building default rate. Tap a flat to see its owner, tenant, payments and reminders.' }));
  };
  search.oninput = paint;
  paint();
  page.append(host);

  if (can('flats','add') && !flats.length){
    page.append(el('div', { class:'card' },
      el('h3', { text:'Add several flats at once' }),
      el('p', { class:'muted small', text:'Paste one flat per line as: flat number, floor, monthly charge. Leave the charge blank to use the building default.' }),
      bulkAdder()));
  }
  return page;
}

function bulkAdder(){
  const box = el('textarea', { rows:6, placeholder:'A-101, 1, 5000\nA-102, 1, 4500\nA-103, 1' });
  const btn = el('button', { class:'btn primary', text:'Create these flats' });
  btn.onclick = async () => {
    const lines = box.value.split('\n').map(l => l.trim()).filter(Boolean);
    if (!lines.length) return err('Nothing to add.');
    const rows = [];
    for (const line of lines){
      const [numRaw, floorRaw, chargeRaw] = line.split(',').map(x => (x || '').trim());
      if (!numRaw || !floorRaw) return err(`Could not read this line: ${line}`);
      const floor = Number(floorRaw);
      if (!Number.isInteger(floor) || floor < 0) return err(`Floor must be a whole number: ${line}`);
      const charge = chargeRaw === '' || chargeRaw === undefined ? null : Number(chargeRaw);
      if (charge !== null && !(charge >= 0)) return err(`Charge must be a number: ${line}`);
      rows.push({ flat_number: numRaw, floor, service_charge: charge });
    }
    btn.disabled = true;
    let made = 0;
    for (const r of rows){
      try { await insert('flats', r); made++; } catch { /* the toast explains */ }
    }
    invalidate('flats');
    ok(`${made} flat${made === 1 ? '' : 's'} created.`);
    refresh();
  };
  return el('div', {}, box, el('div', { class:'btn-row' }, btn));
}

async function flatDialog(flat){
  const numI  = el('input', { type:'text', required:true, maxlength:'20', value: flat?.flat_number || '' });
  const flrI  = el('input', { type:'number', min:'0', required:true, value: flat?.floor ?? '' });
  const areaI = el('input', { type:'number', step:'0.01', min:'0', value: flat?.area_sqft ?? '' });
  const chgI  = el('input', { type:'number', step:'0.01', min:'0', value: flat?.service_charge ?? '' });
  const stI   = select([{ value:'ACTIVE', label:'Active' }, { value:'INACTIVE', label:'Inactive' }],
                        { value: flat?.status || 'ACTIVE' });
  const noteI = el('textarea', { rows:2 });
  noteI.value = flat?.notes || '';

  const body = el('div', {},
    el('div', { class:'grid g-form' }, field('Flat number', numI, { required:true }), field('Floor', flrI, { required:true })),
    el('div', { class:'grid g-form' }, field('Area (sq ft)', areaI),
      field('Monthly charge', chgI, { hint:`Leave blank to use the building default of ${money(settings().default_service_charge)}` })),
    field('Status', stI, { hint: flat ? 'An inactive flat is not billed when a month is generated.' : null }),
    field('Notes', noteI),
    flat ? el('p', { class:'hint', text:'Owner, tenant and phone numbers are on the flat’s own page — tap the flat in the list.' }) : null);

  const res = await modal({ title: flat ? `Edit flat ${flat.flat_number}` : 'Add a flat', body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', validate: () => {
        if (!numI.value.trim()){ err('A flat number is required.'); return false; }
        if (flrI.value === ''){ err('A floor is required.'); return false; }
        return true;
      }, value:true }
  ]});
  if (!res) return;

  const payload = {
    flat_number: numI.value.trim(), floor: Number(flrI.value),
    area_sqft: areaI.value === '' ? null : Number(areaI.value),
    service_charge: chgI.value === '' ? null : Number(chgI.value),
    status: stI.value, notes: noteI.value.trim() || null
  };
  try {
    if (flat) await update('flats', flat.id, payload);
    else      await insert('flats', payload);
    invalidate('flats');
    ok(flat ? `Flat ${payload.flat_number} saved` : `Flat ${payload.flat_number} added`);
    refresh();
  } catch { /* toast shown */ }
}

/* ==================================================================
   ONE FLAT — who lives there, who pays, what is owed, who was chased
   ================================================================== */
async function flatPage(flatId){
  const flat = await one('flats', b => b.eq('id', flatId));
  if (!flat) return emptyState('That flat does not exist.');

  const [dues, people, sums, hist] = await Promise.all([
    q('v_flat_dues', b => b.eq('flat_id', flatId)).catch(() => []),
    peopleRows(b => b.eq('flat_id', flatId)),
    can('charges','view') ? reminderSummaries() : new Map(),
    q('flat_occupancy', b => b.eq('flat_id', flatId).order('from_date', { ascending:false })).catch(() => [])
  ]);
  const d = dues[0] || {};
  const p = people.rows[0] || {};
  const rs = sums.get(flatId);
  const s = settings();
  const owes = Number(d.outstanding) > 0;

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:`Flat ${flat.flat_number}` }),
    el('p', { class:'sub', text: [
      `Floor ${flat.floor}`,
      flat.area_sqft ? `${num(flat.area_sqft)} sq ft` : null,
      `${money(flat.service_charge ?? s.default_service_charge)} a month${flat.service_charge ? '' : ' (building default)'}`,
      flat.status === 'ACTIVE' ? null : 'inactive'
    ].filter(Boolean).join(' · ') })));

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/flats', text:'← Flats' }));
  if (can('flats','edit')) bar.append(el('button', { class:'btn', text:'Edit flat', onclick: () => flatDialog(flat) }));
  if (can('charges','view')) bar.append(el('a', { class:'btn', href:`#/charges/flat/${flatId}`, text:'Statement' }));
  if (owes && can('charges','add'))
    bar.append(el('button', { class:'btn primary', text:'Send a reminder', onclick: () => reminderDialog(flatId) }));
  page.append(bar);

  // Money is shown only to people who may see service charges; for anyone
  // else the view returns nothing, and "Tk 0 outstanding" would be a lie.
  if (can('charges','view')) page.append(el('div', { class:'grid g-stats' },
    stat('Outstanding', money(d.outstanding || 0), null, owes ? 'bad' : 'good'),
    stat('Advance held', money(d.advance || 0)),
    stat('Last payment', d.last_payment_date ? fdate(d.last_payment_date) : 'never'),
    stat('Reminders', rs ? `${rs.since} since paying` : 'none', rs ? `${rs.total} in all` : null,
         rs && rs.since >= 2 ? 'bad' : '')));

  page.append(people.missing ? needsUpdate('Managing owners and tenants') : peopleCard(flat, p));
  if (p.owner_id && can('charges','view')){ const oc = await ownerSummary(p.owner_id); if (oc) page.append(oc); }
  if (can('charges','view')){ const rc = await rateCard(flat); if (rc) page.append(rc); }

  if (flat.notes) page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Notes' })), el('p', { text: flat.notes })));

  if (can('charges','view')){
    const rc = await receiptsCard(flatId, { limit: 12 });
    if (rc) page.append(rc);
    page.append(await reminderHistory(flatId));
  }

  const past = hist.filter(h => h.to_date && !h.voided_at);
  if (past.length){
    const owners = await ref('owners', true);
    const nameOf = (id) => (owners.find(o => o.id === id) || {}).name || '—';
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Past owners and tenants' })),
      table([
        { label:'Name', primary:true, fmt: h => nameOf(h.owner_id) },
        { label:'As', fmt: h => h.relation_type === 'TENANT' ? 'Tenant' : 'Owner' },
        { label:'From', fmt: h => fdate(h.from_date) },
        { label:'To', fmt: h => fdate(h.to_date) }
      ], past)));
  }
  return page;
}

function personLine(role, name, mobile, email, since, billed){
  return el('div', { class:'person' },
    el('div', { class:'person-role' }, el('span', { text: role }),
      billed ? el('span', { class:'badge b-active', text:'pays' }) : null),
    el('div', { class:'person-main' },
      el('b', { text: name }),
      el('div', { class:'small muted', text: [mobile, email, since ? `since ${fdate(since)}` : null].filter(Boolean).join(' · ') || 'no contact details' })));
}

/* ------------------------------------------------------------------
   Temporary rate — a flat still under construction, or let cheaply for
   a while, pays a different amount for a set run of months and goes
   back to its normal rate by itself afterwards.
   ------------------------------------------------------------------ */
const ym = (d) => d ? String(d).slice(0, 7) : '';
const ymLabel = (d) => { if (!d) return ''; const [y, m] = String(d).slice(0, 7).split('-').map(Number); return monthName(y, m); };

/** When the owner has more than one flat: his flats and his total, in one line. */
async function ownerSummary(ownerId){
  let a;
  try { a = ((await rpc('owner_accounts', {}, { silent:true })) || []).find(r => r.owner_id === ownerId); }
  catch { return null; }
  if (!a || (a.flats_owned < 2 && a.flats_paid < 2)) return null;
  const box = el('section', { class:'card owner-sum' },
    el('div', { class:'owner-sum-text' },
      el('b', { text:`${a.owner_name} owns ${a.flats_owned} flats: ${a.owned_list}` }),
      el('div', { class:'small muted', text: [
        a.flats_rented_out ? `${a.flats_rented_out} rented out` : null,
        `pays for ${a.paid_list || 'none'}`,
        `${money(a.monthly_total)} a month`,
        Number(a.outstanding) > 0 ? `owes ${money(a.outstanding)} in all` : 'nothing owed'].filter(Boolean).join(' · ') })),
    el('div', { class:'btn-row' },
      el('a', { class:'btn small', href:`#/charges/owner/${ownerId}`, text:'Owner\u2019s account' }),
      can('charges','add') ? el('button', { class:'btn small primary', type:'button', text:'One payment for all flats',
        onclick: () => groupPaymentDialog(ownerId) }) : null));
  return box;
}

async function rateCard(flat){
  let rows;
  try { rows = await q('flat_rate_overrides', b => b.eq('flat_id', flat.id).order('from_month', { ascending:false }), { silent:true }); }
  catch (e){ if (isMissingObject(e.original || e)) return null; return null; }
  const s = settings();
  const normal = flat.service_charge ?? s.default_service_charge;
  const thisMonth = todayISO().slice(0, 7);
  const live = rows.filter(r => !r.cancelled_at);
  const current = live.find(r => ym(r.from_month) <= thisMonth && (!r.to_month || ym(r.to_month) >= thisMonth));

  const card = el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Temporary rate' }),
      can('charges','edit') ? el('button', { class:'btn small', type:'button', text:'＋ Set a temporary rate', onclick: () => rateDialog(flat) }) : null),
    el('p', { class: current ? 'rate-now temp' : 'rate-now', text: current
      ? `This month: ${money(current.amount)} instead of ${money(normal)} — ${current.reason}${current.to_month ? `, until ${ymLabel(current.to_month)}` : ', until cancelled'}.`
      : `Normal rate: ${money(normal)} a month. Use a temporary rate for a flat under construction, or any time-limited discount; it ends on its own.` }));
  if (rows.length) card.append(table([
    { label:'Months', primary:true, fmt: r => `${ymLabel(r.from_month)} – ${r.to_month ? ymLabel(r.to_month) : 'until cancelled'}` },
    { label:'Rate', cls:'num', fmt: r => money(r.amount, { bare:true }) },
    { label:'Why', key:'reason' },
    { label:'', fmt: r => r.cancelled_at ? el('span', { class:'small muted', text:`cancelled — ${r.cancel_reason || ''}` })
        : (can('charges','edit') ? el('button', { class:'btn small', type:'button', text:'Cancel', onclick: async (e) => {
            e.stopPropagation();
            const reason = await reasonBox('Cancel this temporary rate?', 'Why? (months already billed keep their bill)', 'Cancel the rate');
            if (!reason) return;
            try { await rpc('cancel_temporary_rate', { p_id: r.id, p_reason: reason }); ok('Temporary rate cancelled.'); refresh(); } catch {}
          } }) : null) }
  ], rows, { stack: true }));
  return card;
}

async function rateDialog(flat){
  const d = new Date(); d.setDate(1); d.setMonth(d.getMonth() + 1);
  const next = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  const fromI = el('input', { type:'month', value: next, placeholder:'YYYY-MM' });
  const toI = el('input', { type:'month', placeholder:'YYYY-MM' });
  const amtI = el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal', placeholder:'e.g. 2000' });
  const whyI = el('input', { type:'text', maxlength:'200', placeholder:'e.g. Under construction' });
  const ok1 = (v) => /^\d{4}-\d{2}$/.test(v);
  const body = el('div', {},
    el('p', { class:'muted small', text:`Flat ${flat.flat_number} normally pays ${money(flat.service_charge ?? settings().default_service_charge)}. For the months below it will be billed this amount instead, then go back to normal by itself.` }),
    el('div', { class:'grid g-form' }, field('From month', fromI, { required:true }), field('Until month', toI, { hint:'Leave empty to keep it until you cancel it.' })),
    el('div', { class:'grid g-form' }, field('Monthly amount', amtI, { required:true }), field('Why', whyI, { required:true })),
    el('p', { class:'hint', text:'Months already billed are not changed — use a waiver for those. The rate shows on bills as a temporary rate.' }));
  const res = await modal({ title:`Temporary rate — Flat ${flat.flat_number}`, body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', value:true, validate: () => {
        if (!ok1(fromI.value)){ err('Choose the first month (YYYY-MM).'); return false; }
        if (toI.value && !ok1(toI.value)){ err('The last month should look like 2027-03.'); return false; }
        if (toI.value && toI.value < fromI.value){ err('The last month is before the first.'); return false; }
        if (amtI.value === '' || Number(amtI.value) < 0){ err('Enter the monthly amount.'); return false; }
        if (whyI.value.trim().length < 2){ err('Say why — for example, under construction.'); return false; }
        return true; } }
  ]});
  if (!res) return;
  try {
    await rpc('set_temporary_rate', { p_flat: flat.id, p_from: fromI.value + '-01', p_to: toI.value ? toI.value + '-01' : null,
                                      p_amount: Number(amtI.value), p_reason: whyI.value.trim() });
    ok('Temporary rate saved.'); refresh();
  } catch {}
}

function peopleCard(flat, p){
  const edit = can('flats','edit');
  const card = el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Who lives here and who pays' })));

  // Owner
  if (p.owner_id){
    const row = personLine('Owner', p.owner_name, p.owner_mobile, p.owner_email, p.owner_since, p.owner_billed);
    const acts = el('div', { class:'person-acts' });
    if (can('charges','view')) acts.append(el('a', { class:'btn small', href:`#/charges/owner/${p.owner_id}`, text:'All this owner\u2019s flats' }));
    if (edit) acts.append(
      el('button', { class:'btn small', text:'Edit details', onclick: () => personDialog(p.owner_id) }),
      el('button', { class:'btn small', text:'Change owner', onclick: () => occupantDialog(flat, 'OWNER', p) }),
      el('button', { class:'btn small', text:'Wrong entry?', onclick: async () => { if (await fixDialog(flat, 'OWNER', p)) refresh(); } }));
    if (acts.childNodes.length) row.append(acts);
    card.append(row);
  } else {
    const row = el('div', { class:'person' },
      el('div', { class:'person-role' }, el('span', { text:'Owner' })),
      el('div', { class:'person-main muted', text:'Not recorded yet' }));
    if (edit) row.append(el('div', { class:'person-acts' },
      el('button', { class:'btn small primary', text:'＋ Add owner', onclick: () => occupantDialog(flat, 'OWNER', p) })));
    card.append(row);
  }

  // Tenant
  if (p.tenant_id){
    const row = personLine('Tenant', p.tenant_name, p.tenant_mobile, p.tenant_email, p.tenant_since, p.tenant_billed);
    if (edit) row.append(el('div', { class:'person-acts' },
      el('button', { class:'btn small', text:'Edit details', onclick: () => personDialog(p.tenant_id) }),
      el('button', { class:'btn small', text:'Moved out', onclick: () => moveOutDialog(flat, p) }),
      el('button', { class:'btn small', text:'Wrong entry?', onclick: async () => { if (await fixDialog(flat, 'TENANT', p)) refresh(); } })));
    card.append(row);
  } else {
    const row = el('div', { class:'person' },
      el('div', { class:'person-role' }, el('span', { text:'Tenant' })),
      el('div', { class:'person-main muted', text:'None — the flat is not let' }));
    if (edit) row.append(el('div', { class:'person-acts' },
      el('button', { class:'btn small', text:'＋ Add tenant', onclick: () => occupantDialog(flat, 'TENANT', p) })));
    card.append(row);
  }

  // Who pays — only a real choice when both exist.
  if (p.owner_id && p.tenant_id){
    const choose = async (rel) => {
      if (rel === p.billed_relation) return;
      try {
        await rpc('set_billed_party', { p_flat: flat.id, p_relation: rel });
        ok(rel === 'TENANT' ? `The tenant now pays for ${flat.flat_number}` : `The owner now pays for ${flat.flat_number}`);
        refresh();
      } catch { /* toast */ }
    };
    const seg = el('div', { class:'seg', role:'group', 'aria-label':'Who pays the service charge' },
      el('button', { class: 'seg-btn' + (p.billed_relation === 'OWNER' ? ' on' : ''), type:'button',
        'aria-pressed': String(p.billed_relation === 'OWNER'), text:'Owner', disabled: !edit, onclick: () => choose('OWNER') }),
      el('button', { class: 'seg-btn' + (p.billed_relation === 'TENANT' ? ' on' : ''), type:'button',
        'aria-pressed': String(p.billed_relation === 'TENANT'), text:'Tenant', disabled: !edit, onclick: () => choose('TENANT') }));
    card.append(el('div', { class:'pays' },
      el('span', { text:'Service charge is paid by' }), seg,
      el('span', { class:'small muted', text:'Bills, receipts and reminders go to this person.' })));
  } else if (!p.owner_id && !p.tenant_id){
    card.append(el('p', { class:'hint', text:'Until someone is added, this flat’s bills have no name on them and reminders cannot be sent.' }));
  }
  return card;
}

/* ------------------------------------------------------------------
   Choosing a person: someone already on file, or a new one.
   ------------------------------------------------------------------ */

/** A mobile field that says, as you type, whether WhatsApp can use it.
    The check runs in the database (normalize_mobile) so there is one
    definition of "a usable number", shared with the reminder itself. */
function mobileField(value){
  const input = el('input', { type:'tel', value: value || '', placeholder:'01XXXXXXXXX or +44…', inputmode:'tel' });
  const hint = el('span', { class:'hint' });
  let timer;
  const check = async () => {
    const v = input.value.trim();
    if (!v){ hint.textContent = 'Reminders need a mobile number.'; hint.className = 'hint'; return; }
    try {
      const n = await rpc('normalize_mobile', { p: v }, { silent:true });
      hint.textContent = n ? `WhatsApp-ready: +${n}` : 'Not a mobile number WhatsApp can use — check the digits.';
      hint.className = n ? 'hint ok-line' : 'hint warn-line';
    } catch { hint.textContent = ''; }
  };
  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(check, 350); });
  check();
  const wrap = el('label', { class:'field' }, el('span', { text:'Mobile' }), input, hint);
  return { input, el: wrap };
}

async function occupantDialog(flat, relation, p){
  const people = await activePeople();
  const isTenant = relation === 'TENANT';
  const current = isTenant ? p.tenant_id : p.owner_id;
  const other   = isTenant ? p.owner_id : p.tenant_id;

  const pick = select([{ value:'__new', label:'Someone new — enter their details below' },
                       ...people.filter(x => x.id !== current && x.id !== other)
                             .map(x => ({ value:x.id, label: x.mobile ? `${x.name} · ${x.mobile}` : x.name }))],
                      { value:'__new' });
  const nameI = el('input', { type:'text', maxlength:'120' });
  const mob = mobileField('');
  const mailI = el('input', { type:'email' });
  const altI  = el('input', { type:'text' });
  const fromI = el('input', { type:'date', value: todayISO() });
  const pays  = el('input', { type:'checkbox' });
  pays.checked = true;

  const details = el('div', {},
    field('Name', nameI, { required:true }),
    el('div', { class:'grid g-form' }, mob.el, field('Email', mailI)),
    field('Alternate contact', altI));
  pick.onchange = () => { details.hidden = pick.value !== '__new'; };

  const body = el('div', {},
    field(isTenant ? 'Tenant' : 'Owner', pick),
    details,
    field(isTenant ? 'Moved in on' : (current ? 'Owner from' : 'Owner since'), fromI),
    isTenant ? el('label', { class:'check' }, pays,
      el('span', {}, el('b', { text:'The tenant pays the service charge' }),
        el('span', { class:'small muted', text:' — bills, receipts and reminders go to the tenant. Untick if the owner still pays.' }))) : null,
    !isTenant && current ? el('p', { class:'hint', text:`${p.owner_name} will be kept on record as a past owner. ` +
        (p.owner_billed ? 'The new owner takes over the bill.' : 'The tenant carries on paying.') }) : null,
    isTenant && p.owner_id ? el('p', { class:'hint', text:`${p.owner_name} stays the owner.` }) : null,
    el('p', { class:'hint', text: isTenant
      ? `A tenant is the person renting ${flat.flat_number} itself. If ${p.owner_name || 'the owner'} owns another flat as well, do not add it here: open that flat and choose ${p.owner_name || 'the same person'} as its owner.`
      : 'Already on file for another flat? Choose them from the list instead of typing the name again — then all their flats add up to one account and one receipt.' }));

  const res = await modal({
    title: isTenant ? `Add a tenant to ${flat.flat_number}` : (current ? `Change the owner of ${flat.flat_number}` : `Add the owner of ${flat.flat_number}`),
    body, actions:[
      { label:'Cancel', value:null },
      { label:'Save', kind:'primary', value:true, validate: () => {
          if (pick.value === '__new' && !nameI.value.trim()){ err('A name is needed.'); nameI.focus(); return false; }
          return true;
        } }
    ]});
  if (!res) return;

  const args = {
    p_flat: flat.id,
    p_person: pick.value === '__new' ? null : pick.value,
    p_name: nameI.value.trim() || null, p_mobile: mob.input.value.trim() || null,
    p_email: mailI.value.trim() || null, p_alt: altI.value.trim() || null,
    p_from: fromI.value || todayISO()
  };
  try {
    if (isTenant) await rpc('set_flat_tenant', { ...args, p_billed: pays.checked });
    else          await rpc('set_flat_owner', args);
    invalidate('owners','flats');
    ok(isTenant ? `Tenant added to ${flat.flat_number}` : `Owner of ${flat.flat_number} saved`);
    refresh();
  } catch { /* toast */ }
}

async function moveOutDialog(flat, p){
  const toI = el('input', { type:'date', value: todayISO() });
  const res = await modal({ title:`${p.tenant_name} moved out of ${flat.flat_number}?`,
    body: el('div', {},
      field('Moved out on', toI),
      el('p', { class:'hint', text: p.owner_id
        ? `${p.tenant_name} is kept as a past tenant. ${p.tenant_billed ? `From now on ${p.owner_name}, the owner, receives the bill.` : ''}`
        : `${p.tenant_name} is kept as a past tenant. There is no owner on record, so add one to keep this flat billed.` })),
    actions:[{ label:'Cancel', value:null }, { label:'Record move-out', kind:'primary', value:true }] });
  if (!res) return;
  try {
    await rpc('end_tenancy', { p_flat: flat.id, p_to: toI.value || todayISO() });
    ok(`${p.tenant_name} moved out of ${flat.flat_number}`);
    refresh();
  } catch { /* toast */ }
}

/** Edit a person's contact details. Which flat they belong to is changed
    on the flat's page, never here, so editing a phone number can never
    move a bill or end an ownership by accident. */
async function personDialog(personId){
  const person = personId ? await one('owners', b => b.eq('id', personId)) : null;
  const nameI = el('input', { type:'text', required:true, maxlength:'120', value: person?.name || '' });
  const mob = mobileField(person?.mobile);
  const mailI = el('input', { type:'email', value: person?.email || '' });
  const altI  = el('input', { type:'text', value: person?.alt_contact || '' });
  const noteI = el('textarea', { rows:2 });
  noteI.value = person?.notes || '';

  // A new person can be put into a flat in the same step — through the
  // same functions the flat page uses, so an owner is never closed off.
  let flatI = null, asI = null, paysI = null, linkBox = null;
  if (!person){
    const flats = await ref('flats');
    flatI = select(flats.map(f => ({ value:f.id, label:`Flat ${f.flat_number}` })), { placeholder:'Not in a flat yet' });
    asI = select([{ value:'OWNER', label:'Owner' }, { value:'TENANT', label:'Tenant' }], { value:'OWNER' });
    paysI = el('input', { type:'checkbox' }); paysI.checked = true;
    const paysRow = el('label', { class:'check', hidden:true }, paysI,
      el('span', {}, el('b', { text:'The tenant pays the service charge' })));
    asI.onchange = () => { paysRow.hidden = asI.value !== 'TENANT'; };
    linkBox = el('fieldset', {}, el('legend', {}, 'Flat (optional)'),
      el('div', { class:'grid g-form' }, field('Flat', flatI), field('As', asI)), paysRow,
      el('p', { class:'hint', text:'Adding a tenant keeps the owner. Adding a new owner keeps the old one on record as a past owner.' }));
  }

  const body = el('div', {},
    field('Name', nameI, { required:true }),
    el('div', { class:'grid g-form' }, mob.el, field('Email', mailI)),
    field('Alternate contact', altI, { hint:'Another number, or a relative to call if this one does not answer.' }),
    field('Notes', noteI),
    person ? null : linkBox);

  const res = await modal({ title: person ? `Edit ${person.name}` : 'Add a person', body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', value:true,
      validate: () => { if (!nameI.value.trim()){ err('A name is required.'); return false; } return true; } }
  ]});
  if (!res) return;

  const payload = { name: nameI.value.trim(), mobile: mob.input.value.trim() || null,
                    email: mailI.value.trim() || null, alt_contact: altI.value.trim() || null,
                    notes: noteI.value.trim() || null };
  try {
    if (person) await update('owners', person.id, payload);
    else {
      const saved = await insert('owners', payload);
      if (flatI?.value && saved){
        const args = { p_flat: flatI.value, p_person: saved.id, p_from: todayISO() };
        if (asI.value === 'TENANT') await rpc('set_flat_tenant', { ...args, p_billed: paysI.checked });
        else                        await rpc('set_flat_owner', args);
      }
    }
    invalidate('owners','flats');
    ok(`${payload.name} saved`);
    refresh();
  } catch { /* toast */ }
}

/* ==================================================================
   PEOPLE — everyone on file, and what they are to which flat
   ================================================================== */
async function peopleView(){
  const [people, flats, occ] = await Promise.all([
    ref('owners', true), ref('flats'),
    q('flat_occupancy', b => b.is('to_date', null)).catch(() => [])
  ]);
  const shown = people.filter(p => p.is_active !== false && !p.merged_into);
  const flatNo = (id) => flats.find(f => f.id === id)?.flat_number || '?';
  const rolesOf = (pid) => occ.filter(o => o.owner_id === pid)
    .map(o => `${flatNo(o.flat_id)} ${o.relation_type === 'TENANT' ? 'tenant' : 'owner'}${o.is_billed ? ' (pays)' : ''}`)
    .join(', ');

  const cols = [
    { label:'Name', primary:true, key:'name' },
    { label:'Flats', fmt: o => rolesOf(o.id) || '—', csv: o => rolesOf(o.id) },
    { label:'Mobile', fmt: o => o.mobile || '—', csv: o => o.mobile },
    { label:'Email', fmt: o => o.email || '—', csv: o => o.email },
    { label:'', fmt: o => can('flats','edit')
        ? el('button', { class:'btn small', text:'Edit', onclick: (e) => { e.stopPropagation(); personDialog(o.id); } })
        : '' }
  ];

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/flats', text:'← Flats' }));
  if (can('flats','add'))
    bar.append(el('button', { class:'btn primary', text:'＋ Add person', onclick: () => personDialog(null) }));
  bar.append(el('span', { class:'spacer' }));
  if (can('flats','export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV('people.csv', cols.slice(0,4), shown); logEvent('EXPORT', { module:'flats', detail:'people' });
    }}));

  const dup = await duplicatesCard({ onDone: () => refresh() });
  return el('div', {},
    dup,
    el('div', { class:'page-head' },
      el('h1', { text:'Owners & tenants' }),
      el('p', { class:'sub', text:'Everyone on file. To put someone into a flat as its owner or tenant, open the flat.' })),
    bar,
    table(cols, shown, { empty:'Nobody recorded yet. Open a flat and add its owner.' }));
}

/* ==================================================================
   WHO OWNS & WHO PAYS — every flat on one screen.

   Flats entered one at a time are easy to get wrong in ways that only
   show later: a land owner typed in again for each of his flats, so his
   flats never add up; a tenant put on the owner's flat instead of the one
   he rents. Here each flat's owner is chosen from ONE list of people —
   choosing the same person for A9 and B9 is what makes them one account,
   one bill and one combined receipt — and who pays is a tap per flat.
   ================================================================== */
async function setupView(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' }, el('h1', { text:'Who owns & who pays' }),
    el('p', { class:'sub', text:'Every flat on one screen. Choose each flat’s owner from the list — pick the same person for all the flats they own, and those flats add up to one account, one bill and one combined receipt. Then choose who pays each flat.' })));
  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/flats', text:'← Flats' }));
  if (can('charges','view')) bar.append(el('a', { class:'btn', href:'#/charges/owners', text:'Owners & payers' }));
  page.append(bar);

  const [flats, first] = await Promise.all([ref('flats', true), peopleRows()]);
  if (first.missing){ page.append(needsUpdate('Who owns & who pays')); return page; }
  const dup = await duplicatesCard({ onDone: () => refresh() });
  if (dup) page.append(dup);

  const edit = can('flats','edit');
  const s = settings();
  let people = await activePeople();
  let rows = new Map(first.rows.map(r => [r.flat_id, r]));
  const sorted = [...flats].sort((a, b) => (a.floor - b.floor) || String(a.flat_number).localeCompare(String(b.flat_number), undefined, { numeric:true }));
  const ticked = new Set();

  const statsHost = el('div', {});
  const host = el('div', {});
  const reload = async () => {
    invalidate('owners');
    const [p2, r2] = await Promise.all([activePeople(), peopleRows()]);
    people = p2; rows = new Map(r2.rows.map(r => [r.flat_id, r])); paint();
  };

  /* Put a person on a flat as its owner — a first owner, a correction or a sale. */
  const setOwner = async (flat, row, person, { why } = {}) => {
    const args = person.id ? { p_person: person.id } : { p_name: person.name, p_mobile: person.mobile };
    if (!row.owner_id) return rpc('set_flat_owner', { p_flat: flat.id, ...args });
    if (person.id && person.id === row.owner_id) return null;
    if (why === 'SOLD') return rpc('set_flat_owner', { p_flat: flat.id, ...args, p_from: todayISO() });
    return rpc('correct_occupant', { p_occupancy: row.owner_occupancy_id, p_person: person.id || null,
      p_name: person.id ? null : person.name, p_mobile: person.id ? null : person.mobile,
      p_reason: 'Corrected on Who owns & who pays' });
  };
  const askWhy = async (what) => {
    const r1 = el('input', { type:'radio', name:'why', value:'FIX' }); r1.checked = true;
    const r2 = el('input', { type:'radio', name:'why', value:'SOLD' });
    const body = el('div', {}, el('p', { text: what }),
      el('label', { class:'pick-card' }, r1, el('span', {}, el('b', { text:'Correction — the wrong owner was entered' }),
        el('div', { class:'small muted', text:'Usual while setting up. The record is put right; no past owner is created.' }))),
      el('label', { class:'pick-card' }, r2, el('span', {}, el('b', { text:'The flat was sold' }),
        el('div', { class:'small muted', text:'The old owner is kept as a past owner, from today.' }))));
    const ok_ = await modal({ title:'Change the owner', body, actions:[{ label:'Cancel', value:null }, { label:'Continue', kind:'primary', value:true }] });
    return ok_ ? body.querySelector('input[name=why]:checked').value : null;
  };

  const ownerCell = (f) => {
    const row = rows.get(f.id) || {};
    const sel = personSelect(people, { value: row.owner_id || '', none:'— no owner —', exclude: row.tenant_id ? [row.tenant_id] : [] });
    sel.setAttribute('aria-label', `Owner of ${f.flat_number}`);
    if (!edit){ sel.disabled = true; return sel; }
    sel.onclick = (e) => e.stopPropagation();
    sel.onchange = async () => {
      const v = sel.value;
      try {
        if (v === ''){
          if (row.owner_id && await fixDialog(f, 'OWNER', row)) await reload(); else paint();
          return;
        }
        let person;
        if (v === '__new'){ const np = await newPersonDialog(`Owner of ${f.flat_number}`); if (!np){ paint(); return; } person = np; }
        else person = { id: v };
        let why;
        if (row.owner_id){ why = await askWhy(`${f.flat_number} is recorded as owned by ${row.owner_name}.`); if (!why){ paint(); return; } }
        await setOwner(f, row, person, { why });
        ok(`Owner of ${f.flat_number} saved.`);
        await reload();
      } catch { paint(); }
    };
    return sel;
  };
  const paysCell = (f) => {
    const row = rows.get(f.id) || {};
    if (!row.owner_id && !row.tenant_id) return el('span', { class:'muted', text:'—' });
    if (!(row.owner_id && row.tenant_id)) return el('span', { text: row.owner_id ? 'Owner' : 'Tenant' });
    const choose = async (rel, e) => {
      e.stopPropagation();
      if (!edit || rel === row.billed_relation) return;
      try { await rpc('set_billed_party', { p_flat: f.id, p_relation: rel }); ok(`${f.flat_number}: the ${rel === 'TENANT' ? 'tenant' : 'owner'} pays.`); await reload(); } catch {}
    };
    return el('div', { class:'seg seg-sm', role:'group', 'aria-label':`Who pays for ${f.flat_number}` },
      ['OWNER','TENANT'].map(rel => el('button', { type:'button', class:'seg-btn' + (row.billed_relation === rel ? ' on' : ''),
        'aria-pressed': String(row.billed_relation === rel), disabled: !edit, text: rel === 'OWNER' ? 'Owner' : 'Tenant',
        onclick: (e) => choose(rel, e) })));
  };
  const cols = [
    ...(edit ? [{ label:'', fmt: f => { const c = el('input', { type:'checkbox', 'aria-label':`Tick ${f.flat_number}` });
        c.checked = ticked.has(f.id); c.onclick = (e) => e.stopPropagation();
        c.onchange = () => { c.checked ? ticked.add(f.id) : ticked.delete(f.id); paintBulk(); }; return c; } }] : []),
    { label:'Flat', primary:true, fmt: f => el('a', { href:`#/flats/${f.id}`, text: f.flat_number }) },
    { label:'Owner', fmt: ownerCell },
    { label:'Tenant', fmt: f => { const r = rows.get(f.id) || {};
        return el('a', { href:`#/flats/${f.id}`, class: r.tenant_name ? '' : 'muted', text: r.tenant_name || (edit ? '＋ add on flat page' : '—') }); } },
    { label:'Paid by', fmt: paysCell },
    { label:'Monthly', cls:'num', fmt: f => money(f.service_charge ?? s.default_service_charge, { bare:true }) }
  ];

  /* Tick several flats, give them one owner — a land owner's flats in one go. */
  const bulkSel = personSelect(people, { value:'' , none:'Choose the owner…' });
  const bulkBtn = el('button', { class:'btn primary', type:'button', text:'Make owner of ticked flats' });
  const bulkInfo = el('span', { class:'small muted' });
  const bulk = el('div', { class:'card bulk-owner' },
    el('b', { text:'Several flats, one owner' }),
    el('p', { class:'small muted', text:'Tick the flats a land owner owns, choose him once, and press the button.' }),
    el('div', { class:'toolbar' }, el('div', { class:'grow' }, bulkSel), bulkBtn, bulkInfo));
  const paintBulk = () => { bulkInfo.textContent = ticked.size ? `${ticked.size} ticked` : 'none ticked'; bulkBtn.disabled = !ticked.size; };
  bulkBtn.onclick = async () => {
    if (!bulkSel.value) return err('Choose the owner first.');
    let person;
    if (bulkSel.value === '__new'){ const np = await newPersonDialog('The owner of the ticked flats'); if (!np) return; person = np; }
    else person = { id: bulkSel.value };
    const list = sorted.filter(f => ticked.has(f.id));
    const changing = list.filter(f => { const r = rows.get(f.id) || {}; return r.owner_id && r.owner_id !== person.id; });
    let why = 'FIX';
    if (changing.length){ why = await askWhy(`${changing.map(f => f.flat_number).join(', ')} already ${changing.length === 1 ? 'has an owner' : 'have owners'}.`); if (!why) return; }
    bulkBtn.disabled = true;
    let done = 0;
    for (const f of list){
      try {
        const res = await setOwner(f, rows.get(f.id) || {}, person, { why });
        // A new person is created once; the rest of the flats reuse them.
        if (!person.id && res){ const occ = Array.isArray(res) ? res[0] : res; if (occ?.owner_id) person = { id: occ.owner_id }; }
        done++;
      } catch { break; }
    }
    ticked.clear();
    ok(`${done} flat${done === 1 ? '' : 's'} given to the owner.`);
    await reload();
  };

  const paint = () => {
    const all = [...rows.values()];
    const counts = new Map();
    for (const r of all) if (r.owner_id) counts.set(r.owner_id, (counts.get(r.owner_id) || 0) + 1);
    statsHost.replaceChildren(el('div', { class:'grid g-stats' },
      stat('Flats', num(flats.length)),
      stat('Without an owner', num(flats.filter(f => !(rows.get(f.id) || {}).owner_id).length), null,
           flats.some(f => !(rows.get(f.id) || {}).owner_id) ? 'bad' : 'good'),
      stat('Owners with several flats', num([...counts.values()].filter(n => n > 1).length)),
      stat('Paid by tenants', num(all.filter(r => r.billed_relation === 'TENANT').length))));
    host.replaceChildren(table(cols, sorted, { empty:'No flats yet.' }));
    paintBulk();
  };
  page.append(statsHost);
  if (edit) page.append(bulk);
  page.append(host,
    el('p', { class:'hint', text:'A tenant is added on the flat he rents (tap the flat). "Paid by" decides whose bill, receipt and reminder the flat goes on; a combined receipt can still include a tenant-paid flat if the owner hands over the money.' }));
  paint();
  return page;
}
