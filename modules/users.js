/* Users, roles and the permission grid.

   Everything here is presentation of what the database already enforces.
   Ticking a box writes a role_permissions row; the rule that box
   represents is applied by Row Level Security, not by this screen. */

import { el, field, select, money, table, badge, ok, err, modal, confirmBox,
         emptyState, fdate } from '../core/ui.js';
import { q, insert, update, del, rpc } from '../core/db.js';
import { refresh } from '../core/router.js';
import { can, ref, state, invalidate } from '../core/store.js';

export async function render({ params }){
  if (params[0] === 'roles') return rolesView();
  return usersView();
}

async function usersView(){
  const [users, roles, links] = await Promise.all([
    ref('users', true), ref('roles', true), q('user_roles').catch(() => [])
  ]);
  const rolesOf = (uid) => links.filter(l => l.user_id === uid)
    .map(l => roles.find(r => r.id === l.role_id)).filter(Boolean);

  const cols = [
    { label:'Name', primary:true, key:'full_name' },
    { label:'Email', fmt: u => u.email || '—' },
    { label:'Roles', fmt: u => {
        const rs = rolesOf(u.user_id);
        if (!rs.length) return el('span', { class:'badge b-draft', text:'no role' });
        return el('span', { class:'chips' }, ...rs.map(r => el('span', { class:'badge b-active', text:r.name })));
      } },
    { label:'Approves up to', cls:'num', fmt: u => {
        const rs = rolesOf(u.user_id);
        if (u.approval_limit !== null && u.approval_limit !== undefined) return money(u.approval_limit) + ' *';
        if (rs.some(r => r.is_superuser || r.approve_limit === null)) return 'unlimited';
        const max = Math.max(0, ...rs.map(r => Number(r.approve_limit || 0)));
        return max ? money(max) : '—';
      } },
    { label:'Status', fmt: u => badge(u.is_active ? 'ACTIVE' : 'PENDING') },
    { label:'', fmt: u => can('users','edit')
        ? el('button', { class:'btn small', text:'Manage', onclick: () => userDialog(u, roles, rolesOf(u.user_id)) })
        : '' }
  ];

  const waiting = users.filter(u => !u.is_active);
  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Users & roles' }),
    el('p', { class:'sub', text:'People create their own account by signing in. Nobody sees anything until you activate them and give them a role.' })));

  if (waiting.length){
    page.append(el('div', { class:'alert normal' }, el('div', { class:'a-body' },
      el('div', { class:'a-title', text:`${waiting.length} account${waiting.length === 1 ? '' : 's'} waiting for activation` }),
      el('div', { class:'a-meta', text: waiting.map(u => u.full_name || u.email).join(', ') }))));
  }

  page.append(el('div', { class:'toolbar' },
    el('a', { class:'btn', href:'#/users/roles', text:'Roles & permissions' })));
  page.append(table(cols, users, { empty:'No accounts yet.' }));
  page.append(el('p', { class:'hint', text:'* a personal limit set on this account, overriding the role.' }));
  return page;
}

