-- =====================================================================
-- 052_funds_seed.sql — Phase 4/5 seed: turn on Budget and Reserve, set
-- up the default reserve fund, and register the notification rules.
-- =====================================================================

SET search_path = bms, public;

UPDATE bms.modules SET is_enabled = true WHERE code IN ('budget','reserve');

-- ---------------------------------------------------------------------
-- DEFAULT FUNDS
--
-- Two to start with, because they answer different questions: "can we
-- survive a bad month?" and "can we replace the lift when it dies?"
-- The committee can add more; these two are the ones every building
-- discovers it needed only after it needed them.
-- ---------------------------------------------------------------------
INSERT INTO bms.funds (code, name, fund_type, purpose, opening_balance, target_amount, notes)
VALUES
  ('RESERVE', 'General Reserve Fund', 'RESERVE',
   'Working reserve for unexpected building expenses',
   0, NULL,
   'Set a target amount once the committee agrees one. A common rule of thumb is three months of running cost.'),
  ('CAPEX', 'Capital Replacement Fund', 'SINKING',
   'Lift and generator replacement, major building repair',
   0, NULL,
   'Long-term. Money here is normally held in fixed deposits rather than the current account.')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- NOTIFICATION RULES
--
-- One row per alert the system can raise. `module_code` + `action` decide
-- WHO is told: a caretaker is not woken up about an unreconciled bank
-- statement, and a committee member is not asked to approve anything.
--
-- Turning an alert off is a single UPDATE here — no code change, and the
-- dashboard and the notification generator both stop showing it at once,
-- because they read the same table.
-- ---------------------------------------------------------------------
INSERT INTO bms.notification_rules (alert_type, title, severity, module_code, action) VALUES
  ('PENDING_APPROVAL',       'Expenses waiting for your approval',        'HIGH',   'finance',     'approve'),
  ('SERVICE_CHARGE_OVERDUE', 'Flats with overdue service charge',         'HIGH',   'charges',     'view'   ),
  ('PENDING_WAIVER',         'Waivers and adjustments awaiting decision', 'NORMAL', 'charges',     'waive'  ),
  ('SERVICE_OVERDUE',        'Equipment service overdue',                 'HIGH',   'maintenance', 'view'   ),
  ('SERVICE_DUE_SOON',       'Equipment service due soon',                'NORMAL', 'maintenance', 'view'   ),
  ('INSPECTION_OVERDUE',     'Fire extinguisher inspection overdue',      'HIGH',   'fire',        'view'   ),
  ('INSPECTION_DUE_SOON',    'Fire extinguisher inspection due soon',     'NORMAL', 'fire',        'view'   ),
  ('ISSUES_OVERDUE',         'Maintenance issues past their due date',    'HIGH',   'maintenance', 'view'   ),
  ('ISSUES_OPEN',            'Open maintenance issues',                   'LOW',    'maintenance', 'view'   ),
  ('ISSUES_TO_VERIFY',       'Completed work waiting to be verified',     'NORMAL', 'maintenance', 'approve'),
  ('GENERATOR_RUNNING',      'Generator run not yet closed',              'NORMAL', 'generator',   'view'   ),
  ('SALARY_UNPAID',          'Salaries generated but not yet paid',       'HIGH',   'salary',      'view'   ),
  ('WARRANTY_EXPIRING',      'Warranties expiring within 60 days',        'LOW',    'maintenance', 'view'   ),
  ('FD_MATURING',            'Fixed deposits maturing soon',              'HIGH',   'reserve',     'view'   ),
  ('BANK_UNRECONCILED',      'Bank statements not yet reconciled',        'NORMAL', 'bank',        'view'   ),
  ('OVER_BUDGET',            'Departments over budget',                   'HIGH',   'budget',      'view'   )
ON CONFLICT (alert_type) DO UPDATE
  SET title       = EXCLUDED.title,
      severity    = EXCLUDED.severity,
      module_code = EXCLUDED.module_code,
      action      = EXCLUDED.action;
