/* Finance / general ledger — the one place money is recorded.
   Every module's spending ends up here; nothing else stores an amount. */

import { el, html, field, select, money, fdate, fdatetime, badge, table, emptyState,
         toast, ok, err, modal, reasonBox, confirmBox, downloadCSV, todayISO, monthName } from '../core/ui.js';
import { q, one, rpc, logEvent } from '../core/db.js';
import { can, ref, state, settings, invalidate } from '../core/store.js';
import { go } from '../core/router.js';

export async function render({ params }){
  const sub = params[0];
  if (sub === 'new')       return entryForm();
  if (sub === 'approvals') return approvalQueue();
  if (sub === 'mine')      return ledger({ mine:true });
  if (sub)                 return detail(sub);
  return ledger({});
}

/* ==================================================================
   LEDGER LIST
   ================================================================== */
async function ledger({ mine }){
  const page = el('div', {});
  const head = el('div', { class:'page-head' },
    el('h1', { text: mine ? 'My submissions' : 'Finance ledger' }));
  page.append(head);

  const today = new Date();
  const fromI = el('input', { type:'date', value: `${today.getFullYear()}-01-01` });
  const toI   = el('input', { type:'date', value: todayISO() });
  const depts = await ref('departments');
  const deptI = select(depts.map(d => ({ value:d.id, label:d.name })), { placeholder:'All departments' });
  const statI = select(['POSTED','PENDING_APPROVAL','DRAFT','RETURNED','REJECTED','REVERSED','APPROVED']
                        .map(s => ({ value:s, label:s.replace(/_/g,' ') })), { placeholder:'All statuses' });
  const searchI = el('input', { type:'search', placeholder:'Search description, number, vendor…' });

  const body = el('div', {});
  const bar = el('div', { class:'toolbar' },
    el('div', { style:'flex:1;min-width:9rem' }, field('From', fromI)),
    el('div', { style:'flex:1;min-width:9rem' }, field('To', toI)),
    el('div', { style:'flex:1;min-width:10rem' }, field('Department', deptI)),
    el('div', { style:'flex:1;min-width:10rem' }, field('Status', statI)),
    el('div', { style:'flex:2;min-width:12rem' }, field('Search', searchI)));

  const actions = el('div', { class:'toolbar' });
  if (can('finance','add')) actions.append(el('a', { class:'btn primary', href:'#/finance/new', text:'＋ New entry' }));
  if (can('finance','approve') && !mine)
    actions.append(el('a', { class:'btn', href:'#/finance/approvals', text:'Approval queue' }));
  actions.append(el('span', { class:'spacer' }));
  const exportBtn = el('button', { class:'btn small', text:'Export CSV' });
  if (can('finance','export')) actions.append(exportBtn);

  page.append(actions, bar, body);

  let rows = [];
  async function load(){
    body.replaceChildren(el('p', { class:'muted', text:'Loading…' }));
    rows = await q('v_transactions', b => {
      let x = b.gte('txn_date', fromI.value).lte('txn_date', toI.value)
               .order('txn_date', { ascending:false }).order('created_at', { ascending:false }).limit(500);
      if (mine) x = x.eq('created_by', state.user.id);
      if (deptI.value) x = x.eq('department_id', deptI.value);
      if (statI.value) x = x.eq('status', statI.value);
      return x;
    });
    paint();
  }

  function filtered(){
    const s = searchI.value.trim().toLowerCase();
    if (!s) return rows;
    return rows.filter(r => [r.description, r.txn_no, r.vendor_name, r.category_name, r.reference_no]
      .some(v => v && String(v).toLowerCase().includes(s)));
  }

  function paint(){
    const list = filtered();
    const income  = list.filter(r => r.counts_in_totals && r.direction === 'INCOME')
                        .reduce((t,r) => t + Number(r.amount), 0);
    const expense = list.filter(r => r.counts_in_totals && r.direction === 'EXPENSE')
                        .reduce((t,r) => t + Number(r.amount), 0);

    const cols = [
      { label:'Date',   key:'txn_date', fmt: r => fdate(r.txn_date), csv: r => r.txn_date },
      { label:'Number', fmt: r => r.txn_no || '—', cls:'mono', csv: r => r.txn_no },
      { label:'Description', primary:true, fmt: r => r.description, csv: r => r.description },
      { label:'Department',  fmt: r => r.department_name || '—', csv: r => r.department_name },
      { label:'Category',    fmt: r => r.category_name || '—', csv: r => r.category_name },
      { label:'Account',     fmt: r => r.direction === 'TRANSFER'
          ? `${r.account_name || '?'} → ${r.counter_account_name || '?'}` : (r.account_name || '—'),
        csv: r => r.account_name },
      { label:'Amount', cls:'num', csv: r => r.amount,
        fmt: r => html`<span style="color:${r.direction === 'INCOME' ? 'var(--accent)' : r.direction === 'EXPENSE' ? 'var(--red)' : 'inherit'}">${
          (r.direction === 'INCOME' ? '+' : r.direction === 'EXPENSE' ? '−' : '')}${money(r.amount, { bare:true })}</span>` },
      { label:'Status', fmt: r => badge(r.status), csv: r => r.status }
    ];

    body.replaceChildren(
      el('p', { class:'small muted' },
        `${list.length} entr${list.length === 1 ? 'y' : 'ies'} · posted income ${money(income)} · posted expense ${money(expense)}`),
      table(cols, list, { onRow: r => go('#/finance/' + r.id),
        empty: 'No entries in this range. Widen the dates or clear the filters.' }));

    exportBtn.onclick = () => {
      downloadCSV(`ledger-${fromI.value}-to-${toI.value}.csv`, cols, list);
      logEvent('EXPORT', { module:'finance', detail:`${list.length} ledger rows` });
    };
  }

  for (const c of [fromI, toI, deptI, statI]) c.onchange = load;
  searchI.oninput = () => paint();
  await load();
  return page;
}

