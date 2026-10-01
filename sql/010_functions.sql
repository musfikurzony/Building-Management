-- =====================================================================
-- 010_functions.sql — the rules that make the ledger trustworthy.
--
-- Everything here runs inside PostgreSQL, so it holds whether the caller
-- is the portal UI, a console, or a direct API call. Hiding a button in
-- the browser is decoration; these are the actual rules.
-- =====================================================================

SET search_path = bms, public;

CREATE OR REPLACE FUNCTION bms.assert_perm(p_module text, p_action text)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF NOT bms.has_perm(p_module, p_action) THEN
    RAISE EXCEPTION 'Permission denied: you need % on %', p_action, p_module
      USING ERRCODE = '42501';
  END IF;
END $$;

-- =====================================================================
-- TRANSACTION GUARD — rules 1, 3, 4 and 6 from the design.
-- =====================================================================
CREATE OR REPLACE FUNCTION bms.txn_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_allow_self boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF bms.period_is_closed(NEW.txn_date) THEN
      RAISE EXCEPTION 'Accounting period % is closed — no transaction can be dated then',
        to_char(NEW.txn_date, 'Mon YYYY') USING ERRCODE = '23514';
    END IF;
    NEW.period_id  := bms.period_for(NEW.txn_date);
    NEW.created_by := COALESCE(NEW.created_by, auth.uid());
    IF NEW.status NOT IN ('DRAFT','SUBMITTED') THEN
      RAISE EXCEPTION 'A transaction must be created as DRAFT or SUBMITTED, not %', NEW.status;
    END IF;
    IF NEW.direction <> 'TRANSFER' AND NEW.account_id IS NULL THEN
      RAISE EXCEPTION 'An account is required';
    END IF;
    -- An income category may not carry an expense, or the year's figures
    -- come out plausible and wrong. Categories marked BOTH take either.
    --
    -- A reversal is exempt, and must be: undoing a service-charge receipt
    -- is written as an EXPENSE against the service-charge category on
    -- purpose, so that the two halves cancel in the same line of the
    -- report. Forcing it into a different category would leave the
    -- original income standing in the year's figures forever.
    -- Service charge has exactly one door.
    --
    -- Typing a service-charge receipt straight into the ledger produces
    -- income that belongs to no flat: the money shows on the dashboard,
    -- the flat still reads as unpaid, and if the payment was ALSO recorded
    -- properly the month is counted twice. That happened in the live
    -- building — two receipts for the same money, one attached to a flat
    -- and one floating.
    --
    -- record_payment() stamps source_module = 'charges'; a hand-typed
    -- entry does not. So the category is refused here unless the entry
    -- came through the Service Charge screen, and the message says where
    -- to go instead. Reversals are exempt for the reason below.
    IF NEW.direction = 'INCOME'
       AND NOT COALESCE(NEW.is_reversal, false)
       AND COALESCE(NEW.source_module,'') <> 'charges'
       AND EXISTS (SELECT 1 FROM bms.categories c
                     JOIN bms.departments d ON d.id = c.department_id
                    WHERE c.id = NEW.category_id AND d.code = 'SERVICE_CHARGE') THEN
      RAISE EXCEPTION 'Service charge is recorded in Service Charge → Record payment, so it lands against a flat and appears on that flat''s statement. Entering it here would count the money twice.'
        USING ERRCODE = '23514';
    END IF;

    IF NEW.category_id IS NOT NULL AND NEW.direction IN ('INCOME','EXPENSE')
       AND NOT COALESCE(NEW.is_reversal, false)
       AND EXISTS (SELECT 1 FROM bms.categories c
                    WHERE c.id = NEW.category_id
                      AND c.txn_type NOT IN ('BOTH', NEW.direction)) THEN
      RAISE EXCEPTION 'Category "%" cannot be used for %',
        (SELECT name FROM bms.categories WHERE id = NEW.category_id),
        lower(NEW.direction) USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  -- ---- UPDATE ----
  -- Rule 3: a posted transaction is frozen. Only these may still change.
  IF OLD.status = 'POSTED' THEN
    IF NEW.txn_date          IS DISTINCT FROM OLD.txn_date
    OR NEW.amount            IS DISTINCT FROM OLD.amount
    OR NEW.direction         IS DISTINCT FROM OLD.direction
    OR NEW.account_id        IS DISTINCT FROM OLD.account_id
    OR NEW.counter_account_id IS DISTINCT FROM OLD.counter_account_id
    OR NEW.department_id     IS DISTINCT FROM OLD.department_id
    OR NEW.category_id       IS DISTINCT FROM OLD.category_id
    OR NEW.payment_method    IS DISTINCT FROM OLD.payment_method
    OR NEW.vendor_id         IS DISTINCT FROM OLD.vendor_id
    OR NEW.flat_id           IS DISTINCT FROM OLD.flat_id THEN
      RAISE EXCEPTION 'Transaction % is posted and cannot be edited. Reverse it instead.',
        COALESCE(OLD.txn_no, OLD.id::text) USING ERRCODE = '23514';
    END IF;
    IF NEW.status NOT IN ('POSTED','REVERSED') THEN
      RAISE EXCEPTION 'A posted transaction can only move to REVERSED, not %', NEW.status;
    END IF;
  END IF;

  IF OLD.status IN ('REVERSED','CANCELLED','REJECTED')
     AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'Transaction is % and is final', OLD.status;
  END IF;

  -- Rule 6: no editing a financial field into or inside a closed month.
  IF (NEW.txn_date IS DISTINCT FROM OLD.txn_date OR NEW.amount IS DISTINCT FROM OLD.amount)
     AND (bms.period_is_closed(NEW.txn_date) OR bms.period_is_closed(OLD.txn_date)) THEN
    RAISE EXCEPTION 'That accounting period is closed';
  END IF;

  IF NEW.txn_date IS DISTINCT FROM OLD.txn_date THEN
    NEW.period_id := bms.period_for(NEW.txn_date);
  END IF;

  -- Rule 1: the approver may not be the creator.
  -- A reversal is the one exception: it undoes money rather than moving new
  -- money out, it already required the finance.cancel permission, and it
  -- carries a mandatory reason. Re-entering the expense afterwards would
  -- still need a second person, so the control is not weakened.
  IF NEW.approved_by IS NOT NULL
     AND NOT COALESCE(NEW.is_reversal, false)
     AND NEW.approved_by IS DISTINCT FROM OLD.approved_by
     AND NEW.approved_by = NEW.created_by THEN
    SELECT allow_self_approval INTO v_allow_self FROM bms.building_settings WHERE id;
    IF NOT COALESCE(v_allow_self, false) THEN
      RAISE EXCEPTION 'You cannot approve a transaction you created. A second person must approve it.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- A human-readable number is assigned the moment it leaves DRAFT.
  IF NEW.txn_no IS NULL AND NEW.status <> 'DRAFT' THEN
    NEW.txn_no := bms.next_doc_no(
      CASE NEW.direction WHEN 'INCOME' THEN 'INC' WHEN 'EXPENSE' THEN 'EXP' ELSE 'TRF' END,
      EXTRACT(YEAR FROM NEW.txn_date)::int,
      CASE NEW.direction WHEN 'INCOME' THEN 'INC' WHEN 'EXPENSE' THEN 'EXP' ELSE 'TRF' END);
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_txn_guard ON bms.transactions;
CREATE TRIGGER trg_txn_guard BEFORE INSERT OR UPDATE ON bms.transactions
  FOR EACH ROW EXECUTE FUNCTION bms.txn_guard();