async function userDialog(user, roles, mine){
  const active = el('input', { type:'checkbox' });
  active.checked = !!user.is_active;
  const limit = el('input', { type:'number', step:'0.01', min:'0',
    value: user.approval_limit ?? '', placeholder:'use the role limit' });

  const boxes = roles.map(r => {
    const cb = el('input', { type:'checkbox', value:r.id });
    cb.checked = mine.some(m => m.id === r.id);
    return { role:r, cb };
  });

  const body = el('div', {},
    el('dl', { class:'dl' },
      el('dt', { text:'Name' }),  el('dd', { text:user.full_name }),
      el('dt', { text:'Email' }), el('dd', { text:user.email || '—' }),
      el('dt', { text:'Phone' }), el('dd', { text:user.phone || '—' })),
    el('label', { class:'check', style:'margin-top:.8rem' }, active,
      el('span', { text:'Account is active (can sign in and see the portal)' })),
    el('fieldset', {}, el('legend', {}, 'Roles'),
      ...boxes.map(b => el('label', { class:'check' }, b.cb,
        el('span', {}, el('b', { text:b.role.name }), ' ',
          el('span', { class:'hint', text: b.role.description || '' }))))),
    field('Personal approval limit', limit,
      { hint:'Leave blank to use whatever the role allows. Set 0 to stop this person approving anything.' }));

  const res = await modal({ title:'Manage access', body, actions:[
    { label:'Cancel', value:null },
    { label:'Save', kind:'primary', value:true }
  ]});
  if (!res) return;

  try {
    await update('user_profiles', user.user_id, {
      is_active: active.checked,
      approval_limit: limit.value === '' ? null : Number(limit.value)
    }, 'user_id');

    for (const b of boxes){
      const had = mine.some(m => m.id === b.role.id);
      if (b.cb.checked && !had) await insert('user_roles', { user_id:user.user_id, role_id:b.role.id, assigned_by: state.user.id });
      if (!b.cb.checked && had) await del('user_roles', { user_id:user.user_id, role_id:b.role.id });
    }
    invalidate('users','roles');
    ok('Saved'); refresh();
  } catch { /* toast shown */ }
}

/* ------------------------------------------------------------------ */
async function rolesView(){
  const [roles, perms, rp, modules] = await Promise.all([
    ref('roles', true),
    q('permissions').catch(() => []),
    q('role_permissions').catch(() => []),
    q('modules', b => b.order('sort_order')).catch(() => [])
  ]);
  const has = (roleId, permId) => rp.some(x => x.role_id === roleId && x.permission_id === permId);
  const ACTIONS = ['view','add','edit','approve','export','cancel','waive','close','view_sensitive','manage'];

  const page = el('div', {});
  page.append(el('div', { class:'page-head' },
    el('h1', { text:'Roles & permissions' }),
    el('p', { class:'sub', text:'A tick here writes a permission row. The rule it stands for is applied inside the database on every request, not in the browser.' })));
  const bar = el('div', { class:'toolbar' }, el('a', { class:'btn', href:'#/users', text:'← Users' }));
  if (can('users','manage')){
    bar.append(el('button', { class:'btn primary', text:'＋ New role',
      onclick: () => newRoleDialog(roles) }));
  }
  page.append(bar);

  for (const role of roles){
    const head = el('div', { class:'card-head' },
      el('h2', { text: role.name }),
      role.is_superuser ? el('span', { class:'badge b-active', text:'all permissions' }) : null,
      role.is_system    ? el('span', { class:'badge b-draft',  text:'built in' })
                        : el('span', { class:'badge b-active', text:'yours' }));
    if (!role.is_system && can('users','manage')){
      head.append(el('span', { class:'spacer' }));
      head.append(el('button', { class:'btn small danger', text:'Remove',
        onclick: () => removeRole(role) }));
    }
    const card = el('section', { class:'card' }, head);
    card.append(el('p', { class:'small muted', text: role.description || '' }));
    card.append(el('p', { class:'small' },
      'Posts without approval up to ',
      el('b', { text: role.auto_post_limit === null ? 'any amount' : money(role.auto_post_limit) }),
      ' · approves up to ',
      el('b', { text: role.approve_limit === null ? 'any amount' : money(role.approve_limit) })));

    if (role.is_superuser){
      card.append(el('p', { class:'hint', text:'A superuser role always holds every permission and cannot be narrowed here.' }));
      page.append(card); continue;
    }

    const wrap = el('div', { class:'tablewrap' });
    const thead = el('thead', {}, el('tr', {},
      el('th', {}, 'Module'), ...ACTIONS.map(a => el('th', { class:'center' }, a.replace('_',' ')))));
    const tbody = el('tbody');
    for (const m of modules){
      const tr = el('tr', {}, el('td', {}, m.name));
      for (const a of ACTIONS){
        const p = perms.find(x => x.module_code === m.code && x.action === a);
        const td = el('td', { class:'center' });
        if (!p) td.append(el('span', { class:'muted', text:'·' }));
        else {
          const cb = el('input', { type:'checkbox' });
          cb.checked = has(role.id, p.id);
          cb.disabled = !can('users','manage');
          cb.onchange = async () => {
            try {
              if (cb.checked) await insert('role_permissions', { role_id: role.id, permission_id: p.id });
              else            await del('role_permissions', { role_id: role.id, permission_id: p.id });
              ok(`${role.name}: ${m.name} ${a} ${cb.checked ? 'granted' : 'removed'}`);
            } catch { cb.checked = !cb.checked; }
          };
          td.append(cb);
        }
        tr.append(td);
      }
      tbody.append(tr);
    }
    wrap.append(el('table', {}, thead, tbody));
    card.append(wrap);
    page.append(card);
  }
  return page;
}

