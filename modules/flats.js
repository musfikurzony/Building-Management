/* Flats, owners and who is billed. The flat count and every rate live
   here as data — nothing about "36 flats" or "Tk 5,000" is in code. */

import { el, field, select, money, num, table, emptyState, ok, err, modal,
         downloadCSV, todayISO, badge, stat } from '../core/ui.js';
import { q, one, insert, update, del, logEvent } from '../core/db.js';
import { can, ref, invalidate, settings } from '../core/store.js';
import { go, refresh } from '../core/router.js';

export async function render({ params }){
  if (params[0] === 'owners') return ownersView();
  return flatsView();
}

async function flatsView(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' }, el('h1', { text:'Flats & owners' })));

  const [flats, dues] = await Promise.all([ref('flats', true), q('v_flat_dues').catch(() => [])]);
  const dueOf = (id) => dues.find(d => d.flat_id === id) || {};
  const s = settings();

  const active = flats.filter(f => f.status === 'ACTIVE');
  const monthly = active.reduce((t,f) => t + Number(f.service_charge ?? s.default_service_charge ?? 0), 0);

  page.append(el('div', { class:'grid g-stats' },
    stat('Flats', num(flats.length), `${active.length} active`),
    stat('Floors', num(s.floor_count || Math.max(0, ...flats.map(f => f.floor)))),
    stat('Monthly billing', money(monthly), 'if every active flat is billed'),
    stat('Default rate', money(s.default_service_charge), 'used when a flat has none')));

  const bar = el('div', { class:'toolbar' });
  if (can('flats','add')){
    bar.append(el('button', { class:'btn primary', text:'＋ Add flat', onclick: () => flatDialog(null) }));
  }
  bar.append(el('a', { class:'btn', href:'#/flats/owners', text:'Owners' }));
  const search = el('input', { type:'search', placeholder:'Search flat or owner…' });
  bar.append(el('div', { class:'grow' }, search));
  bar.append(el('span', { class:'spacer' }));

  const cols = [
    { label:'Flat', primary:true, key:'flat_number' },
    { label:'Floor', cls:'num', key:'floor' },
    { label:'Area', cls:'num', fmt: f => f.area_sqft ? num(f.area_sqft) + ' sq ft' : '—', csv: f => f.area_sqft },
    { label:'Monthly charge', cls:'num', csv: f => f.service_charge ?? s.default_service_charge,
      fmt: f => money(f.service_charge ?? s.default_service_charge, { bare:true }) + (f.service_charge ? '' : ' *') },
    { label:'Billed to', fmt: f => dueOf(f.id).billed_to || '—', csv: f => dueOf(f.id).billed_to },
    { label:'Mobile', fmt: f => dueOf(f.id).billed_mobile || '—', csv: f => dueOf(f.id).billed_mobile },
    { label:'Outstanding', cls:'num', csv: f => dueOf(f.id).outstanding || 0,
      fmt: f => money(dueOf(f.id).outstanding || 0, { bare:true }) },
    { label:'Status', fmt: f => badge(f.status), csv: f => f.status }
  ];

  if (can('flats','export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV('flats.csv', cols, flats); logEvent('EXPORT', { module:'flats' });
    }}));
  page.append(bar);

  const host = el('div', {});
  const paint = () => {
    const term = search.value.trim().toLowerCase();
    const list = term ? flats.filter(f =>
      f.flat_number.toLowerCase().includes(term) ||
      String(dueOf(f.id).billed_to || '').toLowerCase().includes(term)) : flats;
    host.replaceChildren(
      table(cols, list, {
        onRow: f => go('#/charges/flat/' + f.id),
        empty: flats.length ? 'No flat matches that search.'
                            : 'No flats yet. Add them one at a time, or import the list.' }),
      el('p', { class:'hint', text:'* uses the building default rate. Tap a flat to open its statement.' }));
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
  const noteI = el('textarea', { rows:2, value: flat?.notes || '' });

  const body = el('div', {},
    el('div', { class:'grid g-form' }, field('Flat number', numI, { required:true }), field('Floor', flrI, { required:true })),
    el('div', { class:'grid g-form' }, field('Area (sq ft)', areaI),
      field('Monthly charge', chgI, { hint:`Leave blank to use the building default of ${money(settings().default_service_charge)}` })),
    field('Status', stI), field('Notes', noteI));

  const res = await modal({ title: flat ? `Edit ${flat.flat_number}` : 'Add a flat', body, actions:[
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
    ok('Saved'); refresh();
  } catch { /* toast shown */ }
}

/* ------------------------------------------------------------------ */
async function ownersView(){
  const [owners, flats, occ] = await Promise.all([
    ref('owners', true), ref('flats'), q('flat_occupancy', b => b.is('to_date', null)).catch(() => [])
  ]);
  const flatsOf = (ownerId) => occ.filter(o => o.owner_id === ownerId)
    .map(o => flats.find(f => f.id === o.flat_id)?.flat_number).filter(Boolean).join(', ');

  const cols = [
    { label:'Name', primary:true, key:'name' },
    { label:'Flats', fmt: o => flatsOf(o.id) || '—', csv: o => flatsOf(o.id) },
    { label:'Mobile', fmt: o => o.mobile || '—', csv: o => o.mobile },
    { label:'Email', fmt: o => o.email || '—', csv: o => o.email },
    { label:'', fmt: o => can('flats','edit')
        ? el('button', { class:'btn small', text:'Edit', onclick: (e) => { e.stopPropagation(); ownerDialog(o); } })
        : '' }
  ];

  const bar = el('div', { class:'toolbar' },
    el('a', { class:'btn', href:'#/flats', text:'← Flats' }));
  if (can('flats','add'))
    bar.append(el('button', { class:'btn primary', text:'＋ Add owner', onclick: () => ownerDialog(null) }));
  bar.append(el('span', { class:'spacer' }));
  if (can('flats','export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV('owners.csv', cols.slice(0,4), owners); logEvent('EXPORT', { module:'flats', detail:'owner list' });
    }}));

  return el('div', {},
    el('div', { class:'page-head' }, el('h1', { text:'Owners & residents' })),
    bar,
    table(cols, owners, { empty:'No owners recorded yet.' }));
}

