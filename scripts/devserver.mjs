/* =====================================================================
   devserver.mjs — a local stand-in for Supabase.

   Serves the portal's static files AND speaks enough of the PostgREST +
   GoTrue wire format that the real supabase-js client works unchanged
   against a local PostgreSQL database.

   Why this exists: it lets the whole portal be developed and tested
   without touching the live Supabase project, and — because every query
   runs as the `authenticated` role with the caller's user id in
   request.jwt.claim.sub — Row Level Security applies exactly as it does
   in production. A permission bug shows up here, not in production.

   NOT for production use. It has no TLS, no password hashing and no rate
   limiting; it is a development tool.

     node scripts/devserver.mjs [port]
   ===================================================================== */

import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import pg from 'pg';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const PORT = Number(process.argv[2] || 5173);
const SCHEMA = 'bms';

const pool = new pg.Pool({
  host: process.env.PGHOST || '127.0.0.1',
  port: Number(process.env.PGPORT || 5433),
  user: process.env.PGUSER || 'postgres',
  database: process.env.PGDATABASE || 'bms_test',
  max: 8
});

const sessions = new Map();      // access_token -> user id
const MIME = {
  '.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8', '.mjs':'text/javascript; charset=utf-8',
  '.css':'text/css; charset=utf-8', '.json':'application/json; charset=utf-8',
  '.svg':'image/svg+xml', '.png':'image/png', '.webmanifest':'application/manifest+json'
};

const json = (res, code, body) => {
  const payload = JSON.stringify(body);
  res.writeHead(code, {
    'Content-Type':'application/json; charset=utf-8',
    // Real PostgREST never lets a browser cache a query result. Without
    // this the app re-renders from a stale copy after every write.
    'Cache-Control':'no-store, no-cache, must-revalidate',
    'Content-Range':'0-0/*',
    'Access-Control-Allow-Origin':'*',
    'Access-Control-Allow-Headers':'*',
    'Access-Control-Expose-Headers':'Content-Range'
  });
  res.end(payload);
};

/* ---------------------------------------------------------------------
   Run one statement as the signed-in user: same role, same claim, so the
   same RLS policies apply.
   --------------------------------------------------------------------- */
