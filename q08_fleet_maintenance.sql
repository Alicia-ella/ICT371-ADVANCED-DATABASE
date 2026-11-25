-- ICT371 Advanced Database
-- Question 8: Transport Fleet Maintenance (PostgreSQL)
-- Own schema (q08) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q08 CASCADE;
CREATE SCHEMA q08;
SET search_path = q08;

-- =====================================================================
-- (a) Tables
-- =====================================================================
CREATE TABLE vehicles (
    vehicle_id             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INT         NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INT         NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id     INT  NOT NULL REFERENCES vehicles (vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT  NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT  NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id      INT PRIMARY KEY REFERENCES vehicles (vehicle_id),
    km_since_service INT  NOT NULL,
    flagged_on      DATE NOT NULL DEFAULT CURRENT_DATE
);

-- =====================================================================
-- (b) Function: fn_service_due  (5,000 km or more since last service)
-- =====================================================================
CREATE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = q08
AS $$
DECLARE
    v_current INT;
    v_service INT;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_service
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle % does not exist', p_vehicle_id;
    END IF;

    RETURN (v_current - v_service) >= 5000;
END;
$$;

-- =====================================================================
-- (d) Trigger: BEFORE INSERT on trips
-- Checks the trip, then moves the vehicle's odometer to the trip end.
-- Because it is a BEFORE INSERT trigger it runs once per inserted trip
-- row, so the odometer is updated exactly once (and the procedure does
-- NOT touch the odometer itself).
-- FOR UPDATE locks the vehicle row so two trips for the same vehicle
-- can't both start from the same odometer value.
-- =====================================================================
CREATE FUNCTION trg_fn_trips_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q08
AS $$
DECLARE
    v_current INT;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle % does not exist', NEW.vehicle_id;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer (%) but starts at %',
            v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trips_odometer();

-- =====================================================================
-- (c) Procedure: pr_record_trip
-- Validates the vehicle and the mileage, then inserts the trip. It does
-- not update the vehicle: the trigger does that.
-- =====================================================================
CREATE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql
SET search_path = q08
AS $$
BEGIN
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer cannot be NULL';
    END IF;

    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle % does not exist', p_vehicle_id;
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- =====================================================================
-- (a, continued) Seed data
-- Three vehicles in different service positions. The six trips are added
-- through the procedure now that the trigger exists, so each one moves the
-- odometer forward.
--   V1: 12000 / last service 10000  -> 2,000 km since service
--   V2: 20000 / last service 14000  -> 6,000 km since service (already due)
--   V3:  4400 / last service     0  -> 4,400 km since service
-- =====================================================================
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAK 1234', 12000, 10000),
    ('BAL 5678', 20000, 14000),
    ('BAM 9012',  4400,     0);

CALL pr_record_trip(1, CURRENT_DATE - 6, 12000, 12400);
CALL pr_record_trip(1, CURRENT_DATE - 3, 12400, 12900);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20300, 20800);
CALL pr_record_trip(3, CURRENT_DATE - 4, 4400, 4700);
CALL pr_record_trip(3, CURRENT_DATE - 1, 4700, 5000);   -- V3 lands on exactly 5,000 km

SELECT * FROM vehicles ORDER BY vehicle_id;   -- 12900, 20800, 5000
SELECT * FROM trips ORDER BY trip_id;

-- Tests for (b), (c), (d)
SELECT vehicle_id, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;
-- V1 false (2,900 km), V2 true (6,800 km), V3 true (exactly 5,000, boundary counts)
-- Each of these fails on purpose (run one at a time):
-- SELECT fn_service_due(99);                                   -- unknown vehicle
-- CALL pr_record_trip(99, CURRENT_DATE, 0, 10);                -- unknown vehicle
-- CALL pr_record_trip(1, CURRENT_DATE, 12900, 12900);          -- end not greater than start
-- CALL pr_record_trip(1, CURRENT_DATE, 12000, 13000);          -- start isn't current odometer (trigger)
-- INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
--   VALUES (1, CURRENT_DATE, 12900, 12800);                    -- direct SQL, bad mileage (trigger)

-- =====================================================================
-- (e) View: v_service_due
-- =====================================================================
CREATE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;   -- BAL 5678 (6800) and BAM 9012 (5000)

-- =====================================================================
-- (f) Index on (vehicle_id, trip_on)
-- A vehicle's trip history is asked for as "this vehicle, between two
-- dates": equality column first, range column second, so one vehicle's
-- trips are read in date order from one slice of the index.
-- =====================================================================
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- Step 1: upsert an alert for every due vehicle (flagged_on keeps the date
--         it was FIRST flagged; only the km figure is refreshed).
-- Step 2: delete alerts for vehicles that are no longer due (after a service).
-- Both steps are in one procedure call, so they succeed or fail together.
-- =====================================================================
CREATE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
SET search_path = q08
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           current_odometer - last_service_odometer,
           CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa
    USING vehicles v
    WHERE v.vehicle_id = sa.vehicle_id
      AND v.current_odometer - v.last_service_odometer < 5000;
END;
$$;

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();   -- rerun: still one row per due vehicle
SELECT * FROM service_alerts ORDER BY vehicle_id;   -- V2 and V3

-- Servicing V2 makes it not due, so its alert disappears on the next run.
-- (Done inside a transaction and rolled back so the seed data stays as is.)
BEGIN;
    UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
    CALL pr_refresh_service_alerts();
    SELECT * FROM service_alerts ORDER BY vehicle_id;   -- only V3 left
ROLLBACK;

-- Schedule: every Monday at 06:00 (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q08-refresh-service-alerts',
    '0 6 * * 1',
    $$CALL q08.pr_refresh_service_alerts()$$
);
