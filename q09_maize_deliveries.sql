-- ICT371 Advanced Database
-- Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL)
-- Own schema (q09) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q09 CASCADE;
CREATE SCHEMA q09;
SET search_path = q09;

-- =====================================================================
-- (a) Tables
-- unit_rate and total_value are NOT supplied by the user: the trigger
-- fills them in. (A BEFORE trigger runs before the NOT NULL check, so
-- leaving them out of an INSERT works fine.)
-- =====================================================================
CREATE TABLE farmers (
    farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_id    INT           NOT NULL REFERENCES farmers (farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,
    total_value  NUMERIC(12,2) NOT NULL,
    delivered_on DATE          NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

-- =====================================================================
-- (b) Function: fn_maize_rate  (A = K5, B = K4, C = K3 per kg)
-- =====================================================================
CREATE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE p_grade
        WHEN 'A' THEN RETURN 5;
        WHEN 'B' THEN RETURN 4;
        WHEN 'C' THEN RETURN 3;
        ELSE RAISE EXCEPTION 'Unsupported grade "%" (use A, B or C)', p_grade;
    END CASE;
END;
$$;

-- =====================================================================
-- (d) Trigger: one place for the pricing rule
-- Runs for BOTH the procedure and direct SQL, on INSERT and UPDATE, so
-- the rate and value can never be set by hand or go out of date (e.g. if
-- someone changes the weight or grade later, the value is recalculated).
-- =====================================================================
CREATE FUNCTION trg_fn_deliveries_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q09
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_deliveries_pricing();

-- =====================================================================
-- (c) Procedure: pr_receive_delivery
-- Inserts only the basic fields with is_paid = false. unit_rate and
-- total_value are left out on purpose: the trigger supplies them.
-- =====================================================================
CREATE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
SET search_path = q09
AS $$
BEGIN
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL';
    END IF;

    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Farmer % does not exist', p_farmer_id;
    END IF;

    PERFORM fn_maize_rate(p_grade);   -- rejects NULL or an unsupported grade with a clear message

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- =====================================================================
-- (a, continued) Seed data (loaded after the trigger exists)
-- Direct INSERTs without rate/value: the trigger fills them in.
-- All three grades, paid and unpaid. Farmer 3 has only paid deliveries.
-- =====================================================================
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Chanda Mulenga'),
    ('F002', 'Bwalya Phiri'),
    ('F003', 'Mwansa Tembo');

INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 120.50, CURRENT_DATE - 3, FALSE),
    (1, 'B',  80.00, CURRENT_DATE - 2, TRUE),
    (2, 'C', 200.00, CURRENT_DATE - 1, FALSE),
    (2, 'A',  45.25, CURRENT_DATE - 1, FALSE),
    (3, 'B', 150.00, CURRENT_DATE - 1, TRUE),
    (3, 'C',  60.00, CURRENT_DATE - 3, TRUE);

SELECT * FROM deliveries ORDER BY delivery_id;

-- Tests for (b), (c), (d)
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
-- Each of these fails on purpose (run one at a time):
-- SELECT fn_maize_rate(NULL);
-- SELECT fn_maize_rate('D');
-- CALL pr_receive_delivery(99, 'A', 10);                       -- unknown farmer
-- CALL pr_receive_delivery(1, 'A', -5);                        -- invalid weight
-- CALL pr_receive_delivery(1, 'Z', 10);                        -- unsupported grade
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value)
--   VALUES (1, 'A', 0, 5, 0);                                  -- direct SQL, weight rejected

-- Trigger overrides hand-typed pricing (direct SQL follows the same rule)
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (3, 'A', 10, 99, 99999, CURRENT_DATE);                  -- rate/value are replaced: 5.00 / 50.00
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;

-- Procedure path
CALL pr_receive_delivery(1, 'B', 100, CURRENT_DATE);            -- 4.00 / 400.00, unpaid
SELECT delivery_id, grade, weight_kg, unit_rate, total_value, is_paid
FROM deliveries WHERE delivery_id = 8;

-- =====================================================================
-- (e) View: v_farmer_amount_due
-- LEFT JOIN + FILTER keeps farmers with nothing unpaid, with amount 0.
-- =====================================================================
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;
-- F001: 602.50 + 400 = 1002.50, F002: 600 + 226.25 = 826.25,
-- F003: 50.00 (only the direct-SQL test row above is unpaid; the rest are paid)

-- =====================================================================
-- (f) Composite index on (farmer_id, delivered_on)
-- "One farmer's deliveries between two dates": equality on farmer_id
-- first, range on delivered_on second, so the matching deliveries are one
-- ordered slice of the index.
-- =====================================================================
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- Recalculates the day's totals from deliveries and replaces the row, so
-- reruns never add on top of old totals.
-- =====================================================================
CREATE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
SET search_path = q09
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun: same numbers
SELECT * FROM daily_purchases;   -- 200 + 45.25 + 150 = 395.25 kg; 600 + 226.25 + 600 = 1426.25

-- Schedule: daily at 01:30 for the previous day (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q09-refresh-purchases',
    '30 1 * * *',
    $$CALL q09.pr_refresh_purchases(CURRENT_DATE - 1)$$
);
