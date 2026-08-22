/* Generator, lift and fire safety — one screen, three faces.

   They share a table because they are the same kind of thing: something
   in the building with a location, a service provider, a next-service
   date and a history. What differs is which actions make sense, and that
   is decided by the route. */

import { el, html, field, select, money, money0, num, fdate, fdatetime, badge,
         table, stat, emptyState, ok, err, modal, confirmBox, reasonBox,
         downloadCSV, todayISO, monthName } from '../core/ui.js';
import { q, one, rpc, logEvent } from '../core/db.js';
import { can, ref, state, settings, invalidate } from '../core/store.js';
import { go, refresh } from '../core/router.js';

const KINDS = {
  generator: { type:'GENERATOR',         title:'Generator',   noun:'generator'   },
  lift:      { type:'LIFT',              title:'Lift',        noun:'lift'        },
  fire:      { type:'FIRE_EXTINGUISHER', title:'Fire safety', noun:'extinguisher'}
};

export function makeModule(moduleCode){
  return { render: ({ params }) => params[0] ? detail(moduleCode, params[0]) : list(moduleCode) };
}

const ragClass = (s) => s === 'OVERDUE' ? 'b-overdue' : s === 'DUE_SOON' ? 'b-partial'
                      : s === 'OK' ? 'b-paid' : 'b-draft';
const ragWord  = (s) => s === 'OVERDUE' ? 'Overdue' : s === 'DUE_SOON' ? 'Due soon'
                      : s === 'OK' ? 'OK' : s === 'RETIRED' ? 'Retired' : 'Not set';

/* ==================================================================
   LIST
   ================================================================== */
