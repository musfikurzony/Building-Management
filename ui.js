/* =====================================================================
   ui.js — DOM, formatting and escaping helpers.

   Escaping is the default, not something you remember to do: `html`
   escapes every interpolation, and anything unescaped has to say so out
   loud by calling raw(). An owner named `<img src=x onerror=...>` is
   rendered as those characters and never as markup — there is a browser
   test that types exactly that and fails if a dialog appears.
   ===================================================================== */

export function esc(v){
  if (v === null || v === undefined) return '';
  return String(v)
    .replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;')
    .replaceAll('"','&quot;').replaceAll("'",'&#39;');
}

const RAW = Symbol('raw');
export function raw(s){ return { [RAW]: String(s ?? '') }; }
function render(v){
  if (v === null || v === undefined || v === false) return '';
  if (Array.isArray(v)) return v.map(render).join('');
  if (typeof v === 'object' && RAW in v) return v[RAW];
  return esc(v);
}

/** Tagged template that escapes every ${...} unless wrapped in raw(). */
export function html(strings, ...vals){
  let out = strings[0];
  for (let i = 0; i < vals.length; i++) out += render(vals[i]) + strings[i+1];
  return raw(out);
}

export function setHTML(node, content){
  node.innerHTML = typeof content === 'object' && RAW in content ? content[RAW] : esc(content);
  return node;
}

export function el(tag, props = {}, ...kids){
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})){
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') n.className = v;
    else if (k === 'html') setHTML(n, v);
    else if (k === 'text') n.textContent = v;
    else if (k.startsWith('on') && typeof v === 'function') n.addEventListener(k.slice(2), v);
    else if (k === 'dataset') Object.assign(n.dataset, v);
    else n.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()){
    if (kid === null || kid === undefined || kid === false) continue;
    n.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return n;
}

export const $  = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

/* ---------------------------------------------------------------------
   Money and dates.
   Amounts arrive from Postgres as strings ("4500.00") precisely so that
   nothing is lost to a float. We format for display and never do
   arithmetic on the way in.
   --------------------------------------------------------------------- */
let CURRENCY = 'Tk';
export function setCurrency(sym){ CURRENCY = sym || 'Tk'; }

