/* =====================================================================
   app.js — boots the portal, owns the shell (top bar, navigation,
   sign-in and the "waiting for approval" screen).
   ===================================================================== */

import { $, el, html, setHTML, toast, err, ok, field, modal } from './ui.js';
import { sb, isConfigured, friendly, logEvent, q, rpc } from './db.js';
import { state, loadSession, loadProfile, signOut, can, canAny } from './store.js';
import { ROUTES, renderRoute, currentRoute } from './router.js';
import { t, setLang, currentLang } from './i18n.js';

const ICONS = {
  dashboard:'▦', flats:'⌂', charges:'৳', finance:'☰', bank:'▤', reports:'▥',
  budget:'◎', reserve:'▣', generator:'⚡', lift:'⇅', fire:'△', maintenance:'✦',
  staff:'☺', salary:'◧', work:'✓', mosque:'☾', users:'⚑', audit:'⏱', settings:'⚙'
};

const boot = $('#boot'), app = $('#app'), view = $('#view');
const bootMsg = $('#bootMsg');

/* ---------------------------------------------------------------------
   Sign in / sign up.
   --------------------------------------------------------------------- */
function authScreen(){
  let mode = 'in';
  const email = el('input', { type:'email', autocomplete:'email', required:true, placeholder:'you@example.com' });
  const pass  = el('input', { type:'password', autocomplete:'current-password', required:true, minlength:'8' });
  const name  = el('input', { type:'text', autocomplete:'name', placeholder:'Your full name' });
  const nameField = field('Full name', name, { required:true });
  nameField.hidden = true;

  const submit = el('button', { class:'btn primary', type:'submit', style:'width:100%', text:'Sign in' });
  const note   = el('p', { class:'hint center', style:'margin-top:.8rem' });

  const tabIn = el('button', { type:'button', 'aria-selected':'true',  text:'Sign in' });
  const tabUp = el('button', { type:'button', 'aria-selected':'false', text:'Create account' });
  const setMode = (m) => {
    mode = m;
    tabIn.setAttribute('aria-selected', String(m === 'in'));
    tabUp.setAttribute('aria-selected', String(m === 'up'));
    nameField.hidden = m === 'in';
    name.required = m === 'up';
    pass.autocomplete = m === 'in' ? 'current-password' : 'new-password';
    submit.textContent = m === 'in' ? 'Sign in' : 'Create account';
    note.textContent = m === 'in' ? '' :
      'New accounts start with no access. An administrator activates them and chooses your role.';
  };
  tabIn.onclick = () => setMode('in');
  tabUp.onclick = () => setMode('up');

  const form = el('form', { novalidate:true, onsubmit: async (e) => {
    e.preventDefault();
    submit.disabled = true;
    const prev = submit.textContent;
    submit.textContent = 'Please wait…';
    try {
      if (mode === 'in'){
        const { error } = await sb.auth.signInWithPassword({ email: email.value.trim(), password: pass.value });
        if (error) throw error;
        await afterSignIn();
      } else {
        if (!name.value.trim()) throw new Error('Please enter your full name.');
        const { error } = await sb.auth.signUp({
          email: email.value.trim(), password: pass.value,
          options: { data: { full_name: name.value.trim() } }
        });
        if (error) throw error;
        ok('Account created. An administrator needs to activate it.');
        await afterSignIn();
      }
    } catch (e2){
      err(friendly(e2));
      submit.disabled = false; submit.textContent = prev;
    }
  }},
    el('div', { class:'auth-tabs', role:'tablist' }, tabIn, tabUp),
    nameField,
    field('Email', email, { required:true }),
    field('Password', pass, { required:true, hint:'At least 8 characters' }),
    submit, note);

  return el('div', { class:'auth' },
    el('div', { class:'auth-card' },
      el('div', { class:'auth-mark' },
        el('div', { class:'dot', text:'BP' }),
        el('h1', { style:'font-size:1.15rem;margin:0', text:'Building Portal' }),
        el('p', { class:'muted small', style:'margin:.2rem 0 0', text:'Management & Finance' })),
      form));
}

/* Shown when the PROJECT is misconfigured rather than the account. The
   distinction matters: "waiting for an administrator" tells the reader to
   go and find a person, when what is actually needed is a setting they
   themselves can change in thirty seconds. */
