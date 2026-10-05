-- =====================================================================
-- LOCAL TEST SHIM — NEVER RUN THIS ON SUPABASE.
-- Recreates just enough of Supabase (auth schema, roles, auth.uid())
-- so the real migrations in ../ can be executed and tested on a plain
-- PostgreSQL instance.
--
-- =====================================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticator') THEN
    CREATE ROLE authenticator LOGIN NOINHERIT;
  END IF;
END $$;

GRANT anon, authenticated, service_role TO authenticator;

CREATE SCHEMA IF NOT EXISTS auth;

-- A stand-in for Supabase's own auth.users. The columns below are the
-- ones anything in this repository reads. They are here so that a script
-- written against real Supabase — DIAGNOSE_LOGIN.sql especially — can be
-- run and proved locally instead of first being tried on a live project.
CREATE TABLE IF NOT EXISTS auth.users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email              text UNIQUE,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now()
);

-- Added separately so an existing test database picks them up too.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS email_confirmed_at timestamptz;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS last_sign_in_at    timestamptz;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS deleted_at         timestamptz;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS banned_until       timestamptz;

-- Supabase exposes the signed-in user id through this function.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claim.role', true), ''), 'anon')
$$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT SELECT ON auth.users TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- pg_safeupdate, because Supabase runs it and a plain PostgreSQL does not.
--
-- Supabase loads this library for the API role. It rejects any UPDATE or
-- DELETE with no WHERE clause — including inside SECURITY DEFINER
-- functions, since it is a session setting and not a privilege.
--
-- Leaving it out of the local database is not a neutral simplification:
-- the system reset passed every test here and then failed on the live
-- site with "DELETE requires a WHERE clause", because a bare DELETE is
-- perfectly legal on the database I was testing against and illegal on
-- the one that matters. A test environment that is more permissive than
-- production cannot find that class of bug, so this closes the gap.
--
-- If the library is not installed the server logs a warning and carries
-- on, so this file still works on a machine without it — but then the
-- gap is open again, and scripts/test.sh says so.
-- ---------------------------------------------------------------------
DO $safeupdate$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET session_preload_libraries = %L',
                 current_database(), 'safeupdate');
  EXECUTE format('ALTER DATABASE %I SET safeupdate.enabled = %L',
                 current_database(), 'on');
END $safeupdate$;

-- ---------------------------------------------------------------------
-- Supabase Storage, as far as the database sees it: the buckets table
-- and the objects table that storage policies are written against. With
-- these, the bucket set-up and every storage policy in the migrations
-- run here exactly as they will on Supabase, and the tests can try an
-- upload as each role and watch the policy allow or refuse it.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 text PRIMARY KEY,
  name               text NOT NULL,
  owner              uuid,
  public             boolean DEFAULT false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now()
);
CREATE TABLE IF NOT EXISTS storage.objects (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id  text REFERENCES storage.buckets(id),
  name       text,
  owner      uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  metadata   jsonb,
  UNIQUE (bucket_id, name)
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
GRANT SELECT ON storage.buckets TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated;
