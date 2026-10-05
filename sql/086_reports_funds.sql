-- =====================================================================
-- 086_reports_funds.sql — the monthly report, and funds that can pay.
--
-- PART 1 — FUNDS THAT PAY FOR THINGS DIRECTLY
-- -------------------------------------------
-- Until now money could leave a fund only by moving to another of our
-- own accounts (a transfer). Real reserves are spent: the lift motor is
-- paid for straight out of the reserve account, and the LPG emergency
-- fund buys a cylinder and is refilled from the next LPG collection.
-- Doing that took two separate entries — an expense in Finance and an
-- earmark withdrawal here — which is exactly the kind of pair that gets
-- half-entered. record_fund_movement can now do both in one step:
-- given a category, a withdrawal becomes a real EXPENSE out of the
-- chosen account and a contribution a real INCOME into it, tied to the
-- fund movement that explains it.
--
-- PART 2 — THE MONTHLY REPORT
-- ---------------------------
-- The figures a finance controller prints and files every month, each
-- computed here so the printed page, the Excel file and the dashboard
-- agree to the taka:
--   report_income_expense   income and expense by department and category
--   report_accounts         every account: opening, money in, money out, closing
--   report_funds            every fund: opening, added, used, closing
--   report_service_charge   billed, collected, collection %, outstanding
-- All read-only, all behind reports.view.
-- =====================================================================

SET search_path = bms, public;

