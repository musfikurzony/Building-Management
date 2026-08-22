/* Staff, attendance and salary.

   Guards, cleaners, the gardener, the caretaker, the imam — one master
   list. Which department a person's salary lands in is decided by their
   position, so payroll classifies itself. */

import { el, field, select, money, money0, num, fdate, badge, table, stat,
         emptyState, ok, err, modal, confirmBox, downloadCSV, todayISO, monthName } from '../core/ui.js';
import { q, one, rpc, insert, update, logEvent } from '../core/db.js';
import { can, ref, state, invalidate } from '../core/store.js';
import { go, refresh } from '../core/router.js';

const now = new Date();

export async function render({ params }){
  if (params[0] === 'attendance') return attendance();
  if (params[0] === 'salary')     return salary();
  if (params[0])                  return detail(params[0]);
  return list();
}

/* ==================================================================
   THE LIST
   ================================================================== */
async function list(){
  const rows = await ref('staff', true);
  const active = rows.filter(r => r.status === 'ACTIVE');
  const payroll = active.reduce((t,r) => t + Number(r.salary || 0), 0);

  const page = el('div', {});
  page.append(el('div', { class:'page-head' }, el('h1', { text:'Staff' })));
  page.append(el('div', { class:'grid g-stats' },
    stat('On the books', num(active.length), `${rows.length - active.length} inactive`),
    stat('Monthly payroll', money0(payroll)),
    stat('In today', num(active.filter(r => r.today_status === 'PRESENT').length),
         active.filter(r => r.today_status === 'ABSENT').length
           ? active.filter(r => r.today_status === 'ABSENT').length + ' absent' : null),
    stat('Advances outstanding', money0(rows.reduce((t,r) => t + Number(r.advance_outstanding || 0), 0)))));

  const bar = el('div', { class:'toolbar' });
  if (can('staff','add'))
    bar.append(el('button', { class:'btn primary', text:'＋ Add staff', onclick: () => staffDialog(null) }));
  if (can('staff','add'))
    bar.append(el('a', { class:'btn primary', href:'#/staff/attendance', text:'Mark attendance' }));
  if (can('salary','view'))
    bar.append(el('a', { class:'btn', href:'#/staff/salary', text:'Salary' }));
  bar.append(el('span', { class:'spacer' }));

  const cols = [
    { label:'Name', primary:true, key:'name' },
    { label:'Code', cls:'mono', key:'staff_code' },
    { label:'Position', key:'position_name' },
    { label:'Department', fmt: r => r.department_name || '—', csv: r => r.department_name },
    { label:'Mobile', fmt: r => r.mobile || '—', csv: r => r.mobile },
    { label:'Shift', fmt: r => r.shift ? r.shift.toLowerCase() : '—', csv: r => r.shift },
    { label:'Monthly salary', cls:'num', fmt: r => money(r.salary, { bare:true }), csv: r => r.salary },
    { label:'This month', fmt: r => `${r.present_this_month} in, ${r.absent_this_month} out`,
      csv: r => `${r.present_this_month}/${r.absent_this_month}` },
    { label:'Status', fmt: r => badge(r.status), csv: r => r.status }
  ];
  if (can('staff','export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV('staff.csv', cols, rows); logEvent('EXPORT', { module:'staff' });
    }}));
  page.append(bar);
  page.append(table(cols, rows, { onRow: r => go('#/staff/' + r.id),
    empty:'Nobody on the list yet. Add the guards, the cleaner and the caretaker.' }));
  return page;
}

