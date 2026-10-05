/* Committee & Rules — who runs the building, and the rules they run it by.

   Two pages, one tap apart:
     #/community        the management committee, with photos
     #/community/rules  the constitution, building rules, decisions,
                        notices and forms — each readable on a phone,
                        printable, and with its signed PDF attached
   Everyone whose role includes "Committee & Rules" can read both (every
   role, by default, including the read-only Resident role). Only those
   with add / edit permission see the buttons that change anything, and
   the database enforces the same rule. */

import { el, field, select, fdate, ok, err, modal, confirmBox, emptyState, todayISO, letterhead } from '../core/ui.js';
import { q, one, insert, update, upsert, del, sb, signedUrl, isMissingObject, logEvent } from '../core/db.js';
import { can, ref, settings, invalidate } from '../core/store.js';
import { go, refresh } from '../core/router.js';

const BUCKET = 'bms-documents';

export async function render({ params }){
  try {
    if (params[0] === 'rules') return await rulesPage();
    if (params[0] === 'doc' && params[1]) return await docPage(params[1]);
    return await committeePage();
  } catch (e){
    if (isMissingObject(e.original || e)) return needsUpdate();
    throw e;
  }
}

function needsUpdate(){
  return el('div', {},
    el('div', { class:'page-head' }, el('h1', { text:'Committee & Rules' })),
    el('div', { class:'alert normal' }, el('div', { class:'a-body' },
      el('div', { class:'a-title', text:'This needs a database update' }),
      el('div', { class:'a-meta', text:'In Supabase open the SQL Editor and run sql/PATCH.sql — it is safe to run twice — then reload this page.' }))));
}

function tabs(active){
  const t = (href, key, label) => el('a', { class:'tab' + (active === key ? ' on' : ''), href,
    'aria-current': active === key ? 'page' : null, text: label });
  return el('nav', { class:'tabs', 'aria-label':'Committee and rules' },
    t('#/community', 'committee', 'Committee'),
    t('#/community/rules', 'rules', 'Rules & documents'));
}

/* ==================================================================
   THE COMMITTEE
   ================================================================== */
// Usual positions, in the order a committee is listed. The order number
// is suggested from these and can be changed for any member.
const POSITIONS = [
  ['Chairman', 10], ['President', 10], ['Vice Chairman', 20], ['Vice President', 20],
  ['General Secretary', 30], ['Joint Secretary', 35], ['Finance Secretary', 40],
  ['Finance Manager', 40], ['Treasurer', 45], ['Organising Secretary', 50],
  ['Operations', 55], ['Maintenance Secretary', 55], ['Advisor', 70], ['Executive Member', 80], ['Member', 90]
];
const suggestedOrder = (pos) => (POSITIONS.find(([p]) => p.toLowerCase() === String(pos || '').trim().toLowerCase()) || [null, 90])[1];

const initials = (name) => String(name || '?').trim().split(/\s+/).filter(w => /^[\p{L}]/u.test(w))
  .slice(0, 2).map(w => w[0]).join('').toUpperCase() || '?';
const hue = (name) => [...String(name || '')].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);

function avatar(m, photo, size = 'md'){
  if (photo) return el('img', { class:`m-avatar ${size}`, src: photo, alt: `Photo of ${m.name}`, loading:'lazy' });
  return el('div', { class:`m-avatar ${size} initials`, style:`--h:${hue(m.name)}`, 'aria-hidden':'true', text: initials(m.name) });
}