async function list(moduleCode){
  const kind = KINDS[moduleCode];
  const rows = await q('v_assets', b => b.eq('asset_type', kind.type).order('asset_code'));

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: kind.title }),
    el('p', { class:'sub', text: moduleCode === 'fire'
      ? 'Green means inspected and in date. Amber is due soon. Red is overdue.'
      : 'Service dates, costs and history for the building’s ' + kind.noun + 's.' })));

  /* ---- the one thing a caretaker opens this screen to do ---- */
  if (moduleCode === 'generator' && can('generator','add')){
    const open = await q('generator_runs', b => b.is('gen_stop', null).order('gen_start')).catch(() => []);
    const bar = el('div', { class:'grid g-2' });
    if (open.length){
      const r = open[0];
      const stop = el('button', { class:'btn btn-big primary' },
        el('span', { class:'ico', text:'■' }),
        el('span', { text:'Power is back — stop the generator' }),
        el('span', { class:'sub', text:'Running since ' + fdatetime(r.gen_start) }));
      stop.onclick = () => stopRunDialog(r);
      bar.append(stop);
    } else {
      const start = el('button', { class:'btn btn-big primary' },
        el('span', { class:'ico', text:'⚡' }),
        el('span', { text:'Log a power cut' }),
        el('span', { class:'sub', text:'Start now, stop it when the power returns' }));
      start.onclick = () => startRunDialog(rows);
      bar.append(start);
    }
    const fuel = el('button', { class:'btn btn-big' },
      el('span', { class:'ico', text:'⛽' }),
      el('span', { text:'Record a fuel purchase' }),
      el('span', { class:'sub', text:'Goes to the ledger for approval' }));
    fuel.onclick = () => fuelDialog(rows);
    bar.append(fuel);
    page.append(bar);
  }

  /* ---- fire safety gets a status board, because that is the question ---- */
  if (moduleCode === 'fire'){
    const count = (s) => rows.filter(r => r.inspection_status === s).length;
    page.append(el('div', { class:'grid g-stats' },
      stat('Extinguishers', num(rows.length)),
      stat('In date',   num(count('OK')),        null, 'good'),
      stat('Due soon',  num(count('DUE_SOON'))),
      stat('Overdue',   num(count('OVERDUE')),   null, count('OVERDUE') ? 'bad' : ''),
      stat('Never inspected', num(count('UNKNOWN')), null, count('UNKNOWN') ? 'bad' : '')));
  } else {
    const overdue = rows.filter(r => r.service_status === 'OVERDUE').length;
    const spend   = rows.reduce((t,r) => t + Number(r.service_cost_ytd || 0), 0);
    page.append(el('div', { class:'grid g-stats' },
      stat('Registered', num(rows.length)),
      stat('Service overdue', num(overdue), null, overdue ? 'bad' : 'good'),
      stat('Open faults', num(rows.reduce((t,r) => t + Number(r.open_issues || 0), 0))),
      stat('Service cost this year', money0(spend))));
  }

  const bar = el('div', { class:'toolbar' });
  if (can(moduleCode,'add'))
    bar.append(el('button', { class:'btn primary', text:'＋ Add ' + kind.noun,
      onclick: () => assetDialog(moduleCode, null) }));
  bar.append(el('span', { class:'spacer' }));

  const cols = moduleCode === 'fire'
    ? [
        { label:'Code', primary:true, key:'asset_code', cls:'mono' },
        { label:'Location', fmt: r => [r.location, r.floor !== null ? 'floor ' + r.floor : null].filter(Boolean).join(' · '),
          csv: r => r.location },
        { label:'Type', fmt: r => r.specs?.class || r.capacity || '—', csv: r => r.specs?.class },
        { label:'Last inspected', fmt: r => r.last_inspection_date ? fdate(r.last_inspection_date) : 'never',
          csv: r => r.last_inspection_date },
        { label:'Next due', fmt: r => r.next_inspection_date ? fdate(r.next_inspection_date) : '—',
          csv: r => r.next_inspection_date },
        { label:'Status', csv: r => r.inspection_status,
          fmt: r => el('span', { class:'badge ' + ragClass(r.inspection_status),
                                 text: ragWord(r.inspection_status) }) },
        { label:'Condition', fmt: r => badge(r.condition), csv: r => r.condition }
      ]
    : [
        { label:'Code', primary:true, key:'asset_code', cls:'mono' },
        { label:'Name', key:'name' },
        { label:'Capacity', fmt: r => r.capacity || '—', csv: r => r.capacity },
        { label:'Last service', fmt: r => r.last_service_date ? fdate(r.last_service_date) : 'never',
          csv: r => r.last_service_date },
        { label:'Next due', fmt: r => r.next_service_date ? fdate(r.next_service_date) : '—',
          csv: r => r.next_service_date },
        { label:'Service', csv: r => r.service_status,
          fmt: r => el('span', { class:'badge ' + ragClass(r.service_status),
                                 text: ragWord(r.service_status) }) },
        { label:'Cost this year', cls:'num', fmt: r => money(r.service_cost_ytd, { bare:true }),
          csv: r => r.service_cost_ytd },
        { label:'Open faults', cls:'num', key:'open_issues' }
      ];

  if (can(moduleCode,'export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV(`${moduleCode}.csv`, cols, rows); logEvent('EXPORT', { module: moduleCode });
    }}));
  page.append(bar);

  page.append(table(cols, rows, {
    onRow: r => go(`#/${moduleCode}/${r.id}`),
    empty: `No ${kind.noun}s on the register yet.` }));

  /* ---- generator: what it ran and what it cost ---- */
  if (moduleCode === 'generator' && rows.length){
    const monthly = await q('v_generator_monthly', b => b
      .order('period_year', { ascending:false }).order('period_month', { ascending:false }).limit(12))
      .catch(() => []);
    if (monthly.length){
      page.append(el('section', { class:'card' },
        el('div', { class:'card-head' }, el('h2', { text:'Running cost by month' })),
        table([
          { label:'Month', primary:true, fmt: r => monthName(r.period_year, r.period_month),
            csv: r => monthName(r.period_year, r.period_month) },
          { label:'Runs', cls:'num', key:'run_count' },
          { label:'Hours', cls:'num', fmt: r => num(r.hours_run, 2), csv: r => r.hours_run },
          { label:'Diesel (L)', cls:'num', fmt: r => num(r.diesel_litres, 2), csv: r => r.diesel_litres },
          { label:'Fuel cost', cls:'num', fmt: r => money(r.fuel_cost, { bare:true }), csv: r => r.fuel_cost },
          { label:'Service', cls:'num', fmt: r => money(r.service_cost, { bare:true }), csv: r => r.service_cost },
          { label:'Total', cls:'num', fmt: r => money(r.total_cost, { bare:true }), csv: r => r.total_cost },
          { label:'L / hour', cls:'num', fmt: r => r.litres_per_hour ? num(r.litres_per_hour, 2) : '—',
            csv: r => r.litres_per_hour }
        ], monthly)));
    }

    const runs = await q('generator_runs', b => b.order('gen_start', { ascending:false }).limit(30))
      .catch(() => []);
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Recent runs' })),
      table([
        { label:'Started', primary:true, fmt: r => fdatetime(r.gen_start), csv: r => r.gen_start },
        { label:'Stopped', fmt: r => r.gen_stop ? fdatetime(r.gen_stop) : 'still running',
          csv: r => r.gen_stop },
        { label:'Minutes', cls:'num', fmt: r => r.duration_minutes ?? '—', csv: r => r.duration_minutes },
        { label:'Reason', fmt: r => String(r.reason).replace(/_/g,' ').toLowerCase(), csv: r => r.reason },
        { label:'Remark', fmt: r => r.problem_remark || '—', csv: r => r.problem_remark }
      ], runs, { empty:'No runs logged yet.' })));
  }

  return page;
}

