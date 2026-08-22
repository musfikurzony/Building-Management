/* Work monitoring — the cleaner's round, the gardener's week, the
   guard's shift. One engine, one screen, built for a thumb. */

import { el, field, select, num, fdate, badge, table, stat, emptyState,
         ok, err, modal, downloadCSV, todayISO, monthName } from '../core/ui.js';
import { q, rpc, logEvent } from '../core/db.js';
import { can, ref, invalidate } from '../core/store.js';
import { go, refresh } from '../core/router.js';

export async function render({ params }){
  if (params[0] === 'new') return logForm();
  return list();
}

async function list(){
  const [logs, compliance] = await Promise.all([
    q('v_work_logs', b => b.order('log_date', { ascending:false }).limit(120)).catch(() => []),
    q('v_work_compliance', b => b.order('period_year', { ascending:false })
                                  .order('period_month', { ascending:false }).limit(24)).catch(() => [])
  ]);

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Work monitoring' }),
    el('p', { class:'sub', text:'What was actually done, by whom, on which day.' })));

  const thisMonth = compliance.filter(c =>
    c.period_year === new Date().getFullYear() && c.period_month === new Date().getMonth() + 1);
  page.append(el('div', { class:'grid g-stats' },
    stat('Logs this month', num(thisMonth.reduce((t,c) => t + Number(c.logs_recorded), 0))),
    stat('Fully done', num(thisMonth.reduce((t,c) => t + Number(c.fully_done), 0)), null, 'good'),
    stat('Partly done', num(thisMonth.reduce((t,c) => t + Number(c.partly_done), 0))),
    stat('Not done', num(thisMonth.reduce((t,c) => t + Number(c.not_done), 0)), null,
         thisMonth.some(c => Number(c.not_done) > 0) ? 'bad' : '')));

  const bar = el('div', { class:'toolbar' });
  if (can('work','add'))
    bar.append(el('a', { class:'btn primary', href:'#/work/new', text:'＋ Record today’s round' }));
  bar.append(el('span', { class:'spacer' }));

  const cols = [
    { label:'Date', primary:true, fmt: r => fdate(r.log_date), csv: r => r.log_date },
    { label:'Round', key:'template_name' },
    { label:'Who', fmt: r => r.staff_name || '—', csv: r => r.staff_name },
    { label:'Items done', cls:'num', fmt: r => `${r.done_count} of ${r.item_count}`,
      csv: r => `${r.done_count}/${r.item_count}` },
    { label:'Result', fmt: r => el('span', {
        class:'badge ' + (r.overall_status === 'DONE' ? 'b-paid'
                       : r.overall_status === 'PARTIAL' ? 'b-partial' : 'b-overdue'),
        text: r.overall_status.replace('_',' ').toLowerCase() }), csv: r => r.overall_status },
    { label:'Remarks', fmt: r => r.remarks || '—', csv: r => r.remarks },
    { label:'Recorded by', fmt: r => r.recorded_by_name || '—', csv: r => r.recorded_by_name }
  ];
  if (can('work','export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV('work-logs.csv', cols, logs); logEvent('EXPORT', { module:'work' }); }}));
  page.append(bar);
  page.append(table(cols, logs, { empty:'Nothing recorded yet.' }));

  if (compliance.length){
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'How often the round is completed' })),
      table([
        { label:'Round', primary:true, key:'template_name' },
        { label:'Month', fmt: r => monthName(r.period_year, r.period_month),
          csv: r => monthName(r.period_year, r.period_month) },
        { label:'Logs', cls:'num', key:'logs_recorded' },
        { label:'Fully done', cls:'num', key:'fully_done' },
        { label:'Partly', cls:'num', key:'partly_done' },
        { label:'Not done', cls:'num', key:'not_done' },
        { label:'%', cls:'num', fmt: r => r.done_pct + '%', csv: r => r.done_pct }
      ], compliance)));
  }
  return page;
}

async function logForm(){
  const [templates, staff] = await Promise.all([ref('templates', true), ref('staff')]);
  if (!templates.length) return emptyState('No checklists have been set up yet.');

  const tplI   = select(templates.map(t => ({ value:t.id, label:t.name })), { value: templates[0].id });
  const staffI = select(staff.filter(s => s.status === 'ACTIVE')
                    .map(s => ({ value:s.id, label:`${s.name} (${s.position_name})` })),
                    { placeholder:'Not tied to one person' });
  const dateI  = el('input', { type:'date', value: todayISO(), max: todayISO() });
  const remI   = el('textarea', { rows:2, placeholder:'Anything worth noting' });

  const items = el('div', { class:'card' });
  const boxes = new Map();

  async function loadItems(){
    items.replaceChildren(el('p', { class:'muted', text:'Loading…' }));
    const rows = await q('work_checklist_items', b => b.eq('template_id', tplI.value).order('sort_order'))
      .catch(() => []);
    boxes.clear();
    const frag = el('div', {});
    for (const it of rows){
      const cb = el('input', { type:'checkbox' });
      boxes.set(it.id, cb);
      frag.append(el('label', { class:'check',
        style:'border-bottom:1px solid var(--line-soft);padding:.2rem 0' },
        cb, el('span', { text: it.label })));
    }
    if (!rows.length) frag.append(emptyState('This checklist has no items yet.'));
    const all = el('button', { class:'btn small', type:'button', text:'Tick everything' });
    all.onclick = () => { for (const cb of boxes.values()) cb.checked = true; };
    items.replaceChildren(el('div', { class:'card-head' },
      el('h2', { text:'Checklist' }), all), frag);
  }
  tplI.onchange = loadItems;

  const save = el('button', { class:'btn primary', text:'Save the round' });
  save.onclick = async () => {
    const payload = [...boxes.entries()].map(([item_id, cb]) => ({ item_id, is_done: cb.checked }));
    if (!payload.length) return err('Nothing to save.');
    save.disabled = true;
    try {
      await rpc('save_work_log', {
        p_template: tplI.value, p_staff: staffI.value || null, p_date: dateI.value,
        p_items: payload, p_remarks: remI.value.trim() || null, p_shift: null
      });
      ok('Saved'); go('#/work');
    } catch { save.disabled = false; }
  };

  await loadItems();
  return el('div', {},
    el('div', { class:'page-head' },
      el('h1', { text:'Record a round' }),
      el('p', { class:'sub', text:'Saving the same round for the same day again corrects it rather than adding a second one.' })),
    el('div', { class:'card' },
      el('div', { class:'grid g-form' }, field('Which round', tplI), field('Date', dateI)),
      field('Who did it', staffI)),
    items,
    el('div', { class:'card' }, field('Remarks', remI)),
    el('div', { class:'btn-row' }, save, el('a', { class:'btn', href:'#/work', text:'Cancel' })));
}
