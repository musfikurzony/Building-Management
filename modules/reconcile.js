/* Bank reconciliation.

   The bank statement is the truth; the ledger is our account of it. This
   screen exists to find the places where the two disagree, and it is
   deliberately unwilling to hide one:

   - Auto-matching only pairs a line with a transaction when there is
     exactly ONE candidate. A wrong automatic match is worse than no match,
     because it makes a reconciliation come out clean while the money is
     wrong.
   - A reconciliation that does not balance is saved as DISPUTED rather
     than refused, so the disagreement is on the record with a figure
     attached instead of being abandoned. */

import { el, field, select, money, money0, fdate, table, stat, ok, err,
         modal, confirmBox, emptyState, badge, todayISO, downloadCSV } from '../core/ui.js';
import { q, one, rpc, logEvent } from '../core/db.js';
import { refresh } from '../core/router.js';
import { can, ref } from '../core/store.js';

export async function render({ params }){
  if (params[0]) return statementDetail(params[0]);
  return list();
}

async function list(){
  const rows = await q('v_bank_statements', b => b.order('statement_date', { ascending:false }));
  const open = rows.filter(r => r.status === 'OPEN');

  const cols = [
    { label:'Statement date', primary:true, fmt: r => fdate(r.statement_date), csv: r => r.statement_date },
    { label:'Account', key:'account_name' },
    { label:'Closing per bank', cls:'num', fmt: r => money(r.closing_balance, { bare:true }), csv: r => r.closing_balance },
    { label:'Closing per books', cls:'num', fmt: r => money(r.system_balance, { bare:true }), csv: r => r.system_balance },
    { label:'Difference', cls:'num',
      fmt: r => diffCell(Number(r.closing_balance) - Number(r.system_balance)),
      csv: r => Number(r.closing_balance) - Number(r.system_balance) },
    { label:'Lines', cls:'num', fmt: r => `${r.line_count - r.unmatched_count} / ${r.line_count}`,
      csv: r => r.line_count },
    { label:'Status', fmt: r => badge(r.status), csv: r => r.status }
  ];

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/bank' }, '← Bank & cash'));
  if (can('bank','edit'))
    bar.append(el('button', { class:'btn primary', onclick: () => statementDialog() }, '＋ New statement'));
  bar.append(el('span', { class:'spacer' }));
  if (can('bank','export'))
    bar.append(el('button', { class:'btn small', onclick: () => {
      downloadCSV('bank-statements.csv', cols, rows); logEvent('EXPORT', { module:'bank' }); }}, 'Export CSV'));

  const page = el('div', {},
    el('div', { class:'page-head' }, el('h1', {}, 'Bank reconciliation'),
      el('p', { class:'sub' }, 'Compare what the bank says with what the books say, one statement at a time.')),
    el('div', { class:'grid g-stats' },
      stat('Statements', String(rows.length)),
      stat('Not yet reconciled', String(open.length), open.length ? 'waiting' : 'all done',
           open.length ? 'bad' : 'good'),
      stat('Unmatched lines', String(open.reduce((t,r) => t + Number(r.unmatched_count || 0), 0)),
           'across open statements')));

  page.append(bar);
  page.append(table(cols, rows, { onRow: r => location.hash = '#/reconcile/' + r.id,
    empty:'No statements uploaded yet. Start with the most recent month-end statement from the bank.' }));
  return page;
}

function diffCell(d){
  const v = Math.round(d * 100) / 100;
  if (Math.abs(v) < 0.005) return el('span', { class:'badge b-ok' }, 'agrees');
  return el('span', { class:'badge b-overdue' }, money(v, { bare:true }));
}

