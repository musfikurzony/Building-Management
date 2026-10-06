/* =====================================================================
   people.js — putting right who owns and who pays.

   Flats entered one at a time leave three mistakes behind, and each one
   stops a land owner's flats adding up to one total:
     • the same person typed in twice        → mergeDialog
     • a person added to the wrong flat      → fixDialog: "Remove"
     • the wrong person named on a flat      → fixDialog: "Replace"
   The database work is in 091_people_fixes.sql; nothing is deleted, and
   every fix is in the audit log.
   ===================================================================== */

import { el, field, select, ok, err, modal } from './ui.js';
import { rpc } from './db.js';
import { can, ref, invalidate } from './store.js';

/** People who can still be chosen (not retired by a merge). */
export async function activePeople(){
  const people = await ref('owners', true);
  return people.filter(p => p.is_active !== false && !p.merged_into);
}

/** A select of people, with "someone new" first. */
export function personSelect(people, { exclude = [], value = '', none = null } = {}){
  const opts = [];
  if (none) opts.push({ value:'', label: none });
  opts.push({ value:'__new', label:'＋ Someone new…' });
  for (const x of people) if (!exclude.includes(x.id))
    opts.push({ value: x.id, label: x.mobile ? `${x.name} · ${x.mobile}` : x.name });
  return select(opts, { value });
}

/** Ask for a new person's name and mobile. Returns {name, mobile} or null. */
export async function newPersonDialog(title = 'Someone new'){
  const nameI = el('input', { type:'text', maxlength:'120' });
  const mobI = el('input', { type:'tel', maxlength:'30', placeholder:'01XXXXXXXXX' });
  const res = await modal({ title, body: el('div', {},
      field('Name', nameI, { required:true }), field('Mobile', mobI),
      el('p', { class:'hint', text:'Check the list first: if this person is already on file (for another flat), choose them instead, so their flats add up.' })),
    actions:[{ label:'Cancel', value:null }, { label:'Add', kind:'primary', value:true,
      validate: () => { if (!nameI.value.trim()){ err('A name is needed.'); return false; } return true; } }] });
  return res ? { name: nameI.value.trim(), mobile: mobI.value.trim() || null } : null;
}

/* ------------------------------------------------------------------
   Likely doubles, with a Merge button each.
   ------------------------------------------------------------------ */
export async function duplicatesCard({ onDone } = {}){
  if (!can('flats','view')) return null;
  let pairs;
  try { pairs = await rpc('possible_duplicate_people', {}, { silent:true }); }
  catch { return null; }                         // before 091: say nothing
  if (!pairs || !pairs.length) return null;
  const box = el('section', { class:'card dup-card' },
    el('div', { class:'card-head' }, el('h2', { text:`Same person entered twice? (${pairs.length})` })),
    el('p', { class:'muted small', text:'These look like one person entered separately for different flats. Merge them so all their flats, dues and receipts come together under one name.' }));
  for (const d of pairs){
    box.append(el('div', { class:'dup-row' },
      el('div', { class:'dup-who' },
        el('div', {}, el('b', { text: d.a_name }), el('span', { class:'small muted', text:` · ${d.a_mobile || 'no mobile'} · ${d.a_flats || 'no flat'}` })),
        el('div', {}, el('b', { text: d.b_name }), el('span', { class:'small muted', text:` · ${d.b_mobile || 'no mobile'} · ${d.b_flats || 'no flat'}` })),
        el('div', { class:'small muted', text: d.reason })),
      can('flats','edit') ? el('button', { class:'btn small primary', type:'button', text:'Merge', onclick: async () => {
        if (await mergeDialog(d)){ onDone ? onDone() : null; }
      } }) : null));
  }
  return box;
}