-- Rule 4: nothing is ever deleted. Belt as well as braces — the REVOKE in
-- 020_rls.sql is the primary control; this catches anything privileged.
CREATE OR REPLACE FUNCTION bms.block_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Rows in % are never deleted. Use cancellation or reversal.', TG_TABLE_NAME
    USING ERRCODE = '42501';
END $$;

DROP TRIGGER IF EXISTS trg_txn_no_delete    ON bms.transactions;
DROP TRIGGER IF EXISTS trg_ledger_no_delete ON bms.ledger_entries;
DROP TRIGGER IF EXISTS trg_pay_no_delete    ON bms.payments;
CREATE TRIGGER trg_txn_no_delete    BEFORE DELETE ON bms.transactions   FOR EACH ROW EXECUTE FUNCTION bms.block_delete();
CREATE TRIGGER trg_ledger_no_delete BEFORE DELETE ON bms.ledger_entries FOR EACH ROW EXECUTE FUNCTION bms.block_delete();
CREATE TRIGGER trg_pay_no_delete    BEFORE DELETE ON bms.payments       FOR EACH ROW EXECUTE FUNCTION bms.block_delete();

-- Ledger entries are written by post_transaction() only, and never edited.
CREATE OR REPLACE FUNCTION bms.block_ledger_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Ledger entries are immutable' USING ERRCODE = '42501';
END $$;
DROP TRIGGER IF EXISTS trg_ledger_no_update ON bms.ledger_entries;
CREATE TRIGGER trg_ledger_no_update BEFORE UPDATE ON bms.ledger_entries
  FOR EACH ROW EXECUTE FUNCTION bms.block_ledger_update();

