-- ICT371 Advanced Database
-- Question 1: Pharmacy Stock and Daily Sales (PostgreSQL)
--
-- Everything for this question lives in its own schema (q01) so the ten
-- question files can be run in the same database without clashing.
-- Each routine has SET search_path = q01 so it still works when pg_cron
-- calls it later (cron does not use my session's search_path).

DROP SCHEMA IF EXISTS q01 CASCADE;
CREATE SCHEMA q01;
SET search_path = q01;

-- =====================================================================
-- (a) Database (tables, keys, constraints)
-- =====================================================================
CREATE TABLE medicines (
    medicine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT           NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT           NOT NULL REFERENCES medicines (medicine_id),
    quantity    INT           NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),  -- price at time of sale
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT         NOT NULL REFERENCES medicines (medicine_id),
    old_qty     INT         NOT NULL,
    new_qty     INT         NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT           NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

-- =====================================================================
-- (b) Function: fn_sale_value
-- =====================================================================
CREATE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SET search_path = q01
AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine % does not exist', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_record_sale
-- The whole procedure is one transaction, so if any check fails the
-- exception rolls everything back and sales/medicines stay unchanged.
-- FOR UPDATE locks the medicine row so two sales can't both pass the
-- stock check at the same time (stops overselling).
-- =====================================================================
CREATE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
SET search_path = q01
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL';
    END IF;

    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine % does not exist', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Not enough stock for medicine % (available %, requested %)',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    -- store the CURRENT price on the sale row
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- =====================================================================
-- (d) Trigger: audit stock changes
-- WHEN clause means the trigger only fires if stock_qty really changed
-- (e.g. updating only the price does nothing).
-- =====================================================================
CREATE FUNCTION trg_fn_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q01
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_medicines_stock_audit();

-- =====================================================================
-- (a, continued) Seed data
-- Medicines are inserted directly; the six sales go through my
-- finished procedure so stock and the audit table update properly.
-- =====================================================================
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 5.00, 50),
    ('Amoxicillin 250mg', 12.50, 30),
    ('ORS Sachet',         3.00, 12);

CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2,  8, CURRENT_DATE - 2);
CALL pr_record_sale(2,  4, CURRENT_DATE - 1);
CALL pr_record_sale(3,  3, CURRENT_DATE - 1);
CALL pr_record_sale(3,  2, CURRENT_DATE - 1);

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;

-- Tests for (b) and (c)
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;      -- 37.50
-- These fail on purpose (uncomment one at a time to see the error):
-- SELECT fn_sale_value(99, 1);                -- unknown medicine
-- SELECT fn_sale_value(1, 0);                 -- invalid quantity
-- CALL pr_record_sale(1, 1000);               -- not enough stock, nothing changes

-- Trigger check: changing only the price must NOT create an audit row
UPDATE medicines SET unit_price = 5.50 WHERE medicine_id = 1;
SELECT count(*) AS audit_rows_after_price_change FROM stock_audit;   -- still 6

-- =====================================================================
-- (e) View: v_low_stock
-- =====================================================================
CREATE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- ORS Sachet already shows up (12 - 5 = 7)
SELECT * FROM v_low_stock;

-- one more sale pushes Amoxicillin below 10 as well (18 - 10 = 8)
CALL pr_record_sale(2, 10, CURRENT_DATE);
SELECT * FROM v_low_stock ORDER BY medicine_id;

-- =====================================================================
-- (f) Index
-- Queries look up ONE medicine and a RANGE of dates, so the equality
-- column (medicine_id) goes first and the range column (sold_on) second.
-- That lets PostgreSQL jump straight to that medicine's entries and read
-- the dates in order, instead of scanning every sale.
-- =====================================================================
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

-- The table is tiny so the planner would pick a seq scan anyway;
-- I turn seq scans off just to show the index is usable.
SET enable_seqscan = off;
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- INSERT ... ON CONFLICT DO UPDATE replaces the row for that day with
-- freshly calculated totals (it never adds to the old ones), so running
-- it again can't double count. A day with no sales gets zeros.
-- =====================================================================
CREATE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
SET search_path = q01
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Run it twice for the same day: totals stay the same
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales;     -- one row, qty 14, amount 5*5+12.5*4+3*5 = 90.00

-- Schedule: every day at 00:15 for the previous day (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q01-refresh-daily-sales',
    '15 0 * * *',
    $$CALL q01.pr_refresh_sales(CURRENT_DATE - 1)$$
);