/* ------------------------------------------------------------------
   Making a role of your own.

   Starting from nothing is 190 checkboxes and easy to get wrong in the
   dangerous direction — the mistake you make is forgetting to remove
   something, not forgetting to add it. So the dialog is built around
   copying an existing role and then narrowing it, which is also how
   people describe what they want: "like the caretaker, but only the
   generator".

   Everything this writes is checked again in the database. A role with
   full access can only be made by someone who already has full access,
   and a permission can only be ticked on by someone who holds it — see
   sql/080_roles.sql, which exists because an Admin could previously
   promote themselves to Super Admin this way.
   ------------------------------------------------------------------ */
async function newRoleDialog(roles){
  const name = el('input', { type:'text', maxlength:'40', required:true,
                             placeholder:'Generator Operator' });
  const desc = el('input', { type:'text', maxlength:'120',
                             placeholder:'What this person is responsible for' });

  const copyable = roles.filter(r => !r.is_superuser);
  const copy = select(
    [{ value:'', label:'Nothing — start with no access at all' },
     ...copyable.map(r => ({ value:r.id, label:`Start from ${r.name}` }))],
    { value: (copyable.find(r => r.code === 'CARETAKER') || {}).id || '' });

  const approve  = el('input', { type:'number', min:'0', step:'0.01', value:'0' });
  const autopost = el('input', { type:'number', min:'0', step:'0.01', value:'0' });

  const body = el('div', {},
    field('Role name', name, { required:true, hint:'What the job is called. You can rename it later.' }),
    field('Description', desc),
    field('Copy the permissions from', copy,
      { hint:'You tick and untick afterwards. Copying is only the starting point.' }),
    el('div', { class:'grid g-form' },
      field('Can approve up to', approve, { hint:'0 means they approve nothing' }),
      field('Posts without approval up to', autopost,
            { hint:'0 means everything they enter waits for someone else' })));

  const go = await modal({ title:'A new role', body, actions:[
    { label:'Cancel', value:null },
    { label:'Create role', kind:'primary',
      validate: () => {
        if (name.value.trim()) return true;
        err('Give the role a name'); name.focus(); return false;
      },
      value: true }
  ]});
  if (!go) return;

  try {
    const r = await rpc('create_role', {
      p_name: name.value.trim(),
      p_description: desc.value.trim() || null,
      p_copy_from: copy.value || null,
      p_approve_limit: Number(approve.value || 0),
      p_auto_post_limit: Number(autopost.value || 0)
    });
    invalidate('roles');
    ok(`${r.name} created — now tick what it should reach`);
    refresh();
  } catch { /* toast shown */ }
}

async function removeRole(role){
  const yes = await confirmBox('Remove this role?',
    `${role.name} will be gone. Anyone still holding it must be moved off it first — the database will refuse otherwise.`,
    'Remove role', 'danger');
  if (!yes) return;
  try {
    await rpc('delete_role', { p_role: role.id });
    invalidate('roles');
    ok(`${role.name} removed`);
    refresh();
  } catch { /* toast shown */ }
}