function setupScreen(){
  return el('div', { class:'auth' },
    el('div', { class:'auth-card center' },
      el('div', { class:'auth-mark' }, el('div', { class:'dot', text:'⚙' })),
      el('h1', { style:'font-size:1.1rem', text:'One setup step is missing' }),
      el('p', { class:'muted', text: state.setupError ||
        'The database cannot be reached through the API.' }),
      el('p', { class:'hint', text:
        'The portal keeps all of its tables in a schema called "bms". Supabase '
        + 'only serves schemas that appear on its exposed list, and "bms" is not '
        + 'on it yet, so every query is being refused before it reaches the data. '
        + 'Nothing is wrong with your account or your database.' }),
      el('div', { class:'btn-row', style:'justify-content:center' },
        el('button', { class:'btn primary', text:'I have done it — retry',
          onclick: async () => { await loadProfile(); renderShell(); } }),
        el('button', { class:'btn danger', text:'Sign out',
          onclick: async () => { await signOut(); renderShell(); } }))));
}

function pendingScreen(){
  return el('div', { class:'auth' },
    el('div', { class:'auth-card center' },
      el('div', { class:'auth-mark' }, el('div', { class:'dot', text:'⏳' })),
      el('h1', { style:'font-size:1.1rem', text:'Waiting for access' }),
      el('p', { class:'muted' , text:
        `Your account (${state.user?.email || ''}) exists but has not been given a role yet. An administrator needs to activate it before you can see anything.` }),
      el('div', { class:'btn-row', style:'justify-content:center' },
        el('button', { class:'btn', text:'Check again', onclick: async () => { await loadProfile(); renderShell(); } }),
        el('button', { class:'btn danger', text:'Sign out', onclick: async () => { await signOut(); renderShell(); } }))));
}

function unconfiguredScreen(){
  return el('div', { class:'auth' },
    el('div', { class:'auth-card' },
      el('h1', { style:'font-size:1.1rem', text:'Not connected yet' }),
      el('p', { class:'muted', text:'config.js still has placeholder values. Put your Supabase project URL and anon key in it, then reload.' }),
      el('pre', { class:'mono small', style:'overflow-x:auto;background:var(--surface-2);padding:.7rem;border-radius:8px',
        text: 'window.BMS_CONFIG = {\n  SUPABASE_URL: "https://xxxx.supabase.co",\n  SUPABASE_ANON_KEY: "eyJ..."\n};' }),
      el('p', { class:'hint', text:'docs/SETUP.md has the full sequence, including the SQL to run first.' })));
}

/* ---------------------------------------------------------------------
   Navigation.
   --------------------------------------------------------------------- */
function buildNav(){
  const nav = $('#sidenav');
  const tabs = $('#tabbar');
  nav.replaceChildren();
  tabs.replaceChildren();

  const visible = state.modules
    .filter(m => m.is_enabled)
    .filter(m => ROUTES.some(r => r.module === m.code))
    .filter(m => canAny(m.code));

  const groups = [
    ['', ['dashboard']],
    ['Building', ['flats','charges']],
    ['Operations', ['generator','lift','fire','maintenance','work','mosque']],
    ['People', ['staff','salary']],
    ['Money', ['finance','bank','reserve','budget','reports']],
    ['Administration', ['users','audit','settings']]
  ];

  for (const [label, codes] of groups){
    const items = visible.filter(m => codes.includes(m.code));
    if (!items.length) continue;
    if (label) nav.append(el('div', { class:'nav-group', text: label }));
    for (const m of items){
      nav.append(el('a', { class:'navlink', href:'#/' + m.code, 'data-module': m.code },
        el('span', { class:'ico', text: ICONS[m.code] || '•' }),
        el('span', { text: t('module.' + m.code, m.name) })));
    }
  }

  const comingSoon = state.modules.filter(m => !m.is_enabled);
  if (comingSoon.length){
    nav.append(el('div', { class:'nav-group', text:'Later phases' }));
    nav.append(el('p', { class:'hint', style:'padding:0 .7rem',
      text: comingSoon.map(m => m.name).join(', ') }));
  }

  // Phone: the four things people actually reach for.
  // On a phone, the four things this person is most likely to want. A
  // caretaker gets operational shortcuts; an admin gets the money ones.
  const preferred = can('finance','view') || can('charges','view')
    ? ['dashboard','charges','finance','flats']
    : ['dashboard','maintenance','generator','work'];
  const tabCodes = preferred.filter(c => visible.some(m => m.code === c));
  for (const code of tabCodes.slice(0,4)){
    const m = visible.find(x => x.code === code);
    tabs.append(el('a', { href:'#/' + code, 'data-module': code },
      el('span', { class:'ico', text: ICONS[code] }),
      el('span', { text: t('module.' + code, m.name) })));
  }
}

