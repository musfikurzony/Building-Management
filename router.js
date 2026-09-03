/* =====================================================================
   router.js — hash routing. No history API, so the app works from a
   file path, a sub-folder, GitHub Pages and Cloudflare alike.
   ===================================================================== */

import { el, spinner, err } from './ui.js';
import { can, canAny, state } from './store.js';

export const ROUTES = [
  { path:'dashboard', module:'dashboard', title:'Dashboard',        load: () => import('../modules/dashboard.js') },
  { path:'flats',     module:'flats',     title:'Flats & Owners',   load: () => import('../modules/flats.js') },
  { path:'charges',   module:'charges',   title:'Service Charge',   load: () => import('../modules/charges.js') },
  { path:'finance',   module:'finance',   title:'Finance / Ledger', load: () => import('../modules/finance.js') },
  { path:'bank',      module:'bank',      title:'Bank & Cash',      load: () => import('../modules/bank.js') },
  { path:'reconcile', module:'bank',      title:'Reconciliation',   load: () => import('../modules/reconcile.js'), hideInNav:true },
  { path:'reserve',   module:'reserve',   title:'Reserve & Funds',  load: () => import('../modules/reserve.js') },
  { path:'budget',    module:'budget',    title:'Budget',           load: () => import('../modules/budget.js') },
  { path:'reports',   module:'reports',   title:'Reports',          load: () => import('../modules/reports.js') },
  { path:'generator', module:'generator', title:'Generator',        load: () => import('../modules/generator.js') },
  { path:'lift',      module:'lift',      title:'Lift',             load: () => import('../modules/lift.js') },
  { path:'fire',      module:'fire',      title:'Fire Safety',      load: () => import('../modules/fire.js') },
  { path:'maintenance',module:'maintenance',title:'Maintenance',    load: () => import('../modules/maintenance.js') },
  { path:'staff',     module:'staff',     title:'Staff',            load: () => import('../modules/staff.js') },
  { path:'salary',    module:'salary',    title:'Salary',           load: () => import('../modules/salary.js') },
  { path:'work',      module:'work',      title:'Work Monitoring',  load: () => import('../modules/work.js') },
  { path:'mosque',    module:'mosque',    title:'Mosque',           load: () => import('../modules/mosque.js') },
  { path:'users',     module:'users',     title:'Users & Roles',    load: () => import('../modules/users.js') },
  { path:'audit',     module:'audit',     title:'Audit Log',        load: () => import('../modules/audit.js') },
  { path:'settings',  module:'settings',  title:'Settings',         load: () => import('../modules/settings.js') }
];

export function parseHash(){
  const raw = (location.hash || '#/dashboard').replace(/^#\/?/, '');
  const [pathPart, queryPart] = raw.split('?');
  const parts = pathPart.split('/').filter(Boolean);
  return { parts, query: new URLSearchParams(queryPart || '') };
}

export function currentRoute(){
  const { parts, query } = parseHash();
  const head = parts[0] || 'dashboard';
  const route = ROUTES.find(r => r.path === head) || ROUTES[0];
  return { route, params: parts.slice(1), query };
}

/** Re-render the current screen in place. Used after a save, instead of
    location.reload(): a full reload throws away the toast that just said
    what happened, and makes every action feel like a page load. */
export function refresh(){
  const host = document.querySelector('#view');
  if (host) return renderRoute(host);
}

export function go(hash){
  if (location.hash === hash) window.dispatchEvent(new HashChangeEvent('hashchange'));
  else location.hash = hash;
}

const cache = new Map();

export async function renderRoute(host){
  const { route, params, query } = currentRoute();

  if (!canAny(route.module) && !can(route.module, 'view')){
    host.replaceChildren(el('div', { class:'card' },
      el('h1', { text: 'Not available to you' }),
      el('p',  { class:'muted', text: `Your account does not have access to ${route.title}. If you think that is wrong, ask an administrator to check your role.` }),
      el('a',  { class:'btn', href:'#/dashboard', text:'Back to dashboard' })));
    return route;
  }

  host.replaceChildren(spinner());
  try {
    let mod = cache.get(route.path);
    if (!mod){ mod = await route.load(); cache.set(route.path, mod); }
    const node = await mod.render({ params, query, state });
    host.replaceChildren(node);
    host.focus({ preventScroll:true });
    window.scrollTo({ top:0, behavior:'instant' });
  } catch (e){
    console.error(e);
    err(e.message || 'That screen failed to load');
    host.replaceChildren(el('div', { class:'card' },
      el('h1', { text:'Could not load this screen' }),
      el('p',  { class:'muted', text: e.message || String(e) }),
      el('button', { class:'btn', text:'Try again', onclick: () => renderRoute(host) })));
  }
  return route;
}
