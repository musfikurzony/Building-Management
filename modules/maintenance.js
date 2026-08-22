/* Maintenance — one board for every fault in the building, from a
   dripping tap to a stuck lift.

   OPEN → ASSIGNED → IN PROGRESS → COMPLETED → VERIFIED, and the person
   who marked the work complete cannot be the one who verifies it. */

import { el, field, select, money, num, fdate, fdatetime, badge, table, stat,
         emptyState, ok, err, modal, reasonBox, confirmBox, downloadCSV } from '../core/ui.js';
import { q, one, rpc, logEvent } from '../core/db.js';
import { can, ref, state, invalidate } from '../core/store.js';
import { go, refresh } from '../core/router.js';

const OPEN_STATES = ['OPEN','ASSIGNED','IN_PROGRESS'];

export async function render({ params, query }){
  if (params[0] === 'new') return newIssueForm(query.get('asset'), query.get('flat'));
  if (params[0])           return detail(params[0]);
  return board();
}

async function board(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Maintenance' }),
    el('p', { class:'sub', text:'Every reported problem, who is on it, and what it cost.' })));

  const showI = select([
    { value:'open',   label:'Open items' },
    { value:'verify', label:'Waiting to be checked' },
    { value:'all',    label:'Everything' }
  ], { value:'open' });

  const bar = el('div', { class:'toolbar' });
  if (can('maintenance','add'))
    bar.append(el('a', { class:'btn primary', href:'#/maintenance/new', text:'＋ Report a problem' }));
  bar.append(el('div', { style:'flex:1;min-width:11rem' }, field('Show', showI)));
  bar.append(el('span', { class:'spacer' }));

  const host = el('div', {});
  const stats = el('div', { class:'grid g-stats' });
  page.append(stats, bar, host);

  let rows = [];
  const cols = [
    { label:'Number', primary:true, cls:'mono', key:'issue_no' },
    { label:'Problem', key:'title' },
    { label:'Where', fmt: r => [r.asset_name, r.flat_number, r.location].filter(Boolean).join(' · ') || '—',
      csv: r => r.location },
    { label:'Priority', fmt: r => el('span', {
        class:'badge ' + (r.priority === 'CRITICAL' ? 'b-overdue' : r.priority === 'HIGH' ? 'b-partial' : 'b-open'),
        text: r.priority.toLowerCase() }), csv: r => r.priority },
    { label:'Reported', fmt: r => fdate(r.reported_at), csv: r => r.reported_at },
    { label:'Assigned to', fmt: r => r.assigned_staff || r.assigned_vendor || '—',
      csv: r => r.assigned_staff || r.assigned_vendor },
    { label:'Status', csv: r => r.status, fmt: r => el('span', {},
        badgeNode(r.status),
        r.is_overdue ? el('span', { class:'badge b-overdue', style:'margin-left:.3rem', text:'late' }) : '') },
    { label:'Cost', cls:'num', fmt: r => r.actual_cost ? money(r.actual_cost, { bare:true })
        : (r.estimated_cost ? '~' + money(r.estimated_cost, { bare:true }) : '—'),
      csv: r => r.actual_cost ?? r.estimated_cost }
  ];

  if (can('maintenance','export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV('maintenance.csv', cols, rows); logEvent('EXPORT', { module:'maintenance' });
    }}));

  async function load(){
    host.replaceChildren(el('p', { class:'muted', text:'Loading…' }));
    const all = await q('v_issues', b => b.order('reported_at', { ascending:false }).limit(300));

    stats.replaceChildren(
      stat('Open',      num(all.filter(r => OPEN_STATES.includes(r.status)).length)),
      stat('Overdue',   num(all.filter(r => r.is_overdue).length), null,
           all.some(r => r.is_overdue) ? 'bad' : 'good'),
      stat('To be checked', num(all.filter(r => r.status === 'COMPLETED').length)),
      stat('Spent this year', money(all
        .filter(r => new Date(r.reported_at).getFullYear() === new Date().getFullYear())
        .reduce((t,r) => t + Number(r.actual_cost || 0), 0))));

    rows = showI.value === 'open'   ? all.filter(r => OPEN_STATES.includes(r.status))
         : showI.value === 'verify' ? all.filter(r => r.status === 'COMPLETED')
         : all;

    host.replaceChildren(table(cols, rows, {
      onRow: r => go('#/maintenance/' + r.id),
      empty: showI.value === 'open' ? 'Nothing is open. ' : 'Nothing to show.' }));
  }
  showI.onchange = load;
  await load();
  return page;
}

