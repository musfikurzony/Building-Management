/* accounts.js — the "Paid from / into" picker, the same on every form.

   It used to open on a blank choice labelled "Default cash account" —
   which read like a second cash box next to "Cash in hand". There is only
   one: the account chosen in Settings → Default cash account. The picker
   now opens on that real account, marked "usual", so what you see is
   where the money is recorded. */
import { select } from './ui.js';
import { settings } from './store.js';

const KIND = { CASH:'cash', BANK:'bank', MOBILE_WALLET:'bKash / Nagad', FD:'fixed deposit' };

export function accountSelect(accounts, { withKind = true, exclude = [] } = {}){
  const def = settings().default_cash_account_id;
  const list = (accounts || []).filter(a => a.is_active !== false && a.kind !== 'FD' && !exclude.includes(a.id));
  const value = list.some(a => a.id === def) ? def : (list.length === 1 ? list[0].id : '');
  return select(list.map(a => ({ value: a.id,
    label: `${a.name}${withKind && KIND[a.kind] ? ` (${KIND[a.kind]})` : ''}${a.id === def ? ' — usual' : ''}` })),
    value ? { value } : { placeholder: 'Choose an account' });
}
