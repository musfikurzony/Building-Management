-- =====================================================================
-- 013_fund_functions.sql — reserve funds, fixed deposits, budgets,
-- reconciliation and the notification generator.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- FUNDS
-- ---------------------------------------------------------------------

-- Money set aside. Two shapes, and the difference matters:
--
--   cash-backed  the money physically moves to another account. That is
--                a TRANSFER in the ledger; income and expense are
--                untouched, and both balances change.
--   earmark      the committee resolves to set money aside and it stays
--                exactly where it is. The reserve rises; the bank does
--                not move. No transaction, because no money moved.
CREATE OR REPLACE FUNCTION bms.record_fund_movement(
    p_fund uuid, p_date date, p_direction text, p_amount bms.money_amount,
    p_cash_backed boolean DEFAULT false,
    p_from_account uuid DEFAULT NULL, p_to_account uuid DEFAULT NULL,
    p_purpose text DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS bms.fund_movements
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE mv bms.fund_movements; t bms.transactions; f bms.funds; v_balance numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('reserve','add');
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;

  SELECT * INTO f FROM bms.funds WHERE id = p_fund;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fund not found'; END IF;

  -- You cannot take out more than the fund holds.
  IF p_direction IN ('WITHDRAWAL','TRANSFER_OUT') THEN
    SELECT current_balance INTO v_balance FROM bms.v_fund_balances WHERE fund_id = p_fund;
    IF p_amount > COALESCE(v_balance, 0) THEN
      RAISE EXCEPTION 'The fund only holds %, so % cannot be taken out',
        COALESCE(v_balance,0), p_amount;
    END IF;
  END IF;

  IF p_cash_backed AND p_direction <> 'INTEREST' THEN
    IF p_from_account IS NULL OR p_to_account IS NULL THEN
      RAISE EXCEPTION 'A cash-backed movement needs the account it comes from and the account it goes to';
    END IF;
    IF p_from_account = p_to_account THEN
      RAISE EXCEPTION 'A transfer needs two different accounts';
    END IF;
    t := bms.create_transaction(
          p_date, 'TRANSFER', NULL, NULL,
          format('%s — %s', f.name, COALESCE(p_purpose,
                 CASE p_direction WHEN 'CONTRIBUTION' THEN 'reserve contribution'
                                  WHEN 'WITHDRAWAL'   THEN 'reserve withdrawal'
                                  ELSE lower(replace(p_direction,'_',' ')) END)),
          p_amount, 'BANK_TRANSFER', p_from_account, p_to_account,
          NULL, NULL, NULL, p_notes, true, 'reserve', p_fund);
  END IF;

  INSERT INTO bms.fund_movements(fund_id, movement_date, direction, amount,
                                 is_cash_movement, txn_id, purpose, notes, created_by)
  VALUES (p_fund, p_date, p_direction, p_amount, p_cash_backed, t.id, p_purpose, p_notes, auth.uid())
  RETURNING * INTO mv;
  RETURN mv;
END $$;

-- ---------------------------------------------------------------------
-- FIXED DEPOSITS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.open_fixed_deposit(
    p_fd_no text, p_bank text, p_principal bms.money_amount, p_date date,
    p_source_account uuid, p_tenure_months int DEFAULT NULL,
    p_rate numeric DEFAULT NULL, p_maturity date DEFAULT NULL,
    p_fund uuid DEFAULT NULL, p_purpose text DEFAULT NULL, p_branch text DEFAULT NULL)
RETURNS bms.fixed_deposits
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE fd bms.fixed_deposits; acct bms.accounts; t bms.transactions;
        v_maturity date; v_expected numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('reserve','add');
  IF p_principal <= 0 THEN RAISE EXCEPTION 'The principal must be greater than zero'; END IF;
  IF p_source_account IS NULL THEN
    RAISE EXCEPTION 'Say which account the money comes from';
  END IF;

  v_maturity := COALESCE(p_maturity,
    CASE WHEN p_tenure_months IS NOT NULL
         THEN (p_date + make_interval(months => p_tenure_months))::date END);

  -- Simple interest is what Bangladeshi FD certificates quote, so that is
  -- what we show as "expected". The bank's actual figure is recorded on
  -- maturity and is the one that reaches the ledger.
  v_expected := CASE
    WHEN p_rate IS NOT NULL AND p_tenure_months IS NOT NULL
    THEN ROUND(p_principal * (1 + (p_rate / 100.0) * (p_tenure_months / 12.0)), 2)
  END;

  -- The FD gets its own account, so the money is visibly somewhere.
  INSERT INTO bms.accounts(code, name, kind, bank_name, opening_balance, opening_date, notes)
  VALUES ('FD-' || upper(p_fd_no), 'FD ' || p_fd_no || ' — ' || p_bank, 'FD',
          p_bank, 0, p_date, p_purpose)
  RETURNING * INTO acct;

  INSERT INTO bms.fixed_deposits(fd_no, bank_name, branch, account_id, source_account_id,
                                 fund_id, principal, deposit_date, tenure_months,
                                 interest_rate, maturity_date, expected_maturity_amount,
                                 purpose, created_by)
  VALUES (p_fd_no, p_bank, p_branch, acct.id, p_source_account, p_fund, p_principal,
          p_date, p_tenure_months, p_rate, v_maturity, v_expected, p_purpose, auth.uid())
  RETURNING * INTO fd;

  -- Opening an FD moves money; it does not spend it.
  t := bms.create_transaction(
        p_date, 'TRANSFER', NULL, NULL,
        format('Fixed deposit %s opened at %s', p_fd_no, p_bank),
        p_principal, 'BANK_TRANSFER', p_source_account, acct.id,
        NULL, NULL, p_fd_no, p_purpose, true, 'fixed_deposit', fd.id);

  INSERT INTO bms.fd_events(fd_id, event_type, event_date, amount, txn_id, created_by)
  VALUES (fd.id, 'OPENED', p_date, p_principal, t.id, auth.uid());

  -- No fund_movement is written when the deposit is tagged to a fund.
  -- Tying an FD to a fund does not change what the fund holds — it says
  -- WHERE the fund holds it. v_fund_balances picks the deposit up as
  -- backing through fixed_deposits.fund_id, so writing a movement here
  -- would count the same money twice.

  RETURN fd;
END $$;

CREATE OR REPLACE FUNCTION bms.record_fd_interest(
    p_fd uuid, p_date date, p_amount bms.money_amount, p_to_account uuid DEFAULT NULL)
RETURNS bms.fd_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE ev bms.fd_events; fd bms.fixed_deposits; t bms.transactions;
        v_dept uuid; v_cat uuid;
BEGIN
  PERFORM bms.assert_perm('reserve','add');
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Interest must be greater than zero'; END IF;
  SELECT * INTO fd FROM bms.fixed_deposits WHERE id = p_fd;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixed deposit not found'; END IF;

  SELECT id INTO v_dept FROM bms.departments WHERE code = 'RESERVE';
  SELECT id INTO v_cat  FROM bms.categories
   WHERE department_id = v_dept AND name = 'Bank interest' LIMIT 1;

  -- Interest is real income, wherever it is credited.
  t := bms.create_transaction(
        p_date, 'INCOME', v_dept, v_cat,
        format('Interest on fixed deposit %s', fd.fd_no),
        p_amount, 'BANK_TRANSFER', COALESCE(p_to_account, fd.account_id),
        NULL, NULL, NULL, fd.fd_no, NULL, true, 'fixed_deposit', fd.id);

  INSERT INTO bms.fd_events(fd_id, event_type, event_date, amount, txn_id, created_by)
  VALUES (p_fd, 'INTEREST_CREDIT', p_date, p_amount, t.id, auth.uid())
  RETURNING * INTO ev;
  RETURN ev;
END $$;

CREATE OR REPLACE FUNCTION bms.mature_fixed_deposit(
    p_fd uuid, p_date date, p_actual_amount bms.money_amount, p_to_account uuid,
    p_premature boolean DEFAULT false)
RETURNS bms.fixed_deposits
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE fd bms.fixed_deposits; t bms.transactions; v_interest numeric(14,2);
        v_held numeric(14,2); v_dept uuid; v_cat uuid;
BEGIN
  PERFORM bms.assert_perm('reserve','approve');
  SELECT * INTO fd FROM bms.fixed_deposits WHERE id = p_fd FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixed deposit not found'; END IF;
  IF fd.status <> 'ACTIVE' THEN RAISE EXCEPTION 'That deposit is already %', fd.status; END IF;
  IF p_actual_amount <= 0 THEN RAISE EXCEPTION 'Enter the amount the bank paid out'; END IF;

  -- Whatever came back above what the deposit already held is NEW income.
  --
  -- The subtlety, and it is the one that silently doubles a building's
  -- reported interest: quarterly interest credited earlier is already
  -- inside this deposit. Booking (payout − principal) again would count
  -- that interest a second time. So the base is what the deposit actually
  -- holds today, not the original principal.
  SELECT COALESCE(current_balance, fd.principal) INTO v_held
    FROM bms.v_account_balances WHERE account_id = fd.account_id;

  v_interest := p_actual_amount - COALESCE(v_held, fd.principal);

  IF v_interest <> 0 THEN
    SELECT id INTO v_dept FROM bms.departments WHERE code = 'RESERVE';
    SELECT id INTO v_cat  FROM bms.categories
     WHERE department_id = v_dept
       AND name = CASE WHEN v_interest > 0 THEN 'Bank interest' ELSE 'Deposit penalty' END
     LIMIT 1;

    -- A premature break can pay back LESS than the deposit holds, because
    -- the bank claws interest back. That is a real cost, and it is booked
    -- as one rather than being quietly lost.
    t := bms.create_transaction(
          p_date,
          CASE WHEN v_interest > 0 THEN 'INCOME' ELSE 'EXPENSE' END,
          v_dept, v_cat,
          format('%s fixed deposit %s',
                 CASE WHEN v_interest > 0 THEN 'Interest on maturity of'
                      ELSE 'Interest forfeited on early encashment of' END, fd.fd_no),
          ABS(v_interest), 'BANK_TRANSFER', fd.account_id, NULL, NULL, NULL,
          fd.fd_no, NULL, true, 'fixed_deposit', fd.id);
  END IF;

  -- Then the whole balance comes back to the bank.
  t := bms.create_transaction(
        p_date, 'TRANSFER', NULL, NULL,
        format('Fixed deposit %s %s', fd.fd_no,
               CASE WHEN p_premature THEN 'encashed early' ELSE 'matured' END),
        p_actual_amount, 'BANK_TRANSFER', fd.account_id, p_to_account,
        NULL, NULL, fd.fd_no, NULL, true, 'fixed_deposit', fd.id);

  UPDATE bms.fixed_deposits
     SET status = CASE WHEN p_premature THEN 'ENCASHED' ELSE 'MATURED' END,
         actual_maturity_amount = p_actual_amount
   WHERE id = p_fd RETURNING * INTO fd;

  INSERT INTO bms.fd_events(fd_id, event_type, event_date, amount, txn_id, created_by)
  VALUES (p_fd, CASE WHEN p_premature THEN 'PREMATURE_ENCASH' ELSE 'MATURITY' END,
          p_date, p_actual_amount, t.id, auth.uid());

  UPDATE bms.accounts SET is_active = false WHERE id = fd.account_id;
  RETURN fd;
END $$;

-- ---------------------------------------------------------------------
-- BUDGETS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.set_budget(
    p_year int, p_department uuid, p_annual bms.money_amount,
    p_category uuid DEFAULT NULL, p_monthly jsonb DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS bms.budgets
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE b bms.budgets; m int; v_amount numeric(14,2); v_spread numeric(14,2); v_last numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('budget','add');
  IF p_annual < 0 THEN RAISE EXCEPTION 'A budget cannot be negative'; END IF;

  -- Deliberately NOT an ON CONFLICT. A department-level budget has a NULL
  -- category, and in a unique index NULL never equals NULL — so the
  -- conflict would never fire and every re-set would silently stack a
  -- second budget on the first, doubling the year's allowance.
  SELECT * INTO b FROM bms.budgets
   WHERE fiscal_year = p_year AND department_id = p_department
     AND category_id IS NOT DISTINCT FROM p_category
   FOR UPDATE;

  IF FOUND THEN
    UPDATE bms.budgets SET annual_amount = p_annual, notes = p_notes
     WHERE id = b.id RETURNING * INTO b;
  ELSE
    INSERT INTO bms.budgets(fiscal_year, department_id, category_id,
                            annual_amount, notes, created_by)
    VALUES (p_year, p_department, p_category, p_annual, p_notes, auth.uid())
    RETURNING * INTO b;
  END IF;

  DELETE FROM bms.budget_lines WHERE budget_id = b.id;

  IF p_monthly IS NOT NULL AND jsonb_typeof(p_monthly) = 'object' THEN
    FOR m IN 1..12 LOOP
      v_amount := COALESCE((p_monthly ->> m::text)::numeric, 0);
      INSERT INTO bms.budget_lines(budget_id, period_month, amount) VALUES (b.id, m, v_amount);
    END LOOP;
  ELSE
    -- Spread evenly, and put the rounding remainder in December rather
    -- than letting twelve roundings quietly lose a few taka.
    v_spread := ROUND(p_annual / 12.0, 2);
    v_last   := p_annual - (v_spread * 11);
    FOR m IN 1..12 LOOP
      INSERT INTO bms.budget_lines(budget_id, period_month, amount)
      VALUES (b.id, m, CASE WHEN m = 12 THEN v_last ELSE v_spread END);
    END LOOP;
  END IF;

  RETURN b;
END $$;

-- ---------------------------------------------------------------------
-- BANK RECONCILIATION
-- ---------------------------------------------------------------------
-- The statement header. Re-uploading the same account/date returns the
-- statement already there rather than creating a second one, and replaces
-- its lines, so a corrected download from the bank overwrites cleanly
-- instead of doubling every figure.
CREATE OR REPLACE FUNCTION bms.create_bank_statement(
    p_account uuid, p_statement_date date, p_closing_balance bms.money_amount,
    p_period_start date DEFAULT NULL, p_period_end date DEFAULT NULL,
    p_opening_balance bms.money_amount DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS bms.bank_statements
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE st bms.bank_statements;
BEGIN
  PERFORM bms.assert_perm('bank','edit');
  IF p_account IS NULL THEN RAISE EXCEPTION 'Say which account this statement is for'; END IF;

  SELECT * INTO st FROM bms.bank_statements
   WHERE account_id = p_account AND statement_date = p_statement_date;

  IF FOUND THEN
    IF st.status = 'RECONCILED' THEN
      RAISE EXCEPTION 'That statement is already reconciled and cannot be replaced';
    END IF;
    DELETE FROM bms.bank_statement_lines WHERE statement_id = st.id;
    UPDATE bms.bank_statements
       SET closing_balance = p_closing_balance, opening_balance = p_opening_balance,
           period_start = p_period_start, period_end = p_period_end, notes = p_notes
     WHERE id = st.id RETURNING * INTO st;
    RETURN st;
  END IF;

  INSERT INTO bms.bank_statements(account_id, statement_date, period_start, period_end,
                                  opening_balance, closing_balance, notes, uploaded_by)
  VALUES (p_account, p_statement_date, p_period_start, p_period_end,
          p_opening_balance, p_closing_balance, p_notes, auth.uid())
  RETURNING * INTO st;
  RETURN st;
END $$;

-- Pair a statement line with a transaction by hand, for the ones
-- auto-matching would not touch.
CREATE OR REPLACE FUNCTION bms.match_statement_line(
    p_line uuid, p_txn uuid, p_ignore boolean DEFAULT false)
RETURNS bms.bank_statement_lines
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE ln bms.bank_statement_lines;
BEGIN
  PERFORM bms.assert_perm('bank','edit');

  IF p_ignore THEN
    UPDATE bms.bank_statement_lines
       SET matched_txn_id = NULL, match_status = 'IGNORED'
     WHERE id = p_line RETURNING * INTO ln;
  ELSE
    -- One bank line, one transaction. Letting a transaction answer for
    -- two lines is how a reconciliation comes out clean while the money
    -- is wrong.
    IF EXISTS (SELECT 1 FROM bms.bank_statement_lines
                WHERE matched_txn_id = p_txn AND id <> p_line) THEN
      RAISE EXCEPTION 'That transaction is already matched to another statement line';
    END IF;
    UPDATE bms.bank_statement_lines
       SET matched_txn_id = p_txn, match_status = 'MANUAL_MATCHED'
     WHERE id = p_line RETURNING * INTO ln;
  END IF;

  IF ln.id IS NULL THEN RAISE EXCEPTION 'Statement line not found'; END IF;
  RETURN ln;
END $$;

CREATE OR REPLACE FUNCTION bms.import_statement_lines(p_statement uuid, p_lines jsonb)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE ln jsonb; n int := 0;
BEGIN
  PERFORM bms.assert_perm('bank','edit');
  FOR ln IN SELECT * FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) LOOP
    INSERT INTO bms.bank_statement_lines(statement_id, line_date, description, reference, debit, credit)
    VALUES (p_statement, (ln->>'line_date')::date, ln->>'description', ln->>'reference',
            COALESCE((ln->>'debit')::numeric, 0), COALESCE((ln->>'credit')::numeric, 0));
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Match statement lines to posted transactions on the same account, by
-- amount and a close date. Anything ambiguous is left alone for a person
-- to decide: a wrong automatic match is worse than no match.
CREATE OR REPLACE FUNCTION bms.auto_match_statement(p_statement uuid, p_day_window int DEFAULT 3)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE st bms.bank_statements; ln record; v_txn uuid; v_count int := 0; v_hits int;
BEGIN
  PERFORM bms.assert_perm('bank','edit');
  SELECT * INTO st FROM bms.bank_statements WHERE id = p_statement;
  IF NOT FOUND THEN RAISE EXCEPTION 'Statement not found'; END IF;

  FOR ln IN SELECT * FROM bms.bank_statement_lines
             WHERE statement_id = p_statement AND match_status = 'UNMATCHED'
  LOOP
    SELECT COUNT(*), (array_agg(c.txn_id))[1] INTO v_hits, v_txn
      FROM (
        SELECT DISTINCT l.txn_id
          FROM bms.ledger_entries l
          JOIN bms.transactions t ON t.id = l.txn_id
         WHERE l.account_id = st.account_id
           AND t.status = 'POSTED'
           AND ABS(l.signed_amount - (ln.credit - ln.debit)) < 0.005
           AND l.entry_date BETWEEN ln.line_date - p_day_window AND ln.line_date + p_day_window
           AND NOT EXISTS (SELECT 1 FROM bms.bank_statement_lines x
                            WHERE x.matched_txn_id = l.txn_id AND x.id <> ln.id)
      ) c;

    IF v_hits = 1 THEN
      UPDATE bms.bank_statement_lines
         SET matched_txn_id = v_txn, match_status = 'AUTO_MATCHED'
       WHERE id = ln.id;
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END $$;

CREATE OR REPLACE FUNCTION bms.reconcile_account(
    p_statement uuid, p_notes text DEFAULT NULL)
RETURNS bms.reconciliations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE st bms.bank_statements; r bms.reconciliations; v_system numeric(14,2);
BEGIN
  PERFORM bms.assert_perm('bank','edit');
  SELECT * INTO st FROM bms.bank_statements WHERE id = p_statement;
  IF NOT FOUND THEN RAISE EXCEPTION 'Statement not found'; END IF;

  SELECT COALESCE(a.opening_balance, 0) + COALESCE(SUM(l.signed_amount), 0)
    INTO v_system
    FROM bms.accounts a
    LEFT JOIN bms.ledger_entries l
           ON l.account_id = a.id AND l.entry_date <= st.statement_date
   WHERE a.id = st.account_id
   GROUP BY a.opening_balance;

  INSERT INTO bms.reconciliations(account_id, statement_id, as_of_date,
                                  system_balance, bank_balance, notes,
                                  status, reconciled_by)
  VALUES (st.account_id, p_statement, st.statement_date,
          COALESCE(v_system, 0), st.closing_balance, p_notes,
          CASE WHEN ABS(st.closing_balance - COALESCE(v_system,0)) < 0.005
               THEN 'AGREED' ELSE 'DISPUTED' END,
          auth.uid())
  RETURNING * INTO r;

  IF r.status = 'AGREED' THEN
    UPDATE bms.bank_statements SET status = 'RECONCILED' WHERE id = p_statement;
  END IF;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- NOTIFICATIONS
--
-- One generator, driven by the same alert view the dashboard uses, so a
-- new alert becomes a new notification with no extra code. Runs nightly
-- under pg_cron where that is available, and on demand otherwise.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms.generate_notifications()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  al record; usr record; rule bms.notification_rules;
  v_key text; v_made int := 0; v_today text := to_char(CURRENT_DATE, 'YYYY-MM-DD');
BEGIN
  IF NOT bms.is_active_user() THEN
    RAISE EXCEPTION 'Not permitted' USING ERRCODE = '42501';
  END IF;

  FOR al IN SELECT * FROM bms.v_alerts_all LOOP
    SELECT * INTO rule FROM bms.notification_rules WHERE alert_type = al.alert_type;
    CONTINUE WHEN NOT FOUND OR NOT rule.is_enabled;

    FOR usr IN SELECT up.user_id FROM bms.user_profiles up WHERE up.is_active LOOP
      -- Only tell people who would be allowed to open the thing.
      CONTINUE WHEN NOT EXISTS (
        SELECT 1 FROM bms.user_roles ur
          JOIN bms.roles r ON r.id = ur.role_id
          LEFT JOIN bms.role_permissions rp ON rp.role_id = r.id
          LEFT JOIN bms.permissions p ON p.id = rp.permission_id
         WHERE ur.user_id = usr.user_id
           AND (r.is_superuser
                OR (p.module_code = rule.module_code AND p.action = rule.action)));

      v_key := al.alert_type || ':' || v_today;
      INSERT INTO bms.notifications(user_id, alert_type, title, body, severity, link, dedupe_key)
      VALUES (usr.user_id, al.alert_type, rule.title,
              format('%s item%s', al.item_count, CASE WHEN al.item_count = 1 THEN '' ELSE 's' END)
                || CASE WHEN al.amount IS NOT NULL THEN ' · ' || al.amount::text ELSE '' END,
              rule.severity, al.link, v_key)
      ON CONFLICT (user_id, dedupe_key) DO NOTHING;
      IF FOUND THEN v_made := v_made + 1; END IF;
    END LOOP;
  END LOOP;
  RETURN v_made;
END $$;

CREATE OR REPLACE FUNCTION bms.mark_notifications_read(p_ids uuid[] DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE bms.notifications
     SET is_read = true, read_at = now()
   WHERE user_id = auth.uid() AND NOT is_read
     AND (p_ids IS NULL OR id = ANY(p_ids));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
