-- =====================================================================
-- 001_core.sql — schema, shared types, identity, roles, permissions,
--                building configuration.
--
-- SAFETY: every object in this file is created inside the `bms` schema.
-- Nothing here alters, drops or reads any LPG Ledger table.
-- =====================================================================

SET search_path = bms, public;

CREATE SCHEMA IF NOT EXISTS bms;

-- Money is ALWAYS this type. Never float, never numeric without a scale.
DO $$ BEGIN
  CREATE DOMAIN bms.money_amount AS numeric(14,2);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Small helper used by every table for the updated_at column.
CREATE OR REPLACE FUNCTION bms.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- MODULES — the registry that drives navigation and the permission grid.
-- Adding module 22 is one INSERT, not a restructure.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.modules (
  code        text PRIMARY KEY,
  name        text NOT NULL,
  icon        text,
  sort_order  int  NOT NULL DEFAULT 100,
  phase       int  NOT NULL DEFAULT 1,
  is_enabled  boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- PERMISSIONS — one row per module x action.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.permissions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  module_code  text NOT NULL REFERENCES bms.modules(code) ON DELETE CASCADE,
  action       text NOT NULL,
  description  text,
  UNIQUE (module_code, action),
  CONSTRAINT permissions_action_ck CHECK (action IN
    ('view','add','edit','approve','export','cancel','waive','view_sensitive','manage','close'))
);

-- ---------------------------------------------------------------------
-- ROLES and their permission bundles.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  description text,
  is_system   boolean NOT NULL DEFAULT false,   -- system roles cannot be deleted
  is_superuser boolean NOT NULL DEFAULT false,  -- implies every permission
  -- Money limits. NULL means unlimited (only sensible for a superuser role).
  approve_limit   bms.money_amount,   -- largest expense this role may approve
  auto_post_limit bms.money_amount,   -- posts straight through up to here; NULL = unlimited
  sort_order  int NOT NULL DEFAULT 100,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bms.role_permissions (
  role_id       uuid NOT NULL REFERENCES bms.roles(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES bms.permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

-- ---------------------------------------------------------------------
-- USER PROFILES — building-side profile, deliberately SEPARATE from the
-- LPG Ledger's public.profiles so that table is never altered.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.user_profiles (
  user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name   text NOT NULL,
  email       text,
  phone       text,
  is_active   boolean NOT NULL DEFAULT false,   -- new sign-ups wait for an admin
  approval_limit bms.money_amount,              -- NULL = use the role default
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bms.user_roles (
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role_id     uuid NOT NULL REFERENCES bms.roles(id) ON DELETE CASCADE,
  assigned_by uuid REFERENCES auth.users(id),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role_id)
);
CREATE INDEX IF NOT EXISTS user_roles_user_idx ON bms.user_roles(user_id);

-- ---------------------------------------------------------------------
-- BUILDING SETTINGS — the singleton. Nothing from the spec is hard-coded
-- in application code; it all lives here.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bms.building_settings (
  id                        boolean PRIMARY KEY DEFAULT true CHECK (id),
  building_name             text NOT NULL DEFAULT 'Our Building',
  address                   text,
  floor_count               int  NOT NULL DEFAULT 9  CHECK (floor_count > 0),
  currency_code             text NOT NULL DEFAULT 'BDT',
  currency_symbol           text NOT NULL DEFAULT 'Tk',
  locale                    text NOT NULL DEFAULT 'en-BD',
  timezone                  text NOT NULL DEFAULT 'Asia/Dhaka',
  fiscal_year_start_month   int  NOT NULL DEFAULT 1 CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  default_service_charge    bms.money_amount NOT NULL DEFAULT 5000.00 CHECK (default_service_charge >= 0),
  charge_due_day            int  NOT NULL DEFAULT 10 CHECK (charge_due_day BETWEEN 1 AND 28),
  late_fee_enabled          boolean NOT NULL DEFAULT false,
  late_fee_type             text NOT NULL DEFAULT 'FIXED' CHECK (late_fee_type IN ('FIXED','PERCENT')),
  late_fee_value            bms.money_amount NOT NULL DEFAULT 0 CHECK (late_fee_value >= 0),
  late_fee_grace_days       int  NOT NULL DEFAULT 5 CHECK (late_fee_grace_days >= 0),
  allow_self_approval       boolean NOT NULL DEFAULT false,
  inspection_warn_days      int  NOT NULL DEFAULT 30 CHECK (inspection_warn_days >= 0),
  service_warn_days         int  NOT NULL DEFAULT 15 CHECK (service_warn_days >= 0),
  fd_maturity_warn_days     int  NOT NULL DEFAULT 30 CHECK (fd_maturity_warn_days >= 0),
  receipt_prefix            text NOT NULL DEFAULT 'RCT',
  -- Where an entry with no account chosen lands (the caretaker's petty cash).
  default_cash_account_id   uuid,
  logo_path                 text,
  updated_at                timestamptz NOT NULL DEFAULT now(),
  updated_by                uuid REFERENCES auth.users(id)
);

-- ---------------------------------------------------------------------
-- has_perm() — the single gate every RLS policy calls.
--
-- SECURITY DEFINER so that a user whose SELECT on bms.user_roles is
-- itself restricted can still have their own permissions evaluated.
-- STABLE so Postgres evaluates it once per statement, not per row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.has_perm(p_module text, p_action text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1
    FROM bms.user_roles ur
    JOIN bms.roles r            ON r.id = ur.role_id
    JOIN bms.user_profiles up   ON up.user_id = ur.user_id
    LEFT JOIN bms.role_permissions rp ON rp.role_id = r.id
    LEFT JOIN bms.permissions p       ON p.id = rp.permission_id
    WHERE ur.user_id = auth.uid()
      AND up.is_active
      AND ( r.is_superuser
            OR (p.module_code = p_module AND p.action = p_action) )
  )
$$;

-- Convenience: is the caller an active user of the building system at all?
CREATE OR REPLACE FUNCTION bms.is_active_user()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM bms.user_profiles up
    WHERE up.user_id = auth.uid() AND up.is_active
  )
$$;

CREATE OR REPLACE FUNCTION bms.is_superuser()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM bms.user_roles ur
    JOIN bms.roles r          ON r.id = ur.role_id
    JOIN bms.user_profiles up ON up.user_id = ur.user_id
    WHERE ur.user_id = auth.uid() AND up.is_active AND r.is_superuser
  )