/* ==================================================================
   NEW ENTRY
   ================================================================== */
async function entryForm(){
  const [depts, cats, accounts, vendors, flats] = await Promise.all([
    ref('departments'), ref('categories'), ref('accounts'), ref('vendors'), ref('flats')
  ]);

  const dirI  = select([
      { value:'EXPENSE',  label:'Expense — money going out' },
      { value:'INCOME',   label:'Income — money coming in' },
      { value:'TRANSFER', label:'Transfer — between our own accounts' }
    ], { value:'EXPENSE' });
  const dateI = el('input', { type:'date', value: todayISO(), required:true });
  const deptI = select(depts.map(d => ({ value:d.id, label:d.name })), { placeholder:'Choose a department' });
  const catI  = select([], { placeholder:'Choose a category' });
  const descI = el('input', { type:'text', required:true, maxlength:'200', placeholder:'What was this for?' });
  const amtI  = el('input', { type:'number', step:'0.01', min:'0.01', required:true, inputmode:'decimal', placeholder:'0.00' });
  const methI = select(['CASH','BANK_TRANSFER','CHEQUE','BKASH','NAGAD','ROCKET','CARD']
                  .map(m => ({ value:m, label:m.replace(/_/g,' ') })), { value:'CASH' });
  const acctI = select(accounts.map(a => ({ value:a.id, label:`${a.name} (${a.kind.toLowerCase()})` })), { placeholder:'Default cash account' });
  const toI   = select(accounts.map(a => ({ value:a.id, label:a.name })), { placeholder:'Into which account' });
  const vendI = select(vendors.map(v => ({ value:v.id, label:v.name })), { placeholder:'None' });
  const flatI = select(flats.map(f => ({ value:f.id, label:f.flat_number })), { placeholder:'Not flat-specific' });
  const refI  = el('input', { type:'text', maxlength:'80', placeholder:'Cheque no, bKash trx id, invoice no' });
  const noteI = el('textarea', { rows:2, maxlength:'500' });
  const fileI = el('input', { type:'file', accept:'image/*,application/pdf', capture:'environment' });

  const toField   = field('Into account', toI, { required:true });
  const deptField = field('Department', deptI, { required:true });
  const catField  = field('Category', catI);
  const vendField = field('Vendor / payee', vendI);
  const flatField = field('Flat (optional)', flatI);

  function syncDirection(){
    const transfer = dirI.value === 'TRANSFER';
    toField.hidden = !transfer;
    deptField.hidden = transfer;
    catField.hidden = transfer;
    vendField.hidden = transfer;
    flatField.hidden = transfer;
    acctI.parentElement.querySelector('span').textContent = transfer ? 'From account' : 'Paid from / into';
    syncCategories();
  }
  function syncCategories(){
    const want = dirI.value;
    const list = cats.filter(c => c.department_id === deptI.value && (c.txn_type === want || c.txn_type === 'BOTH'));
    catI.replaceChildren(el('option', { value:'' }, list.length ? 'Choose a category' : 'No category set up for this'));
    for (const c of list) catI.append(el('option', { value:c.id }, c.name));
  }
  dirI.onchange = syncDirection;
  deptI.onchange = syncCategories;

  const limitNote = el('p', { class:'hint' });
  amtI.oninput = () => {
    const v = Number(amtI.value || 0);
    limitNote.textContent = v > 0
      ? 'Whether this posts straight away or waits for approval is decided by the database from your role limit.'
      : '';
  };

  const submitBtn = el('button', { class:'btn primary', type:'submit', text:'Submit' });
  const draftBtn  = el('button', { class:'btn', type:'button', text:'Save as draft' });

  async function save(submit){
    if (!descI.value.trim()) { err('Please describe what this was for.'); descI.focus(); return; }
    const amount = Number(amtI.value);
    if (!(amount > 0)) { err('Enter an amount greater than zero.'); amtI.focus(); return; }
    if (dirI.value === 'TRANSFER' && !toI.value) { err('Choose the account the money goes into.'); return; }
    if (dirI.value === 'TRANSFER' && toI.value === acctI.value) { err('A transfer needs two different accounts.'); return; }

    submitBtn.disabled = draftBtn.disabled = true;
    try {
      const txn = await rpc('create_transaction', {
        p_txn_date: dateI.value,
        p_direction: dirI.value,
        p_department_id: dirI.value === 'TRANSFER' ? null : (deptI.value || null),
        p_category_id:   dirI.value === 'TRANSFER' ? null : (catI.value  || null),
        p_description: descI.value.trim(),
        p_amount: amount,
        p_payment_method: methI.value,
        p_account_id: acctI.value || null,
        p_counter_account_id: dirI.value === 'TRANSFER' ? toI.value : null,
        p_vendor_id: dirI.value === 'TRANSFER' ? null : (vendI.value || null),
        p_flat_id:   dirI.value === 'TRANSFER' ? null : (flatI.value || null),
        p_reference_no: refI.value.trim() || null,
        p_notes: noteI.value.trim() || null,
        p_submit: submit
      });
      const row = Array.isArray(txn) ? txn[0] : txn;

      if (fileI.files?.[0] && row?.id){
        const { uploadAttachment, BUCKETS } = await import('../core/db.js');
        await uploadAttachment(BUCKETS.receipts, 'transactions', row.id, fileI.files[0])
          .catch(e => toast('Saved, but the receipt did not upload: ' + e.message, 'err'));
      }

      const st = row?.status || '';
      ok(st === 'POSTED'  ? `Posted as ${row.txn_no}.`
        : st === 'PENDING_APPROVAL' ? `Submitted as ${row.txn_no} — waiting for approval.`
        : 'Saved as a draft.');
      invalidate('balances');
      go(st === 'DRAFT' ? '#/finance' : '#/finance/' + row.id);
    } catch (e){
      submitBtn.disabled = draftBtn.disabled = false;
    }
  }

  draftBtn.onclick = () => save(false);
  const form = el('form', { novalidate:true, onsubmit: (e) => { e.preventDefault(); save(true); } },
    el('div', { class:'card' },
      el('div', { class:'grid g-form' },
        field('Type', dirI, { required:true }),
        field('Date', dateI, { required:true })),
      field('Description', descI, { required:true }),
      el('div', { class:'grid g-form' },
        field('Amount', amtI, { required:true, hint: settings().currency_symbol || 'Tk' }),
        field('Payment method', methI)),
      limitNote,
      el('div', { class:'grid g-form' },
        field('Paid from / into', acctI, { hint:'Leave blank to use the default cash account' }),
        toField),
      el('div', { class:'grid g-form' }, deptField, catField),
      el('div', { class:'grid g-form' }, vendField, flatField),
      el('div', { class:'grid g-form' },
        field('Reference number', refI),
        field('Receipt or photo', fileI, { hint:'Photos are shrunk before upload. Max 5 MB.' })),
      field('Notes', noteI),
      el('div', { class:'btn-row' }, submitBtn, draftBtn,
        el('a', { class:'btn', href:'#/finance', text:'Cancel' }))));

  syncDirection();
  return el('div', {},
    el('div', { class:'page-head' },
      el('h1', { text:'New entry' }),
      el('p', { class:'sub', text:'Anything you record here becomes part of the building’s books.' })),
    form);
}