/* ==================================================================
   DETAIL
   ================================================================== */
async function detail(moduleCode, id){
  const a = await one('v_assets', b => b.eq('id', id));
  if (!a) return emptyState('That item is not on the register, or you cannot see it.');

  const [logs, inspections, issues] = await Promise.all([
    q('asset_service_logs', b => b.eq('asset_id', id).order('service_date', { ascending:false })).catch(() => []),
    q('asset_inspections',  b => b.eq('asset_id', id).order('inspection_date', { ascending:false })).catch(() => []),
    q('v_issues', b => b.eq('asset_id', id).order('reported_at', { ascending:false })).catch(() => [])
  ]);

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: a.name }),
    el('p', { class:'sub' },
      el('span', { class:'mono', text: a.asset_code }), ' · ',
      a.location || 'no location recorded', ' · ',
      el('span', { class:'badge ' + ragClass(a.service_status), text: 'Service: ' + ragWord(a.service_status) }),
      moduleCode === 'fire' ? ' ' : '',
      moduleCode === 'fire'
        ? el('span', { class:'badge ' + ragClass(a.inspection_status), text:'Inspection: ' + ragWord(a.inspection_status) })
        : null)));

  page.append(el('div', { class:'grid g-stats' },
    stat('Condition', String(a.condition).replace('_',' ').toLowerCase()),
    stat(moduleCode === 'fire' ? 'Next inspection' : 'Next service',
         (moduleCode === 'fire' ? a.next_inspection_date : a.next_service_date)
           ? fdate(moduleCode === 'fire' ? a.next_inspection_date : a.next_service_date) : 'not set',
         (moduleCode === 'fire' ? a.inspection_days_left : a.service_days_left) !== null
           ? `${Math.abs(moduleCode === 'fire' ? a.inspection_days_left : a.service_days_left)} days ${
               (moduleCode === 'fire' ? a.inspection_days_left : a.service_days_left) < 0 ? 'overdue' : 'away'}`
           : null),
    stat('Cost this year', money(a.service_cost_ytd)),
    stat('Warranty', a.warranty_expiry ? fdate(a.warranty_expiry) : 'none recorded',
         a.under_warranty ? 'still covered' : null)));

  const bar = el('div', { class:'toolbar' },
    el('a', { class:'btn', href:'#/' + moduleCode, text:'← Back' }));
  if (can(moduleCode,'add')){
    bar.append(el('button', { class:'btn primary', text:'Record a service',
      onclick: () => serviceDialog(a) }));
    if (moduleCode === 'fire' || a.asset_type === 'FIRE_EXTINGUISHER')
      bar.append(el('button', { class:'btn primary', text:'Record an inspection',
        onclick: () => inspectionDialog(a) }));
  }
  if (can('maintenance','add'))
    bar.append(el('button', { class:'btn', text:'Report a fault',
      onclick: () => go('#/maintenance/new?asset=' + a.id) }));
  if (can(moduleCode,'edit'))
    bar.append(el('button', { class:'btn', text:'Edit details', onclick: () => assetDialog(moduleCode, a) }));
  page.append(bar);

  const specRows = Object.entries(a.specs || {});
  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Details' })),
    el('dl', { class:'dl' },
      el('dt', { text:'Make / model' }), el('dd', { text: [a.manufacturer, a.model].filter(Boolean).join(' ') || '—' }),
      el('dt', { text:'Capacity' }),     el('dd', { text: a.capacity || '—' }),
      el('dt', { text:'Serial number' }),el('dd', { class:'mono', text: a.serial_no || '—' }),
      el('dt', { text:'Installed' }),    el('dd', { text: a.installation_date ? fdate(a.installation_date) : '—' }),
      el('dt', { text:'Service provider' }), el('dd', { text: a.service_provider || '—' }),
      el('dt', { text:'Service every' }), el('dd', { text: a.service_interval_days ? a.service_interval_days + ' days' : '—' }),
      ...specRows.flatMap(([k,v]) => [
        el('dt', { text: k.replace(/_/g,' ') }),
        el('dd', { text: String(v) })
      ]),
      a.notes ? el('dt', { text:'Notes' }) : null,
      a.notes ? el('dd', { style:'white-space:pre-wrap', text: a.notes }) : null)));

  if (moduleCode === 'fire' || inspections.length){
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Inspections' })),
      table([
        { label:'Date', primary:true, fmt: r => fdate(r.inspection_date), csv: r => r.inspection_date },
        { label:'Result', fmt: r => badge(r.result), csv: r => r.result },
        { label:'Inspector', fmt: r => r.inspector || '—', csv: r => r.inspector },
        { label:'Pressure', fmt: r => r.pressure_ok === null ? '—' : (r.pressure_ok ? 'OK' : 'low'),
          csv: r => r.pressure_ok },
        { label:'Next due', fmt: r => r.next_inspection_date ? fdate(r.next_inspection_date) : '—',
          csv: r => r.next_inspection_date },
        { label:'Remarks', fmt: r => r.remarks || '—', csv: r => r.remarks }
      ], inspections, { empty:'Never inspected.' })));
  }

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Service & repair history' })),
    table([
      { label:'Date', primary:true, fmt: r => fdate(r.service_date), csv: r => r.service_date },
      { label:'Type', fmt: r => String(r.service_type).replace(/_/g,' ').toLowerCase(), csv: r => r.service_type },
      { label:'What was done', key:'description' },
      { label:'Technician', fmt: r => r.technician || '—', csv: r => r.technician },
      { label:'Cost', cls:'num', fmt: r => money(r.cost, { bare:true }), csv: r => r.cost },
      { label:'', fmt: r => r.txn_id
          ? el('a', { class:'btn small', href:'#/finance/' + r.txn_id, text:'Ledger' }) : '' }
    ], logs, { empty:'Nothing recorded yet.' })));

  if (issues.length){
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Faults reported' })),
      table([
        { label:'Number', primary:true, cls:'mono', key:'issue_no' },
        { label:'Reported', fmt: r => fdate(r.reported_at), csv: r => r.reported_at },
        { label:'Problem', key:'title' },
        { label:'Status', fmt: r => badge(r.status), csv: r => r.status },
        { label:'Cost', cls:'num', fmt: r => r.actual_cost ? money(r.actual_cost, { bare:true }) : '—',
          csv: r => r.actual_cost }
      ], issues, { onRow: r => go('#/maintenance/' + r.id) })));
  }
  return page;
}

