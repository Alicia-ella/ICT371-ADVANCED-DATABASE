-- ICT371 Advanced Database
-- Question 5: Hostel Room Allocation (PostgreSQL)
-- Own schema (q05) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q05 CASCADE;
CREATE SCHEMA q05;
SET search_path = q05;

-- =====================================================================
-- (a) Tables
-- The CHECK on allocations ties status to released_on:
--   ACTIVE -> released_on must be NULL, ENDED -> must have a release date.
-- =====================================================================
CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT         NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id    INT         NOT NULL REFERENCES students (student_id),
    room_id       INT         NOT NULL REFERENCES rooms (room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
           (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT  NOT NULL REFERENCES rooms (room_id),
    occupied_beds INT  NOT NULL,
    free_beds     INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- =====================================================================
-- (b) Function: fn_free_beds
-- Only ACTIVE allocations use up beds, ENDED ones are history.
-- =====================================================================
CREATE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql
STABLE
SET search_path = q05
AS $$
DECLARE
    v_capacity INT;
    v_active   INT;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % does not exist', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- =====================================================================
-- (d) Trigger: capacity + one ACTIVE allocation per student
-- Works for direct INSERT/UPDATE too (not only through the procedure).
-- - Only checks rows that are ACTIVE (ENDED rows don't take a bed).
-- - Excludes the row being updated so it doesn't count against itself.
-- - Locks the student row and the room row first (always in that order)
--   so two sessions can't both grab the last bed or both give one student
--   two rooms.
-- =====================================================================
CREATE FUNCTION trg_fn_allocations_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q05
AS $$
DECLARE
    v_capacity INT;
    v_others   INT;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    PERFORM 1 FROM students WHERE student_id = NEW.student_id FOR NO KEY UPDATE;
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR NO KEY UPDATE;

    -- rule 1: student has only one ACTIVE allocation
    IF EXISTS (
        SELECT 1 FROM allocations a
        WHERE a.student_id = NEW.student_id
          AND a.status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    -- rule 2: room must not go over capacity
    SELECT COUNT(*) INTO v_others
    FROM allocations a
    WHERE a.room_id = NEW.room_id
      AND a.status = 'ACTIVE'
      AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

    IF v_others >= v_capacity THEN
        RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocations_rules();

-- =====================================================================
-- (c) Procedure: pr_allocate_room
-- Does the friendly checks first (clear messages); the trigger above is
-- the safety net that still guards the table if someone uses direct SQL.
-- =====================================================================
CREATE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
SET search_path = q05
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student % does not exist', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % does not exist', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- =====================================================================
-- (a, continued) Seed data
-- Room 101 (cap 2) = full, Room 102 (cap 3) = partly occupied,
-- Room 103 (cap 2) = empty. Student 5's old stay in room 103 is ENDED
-- history, so room 103 still shows as empty.
-- =====================================================================
INSERT INTO students (student_number, full_name) VALUES
    ('202402001', 'Chanda Mulenga'),
    ('202402002', 'Bwalya Phiri'),
    ('202402003', 'Mwansa Tembo'),
    ('202402004', 'Temwani Banda'),
    ('202402005', 'Natasha Zulu'),
    ('202402006', 'Kelvin Sakala');

INSERT INTO rooms (room_number, capacity) VALUES
    ('101', 2), ('102', 3), ('103', 2);

CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 55);   -- room 101 now full
CALL pr_allocate_room(3, 2, CURRENT_DATE - 30);   -- room 102 partly occupied
CALL pr_allocate_room(4, 2, CURRENT_DATE - 20);

-- ended history (direct insert, still goes through the trigger)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (5, 3, CURRENT_DATE - 200, CURRENT_DATE - 90, 'ENDED');

SELECT * FROM allocations ORDER BY allocation_id;

-- Tests for (b), (c), (d)
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;   -- 0, 1, 2
-- Each of these fails on purpose (run one at a time):
-- SELECT fn_free_beds(99);                                   -- unknown room
-- CALL pr_allocate_room(6, 1);                               -- room 101 is full
-- CALL pr_allocate_room(1, 3);                               -- student 1 already ACTIVE
-- CALL pr_allocate_room(99, 3);                              -- unknown student
-- INSERT INTO allocations (student_id, room_id, allocated_on) VALUES (6, 1, CURRENT_DATE);   -- direct SQL, trigger says full
-- INSERT INTO allocations (student_id, room_id, allocated_on) VALUES (1, 3, CURRENT_DATE);   -- direct SQL, second ACTIVE

-- Ending an allocation frees the bed (UPDATE path of the trigger):
-- UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE WHERE allocation_id = 1;

-- =====================================================================
-- (e) View: v_room_occupancy
-- LEFT JOIN so rooms with no active allocations still appear.
-- =====================================================================
CREATE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;

-- =====================================================================
-- (f) Partial index for ACTIVE allocations by room
-- The capacity check and occupancy counts always ask "how many ACTIVE
-- allocations in room X". The partial index holds only ACTIVE rows, so it
-- stays small (ENDED history is ignored) and finds a room's occupants fast.
-- =====================================================================
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- One row per date + room (the composite primary key). Upsert replaces
-- the values on a rerun.
-- =====================================================================
CREATE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
SET search_path = q05
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun: still 3 rows
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- Schedule: daily at 23:55 (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q05-refresh-occupancy',
    '55 23 * * *',
    $$CALL q05.pr_refresh_occupancy()$$
);