$$;

-- How much may a user approve? NULL means unlimited.
-- A per-user override on user_profiles wins over the role limits;
-- otherwise it is the highest limit across the user's roles.
CREATE OR REPLACE FUNCTION bms.approval_limit(p_user uuid DEFAULT NULL)
RETURNS bms.money_amount
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_user uuid := COALESCE(p_user, auth.uid());
        v_override bms.money_amount;
        v_unlimited boolean;
        v_limit bms.money_amount;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
     WHERE ur.user_id = v_user AND (r.is_superuser OR r.approve_limit IS NULL)
  ) INTO v_unlimited;
  IF v_unlimited THEN RETURN NULL; END IF;

  SELECT up.approval_limit INTO v_override
    FROM bms.user_profiles up WHERE up.user_id = v_user;
  IF v_override IS NOT NULL THEN RETURN v_override; END IF;

  SELECT MAX(r.approve_limit) INTO v_limit
    FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
   WHERE ur.user_id = v_user;
  RETURN COALESCE(v_limit, 0);
END $$;

-- Below this amount a user's own entries post straight to the ledger.
CREATE OR REPLACE FUNCTION bms.auto_post_limit(p_user uuid DEFAULT NULL)
RETURNS bms.money_amount
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_user uuid := COALESCE(p_user, auth.uid());
        v_unlimited boolean; v_limit bms.money_amount;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
     WHERE ur.user_id = v_user AND (r.is_superuser OR r.auto_post_limit IS NULL)
  ) INTO v_unlimited;
  IF v_unlimited THEN RETURN NULL; END IF;

  SELECT MAX(r.auto_post_limit) INTO v_limit
    FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
   WHERE ur.user_id = v_user;
  RETURN COALESCE(v_limit, 0);
END $$;

-- The whole permission list for the signed-in user, for the UI to cache.
CREATE OR REPLACE FUNCTION bms.my_permissions()
RETURNS TABLE (module_code text, action text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT DISTINCT p.module_code, p.action
  FROM bms.user_roles ur
  JOIN bms.roles r                  ON r.id = ur.role_id
  JOIN bms.user_profiles up         ON up.user_id = ur.user_id
  JOIN bms.role_permissions rp      ON rp.role_id = r.id
  JOIN bms.permissions p            ON p.id = rp.permission_id
  WHERE ur.user_id = auth.uid() AND up.is_active AND NOT r.is_superuser
  UNION
  SELECT p.module_code, p.action
  FROM bms.permissions p
  WHERE bms.is_superuser()
$$;

DROP TRIGGER IF EXISTS trg_modules_updated       ON bms.modules;
DROP TRIGGER IF EXISTS trg_roles_updated         ON bms.roles;
DROP TRIGGER IF EXISTS trg_user_profiles_updated ON bms.user_profiles;
CREATE TRIGGER trg_modules_updated       BEFORE UPDATE ON bms.modules       FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_roles_updated         BEFORE UPDATE ON bms.roles         FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
CREATE TRIGGER trg_user_profiles_updated BEFORE UPDATE ON bms.user_profiles FOR EACH ROW EXECUTE FUNCTION bms.set_updated_at();