/* ==================================================================
   DIALOGS
   ================================================================== */
async function assetDialog(moduleCode, a){
  const kind = KINDS[moduleCode];
  const [depts, vendors] = await Promise.all([ref('departments'), ref('vendors')]);

  const codeI = el('input', { type:'text', required:true, maxlength:'30', value: a?.asset_code || '' });
  const nameI = el('input', { type:'text', required:true, value: a?.name || '' });
  const locI  = el('input', { type:'text', value: a?.location || '' });
  const flrI  = el('input', { type:'number', min:'0', value: a?.floor ?? '' });
  const capI  = el('input', { type:'text', value: a?.capacity || '',
                              placeholder: moduleCode === 'generator' ? '150 kVA'
                                        : moduleCode === 'lift' ? '8 persons' : '5 kg' });
  const makeI = el('input', { type:'text', value: a?.manufacturer || '' });
  const modelI= el('input', { type:'text', value: a?.model || '' });
  const serI  = el('input', { type:'text', value: a?.serial_no || '' });
  const instI = el('input', { type:'date', value: a?.installation_date || '' });
  const warrI = el('input', { type:'date', value: a?.warranty_expiry || '' });
  const intI  = el('input', { type:'number', min:'1', value: a?.service_interval_days ?? (moduleCode === 'lift' ? 30 : 180) });
  const nextI = el('input', { type:'date', value: a?.next_service_date || '' });
  const provI = select(vendors.map(v => ({ value:v.id, label:v.name })), { value: a?.service_provider_id, placeholder:'None' });
  const deptI = select(depts.map(d => ({ value:d.id, label:d.name })), { value: a?.department_id, placeholder:'Choose a department' });
  const condI = select(['GOOD','FAIR','POOR','OUT_OF_ORDER'].map(c => ({ value:c, label:c.replace('_',' ').toLowerCase() })),
                       { value: a?.condition || 'GOOD' });
  const statI = select(['ACTIVE','UNDER_REPAIR','RETIRED'].map(c => ({ value:c, label:c.replace('_',' ').toLowerCase() })),
                       { value: a?.status || 'ACTIVE' });
  const noteI = el('textarea', { rows:2, value: a?.notes || '' });

  const canRetire = can(moduleCode, 'approve');
  if (!canRetire) statI.disabled = true;

  const body = el('div', {},
    el('div', { class:'grid g-form' },
      field('Code', codeI, { required:true, hint:'e.g. GEN-01, FE-0301' }),
      field('Name', nameI, { required:true })),
    el('div', { class:'grid g-form' }, field('Location', locI), field('Floor', flrI)),
    el('div', { class:'grid g-form' }, field('Capacity', capI), field('Department', deptI)),
    el('div', { class:'grid g-form' }, field('Manufacturer', makeI), field('Model', modelI)),
    el('div', { class:'grid g-form' }, field('Serial number', serI), field('Installed on', instI)),
    el('div', { class:'grid g-form' }, field('Warranty until', warrI), field('Service provider', provI)),
    el('div', { class:'grid g-form' },
      field('Service every (days)', intI),
      field(moduleCode === 'fire' ? 'Next inspection due' : 'Next service due', nextI)),
    el('div', { class:'grid g-form' },
      field('Condition', condI),
      field('Status', statI, { hint: canRetire ? null : 'Only someone with approval rights can retire an item' })),
    field('Notes', noteI));

  const res = await modal({ title: a ? 'Edit ' + a.asset_code : 'Add a ' + kind.noun, body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', validate: () => {
        if (!codeI.value.trim() || !nameI.value.trim()){ err('A code and a name are required.'); return false; }
        return true; }, value:true }
  ]});
  if (!res) return;

  const payload = {
    asset_code: codeI.value.trim().toUpperCase(),
    asset_type: kind.type,
    name: nameI.value.trim(),
    location: locI.value.trim() || null,
    floor: flrI.value === '' ? null : Number(flrI.value),
    capacity: capI.value.trim() || null,
    manufacturer: makeI.value.trim() || null,
    model: modelI.value.trim() || null,
    serial_no: serI.value.trim() || null,
    installation_date: instI.value || null,
    warranty_expiry: warrI.value || null,
    service_interval_days: intI.value === '' ? null : Number(intI.value),
    service_provider_id: provI.value || null,
    department_id: deptI.value || null,
    condition: condI.value,
    notes: noteI.value.trim() || null
  };
  if (moduleCode === 'fire') payload.next_inspection_date = nextI.value || null;
  else payload.next_service_date = nextI.value || null;
  if (canRetire) payload.status = statI.value;

  const { insert, update } = await import('../core/db.js');
  try {
    if (a) await update('assets', a.id, payload);
    else   await insert('assets', payload);
    ok('Saved'); refresh();
  } catch { /* toast shown */ }
}