async function detail(id){
  const s = await one('v_staff', b => b.eq('id', id));
  if (!s) return emptyState('That person is not on the list, or you cannot see them.');

  const [att, adv, pay] = await Promise.all([
    q('staff_attendance', b => b.eq('staff_id', id).order('work_date', { ascending:false }).limit(60)).catch(() => []),
    can('salary','view') ? q('staff_advances', b => b.eq('staff_id', id).order('advance_date', { ascending:false })).catch(() => []) : [],
    can('salary','view') ? q('v_salary_payments', b => b.eq('staff_id', id).order('period_year', { ascending:false }).order('period_month', { ascending:false })).catch(() => []) : []
  ]);

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: s.name }),
    el('p', { class:'sub', text: `${s.position_name}${s.department_name ? ' · ' + s.department_name : ''} · joined ${fdate(s.joining_date)}` })));

  page.append(el('div', { class:'grid g-stats' },
    stat('Monthly salary', money(s.salary)),
    stat('Present this month', num(s.present_this_month)),
    stat('Absent this month', num(s.absent_this_month), null, s.absent_this_month ? 'bad' : 'good'),
    stat('Advance outstanding', money(s.advance_outstanding), null,
         Number(s.advance_outstanding) > 0 ? 'bad' : '')));

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/staff', text:'← Staff' }));
  if (can('staff','edit'))
    bar.append(el('button', { class:'btn', text:'Edit details', onclick: () => staffDialog(s) }));
  if (can('salary','add'))
    bar.append(el('button', { class:'btn', text:'Record an advance', onclick: () => advanceDialog(s) }));
  page.append(bar);

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Contact' })),
    el('dl', { class:'dl' },
      el('dt', { text:'Mobile' }), el('dd', { text: s.mobile || '—' }),
      el('dt', { text:'Address' }), el('dd', { text: s.address || '—' }),
      el('dt', { text:'Emergency' }), el('dd', { text: s.emergency_contact || '—' }),
      el('dt', { text:'Shift' }), el('dd', { text: s.shift ? s.shift.toLowerCase() : '—' }),
      s.notes ? el('dt', { text:'Notes' }) : null,
      s.notes ? el('dd', { style:'white-space:pre-wrap', text: s.notes }) : null)));

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Recent attendance' })),
    table([
      { label:'Date', primary:true, fmt: r => fdate(r.work_date), csv: r => r.work_date },
      { label:'Status', fmt: r => badge(r.status), csv: r => r.status },
      { label:'Remarks', fmt: r => r.remarks || '—', csv: r => r.remarks }
    ], att, { empty:'No attendance recorded yet.' })));

  if (can('salary','view') && pay.length){
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Salary history' })),
      table([
        { label:'Month', primary:true, fmt: r => monthName(r.period_year, r.period_month),
          csv: r => monthName(r.period_year, r.period_month) },
        { label:'Base', cls:'num', fmt: r => money(r.base_salary, { bare:true }), csv: r => r.base_salary },
        { label:'Absent', cls:'num', key:'absent_days' },
        { label:'Deducted', cls:'num', fmt: r => money(r.deduction, { bare:true }), csv: r => r.deduction },
        { label:'Advance', cls:'num', fmt: r => money(r.advance_recovery, { bare:true }), csv: r => r.advance_recovery },
        { label:'Net', cls:'num', fmt: r => money(r.net_payable, { bare:true }), csv: r => r.net_payable },
        { label:'Status', fmt: r => badge(r.status), csv: r => r.status }
      ], pay)));
  }

  if (can('salary','view') && adv.length){
    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Advances' })),
      table([
        { label:'Date', primary:true, fmt: r => fdate(r.advance_date), csv: r => r.advance_date },
        { label:'Amount', cls:'num', fmt: r => money(r.amount, { bare:true }), csv: r => r.amount },
        { label:'Recovered', cls:'num', fmt: r => money(r.recovered_amount, { bare:true }), csv: r => r.recovered_amount },
        { label:'Still owed', cls:'num',
          fmt: r => money(Number(r.amount) - Number(r.recovered_amount), { bare:true }),
          csv: r => Number(r.amount) - Number(r.recovered_amount) },
        { label:'Reason', fmt: r => r.reason || '—', csv: r => r.reason }
      ], adv)));
  }
  return page;
}

