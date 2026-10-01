-- =====================================================================
-- 080_roles.sql — roles you can create yourself, and the guards that
-- have to exist before that is safe.
--
-- THE HOLE THIS CLOSES
-- --------------------
-- Before this file, an Admin — not a Super Admin, just the ADMIN role —
-- could do exactly this:
--
--     INSERT INTO bms.roles(code, name, is_superuser) VALUES ('X','X',true);
--     INSERT INTO bms.user_roles(user_id, role_id) VALUES (auth.uid(), <X>);
--
-- and was a Super Admin, with the system reset now available to them.
-- The RLS policy asked only for users.add, which ADMIN holds. I found it
-- by trying it, not by reading the policy, and the reason it had never
-- mattered is that nothing in the interface offered to create a role. The
-- moment a button does, the hole is one click wide, so it is closed here
-- rather than alongside.
--
-- THE RULE
-- --------
-- You cannot grant what you do not hold. A superuser role may only be
-- created or handed out by someone who is already a superuser; a role's
-- approval ceiling may not exceed the ceiling of the person setting it;
-- and a permission may only be ticked onto a role by someone who holds
-- that permission themselves. A Super Admin is exempt from all three,
-- because they already hold everything — that is what the role means.
--
-- The seven roles that ship are marked is_system and are protected from
-- renaming, recoding and deletion. They are what the documentation
-- describes and what a new administrator expects to find.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- The effective approval ceiling of the person making the request.
-- NULL means unlimited. Used to stop a role being given a bigger ceiling
-- than the person creating it has.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.my_approve_ceiling()
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT CASE
    WHEN bms.is_superuser() THEN NULL
    WHEN EXISTS (SELECT 1 FROM bms.user_roles ur JOIN bms.roles r ON r.id = ur.role_id
                  WHERE ur.user_id = auth.uid() AND r.approve_limit IS NULL) THEN NULL
    ELSE (SELECT MAX(r.approve_limit) FROM bms.user_roles ur
            JOIN bms.roles r ON r.id = ur.role_id
           WHERE ur.user_id = auth.uid())
  END;
$$;

-- ---------------------------------------------------------------------
-- Roles: what may be created, changed and removed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.guard_role() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_ceiling numeric;
BEGIN
  -- Server-side work (migrations, seeding, the bootstrap script) runs with
  -- no session user. Those are not people escalating themselves.
  IF auth.uid() IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.is_system THEN
      RAISE EXCEPTION 'The % role is part of the system and cannot be deleted', OLD.name
        USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM bms.user_roles WHERE role_id = OLD.id) THEN
      RAISE EXCEPTION 'Someone still has the % role. Move them off it first.', OLD.name
        USING ERRCODE = '23503';
    END IF;
    RETURN OLD;
  END IF;

  -- The escalation. Only a superuser may make a superuser.
  IF NEW.is_superuser
     AND (TG_OP = 'INSERT' OR NOT COALESCE(OLD.is_superuser, false))
     AND NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can create a role with full access'
      USING ERRCODE = '42501';
  END IF;

  -- ...and only a superuser may quietly mark a role as a system one, which
  -- would otherwise be a way to make a role undeletable.
  IF NEW.is_system AND (TG_OP = 'INSERT' OR NOT COALESCE(OLD.is_system, false))
     AND NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can mark a role as a system role'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.is_system THEN
    IF NEW.code IS DISTINCT FROM OLD.code THEN
      RAISE EXCEPTION 'The code of a system role cannot be changed' USING ERRCODE = '42501';
    END IF;
    IF NOT NEW.is_system THEN
      RAISE EXCEPTION 'A system role cannot be turned into an ordinary one' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- You cannot hand out a bigger cheque than you can sign.
  IF NOT bms.is_superuser() THEN
    v_ceiling := bms.my_approve_ceiling();
    IF v_ceiling IS NOT NULL
       AND (NEW.approve_limit IS NULL OR NEW.approve_limit > v_ceiling)
       AND NEW.approve_limit IS DISTINCT FROM (CASE WHEN TG_OP='UPDATE' THEN OLD.approve_limit END) THEN
      RAISE EXCEPTION 'You cannot give a role a higher approval limit than your own (%)', v_ceiling
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_role_guard ON bms.roles;
CREATE TRIGGER trg_role_guard BEFORE INSERT OR UPDATE OR DELETE ON bms.roles
  FOR EACH ROW EXECUTE FUNCTION bms.guard_role();

-- ---------------------------------------------------------------------
-- Handing a role to a person. Same rule from the other direction: even a
-- superuser role that already exists may only be given out by a superuser.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.guard_user_role() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM bms.roles WHERE id = NEW.role_id AND is_superuser)
     AND NOT bms.is_superuser() THEN
    RAISE EXCEPTION 'Only a Super Admin can give someone full access'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_user_role_guard ON bms.user_roles;
CREATE TRIGGER trg_user_role_guard BEFORE INSERT OR UPDATE ON bms.user_roles
  FOR EACH ROW EXECUTE FUNCTION bms.guard_user_role();

