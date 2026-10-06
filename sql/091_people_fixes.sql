-- =====================================================================
-- 091_people_fixes.sql — putting right who owns and who pays, when the
-- flats were first entered one at a time.
--
-- Entering 36 flats one by one leaves three kinds of mistake behind, and
-- each one quietly breaks the owner totals and the combined receipt:
--
--   1. THE SAME PERSON TWICE. "Nurul Huda" typed as a new person on A9
--      and again on B9 is two people to the database, so his two flats
--      never add up. merge_people() makes them one: every flat, every
--      combined receipt moves to the person kept, missing contact details
--      are filled in from the other, and the other is retired (never
--      deleted — the audit log says who was merged into whom).
--
--   2. A PERSON ON THE WRONG FLAT. A tenant added to A9 who really rents
--      B9. void_occupancy() takes the entry off as "added by mistake":
--      it disappears from the flat and from its history list, the bill
--      goes back to whoever else is there, and the row itself is kept
--      with the reason.
--
--   3. THE WRONG PERSON NAMED. correct_occupant() replaces the person on
--      an entry without inventing a change of ownership: no "past owner"
--      for a typing mistake.
--
-- possible_duplicate_people() finds the likely doubles (same name, or the
-- same mobile number) so the screens can offer the merge.
-- =====================================================================

ALTER TABLE bms.flat_occupancy
  ADD COLUMN IF NOT EXISTS voided_at   timestamptz,
  ADD COLUMN IF NOT EXISTS voided_by   uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS void_reason text;

ALTER TABLE bms.owners
  ADD COLUMN IF NOT EXISTS merged_into uuid REFERENCES bms.owners(id);

-- ---------------------------------------------------------------------
-- After an entry is taken off, someone still current on the flat must
-- receive the bill: the owner first, otherwise the tenant.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms._rebill_flat(p_flat uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM bms.flat_occupancy WHERE flat_id = p_flat AND to_date IS NULL AND is_billed) THEN
    UPDATE bms.flat_occupancy SET is_billed = true
     WHERE id = (SELECT id FROM bms.flat_occupancy
                  WHERE flat_id = p_flat AND to_date IS NULL
                  ORDER BY (relation_type = 'OWNER') DESC, from_date DESC LIMIT 1);
  END IF;
