/* =====================================================================
   db.js — the only file that talks to Supabase.

   Every call goes through here so that error handling, the "you are
   offline" case and the audit hooks live in one place. The client is
   pinned to the `bms` schema, so a query can only ever reach this
   application's own tables — everything it can see is behind Row Level
   Security, and nothing outside `bms` is reachable by accident.
   ===================================================================== */

import { err } from './ui.js';

export const SCHEMA = 'bms';

function makeClient(){
  // The test harness injects a mock so the whole UI can be driven in a
  // browser with no network and no Supabase project.
  if (globalThis.__BMS_MOCK__) return globalThis.__BMS_MOCK__;
  const cfg = globalThis.BMS_CONFIG || {};
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.startsWith('PASTE_')) return null;
  if (!globalThis.supabase) return null;
  return globalThis.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    db: { schema: SCHEMA },
    auth: { persistSession: true, autoRefreshToken: true, storageKey: 'bms-auth' }
  });
}

export const sb = makeClient();
export const isConfigured = () => sb !== null;

/** Turn a Postgres error into something a caretaker can act on. */
export function friendly(e){
  const m = (e && (e.message || e.error_description || e.hint)) || 'Something went wrong';
  if (/permission denied/i.test(m))         return m.replace(/^.*permission denied[^:]*:?\s*/i, '') || 'You do not have permission to do that.';
  if (/duplicate key|already exists/i.test(m)) return 'That already exists.';
  if (/violates foreign key/i.test(m))      return 'That record is still in use somewhere else.';
  if (/violates check constraint "txn_transfer_ck"/i.test(m)) return 'A transfer needs two different accounts.';
  if (/violates not-null/i.test(m))         return 'A required field is missing.';
  if (/Failed to fetch|NetworkError/i.test(m)) return 'No connection. Check your internet and try again.';
  // Every table lives in `bms`, and Supabase will not serve a schema that
  // is not on its exposed list. Without this case the app looks like a
  // permissions problem — the screens render, but every query returns
  // nothing — and the setting that actually needs changing is in the
  // dashboard, not the database.
  if (/invalid schema|PGRST106|schema must be one of/i.test(m))
    return 'The database is not published to the API yet. In Supabase open '
         + 'Project Settings → API → Exposed schemas and add "bms", then reload this page.';
  return m;
}

/** True when the failure is "the bms schema is not exposed", which is a
    project setting rather than anything wrong with the data or the user. */
export const isSchemaNotExposed = (e) =>
  /invalid schema|PGRST106|schema must be one of/i.test(
    (e && (e.message || e.error_description || e.hint)) || '');

function fail(e, silent){
  const msg = friendly(e);
  if (!silent) err(msg);
  const wrapped = new Error(msg);
  wrapped.original = e;
  throw wrapped;
}

/** SELECT helper. `build` receives the query builder for filters. */
export async function q(tableOrView, build = (b) => b, { silent = false } = {}){
  if (!sb) return [];
  const { data, error } = await build(sb.from(tableOrView).select('*'));
  if (error) fail(error, silent);
  return data || [];
}

export async function one(tableOrView, build = (b) => b, opts){
  const rows = await q(tableOrView, (b) => build(b).limit(1), opts);
  return rows[0] || null;
}

export async function insert(table, row){
  if (!sb) return null;
  const { data, error } = await sb.from(table).insert(row).select().maybeSingle();
  if (error) fail(error);
  return data;
}

export async function update(table, id, patch, idCol = 'id'){
  if (!sb) return null;
  const { data, error } = await sb.from(table).update(patch).eq(idCol, id).select().maybeSingle();
  if (error) fail(error);
  return data;
}

export async function upsert(table, row, onConflict){
  if (!sb) return null;
  const { data, error } = await sb.from(table).upsert(row, onConflict ? { onConflict } : undefined).select().maybeSingle();
  if (error) fail(error);
  return data;
}

export async function del(table, match){
  if (!sb) return;
  let b = sb.from(table).delete();
  for (const [k,v] of Object.entries(match)) b = b.eq(k, v);
  const { error } = await b;
  if (error) fail(error);
}

/** Call a Postgres function. This is how every state change happens. */
export async function rpc(name, args = {}, { silent = false } = {}){
  if (!sb) return null;
  const { data, error } = await sb.rpc(name, args);
  if (error) fail(error, silent);
  return data;
}

export async function count(tableOrView, build = (b) => b){
  if (!sb) return 0;
  const { count: c, error } = await build(sb.from(tableOrView).select('*', { count:'exact', head:true }));
  if (error) fail(error, true);
  return c || 0;
}

/* ---------------------------------------------------------------------
   Storage. Buckets are private; nothing is ever a public URL.
   --------------------------------------------------------------------- */
export const BUCKETS = { receipts:'bms-receipts', photos:'bms-photos', documents:'bms-documents' };

/** Shrink a phone photo before upload. 4 MB in, ~200 KB out. */
export async function compressImage(file, maxEdge = 1600, quality = 0.82){
  if (!file.type.startsWith('image/')) return file;
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
  const w = Math.round(bitmap.width * scale), h = Math.round(bitmap.height * scale);
  const canvas = document.createElement('canvas');
  canvas.width = w; canvas.height = h;
  canvas.getContext('2d').drawImage(bitmap, 0, 0, w, h);
  const blob = await new Promise(res => canvas.toBlob(res, 'image/webp', quality));
  bitmap.close?.();
  if (!blob || blob.size >= file.size) return file;
  return new File([blob], file.name.replace(/\.[^.]+$/, '') + '.webp', { type:'image/webp' });
}

export async function uploadAttachment(bucket, entityTable, entityId, file){
  if (!sb) return null;
  const prepared = await compressImage(file);
  if (prepared.size > 5 * 1024 * 1024) throw new Error('That file is larger than 5 MB.');
  const now = new Date();
  const ext = (prepared.name.split('.').pop() || 'bin').toLowerCase();
  const path = `${now.getFullYear()}/${String(now.getMonth()+1).padStart(2,'0')}/${entityTable}/${entityId}/${crypto.randomUUID()}.${ext}`;

  const { error: upErr } = await sb.storage.from(bucket).upload(path, prepared, { contentType: prepared.type });
  if (upErr) fail(upErr);

  return insert('attachments', {
    bucket, storage_path: path, entity_table: entityTable, entity_id: entityId,
    file_name: file.name, mime_type: prepared.type, size_bytes: prepared.size
  });
}

/** Short-lived signed URL. Never a public link. */
export async function signedUrl(bucket, path, seconds = 60){
  if (!sb) return null;
  const { data, error } = await sb.storage.from(bucket).createSignedUrl(path, seconds);
  if (error) fail(error);
  return data?.signedUrl || null;
}

export const logEvent = (action, opts = {}) =>
  rpc('log_event', {
    p_action: action, p_module: opts.module || null, p_detail: opts.detail || null,
    p_entity_table: opts.table || null, p_entity_id: opts.id || null,
    p_entity_label: opts.label || null, p_severity: opts.severity || 'NORMAL'
  }, { silent: true }).catch(() => {});