-- ---------------------------------------------------------------------
-- PART 1
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS bms.record_fund_movement(uuid, date, text, bms.money_amount, boolean, uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION bms.record_fund_movement(
    p_fund uuid, p_date date, p_direction text, p_amount bms.money_amount,
    p_cash_backed boolean DEFAULT false,
    p_from_account uuid DEFAULT NULL, p_to_account uuid DEFAULT NULL,
    p_purpose text DEFAULT NULL, p_notes text DEFAULT NULL,
    p_category uuid DEFAULT NULL, p_method text DEFAULT NULL, p_vendor uuid DEFAULT NULL)
RETURNS bms.fund_movements
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE mv bms.fund_movements; t bms.transactions; f bms.funds; c bms.categories;
        v_balance numeric(14,2); v_dir text; v_account uuid; v_desc text;
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

  v_desc := format('%s — %s', f.name, COALESCE(NULLIF(btrim(p_purpose),''),
              CASE p_direction WHEN 'CONTRIBUTION' THEN 'reserve contribution'
                               WHEN 'WITHDRAWAL'   THEN 'reserve withdrawal'
                               ELSE lower(replace(p_direction,'_',' ')) END));

  IF p_cash_backed AND p_category IS NOT NULL THEN
    -- Paid straight out of the fund, or received straight into it.
    IF p_direction NOT IN ('CONTRIBUTION','WITHDRAWAL') THEN
      RAISE EXCEPTION 'Only money put in or taken out can be booked as income or expense';
    END IF;
    PERFORM bms.assert_perm('finance','add');
    SELECT * INTO c FROM bms.categories WHERE id = p_category;
    IF NOT FOUND THEN RAISE EXCEPTION 'Category not found'; END IF;
    v_dir     := CASE p_direction WHEN 'WITHDRAWAL' THEN 'EXPENSE' ELSE 'INCOME' END;
    v_account := CASE p_direction WHEN 'WITHDRAWAL' THEN p_from_account ELSE p_to_account END;
    IF v_account IS NULL THEN
      RAISE EXCEPTION '%', CASE v_dir WHEN 'EXPENSE' THEN 'Say which account the money was paid from'
                                      ELSE 'Say which account the money was received into' END;
    END IF;
    IF c.txn_type NOT IN (v_dir, 'BOTH') THEN
      RAISE EXCEPTION 'The category "%" is for %, not %', c.name, lower(c.txn_type), lower(v_dir);
    END IF;
    t := bms.create_transaction(
          p_date, v_dir, c.department_id, c.id, v_desc, p_amount,
          COALESCE(p_method, 'CASH'), v_account, NULL,
          p_vendor, NULL, NULL, p_notes, true, 'reserve', p_fund);

  ELSIF p_cash_backed AND p_direction <> 'INTEREST' THEN
    -- Moved between two of our own accounts.
    IF p_from_account IS NULL OR p_to_account IS NULL THEN
      RAISE EXCEPTION 'A cash-backed movement needs the account it comes from and the account it goes to';
    END IF;
    IF p_from_account = p_to_account THEN
      RAISE EXCEPTION 'A transfer needs two different accounts';
    END IF;
    t := bms.create_transaction(
          p_date, 'TRANSFER', NULL, NULL, v_desc,
          p_amount, 'BANK_TRANSFER', p_from_account, p_to_account,
          NULL, NULL, NULL, p_notes, true, 'reserve', p_fund);
  END IF;

  INSERT INTO bms.fund_movements(fund_id, movement_date, direction, amount,
                                 is_cash_movement, txn_id, purpose, notes, created_by)
  VALUES (p_fund, p_date, p_direction, p_amount, p_cash_backed, t.id, p_purpose, p_notes, auth.uid())
  RETURNING * INTO mv;
  RETURN mv;
END $$;

REVOKE ALL ON FUNCTION bms.record_fund_movement(uuid,date,text,bms.money_amount,boolean,uuid,uuid,text,text,uuid,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms.record_fund_movement(uuid,date,text,bms.money_amount,boolean,uuid,uuid,text,text,uuid,text,uuid) TO authenticated;

-- A fund with no account of its own is backed by the cash moved for it.
-- Now that a fund can pay for things directly, that net can go below
-- zero (the money came out of the general account), and a fund cannot
-- hold less than nothing. Same view as 042, with that one floor.
CREATE OR REPLACE VIEW bms.v_fund_balances WITH (security_invoker = true) AS
WITH mv AS (
  SELECT fund_id,
         SUM(CASE WHEN direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN')
                  THEN amount ELSE -amount END)::numeric(14,2) AS movement,
         SUM(CASE WHEN is_cash_movement
                  THEN CASE WHEN direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN')
                            THEN amount ELSE -amount END
                  ELSE 0 END)::numeric(14,2) AS cash_movement,
         MAX(movement_date) AS last_movement
    FROM bms.fund_movements GROUP BY fund_id
)
, bal AS (
  SELECT f.id AS fund_id,
         (f.opening_balance + COALESCE(mv.movement, 0))::numeric(14,2) AS current_balance,
         COALESCE((SELECT SUM(fd.principal) FROM bms.fixed_deposits fd
                    WHERE fd.fund_id = f.id AND fd.status = 'ACTIVE'), 0)::numeric(14,2)
           AS held_in_deposits,
         CASE WHEN f.account_id IS NOT NULL
              THEN COALESCE((SELECT ab.current_balance FROM bms.v_account_balances ab
                              WHERE ab.account_id = f.account_id), 0)
              -- Money paid straight out of a fund with no account of its
              -- own came from the general account; it cannot leave the
              -- fund holding less than nothing.
              ELSE GREATEST(COALESCE(mv.cash_movement, 0), 0)
         END::numeric(14,2) AS held_in_account
    FROM bms.funds f
    LEFT JOIN mv ON mv.fund_id = f.id
)
SELECT f.id AS fund_id, f.code, f.name, f.fund_type, f.purpose,
       f.opening_balance, f.target_amount, f.target_date, f.account_id, f.is_active,
       COALESCE(mv.movement, 0)                                   AS movement,
       b.current_balance,
       b.held_in_deposits,
       b.held_in_account,
       (b.held_in_deposits + b.held_in_account)::numeric(14,2)    AS funded_amount,
       GREATEST(b.current_balance - b.held_in_deposits - b.held_in_account, 0)::numeric(14,2)
            AS unfunded_amount,
       (b.held_in_deposits + b.held_in_account >= b.current_balance) AS is_funded,
       mv.last_movement,
       CASE WHEN f.target_amount > 0
            THEN LEAST(100, ROUND(b.current_balance * 100.0 / f.target_amount, 1))
       END AS progress_pct,
       GREATEST(f.target_amount - b.current_balance, 0)::numeric(14,2) AS remaining_required
  FROM bms.funds f
  JOIN bal b ON b.fund_id = f.id
  LEFT JOIN mv ON mv.fund_id = f.id;


-- ---------------------------------------------------------------------
-- PART 2 — the monthly report
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bms._report_range(p_from date, p_to date) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_from IS NULL OR p_to IS NULL THEN RAISE EXCEPTION 'A report needs a start and an end date'; END IF;
  IF p_to < p_from THEN RAISE EXCEPTION 'The end date is before the start date'; END IF;
END $$;

-- Income and expense, one row per department and category. Same rule as
-- every other total: posted, not a transfer, not reversed.
CREATE OR REPLACE FUNCTION bms.report_income_expense(p_from date, p_to date)
RETURNS TABLE (direction text, department_id uuid, department_name text, department_sort int,
               category_id uuid, category_name text, entries bigint, amount numeric(14,2))
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('reports','view');
  PERFORM bms._report_range(p_from, p_to);
  RETURN QUERY
  SELECT t.direction, t.department_id,
         COALESCE(d.name, 'Unclassified'), COALESCE(d.sort_order, 9999),
         t.category_id, COALESCE(c.name, 'Uncategorised'),
         COUNT(*), SUM(t.amount)::numeric(14,2)
    FROM bms.transactions t
    LEFT JOIN bms.departments d ON d.id = t.department_id
    LEFT JOIN bms.categories  c ON c.id = t.category_id
   WHERE t.status = 'POSTED' AND t.direction IN ('INCOME','EXPENSE')
     AND NOT t.is_reversal AND t.reversed_by_txn_id IS NULL
     AND t.txn_date BETWEEN p_from AND p_to
   GROUP BY t.direction, t.department_id, d.name, d.sort_order, t.category_id, c.name
   ORDER BY t.direction DESC, COALESCE(d.sort_order, 9999), COALESCE(d.name,'Unclassified'),
            SUM(t.amount) DESC;
END $$;

-- Every account over the period. Opening and closing follow the same
-- rule as v_account_balances (opening balance + ledger), so the closing
-- figure of a report that ends today is the balance on the dashboard.
CREATE OR REPLACE FUNCTION bms.report_accounts(p_from date, p_to date)
RETURNS TABLE (account_id uuid, code text, name text, kind text, is_active boolean,
               opening numeric(14,2), money_in numeric(14,2), money_out numeric(14,2),
               closing numeric(14,2))
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('reports','view');
  PERFORM bms._report_range(p_from, p_to);
  RETURN QUERY
  WITH le AS (
    SELECT l.account_id,
           SUM(l.signed_amount) FILTER (WHERE l.entry_date <  p_from)                         AS before,
           SUM(l.signed_amount) FILTER (WHERE l.entry_date BETWEEN p_from AND p_to AND l.signed_amount > 0) AS ins,
           -SUM(l.signed_amount) FILTER (WHERE l.entry_date BETWEEN p_from AND p_to AND l.signed_amount < 0) AS outs
      FROM bms.ledger_entries l
     WHERE l.entry_date <= p_to
     GROUP BY l.account_id
  )
  SELECT a.id, a.code, a.name, a.kind, a.is_active,
         (CASE WHEN a.opening_date <= p_to THEN a.opening_balance ELSE 0 END + COALESCE(le.before,0))::numeric(14,2),
         COALESCE(le.ins, 0)::numeric(14,2),
         COALESCE(le.outs, 0)::numeric(14,2),
         (CASE WHEN a.opening_date <= p_to THEN a.opening_balance ELSE 0 END
            + COALESCE(le.before,0) + COALESCE(le.ins,0) - COALESCE(le.outs,0))::numeric(14,2)
    FROM bms.accounts a
    LEFT JOIN le ON le.account_id = a.id
   WHERE a.is_active OR le.account_id IS NOT NULL
   ORDER BY CASE a.kind WHEN 'BANK' THEN 1 WHEN 'MOBILE_WALLET' THEN 2 WHEN 'CASH' THEN 3 ELSE 4 END, a.name;
END $$;

-- Every fund over the period: the earmark at the start, what was added,
-- what was used, the earmark at the end — and, for today, whether the
-- money behind it is really there.
CREATE OR REPLACE FUNCTION bms.report_funds(p_from date, p_to date)
RETURNS TABLE (fund_id uuid, code text, name text, fund_type text, purpose text,
               opening numeric(14,2), added numeric(14,2), used numeric(14,2),
               closing numeric(14,2), target_amount numeric(14,2),
               funded_now numeric(14,2), is_funded_now boolean, is_active boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('reports','view');
  PERFORM bms._report_range(p_from, p_to);
  RETURN QUERY
  WITH m AS (
    SELECT fm.fund_id,
           SUM(CASE WHEN fm.direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN') THEN fm.amount ELSE -fm.amount END)
             FILTER (WHERE fm.movement_date < p_from) AS before,
           SUM(fm.amount) FILTER (WHERE fm.movement_date BETWEEN p_from AND p_to
                                    AND fm.direction IN ('CONTRIBUTION','INTEREST','TRANSFER_IN')) AS added,
           SUM(fm.amount) FILTER (WHERE fm.movement_date BETWEEN p_from AND p_to
                                    AND fm.direction IN ('WITHDRAWAL','TRANSFER_OUT')) AS used
      FROM bms.fund_movements fm
     WHERE fm.movement_date <= p_to
     GROUP BY fm.fund_id
  )
  SELECT f.id, f.code, f.name, f.fund_type, f.purpose,
         (CASE WHEN f.opening_date <= p_to THEN f.opening_balance ELSE 0 END + COALESCE(m.before,0))::numeric(14,2),
         COALESCE(m.added,0)::numeric(14,2),
         COALESCE(m.used,0)::numeric(14,2),
         (CASE WHEN f.opening_date <= p_to THEN f.opening_balance ELSE 0 END
            + COALESCE(m.before,0) + COALESCE(m.added,0) - COALESCE(m.used,0))::numeric(14,2),
         f.target_amount::numeric(14,2),
         fb.funded_amount, fb.is_funded, f.is_active
    FROM bms.funds f
    LEFT JOIN m ON m.fund_id = f.id
    LEFT JOIN bms.v_fund_balances fb ON fb.fund_id = f.id
   WHERE f.is_active OR m.fund_id IS NOT NULL
   ORDER BY f.code;
END $$;

-- Service charge over the period. "Billed" is what was charged for the
-- months that fall in the period; "collected against it" is what has been
-- paid of those charges so far; "received" is cash that arrived in the
-- period, whatever month it paid for.
CREATE OR REPLACE FUNCTION bms.report_service_charge(p_from date, p_to date)
RETURNS TABLE (billed numeric(14,2), paid_against_billed numeric(14,2), collection_pct numeric(6,1),
               received_in_period numeric(14,2), receipts_in_period bigint,
               flat_months bigint, paid_full bigint, paid_partial bigint, unpaid bigint,
               outstanding_now numeric(14,2), advance_now numeric(14,2), flats_owing_now bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  PERFORM bms.assert_perm('reports','view');
  PERFORM bms._report_range(p_from, p_to);
  RETURN QUERY
  WITH ch AS (
    SELECT fc.net_payable, COALESCE(pa.paid, 0) AS paid
      FROM bms.flat_charges fc
      LEFT JOIN (SELECT flat_charge_id, SUM(amount) AS paid
                   FROM bms.payment_allocations GROUP BY flat_charge_id) pa ON pa.flat_charge_id = fc.id
     WHERE NOT fc.is_cancelled AND fc.charge_source <> 'OPENING'
       AND make_date(fc.period_year, fc.period_month, 1) BETWEEN date_trunc('month', p_from)::date AND p_to
  ), rc AS (
    SELECT COALESCE(SUM(p.amount),0) AS amt, COUNT(*) AS n
      FROM bms.payments p
     WHERE p.status = 'ACTIVE' AND p.payment_date BETWEEN p_from AND p_to
  ), du AS (
    SELECT COALESCE(SUM(outstanding),0) AS o, COALESCE(SUM(advance),0) AS a,
           COUNT(*) FILTER (WHERE outstanding > 0) AS n
      FROM bms.v_flat_dues
  )
  SELECT COALESCE(SUM(ch.net_payable),0)::numeric(14,2),
         COALESCE(SUM(LEAST(ch.paid, ch.net_payable)),0)::numeric(14,2),
         CASE WHEN COALESCE(SUM(ch.net_payable),0) > 0
              THEN ROUND(SUM(LEAST(ch.paid, ch.net_payable)) * 100.0 / SUM(ch.net_payable), 1)
              ELSE 0 END::numeric(6,1),
         (SELECT amt FROM rc)::numeric(14,2), (SELECT n FROM rc),
         COUNT(ch.*), COUNT(*) FILTER (WHERE ch.paid >= ch.net_payable),
         COUNT(*) FILTER (WHERE ch.paid > 0 AND ch.paid < ch.net_payable),
         COUNT(*) FILTER (WHERE ch.paid = 0 AND ch.net_payable > 0),
         (SELECT o FROM du)::numeric(14,2), (SELECT a FROM du)::numeric(14,2), (SELECT n FROM du)
    FROM ch;
END $$;

REVOKE ALL ON FUNCTION bms._report_range(date,date)           FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.report_income_expense(date,date)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.report_accounts(date,date)         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.report_funds(date,date)            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION bms.report_service_charge(date,date)   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bms._report_range(date,date)          TO authenticated;
GRANT EXECUTE ON FUNCTION bms.report_income_expense(date,date)  TO authenticated;
GRANT EXECUTE ON FUNCTION bms.report_accounts(date,date)        TO authenticated;
GRANT EXECUTE ON FUNCTION bms.report_funds(date,date)           TO authenticated;
GRANT EXECUTE ON FUNCTION bms.report_service_charge(date,date)  TO authenticated;

-- ---------------------------------------------------------------------
-- PART 3 — an LPG department, asked for by the building.
--
-- LPG billing stays in the separate LPG Ledger app. What lives here is
-- only the LPG emergency money: the balance kept to buy a cylinder before
-- the month's meter collection comes in, and refilled from it. Its own
-- department keeps those entries in a line of their own on every report
-- instead of mixed into the building's running costs. Seeded once; it is
-- ordinary data afterwards — rename it, hide it, or add to it in Settings.
-- ---------------------------------------------------------------------
INSERT INTO bms.departments (code, name, sort_order)
VALUES ('LPG', 'LPG (emergency fund)', 115)
ON CONFLICT (code) DO NOTHING;

INSERT INTO bms.categories (department_id, name, txn_type, sort_order)
SELECT d.id, v.name, v.txn_type, v.sort_order
  FROM bms.departments d
  CROSS JOIN (VALUES
    ('Cylinder bought from the emergency fund',     'EXPENSE', 10),
    ('Emergency fund repaid from LPG collection',   'INCOME',  20)
  ) AS v(name, txn_type, sort_order)
 WHERE d.code = 'LPG'
   AND NOT EXISTS (SELECT 1 FROM bms.categories c
                    WHERE c.department_id = d.id AND c.name = v.name AND c.parent_id IS NULL);
