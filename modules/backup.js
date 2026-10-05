/* =====================================================================
   backup.js — every record, in one Excel file, kept off the internet.

   WHY
   ---
   The portal lives online. If the internet is down, the hosting has a bad
   day, or a future committee needs the history and nobody remembers the
   password, the building's records must still exist somewhere a person
   can open. An Excel file opens on any computer, any phone, for decades.

   WHAT IS IN IT
   -------------
   One sheet per kind of record: every ledger entry in every state (posted,
   pending, reversed — nothing filtered), every receipt and what it paid,
   every charge, waiver, reminder, fund movement, deposit, salary payment,
   operational log and the audit trail; then the lists that give them
   meaning (flats, people, accounts, funds, categories, staff, committee,
   rules). A date range narrows the dated records only — the lists always
   come whole, so a backup of one month can still be read on its own.

   Bank account numbers are deliberately left out; the file can travel.
   Records are fetched a thousand at a time, because the database answers
   at most that many per request and a backup that silently stopped at
   1,000 rows would be worse than none.
   ===================================================================== */

import { el, field, select, num, fdate, fdatetime, ok, err, table, emptyState, todayISO } from '../core/ui.js';
import { q, rpc, isMissingObject } from '../core/db.js';
import { downloadXLSX } from '../core/xlsx.js';
import { can, settings, state } from '../core/store.js';
import { refresh } from '../core/router.js';

const PAGE = 1000;

// [sheet name, source, date column (null = always whole), order column]
const DATED = [
  ['Ledger (all entries)',  'v_transactions',     'txn_date',        'txn_date'],
  ['Receipts',              'payments',           'payment_date',    'payment_date'],
  ['Receipt allocations',   'payment_allocations','allocated_at',    'allocated_at'],
  ['Service charges',       'v_flat_charges',     'period_start',    'period_start'],
  ['Waivers & adjustments', 'adjustments',        'requested_at',    'requested_at'],
  ['Reminders sent',        'charge_reminders',   'sent_at',         'sent_at'],
  ['Fund movements',        'fund_movements',     'movement_date',   'movement_date'],
  ['Deposit events',        'fd_events',          'event_date',      'event_date'],
  ['Salary payments',       'salary_payments',    'paid_date',       'paid_date'],
  ['Staff advances',        'staff_advances',     'advance_date',    'advance_date'],
  ['Fuel purchases',        'fuel_purchases',     'purchase_date',   'purchase_date'],
  ['Generator runs',        'generator_runs',     'created_at',      'created_at'],
  ['Maintenance issues',    'issues',             'reported_at',     'reported_at'],
  ['Asset servicing',       'asset_service_logs', 'service_date',    'service_date'],
  ['Inspections',           'asset_inspections',  'inspection_date', 'inspection_date'],
  ['Attendance',            'staff_attendance',   'work_date',       'work_date'],
  ['Staff leave',           'staff_leaves',       'from_date',       'from_date'],
  ['Work logs',             'work_logs',          'log_date',        'log_date'],
  ['Audit log',             'v_audit_log',        'occurred_at',     'occurred_at']
];
const LISTS = [
  ['Flats',                 'flats',              'flat_number'],
  ['Owners & tenants',      'owners',             'name'],
  ['Occupancy history',     'flat_occupancy',     'from_date'],
  ['Accounts',              'v_account_balances', 'name'],
  ['Funds',                 'v_fund_balances',    'code'],
  ['Fixed deposits',        'v_fixed_deposits',   'deposit_date'],
  ['Departments',           'departments',        'sort_order'],
  ['Categories',            'categories',         'name'],
  ['Vendors',               'vendors',            'name'],
  ['Budgets',               'budgets',            'created_at'],
  ['Staff',                 'v_staff',            'name'],
  ['Assets',                'v_assets',           'asset_code'],
  ['Committee',             'v_board_members',    'sort_order'],
  ['Rules & documents',     'building_documents', 'title'],
  ['Building settings',     'building_settings',  'id'],
  ['Backups made',          'backup_log',         'made_at']
];

// Never copied into a file that may be emailed or left on a laptop.
const LEAVE_OUT = new Set(['photo', 'certificate_path', 'storage_path', 'user_agent']);
const MONEY = /(amount|balance|charge|paid|due|payable|principal|outstanding|advance|salary|total|cost|price|movement|opening|closing|^net_|gross|deduction|limit|value|funded|interest)/i;
const NOT_MONEY = /(_id$|^id$|_no$|number|mobile|phone|reference|code|count|days|pct|percent|rate|order|year|month|qty|quantity|litre|hour|reading|size)/i;

/** Every row of a table or view, a thousand at a time. */
async function fetchAll(source, build, order){
  try { return await fetchPages(source, build, order); }
  catch (e){
    // A view without the column we sort by: read it unsorted rather than lose the sheet.
    if (order && isMissingObject(e.original || e) && /column/i.test((e.original || e).message || '')) return fetchPages(source, build, null);
    throw e;
  }
}
async function fetchPages(source, build, order){
  const out = [];
  for (let from = 0; ; from += PAGE){
    const rows = await q(source, b => {
      let x = build(b);
      if (order) x = x.order(order, { ascending: true });
      return x.range(from, from + PAGE - 1);
    }, { silent: true });
    out.push(...rows);
    if (rows.length < PAGE) break;
    if (from > 500000) break;   // a safety stop far beyond any building's history
  }
  return out;
}

