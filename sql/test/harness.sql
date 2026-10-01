-- Minimal test harness. Runs as the CALLING role (no SECURITY DEFINER),
-- so tests can SET ROLE authenticated and see real RLS behaviour.
CREATE SCHEMA IF NOT EXISTS t;
GRANT USAGE ON SCHEMA t TO PUBLIC;

DROP TABLE IF EXISTS t.results CASCADE;
CREATE TABLE t.results (
  id      serial PRIMARY KEY,
  suite   text,
  name    text,
  passed  boolean,
  detail  text
);
GRANT ALL ON t.results TO PUBLIC;
GRANT ALL ON SEQUENCE t.results_id_seq TO PUBLIC;

CREATE TABLE IF NOT EXISTS t.state (k text PRIMARY KEY, v text);
GRANT ALL ON t.state TO PUBLIC;

CREATE OR REPLACE FUNCTION t.suite() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT COALESCE(current_setting('t.suite', true), '?') $$;

CREATE OR REPLACE FUNCTION t.ok(p_name text, p_cond boolean, p_detail text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t.results(suite, name, passed, detail)
  VALUES (t.suite(), p_name, COALESCE(p_cond,false), p_detail);
END $$;

CREATE OR REPLACE FUNCTION t.record_eq(p_name text, p_expected text, p_actual text, p_same boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t.results(suite, name, passed, detail)
  VALUES (t.suite(), p_name, p_same,
          CASE WHEN p_same THEN NULL
               ELSE format('expected [%s], got [%s]',
                           COALESCE(p_expected,'NULL'), COALESCE(p_actual,'NULL')) END);
END $$;

-- Concrete overloads rather than anyelement, so a domain type such as
-- bms.money_amount coerces to its base type instead of failing to match.
CREATE OR REPLACE FUNCTION t.eq(p_name text, p_expected numeric, p_actual numeric)
RETURNS void LANGUAGE sql AS $$
  SELECT t.record_eq(p_name, p_expected::text, p_actual::text, p_expected IS NOT DISTINCT FROM p_actual) $$;

CREATE OR REPLACE FUNCTION t.eq(p_name text, p_expected int, p_actual int)
RETURNS void LANGUAGE sql AS $$
  SELECT t.record_eq(p_name, p_expected::text, p_actual::text, p_expected IS NOT DISTINCT FROM p_actual) $$;

CREATE OR REPLACE FUNCTION t.eq(p_name text, p_expected bigint, p_actual bigint)
RETURNS void LANGUAGE sql AS $$
  SELECT t.record_eq(p_name, p_expected::text, p_actual::text, p_expected IS NOT DISTINCT FROM p_actual) $$;

CREATE OR REPLACE FUNCTION t.eq(p_name text, p_expected text, p_actual text)
RETURNS void LANGUAGE sql AS $$
  SELECT t.record_eq(p_name, p_expected, p_actual, p_expected IS NOT DISTINCT FROM p_actual) $$;

CREATE OR REPLACE FUNCTION t.eq(p_name text, p_expected boolean, p_actual boolean)
RETURNS void LANGUAGE sql AS $$
  SELECT t.record_eq(p_name, p_expected::text, p_actual::text, p_expected IS NOT DISTINCT FROM p_actual) $$;

CREATE OR REPLACE FUNCTION t.eq(p_name text, p_expected uuid, p_actual uuid)
RETURNS void LANGUAGE sql AS $$
  SELECT t.record_eq(p_name, p_expected::text, p_actual::text, p_expected IS NOT DISTINCT FROM p_actual) $$;

CREATE OR REPLACE FUNCTION t.eq(p_name text, p_expected date, p_actual date)
RETURNS void LANGUAGE sql AS $$
  SELECT t.record_eq(p_name, p_expected::text, p_actual::text, p_expected IS NOT DISTINCT FROM p_actual) $$;

-- Runs a statement expecting it to FAIL, optionally with a message match.
CREATE OR REPLACE FUNCTION t.throws(p_name text, p_stmt text, p_expect text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
  BEGIN
    EXECUTE p_stmt;
    INSERT INTO t.results(suite, name, passed, detail)
    VALUES (t.suite(), p_name, false, 'expected an error, statement succeeded');
    RETURN;
  EXCEPTION WHEN others THEN
    v_msg := SQLERRM;
  END;
  INSERT INTO t.results(suite, name, passed, detail)
  VALUES (t.suite(), p_name,
          p_expect IS NULL OR position(lower(p_expect) in lower(v_msg)) > 0,
          CASE WHEN p_expect IS NULL OR position(lower(p_expect) in lower(v_msg)) > 0
               THEN NULL ELSE format('expected message like "%s", got "%s"', p_expect, v_msg) END);
END $$;

-- Runs a statement expecting it to SUCCEED.
CREATE OR REPLACE FUNCTION t.runs(p_name text, p_stmt text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_stmt;
  INSERT INTO t.results(suite, name, passed) VALUES (t.suite(), p_name, true);
EXCEPTION WHEN others THEN
  INSERT INTO t.results(suite, name, passed, detail)
  VALUES (t.suite(), p_name, false, SQLERRM);
END $$;

CREATE OR REPLACE FUNCTION t.remember(p_k text, p_v text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO t.state(k,v) VALUES (p_k,p_v)
  ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v
$$;

CREATE OR REPLACE FUNCTION t.recall(p_k text) RETURNS text
LANGUAGE sql STABLE AS $$ SELECT v FROM t.state WHERE k = p_k $$;

CREATE OR REPLACE FUNCTION t.uid(p_k text) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT t.recall(p_k)::uuid $$;
