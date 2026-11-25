-- ICT371 Advanced Database
-- Question 6: Monthly Payroll Processing (PostgreSQL)
-- Own schema (q06) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q06 CASCADE;
CREATE SCHEMA q06;
SET search_path = q06;

-- =====================================================================
-- (a) Tables
-- pay_month must be the first day of a month (CHECK on the day number).
-- UNIQUE (employee_id, pay_month) = one payroll row per employee per month.
-- =====================================================================
CREATE TABLE employees (
    employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees (employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT ck_pay_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees (employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- =====================================================================
-- (b) Function: fn_net_pay
-- net = basic + allowance - deduction. Negative net is rejected.
-- =====================================================================
CREATE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SET search_path = q06
AS $$
DECLARE
    v_basic NUMERIC;
    v_allow NUMERIC;
    v_deduc NUMERIC;
    v_net   NUMERIC;
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allow, v_deduc
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee % does not exist', p_employee_id;
    END IF;

    v_net := v_basic + v_allow - v_deduc;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Net pay for employee % would be negative (%)', p_employee_id, v_net;
    END IF;

    RETURN v_net;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_process_payroll
-- - FOR loop over the active employees.
-- - ON CONFLICT DO NOTHING leaves an existing month's row unchanged.
-- - If fn_net_pay raises for any employee, the exception aborts the whole
--   call, so rows inserted earlier in the loop are rolled back too.
-- =====================================================================
CREATE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
SET search_path = q06
AS $$
DECLARE
    r RECORD;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Month must be the first day of a month (got %)', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id,
                p_month,
                r.basic_salary + r.allowance,
                fn_net_pay(r.employee_id))
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- =====================================================================
-- (d) Trigger: log real basic_salary changes
-- =====================================================================
CREATE FUNCTION trg_fn_employees_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q06
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_employees_salary_audit();

-- =====================================================================
-- (a, continued) Seed data
-- Four employees; Natasha (4) is made inactive after September, so she
-- has a September payroll row but no October one.
-- =====================================================================
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chanda Mulenga', 8000.00, 1500.00, 1200.00, TRUE),
    ('Bwalya Phiri',   6500.00, 1000.00,  900.00, TRUE),
    ('Mwansa Tembo',   9500.00, 2000.00, 1800.00, TRUE),
    ('Natasha Zulu',   5000.00,  800.00,  600.00, TRUE),
    ('Kelvin Sakala',  4500.00,  500.00,  400.00, FALSE);   -- inactive from the start

CALL pr_process_payroll(DATE '2026-09-01');

UPDATE employees SET active = FALSE WHERE employee_id = 4;
CALL pr_process_payroll(DATE '2026-10-01');

SELECT * FROM payroll ORDER BY pay_month, employee_id;   -- Sept: 4 rows, Oct: 3 rows (Natasha is inactive)

-- Tests for (b), (c)
SELECT employee_id, fn_net_pay(employee_id) AS net FROM employees ORDER BY 1;
-- Rerun: nothing changes or duplicates
CALL pr_process_payroll(DATE '2026-10-01');
SELECT pay_month, COUNT(*) AS rows_for_month FROM payroll GROUP BY pay_month ORDER BY 1;

-- Each of these fails on purpose (run one at a time):
-- SELECT fn_net_pay(99);                                 -- unknown employee
-- CALL pr_process_payroll(DATE '2026-11-15');            -- not a month start
-- CALL pr_process_payroll(NULL);

-- Whole-call failure demo: a negative net aborts everything (shown inside a
-- transaction so the data is left untouched)
-- BEGIN;
--   UPDATE employees SET deduction = 99999 WHERE employee_id = 2;
--   CALL pr_process_payroll(DATE '2026-11-01');           -- ERROR: net pay negative
-- ROLLBACK;

-- Trigger check: a salary change is logged, an allowance-only change is not
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;
UPDATE employees SET allowance    = 1600.00 WHERE employee_id = 1;
SELECT * FROM salary_audit;     -- exactly 1 row (8000 -> 8500)

-- =====================================================================
-- (e) View: v_payroll_report
-- Inner join with NO filter on employees.active, so inactive employees'
-- earlier payroll rows still show up.
-- =====================================================================
CREATE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;   -- Natasha appears for September

-- =====================================================================
-- (f) Index on pay_month
-- The existing unique index is (employee_id, pay_month): employee_id is
-- the FIRST column, so it can't be used efficiently to find all employees
-- for one month. A separate index on pay_month alone fixes that, and it
-- doesn't repeat the unique index (different leading column).
-- =====================================================================
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job: 02:00 on the 1st of every month, for last month.
-- DATE_TRUNC('month', today - 1 month) = first day of the previous month.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q06-monthly-payroll',
    '0 2 1 * *',
    $$CALL q06.pr_process_payroll(DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::date)$$
);

-- How to inspect the job and its run history (pg_cron tables):
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q06-monthly-payroll';

SELECT jobid, status, start_time, end_time    -- real pg_cron also has return_message
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 10;

-- To remove the job later: SELECT cron.unschedule('q06-monthly-payroll');