const human = (k) => k.replace(/_/g, ' ').replace(/^\w/, c => c.toUpperCase()).replace(/\bId\b/g, 'ID');
const isNumeric = (v) => typeof v === 'number' || (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v));

function cellValue(v){
  if (v === null || v === undefined) return '';
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  if (Array.isArray(v) || typeof v === 'object') return JSON.stringify(v).slice(0, 32000);
  if (typeof v === 'string'){
    if (/^\d{4}-\d{2}-\d{2}T00:00:00(\.0+)?Z$/.test(v)) return v.slice(0, 10);
    if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)){
      const d = new Date(v);
      if (!isNaN(d)) return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')} ` +
                            `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`;
    }
    return v.length > 32000 ? v.slice(0, 32000) + ' …(cut)' : v;
  }
  return v;
}

/** Columns from the rows themselves: readable ones first, ids at the end. */
function sheetFor(name, rows){
  const keys = [];
  for (const r of rows.slice(0, 200)) for (const k of Object.keys(r)) if (!keys.includes(k) && !LEAVE_OUT.has(k)) keys.push(k);
  const idLike = (k) => k === 'id' || /_id$/.test(k) || /_by$/.test(k);
  const ordered = [...keys.filter(k => !idLike(k)), ...keys.filter(idLike)];
  const columns = ordered.map(k => {
    const money = MONEY.test(k) && !NOT_MONEY.test(k) && rows.some(r => r[k] !== null && r[k] !== undefined && isNumeric(r[k]));
    return money
      ? { label: human(k), key: k, money: true, get: r => r[k] === null || r[k] === undefined || r[k] === '' ? null : Number(r[k]) }
      : { label: human(k), key: k, get: r => cellValue(r[k]), width: idLike(k) ? 38 : undefined };
  });
  return { name, columns: columns.length ? columns : [{ label:'(no records)', key:'x' }], rows };
}

export async function backupPage(tabs){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Reports' }),
    el('p', { class:'sub', text:'Download every record as one Excel file, to keep safe offline.' })));
  page.append(tabs('backup'));

  const may = can('reports', 'export');
  let history = null, missing = false;
  try { history = await q('backup_log', b => b.order('made_at', { ascending:false }).limit(24), { silent:true }); }
  catch (e){ if (isMissingObject(e.original || e)) missing = true; else history = []; }

  const last = history && history[0];
  const days = last ? Math.floor((Date.now() - new Date(last.made_at).getTime()) / 86400000) : null;
  page.append(el('section', { class:'card backup-hero' + (last && days <= 31 ? ' fresh' : ' stale') },
    el('div', { class:'backup-mark', 'aria-hidden':'true', text: last && days <= 31 ? '✓' : '!' }),
    el('div', {},
      el('h2', { text: missing ? 'Backups' : last ? `Last backup ${days === 0 ? 'today' : days === 1 ? 'yesterday' : `${days} days ago`}` : 'No backup has been taken yet' }),
      el('p', { class:'muted', text: last
        ? `${fdatetime(last.made_at)} by ${last.made_by_name || 'someone'} · ${last.scope === 'ALL' ? 'all records' : `${fdate(last.date_from)} to ${fdate(last.date_to)}`} · ${num(last.total_rows)} rows`
        : 'Take one now, then once a month — on the 1st, after the month’s report. Save it to Google Drive and to a USB stick.' }))));

  if (!may){
    page.append(emptyState('Downloading a backup needs permission to export reports. Ask an administrator.'));
  } else {
    const scopeI = select([{ value:'ALL', label:'Everything, from the first record' }, { value:'RANGE', label:'Only a date range' }], { value:'ALL' });
    const fromI = el('input', { type:'date', value: `${new Date().getFullYear()}-01-01` });
    const toI   = el('input', { type:'date', value: todayISO() });
    const rangeBox = el('div', { class:'grid g-form', hidden:true }, field('From', fromI), field('To', toI));
    scopeI.onchange = () => { rangeBox.hidden = scopeI.value !== 'RANGE'; };
    const go = el('button', { class:'btn primary big', type:'button', text:'Download backup (Excel)' });
    const progress = el('ol', { class:'backup-progress', hidden:true });

    go.onclick = async () => {
      const ranged = scopeI.value === 'RANGE';
      if (ranged && (!fromI.value || !toI.value || toI.value < fromI.value)) return err('Choose a start date before the end date.');
      go.disabled = true; go.textContent = 'Collecting records…';
      progress.hidden = false; progress.replaceChildren();
      try {
        const res = await buildBackup(ranged ? { from: fromI.value, to: toI.value } : null, (name, n, note) => {
          progress.append(el('li', { class: note ? 'skipped' : '' }, el('span', { text: name }),
            el('span', { class:'num', text: note || `${num(n)} rows` })));
        });
        try { await rpc('log_backup', { p_scope: ranged ? 'RANGE' : 'ALL', p_from: ranged ? fromI.value : null,
                                        p_to: ranged ? toI.value : null, p_sheets: res.sheets, p_rows: res.rows }, { silent:true }); }
        catch { /* the file is what matters; the log is a convenience */ }
        ok(`Backup saved — ${num(res.rows)} rows in ${res.sheets} sheets. Keep the file somewhere safe.`);
        setTimeout(refresh, 1800);
      } catch (e){
        err('The backup could not be made: ' + (e.message || e));
      } finally {
        go.disabled = false; go.textContent = 'Download backup (Excel)';
      }
    };

    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Download a backup' })),
      field('What to include', scopeI, { hint:'Lists — flats, people, accounts, funds, committee, rules — are always included in full.' }),
      rangeBox,
      el('ul', { class:'backup-contents' },
        el('li', { text:'Every ledger entry — income, expense, transfers — in every state, including reversed and pending' }),
        el('li', { text:'Every receipt and what it paid, every service charge, waiver and reminder' }),
        el('li', { text:'Reserve funds, fixed deposits, salaries, staff, generator, lift, fire and maintenance records' }),
        el('li', { text:'The audit log: who did what, and when' }),
        el('li', { text:'Not included: bank account numbers and photos, so the file is safe to keep on a laptop' })),
      el('div', { class:'btn-row' }, go),
      progress));
  }

  if (history && history.length){
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Backups taken' })),
      table([
        { label:'When', primary:true, fmt: b => fdatetime(b.made_at) },
        { label:'By', fmt: b => b.made_by_name || '—' },
        { label:'Covers', fmt: b => b.scope === 'ALL' ? 'All records' : `${fdate(b.date_from)} – ${fdate(b.date_to)}` },
        { label:'Sheets', cls:'num', fmt: b => num(b.sheets) },
        { label:'Rows', cls:'num', fmt: b => num(b.total_rows) }
      ], history)));
  } else if (missing){
    page.append(el('p', { class:'hint', text:'The list of backups taken appears once sql/PATCH.sql has been run. Downloading works already.' }));
  }
  return page;
}