async function asUser(userId, fn){
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (userId){
      await client.query('SET LOCAL ROLE authenticated');
      await client.query("SELECT set_config('request.jwt.claim.sub', $1, true)", [userId]);
      await client.query("SELECT set_config('request.jwt.claim.role', 'authenticated', true)");
    } else {
      await client.query('SET LOCAL ROLE anon');
    }
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e){
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

/* ---------------------------------------------------------------------
   PostgREST-ish query translation.
   --------------------------------------------------------------------- */
const OPS = { eq:'=', gt:'>', gte:'>=', lt:'<', lte:'<=', neq:'<>', like:'LIKE', ilike:'ILIKE' };

function buildSelect(table, params){
  const where = [], args = [];
  let order = '', limit = '', offset = '';

  for (const [key, value] of params){
    if (key === 'select' || key === 'on_conflict' || key === 'columns') continue;
    if (key === 'order'){
      order = ' ORDER BY ' + value.split(',').map(part => {
        const [col, ...mods] = part.split('.');
        const dir = mods.includes('desc') ? 'DESC' : 'ASC';
        const nulls = mods.includes('nullsfirst') ? ' NULLS FIRST'
                    : mods.includes('nullslast') ? ' NULLS LAST' : '';
        return `"${col}" ${dir}${nulls}`;
      }).join(', ');
      continue;
    }
    if (key === 'limit'){ limit = ` LIMIT ${Number(value) || 100}`; continue; }
    if (key === 'offset'){ offset = ` OFFSET ${Number(value) || 0}`; continue; }

    const dot = value.indexOf('.');
    const op  = value.slice(0, dot);
    const val = value.slice(dot + 1);

    if (op === 'is'){
      where.push(`"${key}" IS ${val === 'null' ? 'NULL' : val.toUpperCase()}`);
    } else if (op === 'in'){
      const items = val.replace(/^\(|\)$/g,'').split(',').map(s => s.replace(/^"|"$/g,''));
      if (!items.length || (items.length === 1 && items[0] === '')){ where.push('false'); continue; }
      const ph = items.map(v => { args.push(v); return `$${args.length}`; });
      where.push(`"${key}"::text IN (${ph.join(',')})`);
    } else if (OPS[op]){
      args.push(val);
      where.push(`"${key}"::text ${OPS[op]} $${args.length}::text`);
    }
  }
  const sql = `SELECT * FROM ${SCHEMA}."${table}"` +
              (where.length ? ' WHERE ' + where.join(' AND ') : '') + order + limit + offset;
  return { sql, args };
}

const retsetCache = new Map();
async function isSetReturning(fn){
  if (retsetCache.has(fn)) return retsetCache.get(fn);
  const out = await pool.query(
    `SELECT bool_or(p.proretset) AS retset FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = $1 AND p.proname = $2`, [SCHEMA, fn]);
  const v = !!out.rows[0]?.retset;
  retsetCache.set(fn, v);
  return v;
}

async function handleRest(req, res, url, userId, body){
  const parts = url.pathname.replace(/^\/rest\/v1\/?/, '').split('/').filter(Boolean);

  // --- RPC ---
  if (parts[0] === 'rpc'){
    const fn = parts[1];
    const args = body || {};
    const names = Object.keys(args);
    const ph = names.map((n,i) => `${n} => $${i+1}`).join(', ');
    const sql = `SELECT * FROM ${SCHEMA}."${fn}"(${ph})`;
    // An object or array argument is a jsonb parameter. node-postgres would
    // otherwise send it as a Postgres array literal ({a,b}), which is not
    // JSON; real PostgREST sends it as JSON text. Match that.
    const values = names.map(n => {
      const v = args[n];
      return (v !== null && typeof v === 'object') ? JSON.stringify(v) : v;
    });
    const out = await asUser(userId, c => c.query(sql, values));

    // Whether a set or a single value comes back is a property of the
    // function, not of how many rows it happened to return this time.
    const setReturning = await isSetReturning(fn);
    const single = out.fields.length === 1 && out.fields[0].name === fn;
    const rows = single ? out.rows.map(r => r[fn]) : out.rows;
    return json(res, 200, setReturning ? rows : (rows.length ? rows[0] : null));
  }

  const table = parts[0];
  const params = [...url.searchParams.entries()];
  const prefer = String(req.headers['prefer'] || '');
  const wantsRow = prefer.includes('return=representation');
  const headOnly = req.method === 'HEAD' || prefer.includes('count=exact') && req.method === 'GET' && req.headers['range-unit'];

  if (req.method === 'GET' || req.method === 'HEAD'){
    const { sql, args } = buildSelect(table, params);
    const out = await asUser(userId, c => c.query(sql, args));
    if (req.method === 'HEAD'){
      res.writeHead(200, { 'Content-Range': `0-${Math.max(0,out.rowCount-1)}/${out.rowCount}`,
                           'Access-Control-Expose-Headers':'Content-Range' });
      return res.end();
    }
    if (wantsObject(req)) return sendRows(req, res, out.rows);
    res.writeHead(200, { 'Content-Type':'application/json; charset=utf-8',
                         'Cache-Control':'no-store, no-cache, must-revalidate',
                         'Content-Range': `0-${Math.max(0,out.rowCount-1)}/${out.rowCount}` });
    return res.end(JSON.stringify(out.rows));
  }

  if (req.method === 'POST'){
    const rows = Array.isArray(body) ? body : [body];
    const onConflict = url.searchParams.get('on_conflict');
    const results = [];
    await asUser(userId, async (c) => {
      for (const row of rows){
        const cols = Object.keys(row);
        const ph = cols.map((_,i) => `$${i+1}`);
        let sql = `INSERT INTO ${SCHEMA}."${table}" (${cols.map(x => `"${x}"`).join(',')}) VALUES (${ph.join(',')})`;
        if (onConflict){
          const keys = onConflict.split(',').map(k => `"${k.trim()}"`).join(',');
          const sets = cols.filter(x => !onConflict.split(',').map(s=>s.trim()).includes(x))
                           .map(x => `"${x}" = EXCLUDED."${x}"`).join(', ');
          sql += ` ON CONFLICT (${keys}) DO ${sets ? 'UPDATE SET ' + sets : 'NOTHING'}`;
        }
        sql += ' RETURNING *';
        const out = await c.query(sql, cols.map(k => row[k]));
        results.push(...out.rows);
      }
    });
    return wantsRow ? sendRows(req, res, results, 201) : json(res, 201, null);
  }

  if (req.method === 'PATCH'){
    const cols = Object.keys(body);
    const { sql: sel, args } = buildSelect(table, params);
    const whereClause = sel.includes(' WHERE ') ? sel.slice(sel.indexOf(' WHERE ')).replace(/ ORDER BY .*| LIMIT .*/g,'') : '';
    const sets = cols.map((c,i) => `"${c}" = $${args.length + i + 1}`).join(', ');
    const sql = `UPDATE ${SCHEMA}."${table}" SET ${sets}${whereClause} RETURNING *`;
    const out = await asUser(userId, c => c.query(sql, [...args, ...cols.map(k => body[k])]));
    return wantsRow ? sendRows(req, res, out.rows) : json(res, 200, null);
  }

  if (req.method === 'DELETE'){
    const { sql: sel, args } = buildSelect(table, params);
    const whereClause = sel.includes(' WHERE ') ? sel.slice(sel.indexOf(' WHERE ')).replace(/ ORDER BY .*| LIMIT .*/g,'') : '';
    const sql = `DELETE FROM ${SCHEMA}."${table}"${whereClause} RETURNING *`;
    const out = await asUser(userId, c => c.query(sql, args));
    return json(res, 200, wantsRow ? out.rows : null);
  }

  return json(res, 405, { message:'Method not supported by the dev server' });
}

/* ---------------------------------------------------------------------
   A very small GoTrue stand-in. Passwords are not checked: this is a
   development tool, and the accounts are the local test fixtures.
   --------------------------------------------------------------------- */
async function handleAuth(req, res, url, body){
  const p = url.pathname.replace(/^\/auth\/v1\/?/, '');

  if (p === 'token'){
    const email = body?.email;
    const out = await pool.query('SELECT id, email FROM auth.users WHERE email = $1', [email]);
    if (!out.rows.length) return json(res, 400, { error:'invalid_grant', error_description:'No such account on the dev server' });
    const user = out.rows[0];
    const token = crypto.randomUUID();
    sessions.set(token, user.id);
    return json(res, 200, {
      access_token: token, token_type:'bearer', expires_in: 86400,
      expires_at: Math.floor(Date.now()/1000) + 86400,
      refresh_token: token,
      user: { id: user.id, email: user.email, aud:'authenticated', role:'authenticated',
              app_metadata:{}, user_metadata:{}, created_at:new Date().toISOString() }
    });
  }

  if (p === 'signup'){
    const email = body?.email;
    let out = await pool.query('SELECT id, email FROM auth.users WHERE email = $1', [email]);
    if (!out.rows.length)
      out = await pool.query('INSERT INTO auth.users(email, raw_user_meta_data) VALUES ($1,$2) RETURNING id, email',
                             [email, JSON.stringify(body?.data || {})]);
    const user = out.rows[0];
    const token = crypto.randomUUID();
    sessions.set(token, user.id);
    return json(res, 200, {
      access_token: token, token_type:'bearer', expires_in: 86400, refresh_token: token,
      user: { id:user.id, email:user.email, aud:'authenticated', role:'authenticated',
              app_metadata:{}, user_metadata: body?.data || {}, created_at:new Date().toISOString() }
    });
  }

  if (p === 'logout'){ res.writeHead(204); return res.end(); }
  if (p === 'user'){
    const uid = sessions.get(bearer(req));
    if (!uid) return json(res, 401, { message:'not signed in' });
    const out = await pool.query('SELECT id, email FROM auth.users WHERE id=$1', [uid]);
    return json(res, 200, { id: out.rows[0].id, email: out.rows[0].email, aud:'authenticated', role:'authenticated', user_metadata:{}, app_metadata:{} });
  }
  return json(res, 404, { message:'not implemented in the dev server: ' + p });
}

const bearer = (req) => String(req.headers['authorization'] || '').replace(/^Bearer\s+/i, '');

/** supabase-js .single()/.maybeSingle() ask for one object, not an array. */
function wantsObject(req){
  return String(req.headers['accept'] || '').includes('application/vnd.pgrst.object+json');
}
function sendRows(req, res, rows, code = 200){
  if (wantsObject(req)){
    if (!rows.length)
      return json(res, 406, { code:'PGRST116', message:'JSON object requested, multiple (or no) rows returned',
                              details:'Results contain 0 rows', hint:null });
    return json(res, code, rows[0]);
  }
  return json(res, code, rows);
}

/* ---------------------------------------------------------------------
   A small Supabase Storage stand-in. Files live on local disk; the
   storage.objects row is written AS THE SIGNED-IN USER, so the storage
   policies in the migrations decide — exactly as on Supabase — who may
   upload, open and remove. A missing bucket answers "Bucket not found",
   and the bucket's own size and file-type limits are enforced, because
   those are the failures a person meets in real use.
   --------------------------------------------------------------------- */
const STORE = path.join(process.env.TMPDIR || '/tmp', `bms-devstorage-${PORT}`);
const signed = new Map();   // token -> { bucket, name }
const storageErr = (res, http, status, error, message) => json(res, http, { statusCode: String(status), error, message });
const blobPath = (bucket, name) => path.join(STORE, bucket, crypto.createHash('sha1').update(name).digest('hex'));

function multipartFile(raw, contentType){
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || '');
  if (!m) return { data: raw, type: contentType || 'application/octet-stream' };
  const boundary = Buffer.from('--' + (m[1] || m[2]));
  let pos = raw.indexOf(boundary);
  while (pos !== -1){
    const next = raw.indexOf(boundary, pos + boundary.length);
    if (next === -1) break;
    const part = raw.subarray(pos + boundary.length + 2, next - 2);
    const sep = part.indexOf('\r\n\r\n');
    const head = part.subarray(0, sep).toString('utf8');
    if (/filename=/i.test(head) || /name=""/.test(head)){
      const type = (/content-type:\s*([^\r\n]+)/i.exec(head) || [])[1] || 'application/octet-stream';
      return { data: part.subarray(sep + 4), type: type.trim() };
    }
    pos = next;
  }
  return { data: Buffer.alloc(0), type: 'application/octet-stream' };
}