async function statementDetail(id){
  const st = await one('v_bank_statements', b => b.eq('id', id));
  if (!st) return emptyState('That statement does not exist, or you cannot see it.');

  const [lines, recs] = await Promise.all([
    q('bank_statement_lines', b => b.eq('statement_id', id).order('line_date')),
    q('reconciliations', b => b.eq('statement_id', id).order('reconciled_at', { ascending:false })).catch(() => [])
  ]);

  const matchedIds = [...new Set(lines.map(l => l.matched_txn_id).filter(Boolean))];
  const txns = matchedIds.length
    ? await q('v_transactions', b => b.in('id', matchedIds)).catch(() => []) : [];
  const txnOf = (tid) => txns.find(t => t.id === tid);

  const diff = Number(st.closing_balance) - Number(st.system_balance);
  const unmatched = lines.filter(l => l.match_status === 'UNMATCHED');

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', {}, `${st.account_name} — ${fdate(st.statement_date)}`),
    el('p', { class:'sub' }, st.notes || 'Bank statement')));

  page.append(el('div', { class:'grid g-stats' },
    stat('Bank says', money(st.closing_balance), 'closing balance on the statement'),
    stat('Books say', money(st.system_balance), 'ledger up to this date'),
    stat('Difference', money(diff), Math.abs(diff) < 0.005 ? 'they agree' : 'they do not agree',
         Math.abs(diff) < 0.005 ? 'good' : 'bad'),
    stat('Unmatched lines', String(unmatched.length),
         unmatched.length ? 'need a decision' : 'every line accounted for',
         unmatched.length ? 'bad' : 'good')));

  if (Math.abs(diff) >= 0.005)
    page.append(el('div', { class:'alert high' },
      el('div', { class:'a-body' },
        el('div', { class:'a-title' }, `The books and the bank differ by ${money(Math.abs(diff))}`),
        el('div', { class:'a-meta' },
          diff > 0
            ? 'The bank holds more than the books show — money came in that has not been entered, or an expense was entered that never left the account.'
            : 'The books show more than the bank holds — an expense has not been entered, or income was entered that never arrived.'))));

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/reconcile' }, '← Statements'));
  if (can('bank','edit') && st.status !== 'RECONCILED'){
    bar.append(el('button', { class:'btn', onclick: () => importDialog(st) }, 'Import lines'));
    bar.append(el('button', { class:'btn', onclick: () => autoMatch(st) }, 'Match automatically'));
    bar.append(el('button', { class:'btn primary', onclick: () => finish(st, diff) }, 'Reconcile'));
  }
  page.append(bar);

  page.append(el('h2', {}, 'Statement lines'));
  page.append(table([
    { label:'Date', primary:true, fmt: l => fdate(l.line_date), csv: l => l.line_date },
    { label:'Description', fmt: l => l.description || '—', csv: l => l.description },
    { label:'Reference', fmt: l => l.reference || '—', csv: l => l.reference },
    { label:'Out', cls:'num', fmt: l => Number(l.debit) ? money(l.debit, { bare:true }) : '—', csv: l => l.debit },
    { label:'In', cls:'num', fmt: l => Number(l.credit) ? money(l.credit, { bare:true }) : '—', csv: l => l.credit },
    { label:'Match', fmt: l => matchCell(l, txnOf(l.matched_txn_id)), csv: l => l.match_status }
  ], lines, {
    onRow: l => (can('bank','edit') && st.status !== 'RECONCILED') ? lineDialog(st, l) : null,
    empty:'No lines imported yet. Import them from the bank’s CSV or type the few that matter.' }));

  if (recs.length){
    page.append(el('h2', {}, 'Reconciliation attempts'));
    page.append(table([
      { label:'When', primary:true, fmt: r => fdate(r.reconciled_at), csv: r => r.reconciled_at },
      { label:'Books', cls:'num', fmt: r => money(r.system_balance, { bare:true }), csv: r => r.system_balance },
      { label:'Bank', cls:'num', fmt: r => money(r.bank_balance, { bare:true }), csv: r => r.bank_balance },
      { label:'Difference', cls:'num', fmt: r => money(r.difference, { bare:true }), csv: r => r.difference },
      { label:'Result', fmt: r => badge(r.status), csv: r => r.status },
      { label:'Notes', fmt: r => r.notes || '—', csv: r => r.notes }
    ], recs, {}));
    page.append(el('p', { class:'hint' },
      'Every attempt is kept, including the ones that did not balance. That history is what shows when a difference first appeared.'));
  }

  return page;
}

function matchCell(l, txn){
  if (l.match_status === 'UNMATCHED') return el('span', { class:'badge b-pending' }, 'unmatched');
  if (l.match_status === 'IGNORED')   return el('span', { class:'badge b-draft' }, 'set aside');
  const label = l.match_status === 'AUTO_MATCHED' ? 'matched' : 'matched by hand';
  return el('span', {}, el('span', { class:'badge b-ok' }, label),
    txn ? el('span', { class:'small muted' }, ' ' + (txn.txn_no || txn.description || '')) : null);
}

