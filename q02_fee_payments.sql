-- ICT371 Advanced Database
-- Question 2: University Fee Payments (PostgreSQL)
-- Own schema (q02) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q02 CASCADE;
CREATE SCHEMA q02;
SET search_path = q02;

-- =====================================================================
-- (a) Tables and constraints
-- fee_due can't be negative; amount must be positive. "No credit
-- balances" is enforced in the procedure (payment can't exceed balance).
-- =====================================================================
CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INT           NOT NULL REFERENCES students (student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id INT           NOT NULL REFERENCES payments (payment_id),
    student_id INT           NOT NULL REFERENCES students (student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT           NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

-- =====================================================================
-- (b) Function: fn_fee_balance
-- COALESCE(SUM(...), 0) handles a student with no payments.
-- =====================================================================
CREATE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SET search_path = q02
AS $$
DECLARE
    v_fee  NUMERIC;
    v_paid NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student % does not exist', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_receive_payment
-- Only inserts the payment. fee_due is never changed, and the audit row
-- comes from the trigger below (NOT from this procedure).
-- FOR UPDATE on the student row stops two payments sneaking past the
-- balance check at the same time.
-- =====================================================================
CREATE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
SET search_path = q02
AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero (got %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date cannot be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student % does not exist', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment of % is more than the outstanding balance of %', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER INSERT on payments writes the audit row
-- =====================================================================
CREATE FUNCTION trg_fn_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q02
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payments_audit();

-- =====================================================================
-- (a, continued) Seed data
-- Student 3 (Mwansa) has no payments yet. Payments go through the
-- procedure so the balance rule is checked and the trigger fills the audit.
-- =====================================================================
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202401001', 'Chanda Mulenga',  5000.00),
    ('202401002', 'Bwalya Phiri',    3500.00),
    ('202401003', 'Mwansa Tembo',    4200.00);

CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 5);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 2500.00, CURRENT_DATE - 1);   -- Bwalya is now fully settled
CALL pr_receive_payment(1,  250.00, CURRENT_DATE - 1);

SELECT * FROM students ORDER BY student_id;
SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;   -- 6 rows, written by the trigger

-- Tests for (b) and (c)
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1;
-- 1 -> 1750.00, 2 -> 0.00, 3 -> 4200.00 (full fee, no payments)
-- Each of these fails on purpose (run one at a time):
-- SELECT fn_fee_balance(99);                       -- unknown student
-- CALL pr_receive_payment(1, NULL);                -- NULL amount
-- CALL pr_receive_payment(1, 0);                   -- zero
-- CALL pr_receive_payment(1, -50);                 -- negative
-- CALL pr_receive_payment(1, 99999);               -- more than balance
-- CALL pr_receive_payment(2, 1);                   -- already settled, balance is 0

-- =====================================================================
-- (e) View: v_fee_balances (only students who still owe)
-- =====================================================================
CREATE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(p.total_paid, 0) AS outstanding_balance
FROM students s
LEFT JOIN (
    SELECT student_id, SUM(amount) AS total_paid
    FROM payments
    GROUP BY student_id
) p ON p.student_id = s.student_id
WHERE s.fee_due - COALESCE(p.total_paid, 0) > 0;

SELECT * FROM v_fee_balances ORDER BY student_number;   -- Bwalya is not listed

-- =====================================================================
-- (f) Composite index
-- Equality on student_id first, range on paid_on second. The index
-- entries for one student are stored in date order, so the date range is
-- one small slice. It also helps fn_fee_balance, which filters on student_id.
-- =====================================================================
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- Upsert: the day's row is replaced with recalculated values, so rerunning
-- gives the same answer and never doubles up.
-- =====================================================================
CREATE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
SET search_path = q02
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);   -- rerun: row is replaced, not added to
SELECT * FROM daily_collections;                  -- 3 payments, 500 + 2500 + 250 = 3250.00

-- Schedule: daily at 01:00 for the previous day (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q02-refresh-collections',
    '0 1 * * *',
    $$CALL q02.pr_refresh_collections(CURRENT_DATE - 1)$$
);