async function handleStorage(req, res, url, userId, body, raw){
  const rest = decodeURIComponent(url.pathname.replace(/^\/storage\/v1\/?/, ''));

  // A signed link, opened from anywhere: the token is the permission.
  if (req.method === 'GET' && rest.startsWith('object/sign/')){
    const t = signed.get(url.searchParams.get('token') || '');
    if (!t) return storageErr(res, 400, 400, 'InvalidSignature', 'The signature is invalid or has expired');
    const meta = await pool.query('SELECT metadata FROM storage.objects WHERE bucket_id=$1 AND name=$2', [t.bucket, t.name]);
    const data = await fs.readFile(blobPath(t.bucket, t.name));
    res.writeHead(200, { 'Content-Type': meta.rows[0]?.metadata?.mimetype || 'application/octet-stream', 'Cache-Control':'no-store' });
    return res.end(data);
  }

  if (req.method === 'POST' && rest.startsWith('object/sign/')){
    const [bucket, ...nameParts] = rest.slice('object/sign/'.length).split('/');
    const name = nameParts.join('/');
    const seen = await asUser(userId, c => c.query('SELECT 1 FROM storage.objects WHERE bucket_id=$1 AND name=$2', [bucket, name]));
    if (!seen.rowCount) return storageErr(res, 400, 404, 'not_found', 'Object not found');
    const token = crypto.randomUUID();
    signed.set(token, { bucket, name });
    return json(res, 200, { signedURL: `/object/sign/${bucket}/${name}?token=${token}` });
  }

  if (rest.startsWith('object/')){
    const [bucket, ...nameParts] = rest.slice('object/'.length).split('/');
    const name = nameParts.join('/');

    if (req.method === 'DELETE' && !name){
      const prefixes = (body && body.prefixes) || [];
      const out = await asUser(userId, c => c.query(
        'DELETE FROM storage.objects WHERE bucket_id=$1 AND name = ANY($2::text[]) RETURNING name', [bucket, prefixes]));
      return json(res, 200, out.rows);
    }

    if (req.method === 'GET'){
      const seen = await asUser(userId, c => c.query('SELECT metadata FROM storage.objects WHERE bucket_id=$1 AND name=$2', [bucket, name]));
      if (!seen.rowCount) return storageErr(res, 400, 404, 'not_found', 'Object not found');
      const data = await fs.readFile(blobPath(bucket, name));
      res.writeHead(200, { 'Content-Type': seen.rows[0].metadata?.mimetype || 'application/octet-stream', 'Cache-Control':'no-store' });
      return res.end(data);
    }

    if (req.method === 'POST' || req.method === 'PUT'){
      const b = await pool.query('SELECT * FROM storage.buckets WHERE id=$1', [bucket]).catch(() => ({ rows: [] }));
      if (!b.rows.length) return storageErr(res, 400, 404, 'Bucket not found', 'Bucket not found');
      const file = multipartFile(raw || Buffer.alloc(0), req.headers['content-type']);
      const bk = b.rows[0];
      if (bk.file_size_limit && file.data.length > Number(bk.file_size_limit))
        return storageErr(res, 400, 413, 'Payload too large', 'The object exceeded the maximum allowed size');
      if (bk.allowed_mime_types && bk.allowed_mime_types.length && !bk.allowed_mime_types.includes(file.type))
        return storageErr(res, 400, 415, 'invalid_mime_type', `mime type ${file.type} is not supported`);
      try {
        await asUser(userId, c => c.query(
          'INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES ($1,$2,$3,$4)',
          [bucket, name, userId, JSON.stringify({ mimetype: file.type, size: file.data.length })]));
      } catch (e){
        if (/duplicate key/i.test(e.message)) return storageErr(res, 400, 409, 'Duplicate', 'The resource already exists');
        return storageErr(res, 400, 403, 'Unauthorized', 'new row violates row-level security policy');
      }
      await fs.mkdir(path.join(STORE, bucket), { recursive: true });
      await fs.writeFile(blobPath(bucket, name), file.data);
      return json(res, 200, { Key: `${bucket}/${name}`, Id: crypto.randomUUID() });
    }
  }
  return storageErr(res, 400, 400, 'not_implemented', 'Not emulated by the dev server: ' + rest);
}

