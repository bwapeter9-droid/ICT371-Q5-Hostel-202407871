-- =====================================================================
-- ICT371 Advanced Database | Student No: 202407871
-- QUESTION 5: Hostel Room Allocation  (50 marks)
-- Run with:  psql -d yourdb -f ICT371_202407871_Q5_Hostel.sql
-- Objects live in schema q5_hostel; the script can be re-run safely.
-- (The paper labels parts c and e as "€" - a typo; they are (c) and (e).)
-- =====================================================================
DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path TO q5_hostel, public;

-- ---------------------------------------------------------------------
-- (a) DATABASE AND SEED DATA [6]
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id      SERIAL       PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id      SERIAL      PRIMARY KEY,
    room_number  VARCHAR(10) NOT NULL UNIQUE,
    capacity     INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id  SERIAL      PRIMARY KEY,
    student_id     INTEGER     NOT NULL REFERENCES students(student_id),
    room_id        INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on   DATE        NOT NULL,
    released_on    DATE        NULL,
    status         VARCHAR(10) NOT NULL,
    CONSTRAINT chk_status CHECK (status IN ('ACTIVE', 'ENDED')),
    -- ACTIVE requires released_on NULL; ENDED requires a release date
    CONSTRAINT chk_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date  DATE    NOT NULL,
    room_id        INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds  INTEGER NOT NULL,
    free_beds      INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('2024101', 'Mary Chola'),
    ('2024102', 'John Mwale'),
    ('2024103', 'Grace Lubinda'),
    ('2024104', 'Peter Kunda'),
    ('2024105', 'Lucy Musonda');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),     -- will be FULL
    ('R102', 3),     -- PARTLY occupied
    ('R103', 2);     -- EMPTY

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (1, 1, CURRENT_DATE - 60, NULL,              'ACTIVE'),   -- R101 full (2/2)
    (2, 1, CURRENT_DATE - 55, NULL,              'ACTIVE'),
    (3, 2, CURRENT_DATE - 30, NULL,              'ACTIVE'),   -- R102 1/3
    (4, 2, CURRENT_DATE - 90, CURRENT_DATE - 20, 'ENDED');    -- history only, no bed used
-- Student 5 has no allocation yet; room R103 has none.

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_free_beds [6]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM   allocations
    WHERE  room_id = p_room_id AND status = 'ACTIVE';     -- ENDED rows ignored

    RETURN v_capacity - v_active;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_allocate_room [8]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- Lock the room row: two simultaneous allocations to one room queue up
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER BEFORE INSERT OR UPDATE [8]
-- Enforces the same rules for direct SQL. The row being updated is
-- excluded when counting "other" allocations.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        -- one ACTIVE allocation per student (excluding this row on UPDATE)
        IF EXISTS (SELECT 1 FROM allocations a
                   WHERE a.student_id = NEW.student_id
                     AND a.status = 'ACTIVE'
                     AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)) THEN
            RAISE EXCEPTION 'Student % already has another ACTIVE allocation', NEW.student_id;
        END IF;

        -- capacity (excluding this row on UPDATE)
        SELECT COUNT(*) INTO v_others
        FROM   allocations a
        WHERE  a.room_id = NEW.room_id
          AND  a.status = 'ACTIVE'
          AND  (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- ---------------------------------------------------------------------
-- (e) VIEW v_room_occupancy [5]
-- The ACTIVE filter is in the JOIN condition (not WHERE) so rooms with
-- no allocations still appear with 0 occupied beds.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)::INTEGER              AS occupied_beds,
       (r.capacity - COUNT(a.allocation_id))::INTEGER AS free_beds
FROM   rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- ---------------------------------------------------------------------
-- (f) INDEX [5]
-- Partial index: contains only ACTIVE rows, the only ones that occupy
-- beds. It is small and exactly serves the capacity check/occupancy count.
-- ---------------------------------------------------------------------
CREATE INDEX idx_allocations_room_active ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB [6]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM   v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;


-- Safe scheduling: runs only if pg_cron is available on this server.
-- If it is not installed you will just see a NOTICE and the rest of the script still works.
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q5_refresh_occupancy', '55 23 * * *', $cmd$CALL q5_hostel.pr_refresh_occupancy()$cmd$);
        RAISE NOTICE 'Job q5_refresh_occupancy scheduled: 55 23 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not installed on this server - job NOT scheduled. Schedule used: 55 23 * * *';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule job (q5_refresh_occupancy): %', SQLERRM;
END
$do$;

-- Inspect job / history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q5_refresh_occupancy';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- =====================================================================
-- TESTS / EVIDENCE
-- =====================================================================
SELECT '--- (a)/(e) Full, partly occupied and empty rooms ---' AS section;
SELECT * FROM v_room_occupancy ORDER BY room_id;

SELECT '--- (b) Function ---' AS section;
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;   -- 0, 2, 2
DO $$ BEGIN PERFORM fn_free_beds(999);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown room): %', SQLERRM; END $$;

SELECT '--- (c) Procedure ---' AS section;
DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown student): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(5, 99, CURRENT_DATE);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown room): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);                -- student 1 already ACTIVE
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (already active): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(4, 1, CURRENT_DATE);                -- R101 full
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (room full): %', SQLERRM; END $$;
CALL pr_allocate_room(5, 3, CURRENT_DATE);                            -- valid
SELECT * FROM allocations ORDER BY allocation_id;

SELECT '--- (d) Trigger: direct SQL ---' AS section;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)
            VALUES (4, 1, CURRENT_DATE, 'ACTIVE');                    -- R101 full
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (capacity, direct insert): %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)
            VALUES (1, 3, CURRENT_DATE, 'ACTIVE');                    -- student 1 already ACTIVE
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (one ACTIVE per student): %', SQLERRM; END $$;
DO $$ BEGIN UPDATE allocations SET room_id = 1 WHERE student_id = 3 AND status = 'ACTIVE';  -- move into full room
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (capacity, update): %', SQLERRM; END $$;
-- Updating a row inside the full room R101 must still work (it excludes itself):
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

SELECT '--- (e) View after allocation (R103 no longer empty) ---' AS section;
SELECT * FROM v_room_occupancy ORDER BY room_id;

SELECT '--- (f) EXPLAIN ---' AS section;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

SELECT '--- (g) Run twice: one row per date+room ---' AS section;
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY room_id;
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY room_id;                    -- same 3 rows