async function ownerDialog(owner){
  const nameI = el('input', { type:'text', required:true, value: owner?.name || '' });
  const mobI  = el('input', { type:'tel', value: owner?.mobile || '', placeholder:'01XXXXXXXXX' });
  const mailI = el('input', { type:'email', value: owner?.email || '' });
  const altI  = el('input', { type:'text', value: owner?.alt_contact || '' });
  const flats = await ref('flats');
  const occ = owner ? await q('flat_occupancy', b => b.eq('owner_id', owner.id).is('to_date', null)).catch(() => []) : [];
  const linked = new Set(occ.map(o => o.flat_id));
  const flatI = select(flats.map(f => ({ value:f.id, label:f.flat_number })),
                       { value: occ[0]?.flat_id, placeholder:'Not linked to a flat' });
  const relI = select([{ value:'OWNER', label:'Owner' }, { value:'TENANT', label:'Tenant' }],
                      { value: occ[0]?.relation_type || 'OWNER' });

  const body = el('div', {},
    field('Name', nameI, { required:true }),
    el('div', { class:'grid g-form' }, field('Mobile', mobI), field('Email', mailI)),
    field('Alternate contact', altI),
    el('fieldset', {}, el('legend', {}, 'Billing link'),
      el('div', { class:'grid g-form' }, field('Flat', flatI), field('Relationship', relI)),
      el('p', { class:'hint', text:'Whoever is linked here receives the bill and appears on the outstanding report.' })));

  const res = await modal({ title: owner ? 'Edit owner' : 'Add owner', body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary',
      validate: () => { if (!nameI.value.trim()){ err('A name is required.'); return false; } return true; }, value:true }
  ]});
  if (!res) return;

  const payload = { name: nameI.value.trim(), mobile: mobI.value.trim() || null,
                    email: mailI.value.trim() || null, alt_contact: altI.value.trim() || null };
  try {
    const saved = owner ? await update('owners', owner.id, payload) : await insert('owners', payload);
    if (flatI.value && !linked.has(flatI.value)){
      // close any previous billed occupancy on that flat, then open a new one
      const current = await q('flat_occupancy', b => b.eq('flat_id', flatI.value).is('to_date', null).eq('is_billed', true)).catch(() => []);
      for (const c of current) await update('flat_occupancy', c.id, { to_date: todayISO() });
      await insert('flat_occupancy', {
        flat_id: flatI.value, owner_id: saved.id, relation_type: relI.value,
        is_billed: true, from_date: todayISO()
      });
    }
    invalidate('owners','flats');
    ok('Saved'); refresh();
  } catch { /* toast shown */ }
}
