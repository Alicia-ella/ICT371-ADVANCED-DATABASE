-- ICT371 Advanced Database
-- Question 7: Water Meter Readings and Billing (PostgreSQL)
-- Own schema (q07) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q07 CASCADE;
CREATE SCHEMA q07;
SET search_path = q07;

-- =====================================================================
-- (a) Tables
-- current_reading >= previous_reading is enforced by the trigger in (d).
-- amount_paid is kept between 0 and charge by a CHECK.
-- =====================================================================
CREATE TABLE customers (
    customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id      INT           NOT NULL REFERENCES customers (customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT ck_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id  INT           NOT NULL UNIQUE REFERENCES readings (reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

-- =====================================================================
-- (b) Function: fn_water_charge
-- First 10 units at K5, units above 10 at K8.
--   LEAST(u,10)*5 + GREATEST(u-10,0)*8
-- 0 units -> 0, exactly 10 -> 50, 12.5 -> 50 + 2.5*8 = 70.
-- =====================================================================
CREATE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption cannot be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be negative (got %)', p_units;
    END IF;

    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END;
$$;

-- =====================================================================
-- (d) Trigger: reject current_reading < previous_reading
-- BEFORE INSERT OR UPDATE + RAISE EXCEPTION means the row is never stored,
-- even for direct SQL or bulk imports.
-- =====================================================================
CREATE FUNCTION trg_fn_readings_check()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q07
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading (%) cannot be below previous reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_readings_check();

-- =====================================================================
-- (c) Procedure: pr_generate_bill
-- consumption = current - previous; charge comes from fn_water_charge.
-- =====================================================================
CREATE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
SET search_path = q07
AS $$
DECLARE
    v_prev NUMERIC;
    v_curr NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reading % does not exist', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END;
$$;

-- =====================================================================
-- (a, continued) Seed data: 3 customers, 6 readings
-- units used: 0, 10 (exactly), 12.5, 25, 4, 18
-- =====================================================================
INSERT INTO customers (full_name) VALUES
    ('Chanda Mulenga'), ('Bwalya Phiri'), ('Mwansa Tembo');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00),   -- 1: 0 units
    (1, DATE '2026-10-01', 100.00, 110.00),   -- 2: exactly 10
    (2, DATE '2026-09-01', 200.00, 212.50),   -- 3: 12.5 units
    (2, DATE '2026-10-01', 212.50, 237.50),   -- 4: 25 units
    (3, DATE '2026-09-01',  50.00,  54.00),   -- 5: 4 units
    (3, DATE '2026-10-01',  54.00,  72.00);   -- 6: 18 units

SELECT reading_id, current_reading - previous_reading AS units,
       fn_water_charge(current_reading - previous_reading) AS charge
FROM readings ORDER BY reading_id;
-- 0 -> 0.00, 10 -> 50.00, 12.5 -> 70.00, 25 -> 50+15*8 = 170.00, 4 -> 20.00, 18 -> 50+64 = 114.00

-- bills: some overdue, some not, some paid / partly paid
CALL pr_generate_bill(1, CURRENT_DATE - 40);   -- charge 0, nothing to pay
CALL pr_generate_bill(2, CURRENT_DATE - 10);   -- 50, overdue
CALL pr_generate_bill(3, CURRENT_DATE - 30);   -- 70, overdue
CALL pr_generate_bill(4, CURRENT_DATE + 10);   -- 170, not due yet
CALL pr_generate_bill(5, CURRENT_DATE - 25);   -- 20, will be fully paid
CALL pr_generate_bill(6, CURRENT_DATE - 5);    -- 114, overdue, partly paid

UPDATE bills SET amount_paid = charge WHERE reading_id = 5;     -- fully paid
UPDATE bills SET amount_paid = 50     WHERE reading_id = 6;     -- partly paid
UPDATE bills SET amount_paid = 20     WHERE reading_id = 3;     -- partly paid

SELECT * FROM bills ORDER BY bill_id;

-- Tests for (b), (c), (d)
-- Each of these fails on purpose (run one at a time):
-- SELECT fn_water_charge(NULL);
-- SELECT fn_water_charge(-1);
-- CALL pr_generate_bill(99, CURRENT_DATE);                -- unknown reading
-- CALL pr_generate_bill(2, CURRENT_DATE);                 -- already billed
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
--   VALUES (1, DATE '2026-11-01', 110, 100);              -- trigger rejects, row not stored
-- UPDATE bills SET amount_paid = 999 WHERE bill_id = 2;   -- paid more than charge (CHECK)

-- =====================================================================
-- (e) View: v_overdue_bills
-- =====================================================================
CREATE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings  r ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;
-- Chanda 50.00 (bill 2), Bwalya 50.00 (bill 3: 70-20), Mwansa 64.00 (bill 6: 114-50)

-- =====================================================================
-- (f) Partial index for unpaid bills by due date
-- Overdue searches only care about bills that are NOT fully paid. A
-- partial index (WHERE amount_paid < charge) holds only those rows, so it
-- stays small as paid bills pile up, and due_on in the index lets the
-- "due before today" range be read straight off it.
-- =====================================================================
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE
ORDER BY due_on;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job: today's total unpaid balance
-- Upsert, so a rerun on the same date replaces the total.
-- =====================================================================
CREATE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
SET search_path = q07
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE,
           COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun: same total, one row
SELECT * FROM receivable_snapshot;   -- 50 + 50 + 170 + 64 = 334.00

-- Schedule: daily at 00:30 (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q07-refresh-receivables',
    '30 0 * * *',
    $$CALL q07.pr_refresh_receivables()$$
);