export function money(v, opts = {}){
  if (v === null || v === undefined || v === '') return opts.dash ? '—' : '';
  const n = Number(v);
  if (!Number.isFinite(n)) return String(v);
  const body = n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return (opts.bare ? '' : CURRENCY + ' ') + body;
}
/** Whole taka, for dashboard cards where the paisa is noise. */
export function money0(v){
  const n = Number(v || 0);
  if (!Number.isFinite(n)) return String(v);
  return CURRENCY + ' ' + Math.round(n).toLocaleString('en-IN');
}
export function num(v, dp = 0){
  const n = Number(v || 0);
  return n.toLocaleString('en-IN', { minimumFractionDigits: dp, maximumFractionDigits: dp });
}

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
export function fdate(v){
  if (!v) return '';
  const d = new Date(v.length <= 10 ? v + 'T00:00:00' : v);
  if (isNaN(d)) return String(v);
  return `${String(d.getDate()).padStart(2,'0')} ${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}
export function fdatetime(v){
  if (!v) return '';
  const d = new Date(v);
  if (isNaN(d)) return String(v);
  const t = d.toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
  return `${fdate(v)}, ${t}`;
}
export function monthName(y, m){ return `${MONTHS[m-1]} ${y}`; }
export function todayISO(){
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

export function badge(status){
  const s = String(status || '').toLowerCase();
  const label = String(status || '').replace(/_/g,' ');
  return html`<span class="badge b-${raw(esc(s))}">${label}</span>`;
}

/* ---------------------------------------------------------------------
   Toasts and modals.
   --------------------------------------------------------------------- */
export function toast(msg, kind = ''){
  const host = $('#toasts');
  if (!host) { console.log(msg); return; }
  const node = el('div', { class: 'toast ' + kind, role: 'status', text: String(msg) });
  host.append(node);
  setTimeout(() => node.remove(), kind === 'err' ? 7000 : 3800);
}
export const ok  = (m) => toast(m, 'ok');
export const err = (m) => toast(m, 'err');

/** A modal that returns a promise. resolve(null) on cancel. */
export function modal({ title, body, actions = [], onMount }){
  return new Promise((resolve) => {
    const host = $('#modalHost');
    const close = (val) => { scrim.remove(); document.removeEventListener('keydown', onKey); resolve(val); };
    const onKey = (e) => { if (e.key === 'Escape') close(null); };

    const btns = el('div', { class: 'btn-row' });
    const box  = el('div', { class: 'modal', role:'dialog', 'aria-modal':'true', 'aria-label': title || 'Dialog' },
      el('div', { class: 'modal-head' },
        el('h2', { text: title || '' }),
        el('button', { class: 'icon-btn', 'aria-label': 'Close', onclick: () => close(null), text: '✕' })),
      typeof body === 'string' ? el('p', { text: body }) : body,
      btns);

    for (const a of actions){
      btns.append(el('button', {
        class: 'btn ' + (a.kind || ''),
        onclick: async () => {
          if (a.validate && !a.validate()) return;
          close(a.value !== undefined ? a.value : (a.collect ? a.collect() : true));
        },
        text: a.label
      }));
    }
    if (!actions.length) btns.append(el('button', { class:'btn', text:'Close', onclick: () => close(null) }));

    const scrim = el('div', { class:'modal-scrim', onclick: (e) => { if (e.target === scrim) close(null); } }, box);
    host.append(scrim);
    document.addEventListener('keydown', onKey);
    if (onMount) onMount(box);
    const first = box.querySelector('input,select,textarea,button');
    if (first) first.focus();
  });
}

export function confirmBox(title, message, confirmLabel = 'Confirm', kind = 'primary'){
  return modal({ title, body: message, actions: [
    { label: 'Cancel', value: null },
    { label: confirmLabel, kind, value: true }
  ]});
}

/** Prompt for a mandatory reason — used by every reversal and rejection. */
export async function reasonBox(title, label = 'Reason', confirmLabel = 'Confirm'){
  let input;
  const body = el('div', {}, el('label', { class: 'field' },
    el('span', { class:'req', text: label }),
    (input = el('textarea', { rows: 3, required: true }))));
  const res = await modal({ title, body, actions: [
    { label: 'Cancel', value: null },
    { label: confirmLabel, kind: 'danger',
      validate: () => {
        if (input.value.trim()) return true;
        err('A reason is required'); input.focus(); return false;
      },
      collect: () => input.value.trim() }
  ]});
  return res;
}

/* ---------------------------------------------------------------------
   Small builders used all over the module screens.
   --------------------------------------------------------------------- */
export function stat(label, value, foot, tone = ''){
  return el('div', { class: 'stat ' + tone },
    el('span', { class:'label', text: label }),
    el('span', { class:'value', text: value }),
    foot ? el('span', { class:'foot', text: foot }) : null);
}

export function emptyState(message, action){
  const n = el('div', { class:'empty' }, el('p', { text: message }));
  if (action) n.append(action);
  return n;
}

export function field(label, control, { hint, required } = {}){
  return el('label', { class:'field' },
    el('span', { class: required ? 'req' : '', text: label }),
    control,
    hint ? el('span', { class:'hint', text: hint }) : null);
}

export function select(options, { value, placeholder, name } = {}){
  const s = el('select', name ? { name } : {});
  if (placeholder) s.append(el('option', { value:'' }, placeholder));
  for (const o of options){
    const opt = el('option', { value: o.value }, o.label);
    if (String(o.value) === String(value)) opt.selected = true;
    s.append(opt);
  }
  return s;
}

/** Table builder. cols: [{key,label,cls,fmt,primary}] */
export function table(cols, rows, { onRow, foot, stack = true, empty = 'Nothing to show.' } = {}){
  if (!rows || !rows.length) return emptyState(empty);
  const thead = el('thead', {}, el('tr', {}, cols.map(c => el('th', { class: c.cls || '' }, c.label))));
  const tbody = el('tbody');
  for (const r of rows){
    const tr = el('tr', onRow ? { class:'clickable', tabindex:'0',
      onclick: () => onRow(r),
      onkeydown: (e) => { if (e.key === 'Enter') onRow(r); } } : {});
    for (const c of cols){
      const td = el('td', { class: (c.cls || '') + (c.primary ? ' primary' : ''), 'data-l': c.label });
      const v = c.fmt ? c.fmt(r) : r[c.key];
      if (v instanceof Node) td.append(v);
      else if (v && typeof v === 'object' && RAW in v) setHTML(td, v);
      else td.textContent = v === null || v === undefined ? '' : String(v);
      tr.append(td);
    }
    tbody.append(tr);
  }
  const t = el('table', { class: stack ? 'stack' : '' }, thead, tbody);
  if (foot) t.append(el('tfoot', {}, el('tr', {}, foot.map(f => el('td', { class: f.cls || '', 'data-l': f.label || '' }, f.value)))));
  return el('div', { class:'tablewrap' }, t);
}

/* ---------------------------------------------------------------------
   CSV export. Cells starting with = + - @ are prefixed so a vendor named
   "=cmd()" cannot execute when the file is opened in Excel.
   --------------------------------------------------------------------- */
export function toCSV(cols, rows){
  const cell = (v) => {
    let s = v === null || v === undefined ? '' : String(v);
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
    return '"' + s.replaceAll('"','""') + '"';
  };
  const lines = [cols.map(c => cell(c.label)).join(',')];
  for (const r of rows) lines.push(cols.map(c => cell(c.csv ? c.csv(r) : r[c.key])).join(','));
  return '﻿' + lines.join('\r\n');
}

export function downloadCSV(filename, cols, rows){
  const blob = new Blob([toCSV(cols, rows)], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = el('a', { href: url, download: filename });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/**
 * The block that turns a screen into a document when it is printed.
 *
 * Hidden on screen — the page already has a heading and the building name
 * is in the top bar — and revealed by the print stylesheet, so a saved PDF
 * carries the building's name, address, what the report is, the period it
 * covers, and when it was produced. Without the period and the date, a
 * printed statement is unfalsifiable: nobody looking at it later can tell
 * what it was meant to show.
 */
export function letterhead({ name, address, title, period, extra } = {}){
  return el('div', { class:'letterhead' },
    el('p', { class:'lh-name', text: name || 'Building' }),
    address ? el('p', { class:'lh-addr', text: address }) : null,
    el('hr', { class:'lh-rule' }),
    el('p', { class:'lh-title', text: title || 'Report' }),
    el('div', { class:'lh-meta' },
      el('span', { text: period || '' }),
      el('span', { text: extra || ('Produced ' + fdatetime(new Date().toISOString())) })));
}

export function spinner(){ return el('div', { class:'center' }, el('div', { class:'spinner', style:'margin:2rem auto' })); }