-- ---------------------------------------------------------------------
-- Ticking a permission onto a role. You may only grant what you hold.
-- Without this, someone with users.manage could tick finance.approve onto
-- their own role and walk around the approval limits entirely.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.guard_role_permission() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_mod text; v_act text;
BEGIN
  IF auth.uid() IS NULL OR bms.is_superuser() THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;                      -- taking access away is always allowed
  END IF;
  SELECT module_code, action INTO v_mod, v_act
    FROM bms.permissions WHERE id = NEW.permission_id;
  IF NOT bms.has_perm(v_mod, v_act) THEN
    RAISE EXCEPTION 'You cannot grant "% %" because you do not have it yourself', v_mod, v_act
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_role_perm_guard ON bms.role_permissions;
CREATE TRIGGER trg_role_perm_guard BEFORE INSERT OR UPDATE ON bms.role_permissions
  FOR EACH ROW EXECUTE FUNCTION bms.guard_role_permission();

-- ---------------------------------------------------------------------
-- Creating a role, with its permissions copied from an existing one.
--
-- A new role starting from nothing is 190 ticks of work and easy to get
-- wrong in the dangerous direction — forgetting to remove something.
-- Starting from "like the Caretaker, but only the generator" is how
-- people actually think about it, so that is what this takes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.create_role(
    p_name text,
    p_description text DEFAULT NULL,
    p_copy_from uuid DEFAULT NULL,
    p_approve_limit bms.money_amount DEFAULT 0,
    p_auto_post_limit bms.money_amount DEFAULT 0)
RETURNS bms.roles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.roles; v_code text; v_n int := 0;
BEGIN
  PERFORM bms.assert_perm('users','manage');

  IF COALESCE(btrim(p_name),'') = '' THEN
    RAISE EXCEPTION 'A role needs a name';
  END IF;

  -- A readable, stable code derived from the name: "Generator Operator"
  -- becomes GENERATOR_OPERATOR, with a numeric suffix only if it collides.
  v_code := upper(regexp_replace(btrim(p_name), '[^a-zA-Z0-9]+', '_', 'g'));
  v_code := btrim(v_code, '_');
  IF v_code = '' THEN v_code := 'ROLE'; END IF;
  v_code := left(v_code, 40);
  WHILE EXISTS (SELECT 1 FROM bms.roles WHERE code = v_code) LOOP
    v_n := v_n + 1;
    v_code := left(upper(regexp_replace(btrim(p_name), '[^a-zA-Z0-9]+', '_', 'g')), 36) || '_' || v_n;
    IF v_n > 50 THEN RAISE EXCEPTION 'Could not find a free code for "%"', p_name; END IF;
  END LOOP;

  INSERT INTO bms.roles (code, name, description, is_system, is_superuser,
                         approve_limit, auto_post_limit, sort_order)
  VALUES (v_code, btrim(p_name), NULLIF(btrim(COALESCE(p_description,'')),''),
          false, false, p_approve_limit, p_auto_post_limit,
          (SELECT COALESCE(MAX(sort_order),100) + 10 FROM bms.roles))
  RETURNING * INTO r;

  IF p_copy_from IS NOT NULL THEN
    -- A superuser role holds no permission rows — it is a flag, not a list —
    -- so copying from one would silently produce an empty role. Say so.
    IF EXISTS (SELECT 1 FROM bms.roles WHERE id = p_copy_from AND is_superuser) THEN
      RAISE EXCEPTION 'Super Admin has no permission list to copy. Start from Admin instead.';
    END IF;
    INSERT INTO bms.role_permissions (role_id, permission_id)
    SELECT r.id, rp.permission_id FROM bms.role_permissions rp
     WHERE rp.role_id = p_copy_from
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- Removing one. The guard above does the refusing; this exists so the
-- interface has something to call and gets a clear error back.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.delete_role(p_role uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('users','manage');
  DELETE FROM bms.roles WHERE id = p_role;
  IF NOT FOUND THEN RAISE EXCEPTION 'That role no longer exists'; END IF;
END $$;

REVOKE ALL ON FUNCTION bms.create_role(text, text, uuid, bms.money_amount, bms.money_amount) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.delete_role(uuid)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.my_approve_ceiling()   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.create_role(text, text, uuid, bms.money_amount, bms.money_amount) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.delete_role(uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION bms.my_approve_ceiling() TO authenticated;

-- Note: no DELETE privilege is granted to `authenticated`, deliberately.
-- A direct DELETE is refused by the grant before RLS or the guard above
-- is consulted. Removal goes through delete_role() instead, which runs
-- as the owner, fires the guard, and returns a sentence explaining why
-- when it refuses. Two layers, and the outer one needs no thought.

-- ---------------------------------------------------------------------
-- Categories: the same table the ledger uses, now editable.
--
-- Deleting one is not offered. A category that has been used is attached
-- to real transactions and removing it would either orphan them or
-- silently rewrite history; a category that has not been used is harmless
-- to leave. Hiding is the honest operation, so is_active is what the
-- screen changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.category_usage(p_category uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT (SELECT count(*) FROM bms.transactions WHERE category_id = p_category)
       + (SELECT count(*) FROM bms.budgets      WHERE category_id = p_category);
$$;
REVOKE ALL ON FUNCTION bms.category_usage(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.category_usage(uuid) TO authenticated;
