-- =====================================================================
-- 094_remove_person.sql — taking a person off the list.
--
-- A name entered by mistake, a placeholder owner put on many flats while
-- setting up, someone who sold up and left: the owner wants them gone
-- from the lists. Erasing a person would also erase who owned a flat and
-- who paid — the history the receipts and statements stand on — so a
-- person is REMOVED instead: hidden from every list and picker, kept in
-- the records, and back with one tap if it was a mistake.
--
--   remove_person(person, reason, take_off_flats)
--     • refuses while they are still on a flat, unless take_off_flats —
--       then each current entry is taken off as "added by mistake" and
--       the bill passes to whoever else is on the flat;
--   restore_person(person) brings them back to the lists.
-- Both need flats.edit and are in the audit log.
-- =====================================================================

ALTER TABLE bms.owners
  ADD COLUMN IF NOT EXISTS removed_at     timestamptz,
  ADD COLUMN IF NOT EXISTS removed_reason text;

CREATE OR REPLACE FUNCTION bms.remove_person(p_person uuid, p_reason text, p_take_off_flats boolean DEFAULT false)
RETURNS bms.owners
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE o bms.owners; v_flats text; occ record; v_n int := 0;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why (for example: entered by mistake)'; END IF;
  SELECT * INTO o FROM bms.owners WHERE id = p_person FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That person no longer exists'; END IF;
  IF o.removed_at IS NOT NULL THEN RAISE EXCEPTION '% has already been removed', o.name; END IF;

  SELECT string_agg(f.flat_number || ' (' || lower(fo.relation_type) || ')', ', ' ORDER BY f.floor, f.flat_number)
    INTO v_flats
    FROM bms.flat_occupancy fo JOIN bms.flats f ON f.id = fo.flat_id
   WHERE fo.owner_id = p_person AND fo.to_date IS NULL;

  IF v_flats IS NOT NULL AND NOT p_take_off_flats THEN
    RAISE EXCEPTION '% is still on %. Take them off those flats first, or tick "take off all their flats".', o.name, v_flats;
  END IF;

  FOR occ IN SELECT fo.id FROM bms.flat_occupancy fo WHERE fo.owner_id = p_person AND fo.to_date IS NULL LOOP
    PERFORM bms.void_occupancy(occ.id, 'Person removed: ' || btrim(p_reason));
    v_n := v_n + 1;
  END LOOP;

  UPDATE bms.owners
     SET is_active = false, removed_at = now(), removed_reason = btrim(p_reason)
   WHERE id = p_person
  RETURNING * INTO o;

  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code, entity_table, entity_id, entity_label, detail, severity)
  VALUES (auth.uid(), bms.actor_name(), 'UPDATE', 'flats', 'owners', p_person, o.name,
          format('Removed %s from the lists (%s)%s', o.name, btrim(p_reason),
                 CASE WHEN v_n > 0 THEN format(' and took them off %s flat(s): %s', v_n, v_flats) ELSE '' END), 'HIGH');
  RETURN o;
END $$;

CREATE OR REPLACE FUNCTION bms.restore_person(p_person uuid)
RETURNS bms.owners
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE o bms.owners;
BEGIN
  PERFORM bms.assert_perm('flats','edit');
  SELECT * INTO o FROM bms.owners WHERE id = p_person FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That person no longer exists'; END IF;
  IF o.merged_into IS NOT NULL THEN RAISE EXCEPTION '% was merged into another person and cannot be restored', o.name; END IF;
  IF o.removed_at IS NULL THEN RETURN o; END IF;
  UPDATE bms.owners SET is_active = true, removed_at = NULL, removed_reason = NULL WHERE id = p_person RETURNING * INTO o;
  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code, entity_table, entity_id, entity_label, detail, severity)
  VALUES (auth.uid(), bms.actor_name(), 'UPDATE', 'flats', 'owners', p_person, o.name,
          format('Restored %s to the lists (their flats are not put back)', o.name), 'NORMAL');
  RETURN o;
END $$;

REVOKE ALL ON FUNCTION bms.remove_person(uuid,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.restore_person(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.remove_person(uuid,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION bms.restore_person(uuid) TO authenticated;
