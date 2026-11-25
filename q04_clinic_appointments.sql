-- ICT371 Advanced Database
-- Question 4: Clinic Appointment Scheduling (PostgreSQL)
-- Own schema (q04) + SET search_path on every routine so pg_cron can run them.

DROP SCHEMA IF EXISTS q04 CASCADE;
CREATE SCHEMA q04;
SET search_path = q04;

-- =====================================================================
-- (a) Tables
-- slot_time is a TIME and is limited to the four allowed slots.
-- =====================================================================
CREATE TABLE patients (
    patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      INT         NOT NULL REFERENCES patients (patient_id),
    doctor_id       INT         NOT NULL REFERENCES doctors (doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date   DATE PRIMARY KEY,
    booked_count   INT NOT NULL,
    attended_count INT NOT NULL,
    cancelled_count INT NOT NULL
);

-- =====================================================================
-- (b) Function: fn_daily_load
-- COUNT(*) returns 0 when there are no rows, so an empty day gives 0.
-- =====================================================================
CREATE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql
STABLE
SET search_path = q04
AS $$
DECLARE
    v_count INT;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor % does not exist', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- =====================================================================
-- (d) Trigger (created before the procedure and seed data so every
-- insert is protected). Rejects a clash with another non-cancelled
-- appointment for the same doctor, date and slot.
-- - On UPDATE the row being changed is excluded from the search.
-- - Cancelled rows never clash and are never blocked.
-- - It locks the doctor row first (FOR NO KEY UPDATE) so two sessions
--   booking the same slot at the same moment are handled one at a time.
-- =====================================================================
CREATE FUNCTION trg_fn_appointments_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q04
AS $$
BEGIN
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = NEW.doctor_id FOR NO KEY UPDATE;

    IF EXISTS (
        SELECT 1
        FROM appointments a
        WHERE a.doctor_id       = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time       = NEW.slot_time
          AND a.status         <> 'CANCELLED'
          AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
    ) THEN
        RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointments_clash();

-- =====================================================================
-- (c) Procedure: pr_book_appointment
-- Validates IDs, past date, slot. The slot clash itself is caught by the
-- trigger when the INSERT runs.
-- =====================================================================
CREATE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql
SET search_path = q04
AS $$
BEGIN
    IF p_day IS NULL OR p_slot IS NULL THEN
        RAISE EXCEPTION 'Day and slot cannot be NULL';
    END IF;

    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient % does not exist', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor % does not exist', p_doctor_id;
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book an appointment in the past (%)', p_day;
    END IF;

    IF p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Slot % is not supported (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- =====================================================================
-- (a, continued) Seed data: 3 patients, 3 doctors, 6 appointments
-- Past appointments (attended / cancelled) are inserted directly because
-- the procedure refuses past dates. Today and future ones use the procedure.
-- =====================================================================
INSERT INTO patients (full_name) VALUES
    ('Chanda Mulenga'), ('Bwalya Phiri'), ('Mwansa Tembo');
INSERT INTO doctors (full_name) VALUES
    ('Dr. Banda'), ('Dr. Zulu'), ('Dr. Mumba');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED'),
    (3, 2, CURRENT_DATE - 1, '09:00', 'CANCELLED');

CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, '11:00');

SELECT * FROM appointments ORDER BY appointment_id;

-- Tests for (b), (c), (d)
SELECT fn_daily_load(1, CURRENT_DATE)     AS dr_banda_today,        -- 1
       fn_daily_load(2, CURRENT_DATE - 1) AS dr_zulu_yesterday,     -- 0 (only a cancelled one)
       fn_daily_load(3, CURRENT_DATE + 5) AS dr_mumba_empty_day;    -- 0
-- Each of these fails on purpose (run one at a time):
-- SELECT fn_daily_load(99, CURRENT_DATE);                      -- unknown doctor
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');       -- clash (trigger)
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '11:00');   -- past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, '13:00');       -- unsupported slot
-- CALL pr_book_appointment(99, 1, CURRENT_DATE, '11:00');      -- unknown patient

-- UPDATE case: moving appointment 4 onto Dr. Zulu's 10:00 today clashes with appointment 5
-- UPDATE appointments SET doctor_id = 2, slot_time = '10:00' WHERE appointment_id = 4;
-- but updating an appointment without changing its slot is fine (it ignores itself):
UPDATE appointments SET patient_id = 3 WHERE appointment_id = 4;
UPDATE appointments SET patient_id = 1 WHERE appointment_id = 4;

-- A cancelled slot can be rebooked: appointment 3 (cancelled) held Dr. Zulu 09:00 yesterday
-- INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time)
--   VALUES (1, 2, CURRENT_DATE - 1, '09:00');   -- would be allowed

-- =====================================================================
-- (e) View: v_today_appointments
-- Only names and the slot are shown (no other patient details).
-- =====================================================================
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- =====================================================================
-- (f) Non-unique index on (appointment_day, doctor_id)
-- The clinic looks up "this day, this doctor" (daily load, clash check,
-- schedules), so both columns are equality filters and the index finds
-- those few rows directly. It's non-unique because many appointments
-- (different slots) share the same day and doctor.
-- =====================================================================
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;   -- tiny table, so force the planner to show the index
EXPLAIN
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- COUNT(*) FILTER (WHERE ...) gives the three status counts in one pass.
-- ON CONFLICT replaces that date's summary on a rerun.
-- =====================================================================
CREATE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
SET search_path = q04
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM clinic_summary;                        -- booked 0, attended 2, cancelled 1

-- Schedule: daily at 01:00 for the previous day (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q04-refresh-clinic-summary',
    '0 1 * * *',
    $$CALL q04.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$
);