async function startRunDialog(assets){
  const gen = assets.filter(a => a.status !== 'RETIRED');
  if (!gen.length) return err('Add a generator to the register first.');

  const now = new Date();
  const local = (d) => new Date(d.getTime() - d.getTimezoneOffset()*60000).toISOString().slice(0,16);
  const assetI = select(gen.map(a => ({ value:a.id, label:a.name })), { value: gen[0].id });
  const startI = el('input', { type:'datetime-local', value: local(now), required:true });
  const outI   = el('input', { type:'datetime-local', value: local(now) });
  const reasonI= select([['POWER_CUT','Power cut'],['TESTING','Test run'],['MAINTENANCE','Maintenance'],['OTHER','Other']]
                  .map(([v,l]) => ({ value:v, label:l })), { value:'POWER_CUT' });
  const hourI  = el('input', { type:'number', step:'0.1', inputmode:'decimal', placeholder:'hour meter now' });

  const body = el('div', {},
    gen.length > 1 ? field('Generator', assetI) : null,
    el('div', { class:'grid g-form' },
      field('Power went at', outI),
      field('Generator started at', startI, { required:true })),
    el('div', { class:'grid g-form' }, field('Reason', reasonI), field('Hour meter', hourI)),
    el('p', { class:'hint', text:'Save this now and come back to stop it when the power returns.' }));

  const res = await modal({ title:'Log a power cut', body, actions:[
    { label:'Cancel', value:null },
    { label:'Generator started', kind:'primary', value:true }
  ]});
  if (!res) return;
  try {
    await rpc('log_generator_run', {
      p_asset: assetI.value, p_gen_start: new Date(startI.value).toISOString(),
      p_gen_stop: null,
      p_outage_start: outI.value ? new Date(outI.value).toISOString() : null,
      p_outage_end: null, p_reason: reasonI.value,
      p_hour_start: hourI.value === '' ? null : Number(hourI.value),
      p_hour_stop: null, p_fuel_litres: null, p_remark: null
    });
    ok('Logged. Stop it when the power returns.');
    refresh();
  } catch { /* toast shown */ }
}

