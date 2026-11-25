-- ICT371 Advanced Database
-- Question 3: Library Returns and Overdue Fines (PostgreSQL)
-- Own schema (q03) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q03 CASCADE;
CREATE SCHEMA q03;
SET search_path = q03;

-- =====================================================================
-- (a) Tables
-- =====================================================================
CREATE TABLE books (
    book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id       INT           NOT NULL REFERENCES books (book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id          INT         NOT NULL REFERENCES loans (loan_id),
    old_returned_on  DATE        NULL,
    new_returned_on  DATE        NULL,
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT           NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

-- =====================================================================
-- (b) Function: fn_loan_fine
-- K2 per day after the due date. Returned on the due date -> 0.
-- If the book was returned, the clock stops at the return date, so I use
-- the EARLIER of p_as_of and returned_on.
-- =====================================================================
CREATE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SET search_path = q03
AS $$
DECLARE
    v_due       DATE;
    v_returned  DATE;
    v_end       DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date cannot be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % does not exist', p_loan_id;
    END IF;

    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_return_loan
-- Return date and final fine are written in ONE update statement, so they
-- always go together. The fine is calculated with the return date as the
-- as-of date (fn_loan_fine only looks at the stored row, so I compute the
-- same thing directly here before the row is updated).
-- =====================================================================
CREATE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql
SET search_path = q03
AS $$
DECLARE
    v_loan loans%ROWTYPE;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be NULL';
    END IF;

    SELECT * INTO v_loan FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % does not exist', p_loan_id;
    END IF;
    IF v_loan.returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_loan.returned_on;
    END IF;
    IF p_returned_on < v_loan.borrowed_on THEN
        RAISE EXCEPTION 'Return date % is before the borrow date %', p_returned_on, v_loan.borrowed_on;
    END IF;

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = 2 * GREATEST(p_returned_on - due_on, 0)
    WHERE loan_id = p_loan_id;
END;
$$;

-- =====================================================================
-- (d) Trigger: log changes to returned_on
-- The WHEN clause stops an audit row when the date didn't change.
-- =====================================================================
CREATE FUNCTION trg_fn_loans_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q03
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loans_audit();

-- =====================================================================
-- (a, continued) Seed data: 3 books, 6 loans
-- Dates are relative to today so the overdue examples stay overdue.
-- Loans 3, 4 and 6 are returned through the procedure (trigger is ready).
-- =====================================================================
INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Chanda Mulenga', CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue
    (2, 'Bwalya Phiri',   CURRENT_DATE -  5, CURRENT_DATE +  9),  -- 2 open, not due yet
    (3, 'Mwansa Tembo',   CURRENT_DATE - 20, CURRENT_DATE -  6),  -- 3 will be returned on time
    (1, 'Temwani Banda',  CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 4 will be returned late
    (2, 'Natasha Zulu',   CURRENT_DATE - 12, CURRENT_DATE -  2),  -- 5 open, overdue
    (3, 'Kelvin Sakala',  CURRENT_DATE - 25, CURRENT_DATE - 11);  -- 6 returned on the due date

CALL pr_return_loan(3, CURRENT_DATE - 8);    -- 2 days early, fine 0
CALL pr_return_loan(4, CURRENT_DATE - 20);   -- 6 days late, fine 12
CALL pr_return_loan(6, CURRENT_DATE - 11);   -- exactly on due date, fine 0

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;   -- 3 rows

-- Tests for (b)
SELECT loan_id,
       fn_loan_fine(loan_id, CURRENT_DATE)       AS fine_today,
       fn_loan_fine(loan_id, CURRENT_DATE + 10)  AS fine_in_10_days
FROM loans ORDER BY loan_id;
-- loan 1: 32 today (16 days) / 52 later; loan 4 stays 12 because it was returned
-- Each of these fails on purpose (run one at a time):
-- SELECT fn_loan_fine(99, CURRENT_DATE);                       -- unknown loan
-- CALL pr_return_loan(99, CURRENT_DATE);                       -- unknown loan
-- CALL pr_return_loan(3, CURRENT_DATE);                        -- already returned
-- CALL pr_return_loan(1, CURRENT_DATE - 60);                   -- before borrowed_on

-- Trigger check: updating a different column must not create an audit row
UPDATE loans SET borrower_name = 'Chanda M. Mulenga' WHERE loan_id = 1;
SELECT count(*) AS audit_rows FROM loan_audit;   -- still 3

-- =====================================================================
-- (e) View: v_overdue_loans
-- =====================================================================
CREATE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY loan_id;   -- loans 1 and 5

-- =====================================================================
-- (f) Index for "unreturned loans of a given book"
-- A partial index only stores rows where returned_on IS NULL, i.e. open
-- loans. It stays small even when most loans are old returned ones, and
-- the book_id lookup goes straight to the open loans of that book.
-- =====================================================================
CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- "Still unreturned as of that date" = not returned yet, or returned
-- after p_as_of. I only count the overdue ones (due before p_as_of) since
-- the table is overdue_summary. fn_loan_fine(…, p_as_of) already stops the
-- fine at p_as_of for loans returned later. The upsert replaces the same
-- snapshot_date on a rerun.
-- =====================================================================
CREATE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
SET search_path = q03
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date cannot be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces the row
SELECT * FROM overdue_summary;           -- 2 loans, 32 + 4 = 36.00

-- Schedule: every day at 00:10 for CURRENT_DATE (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q03-refresh-overdue',
    '10 0 * * *',
    $$CALL q03.pr_refresh_overdue(CURRENT_DATE)$$
);
