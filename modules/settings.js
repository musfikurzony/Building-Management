/* Building settings — the values the spec insisted must never be
   hard-coded. Flat count, floors, the default charge, the due day, the
   currency: all of it is a row in a table, editable here. */

import { el, field, select, money, ok, err, table, badge, monthName,
         confirmBox, reasonBox, emptyState } from '../core/ui.js';
import { q, update, rpc } from '../core/db.js';
import { refresh } from '../core/router.js';
import { can, ref, state, settings, invalidate } from '../core/store.js';

export async function render(){
  const s = settings();
  const editable = can('settings','edit');
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Settings' }),
    el('p', { class:'sub', text: editable ? 'Changing anything here is recorded in the audit log.' : 'You can see these but not change them.' })));

  const f = {};
  const mk = (key, label, attrs, hint) => {
    f[key] = el('input', Object.assign({ value: s[key] ?? '' }, attrs));
    if (!editable) f[key].disabled = true;
    return field(label, f[key], { hint });
  };

  const accounts = await ref('accounts');
  const cashSel = select(accounts.map(a => ({ value:a.id, label:`${a.name} (${a.kind.toLowerCase()})` })),
                         { value: s.default_cash_account_id, placeholder:'None chosen' });
  if (!editable) cashSel.disabled = true;

  const selfApp = el('input', { type:'checkbox' });
  selfApp.checked = !!s.allow_self_approval;
  if (!editable) selfApp.disabled = true;

  const lateOn = el('input', { type:'checkbox' });
  lateOn.checked = !!s.late_fee_enabled;
  if (!editable) lateOn.disabled = true;
  const lateType = select([{ value:'FIXED', label:'Fixed amount' }, { value:'PERCENT', label:'Percentage of the bill' }],
                          { value: s.late_fee_type });
  if (!editable) lateType.disabled = true;

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'The building' })),
    mk('building_name', 'Building name', { type:'text', maxlength:'120' }),
    mk('address', 'Address', { type:'text', maxlength:'200' }),
    el('div', { class:'grid g-form' },
      mk('floor_count', 'Number of floors', { type:'number', min:'1' }),
      mk('timezone', 'Timezone', { type:'text' }))));

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Service charge' })),
    el('div', { class:'grid g-form' },
      mk('default_service_charge', 'Default monthly charge',
         { type:'number', step:'0.01', min:'0' }, 'Used by any flat that has no rate of its own'),
      mk('charge_due_day', 'Due day of the month', { type:'number', min:'1', max:'28' })),
    el('div', { class:'grid g-form' },
      mk('receipt_prefix', 'Receipt number prefix', { type:'text', maxlength:'8' }),
      mk('fiscal_year_start_month', 'Fiscal year starts in month', { type:'number', min:'1', max:'12' })),
    el('fieldset', {}, el('legend', {}, 'Late fee'),
      el('label', { class:'check' }, lateOn, el('span', { text:'Charge a late fee on overdue service charge' })),
      el('div', { class:'grid g-form' },
        field('Type', lateType),
        mk('late_fee_value', 'Amount or percentage', { type:'number', step:'0.01', min:'0' }),
        mk('late_fee_grace_days', 'Grace days', { type:'number', min:'0' })))));

  page.append(el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Money & approvals' })),
    el('div', { class:'grid g-form' },
      mk('currency_symbol', 'Currency symbol', { type:'text', maxlength:'5' }),
      mk('currency_code', 'Currency code', { type:'text', maxlength:'5' })),
    field('Default cash account', cashSel,
      { hint:'Where an entry with no account chosen lands — the caretaker never sees the bank.' }),
    el('label', { class:'check' }, selfApp,
      el('span', {}, el('b', { text:'Allow a person to approve their own expense' }))),
    el('p', { class:'hint', text:'Leave this off wherever possible. With it on, every self-approval is still recorded in the audit log, but the second pair of eyes is gone.' })));

  if (editable){
    const save = el('button', { class:'btn primary', text:'Save settings' });
    save.onclick = async () => {
      save.disabled = true;
      try {
        await update('building_settings', true, {
          building_name: f.building_name.value.trim() || 'Our Building',
          address: f.address.value.trim() || null,
          floor_count: Number(f.floor_count.value) || 1,
          timezone: f.timezone.value.trim() || 'Asia/Dhaka',
          default_service_charge: Number(f.default_service_charge.value || 0),
          charge_due_day: Math.min(28, Math.max(1, Number(f.charge_due_day.value) || 10)),
          receipt_prefix: f.receipt_prefix.value.trim() || 'RCT',
          fiscal_year_start_month: Math.min(12, Math.max(1, Number(f.fiscal_year_start_month.value) || 1)),
          late_fee_enabled: lateOn.checked,
          late_fee_type: lateType.value,
          late_fee_value: Number(f.late_fee_value.value || 0),
          late_fee_grace_days: Number(f.late_fee_grace_days.value || 0),
          currency_symbol: f.currency_symbol.value.trim() || 'Tk',
          currency_code: f.currency_code.value.trim() || 'BDT',
          default_cash_account_id: cashSel.value || null,
          allow_self_approval: selfApp.checked
        }, 'id');
        ok('Saved'); refresh();
      } catch { save.disabled = false; }
    };
    page.append(el('div', { class:'btn-row' }, save));
  }

  page.append(await periodsCard());
  return page;
}

async function periodsCard(){
  const rows = await q('accounting_periods', b => b
    .order('period_year', { ascending:false }).order('period_month', { ascending:false }).limit(24)).catch(() => []);

  const card = el('section', { class:'card' },
    el('div', { class:'card-head' }, el('h2', { text:'Accounting periods' })),
    el('p', { class:'small muted', text:'Closing a month freezes it: nothing can be created, edited or dated into it afterwards. That is what makes last year’s report stay the same as last year’s report.' }));

  if (!rows.length){ card.append(emptyState('No periods yet — they appear as soon as the first transaction is recorded.')); return card; }

  card.append(table([
    { label:'Period', primary:true, fmt: r => monthName(r.period_year, r.period_month) },
    { label:'Status', fmt: r => badge(r.status) },
    { label:'Closed', fmt: r => r.closed_at ? new Date(r.closed_at).toLocaleDateString() : '—' },
    { label:'', fmt: r => {
        if (!can('finance','close')) return '';
        if (r.status === 'OPEN'){
          const b = el('button', { class:'btn small', text:'Close' });
          b.onclick = async () => {
            const yes = await confirmBox('Close this month?',
              `${monthName(r.period_year, r.period_month)} will be frozen. Everything in it must already be posted.`, 'Close month');
            if (!yes) return;
            try { await rpc('close_period', { p_year:r.period_year, p_month:r.period_month }); ok('Closed'); refresh(); } catch {}
          };
          return b;
        }
        const b = el('button', { class:'btn small danger', text:'Reopen' });
        b.onclick = async () => {
          const reason = await reasonBox('Reopen this month', 'Why does it need reopening? This is recorded.', 'Reopen');
          if (!reason) return;
          try { await rpc('reopen_period', { p_year:r.period_year, p_month:r.period_month, p_reason:reason }); ok('Reopened'); refresh(); } catch {}
        };
        return b;
      } }
  ], rows));
  return card;
}
