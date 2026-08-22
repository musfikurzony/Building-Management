/* Bank & cash. Balances are never stored — every figure here is the
   opening balance plus the ledger, computed in SQL. The account number
   sits behind its own permission. */

import { el, field, select, money, money0, fdate, table, stat, ok, err, modal, emptyState, downloadCSV } from '../core/ui.js';
import { q, one, insert, update, upsert, logEvent } from '../core/db.js';
import { refresh } from '../core/router.js';
import { can, ref, invalidate } from '../core/store.js';

export async function render({ params }){
  if (params[0]) return accountDetail(params[0]);
  return list();
}

async function list(){
  const rows = await q('v_account_balances', b => b.order('kind').order('name'));
  const total = (kinds) => rows.filter(r => r.is_active && kinds.includes(r.kind))
    .reduce((t,r) => t + Number(r.current_balance || 0), 0);

  const cols = [
    { label:'Account', primary:true, key:'name' },
    { label:'Type', fmt: r => r.kind.replace('_',' ').toLowerCase(), csv: r => r.kind },
    { label:'Bank', fmt: r => r.bank_name || '—', csv: r => r.bank_name },
    { label:'Opening', cls:'num', fmt: r => money(r.opening_balance, { bare:true }), csv: r => r.opening_balance },
    { label:'Movement', cls:'num', fmt: r => money(r.movement, { bare:true }), csv: r => r.movement },
    { label:'Balance', cls:'num', fmt: r => money(r.current_balance, { bare:true }), csv: r => r.current_balance },
    { label:'Last entry', fmt: r => r.last_entry_date ? fdate(r.last_entry_date) : '—', csv: r => r.last_entry_date }
  ];

  const bar = el('div', { class:'toolbar' });
  bar.append(el('a', { class:'btn', href:'#/reconcile', text:'Reconciliation' }));
  if (can('bank','add')) bar.append(el('button', { class:'btn primary', text:'＋ Add account', onclick: () => accountDialog(null) }));
  bar.append(el('span', { class:'spacer' }));
  if (can('bank','export'))
    bar.append(el('button', { class:'btn small', text:'Export CSV', onclick: () => {
      downloadCSV('accounts.csv', cols, rows); logEvent('EXPORT', { module:'bank' }); }}));

  return el('div', {},
    el('div', { class:'page-head' }, el('h1', { text:'Bank & cash' }),
      el('p', { class:'sub', text:'Balances are derived from the ledger. There is no stored balance that can drift.' })),
    el('div', { class:'grid g-stats' },
      stat('Bank', money0(total(['BANK']))),
      stat('Cash & wallets', money0(total(['CASH','MOBILE_WALLET']))),
      stat('Fixed deposits', money0(total(['FD']))),
      stat('Total held', money0(total(['BANK','CASH','MOBILE_WALLET','FD'])))),
    bar,
    table(cols, rows, { onRow: r => location.hash = '#/bank/' + r.account_id,
      empty:'No accounts yet. Add the building’s bank account and a petty-cash account.' }));
}

