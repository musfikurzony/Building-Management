/* =====================================================================
   attachments.js — receipts, invoices and photos on an entry.

   One card, used wherever evidence belongs: a finance entry (money in or
   out), and a service-charge payment (its proof — a bKash screenshot or
   a deposit slip). It shows pictures as pictures, opens PDFs in a new
   tab, lets an entry gain a receipt at any time — including an old,
   posted one — and lets a wrong file be taken down without destroying
   it. Each file says who added it and when, so a receipt added weeks
   after the entry is visibly late rather than passing for the original.
   ===================================================================== */

import { el, fdate, fdatetime, ok, err, reasonBox } from './ui.js';
import { q, rpc, signedUrl, uploadAttachment, attachmentBlob, logEvent, isMissingObject } from './db.js';
import { can, state } from './store.js';

const isImage = (a) => /^image\//.test(a.mime_type || '');
const size = (n) => !n ? '' : n < 1024 * 1024 ? `${Math.max(1, Math.round(n / 1024))} KB` : `${(n / 1024 / 1024).toFixed(1)} MB`;

/**
 * @param {object} o
 *   entityTable  'transactions' | 'payments' | …
 *   entityId     the entry's id
 *   bucket       storage bucket
 *   canAdd       may this person attach here
 *   title, hint  wording for the card
 *   entryDate    the entry's own date, to flag a late attachment
 */
export function attachmentsCard(o){
  const card = el('section', { class:'card attach-card' },
    el('div', { class:'card-head' }, el('h2', { text: o.title || 'Receipts & photos' })));
  const grid = el('div', { class:'attach-grid' });
  const removedBox = el('div', {});
  const status = el('p', { class:'small muted', hidden:true });
  card.append(grid, status);

  if (o.canAdd){
    const input = el('input', { type:'file', multiple:true, accept:'image/*,application/pdf', class:'visually-hidden',
                                id:`attach-${o.entityId}` });
    const label = el('label', { class:'btn', for:`attach-${o.entityId}`, text:'＋ Attach receipt or photo' });
    input.onchange = async () => {
      const files = [...input.files];
      input.value = '';
      if (!files.length) return;
      label.classList.add('disabled');
      let done = 0;
      for (const f of files){
        status.hidden = false;
        status.textContent = `Uploading ${f.name}${files.length > 1 ? ` (${done + 1} of ${files.length})` : ''}…`;
        try { await uploadAttachment(o.bucket, o.entityTable, o.entityId, f); done++; }
        catch (e){ err(e.message || String(e)); }
      }
      status.hidden = true;
      label.classList.remove('disabled');
      if (done){ ok(done === 1 ? 'Attached' : `${done} files attached`); paint(); }
    };
    card.append(el('div', { class:'btn-row' }, label, input),
      el('p', { class:'hint', text: o.hint || 'A photo of the receipt or invoice, or a PDF. You can add one at any time — even to an older entry.' }));
  }
  card.append(removedBox);

  async function paint(){
    let rows;
    try {
      rows = await q('attachments', b => b.eq('entity_table', o.entityTable).eq('entity_id', o.entityId)
        .order('uploaded_at', { ascending:true }), { silent:true });
    } catch (e){
      grid.replaceChildren(el('p', { class:'small muted', text: isMissingObject(e.original || e)
        ? 'Attachments need a database update: run sql/PATCH.sql.' : 'Attachments could not be read.' }));
      return;
    }
    const who = (id, name) => id && id === state.user?.id ? 'you' : (name || 'someone');
    const live = rows.filter(a => !a.deleted_at);
    const removed = rows.filter(a => a.deleted_at);

    grid.replaceChildren(...(live.length ? live.map(a => tile(a)) : [el('p', { class:'small muted attach-empty',
      text: o.canAdd ? 'Nothing attached yet.' : 'Nothing attached.' })]));
    removedBox.replaceChildren(...(removed.length ? [el('details', { class:'attach-removed' },
      el('summary', { text:`Removed (${removed.length})` }),
      el('ul', {}, removed.map(a => el('li', { class:'small' },
        el('b', { text: a.file_name }), ` — removed ${fdatetime(a.deleted_at)} by ${who(a.deleted_by, a.deleted_by_name)}: ${a.deleted_reason || ''}`))))] : []));

    function tile(a){
      const late = o.entryDate && String(a.uploaded_at).slice(0, 10) > String(o.entryDate).slice(0, 10);
      const thumb = el('button', { class:'attach-thumb', type:'button', title:`Open ${a.file_name}`,
        onclick: () => openFile(a) },
        isImage(a) ? el('span', { class:'attach-loading', text:'…' }) : el('span', { class:'attach-pdf', text: /pdf/i.test(a.mime_type) ? 'PDF' : 'FILE' }));
      if (isImage(a)){
        attachmentBlob(a.bucket, a.storage_path).then(blob => {
          const url = URL.createObjectURL(blob);
          thumb.replaceChildren(el('img', { src: url, alt: a.file_name, loading:'lazy' }));
        }).catch(() => thumb.replaceChildren(el('span', { class:'attach-pdf', text:'IMG' })));
      }
      const mayRemove = can('finance', 'cancel') ||
        (a.uploaded_by === state.user?.id && Date.now() - new Date(a.uploaded_at).getTime() < 86400000);
      return el('figure', { class:'attach-tile' }, thumb,
        el('figcaption', {},
          el('span', { class:'attach-name', text: a.file_name }),
          el('span', { class:'small muted', text: `${size(a.size_bytes)} · added ${fdate(String(a.uploaded_at).slice(0, 10))} by ${who(a.uploaded_by, a.uploaded_by_name)}` }),
          late ? el('span', { class:'badge b-draft', text:'added after the entry date' }) : null,
          mayRemove ? el('button', { class:'btn small', type:'button', text:'Remove', onclick: () => remove(a) }) : null));
    }
  }

  async function openFile(a){
    const w = window.open('', '_blank');
    try {
      const url = await signedUrl(a.bucket, a.storage_path, 300);
      if (!url) throw new Error('no link');
      if (w) w.location.href = url; else location.href = url;
      logEvent('FILE_DOWNLOAD', { module: o.entityTable === 'payments' ? 'charges' : 'finance', table:'attachments', id:a.id, label:a.file_name });
    } catch (e){
      if (w) w.close();
      err('The file could not be opened. ' + (e.message || ''));
    }
  }

  async function remove(a){
    const reason = await reasonBox(`Remove ${a.file_name}?`, 'Why? (wrong photo, duplicate, wrong entry…)', 'Remove');
    if (!reason) return;
    try {
      await rpc('remove_attachment', { p_id: a.id, p_reason: reason });
      ok('Removed. It is kept in the record, marked removed.');
      paint();
    } catch { /* toast */ }
  }

  paint();
  return card;
}