-- =====================================================================
-- TRANSACTION LIFECYCLE RPCs
-- =====================================================================

-- Does this amount, entered by this user, need someone else to approve it?
CREATE OR REPLACE FUNCTION bms.needs_approval(p_amount bms.money_amount, p_user uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE v_limit bms.money_amount := bms.auto_post_limit(COALESCE(p_user, auth.uid()));
BEGIN
  IF v_limit IS NULL THEN RETURN false; END IF;   -- unlimited
  RETURN p_amount > v_limit;
END $$;

-- Write the account movements for a transaction and mark it POSTED.
CREATE OR REPLACE FUNCTION bms.post_transaction(p_txn uuid)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions;
BEGIN
  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status = 'POSTED' THEN RETURN t; END IF;
  IF t.status <> 'APPROVED' THEN
    RAISE EXCEPTION 'Only an APPROVED transaction can be posted (this one is %)', t.status;
  END IF;
  IF bms.period_is_closed(t.txn_date) THEN
    RAISE EXCEPTION 'That accounting period is closed';
  END IF;

  IF t.direction = 'INCOME' THEN
    INSERT INTO bms.ledger_entries(txn_id, account_id, entry_date, signed_amount, memo)
    VALUES (t.id, t.account_id, t.txn_date, t.amount, t.description);
  ELSIF t.direction = 'EXPENSE' THEN
    INSERT INTO bms.ledger_entries(txn_id, account_id, entry_date, signed_amount, memo)
    VALUES (t.id, t.account_id, t.txn_date, -t.amount, t.description);
  ELSE  -- TRANSFER: out of one account, into the other. Never income or expense.
    INSERT INTO bms.ledger_entries(txn_id, account_id, entry_date, signed_amount, memo)
    VALUES (t.id, t.account_id,        t.txn_date, -t.amount, t.description || ' (out)');
    INSERT INTO bms.ledger_entries(txn_id, account_id, entry_date, signed_amount, memo)
    VALUES (t.id, t.counter_account_id, t.txn_date,  t.amount, t.description || ' (in)');
  END IF;

  UPDATE bms.transactions
     SET status = 'POSTED', posted_at = now()
   WHERE id = t.id
  RETURNING * INTO t;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION bms.submit_transaction(p_txn uuid)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions;
BEGIN
  PERFORM bms.assert_perm('finance','add');
  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status NOT IN ('DRAFT','RETURNED') THEN
    RAISE EXCEPTION 'Only a DRAFT or RETURNED transaction can be submitted (this one is %)', t.status;
  END IF;

  IF bms.needs_approval(t.amount, t.created_by) THEN
    UPDATE bms.transactions
       SET status = 'PENDING_APPROVAL', submitted_by = auth.uid(), submitted_at = now()
     WHERE id = t.id RETURNING * INTO t;
  ELSE
    -- Under the entrant's own auto-post limit: approved by themselves and
    -- posted straight away. Recorded as such, not hidden.
    UPDATE bms.transactions
       SET status = 'APPROVED', submitted_by = auth.uid(), submitted_at = now(),
           approved_by = NULL, approved_at = now(),
           notes = COALESCE(t.notes,'') ||
                   CASE WHEN COALESCE(t.notes,'') = '' THEN '' ELSE E'\n' END ||
                   '[auto-posted: within entrant''s limit]'
     WHERE id = t.id RETURNING * INTO t;
    t := bms.post_transaction(t.id);
  END IF;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION bms.approve_transaction(p_txn uuid, p_post boolean DEFAULT true)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions; v_limit bms.money_amount;
BEGIN
  PERFORM bms.assert_perm('finance','approve');
  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status <> 'PENDING_APPROVAL' THEN
    RAISE EXCEPTION 'Only a PENDING_APPROVAL transaction can be approved (this one is %)', t.status;
  END IF;

  -- Rule 2: within this approver's limit.
  v_limit := bms.approval_limit();
  IF v_limit IS NOT NULL AND t.amount > v_limit THEN
    RAISE EXCEPTION 'This transaction of % is above your approval limit of %', t.amount, v_limit
      USING ERRCODE = '42501';
  END IF;

  UPDATE bms.transactions
     SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now()
   WHERE id = t.id RETURNING * INTO t;   -- the guard trigger blocks self-approval

  IF p_post THEN t := bms.post_transaction(t.id); END IF;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION bms.reject_transaction(p_txn uuid, p_reason text, p_return boolean DEFAULT false)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions;
BEGIN
  PERFORM bms.assert_perm('finance','approve');
  IF COALESCE(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'A reason is required';
  END IF;
  UPDATE bms.transactions
     SET status = CASE WHEN p_return THEN 'RETURNED' ELSE 'REJECTED' END,
         rejected_reason = p_reason,
         approved_by = NULL, approved_at = NULL
   WHERE id = p_txn AND status = 'PENDING_APPROVAL'
  RETURNING * INTO t;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction is not pending approval'; END IF;
  RETURN t;
END $$;

-- Rule 5: a reversal is a real, opposite transaction, linked both ways.
CREATE OR REPLACE FUNCTION bms.reverse_transaction(p_txn uuid, p_reason text, p_date date DEFAULT NULL)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions; r bms.transactions; v_date date;
BEGIN
  PERFORM bms.assert_perm('finance','cancel');
  IF COALESCE(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'A reversal reason is required';
  END IF;

  SELECT * INTO t FROM bms.transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status <> 'POSTED' THEN
    RAISE EXCEPTION 'Only a POSTED transaction can be reversed (this one is %)', t.status;
  END IF;
  IF t.reversed_by_txn_id IS NOT NULL THEN
    RAISE EXCEPTION 'That transaction has already been reversed';
  END IF;

  -- Reverse into the original month if it is still open, otherwise today.
  v_date := COALESCE(p_date, t.txn_date);
  IF bms.period_is_closed(v_date) THEN v_date := CURRENT_DATE; END IF;
  IF bms.period_is_closed(v_date) THEN
    RAISE EXCEPTION 'Both the original period and the current period are closed';
  END IF;

  INSERT INTO bms.transactions(
      txn_date, direction, department_id, category_id, description, amount,
      payment_method, account_id, counter_account_id, vendor_id, flat_id,
      reference_no, status, notes, source_module, source_ref,
      is_reversal, reversal_of_txn_id, reversal_reason, created_by)
  VALUES (
      v_date,
      CASE t.direction WHEN 'INCOME' THEN 'EXPENSE' WHEN 'EXPENSE' THEN 'INCOME' ELSE 'TRANSFER' END,
      t.department_id, t.category_id,
      'Reversal of ' || COALESCE(t.txn_no, t.id::text) || ' — ' || p_reason,
      t.amount, t.payment_method,
      -- a transfer reverses by swapping its two ends
      CASE WHEN t.direction = 'TRANSFER' THEN t.counter_account_id ELSE t.account_id END,
      CASE WHEN t.direction = 'TRANSFER' THEN t.account_id ELSE NULL END,
      t.vendor_id, t.flat_id, t.reference_no, 'DRAFT', t.notes, t.source_module, t.source_ref,
      true, t.id, p_reason, auth.uid())
  RETURNING * INTO r;

  UPDATE bms.transactions SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now()
   WHERE id = r.id;
  r := bms.post_transaction(r.id);

  UPDATE bms.transactions
     SET status = 'REVERSED', reversed_by_txn_id = r.id, reversal_reason = p_reason
   WHERE id = t.id;

  RETURN r;
END $$;

-- Create + submit in one atomic call, which is what the UI actually does.
CREATE OR REPLACE FUNCTION bms.create_transaction(
    p_txn_date date, p_direction text, p_department_id uuid, p_category_id uuid,
    p_description text, p_amount bms.money_amount, p_payment_method text,
    p_account_id uuid, p_counter_account_id uuid DEFAULT NULL,
    p_vendor_id uuid DEFAULT NULL, p_flat_id uuid DEFAULT NULL,
    p_reference_no text DEFAULT NULL, p_notes text DEFAULT NULL,
    p_submit boolean DEFAULT true,
    p_source_module text DEFAULT NULL, p_source_ref uuid DEFAULT NULL)
RETURNS bms.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE t bms.transactions; v_account uuid := p_account_id;
BEGIN
  PERFORM bms.assert_perm('finance','add');
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero';
  END IF;

  -- A caretaker has no sight of the bank, so an entry with no account
  -- chosen lands in the petty-cash account named in settings.
  IF v_account IS NULL AND p_direction <> 'TRANSFER' THEN
    SELECT COALESCE(bs.default_cash_account_id,
                    (SELECT a.id FROM bms.accounts a
                      WHERE a.kind = 'CASH' AND a.is_active ORDER BY a.created_at LIMIT 1))
      INTO v_account FROM bms.building_settings bs WHERE bs.id;
    IF v_account IS NULL THEN
      RAISE EXCEPTION 'No account was chosen and no default cash account is configured';
    END IF;
  END IF;

  INSERT INTO bms.transactions(
      txn_date, direction, department_id, category_id, description, amount,
      payment_method, account_id, counter_account_id, vendor_id, flat_id,
      reference_no, notes, status, created_by, source_module, source_ref)
  VALUES (
      p_txn_date, p_direction, p_department_id, p_category_id, p_description, p_amount,
      p_payment_method, v_account, p_counter_account_id, p_vendor_id, p_flat_id,
      p_reference_no, p_notes, 'DRAFT', auth.uid(), p_source_module, p_source_ref)
  RETURNING * INTO t;

  IF p_submit THEN t := bms.submit_transaction(t.id); END IF;
  RETURN t;
END $$;

-- =====================================================================
-- ACCOUNTING PERIODS
-- =====================================================================
CREATE OR REPLACE FUNCTION bms.close_period(p_year int, p_month int)
RETURNS bms.accounting_periods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE p bms.accounting_periods; v_open int;
BEGIN
  PERFORM bms.assert_perm('finance','close');
  SELECT COUNT(*) INTO v_open FROM bms.transactions t
   WHERE EXTRACT(YEAR FROM t.txn_date)::int = p_year
     AND EXTRACT(MONTH FROM t.txn_date)::int = p_month
     AND t.status IN ('DRAFT','SUBMITTED','PENDING_APPROVAL','RETURNED','APPROVED');
  IF v_open > 0 THEN
    RAISE EXCEPTION '% transaction(s) in that month are still unposted. Post, reject or cancel them first.', v_open;
  END IF;

  PERFORM bms.period_for(make_date(p_year, p_month, 1));
  UPDATE bms.accounting_periods
     SET status = 'CLOSED', closed_by = auth.uid(), closed_at = now()
   WHERE period_year = p_year AND period_month = p_month
  RETURNING * INTO p;
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION bms.reopen_period(p_year int, p_month int, p_reason text)
RETURNS bms.accounting_periods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE p bms.accounting_periods;
BEGIN
  PERFORM bms.assert_perm('finance','close');
  IF COALESCE(btrim(p_reason),'') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;
  UPDATE bms.accounting_periods
     SET status = 'OPEN', closed_by = NULL, closed_at = NULL,
         notes = COALESCE(notes,'') || E'\nReopened: ' || p_reason
   WHERE period_year = p_year AND period_month = p_month
  RETURNING * INTO p;
  IF NOT FOUND THEN RAISE EXCEPTION 'No such period'; END IF;
  RETURN p;
END $$;


-- ---------------------------------------------------------------------
-- A safe account picker for people who may record a spend but must not
-- see balances. Returns names only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.entry_accounts()
RETURNS TABLE (id uuid, code text, name text, kind text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF NOT (bms.has_perm('finance','add') OR bms.has_perm('bank','view')
          OR bms.has_perm('charges','add')) THEN
    RAISE EXCEPTION 'Permission denied' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT a.id, a.code, a.name, a.kind FROM bms.accounts a
     WHERE a.is_active AND a.kind <> 'FD' ORDER BY a.kind, a.name;
END $$;
REVOKE ALL ON FUNCTION bms.entry_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bms.entry_accounts() TO authenticated;

-- What a person is allowed to see about their own submissions, without
-- granting them the whole ledger.
CREATE OR REPLACE FUNCTION bms.my_submissions()
RETURNS SETOF bms.transactions
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT * FROM bms.transactions WHERE created_by = auth.uid() ORDER BY created_at DESC
$$;
REVOKE ALL ON FUNCTION bms.my_submissions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bms.my_submissions() TO authenticated;
