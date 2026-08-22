/* =====================================================================
   store.js — session, permissions and the small reference lists that
   every screen needs. Loaded once after sign-in, refreshed on demand.

   The permission cache here decides what to SHOW. It decides nothing
   about what is ALLOWED — that lives in Row Level Security and the RPC
   functions, where the browser cannot reach it.
   ===================================================================== */

import { sb, q, rpc, insert } from './db.js';
import { setCurrency } from './ui.js';

export const state = {
  session: null,
  user: null,
  profile: null,
  roles: [],
  perms: new Set(),
  isSuper: false,
  settings: null,
  modules: [],
  ref: {},          // departments, categories, accounts, flats…
  status: 'loading' // loading | signedout | pending | ready | unconfigured
};

export function can(module, action){
  return state.isSuper || state.perms.has(module + '.' + action);
}
export function canAny(module){
  if (state.isSuper) return true;
  for (const p of state.perms) if (p.startsWith(module + '.')) return true;
  return false;
}

export async function loadSession(){
  if (!sb) { state.status = 'unconfigured'; return state; }
  const { data } = await sb.auth.getSession();
  state.session = data?.session || null;
  state.user = state.session?.user || null;
  if (!state.user) { state.status = 'signedout'; return state; }
  return loadProfile();
}

export async function loadProfile(){
  const uid = state.user.id;

  let rows = await q('user_profiles', b => b.eq('user_id', uid), { silent:true }).catch(() => []);
  let profile = rows[0];

  if (!profile){
    // First sign-in. The row is created inactive; only an administrator
    // can switch it on (enforced by policy, not by this code).
    const name = state.user.user_metadata?.full_name || state.user.email;
    profile = await insert('user_profiles', {
      user_id: uid, full_name: name, email: state.user.email, is_active: false
    }).catch(() => null);
  }
  state.profile = profile;

  if (!profile || !profile.is_active){ state.status = 'pending'; return state; }

  // If permissions cannot be read, the token is stale or revoked. That is
  // a signed-out state, not an error to shout about on the boot screen.
  let perms;
  try {
    perms = await rpc('my_permissions', {}, { silent:true }) || [];
  } catch {
    state.status = 'signedout';
    state.perms = new Set();
    return state;
  }
  state.perms = new Set(perms.map(p => `${p.module_code}.${p.action}`));

  // These three are for display only — the role chips in the menu, the
  // building name, the nav. A user who cannot read them (or a request that
  // is cut short by a reload) should still be able to sign in.
  const roleRows = await q('user_roles', b => b.eq('user_id', uid), { silent:true }).catch(() => []);
  const allRoles = await q('roles', b => b.order('sort_order'), { silent:true }).catch(() => []);
  const mine = new Set(roleRows.map(r => r.role_id));
  state.roles = allRoles.filter(r => mine.has(r.id));
  state.isSuper = state.roles.some(r => r.is_superuser);

  const settings = await q('building_settings', b => b, { silent:true }).catch(() => []);
  state.settings = settings[0] || null;
  if (state.settings) setCurrency(state.settings.currency_symbol);

  state.modules = await q('modules', b => b.order('sort_order'), { silent:true }).catch(() => []);

  state.status = 'ready';
  return state;
}

/** Reference lists, cached for the session. */
export async function ref(name, force = false){
  if (state.ref[name] && !force) return state.ref[name];
  const loaders = {
    departments: () => q('departments', b => b.eq('is_active', true).order('sort_order')),
    categories:  () => q('categories',  b => b.eq('is_active', true).order('sort_order')),
    accounts:    () => rpc('entry_accounts'),
    balances:    () => q('v_account_balances', b => b.order('kind').order('name')),
    flats:       () => q('flats',   b => b.order('floor').order('flat_number')),
    owners:      () => q('owners',  b => b.order('name')),
    vendors:     () => q('vendors', b => b.eq('is_active', true).order('name')),
    users:       () => q('user_profiles', b => b.order('full_name')),
    roles:       () => q('roles',   b => b.order('sort_order')),
    periods:     () => q('accounting_periods', b => b.order('period_year',{ascending:false}).order('period_month',{ascending:false})),
    staff:       () => q('v_staff', b => b.order('name')),
    positions:   () => q('staff_positions', b => b.eq('is_active', true).order('sort_order')),
    assets:      () => q('v_assets', b => b.neq('status','RETIRED').order('asset_code')),
    templates:   () => q('work_checklist_templates', b => b.eq('is_active', true).order('sort_order'))
  };
  if (!loaders[name]) throw new Error('Unknown reference list: ' + name);
  state.ref[name] = await loaders[name]().catch(() => []);
  return state.ref[name];
}

export function invalidate(...names){
  if (!names.length) state.ref = {};
  for (const n of names) delete state.ref[n];
}

export async function signOut(){
  await sb?.auth.signOut();
  state.session = null; state.user = null; state.profile = null;
  state.perms = new Set(); state.roles = []; state.ref = {};
  state.status = 'signedout';
}

export const settings = () => state.settings || {};
export const currency  = () => settings().currency_symbol || 'Tk';