async function statementDialog(){
  const accounts = (await ref('balances')).filter(a => a.is_active && ['BANK','MOBILE_WALLET'].includes(a.kind));
  if (!accounts.length) return err('There is no bank account to reconcile yet.');

  const acctI  = select(accounts.map(a => ({ value:a.account_id, label:a.name })), { placeholder:'Choose an account' });
  const dateI  = el('input', { type:'date', value: todayISO(), required:true });
  const fromI  = el('input', { type:'date' });
  const toI    = el('input', { type:'date' });
  const openI  = el('input', { type:'number', step:'0.01', inputmode:'decimal' });
  const closeI = el('input', { type:'number', step:'0.01', required:true, inputmode:'decimal' });
  const noteI  = el('textarea', { rows:'2' });

  const res = await modal({
    title:'New bank statement',
    body: el('div', {},
      field('Account', acctI, { required:true }),
      field('Statement date', dateI, { required:true, hint:'The date the closing balance applies to.' }),
      field('Period from', fromI),
      field('Period to', toI),
      field('Opening balance per bank', openI),
      field('Closing balance per bank', closeI, { required:true,
        hint:'Type the bank’s figure exactly. This is what the books will be checked against.' }),
      field('Notes', noteI)),
    actions: [{ label:'Create statement', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;
  if (!acctI.value) return err('Choose an account.');
  if (closeI.value === '') return err('Enter the closing balance from the statement.');

  try {
    const st = await rpc('create_bank_statement', {
      p_account: acctI.value, p_statement_date: dateI.value,
      p_closing_balance: Number(closeI.value),
      p_period_start: fromI.value || null, p_period_end: toI.value || null,
      p_opening_balance: openI.value === '' ? null : Number(openI.value),
      p_notes: noteI.value.trim() || null
    });
    ok('Statement created.');
    location.hash = '#/reconcile/' + st.id;
  } catch (e){ err(e.message); }
}

/* Paste-a-CSV import. Building staff download a CSV from internet banking;
   asking them to reformat it into JSON would guarantee it never gets used. */
async function importDialog(st){
  const area = el('textarea', { rows:'10',
    placeholder:'date, description, out, in\n2026-08-01, Service charge deposit, , 45000\n2026-08-03, DESCO electricity, 18200,' });
  const preview = el('div', { class:'hint' }, '');

  const parse = () => {
    const out = [];
    for (const line of area.value.split(/\r?\n/)){
      const s = line.trim();
      if (!s) continue;
      const cells = splitCsv(s);
      if (cells.length < 2) continue;
      const d = normDate(cells[0]);
      if (!d) continue;                       // header row or junk — skipped
      const debit  = numOrZero(cells[2]);
      const credit = numOrZero(cells[3]);
      if (!debit && !credit) continue;
      out.push({ line_date: d, description: (cells[1] || '').trim() || null,
                 reference: (cells[4] || '').trim() || null, debit, credit });
    }
    return out;
  };
  const recount = () => {
    const rows = parse();
    const inTotal  = rows.reduce((t,r) => t + r.credit, 0);
    const outTotal = rows.reduce((t,r) => t + r.debit, 0);
    preview.textContent = rows.length
      ? `${rows.length} line${rows.length === 1 ? '' : 's'} read — ${money(inTotal)} in, ${money(outTotal)} out. Lines without a readable date are skipped, so a header row is fine.`
      : 'Nothing readable yet. One line per transaction: date, description, money out, money in.';
  };
  area.oninput = recount; recount();

  const res = await modal({
    title:'Import statement lines',
    body: el('div', {},
      field('Paste the statement', area, {
        hint:'Comma-separated: date, description, money out, money in, reference. Straight from the bank’s CSV is fine.' }),
      preview),
    actions: [{ label:'Import', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;

  const rows = parse();
  if (!rows.length) return err('No readable lines were found.');
  const yes = await confirmBox('Replace the existing lines?',
    `${rows.length} lines will be imported. Any lines already on this statement are replaced, so re-importing a corrected download is safe.`,
    'Import');
  if (!yes) return;

  try {
    const n = await rpc('import_statement_lines', { p_statement: st.id, p_lines: rows });
    ok(`${n} lines imported.`);
    refresh();
  } catch (e){ err(e.message); }
}

const splitCsv = (s) => s.split(',').map(c => c.replace(/^["']|["']$/g, '').trim());
const numOrZero = (v) => { const n = Number(String(v || '').replace(/[^\d.-]/g, '')); return Number.isFinite(n) && n > 0 ? n : 0; };

/** Accept 2026-08-01, 01/08/2026 and 01-08-2026; reject anything else. */
function normDate(v){
  const s = String(v || '').trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const m = s.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/);
  if (m) return `${m[3]}-${m[2].padStart(2,'0')}-${m[1].padStart(2,'0')}`;
  return null;
}

async function autoMatch(st){
  try {
    const n = await rpc('auto_match_statement', { p_statement: st.id, p_day_window: 3 });
    ok(n === 0
      ? 'Nothing new could be matched with confidence. The rest need a person.'
      : `${n} line${n === 1 ? '' : 's'} matched. Anything ambiguous was left alone on purpose.`);
    refresh();
  } catch (e){ err(e.message); }
}

async function lineDialog(st, line){
  // Candidates: posted transactions on this account, near this date. The
  // list is deliberately wider than the auto-matcher's, because a person
  // can judge what an algorithm should not guess.
  const from = shiftDate(line.line_date, -10), to = shiftDate(line.line_date, 10);
  const entries = await q('ledger_entries', b => b.eq('account_id', st.account_id)
    .gte('entry_date', from).lte('entry_date', to)).catch(() => []);
  const ids = [...new Set(entries.map(e => e.txn_id))];
  const txns = ids.length ? await q('v_transactions', b => b.in('id', ids)).catch(() => []) : [];
  const signed = new Map(entries.map(e => [e.txn_id, Number(e.signed_amount)]));
  const target = Number(line.credit) - Number(line.debit);

  // Closest amount first — the right answer is usually the exact one.
  txns.sort((a,b) => Math.abs((signed.get(a.id) ?? 0) - target) - Math.abs((signed.get(b.id) ?? 0) - target));

  const pickI = select(txns.map(t => ({
    value: t.id,
    label: `${fdate(t.txn_date)} · ${money(signed.get(t.id) ?? 0)} · ${t.description || t.txn_no}`
  })), { value: line.matched_txn_id || '', placeholder:'Choose a transaction' });

  const res = await modal({
    title:`${fdate(line.line_date)} — ${line.description || 'statement line'}`,
    body: el('div', {},
      el('dl', { class:'dl' },
        el('dt', {}, 'Amount'), el('dd', {}, money(target) + (target < 0 ? ' out' : ' in')),
        el('dt', {}, 'Reference'), el('dd', {}, line.reference || '—'),
        el('dt', {}, 'Current status'), el('dd', {}, matchCell(line))),
      field('Match to transaction', pickI, {
        hint: txns.length
          ? 'Sorted with the closest amount first. Only transactions on this account within ten days are offered.'
          : 'No transaction on this account falls within ten days of this line.' })),
    actions: [
      { label:'Set aside', value:'ignore' },
      { label:'Match', kind:'primary', value:'match' }
    ]
  });
  if (!res) return;

  try {
    if (res === 'ignore'){
      await rpc('match_statement_line', { p_line: line.id, p_txn: null, p_ignore: true });
      ok('Line set aside. It no longer counts as unmatched, but it is still on the statement.');
    } else {
      if (!pickI.value) return err('Choose a transaction, or set the line aside.');
      await rpc('match_statement_line', { p_line: line.id, p_txn: pickI.value, p_ignore: false });
      ok('Matched.');
    }
    refresh();
  } catch (e){ err(e.message); }
}

const shiftDate = (iso, days) => {
  const d = new Date(iso + 'T00:00:00');
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0,10);
};

async function finish(st, diff){
  const noteI = el('textarea', { rows:'2' });
  const agrees = Math.abs(diff) < 0.005;

  const res = await modal({
    title:'Reconcile this statement',
    body: el('div', {},
      el('p', {}, agrees
        ? 'The books and the bank agree. Reconciling will close this statement.'
        : `The books and the bank differ by ${money(Math.abs(diff))}. You can still record the reconciliation — it will be saved as DISPUTED with the difference attached, and the statement stays open.`),
      field('Notes', noteI, { hint: agrees ? '' : 'Say what you think the difference is, if you know.' })),
    actions: [{ label: agrees ? 'Reconcile' : 'Record the disagreement', kind:'primary', value:'save' }]
  });
  if (res !== 'save') return;

  try {
    const r = await rpc('reconcile_account', { p_statement: st.id, p_notes: noteI.value.trim() || null });
    ok(r.status === 'AGREED'
      ? 'Reconciled. The statement is closed.'
      : `Recorded as disputed, ${money(Math.abs(Number(r.difference)))} apart.`);
    refresh();
  } catch (e){ err(e.message); }
}