async function committeePage(){
  const s = settings();
  const [info, members, photos] = await Promise.all([
    one('committee_info', b => b, { silent:true }),
    q('v_board_members', b => b.order('sort_order').order('name'), { silent:true }),
    q('board_member_photos', b => b, { silent:true }).catch(() => [])
  ]);
  const photoOf = new Map(photos.map(p => [p.member_id, p.photo]));
  const current = members.filter(m => m.is_current);
  const former  = members.filter(m => !m.is_current);
  const editable = can('community', 'edit');

  const page = el('div', { class:'community' });
  page.append(el('div', { class:'page-head' }, el('h1', { text:'Committee & Rules' })), tabs('committee'));

  const hero = el('section', { class:'hero' },
    el('div', { class:'hero-kicker', text: s.building_name || 'Our building' }),
    el('h2', { class:'hero-title', text: info?.title || 'Management Committee' }),
    info?.term ? el('div', { class:'hero-term', text: `Term ${info.term}` }) : null,
    info?.intro ? el('p', { class:'hero-intro', text: info.intro }) : null);
  if (editable) hero.append(el('button', { class:'btn small hero-edit', type:'button', text:'Edit heading',
    onclick: () => headingDialog(info) }));
  page.append(hero);

  if (can('community', 'add'))
    page.append(el('div', { class:'toolbar' },
      el('button', { class:'btn primary', type:'button', text:'＋ Add committee member', onclick: () => memberDialog(null) })));

  if (!current.length){
    page.append(emptyState(can('community', 'add')
      ? 'No committee members yet. Add the chairman first — the others are listed in order of position.'
      : 'The committee has not been added yet.'));
  } else {
    // The chairman and vice chairman (order 20 or less) lead, larger.
    const leads = current.filter(m => m.sort_order <= 20);
    const rest  = current.filter(m => m.sort_order > 20);
    if (leads.length) page.append(el('div', { class:'members leads' }, leads.map(m => memberCard(m, photoOf.get(m.id), 'lg', editable))));
    if (rest.length)  page.append(el('div', { class:'members' }, rest.map(m => memberCard(m, photoOf.get(m.id), 'md', editable))));
  }

  if (former.length){
    page.append(el('details', { class:'card former' },
      el('summary', { text:`Former committee members (${former.length})` }),
      el('div', { class:'members compact' }, former.map(m => memberCard(m, photoOf.get(m.id), 'sm', editable)))));
  }
  return page;
}

function memberCard(m, photo, size, editable){
  const term = [m.term_from ? fdate(m.term_from) : null, m.term_to ? fdate(m.term_to) : (m.is_current ? null : '')]
    .filter(x => x !== null).join(' – ');
  const card = el('article', { class:`member ${size}` },
    avatar(m, photo, size),
    el('div', { class:'member-body' },
      el('div', { class:'member-position', text: m.position }),
      el('h3', { class:'member-name', text: m.name }),
      m.flat_number ? el('div', { class:'member-flat', text:`Flat ${m.flat_number}` }) : null,
      m.about ? el('p', { class:'member-about', text: m.about }) : null,
      (m.phone || m.email) ? el('div', { class:'member-contact' },
        m.phone ? el('a', { href:`tel:${String(m.phone).replace(/[^\d+]/g, '')}`, text: m.phone }) : null,
        m.email ? el('a', { href:`mailto:${m.email}`, text: m.email }) : null,
        editable && !m.show_phone ? el('span', { class:'small muted', text:'(not shown to residents)' }) : null) : null,
      term ? el('div', { class:'small muted', text: term }) : null));
  if (editable) card.append(el('button', { class:'btn small member-edit', type:'button', text:'Edit',
    'aria-label': `Edit ${m.name}`, onclick: () => memberDialog(m.id) }));
  return card;
}

async function headingDialog(info){
  const titleI = el('input', { type:'text', maxlength:'120', value: info?.title || 'Management Committee' });
  const termI  = el('input', { type:'text', maxlength:'60', value: info?.term || '', placeholder:'e.g. 2026 – 2028' });
  const introI = el('textarea', { rows:3, maxlength:'1000', placeholder:'A line or two about the committee: when it was elected, how to reach it.' });
  introI.value = info?.intro || '';
  const res = await modal({ title:'Committee heading', body: el('div', {},
      field('Title', titleI, { required:true }), field('Term', termI), field('Introduction', introI)),
    actions:[{ label:'Cancel', value:null }, { label:'Save', kind:'primary', value:true,
      validate: () => { if (!titleI.value.trim()){ err('A title is needed.'); return false; } return true; } }] });
  if (!res) return;
  try {
    await update('committee_info', true, { title: titleI.value.trim(), term: termI.value.trim() || null,
                                           intro: introI.value.trim() || null }, 'id');
    ok('Heading saved'); refresh();
  } catch { /* toast */ }
}