export async function mergeDialog(d){
  const opt = (id, name, mobile, flats, checked) => {
    const r = el('input', { type:'radio', name:'keep', value:id }); r.checked = checked;
    return el('label', { class:'pick-card' }, r, el('span', {}, el('b', { text: name }),
      el('span', { class:'small muted', text:` · ${mobile || 'no mobile'} · ${flats || 'no flat'}` })));
  };
  const body = el('div', {},
    el('p', { text:'Which name should stay?' }),
    opt(d.a_id, d.a_name, d.a_mobile, d.a_flats, true),
    opt(d.b_id, d.b_name, d.b_mobile, d.b_flats, false),
    el('p', { class:'hint', text:'All flats and combined receipts of the other entry move to the one you keep. Missing mobile or email is filled in from the other. The other entry is retired, not deleted, and the merge is recorded in the audit log.' }));
  const res = await modal({ title:'Merge into one person', body, actions:[
    { label:'Cancel', value:null }, { label:'Merge', kind:'primary', value:true }] });
  if (!res) return false;
  const keep = body.querySelector('input[name=keep]:checked').value;
  const drop = keep === d.a_id ? d.b_id : d.a_id;
  try {
    const k = await rpc('merge_people', { p_keep: keep, p_drop: drop });
    invalidate('owners');
    ok(`Merged into ${(Array.isArray(k) ? k[0] : k)?.name || 'one person'}.`);
    return true;
  } catch { return false; }
}

/* ------------------------------------------------------------------
   A wrong entry on a flat: take it off, or name the right person.
   p is a v_flat_people row.
   ------------------------------------------------------------------ */
export async function fixDialog(flat, relation, p){
  const isTenant = relation === 'TENANT';
  const occ  = isTenant ? p.tenant_occupancy_id : p.owner_occupancy_id;
  const name = isTenant ? p.tenant_name : p.owner_name;
  const other = isTenant ? p.owner_id : p.tenant_id;
  const people = await activePeople();

  const how = (v, title, text, checked) => {
    const r = el('input', { type:'radio', name:'how', value:v }); r.checked = checked;
    return el('label', { class:'pick-card' }, r, el('span', {}, el('b', { text: title }), el('div', { class:'small muted', text })));
  };
  const pick = personSelect(people, { exclude: [isTenant ? p.tenant_id : p.owner_id, other].filter(Boolean), value:'__new' });
  const nameI = el('input', { type:'text', maxlength:'120' });
  const mobI = el('input', { type:'tel', maxlength:'30' });
  const newBox = el('div', {}, el('div', { class:'grid g-form' }, field('Name', nameI), field('Mobile', mobI)));
  const replaceBox = el('div', { class:'sub-box' }, field('The right person', pick), newBox);
  const whyI = el('input', { type:'text', maxlength:'200', placeholder: isTenant ? 'e.g. He rents B9, not A9' : 'e.g. Typed the wrong name' });
  pick.onchange = () => { newBox.hidden = pick.value !== '__new'; };

  const body = el('div', {},
    el('p', {}, `${name} is recorded as the ${isTenant ? 'tenant' : 'owner'} of ${flat.flat_number}. What is wrong?`),
    how('VOID', isTenant ? 'Remove — added to this flat by mistake' : 'Remove — this person does not own this flat',
      'Taken off the flat and its history. Nothing is deleted; the reason is kept.', true),
    how('CORRECT', 'Replace with the right person',
      isTenant ? 'The tenant was named wrongly.' : 'The owner was named wrongly. This is a correction, not a sale — no past owner is created.', false),
    replaceBox,
    field('Why', whyI, { required:true }));
  const sync = () => { replaceBox.hidden = body.querySelector('input[name=how]:checked').value !== 'CORRECT'; };
  body.querySelectorAll('input[name=how]').forEach(r => r.onchange = sync); sync();

  const res = await modal({ title:`Fix ${flat.flat_number} — ${isTenant ? 'tenant' : 'owner'}`, body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', value:true, validate: () => {
        if (!whyI.value.trim()){ err('Say why, so the record explains itself.'); return false; }
        if (body.querySelector('input[name=how]:checked').value === 'CORRECT' && pick.value === '__new' && !nameI.value.trim()){
          err('Enter the right person’s name, or choose them from the list.'); return false; }
        return true; } }
  ]});
  if (!res) return false;
  try {
    if (body.querySelector('input[name=how]:checked').value === 'VOID')
      await rpc('void_occupancy', { p_occupancy: occ, p_reason: whyI.value.trim() });
    else
      await rpc('correct_occupant', { p_occupancy: occ, p_person: pick.value === '__new' ? null : pick.value,
        p_name: pick.value === '__new' ? nameI.value.trim() : null, p_mobile: pick.value === '__new' ? (mobI.value.trim() || null) : null,
        p_reason: whyI.value.trim() });
    invalidate('owners');
    ok('Fixed.');
    return true;
  } catch (e){ return false; }
}