/* --------------------------------------------------------------------- */
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (req.method === 'OPTIONS'){
    res.writeHead(204, { 'Access-Control-Allow-Origin':'*', 'Access-Control-Allow-Headers':'*',
                         'Access-Control-Allow-Methods':'GET,POST,PATCH,PUT,DELETE,HEAD,OPTIONS' });
    return res.end();
  }

  let body = null, raw = null;
  if (['POST','PATCH','PUT','DELETE'].includes(req.method)){
    const chunks = [];
    for await (const c of req) chunks.push(c);
    raw = Buffer.concat(chunks);
    const text = /multipart\//i.test(req.headers['content-type'] || '') ? '' : raw.toString('utf8');
    try { body = text ? JSON.parse(text) : null; } catch { body = null; }
  }

  try {
    if (url.pathname.startsWith('/auth/v1')) return await handleAuth(req, res, url, body);
    if (url.pathname.startsWith('/rest/v1'))
      return await handleRest(req, res, url, sessions.get(bearer(req)) || null, body);
    if (url.pathname.startsWith('/storage/v1'))
      return await handleStorage(req, res, url, sessions.get(bearer(req)) || null, body, raw);

    // The dev server hands the app its own address, so the real config.js
    // is never served and the tests can never reach the live project.
    if (url.pathname === '/config.js'){
      res.writeHead(200, { 'Content-Type':'text/javascript; charset=utf-8', 'Cache-Control':'no-store' });
      return res.end(`window.BMS_CONFIG = { SUPABASE_URL: 'http://localhost:${PORT}', SUPABASE_ANON_KEY: 'dev-anon-key' };\n`);
    }

    // static files
    let file = url.pathname === '/' ? '/index.html' : url.pathname;
    const full = path.join(ROOT, path.normalize(file).replace(/^(\.\.[/\\])+/, ''));
    if (!full.startsWith(ROOT)) { res.writeHead(403); return res.end(); }
    const data = await fs.readFile(full);
    res.writeHead(200, { 'Content-Type': MIME[path.extname(full)] || 'application/octet-stream',
                         'Cache-Control':'no-store', ...cspHeaders() });
    return res.end(data);
  } catch (e){
    if (e.code === 'ENOENT'){ res.writeHead(404); return res.end('Not found'); }
    const msg = e.message || String(e);
    const code = /permission denied|row-level security/i.test(msg) ? 403 : 400;
    return json(res, code, { message: msg, code: e.code, details: e.detail || null, hint: e.hint || null });
  }
});

/* The production Content-Security-Policy, minus the parts that name the
   real Supabase project. Set CSP=1 to serve it, so the browser suite can
   prove the policy does not break the app — a CSP that only gets tested
   in production is a CSP that gets discovered by a user.

   connect-src is 'self' here because the dev server IS the API. Every
   other directive is character-for-character what _headers ships. */
function cspHeaders(){
  if (!process.env.CSP) return {};
  return {
    'Content-Security-Policy': [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob:",
      "font-src 'self'",
      "connect-src 'self'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "object-src 'none'"
    ].join('; '),
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer'
  };
}

server.listen(PORT, () => {
  console.log(`Building Portal dev server → http://localhost:${PORT}`);
  console.log(`Database: ${process.env.PGDATABASE || 'bms_test'} on ${process.env.PGHOST || '127.0.0.1'}:${process.env.PGPORT || 5433}`);
});