async function staffDialog(s){
  const positions = await ref('positions');
  const codeI = el('input', { type:'text', required:true, maxlength:'20', value: s?.staff_code || '' });
  const nameI = el('input', { type:'text', required:true, value: s?.name || '' });
  const posI  = select(positions.map(p => ({ value:p.id, label:p.name })), { value: s?.position_id });
  const mobI  = el('input', { type:'tel', value: s?.mobile || '', placeholder:'01XXXXXXXXX' });
  const addrI = el('textarea', { rows:2, value: s?.address || '' });
  const emgI  = el('input', { type:'text', value: s?.emergency_contact || '' });
  const joinI = el('input', { type:'date', required:true, value: s?.joining_date || todayISO() });
  const leftI = el('input', { type:'date', value: s?.leaving_date || '' });
  const salI  = el('input', { type:'number', step:'0.01', min:'0', inputmode:'decimal', value: s?.salary ?? '' });
  const shiftI= select([['GENERAL','General'],['MORNING','Morning'],['EVENING','Evening'],['NIGHT','Night']]
                  .map(([v,l]) => ({ value:v, label:l })), { value: s?.shift, placeholder:'Not set' });
  const statI = select([{ value:'ACTIVE', label:'Active' }, { value:'INACTIVE', label:'Inactive' }],
                       { value: s?.status || 'ACTIVE' });
  const noteI = el('textarea', { rows:2, value: s?.notes || '' });

  const body = el('div', {},
    el('div', { class:'grid g-form' }, field('Staff code', codeI, { required:true, hint:'e.g. S-001' }),
      field('Name', nameI, { required:true })),
    el('div', { class:'grid g-form' }, field('Position', posI, { required:true }),
      field('Monthly salary', salI, { required:true })),
    el('div', { class:'grid g-form' }, field('Mobile', mobI), field('Shift', shiftI)),
    field('Address', addrI),
    el('div', { class:'grid g-form' }, field('Emergency contact', emgI), field('Joined on', joinI, { required:true })),
    el('div', { class:'grid g-form' }, field('Left on', leftI), field('Status', statI)),
    field('Notes', noteI));

  const res = await modal({ title: s ? 'Edit ' + s.name : 'Add staff', body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', validate: () => {
        if (!codeI.value.trim() || !nameI.value.trim()){ err('A code and a name are required.'); return false; }
        if (!posI.value){ err('Choose a position.'); return false; }
        return true; }, value:true }
  ]});
  if (!res) return;

  const payload = {
    staff_code: codeI.value.trim().toUpperCase(), name: nameI.value.trim(),
    position_id: posI.value, mobile: mobI.value.trim() || null,
    address: addrI.value.trim() || null, emergency_contact: emgI.value.trim() || null,
    joining_date: joinI.value, leaving_date: leftI.value || null,
    salary: Number(salI.value || 0), shift: shiftI.value || null,
    status: statI.value, notes: noteI.value.trim() || null
  };
  try {
    if (s) await update('staff', s.id, payload);
    else   await insert('staff', payload);
    invalidate('staff');
    ok('Saved'); refresh();
  } catch { /* toast shown */ }
}

async function advanceDialog(s){
  const accounts = await ref('accounts');
  const amtI  = el('input', { type:'number', step:'0.01', min:'0.01', inputmode:'decimal', required:true });
  const dateI = el('input', { type:'date', value: todayISO(), required:true });
  const acctI = select(accounts.map(a => ({ value:a.id, label:a.name })), { placeholder:'Choose an account' });
  const whyI  = el('input', { type:'text', maxlength:'120', placeholder:'Reason' });

  const body = el('div', {},
    el('p', { class:'muted small', text:
      `${s.name} currently owes ${money(s.advance_outstanding)} in advances.` }),
    el('div', { class:'grid g-form' }, field('Amount', amtI, { required:true }), field('Date', dateI, { required:true })),
    el('div', { class:'grid g-form' }, field('Paid from', acctI, { required:true }), field('Reason', whyI)),
    el('p', { class:'hint', text:'This is an expense now, and it is recovered automatically from the next salary.' }));

  const res = await modal({ title:'Salary advance', body, actions:[
    { label:'Cancel', value:null },
    { label:'Record advance', kind:'primary', validate: () => {
        if (!(Number(amtI.value) > 0)){ err('Enter an amount.'); return false; }
        if (!acctI.value){ err('Choose the account it was paid from.'); return false; }
        return true; }, value:true }
  ]});
  if (!res) return;
  try {
    await rpc('record_staff_advance', {
      p_staff: s.id, p_date: dateI.value, p_amount: Number(amtI.value),
      p_account: acctI.value, p_reason: whyI.value.trim() || null, p_method:'CASH'
    });
    invalidate('balances','staff');
    ok('Advance recorded'); refresh();
  } catch { /* toast shown */ }
}