END $$;
REVOKE ALL ON FUNCTION bms._rebill_flat(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Added by mistake.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.void_occupancy(p_occupancy uuid, p_reason text)
RETURNS bms.flat_occupancy
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.flat_occupancy;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why (for example: added to the wrong flat)'; END IF;
  SELECT * INTO r FROM bms.flat_occupancy WHERE id = p_occupancy FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry no longer exists'; END IF;
  IF r.voided_at IS NOT NULL THEN RAISE EXCEPTION 'That entry has already been removed'; END IF;
  IF r.to_date IS NOT NULL THEN RAISE EXCEPTION 'Only a current owner or tenant can be removed as a mistake'; END IF;

  UPDATE bms.flat_occupancy
     SET to_date = from_date, is_billed = false,
         voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
   WHERE id = r.id
  RETURNING * INTO r;
  PERFORM bms._rebill_flat(r.flat_id);
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- 3. The wrong person named on an entry.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.correct_occupant(
    p_occupancy uuid, p_person uuid DEFAULT NULL, p_name text DEFAULT NULL,
    p_mobile text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS bms.flat_occupancy
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE r bms.flat_occupancy; v_person uuid;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  SELECT * INTO r FROM bms.flat_occupancy WHERE id = p_occupancy FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry no longer exists'; END IF;
  IF r.voided_at IS NOT NULL OR r.to_date IS NOT NULL THEN
    RAISE EXCEPTION 'Only a current owner or tenant can be corrected';
  END IF;
  v_person := bms._person_for(p_person, p_name, p_mobile, NULL, NULL);
  IF v_person = r.owner_id THEN RETURN r; END IF;
  IF EXISTS (SELECT 1 FROM bms.flat_occupancy
              WHERE flat_id = r.flat_id AND to_date IS NULL AND id <> r.id AND owner_id = v_person) THEN
    RAISE EXCEPTION 'That person is already the % of this flat',
      (SELECT lower(relation_type) FROM bms.flat_occupancy
        WHERE flat_id = r.flat_id AND to_date IS NULL AND id <> r.id AND owner_id = v_person LIMIT 1);
  END IF;
  UPDATE bms.flat_occupancy
     SET owner_id = v_person,
         notes = trim(BOTH ' ' FROM COALESCE(notes, '') || ' Corrected: ' ||
                 COALESCE(NULLIF(btrim(p_reason), ''), 'wrong person entered'))
   WHERE id = r.id
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- 1. The same person entered twice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.merge_people(p_keep uuid, p_drop uuid)
RETURNS bms.owners
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE k bms.owners; d bms.owners; v_flats int; v_groups int; v_clash text;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  IF p_keep IS NULL OR p_drop IS NULL OR p_keep = p_drop THEN
    RAISE EXCEPTION 'Choose two different people';
  END IF;
  SELECT * INTO k FROM bms.owners WHERE id = p_keep FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'The person to keep no longer exists'; END IF;
  SELECT * INTO d FROM bms.owners WHERE id = p_drop FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'The person to merge no longer exists'; END IF;
  IF d.merged_into IS NOT NULL THEN RAISE EXCEPTION '% has already been merged', d.name; END IF;

  -- One person cannot be both the owner and the tenant of the same flat.
  SELECT f.flat_number INTO v_clash
    FROM bms.flat_occupancy a
    JOIN bms.flat_occupancy b ON b.flat_id = a.flat_id AND b.to_date IS NULL AND b.owner_id = p_drop
    JOIN bms.flats f ON f.id = a.flat_id
   WHERE a.owner_id = p_keep AND a.to_date IS NULL AND a.relation_type <> b.relation_type
   LIMIT 1;
  IF v_clash IS NOT NULL THEN
    RAISE EXCEPTION 'They cannot be one person: one is the owner and the other the tenant of flat %. Fix that flat first.', v_clash;
  END IF;

  -- The same flat, same role, both current: keep the earlier entry.
  UPDATE bms.flat_occupancy b
     SET to_date = b.from_date, is_billed = false,
         voided_at = now(), voided_by = auth.uid(), void_reason = 'Duplicate of ' || k.name || ' (people merged)'
   WHERE b.owner_id = p_drop AND b.to_date IS NULL
     AND EXISTS (SELECT 1 FROM bms.flat_occupancy a
                  WHERE a.owner_id = p_keep AND a.flat_id = b.flat_id
                    AND a.relation_type = b.relation_type AND a.to_date IS NULL);

  UPDATE bms.flat_occupancy SET owner_id = p_keep WHERE owner_id = p_drop;
  GET DIAGNOSTICS v_flats = ROW_COUNT;
  UPDATE bms.payment_groups SET payer_owner_id = p_keep WHERE payer_owner_id = p_drop;
  GET DIAGNOSTICS v_groups = ROW_COUNT;

  UPDATE bms.owners
     SET mobile      = COALESCE(NULLIF(btrim(mobile), ''), d.mobile),
         email       = COALESCE(NULLIF(btrim(email), ''), d.email),
         alt_contact = COALESCE(NULLIF(btrim(alt_contact), ''), d.alt_contact,
                                CASE WHEN d.mobile IS DISTINCT FROM mobile THEN d.mobile END),
         address     = COALESCE(NULLIF(btrim(address), ''), d.address)
   WHERE id = p_keep
  RETURNING * INTO k;

  UPDATE bms.owners
     SET is_active = false, merged_into = p_keep,
         notes = trim(BOTH ' ' FROM COALESCE(notes, '') || ' Merged into ' || k.name || ' on ' || to_char(CURRENT_DATE, 'DD Mon YYYY') || '.')
   WHERE id = p_drop;

  PERFORM bms._rebill_flat(fo.flat_id) FROM bms.flat_occupancy fo WHERE fo.owner_id = p_keep AND fo.to_date IS NULL;

  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code, entity_table, entity_id, entity_label, detail, severity)
  VALUES (auth.uid(), bms.actor_name(), 'UPDATE', 'flats', 'owners', p_keep, k.name,
          format('Merged %s%s into %s: %s flat entries and %s combined receipts moved', d.name,
                 COALESCE(' (' || d.mobile || ')', ''), k.name, v_flats, v_groups), 'HIGH');
  RETURN k;
END $$;

-- ---------------------------------------------------------------------
-- Likely doubles: the same name (ignoring case, spaces and dots) or the
-- same mobile number, among people still in use.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.possible_duplicate_people()
RETURNS TABLE (a_id uuid, a_name text, a_mobile text, a_flats text,
               b_id uuid, b_name text, b_mobile text, b_flats text, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM bms.assert_perm('flats','view');
  RETURN QUERY
  WITH p AS (
    SELECT o.id, o.name, o.mobile, o.created_at,
           lower(regexp_replace(o.name, '[\s\.\-]+', '', 'g')) AS nkey,
           bms.normalize_mobile(o.mobile) AS mkey,
           (SELECT string_agg(f.flat_number || CASE WHEN fo.relation_type = 'TENANT' THEN ' (tenant)' ELSE '' END,
                              ', ' ORDER BY f.floor, f.flat_number)
              FROM bms.flat_occupancy fo JOIN bms.flats f ON f.id = fo.flat_id
             WHERE fo.owner_id = o.id AND fo.to_date IS NULL) AS flats
      FROM bms.owners o
     WHERE o.merged_into IS NULL AND o.is_active
  )
  SELECT a.id, a.name, a.mobile, a.flats, b.id, b.name, b.mobile, b.flats,
         CASE WHEN a.nkey = b.nkey AND a.mkey IS NOT DISTINCT FROM b.mkey THEN 'same name and mobile'
              WHEN a.nkey = b.nkey THEN 'same name'
              ELSE 'same mobile number' END
    FROM p a JOIN p b
      ON (a.created_at, a.id) < (b.created_at, b.id)
     AND (a.nkey = b.nkey OR (a.mkey IS NOT NULL AND a.mkey = b.mkey))
   ORDER BY a.name, b.name;
END $$;

REVOKE ALL ON FUNCTION bms.void_occupancy(uuid,text)                       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.correct_occupant(uuid,uuid,text,text,text)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.merge_people(uuid,uuid)                         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.possible_duplicate_people()                     FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.void_occupancy(uuid,text)                    TO authenticated;
GRANT EXECUTE ON FUNCTION bms.correct_occupant(uuid,uuid,text,text,text)   TO authenticated;
GRANT EXECUTE ON FUNCTION bms.merge_people(uuid,uuid)                      TO authenticated;
GRANT EXECUTE ON FUNCTION bms.possible_duplicate_people()                  TO authenticated;