/* ==================================================================
   APPROVAL QUEUE
   ================================================================== */
async function approvalQueue(){
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Approval queue' }),
    el('p', { class:'sub', text:'You cannot approve an entry you created yourself — the database refuses it.' })));

  const body = el('div', {});
  page.append(body);

  async function load(){
    const rows = await q('v_transactions', b => b.eq('status','PENDING_APPROVAL').order('txn_date'));
    if (!rows.length){
      body.replaceChildren(emptyState('Nothing is waiting for approval.'));
      return;
    }
    body.replaceChildren(...rows.map(card));
  }

  function card(r){
    const mine = r.created_by === state.user.id;
    const box = el('div', { class:'card' },
      el('div', { class:'card-head' },
        el('h3', { text: r.description }),
        el('span', { class:'num', style:'font-weight:700', text: money(r.amount) })),
      el('dl', { class:'dl' },
        el('dt', { text:'Date' }),       el('dd', { text: fdate(r.txn_date) }),
        el('dt', { text:'Number' }),     el('dd', { class:'mono', text: r.txn_no || '—' }),
        el('dt', { text:'Department' }), el('dd', { text: `${r.department_name || '—'} · ${r.category_name || '—'}` }),
        el('dt', { text:'Account' }),    el('dd', { text: r.account_name || '—' }),
        el('dt', { text:'Vendor' }),     el('dd', { text: r.vendor_name || '—' }),
        el('dt', { text:'Entered by' }), el('dd', { text: `${r.created_by_name || 'unknown'} · ${fdatetime(r.created_at)}` })));

    if (mine){
      box.append(el('p', { class:'hint', text:'You entered this one, so someone else has to approve it.' }));
    } else {
      const approve = el('button', { class:'btn primary', text:'Approve & post' });
      const ret     = el('button', { class:'btn', text:'Return for changes' });
      const reject  = el('button', { class:'btn danger', text:'Reject' });

      approve.onclick = async () => {
        const yes = await confirmBox('Approve and post?',
          `${r.description} — ${money(r.amount)}. Once posted it can only be corrected by a reversal.`,
          'Approve & post');
        if (!yes) return;
        approve.disabled = true;
        try { await rpc('approve_transaction', { p_txn: r.id, p_post: true }); ok('Posted'); invalidate('balances'); load(); }
        catch { approve.disabled = false; }
      };
      ret.onclick = async () => {
        const reason = await reasonBox('Return for changes', 'What needs fixing?', 'Return');
        if (!reason) return;
        await rpc('reject_transaction', { p_txn: r.id, p_reason: reason, p_return: true });
        ok('Returned to the person who entered it'); load();
      };
      reject.onclick = async () => {
        const reason = await reasonBox('Reject this entry', 'Why is it rejected?', 'Reject');
        if (!reason) return;
        await rpc('reject_transaction', { p_txn: r.id, p_reason: reason, p_return: false });
        ok('Rejected'); load();
      };
      box.append(el('div', { class:'btn-row' }, approve, ret, reject));
    }
    return box;
  }

  await load();
  return page;
}