async function accountDetail(id){
  const acct = await one('v_account_balances', b => b.eq('account_id', id));
  if (!acct) return emptyState('That account does not exist, or you cannot see it.');

  const raw = await one('accounts', b => b.eq('id', id));
  const entries = await q('ledger_entries', b => b.eq('account_id', id)
    .order('entry_date', { ascending:false }).limit(200)).catch(() => []);
  const txnIds = [...new Set(entries.map(e => e.txn_id))];
  const txns = txnIds.length
    ? await q('v_transactions', b => b.in('id', txnIds)).catch(() => []) : [];
  const txnOf = (tid) => txns.find(t => t.id === tid) || {};

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text: acct.name }),
    el('p', { class:'sub', text: `${acct.kind.replace('_',' ').toLowerCase()}${acct.bank_name ? ' · ' + acct.bank_name : ''}` })));

  page.append(el('div', { class:'grid g-stats' },
    stat('Current balance', money(acct.current_balance)),
    stat('Opening balance', money(acct.opening_balance), fdate(raw?.opening_date)),
    stat('Ledger movement', money(acct.movement)),
    stat('Entries shown', String(entries.length), 'most recent 200')));

  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/bank', text:'← Accounts' }));
  if (can('bank','edit')) bar.append(el('button', { class:'btn', text:'Edit account', onclick: () => accountDialog(raw) }));
  if (can('bank','view_sensitive')){
    const b = el('button', { class:'btn', text:'Show account number' });
    b.onclick = async () => {
      const sec = await one('account_secrets', x => x.eq('account_id', id)).catch(() => null);
      logEvent('REPORT_VIEW', { module:'bank', detail:'viewed account number', table:'accounts', id, label: acct.name, severity:'HIGH' });
      await modal({ title:'Account details', body: el('dl', { class:'dl' },
        el('dt', { text:'Account number' }), el('dd', { class:'mono', text: sec?.account_number || 'not recorded' }),
        el('dt', { text:'Routing' }),        el('dd', { class:'mono', text: sec?.routing_number || '—' }),
        el('dt', { text:'Branch' }),         el('dd', { text: raw?.branch || '—' })) });
    };
    bar.append(b);
  }
  page.append(bar);

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Movement' })),
    table([
      { label:'Date', fmt: e => fdate(e.entry_date) },
      { label:'Description', primary:true, fmt: e => e.memo || txnOf(e.txn_id).description || '' },
      { label:'Number', cls:'mono', fmt: e => txnOf(e.txn_id).txn_no || '—' },
      { label:'Change', cls:'num', fmt: e => money(e.signed_amount, { bare:true }) }
    ], entries, { onRow: e => location.hash = '#/finance/' + e.txn_id,
      empty:'Nothing has moved through this account yet.' })));
  return page;
}

async function accountDialog(acct){
  const codeI = el('input', { type:'text', required:true, maxlength:'20', value: acct?.code || '' });
  const nameI = el('input', { type:'text', required:true, value: acct?.name || '' });
  const kindI = select([['BANK','Bank account'],['CASH','Cash in hand'],['MOBILE_WALLET','Mobile wallet (bKash/Nagad)'],['FD','Fixed deposit']]
      .map(([v,l]) => ({ value:v, label:l })), { value: acct?.kind || 'BANK' });
  const bankI = el('input', { type:'text', value: acct?.bank_name || '' });
  const brI   = el('input', { type:'text', value: acct?.branch || '' });
  const openI = el('input', { type:'number', step:'0.01', value: acct?.opening_balance ?? 0 });
  const dateI = el('input', { type:'date', value: acct?.opening_date || new Date().toISOString().slice(0,10) });
  const numI  = el('input', { type:'text', value:'', placeholder: acct ? 'leave blank to keep' : '' });

  const body = el('div', {},
    el('div', { class:'grid g-form' }, field('Short code', codeI, { required:true, hint:'e.g. BANK1, CASH' }),
      field('Name', nameI, { required:true })),
    field('Type', kindI),
    el('div', { class:'grid g-form' }, field('Bank', bankI), field('Branch', brI)),
    el('div', { class:'grid g-form' },
      field('Opening balance', openI, { hint: acct ? 'Changing this moves every balance from that date on.' : '' }),
      field('Opening date', dateI)),
    can('bank','view_sensitive')
      ? field('Account number', numI, { hint:'Stored separately and only visible to people with the bank permission. Never appears in the audit log.' })
      : null);

  const res = await modal({ title: acct ? 'Edit account' : 'Add account', body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', validate: () => {
        if (!codeI.value.trim() || !nameI.value.trim()){ err('Code and name are required.'); return false; }
        return true; }, value:true }
  ]});
  if (!res) return;

  const payload = {
    code: codeI.value.trim().toUpperCase(), name: nameI.value.trim(), kind: kindI.value,
    bank_name: bankI.value.trim() || null, branch: brI.value.trim() || null,
    opening_balance: Number(openI.value || 0), opening_date: dateI.value
  };
  try {
    const saved = acct ? await update('accounts', acct.id, payload) : await insert('accounts', payload);
    if (numI.value.trim() && can('bank','view_sensitive'))
      await upsert('account_secrets', { account_id: saved.id, account_number: numI.value.trim() }, 'account_id');
    invalidate('accounts','balances');
    ok('Saved'); refresh();
  } catch { /* toast shown */ }
}
