-- =====================================================================
-- 095_correct_entry.sql — putting right a posted entry.
--
-- A posted entry is never edited: the books must show what was recorded
-- and what was done about it. A wrong date or amount is put right by
-- REVERSING the entry and recording the right one — both kept, both
-- dated, both in the audit log. correct_transaction() does the two steps
-- as one, so nobody is left half-way with the money missing.
--
-- It also closes a gap found on the way: reversing an entry that was paid
-- from (or into) a fund — an LPG cylinder, say — reversed the money but
-- left the fund's own record untouched, so the LPG fund stayed short.
-- A reversal now writes the opposite fund movement too, and any entry
-- already reversed that way is repaired below.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A fund follows its entry when the entry is reversed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.fund_follows_reversal() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE mv record; r bms.transactions;
BEGIN
  IF NEW.reversed_by_txn_id IS NULL OR OLD.reversed_by_txn_id IS NOT NULL THEN RETURN NEW; END IF;
  SELECT * INTO r FROM bms.transactions WHERE id = NEW.reversed_by_txn_id;
  FOR mv IN SELECT * FROM bms.fund_movements WHERE txn_id = NEW.id LOOP
    IF NOT EXISTS (SELECT 1 FROM bms.fund_movements WHERE txn_id = r.id AND fund_id = mv.fund_id) THEN
      INSERT INTO bms.fund_movements(fund_id, movement_date, direction, amount, is_cash_movement, txn_id, purpose, notes, created_by)
      VALUES (mv.fund_id, r.txn_date,
              CASE mv.direction WHEN 'CONTRIBUTION' THEN 'WITHDRAWAL' WHEN 'WITHDRAWAL' THEN 'CONTRIBUTION'
                                WHEN 'TRANSFER_IN' THEN 'TRANSFER_OUT' WHEN 'TRANSFER_OUT' THEN 'TRANSFER_IN'
                                ELSE 'WITHDRAWAL' END,
              mv.amount, mv.is_cash_movement, r.id,
              'Reversal of ' || COALESCE(NEW.txn_no, '') || COALESCE(' — ' || mv.purpose, ''),
              NEW.reversal_reason, auth.uid());
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_fund_follows_reversal ON bms.transactions;
CREATE TRIGGER trg_fund_follows_reversal AFTER UPDATE OF reversed_by_txn_id ON bms.transactions
  FOR EACH ROW EXECUTE FUNCTION bms.fund_follows_reversal();

-- Repair: entries reversed before this file left their fund short.
INSERT INTO bms.fund_movements(fund_id, movement_date, direction, amount, is_cash_movement, txn_id, purpose, notes)
SELECT mv.fund_id, r.txn_date,
       CASE mv.direction WHEN 'CONTRIBUTION' THEN 'WITHDRAWAL' WHEN 'WITHDRAWAL' THEN 'CONTRIBUTION'
                         WHEN 'TRANSFER_IN' THEN 'TRANSFER_OUT' WHEN 'TRANSFER_OUT' THEN 'TRANSFER_IN'
                         ELSE 'WITHDRAWAL' END,
       mv.amount, mv.is_cash_movement, r.id,
       'Reversal of ' || COALESCE(t.txn_no, '') || COALESCE(' — ' || mv.purpose, ''), t.reversal_reason
  FROM bms.fund_movements mv
  JOIN bms.transactions t ON t.id = mv.txn_id AND t.reversed_by_txn_id IS NOT NULL
  JOIN bms.transactions r ON r.id = t.reversed_by_txn_id
 WHERE NOT EXISTS (SELECT 1 FROM bms.fund_movements x WHERE x.txn_id = r.id AND x.fund_id = mv.fund_id);

-- ---------------------------------------------------------------------
-- 2. Correct an entry: reverse it and record it again, right.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.correct_transaction(
    p_txn uuid, p_date date, p_amount bms.money_amount,
    p_description text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions; fm bms.fund_movements; nm bms.fund_movements; n bms.transactions; v_reason text;
BEGIN
  PERFORM bms.assert_perm('finance','cancel');
  PERFORM bms.assert_perm('finance','add');
  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Entry not found'; END IF;
  IF t.status <> 'POSTED' OR t.reversed_by_txn_id IS NOT NULL OR t.is_reversal THEN
    RAISE EXCEPTION 'Only a posted entry that has not been reversed can be corrected';
  END IF;
  IF COALESCE(t.source_module, 'reserve') NOT IN ('reserve') THEN
    RAISE EXCEPTION '%', CASE t.source_module
      WHEN 'charges'       THEN 'This is a service-charge payment. Correct it in Service Charge → Payments & receipts (reverse the payment and record it again).'
      WHEN 'salary'        THEN 'This entry was made from Salary. Correct it there.'
      WHEN 'generator'     THEN 'This entry was made from the Generator fuel log. Correct it there.'
      WHEN 'maintenance'   THEN 'This entry was made from a Maintenance job. Correct it there.'
      WHEN 'fixed_deposit' THEN 'This entry was made from Reserve & Deposits. Correct it there.'
      ELSE 'This entry was made from another screen (' || t.source_module || '). Correct it there.' END;
  END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Choose the right date'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter the right amount'; END IF;
  v_reason := COALESCE(NULLIF(btrim(p_reason), ''), 'Wrong date or amount entered');

  SELECT * INTO fm FROM bms.fund_movements WHERE txn_id = t.id ORDER BY created_at LIMIT 1;

  PERFORM bms.reverse_transaction(t.id, 'Corrected — ' || v_reason);

  IF fm.id IS NOT NULL THEN
    -- Paid from (or into) a fund: record it again through the fund, so
    -- the fund and the books stay one story.
    nm := bms.record_fund_movement(
            fm.fund_id, p_date, fm.direction, p_amount, true,
            CASE WHEN t.direction IN ('EXPENSE','TRANSFER') THEN t.account_id END,
            CASE WHEN t.direction = 'INCOME' THEN t.account_id WHEN t.direction = 'TRANSFER' THEN t.counter_account_id END,
            COALESCE(NULLIF(btrim(p_description), ''), fm.purpose),
            'Correction of ' || COALESCE(t.txn_no, '') || ' — ' || v_reason,
            CASE WHEN t.direction IN ('INCOME','EXPENSE') THEN t.category_id END,
            t.payment_method, t.vendor_id);
    SELECT * INTO n FROM bms.transactions WHERE id = nm.txn_id;
  ELSE
    n := bms.create_transaction(
            p_date, t.direction, t.department_id, t.category_id,
            COALESCE(NULLIF(btrim(p_description), ''), t.description), p_amount, t.payment_method,
            t.account_id, t.counter_account_id, t.vendor_id, t.flat_id, t.reference_no,
            trim(BOTH ' ' FROM 'Correction of ' || COALESCE(t.txn_no, '') || ' — ' || v_reason), true, NULL, NULL);
  END IF;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION bms.correct_transaction(uuid,date,bms.money_amount,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.correct_transaction(uuid,date,bms.money_amount,text,text) TO authenticated;