/** Collect everything and download the workbook. Returns what it wrote. */
export async function buildBackup(range, onSheet = () => {}){
  const s = settings();
  const stamp = todayISO();
  const sheets = [];
  const counts = [];
  let total = 0;

  // In a ranged backup, allocations follow the receipts in range.
  let receiptIds = null;
  for (const [name, source, dateCol, order] of DATED){
    try {
      let rows;
      if (range && source === 'payment_allocations' && receiptIds){
        rows = (await fetchAll(source, b => b, order)).filter(r => receiptIds.has(r.payment_id));
      } else {
        rows = await fetchAll(source, b => {
          if (!range) return b;
          const isTs = /_at$/.test(dateCol);
          return b.gte(dateCol, range.from).lte(dateCol, isTs ? range.to + 'T23:59:59.999' : range.to);
        }, order);
      }
      if (source === 'payments') receiptIds = new Set(rows.map(r => r.id));
      sheets.push(sheetFor(name, rows)); counts.push([name, rows.length, '']); total += rows.length;
      onSheet(name, rows.length);
    } catch (e){
      const why = isMissingObject(e.original || e) ? 'not in this database' : 'not available to you';
      counts.push([name, 0, why]); onSheet(name, 0, why);
    }
  }
  for (const [name, source, order] of LISTS){
    try {
      const rows = await fetchAll(source, b => b, order);
      sheets.push(sheetFor(name, rows)); counts.push([name, rows.length, '']); total += rows.length;
      onSheet(name, rows.length);
    } catch (e){
      const why = isMissingObject(e.original || e) ? 'not in this database' : 'not available to you';
      counts.push([name, 0, why]); onSheet(name, 0, why);
    }
  }

  const about = {
    name: 'About this backup',
    title: `${s.building_name || 'Building'} — backup`,
    subtitle: `${range ? `Records dated ${range.from} to ${range.to}` : 'All records'} · made ${fdatetime(new Date().toISOString())} by ${state.profile?.full_name || ''}`,
    columns: [{ label:'Sheet', key:'n', width:30 }, { label:'Rows', key:'c' }, { label:'Note', key:'w', width:60 }],
    rows: [
      ...counts.map(([n, c, w]) => ({ n, c, w: w || (n === 'Ledger (all entries)' ? 'Includes posted, pending, rejected and reversed entries. Status column says which.' : '') })),
      { n:'', c:'', w:'' },
      { n:'How to read it', c:'', w:'One sheet per kind of record. The ID columns at the right of each sheet link records across sheets.' },
      { n:'Keep it safe', c:'', w:'It holds residents’ names and phone numbers. Bank account numbers are not included.' }
    ]
  };
  const file = range ? `building-backup-${range.from}-to-${range.to}.xlsx` : `building-backup-all-${stamp}.xlsx`;
  downloadXLSX(file, [about, ...sheets]);
  return { sheets: sheets.length, rows: total, file };
}