function badgeNode(status){
  return el('span', { class:'badge b-' + String(status).toLowerCase(),
                      text: String(status).replace(/_/g,' ').toLowerCase() });
}

/* ------------------------------------------------------------------ */
async function newIssueForm(assetId, flatId){
  const [depts, assets, flats] = await Promise.all([
    ref('departments'),
    q('v_assets', b => b.neq('status','RETIRED').order('asset_code')).catch(() => []),
    ref('flats')
  ]);

  const titleI = el('input', { type:'text', required:true, maxlength:'160',
                               placeholder:'What is wrong? e.g. Lift stopping between floors' });
  const descI  = el('textarea', { rows:3, placeholder:'Anything else worth knowing' });
  const priI   = select([['CRITICAL','Critical — someone could be hurt, or nothing works'],
                         ['HIGH','High — needs sorting today'],
                         ['MEDIUM','Medium — this week'],
                         ['LOW','Low — when convenient']].map(([v,l]) => ({ value:v, label:l })),
                        { value:'MEDIUM' });
  const deptI  = select(depts.map(d => ({ value:d.id, label:d.name })), { placeholder:'Not sure' });
  const assetI = select(assets.map(a => ({ value:a.id, label:`${a.asset_code} — ${a.name}` })),
                        { value: assetId, placeholder:'Not about a specific machine' });
  const flatI  = select(flats.map(f => ({ value:f.id, label:f.flat_number })),
                        { value: flatId, placeholder:'Not about a specific flat' });
  const locI   = el('input', { type:'text', maxlength:'120', placeholder:'e.g. 3rd floor landing' });
  const flrI   = el('input', { type:'number', min:'0', placeholder:'Floor' });
  const estI   = el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal',
                               placeholder:'If you have a quote' });
  const fileI  = el('input', { type:'file', accept:'image/*', capture:'environment' });

  const submit = el('button', { class:'btn primary', type:'submit', text:'Report it' });

  const form = el('form', { novalidate:true, onsubmit: async (e) => {
    e.preventDefault();
    if (!titleI.value.trim()){ err('Please say what is wrong.'); titleI.focus(); return; }
    submit.disabled = true;
    try {
      const issue = await rpc('create_issue', {
        p_title: titleI.value.trim(),
        p_description: descI.value.trim() || null,
        p_priority: priI.value,
        p_department: deptI.value || null,
        p_asset: assetI.value || null,
        p_flat: flatI.value || null,
        p_location: locI.value.trim() || null,
        p_floor: flrI.value === '' ? null : Number(flrI.value),
        p_estimated_cost: estI.value === '' ? null : Number(estI.value)
      });
      const row = Array.isArray(issue) ? issue[0] : issue;
      if (fileI.files?.[0] && row?.id){
        const { uploadAttachment, BUCKETS } = await import('../core/db.js');
        await uploadAttachment(BUCKETS.photos, 'issues', row.id, fileI.files[0])
          .catch(e2 => err('Reported, but the photo did not upload: ' + e2.message));
      }
      ok(`Reported as ${row?.issue_no || 'a new issue'}.`);
      go('#/maintenance/' + row.id);
    } catch { submit.disabled = false; }
  }},
    el('div', { class:'card' },
      field('What is wrong', titleI, { required:true }),
      field('How urgent', priI, { required:true }),
      field('Photo', fileI, { hint:'A picture saves a lot of explaining. Shrunk before upload.' }),
      field('More detail', descI),
      el('div', { class:'grid g-form' }, field('Where', locI), field('Floor', flrI)),
      el('div', { class:'grid g-form' }, field('Which machine', assetI), field('Which flat', flatI)),
      el('div', { class:'grid g-form' }, field('Department', deptI), field('Estimated cost', estI)),
      el('div', { class:'btn-row' }, submit,
        el('a', { class:'btn', href:'#/maintenance', text:'Cancel' }))));

  return el('div', {},
    el('div', { class:'page-head' },
      el('h1', { text:'Report a problem' }),
      el('p', { class:'sub', text:'Anyone can report. Someone with the right role picks it up from there.' })),
    form);
}

