/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #10 — The Claims Intake Pipeline
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Standard vs. Append-Only Streams
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE STREAM claims_intake_changes ON TABLE claims_intake;

UPDATE claims_intake
SET intake_status = 'ACCEPTED', reject_reason = NULL
WHERE claim_id = (SELECT MIN(claim_id) FROM claims_intake WHERE intake_status = 'REJECTED');

SELECT claim_id, intake_status, METADATA$ACTION, METADATA$ISUPDATE
FROM claims_intake_changes;
-- [TEACHING NOTE]
-- Two rows: DELETE (old image) + INSERT (new image), both ISUPDATE = TRUE.
-- A standard stream returns the NET change since its offset — update a row
-- twice and you still see one DELETE/INSERT pair. Append-only streams ignore
-- updates and deletes entirely, which is why they suit landing tables.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Inspect the Task Graph
-- ──────────────────────────────────────────────────────────────────────────────
-- (a)
SELECT name, predecessors, state
FROM TABLE(INFORMATION_SCHEMA.TASK_DEPENDENTS(
        TASK_NAME => 'smith_ins.core.t_load_intake', RECURSIVE => TRUE));

-- (b)
WITH h AS (
    SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
            SCHEDULED_TIME_RANGE_START => DATEADD(hour, -2, CURRENT_TIMESTAMP())))
    WHERE database_name = 'SMITH_INS'
)
SELECT name, state, DATEDIFF(second, query_start_time, completed_time) AS seconds
FROM h
WHERE graph_run_group_id = (SELECT graph_run_group_id FROM h
                            WHERE name = 'T_LOAD_INTAKE' AND state = 'SUCCEEDED'
                            ORDER BY scheduled_time DESC LIMIT 1)
ORDER BY query_start_time;
-- (c) Only the root task has a schedule; children run when their predecessors
--     finish. All tasks in a graph share the owner role and database.
-- [TEACHING NOTE]
-- The finalizer shows in TASK_HISTORY too. Production monitoring uses
-- SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY / COMPLETE_TASK_GRAPHS (latency
-- applies) and SUSPEND_TASK_AFTER_NUM_FAILURES / TASK_AUTO_RETRY_ATTEMPTS.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Refresh Modes
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DYNAMIC TABLE smith_ins.analytics.dt_intake_top_claim
    TARGET_LAG = '5 minutes'
    WAREHOUSE  = smith_wh
AS
SELECT channel, claim_id, total_amount
FROM smith_ins.analytics.dt_intake_enriched
QUALIFY ROW_NUMBER() OVER (PARTITION BY channel ORDER BY total_amount DESC) = 1;

SHOW DYNAMIC TABLES LIKE 'DT_INTAKE%' IN SCHEMA smith_ins.analytics;
SELECT "name", "target_lag", "refresh_mode", "refresh_mode_reason"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

ALTER DYNAMIC TABLE smith_ins.analytics.dt_intake_top_claim REFRESH;
ALTER DYNAMIC TABLE smith_ins.analytics.dt_intake_top_claim SUSPEND;
-- [TEACHING NOTE]
-- REFRESH_MODE defaults to AUTO: Snowflake picks INCREMENTAL when the query
-- supports it, otherwise FULL, and REFRESH_MODE_REASON explains why. Aggregates
-- and joins are typically incremental. Students should verify, not assume.
-- Because DT_INTAKE_ENRICHED is DOWNSTREAM, it now refreshes for this table too.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — End-to-End Latency
-- ──────────────────────────────────────────────────────────────────────────────
-- 1) Run Hands-on #06a with batches = 2, wait ~1 minute for the pipe.
-- 2) EXECUTE TASK t_load_intake;  (wait ~1 minute)
SELECT COUNT(*)                                                     AS new_claims,
       ROUND(AVG(DATEDIFF(second, i.reported_at, r.loaded_at)))     AS sec_report_to_pipe,
       ROUND(AVG(DATEDIFF(second, r.loaded_at, i.processed_at)))    AS sec_pipe_to_task
FROM claims_intake i
JOIN smith_ins.raw.claims_feed_raw r ON r.record:claim_id::STRING = i.claim_id
WHERE i.processed_at > DATEADD(minute, -30, CURRENT_TIMESTAMP());

ALTER DYNAMIC TABLE smith_ins.analytics.dt_intake_daily REFRESH;
SELECT SUM(claims) FROM smith_ins.analytics.dt_intake_daily WHERE loss_date >= CURRENT_DATE() - 30;
-- [TEACHING NOTE]
-- REPORTED_AT is set when the generator builds the file, so stage 1 includes
-- file-write time plus Snowpipe's ~1-minute notification latency. Stage 2 is
-- dominated by the task SCHEDULE. Options: shorter schedule, a triggered task
-- (no SCHEDULE, runs when the stream has data). A dynamic table is still a
-- BATCH refresh (target lag of minutes or more) — fine for reporting, not for
-- seconds-latency needs. Note RAW timestamps are NTZ and
-- PROCESSED_AT is LTZ — align time zones before trusting the seconds.