async function stopRunDialog(run){
  const now = new Date();
  const local = (d) => new Date(d.getTime() - d.getTimezoneOffset()*60000).toISOString().slice(0,16);
  const stopI = el('input', { type:'datetime-local', value: local(now), required:true });
  const hourI = el('input', { type:'number', step:'0.1', inputmode:'decimal',
                              value: run.hour_meter_start ?? '', placeholder:'hour meter now' });
  const remI  = el('textarea', { rows:2, placeholder:'Anything wrong?' });

  const body = el('div', {},
    el('p', { class:'muted small', text:'Running since ' + fdatetime(run.gen_start) }),
    field('Generator stopped at', stopI, { required:true }),
    field('Hour meter', hourI),
    field('Problem or remark', remI));

  const res = await modal({ title:'Stop the generator', body, actions:[
    { label:'Cancel', value:null },
    { label:'Generator stopped', kind:'primary', value:true }
  ]});
  if (!res) return;
  try {
    await rpc('close_generator_run', {
      p_run: run.id, p_gen_stop: new Date(stopI.value).toISOString(),
      p_hour_stop: hourI.value === '' ? null : Number(hourI.value),
      p_outage_end: new Date(stopI.value).toISOString(),
      p_remark: remI.value.trim() || null
    });
    ok('Run closed'); refresh();
  } catch { /* toast shown */ }
}

