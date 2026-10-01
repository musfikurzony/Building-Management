-- =====================================================================
-- 020_audit.sql — one append-only log, written by a generic trigger so
-- no future developer has to remember to log anything.
-- =====================================================================

SET search_path = bms, public;

CREATE TABLE IF NOT EXISTS bms.audit_log (
  id                  bigserial PRIMARY KEY,
  occurred_at         timestamptz NOT NULL DEFAULT now(),
  actor_user_id       uuid,
  actor_name_snapshot text,          -- the name AS IT WAS at the time
  action              text NOT NULL,
  module_code         text,
  entity_table        text,
  entity_id           uuid,
  entity_label        text,          -- human string: "Flat A-103", "EXP-2026-0417"
  old_values          jsonb,
  new_values          jsonb,
  changed_fields      text[],
  severity            text NOT NULL DEFAULT 'NORMAL' CHECK (severity IN ('LOW','NORMAL','HIGH')),
  detail              text,
  user_agent          text
);
CREATE INDEX IF NOT EXISTS audit_time_idx   ON bms.audit_log(occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_entity_idx ON bms.audit_log(entity_table, entity_id);
CREATE INDEX IF NOT EXISTS audit_actor_idx  ON bms.audit_log(actor_user_id);
CREATE INDEX IF NOT EXISTS audit_sev_idx    ON bms.audit_log(severity) WHERE severity = 'HIGH';

-- Columns whose VALUES never enter the log. We record that they changed,
-- not what they changed to.
CREATE OR REPLACE FUNCTION bms.audit_mask(p_row jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(p_row, '{}'::jsonb)
         - 'account_number' - 'routing_number' - 'extra'
$$;

CREATE OR REPLACE FUNCTION bms.actor_name() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
  SELECT COALESCE(
    (SELECT up.full_name FROM bms.user_profiles up WHERE up.user_id = auth.uid()),
    (SELECT u.email      FROM auth.users u        WHERE u.id = auth.uid()),
    'system')
$$;

-- TG_ARGV[0] = module code, TG_ARGV[1] = label column, TG_ARGV[2] = severity
CREATE OR REPLACE FUNCTION bms.audit_trigger() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
DECLARE
  v_old jsonb; v_new jsonb; v_changed text[]; v_label text;
  v_module text := COALESCE(TG_ARGV[0], TG_TABLE_NAME);
  v_labelcol text := TG_ARGV[1];
  v_sev text := COALESCE(TG_ARGV[2], 'NORMAL');
  v_id uuid; v_action text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new := bms.audit_mask(to_jsonb(NEW)); v_action := 'INSERT';
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := bms.audit_mask(to_jsonb(OLD));
    v_new := bms.audit_mask(to_jsonb(NEW));
    SELECT array_agg(key ORDER BY key) INTO v_changed
      FROM jsonb_each(v_new) n
     WHERE key <> 'updated_at'
       AND n.value IS DISTINCT FROM (v_old -> n.key);
    IF v_changed IS NULL THEN RETURN NULL; END IF;   -- nothing meaningful changed
    v_action := 'UPDATE';
  ELSE
    v_old := bms.audit_mask(to_jsonb(OLD)); v_action := 'DELETE';
  END IF;

  BEGIN
    v_id := (COALESCE(v_new, v_old) ->> 'id')::uuid;
  EXCEPTION WHEN others THEN v_id := NULL; END;

  IF v_labelcol IS NOT NULL THEN
    v_label := COALESCE(v_new ->> v_labelcol, v_old ->> v_labelcol);
  END IF;

  -- A status change on a financial record is always worth flagging.
  IF v_changed IS NOT NULL AND 'status' = ANY(v_changed) THEN v_sev := 'HIGH'; END IF;

  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code,
                            entity_table, entity_id, entity_label,
                            old_values, new_values, changed_fields, severity)
  VALUES (auth.uid(), bms.actor_name(), v_action, v_module,
          TG_TABLE_NAME, v_id, v_label, v_old, v_new, v_changed, v_sev);
  RETURN NULL;
END $$;

-- Explicit events the database cannot see by itself (login, export, download).
CREATE OR REPLACE FUNCTION bms.log_event(
    p_action text, p_module text DEFAULT NULL, p_detail text DEFAULT NULL,
    p_entity_table text DEFAULT NULL, p_entity_id uuid DEFAULT NULL,
    p_entity_label text DEFAULT NULL, p_severity text DEFAULT 'NORMAL')
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = bms, public, pg_temp AS $$
BEGIN
  IF p_action NOT IN ('LOGIN','LOGOUT','LOGIN_FAILED','EXPORT','FILE_DOWNLOAD',
                      'FILE_UPLOAD','REPORT_VIEW','PERIOD_CLOSE','NOTE') THEN
    RAISE EXCEPTION 'Unsupported audit action %', p_action;
  END IF;
  INSERT INTO bms.audit_log(actor_user_id, actor_name_snapshot, action, module_code,
                            entity_table, entity_id, entity_label, detail, severity)
  VALUES (auth.uid(), bms.actor_name(), p_action, p_module,
          p_entity_table, p_entity_id, p_entity_label, p_detail, p_severity);
END $$;

-- ---------------------------------------------------------------------
-- Attach the trigger to everything that matters.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t record;
  spec text[][] := ARRAY[
    ['transactions',    'finance',  'txn_no',      'HIGH'],
    ['ledger_entries',  'finance',  NULL,          'HIGH'],
    ['accounts',        'bank',     'name',        'HIGH'],
    ['account_secrets', 'bank',     NULL,          'HIGH'],
    ['accounting_periods','finance',NULL,          'HIGH'],
    ['payments',        'charges',  'receipt_no',  'HIGH'],
    ['payment_allocations','charges',NULL,         'NORMAL'],
    ['flat_charges',    'charges',  NULL,          'NORMAL'],
    ['charge_runs',     'charges',  NULL,          'HIGH'],
    ['adjustments',     'charges',  NULL,          'HIGH'],
    ['flats',           'flats',    'flat_number', 'NORMAL'],
    ['owners',          'flats',    'name',        'NORMAL'],
    ['flat_occupancy',  'flats',    NULL,          'NORMAL'],
    ['vendors',         'finance',  'name',        'LOW'],
    ['departments',     'settings', 'name',        'NORMAL'],
    ['categories',      'settings', 'name',        'LOW'],
    ['budgets',         'budget',   NULL,          'NORMAL'],
    ['budget_lines',    'budget',   NULL,          'LOW'],
    ['roles',           'users',    'name',        'HIGH'],
    ['role_permissions','users',    NULL,          'HIGH'],
    ['user_roles',      'users',    NULL,          'HIGH'],
    ['user_profiles',   'users',    'full_name',   'HIGH'],
    ['building_settings','settings',NULL,          'HIGH'],
    ['attachments',     'finance',  'file_name',   'NORMAL'],
    ['assets',          'maintenance','asset_code','NORMAL'],
    ['asset_service_logs','maintenance',NULL,      'NORMAL'],
    ['asset_inspections','fire',     NULL,          'NORMAL'],
    ['generator_runs',  'generator', NULL,          'LOW'   ],
    ['fuel_purchases',  'generator', 'invoice_no',  'NORMAL'],
    ['issues',          'maintenance','issue_no',   'NORMAL'],
    ['staff',           'staff',     'name',        'HIGH'  ],
    ['staff_attendance','staff',     NULL,          'LOW'   ],
    ['staff_advances',  'salary',    NULL,          'HIGH'  ],
    ['salary_runs',     'salary',    NULL,          'HIGH'  ],
    ['salary_payments', 'salary',    NULL,          'HIGH'  ],
    ['work_logs',       'work',      NULL,          'LOW'   ],
    ['funds',           'reserve',   'name',        'HIGH'  ],
    ['fund_movements',  'reserve',   NULL,          'HIGH'  ],
    ['fixed_deposits',  'reserve',   'fd_no',       'HIGH'  ],
    ['fd_events',       'reserve',   NULL,          'HIGH'  ],
    ['bank_statements', 'bank',      NULL,          'NORMAL'],
    ['reconciliations', 'bank',      NULL,          'HIGH'  ],
    ['notification_rules','settings',  'title',     'LOW'   ]
  ];
  i int;
BEGIN
  FOR i IN 1 .. array_length(spec, 1) LOOP
    IF to_regclass('bms.' || spec[i][1]) IS NOT NULL THEN
      EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_%1$s ON bms.%1$s', spec[i][1]);
      EXECUTE format(
        'CREATE TRIGGER trg_audit_%1$s AFTER INSERT OR UPDATE OR DELETE ON bms.%1$s
           FOR EACH ROW EXECUTE FUNCTION bms.audit_trigger(%2$L, %3$s, %4$L)',
        spec[i][1], spec[i][2],
        CASE WHEN spec[i][3] IS NULL THEN 'NULL' ELSE quote_literal(spec[i][3]) END,
        spec[i][4]);
    END IF;
  END LOOP;
END $$;

-- The log is append-only for everyone, including admins.
CREATE OR REPLACE FUNCTION bms.block_audit_write() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'The audit log is append-only' USING ERRCODE = '42501';
END $$;
DROP TRIGGER IF EXISTS trg_audit_immutable ON bms.audit_log;
CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON bms.audit_log
  FOR EACH ROW EXECUTE FUNCTION bms.block_audit_write();