function markActive(moduleCode){
  for (const a of document.querySelectorAll('.navlink, .tabbar a')){
    if (a.dataset.module === moduleCode) a.setAttribute('aria-current','page');
    else a.removeAttribute('aria-current');
  }
}

function wireShell(){
  const nav = $('#sidenav'), scrim = $('#navScrim'), toggle = $('#navToggle');
  const closeNav = () => { nav.classList.remove('open'); scrim.hidden = true; toggle.setAttribute('aria-expanded','false'); };
  toggle.onclick = () => {
    const open = nav.classList.toggle('open');
    scrim.hidden = !open; toggle.setAttribute('aria-expanded', String(open));
  };
  scrim.onclick = closeNav;
  nav.addEventListener('click', (e) => { if (e.target.closest('a')) closeNav(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeNav(); });

  const userBtn = $('#userBtn'), panel = $('#userPanel');
  userBtn.onclick = () => {
    panel.hidden = !panel.hidden;
    userBtn.setAttribute('aria-expanded', String(!panel.hidden));
  };
  document.addEventListener('click', (e) => {
    if (!panel.hidden && !e.target.closest('.usermenu')) { panel.hidden = true; userBtn.setAttribute('aria-expanded','false'); }
  });
  panel.addEventListener('click', async (e) => {
    const act = e.target.dataset?.act;
    if (act === 'signout'){ await logEvent('LOGOUT'); await signOut(); renderShell(); }
    if (act === 'profile'){ panel.hidden = true; await editMyDetails(); }
  });

  $('#langBtn').onclick = () => {
    setLang(currentLang() === 'en' ? 'bn' : 'en');
    location.reload();
  };
  $('#year').textContent = new Date().getFullYear();

  wireBell();
}

/* ---------------------------------------------------------------------
   Notifications.

   The list is generated in SQL from the same alert view the dashboard
   uses, and filtered by permission there — so the bell can render whatever
   it is given without deciding who is allowed to see what.
   --------------------------------------------------------------------- */
let loadBell = async () => {};

function wireBell(){
  const btn = $('#bellBtn'), panel = $('#bellPanel'), list = $('#bellList'), count = $('#bellCount');
  if (!btn) return;

  const paint = (rows) => {
    const unread = rows.filter(r => !r.is_read).length;
    count.textContent = String(unread);
    count.hidden = unread === 0;
    list.replaceChildren();
    if (!rows.length){
      list.append(el('p', { class:'hint', style:'padding:.5rem .8rem', text:'Nothing needs your attention.' }));
      return;
    }
    for (const r of rows.slice(0, 12)){
      const item = el('a', { class:'popover-item' + (r.is_read ? '' : ' unread'), href: r.link || '#/dashboard' },
        el('b', { text: r.title }),
        r.body ? el('span', { class:'muted small', text: ' ' + r.body }) : null);
      item.onclick = () => { panel.hidden = true; };
      list.append(item);
    }
  };

  const load = async () => {
    const rows = await q('v_my_notifications',
      b => b.order('created_at', { ascending:false }).limit(30), { silent:true }).catch(() => []);
    paint(rows);
  };
  loadBell = load;

  btn.onclick = async () => {
    panel.hidden = !panel.hidden;
    btn.setAttribute('aria-expanded', String(!panel.hidden));
    if (!panel.hidden) await load();
  };
  document.addEventListener('click', (e) => {
    if (!panel.hidden && !e.target.closest('#bellPanel') && !e.target.closest('#bellBtn')){
      panel.hidden = true; btn.setAttribute('aria-expanded','false');
    }
  });
  panel.addEventListener('click', async (e) => {
    if (e.target.dataset?.act !== 'readall') return;
    try { await rpc('mark_notifications_read', {}, { silent:true }); } catch { /* best effort */ }
    await load();
  });

  // Nothing is fetched here. wireShell() runs once at boot, BEFORE the
  // session is known, so loading now would fetch as a signed-out user,
  // fail, and never retry — leaving the bell permanently empty for anyone
  // who signs in during that page load. refreshBell() is called from
  // renderShell() instead, once there is a signed-in person to fetch for.
}

/** Generate this person's notifications and repaint the badge. Called
    whenever the shell renders in a signed-in state. Best-effort
    throughout: the dashboard carries the same information, so a failure
    here must never block the app. */
async function refreshBell(){
  const btn = $('#bellBtn');
  if (!btn) return;
  btn.hidden = state.status !== 'ready';
  if (state.status !== 'ready') return;
  try { await rpc('generate_notifications', {}, { silent:true }); } catch { /* ignore */ }
  try { await loadBell(); } catch { /* ignore */ }
}

async function editMyDetails(){
  const name  = el('input', { type:'text',  value: state.profile?.full_name || '' });
  const phone = el('input', { type:'tel',   value: state.profile?.phone || '', placeholder:'01XXXXXXXXX' });
  const body = el('div', {}, field('Full name', name, { required:true }), field('Mobile', phone));
  const res = await modal({ title:'My details', body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', value:true }
  ]});
  if (!res) return;
  const { update } = await import('./db.js');
  await update('user_profiles', state.user.id, { full_name: name.value.trim(), phone: phone.value.trim() || null }, 'user_id');
  await loadProfile();
  renderShell();
  ok('Saved');
}