/* ==================================================================
   ATTENDANCE — one tap per person, built for a phone.
   ================================================================== */
async function attendance(){
  const staff = (await ref('staff', true)).filter(s => s.status === 'ACTIVE');
  const dateI = el('input', { type:'date', value: todayISO(), max: todayISO() });

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Attendance' }),
    el('p', { class:'sub', text:'One tap per person. Marking the same day again corrects it.' })));
  page.append(el('div', { class:'toolbar' },
    el('a', { class:'btn', href:'#/staff', text:'← Staff' }),
    el('div', { style:'flex:1;min-width:10rem' }, field('Date', dateI))));

  const host = el('div', {});
  page.append(host);
  const picks = new Map();

  async function load(){
    host.replaceChildren(el('p', { class:'muted', text:'Loading…' }));
    const existing = await q('staff_attendance', b => b.eq('work_date', dateI.value)).catch(() => []);
    const byStaff = new Map(existing.map(e => [e.staff_id, e.status]));
    picks.clear();

    const card = el('div', { class:'card' });
    for (const s of staff){
      const current = byStaff.get(s.id) || '';
      picks.set(s.id, current);
      const row = el('div', { style:'padding:.6rem 0;border-bottom:1px solid var(--line-soft)' },
        el('div', { style:'font-weight:600', text: s.name }),
        el('div', { class:'small muted', text: `${s.position_name}${s.shift ? ' · ' + s.shift.toLowerCase() : ''}` }));
      const btns = el('div', { class:'btn-row', style:'margin-top:.4rem' });
      for (const [val, label] of [['PRESENT','Present'],['ABSENT','Absent'],['LEAVE','Leave'],['HALF_DAY','Half day']]){
        const b = el('button', { class:'btn small' + (current === val ? ' primary' : ''), text: label });
        b.onclick = () => {
          picks.set(s.id, val);
          for (const other of btns.children) other.className = 'btn small';
          b.className = 'btn small primary';
        };
        btns.append(b);
      }
      row.append(btns);
      card.append(row);
    }
    if (!staff.length) card.append(emptyState('Add some staff first.'));

    const save = el('button', { class:'btn primary', text:'Save attendance' });
    save.onclick = async () => {
      const entries = [...picks.entries()].filter(([,v]) => v)
        .map(([staff_id, status]) => ({ staff_id, status }));
      if (!entries.length) return err('Mark at least one person.');
      save.disabled = true;
      try {
        const n = await rpc('mark_attendance', { p_work_date: dateI.value, p_entries: entries });
        ok(`Saved for ${n} ${n === 1 ? 'person' : 'people'}.`);
        invalidate('staff');
        load();
      } catch { /* toast shown */ } finally { save.disabled = false; }
    };
    host.replaceChildren(card, el('div', { class:'btn-row' }, save));
  }
  dateI.onchange = load;
  await load();
  return page;
}

/* ==================================================================
   SALARY
   ================================================================== */