async function fuelDialog(assets){
  const [vendors, accounts] = await Promise.all([ref('vendors'), ref('accounts')]);
  const assetI = select(assets.map(a => ({ value:a.id, label:a.name })), { value: assets[0]?.id });
  const dateI  = el('input', { type:'date', value: todayISO(), required:true });
  const typeI  = select([['DIESEL','Diesel'],['ENGINE_OIL','Engine oil'],['COOLANT','Coolant'],['OTHER','Other']]
                  .map(([v,l]) => ({ value:v, label:l })), { value:'DIESEL' });
  const qtyI   = el('input', { type:'number', step:'0.001', min:'0.001', inputmode:'decimal', required:true });
  const priceI = el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal', required:true });
  const vendI  = select(vendors.map(v => ({ value:v.id, label:v.name })), { placeholder:'None' });
  const invI   = el('input', { type:'text', maxlength:'60', placeholder:'Invoice number' });
  const hourI  = el('input', { type:'number', step:'0.1', inputmode:'decimal', placeholder:'hour meter' });
  const acctI  = select(accounts.map(a => ({ value:a.id, label:a.name })), { placeholder:'Default cash account' });
  const total  = el('p', { class:'hint' });

  const sync = () => {
    const q1 = Number(qtyI.value || 0), p1 = Number(priceI.value || 0);
    total.textContent = q1 > 0 && p1 > 0
      ? `Total: ${money(Math.round(q1 * p1 * 100) / 100)} — the exact figure is worked out by the database.`
      : '';
  };
  qtyI.oninput = priceI.oninput = sync;

  const body = el('div', {},
    field('Generator', assetI),
    el('div', { class:'grid g-form' }, field('Date', dateI, { required:true }), field('What was bought', typeI)),
    el('div', { class:'grid g-form' },
      field('Quantity (litres)', qtyI, { required:true }),
      field('Price per litre', priceI, { required:true })),
    total,
    el('div', { class:'grid g-form' }, field('Supplier', vendI), field('Invoice number', invI)),
    el('div', { class:'grid g-form' }, field('Hour meter', hourI), field('Paid from', acctI)),
    el('p', { class:'hint', text:'This becomes an expense in the ledger. Whether it posts straight away or waits for approval depends on your role.' }));

  const res = await modal({ title:'Record a fuel purchase', body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', validate: () => {
        if (!(Number(qtyI.value) > 0)){ err('Enter a quantity.'); return false; }
        if (!(Number(priceI.value) >= 0)){ err('Enter a price.'); return false; }
        return true; }, value:true }
  ]});
  if (!res) return;
  try {
    await rpc('record_fuel_purchase', {
      p_asset: assetI.value, p_date: dateI.value, p_fuel_type: typeI.value,
      p_quantity: Number(qtyI.value), p_unit_price: Number(priceI.value), p_unit:'LITRE',
      p_vendor: vendI.value || null, p_invoice: invI.value.trim() || null,
      p_hour_meter: hourI.value === '' ? null : Number(hourI.value),
      p_account: acctI.value || null, p_method:'CASH'
    });
    invalidate('balances');
    ok('Recorded'); refresh();
  } catch { /* toast shown */ }
}