/** A photo, made square and small enough to keep in the database. */
async function squarePhoto(file){
  if (!file.type.startsWith('image/')) throw new Error('Choose a picture (JPG or PNG).');
  const bmp = await createImageBitmap(file);
  const side = Math.min(bmp.width, bmp.height);
  const c = document.createElement('canvas');
  c.width = c.height = 360;
  const g = c.getContext('2d');
  g.fillStyle = '#fff'; g.fillRect(0, 0, 360, 360);
  g.drawImage(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side, 0, 0, 360, 360);
  bmp.close?.();
  for (const qy of [0.85, 0.75, 0.6]){
    const url = c.toDataURL('image/jpeg', qy);
    if (url.length < 380000) return url;
  }
  throw new Error('That picture could not be made small enough.');
}

async function memberDialog(id){
  const m = id ? await one('board_members', b => b.eq('id', id)) : null;
  const ph = id ? await one('board_member_photos', b => b.eq('member_id', id), { silent:true }).catch(() => null) : null;
  const flats = await ref('flats');

  let photo = ph?.photo || null, photoChanged = false;
  const preview = el('div', { class:'photo-preview' });
  const paint = () => preview.replaceChildren(avatar({ name: nameI.value || m?.name || '?' }, photo, 'lg'));
  const fileI = el('input', { type:'file', accept:'image/*', class:'visually-hidden', id:'memberPhoto' });
  const pick  = el('label', { class:'btn small', for:'memberPhoto', text: photo ? 'Change photo' : 'Add photo' });
  const clear = el('button', { class:'btn small', type:'button', text:'Remove photo', hidden: !photo,
    onclick: () => { photo = null; photoChanged = true; clear.hidden = true; pick.textContent = 'Add photo'; paint(); } });
  fileI.onchange = async () => {
    const f = fileI.files[0]; if (!f) return;
    try { photo = await squarePhoto(f); photoChanged = true; clear.hidden = false; pick.textContent = 'Change photo'; paint(); }
    catch (e){ err(e.message || String(e)); }
  };

  const nameI = el('input', { type:'text', maxlength:'120', value: m?.name || '' });
  nameI.addEventListener('input', () => { if (!photo) paint(); });
  const posList = el('datalist', { id:'positionList' }, POSITIONS.map(([p]) => el('option', { value: p })));
  const posI  = el('input', { type:'text', maxlength:'80', list:'positionList', value: m?.position || '', placeholder:'Chairman, Vice Chairman, Advisor…' });
  const ordI  = el('input', { type:'number', min:'0', max:'999', value: m?.sort_order ?? '' });
  let orderTouched = !!m;
  ordI.addEventListener('input', () => { orderTouched = true; });
  posI.addEventListener('input', () => { if (!orderTouched) ordI.value = suggestedOrder(posI.value); });
  const flatI = select(flats.map(f => ({ value:f.id, label:`Flat ${f.flat_number}` })), { value: m?.flat_id || '', placeholder:'Not given' });
  const phoneI = el('input', { type:'tel', maxlength:'40', value: m?.phone || '' });
  const mailI  = el('input', { type:'email', maxlength:'120', value: m?.email || '' });
  const showI  = el('input', { type:'checkbox' }); showI.checked = !!m?.show_phone;
  const aboutI = el('textarea', { rows:3, maxlength:'1000', placeholder:'Responsibilities, or a line about this member.' });
  aboutI.value = m?.about || '';
  const fromI = el('input', { type:'date', value: m?.term_from || '' });
  const toI   = el('input', { type:'date', value: m?.term_to || '' });
  const curI  = el('input', { type:'checkbox' }); curI.checked = m ? !!m.is_current : true;

  const body = el('div', {},
    el('div', { class:'photo-row' }, preview, el('div', { class:'btn-row' }, pick, clear), fileI),
    field('Name', nameI, { required:true }),
    el('div', { class:'grid g-form' }, field('Position', posI, { required:true }),
      field('Order on the page', ordI, { hint:'Smaller comes first. Chairman 10, Vice Chairman 20 — suggested as you type the position.' })),
    posList,
    field('Flat', flatI),
    el('div', { class:'grid g-form' }, field('Phone', phoneI), field('Email', mailI)),
    el('label', { class:'check' }, showI, el('span', {}, el('b', { text:'Show phone and email to residents' }),
      el('span', { class:'small muted', text:' — otherwise only committee editors see them.' }))),
    field('About', aboutI),
    el('div', { class:'grid g-form' }, field('On the committee from', fromI), field('Until', toI)),
    el('label', { class:'check' }, curI, el('span', { text:'Current member (untick for a former member — kept in the history)' })));

  const actions = [{ label:'Cancel', value:null }];
  if (m && can('community', 'cancel')) actions.push({ label:'Delete', kind:'danger', value:'delete' });
  actions.push({ label:'Save', kind:'primary', value:'save', validate: () => {
    if (!nameI.value.trim()){ err('A name is needed.'); return false; }
    if (!posI.value.trim()){ err('A position is needed.'); return false; }
    if (fromI.value && toI.value && toI.value < fromI.value){ err('The end of the term is before its start.'); return false; }
    return true;
  } });

  setTimeout(paint);
  const res = await modal({ title: m ? `Edit ${m.name}` : 'Add a committee member', body, actions });
  if (!res) return;

  if (res === 'delete'){
    if (!await confirmBox(`Delete ${m.name}?`, 'To keep them in the committee history instead, cancel and untick "Current member".', 'Delete', 'danger')) return;
    try { await del('board_members', { id: m.id }); ok(`${m.name} removed`); refresh(); } catch { /* toast */ }
    return;
  }

  const row = {
    name: nameI.value.trim(), position: posI.value.trim(),
    sort_order: ordI.value === '' ? suggestedOrder(posI.value) : Math.max(0, Math.min(999, Number(ordI.value))),
    flat_id: flatI.value || null, phone: phoneI.value.trim() || null, email: mailI.value.trim() || null,
    show_phone: showI.checked, about: aboutI.value.trim() || null,
    term_from: fromI.value || null, term_to: toI.value || null, is_current: curI.checked
  };
  try {
    const saved = m ? await update('board_members', m.id, row) : await insert('board_members', row);
    const memberId = m?.id || saved?.id;
    if (photoChanged && memberId){
      if (photo) await upsert('board_member_photos', { member_id: memberId, photo }, 'member_id');
      else await del('board_member_photos', { member_id: memberId });
    }
    ok(`${row.name} saved`); refresh();
  } catch { /* toast */ }
}