function paintIdentity(){
  const s = state.settings || {};
  $('#brandName').textContent = s.building_name || 'Building Portal';
  $('#brandSub').textContent  = 'Management & Finance';
  document.title = (s.building_name || 'Building Portal') + ' — Portal';

  const n = state.profile?.full_name || state.user?.email || '';
  $('#userName').textContent  = n;
  $('#userEmail').textContent = state.user?.email || '';
  $('#userInitials').textContent =
    n.split(/\s+/).filter(Boolean).slice(0,2).map(w => w[0]).join('').toUpperCase() || '?';
  const chips = $('#userRoles');
  chips.replaceChildren(...state.roles.map(r => el('span', { class:'badge b-active', text:r.name })));
}

/* ---------------------------------------------------------------------
   Boot sequence.
   --------------------------------------------------------------------- */
async function afterSignIn(){
  // loadSession() picks up the new session AND the user id; calling
  // loadProfile() alone would run before state.user exists.
  await loadSession();
  if (state.status === 'ready') logEvent('LOGIN', { detail: navigator.userAgent.slice(0,120) });
  renderShell();
}

function renderShell(){
  boot.hidden = true;
  app.hidden = false;

  const bell = $('#bellBtn');
  if (bell) bell.hidden = state.status !== 'ready';

  if (state.status === 'unconfigured'){ view.replaceChildren(unconfiguredScreen()); chromeVisible(false); return; }
  if (state.status === 'signedout')   { view.replaceChildren(authScreen());        chromeVisible(false); return; }
  if (state.status === 'setup')       { view.replaceChildren(setupScreen());       chromeVisible(false); return; }
  if (state.status === 'pending')     { view.replaceChildren(pendingScreen());     chromeVisible(false); return; }

  chromeVisible(true);
  paintIdentity();
  buildNav();
  route();
  refreshBell();
}

function chromeVisible(on){
  $('.topbar').hidden = !on;
  $('#sidenav').hidden = !on;
  $('#tabbar').hidden = !on;
  $('.credit').hidden = false;
}

async function route(){
  if (state.status !== 'ready') return;
  const { route: r } = currentRoute();
  markActive(r.module);
  await renderRoute(view);
}

window.addEventListener('hashchange', route);

// The building name and currency live in the top bar, which is painted
// once per shell render. A settings save has to repaint it, or the header
// keeps showing the old name until the next sign-in.
window.addEventListener('bms:settings-changed', () => {
  if (state.status === 'ready') paintIdentity();
});

(async function main(){
  try {
    wireShell();   // menu, user panel, language toggle, footer year
    if (!isConfigured()){ state.status = 'unconfigured'; renderShell(); return; }
    bootMsg.textContent = 'Checking your session…';
    await loadSession();
    sb.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT'){ state.status = 'signedout'; renderShell(); }
    });
    renderShell();
    if ('serviceWorker' in navigator && location.protocol.startsWith('http')){
      navigator.serviceWorker.register('service-worker.js').catch(() => {});
    }
  } catch (e){
    console.error(e);
    bootMsg.textContent = 'Could not start: ' + (e.message || e);
  }
})();

// Exposed for the browser test harness.
globalThis.__BMS_APP__ = { state, renderShell, route, can };