/* ------------------------------------------------------------------ */
async function detail(id){
  const i = await one('v_issues', b => b.eq('id', id));
  if (!i) return emptyState('That issue does not exist, or you cannot see it.');

  const [updates, staff, vendors, accounts, files] = await Promise.all([
    q('issue_updates', b => b.eq('issue_id', id).order('created_at')).catch(() => []),
    ref('staff').catch(() => []),
    ref('vendors'),
    ref('accounts'),
    q('attachments', b => b.eq('entity_table','issues').eq('entity_id', id).is('deleted_at', null)).catch(() => [])
  ]);
  const users = await ref('users').catch(() => []);
  const nameOf = (uid) => users.find(u => u.user_id === uid)?.full_name || 'someone';

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: i.title }),
    el('p', { class:'sub' },
      el('span', { class:'mono', text: i.issue_no }), ' · ',
      badgeNode(i.status), ' · ',
      el('span', { text: i.priority.toLowerCase() + ' priority' }),
      i.is_overdue ? el('span', { class:'badge b-overdue', style:'margin-left:.4rem', text:'past target time' }) : null)));

  page.append(el('div', { class:'card' },
    i.description ? el('p', { style:'white-space:pre-wrap', text: i.description }) : null,
    el('dl', { class:'dl' },
      el('dt', { text:'Reported' }),    el('dd', { text: `${fdatetime(i.reported_at)} by ${i.reported_by_name || 'someone'}` }),
      el('dt', { text:'Target' }),      el('dd', { text: i.due_at ? fdatetime(i.due_at) : '—' }),
      el('dt', { text:'Where' }),       el('dd', { text: [i.asset_name, i.flat_number, i.location,
                                                          i.floor !== null ? 'floor ' + i.floor : null]
                                                          .filter(Boolean).join(' · ') || '—' }),
      el('dt', { text:'Department' }),  el('dd', { text: i.department_name || '—' }),
      el('dt', { text:'Assigned to' }), el('dd', { text: i.assigned_staff || i.assigned_vendor || 'nobody yet' }),
      el('dt', { text:'Estimated' }),   el('dd', { text: i.estimated_cost ? money(i.estimated_cost) : '—' }),
      el('dt', { text:'Actual cost' }), el('dd', { text: i.actual_cost ? money(i.actual_cost) : '—' }),
      i.resolution ? el('dt', { text:'How it was fixed' }) : null,
      i.resolution ? el('dd', { style:'white-space:pre-wrap', text: i.resolution }) : null,
      i.verified_at ? el('dt', { text:'Checked by' }) : null,
      i.verified_at ? el('dd', { text: `${i.verified_by_name || 'someone'} · ${fdatetime(i.verified_at)}` }) : null,
      i.hours_to_complete ? el('dt', { text:'Time taken' }) : null,
      i.hours_to_complete ? el('dd', { text: num(i.hours_to_complete, 1) + ' hours' }) : null)));

  if (files.length){
    const box = el('div', { class:'card' }, el('div', { class:'card-head' }, el('h2', { text:'Photos' })));
    for (const f of files){
      const b = el('button', { class:'btn small', text: f.file_name });
      b.onclick = async () => {
        const { signedUrl } = await import('../core/db.js');
        const url = await signedUrl(f.bucket, f.storage_path, 60);
        if (url) window.open(url, '_blank', 'noopener');
      };
      box.append(el('div', { style:'margin-bottom:.4rem' }, b));
    }
    page.append(box);
  }

  /* ---- what can be done next ---- */
  if (can('maintenance','edit') && !['VERIFIED','CANCELLED'].includes(i.status)){
    const actions = el('div', { class:'btn-row' });

    if (i.status === 'OPEN')
      actions.append(el('button', { class:'btn primary', text:'Assign it',
        onclick: () => moveDialog(i, 'ASSIGNED', staff, vendors, accounts) }));
    if (['OPEN','ASSIGNED'].includes(i.status))
      actions.append(el('button', { class:'btn', text:'Work has started',
        onclick: () => moveDialog(i, 'IN_PROGRESS', staff, vendors, accounts) }));
    if (['OPEN','ASSIGNED','IN_PROGRESS'].includes(i.status))
      actions.append(el('button', { class:'btn primary', text:'Mark as done',
        onclick: () => moveDialog(i, 'COMPLETED', staff, vendors, accounts) }));
    if (i.status === 'COMPLETED' && can('maintenance','approve')){
      const doneByMe = updates.some(u => u.status_to === 'COMPLETED' && u.created_by === state.user.id);
      if (doneByMe){
        actions.append(el('span', { class:'hint',
          text:'You marked this done, so someone else has to check it.' }));
      } else {
        actions.append(el('button', { class:'btn primary', text:'I have checked it',
          onclick: async () => {
            const note = await reasonBox('Verify this work', 'What did you check?', 'Verify');
            if (!note) return;
            try { await rpc('update_issue', { p_issue: i.id, p_status:'VERIFIED', p_note: note });
                  ok('Verified'); refresh(); } catch {}
          }}));
      }
    }
    actions.append(el('button', { class:'btn danger', text:'Cancel this issue',
      onclick: async () => {
        const reason = await reasonBox('Cancel this issue', 'Why is it being cancelled?', 'Cancel it');
        if (!reason) return;
        try { await rpc('update_issue', { p_issue: i.id, p_status:'CANCELLED', p_note: reason });
              ok('Cancelled'); refresh(); } catch {}
      }}));
    page.append(actions);
  }

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'History' })),
    ...(updates.length ? updates.map(u => el('div', {
        style:'padding:.5rem 0;border-bottom:1px solid var(--line-soft)' },
      el('div', {},
        u.status_to ? badgeNode(u.status_to) : null, ' ',
        el('span', { text: u.note || '' })),
      el('div', { class:'small muted', text: `${nameOf(u.created_by)} · ${fdatetime(u.created_at)}` })))
      : [emptyState('Nothing yet.')])));

  page.append(el('div', { class:'btn-row' },
    el('a', { class:'btn', href:'#/maintenance', text:'← Back to the board' }),
    i.txn_id ? el('a', { class:'btn', href:'#/finance/' + i.txn_id, text:'See the cost in the ledger' }) : null,
    i.asset_id ? el('a', { class:'btn', href:'#/maintenance', text:'' }) : null));
  return page;
}