/* ==================================================================
   RULES & DOCUMENTS
   ================================================================== */
const CATS = [
  { value:'CONSTITUTION', label:'Constitution',          icon:'§' },
  { value:'RULES',        label:'Building rules',        icon:'☰' },
  { value:'DECISION',     label:'Committee decisions',   icon:'✓' },
  { value:'NOTICE',       label:'Notices',               icon:'!' },
  { value:'FORM',         label:'Forms',                 icon:'✎' },
  { value:'OTHER',        label:'Other documents',       icon:'•' }
];
const catOf = (v) => CATS.find(c => c.value === v) || CATS[CATS.length - 1];
const fileSize = (n) => !n ? '' : n < 1024 * 1024 ? `${Math.max(1, Math.round(n / 1024))} KB` : `${(n / 1024 / 1024).toFixed(1)} MB`;
const fileKind = (d) => /pdf/i.test(d.file_mime || d.file_name || '') ? 'PDF'
  : /image/i.test(d.file_mime || '') ? 'Picture'
  : /word|\.docx?$/i.test(`${d.file_mime || ''} ${d.file_name || ''}`) ? 'Word file' : 'File';

async function rulesPage(){
  const docs = await q('building_documents', b => b.order('is_pinned', { ascending:false })
    .order('effective_date', { ascending:false, nullsFirst:false }).order('title'), { silent:true });
  const page = el('div', { class:'community' });
  page.append(el('div', { class:'page-head' }, el('h1', { text:'Committee & Rules' }),
    el('p', { class:'sub', text:'The constitution, the building rules and the committee’s decisions — the version in force, for everyone to read.' })),
    tabs('rules'));

  const search = el('input', { type:'search', placeholder:'Search the rules and documents…' });
  let cat = '';
  const chips = el('div', { class:'chip-row', role:'group', 'aria-label':'Filter by kind' });
  const paintChips = () => chips.replaceChildren(
    ...[{ value:'', label:'All' }, ...CATS].filter(c => !c.value || docs.some(d => d.category === c.value)).map(c =>
      el('button', { type:'button', class:'filter-chip' + (cat === c.value ? ' on' : ''), 'aria-pressed': String(cat === c.value),
        text: c.value ? `${c.label} (${docs.filter(d => d.category === c.value).length})` : `All (${docs.length})`,
        onclick: () => { cat = c.value; paintChips(); paint(); } })));
  const bar = el('div', { class:'toolbar' }, el('div', { class:'grow' }, search));
  if (can('community', 'add')) bar.append(el('button', { class:'btn primary', type:'button', text:'＋ Add document', onclick: () => docDialog(null) }));
  page.append(bar, chips);

  const host = el('div', {});
  page.append(host);
  const paint = () => {
    const t = search.value.trim().toLowerCase();
    const list = docs.filter(d => (!cat || d.category === cat) &&
      (!t || [d.title, d.summary, d.body, d.version_label].some(x => String(x || '').toLowerCase().includes(t))));
    if (!docs.length){
      host.replaceChildren(emptyState(can('community', 'add')
        ? 'Nothing here yet. Start with the constitution or the building rules — upload the document (PDF, Word or a photo), type the rules in, or both.'
        : 'No rules or documents have been published yet.'));
      return;
    }
    if (!list.length){ host.replaceChildren(emptyState('Nothing matches that search.')); return; }
    const out = [];
    const pinned = list.filter(d => d.is_pinned);
    if (pinned.length) out.push(el('section', { class:'doc-group' }, el('h2', { text:'Important' }), pinned.map(docRow)));
    for (const c of CATS){
      const items = list.filter(d => !d.is_pinned && d.category === c.value);
      if (items.length) out.push(el('section', { class:'doc-group' }, el('h2', { text: c.label }), items.map(docRow)));
    }
    host.replaceChildren(...out);
  };
  search.oninput = paint;
  paintChips(); paint();
  return page;
}