async function serviceDialog(a){
  const [vendors, accounts] = await Promise.all([ref('vendors'), ref('accounts')]);
  const dateI = el('input', { type:'date', value: todayISO(), required:true });
  const typeI = select([['ROUTINE','Routine service'],['REPAIR','Repair'],['BREAKDOWN','Breakdown'],
                        ['PART_REPLACEMENT','Part replacement'],['OTHER','Other']]
                  .map(([v,l]) => ({ value:v, label:l })), { value:'ROUTINE' });
  const descI = el('input', { type:'text', required:true, maxlength:'200', placeholder:'What was done?' });
  const costI = el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal', value:'0' });
  const vendI = select(vendors.map(v => ({ value:v.id, label:v.name })),
                       { value: a.service_provider_id, placeholder:'None' });
  const techI = el('input', { type:'text', maxlength:'80', placeholder:'Who came?' });
  const nextI = el('input', { type:'date' });
  const acctI = select(accounts.map(x => ({ value:x.id, label:x.name })), { placeholder:'Default cash account' });
  const partI = el('input', { type:'text', maxlength:'80', placeholder:'Part replaced (optional)' });
  const pcostI= el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal', placeholder:'0.00' });

  const body = el('div', {},
    el('div', { class:'grid g-form' }, field('Date', dateI, { required:true }), field('Type', typeI)),
    field('What was done', descI, { required:true }),
    el('div', { class:'grid g-form' }, field('Technician', techI), field('Company', vendI)),
    el('div', { class:'grid g-form' },
      field('Cost', costI, { hint:'Leave at 0 if there was nothing to pay' }),
      field('Paid from', acctI)),
    field('Next service due', nextI,
      { hint: a.service_interval_days ? `Leave blank to use the ${a.service_interval_days}-day interval` : null }),
    el('fieldset', {}, el('legend', {}, 'Part replaced'),
      el('div', { class:'grid g-form' }, field('Part', partI), field('Part cost', pcostI))));

  const res = await modal({ title:'Record a service — ' + a.name, body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', validate: () => {
        if (!descI.value.trim()){ err('Describe what was done.'); return false; }
        return true; }, value:true }
  ]});
  if (!res) return;

  const parts = partI.value.trim()
    ? [{ part_name: partI.value.trim(), quantity: 1, unit_cost: Number(pcostI.value || 0) }] : [];
  try {
    await rpc('record_asset_service', {
      p_asset: a.id, p_date: dateI.value, p_service_type: typeI.value,
      p_description: descI.value.trim(), p_cost: Number(costI.value || 0),
      p_vendor: vendI.value || null, p_technician: techI.value.trim() || null,
      p_next_due: nextI.value || null, p_account: acctI.value || null,
      p_method: 'CASH', p_parts: parts, p_notes: null
    });
    invalidate('balances');
    ok('Service recorded'); refresh();
  } catch { /* toast shown */ }
}

async function inspectionDialog(a){
  const s = settings();
  const dateI = el('input', { type:'date', value: todayISO(), required:true });
  const resI  = select([['PASS','Pass — all in order'],['NEEDS_ATTENTION','Needs attention'],['FAIL','Fail']]
                  .map(([v,l]) => ({ value:v, label:l })), { value:'PASS' });
  const inspI = el('input', { type:'text', maxlength:'80', placeholder:'Who inspected it?' });
  const nextI = el('input', { type:'date' });
  const remI  = el('textarea', { rows:2 });
  const press = el('input', { type:'checkbox' }); press.checked = true;
  const seal  = el('input', { type:'checkbox' }); seal.checked = true;
  const access= el('input', { type:'checkbox' }); access.checked = true;

  const body = el('div', {},
    el('div', { class:'grid g-form' }, field('Date', dateI, { required:true }), field('Result', resI)),
    el('fieldset', {}, el('legend', {}, 'Checks'),
      el('label', { class:'check' }, press,  el('span', { text:'Pressure gauge in the green' })),
      el('label', { class:'check' }, seal,   el('span', { text:'Seal and pin intact' })),
      el('label', { class:'check' }, access, el('span', { text:'Access clear, sign visible' }))),
    el('div', { class:'grid g-form' }, field('Inspector', inspI),
      field('Next inspection due', nextI, { hint:`Leave blank for ${a.service_interval_days || 180} days from now` })),
    field('Remarks', remI));

  const res = await modal({ title:'Inspection — ' + a.name, body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', value:true }
  ]});
  if (!res) return;
  try {
    await rpc('record_inspection', {
      p_asset: a.id, p_date: dateI.value, p_result: resI.value,
      p_next_date: nextI.value || null, p_inspector: inspI.value.trim() || null,
      p_pressure_ok: press.checked, p_seal_ok: seal.checked, p_access_clear: access.checked,
      p_remarks: remI.value.trim() || null
    });
    ok('Inspection recorded'); refresh();
  } catch { /* toast shown */ }
}
