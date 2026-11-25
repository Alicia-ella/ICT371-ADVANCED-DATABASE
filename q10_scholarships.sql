-- ICT371 Advanced Database
-- Question 10: Scholarship Application Assessment (PostgreSQL)
-- Own schema (q10) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path = q10;

-- =====================================================================
-- (a) Tables
-- Eligibility rules (age 18-25, income <= K3,000, mark >= 70) are NOT
-- table constraints because applications that fail them are still valid
-- rows (they just get REJECTED). The table only blocks impossible values.
-- =====================================================================
CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id         INT           NOT NULL REFERENCES students (student_id),
    age_at_application INT           NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id INT         NOT NULL REFERENCES applications (application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- (b) Function: fn_scholarship_eligible
-- =====================================================================
CREATE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark cannot be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- =====================================================================
-- (d) Trigger: audit real status changes
-- =====================================================================
CREATE FUNCTION trg_fn_applications_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q10
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_applications_audit();

-- =====================================================================
-- (c) Procedure: pr_assess_application
-- FOR UPDATE locks the application row, so two assessments can't process
-- the same application twice. A completed one raises a clear error.
-- =====================================================================
CREATE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
SET search_path = q10
AS $$
DECLARE
    v_app applications%ROWTYPE;
BEGIN
    SELECT * INTO v_app
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;

    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)',
            p_application_id, v_app.status;
    END IF;

    UPDATE applications
    SET status = CASE
                    WHEN fn_scholarship_eligible(v_app.age_at_application,
                                                 v_app.monthly_income,
                                                 v_app.average_mark)
                    THEN 'APPROVED'
                    ELSE 'REJECTED'
                 END
    WHERE application_id = p_application_id;
END;
$$;

-- =====================================================================
-- (a, continued) Seed data: 3 students, 6 PENDING applications
-- Expected results are noted on each row.
-- =====================================================================
INSERT INTO students (student_number, full_name) VALUES
    ('202403001', 'Chanda Mulenga'),
    ('202403002', 'Bwalya Phiri'),
    ('202403003', 'Mwansa Tembo');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 22, 2000.00, 85.00, CURRENT_DATE - 10),   -- 1 clearly qualifies          -> APPROVED
    (1, 18, 3000.00, 70.00, CURRENT_DATE -  9),   -- 2 all three on the boundary -> APPROVED
    (2, 25, 2500.00, 75.50, CURRENT_DATE -  8),   -- 3 oldest allowed age        -> APPROVED
    (2, 26, 1000.00, 90.00, CURRENT_DATE -  7),   -- 4 too old                   -> REJECTED
    (3, 20, 3000.01, 80.00, CURRENT_DATE -  6),   -- 5 income just over          -> REJECTED
    (3, 21, 1500.00, 69.99, CURRENT_DATE -  5);   -- 6 mark just under           -> REJECTED

SELECT * FROM applications ORDER BY application_id;

-- Tests for (b)
SELECT fn_scholarship_eligible(18, 3000, 70)    AS all_boundaries,   -- true
       fn_scholarship_eligible(17, 1000, 90)    AS too_young,        -- false
       fn_scholarship_eligible(25, 3000.01, 90) AS income_over;      -- false
-- Each of these fails on purpose (run one at a time):
-- SELECT fn_scholarship_eligible(NULL, 1000, 80);
-- SELECT fn_scholarship_eligible(20, -1, 80);
-- SELECT fn_scholarship_eligible(0, 1000, 80);
-- SELECT fn_scholarship_eligible(20, 1000, 101);
-- CALL pr_assess_application(99);                              -- unknown application

-- Assess one by hand with the procedure
CALL pr_assess_application(1);
SELECT application_id, status FROM applications WHERE application_id = 1;   -- APPROVED
-- CALL pr_assess_application(1);                               -- fails: already assessed

-- Trigger check: an update that leaves the status unchanged must not create an audit row
UPDATE applications SET status = status WHERE application_id = 2;
SELECT * FROM decision_audit;    -- just the 1 row for application 1

-- =====================================================================
-- (e) View: v_approved_applicants (no household income)
-- =====================================================================
CREATE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- =====================================================================
-- (f) Index on (status, submitted_on)
-- The search is "this status, within a date range": equality on status
-- first, range on submitted_on second. The weekly job and officers mostly
-- look up PENDING applications, so this finds them without reading
-- already-decided ones.
-- =====================================================================
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job: pr_assess_pending
-- Query FOR loop over PENDING applications only. Each one goes through
-- pr_assess_application, which only accepts PENDING rows. Once assessed,
-- an application is no longer PENDING, so a rerun finds nothing to do and
-- no extra audit rows appear.
-- =====================================================================
CREATE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
SET search_path = q10
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;      -- 1,2,3 APPROVED; 4,5,6 REJECTED

SELECT * FROM v_approved_applicants ORDER BY student_number;
SELECT * FROM decision_audit ORDER BY audit_id; -- 6 rows (one per application)

CALL pr_assess_pending();                        -- rerun: nothing to assess
SELECT COUNT(*) AS audit_rows_after_rerun FROM decision_audit;   -- still 6

-- Schedule: every Monday at 08:00 (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q10-assess-pending',
    '0 8 * * 1',
    $$CALL q10.pr_assess_pending()$$
);