function docRow(d){
  const c = catOf(d.category);
  return el('a', { class:'doc-row', href:`#/community/doc/${d.id}` },
    el('span', { class:`doc-icon c-${d.category.toLowerCase()}`, 'aria-hidden':'true', text: c.icon }),
    el('span', { class:'doc-main' },
      el('span', { class:'doc-title' }, d.title, !d.is_published ? el('span', { class:'badge b-draft', text:'draft' }) : null),
      el('span', { class:'doc-meta', text: [c.label,
        d.effective_date ? `in force from ${fdate(d.effective_date)}` : null,
        d.version_label ? `version ${d.version_label}` : null,
        d.file_name ? `${fileKind(d)} attached` : null].filter(Boolean).join(' · ') }),
      d.summary ? el('span', { class:'doc-summary', text: d.summary }) : null),
    el('span', { class:'doc-go', 'aria-hidden':'true', text:'›' }));
}

/**
 * The text of a document, laid out for reading. Plain text in, safe DOM
 * out — nothing typed into a rule is ever treated as markup:
 *   # Heading / ## Sub-heading
 *   1. A numbered rule (1.2, ১., 3) also work — the number is kept as typed)
 *   - a bullet
 *   a blank line starts a new paragraph
 */
export function renderBody(text){
  const box = el('div', { class:'doc-body' });
  let list = null;
  for (const raw of String(text || '').replace(/\r\n/g, '\n').split('\n')){
    const line = raw.trimEnd();
    const t = line.trim();
    let m;
    if (!t){ list = null; continue; }
    if ((m = t.match(/^(#{1,3})\s+(.*)$/))){
      list = null; box.append(el(m[1].length === 1 ? 'h2' : 'h3', { class:'doc-h', text: m[2] })); continue;
    }
    if ((m = t.match(/^[-•*]\s+(.*)$/))){
      if (!list){ list = el('ul', { class:'doc-list' }); box.append(list); }
      list.append(el('li', { text: m[1] })); continue;
    }
    list = null;
    if ((m = t.match(/^([0-9০-৯]+(?:\.[0-9০-৯]+)*|[a-z]|[ivx]+)[.)]\s+(.*)$/i) || t.match(/^([0-9০-৯]+(?:\.[0-9০-৯]+)+)\s+(.*)$/))
        && t.length > m[1].length + 2){
      box.append(el('div', { class:'rule' + (raw.match(/^\s{2,}/) || m[1].includes('.') ? ' sub' : '') },
        el('span', { class:'rule-no', text: /[.)]$/.test(m[1]) ? m[1] : (m[1].includes('.') ? m[1] : m[1] + '.') }),
        el('span', { class:'rule-text', text: m[2] })));
      continue;
    }
    box.append(el('p', { text: t }));
  }
  return box;
}

async function docPage(id){
  const d = await one('building_documents', b => b.eq('id', id), { silent:true });
  if (!d) return el('div', {}, tabs('rules'), emptyState('That document does not exist, or is not published.'));
  const s = settings();
  const c = catOf(d.category);
  const page = el('div', { class:'community doc-page' });

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/community/rules', text:'← Rules & documents' }));
  if (d.file_path) bar.append(el('button', { class:'btn primary', type:'button', text:`Open the ${fileKind(d)} (${fileSize(d.file_size)})`,
    onclick: () => openFile(d) }));
  bar.append(el('button', { class:'btn', type:'button', text:'Print', onclick: () => window.print() }));
  if (can('community', 'edit')) bar.append(el('button', { class:'btn', type:'button', text:'Edit', onclick: () => docDialog(d) }));
  page.append(bar);

  page.append(letterhead({ name: s.building_name, address: s.address, title: d.title,
    period: [c.label, d.effective_date ? `in force from ${fdate(d.effective_date)}` : null, d.version_label ? `version ${d.version_label}` : null].filter(Boolean).join(' · ') }));

  const article = el('article', { class:'card doc-article' },
    el('div', { class:'doc-kicker' }, el('span', { class:`doc-icon c-${d.category.toLowerCase()}`, 'aria-hidden':'true', text: c.icon }), c.label,
      !d.is_published ? el('span', { class:'badge b-draft', text:'draft — not visible to residents' }) : null),
    el('h1', { class:'doc-heading', text: d.title }),
    el('div', { class:'doc-meta', text: [d.effective_date ? `In force from ${fdate(d.effective_date)}` : null,
      d.version_label ? `Version ${d.version_label}` : null, `Last updated ${fdate(String(d.updated_at).slice(0, 10))}`].filter(Boolean).join(' · ') }),
    d.summary ? el('p', { class:'doc-lead', text: d.summary }) : null,
    d.body ? renderBody(d.body) : null,
    d.file_path ? el('div', { class:'doc-file' },
      el('span', { class:'doc-file-icon', 'aria-hidden':'true', text: fileKind(d) === 'PDF' ? 'PDF' : '▣' }),
      el('span', { class:'doc-file-name' }, el('b', { text: d.file_name }), el('span', { class:'small muted', text: ` · ${fileSize(d.file_size)}` })),
      el('button', { class:'btn small', type:'button', text:'Open', onclick: () => openFile(d) })) : null);
  page.append(article);
  return page;
}

async function openFile(d){
  // Open the tab first, inside the tap, so no phone treats it as a pop-up;
  // then point it at the signed link once that comes back.
  const w = window.open('', '_blank');
  try {
    const url = await signedUrl(BUCKET, d.file_path, 300);
    if (!url) throw new Error('no link');
    if (w) w.location.href = url; else location.href = url;
    logEvent('FILE_DOWNLOAD', { module:'community', table:'building_documents', id: d.id, label: d.title });
  } catch {
    if (w) w.close();
    err('The file could not be opened. If this keeps happening, run sql/PATCH.sql (it sets up the document storage) and try again.');
  }
}

async function uploadFile(docId, file){
  if (file.size > 15 * 1024 * 1024) throw new Error('That file is larger than 15 MB. Scan it at a lower resolution and try again.');
  const safe = file.name.replace(/[^\w.\-]+/g, '_').slice(-80) || 'document';
  const path = `community/${docId}/${Date.now()}-${safe}`;
  const { error } = await sb.storage.from(BUCKET).upload(path, file, { contentType: file.type || 'application/octet-stream' });
  if (error){
    if (/bucket not found/i.test(error.message || '')) throw new Error('Document storage is not set up yet. Run sql/PATCH.sql in Supabase (it creates it), then try again.');
    throw new Error('The file could not be uploaded: ' + (error.message || error));
  }
  return { file_path: path, file_name: file.name, file_mime: file.type || null, file_size: file.size };
}
const removeFile = (path) => path && sb?.storage.from(BUCKET).remove([path]).catch(() => {});

async function docDialog(d){
  const titleI = el('input', { type:'text', maxlength:'200', value: d?.title || '' });
  const catI   = select(CATS.map(c => ({ value:c.value, label:c.label })), { value: d?.category || 'RULES' });
  const dateI  = el('input', { type:'date', value: d?.effective_date || todayISO() });
  const verI   = el('input', { type:'text', maxlength:'40', value: d?.version_label || '', placeholder:'e.g. 2026 amendment' });
  const sumI   = el('textarea', { rows:2, maxlength:'600', placeholder:'One or two sentences: what this is and who it applies to.' });
  sumI.value = d?.summary || '';
  const bodyI  = el('textarea', { rows:14, maxlength:'200000', class:'doc-editor',
    placeholder:'# Part 1 — General\n1. Every resident shall…\n2. Visitors must…\n\n# Part 2 — Service charge\n1. The monthly charge is due by the 10th.\n- Bullet points start with a dash' });
  bodyI.value = d?.body || '';
  const fileI  = el('input', { type:'file',
    accept:'application/pdf,image/*,.doc,.docx,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document' });
  let dropFile = false;
  const fileNow = d?.file_name ? el('div', { class:'small' }, `Attached: ${d.file_name} (${fileSize(d.file_size)}) `,
    el('button', { class:'btn small', type:'button', text:'Remove', onclick: (e) => { dropFile = true; e.target.parentElement.textContent = 'The attached file will be removed when you save.'; } })) : null;
  const pubI = el('input', { type:'checkbox' }); pubI.checked = d ? !!d.is_published : true;
  const pinI = el('input', { type:'checkbox' }); pinI.checked = !!d?.is_pinned;

  const body = el('div', {},
    field('Title', titleI, { required:true }),
    el('div', { class:'grid g-form' }, field('Kind', catI), field('In force from', dateI)),
    field('Version', verI),
    field('Summary', sumI),
    field('Text of the rules', bodyI, { hint:'Optional if you attach a file. Start a line with # for a heading, 1. for a numbered rule, - for a bullet. Bangla works too.' }),
    field('Attach a file (PDF, Word or picture, up to 15 MB)', fileI, { hint:'The signed or official copy. Residents can open and download it. PDF is best: it opens on every phone without an app.' }),
    fileNow,
    el('label', { class:'check' }, pubI, el('span', { text:'Published — residents can read it (untick to keep it as a draft)' })),
    el('label', { class:'check' }, pinI, el('span', { text:'Pin to the top under "Important"' })));

  const actions = [{ label:'Cancel', value:null }];
  if (d && can('community', 'cancel')) actions.push({ label:'Delete', kind:'danger', value:'delete' });
  actions.push({ label:'Save', kind:'primary', value:'save', validate: () => {
    if (!titleI.value.trim()){ err('A title is needed.'); return false; }
    const hasFile = fileI.files[0] || (d?.file_path && !dropFile);
    if (!bodyI.value.trim() && !sumI.value.trim() && !hasFile){ err('Type the rules, write a summary, or attach a file.'); return false; }
    return true;
  } });
  const res = await modal({ title: d ? 'Edit document' : 'Add a rule or document', body, actions });
  if (!res) return;

  if (res === 'delete'){
    if (!await confirmBox(`Delete "${d.title}"?`, 'It disappears for everyone. To take it down for a while instead, untick "Published".', 'Delete', 'danger')) return;
    try { await del('building_documents', { id: d.id }); removeFile(d.file_path); ok('Document deleted'); go('#/community/rules'); } catch { /* toast */ }
    return;
  }

  const id = d?.id || crypto.randomUUID();
  const row = {
    title: titleI.value.trim(), category: catI.value, effective_date: dateI.value || null,
    version_label: verI.value.trim() || null, summary: sumI.value.trim() || null,
    body: bodyI.value.replace(/\r\n/g, '\n').trim() || null,
    is_published: pubI.checked, is_pinned: pinI.checked
  };
  try {
    let oldPath = null;
    if (fileI.files[0]){
      Object.assign(row, await uploadFile(id, fileI.files[0]));
      oldPath = d?.file_path || null;
    } else if (dropFile){
      Object.assign(row, { file_path:null, file_name:null, file_mime:null, file_size:null });
      oldPath = d?.file_path || null;
    }
    if (d) await update('building_documents', d.id, row);
    else   await insert('building_documents', { id, ...row });
    if (oldPath) removeFile(oldPath);
    ok(d ? 'Document saved' : 'Document added');
    if (d) refresh(); else go(`#/community/doc/${id}`);
  } catch (e){ if (e?.message && !e.original) err(e.message); }
}
