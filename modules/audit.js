/* Audit log — append-only, written by database triggers.
   Nothing in this screen can change a row; the table itself refuses
   UPDATE and DELETE from every role including the owner. */

import { el, field, select, fdatetime, table, badge, emptyState, downloadCSV } from '../core/ui.js';
import { q, logEvent } from '../core/db.js';
import { can, ref } from '../core/store.js';

export async function render(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Audit log' }),
    el('p', { class:'sub', text:'Every important change, who made it, and what it was before. This log cannot be edited or deleted by anyone.' })));

  const sevI = select([{ value:'HIGH', label:'High only' }, { value:'', label:'Everything' }], { value:'' });
  const modI = select(['finance','charges','bank','flats','users','settings','budget']
    .map(m => ({ value:m, label:m })), { placeholder:'All modules' });
  const searchI = el('input', { type:'search', placeholder:'Search person, record, action…' });

  page.append(el('div', { class:'toolbar' },
    el('div', { style:'flex:1;min-width:9rem' }, field('Severity', sevI)),
    el('div', { style:'flex:1;min-width:9rem' }, field('Module', modI)),
    el('div', { style:'flex:2;min-width:12rem' }, field('Search', searchI))));

  const body = el('div', {});
  page.append(body);

  let rows = [];
  const cols = [
    { label:'When', fmt: r => fdatetime(r.occurred_at), csv: r => r.occurred_at },
    { label:'Who', primary:true, fmt: r => r.actor_name_snapshot || 'system', csv: r => r.actor_name_snapshot },
    { label:'Action', fmt: r => String(r.action).replace(/_/g,' ').toLowerCase(), csv: r => r.action },
    { label:'Record', fmt: r => r.entity_label || (r.entity_table || ''), csv: r => r.entity_label || r.entity_table },
    { label:'Change', fmt: r => r.change_summary || r.detail || '', csv: r => r.change_summary || r.detail },
    { label:'Severity', fmt: r => badge(r.severity), csv: r => r.severity }
  ];

  async function load(){
    body.replaceChildren(el('p', { class:'muted', text:'Loading…' }));
    rows = await q('v_audit_log', b => {
      let x = b.order('occurred_at', { ascending:false }).limit(400);
      if (sevI.value) x = x.eq('severity', sevI.value);
      if (modI.value) x = x.eq('module_code', modI.value);
      return x;
    }).catch(() => []);
    paint();
  }
  function paint(){
    const s = searchI.value.trim().toLowerCase();
    const list = s ? rows.filter(r => [r.actor_name_snapshot, r.entity_label, r.action, r.change_summary, r.detail]
      .some(v => v && String(v).toLowerCase().includes(s))) : rows;
    body.replaceChildren(
      el('div', { class:'toolbar' },
        el('span', { class:'small muted', text:`${list.length} entries (most recent 400)` }),
        el('span', { class:'spacer' }),
        can('audit','export') ? el('button', { class:'btn small', text:'Export CSV', onclick: () => {
          downloadCSV('audit-log.csv', cols, list);
          logEvent('EXPORT', { module:'audit', detail:`${list.length} audit rows`, severity:'HIGH' });
        }}) : null),
      table(cols, list, { empty:'Nothing logged yet.' }));
  }
  sevI.onchange = modI.onchange = load;
  searchI.oninput = paint;
  await load();
  return page;
}