async function salary(){
  const runs = await q('salary_runs', b => b
    .order('period_year', { ascending:false }).order('period_month', { ascending:false }).limit(24))
    .catch(() => []);

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Salary' }),
    el('p', { class:'sub', text:'Generated from the staff list and the month’s attendance. Every payment posts to the ledger.' })));

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/staff', text:'← Staff' }));
  if (can('salary','add'))
    bar.append(el('button', { class:'btn primary', text:'Generate a month', onclick: () => generateDialog() }));
  page.append(bar);

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Salary runs' })),
    table([
      { label:'Month', primary:true, fmt: r => monthName(r.period_year, r.period_month),
        csv: r => monthName(r.period_year, r.period_month) },
      { label:'Staff', cls:'num', key:'staff_count' },
      { label:'Total', cls:'num', fmt: r => money(r.total_amount, { bare:true }), csv: r => r.total_amount },
      { label:'Generated', fmt: r => fdate(r.generated_at), csv: r => r.generated_at }
    ], runs, { empty:'No salary has been generated yet.' })));

  const latest = runs[0];
  if (latest){
    const lines = await q('v_salary_payments', b => b.eq('run_id', latest.id).order('staff_name'))
      .catch(() => []);
    const accounts = await ref('accounts');

    const cols = [
      { label:'Name', primary:true, key:'staff_name' },
      { label:'Position', key:'position_name' },
      { label:'Base', cls:'num', fmt: r => money(r.base_salary, { bare:true }), csv: r => r.base_salary },
      { label:'Absent', cls:'num', key:'absent_days' },
      { label:'Deducted', cls:'num', fmt: r => money(r.deduction, { bare:true }), csv: r => r.deduction },
      { label:'Advance', cls:'num', fmt: r => money(r.advance_recovery, { bare:true }), csv: r => r.advance_recovery },
      { label:'Net', cls:'num', fmt: r => money(r.net_payable, { bare:true }), csv: r => r.net_payable },
      { label:'Status', fmt: r => badge(r.status), csv: r => r.status },
      { label:'', fmt: r => {
          if (r.status !== 'PENDING' || !can('salary','edit')) return '';
          const b = el('button', { class:'btn small primary', text:'Pay' });
          b.onclick = async (e) => {
            e.stopPropagation();
            const acctI = select(accounts.map(a => ({ value:a.id, label:a.name })), { placeholder:'Choose an account' });
            const dateI = el('input', { type:'date', value: todayISO() });
            const methI = select(['CASH','BANK_TRANSFER','BKASH','CHEQUE'].map(m => ({ value:m, label:m.replace(/_/g,' ') })),
                                 { value:'CASH' });
            const okd = await modal({ title:`Pay ${r.staff_name} — ${money(r.net_payable)}`,
              body: el('div', {},
                field('Paid from', acctI, { required:true }),
                el('div', { class:'grid g-form' }, field('Date', dateI), field('Method', methI))),
              actions:[{ label:'Cancel', value:null },
                       { label:'Pay', kind:'primary',
                         validate: () => { if (!acctI.value){ err('Choose an account.'); return false; } return true; },
                         value:true }]});
            if (!okd) return;
            try {
              await rpc('pay_salary', { p_payment: r.id, p_date: dateI.value,
                                        p_account: acctI.value, p_method: methI.value });
              invalidate('balances','staff');
              ok('Paid'); refresh();
            } catch {}
          };
          return b;
        } }
    ];

    page.append(el('section', { class:'card' },
      el('div', { class:'card-head' },
        el('h2', { text: monthName(latest.period_year, latest.period_month) }),
        can('salary','export') ? el('button', { class:'btn small', text:'CSV',
          onclick: () => downloadCSV(`salary-${latest.period_year}-${latest.period_month}.csv`, cols, lines) }) : null),
      table(cols, lines, { empty:'Nobody on this run.' })));
  }
  return page;
}

async function generateDialog(){
  const y = el('input', { type:'number', value: now.getFullYear(), min:'2000', max:'2200' });
  const m = select(Array.from({length:12}, (_,i) => ({ value:i+1, label: monthName(now.getFullYear(), i+1).split(' ')[0] })),
                   { value: now.getMonth() === 0 ? 12 : now.getMonth() });
  const staff = (await ref('staff')).filter(s => s.status === 'ACTIVE');

  const body = el('div', {},
    el('p', { class:'muted small', text:
      `${staff.length} active staff will be included, each at their own salary. Unexcused absences that month are deducted at one day's pay each, and any outstanding advance is recovered.` }),
    el('div', { class:'grid g-form' }, field('Year', y), field('Month', m)),
    el('p', { class:'hint', text:'Nothing is paid by generating. Each person is paid individually afterwards.' }));

  const res = await modal({ title:'Generate salary', body, actions:[
    { label:'Cancel', value:null }, { label:'Generate', kind:'primary', value:true }
  ]});
  if (!res) return;
  try {
    const run = await rpc('generate_salary_run', { p_year: Number(y.value), p_month: Number(m.value) });
    const row = Array.isArray(run) ? run[0] : run;
    ok(`Generated for ${row?.staff_count ?? staff.length} people, ${money(row?.total_amount ?? 0)} in total.`);
    refresh();
  } catch { /* toast shown */ }
}