/* ==================================================================
   DETAIL
   ================================================================== */
async function detail(id){
  const r = await one('v_transactions', b => b.eq('id', id));
  if (!r) return emptyState('That entry does not exist, or you cannot see it.');

  const lines = await q('ledger_entries', b => b.eq('txn_id', id)).catch(() => []);
  const accounts = await ref('accounts');
  const accName = (aid) => accounts.find(a => a.id === aid)?.name || '—';
  const files = await q('attachments', b => b.eq('entity_table','transactions').eq('entity_id', id).is('deleted_at', null)).catch(() => []);

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: r.description }),
    el('p', { class:'sub' }, r.txn_no ? el('span', { class:'mono', text:r.txn_no }) : 'Draft', ' · ', badgeNode(r.status))));

  page.append(el('div', { class:'card' },
    el('dl', { class:'dl' },
      el('dt', { text:'Amount' }),   el('dd', { class:'num', style:'font-weight:700', text: money(r.amount) }),
      el('dt', { text:'Type' }),     el('dd', { text: r.direction }),
      el('dt', { text:'Date' }),     el('dd', { text: fdate(r.txn_date) }),
      el('dt', { text:'Department' }), el('dd', { text: r.department_name || '—' }),
      el('dt', { text:'Category' }), el('dd', { text: [r.parent_category_name, r.category_name].filter(Boolean).join(' › ') || '—' }),
      el('dt', { text:'Account' }),  el('dd', { text: r.direction === 'TRANSFER'
        ? `${r.account_name} → ${r.counter_account_name}` : (r.account_name || '—') }),
      el('dt', { text:'Method' }),   el('dd', { text: String(r.payment_method).replace(/_/g,' ') }),
      el('dt', { text:'Vendor' }),   el('dd', { text: r.vendor_name || '—' }),
      el('dt', { text:'Flat' }),     el('dd', { text: r.flat_number || '—' }),
      el('dt', { text:'Reference' }),el('dd', { text: r.reference_no || '—' }),
      el('dt', { text:'Entered by' }), el('dd', { text: `${r.created_by_name || '—'} · ${fdatetime(r.created_at)}` }),
      el('dt', { text:'Approved by' }), el('dd', { text: r.approved_by_name
        ? `${r.approved_by_name} · ${fdatetime(r.approved_at)}`
        : (r.status === 'POSTED' ? 'Auto-posted within the entrant’s limit' : '—') }),
      r.notes ? el('dt', { text:'Notes' }) : null,
      r.notes ? el('dd', { style:'white-space:pre-wrap', text: r.notes }) : null,
      r.rejected_reason ? el('dt', { text:'Reason' }) : null,
      r.rejected_reason ? el('dd', { text: r.rejected_reason }) : null)));

  if (r.reversal_of_txn_id || r.reversed_by_txn_id){
    const other = r.reversal_of_txn_id || r.reversed_by_txn_id;
    page.append(el('div', { class:'alert normal' }, el('div', { class:'a-body' },
      el('div', { class:'a-title', text: r.is_reversal ? 'This entry reverses another' : 'This entry has been reversed' }),
      el('div', { class:'a-meta' }, r.reversal_reason || '', ' ',
        el('a', { href:'#/finance/' + other, text:'View the linked entry →' })))));
  }

  if (lines.length){
    page.append(el('div', { class:'card' },
      el('div', { class:'card-head' }, el('h2', { text:'Account movement' })),
      table([
        { label:'Account', fmt: l => accName(l.account_id), primary:true },
        { label:'Date',    fmt: l => fdate(l.entry_date) },
        { label:'Change',  cls:'num', fmt: l => money(l.signed_amount) }
      ], lines)));
  }

  if (files.length){
    const list = el('div', { class:'card' }, el('div', { class:'card-head' }, el('h2', { text:'Attachments' })));
    for (const f of files){
      const link = el('button', { class:'btn small', text: f.file_name });
      link.onclick = async () => {
        const { signedUrl } = await import('../core/db.js');
        const url = await signedUrl(f.bucket, f.storage_path, 60);
        logEvent('FILE_DOWNLOAD', { module:'finance', table:'attachments', id:f.id, label:f.file_name });
        if (url) window.open(url, '_blank', 'noopener');
      };
      list.append(el('div', { style:'margin-bottom:.4rem' }, link));
    }
    page.append(list);
  }

  const btns = el('div', { class:'btn-row' }, el('a', { class:'btn', href:'#/finance', text:'Back to ledger' }));

  if (r.status === 'DRAFT' && r.created_by === state.user.id && can('finance','add')){
    const b = el('button', { class:'btn primary', text:'Submit for approval' });
    b.onclick = async () => { b.disabled = true; try { await rpc('submit_transaction', { p_txn:r.id }); ok('Submitted'); go('#/finance/'+r.id); } catch { b.disabled = false; } };
    btns.append(b);
  }
  if (r.status === 'RETURNED' && r.created_by === state.user.id){
    const b = el('button', { class:'btn primary', text:'Resubmit' });
    b.onclick = async () => { b.disabled = true; try { await rpc('submit_transaction', { p_txn:r.id }); ok('Resubmitted'); go('#/finance/'+r.id); } catch { b.disabled = false; } };
    btns.append(b);
  }
  if (r.status === 'POSTED' && !r.reversed_by_txn_id && can('finance','cancel')){
    const b = el('button', { class:'btn danger', text:'Reverse this entry' });
    b.onclick = async () => {
      const reason = await reasonBox('Reverse this entry',
        'Why is it being reversed? This is kept forever.', 'Reverse');
      if (!reason) return;
      b.disabled = true;
      try {
        const rev = await rpc('reverse_transaction', { p_txn:r.id, p_reason:reason });
        const row = Array.isArray(rev) ? rev[0] : rev;
        ok('Reversed. The original stays on record.');
        invalidate('balances');
        go('#/finance/' + (row?.id || r.id));
      } catch { b.disabled = false; }
    };
    btns.append(b);
  }
  page.append(btns);
  return page;
}

function badgeNode(status){
  const s = String(status || '').toLowerCase();
  return el('span', { class:'badge b-' + s, text: String(status).replace(/_/g,' ') });
}
