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
  // A function the app knows about but the database has never heard of
  // means one of the migration files was not run. Saying "does not exist"
  // is true and useless; naming the file is what someone can act on.
  if (isMissingFunction(e)){
    const fn = (m.match(/bms\.([a-z_]+)/i) || [])[1] || '';
    const file = MIGRATION_OF[fn]
              || MIGRATION_OF[Object.keys(MIGRATION_OF).find(k => m.includes(k)) || ''];
    return file
      ? `This part of the app needs a database update that has not been run yet. `
      + `In Supabase open the SQL Editor and run sql/${file} (or re-run sql/BUNDLE_all.sql, `
      + `which includes it and is safe to run twice), then reload this page.`
      : 'The database is missing something this screen needs. Re-run sql/BUNDLE_all.sql '
      + 'in the Supabase SQL Editor, then reload this page.';
  }
  return m;
}

/** Which migration file introduced which function. Used only to turn a
    "does not exist" into an instruction. */
const MIGRATION_OF = {
  reset_preview:  '070_reset.sql',
  reset_system:   '070_reset.sql',
  create_role:    '080_roles.sql',
  delete_role:    '080_roles.sql',
  category_usage: '080_roles.sql',
  // 085 adds tables, views and columns as well as functions, so the
  // names to recognise include those.
  set_flat_owner:        '085_people_reminders.sql',
  set_flat_tenant:       '085_people_reminders.sql',
  end_tenancy:           '085_people_reminders.sql',
  set_billed_party:      '085_people_reminders.sql',
  reminder_context:      '085_people_reminders.sql',
  log_charge_reminder:   '085_people_reminders.sql',
  v_flat_people:         '085_people_reminders.sql',
  v_flat_reminders:      '085_people_reminders.sql',
  charge_reminders:      '085_people_reminders.sql',
  reminder_templates:    '085_people_reminders.sql',
  reminder_how_to_pay:   '085_people_reminders.sql',
  reminder_language:     '085_people_reminders.sql',
  reminder_deadline_days:'085_people_reminders.sql',
  report_income_expense: '086_reports_funds.sql',
  report_accounts:       '086_reports_funds.sql',
  report_funds:          '086_reports_funds.sql',
  report_service_charge: '086_reports_funds.sql',
  // Only the new form of this one (paying straight out of a fund) is
  // missing before 086; the old form still exists.
  record_fund_movement:  '086_reports_funds.sql',
  v_board_members:       '087_community_backup.sql',
  board_members:         '087_community_backup.sql',
  board_member_photos:   '087_community_backup.sql',
  building_documents:    '087_community_backup.sql',
  committee_info:        '087_community_backup.sql',
  backup_log:            '087_community_backup.sql',
  log_backup:            '087_community_backup.sql',
  remove_attachment:     '088_storage_setup.sql',
  uploaded_by_name:      '088_storage_setup.sql',
  owner_accounts:        '089_owners_bills.sql',
  owner_flats:           '089_owners_bills.sql',
  month_bills:           '089_owners_bills.sql',
  log_bill_notice:       '089_owners_bills.sql',
  merge_people:          '091_people_fixes.sql',
  void_occupancy:        '091_people_fixes.sql',
  correct_occupant:      '091_people_fixes.sql',
  possible_duplicate_people: '091_people_fixes.sql',
  record_group_payment:  '089_owners_bills.sql',
  reverse_group_payment: '089_owners_bills.sql',
  v_payment_groups:      '089_owners_bills.sql',
  payment_groups:        '089_owners_bills.sql',
  set_temporary_rate:    '089_owners_bills.sql',
  cancel_temporary_rate: '089_owners_bills.sql',
  flat_rate_overrides:   '089_owners_bills.sql',
  flat_rate_for:         '089_owners_bills.sql',
  bill_template_en:      '089_owners_bills.sql',
};

/** True when the database has never heard of a function the app called —
    i.e. a migration is missing, not a permission or data problem.
    PostgREST reports it as PGRST202 with "in the schema cache"; a direct
    Postgres error says "does not exist". Both mean the same thing. */
export const isMissingFunction = (e) =>
  /PGRST20[245]|could not find the (function|table|relation)|could not find the '.*' column|does not exist/i.test(
    (e && (e.message || e.error_description || e.hint)) || '');

/** The same, under the name that says what it now covers: a function,
    table, view or column the code expects and the database lacks. */
export const isMissingObject = isMissingFunction;

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

const TYPE_BY_EXT = {
  jpg:'image/jpeg', jpeg:'image/jpeg', png:'image/png', webp:'image/webp', heic:'image/heic', heif:'image/heif',
  pdf:'application/pdf', doc:'application/msword',
  docx:'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
};
export const MAX_UPLOAD = 10 * 1024 * 1024;

/** What went wrong with a storage call, in words someone can act on. */
export function storageMessage(e){
  const m = String((e && (e.message || e.error)) || e || '');
  if (/bucket not found/i.test(m))
    return 'File storage is not set up yet. In Supabase open the SQL Editor and run sql/PATCH.sql (it creates the storage), then attach the file again.';
  if (/row-level security|unauthori[sz]ed|permission denied/i.test(m))
    return 'Your role is not allowed to attach files here. Ask an administrator.';
  if (/maximum allowed size|too large|payload/i.test(m)) return 'That file is too large. The limit is 10 MB.';
  if (/mime type|not supported/i.test(m)) return 'That kind of file is not accepted here. Use a photo (JPG or PNG) or a PDF.';
  if (/failed to fetch|network/i.test(m)) return 'No connection. Check your internet and try again.';
  return 'The file could not be uploaded: ' + m;
}

/**
 * Store a file and record it against an entry. The picture is shrunk
 * first (a 4 MB phone photo becomes ~200 KB); if the phone's format
 * cannot be shrunk in the browser it goes as it is. Nothing is recorded
 * unless the file really arrived, and nothing is left behind if the
 * record cannot be written.
 */
export async function uploadAttachment(bucket, entityTable, entityId, file){
  if (!sb) return null;
  let prepared = file;
  try { prepared = await compressImage(file); } catch { prepared = file; }
  const ext = (prepared.name.split('.').pop() || '').toLowerCase();
  const type = prepared.type || TYPE_BY_EXT[ext];
  if (!type) throw new Error('That kind of file cannot be attached. Use a photo (JPG or PNG) or a PDF.');
  if (prepared.type !== type) prepared = new File([prepared], prepared.name, { type });
  if (prepared.size > MAX_UPLOAD) throw new Error('That file is larger than 10 MB. Take the photo again or scan the PDF at a lower resolution.');

  const now = new Date();
  const path = `${now.getFullYear()}/${String(now.getMonth()+1).padStart(2,'0')}/${entityTable}/${entityId}/${crypto.randomUUID()}.${ext || 'bin'}`;
  const { error: upErr } = await sb.storage.from(bucket).upload(path, prepared, { contentType: type });
  if (upErr) throw new Error(storageMessage(upErr));

  try {
    return await insert('attachments', {
      bucket, storage_path: path, entity_table: entityTable, entity_id: entityId,
      file_name: file.name, mime_type: type, size_bytes: prepared.size
    });
  } catch (e){
    sb.storage.from(bucket).remove([path]).catch(() => {});
    throw e;
  }
}

/** The file itself, for showing a picture inside the page. */
export async function attachmentBlob(bucket, path){
  if (!sb) return null;
  const { data, error } = await sb.storage.from(bucket).download(path);
  if (error) throw new Error(storageMessage(error));
  return data;
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