async function moveDialog(i, status, staff, vendors, accounts){
  const noteI  = el('textarea', { rows:2, placeholder:'A short note for the record' });
  const staffI = select(staff.filter(s => s.status === 'ACTIVE')
                    .map(s => ({ value:s.id, label:`${s.name} (${s.position_name})` })),
                    { value: i.assigned_staff_id, placeholder:'Nobody in particular' });
  const vendI  = select(vendors.map(v => ({ value:v.id, label:v.name })),
                    { value: i.assigned_vendor_id, placeholder:'No outside company' });
  const costI  = el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal',
                               value: i.actual_cost ?? '' });
  const resI   = el('textarea', { rows:2, placeholder:'What was actually done?' });
  const acctI  = select(accounts.map(a => ({ value:a.id, label:a.name })), { placeholder:'Default cash account' });

  const isDone = status === 'COMPLETED';
  const body = el('div', {},
    isDone ? field('How it was fixed', resI) : null,
    !isDone ? el('div', { class:'grid g-form' },
      field('Assign to staff', staffI), field('Or to a company', vendI)) : null,
    isDone ? el('div', { class:'grid g-form' },
      field('What it cost', costI, { hint:'Leave blank if nothing was paid' }),
      field('Paid from', acctI)) : null,
    field('Note', noteI),
    isDone ? el('p', { class:'hint', text:'A cost entered here becomes an expense in the ledger, and follows the same approval rules as any other spend. Someone else will need to check the work.' }) : null);

  const label = { ASSIGNED:'Assign', IN_PROGRESS:'Mark in progress', COMPLETED:'Mark as done' }[status];
  const res = await modal({ title: label, body, actions:[
    { label:'Cancel', value:null }, { label, kind:'primary', value:true }
  ]});
  if (!res) return;

  try {
    await rpc('update_issue', {
      p_issue: i.id, p_status: status,
      p_note: noteI.value.trim() || null,
      p_staff: isDone ? null : (staffI.value || null),
      p_vendor: isDone ? null : (vendI.value || null),
      p_actual_cost: isDone && costI.value !== '' ? Number(costI.value) : null,
      p_resolution: isDone ? (resI.value.trim() || null) : null,
      p_account: acctI.value || null, p_method:'CASH'
    });
    invalidate('balances');
    ok('Updated'); refresh();
  } catch { /* toast shown */ }
}
