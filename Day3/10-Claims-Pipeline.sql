/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #10 — The Claims Intake Pipeline                      (30 minutes)
1) Streams: change tracking on the Snowpipe landing table
2) A task graph: serverless root task, child task and finalizer
3) Dynamic tables: declarative transformation with a target lag
4) End to end: file → Snowpipe → stream → task → dynamic table
Prerequisite: Hands-on #06 (RAW.CLAIMS_FEED_RAW and CLAIMS_FEED_PIPE)
----------------------------------------------------------------------------------*/

/*
  FLOW
  @CLAIMS_LANDING ─(pipe)→ RAW.CLAIMS_FEED_RAW ─(stream)→ TASK T_LOAD_INTAKE
        → CORE.CLAIMS_INTAKE ─→ TASK T_SIU_QUEUE (child)       TASK T_FINALIZE (log)
        → ANALYTICS.DT_INTAKE_DAILY (dynamic table, TARGET_LAG)
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

USE ROLE accountadmin;
GRANT EXECUTE TASK, EXECUTE MANAGED TASK ON ACCOUNT TO ROLE sysadmin;

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ A Stream on the Landing Table
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- A stream is an offset, not a copy. APPEND_ONLY suits an insert-only landing
-- table and is cheaper to compute. SHOW_INITIAL_ROWS = TRUE makes the first
-- read return rows already in the table (the Hands-on #06 loads).

CREATE OR REPLACE STREAM smith_ins.raw.claims_feed_stream
    ON TABLE smith_ins.raw.claims_feed_raw
    APPEND_ONLY = TRUE
    SHOW_INITIAL_ROWS = TRUE;

SELECT COUNT(*) AS pending_rows FROM smith_ins.raw.claims_feed_stream;
SELECT SYSTEM$STREAM_HAS_DATA('smith_ins.raw.claims_feed_stream');

-- Reading a stream in a SELECT does NOT advance it — only committed DML does.
SELECT record:claim_id::STRING, METADATA$ACTION, METADATA$ISUPDATE
FROM smith_ins.raw.claims_feed_stream LIMIT 3;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Target Table and a Serverless Root Task
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- No WAREHOUSE → serverless task; Snowflake sizes compute from history.
-- WHEN SYSTEM$STREAM_HAS_DATA skips the run (no compute) if nothing arrived.
-- MERGE + QUALIFY makes the load idempotent if a claim arrives twice.

CREATE OR REPLACE TABLE claims_intake (
    claim_id         VARCHAR(20),
    policy_id        VARCHAR(12),
    holder_id        NUMBER(7),
    line_of_business VARCHAR(12),
    claim_type       VARCHAR(30),
    loss_date        DATE,
    reported_at      TIMESTAMP_NTZ,
    channel          VARCHAR(12),
    line_items       NUMBER,
    total_amount     NUMBER(12,2),
    intake_status    VARCHAR(12),        -- ACCEPTED | REJECTED
    reject_reason    VARCHAR(40),
    source_file      VARCHAR,
    processed_at     TIMESTAMP_LTZ
);

CREATE OR REPLACE TABLE pipeline_log (
    run_group_id VARCHAR, finished_at TIMESTAMP_LTZ, intake_rows NUMBER, rejected_rows NUMBER
);

CREATE OR REPLACE TASK t_load_intake
    SCHEDULE = '5 MINUTE'
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    WHEN SYSTEM$STREAM_HAS_DATA('smith_ins.raw.claims_feed_stream')
AS
MERGE INTO smith_ins.core.claims_intake t
USING (
    WITH s AS (                                   -- newest copy of each claim in the stream
        SELECT record, file_name, loaded_at
        FROM smith_ins.raw.claims_feed_stream
        QUALIFY ROW_NUMBER() OVER (PARTITION BY record:claim_id ORDER BY loaded_at DESC) = 1
    ),
    li AS (                                       -- total of the line-item array
        SELECT s.record:claim_id::STRING AS claim_id, SUM(f.value:amount::NUMBER(12,2)) AS total_amount
        FROM s, LATERAL FLATTEN(INPUT => s.record:line_items) f
        GROUP BY 1
    )
    SELECT s.record:claim_id::STRING                    AS claim_id,
           s.record:policy_id::STRING                   AS policy_id,
           s.record:claimant.holder_id::NUMBER          AS holder_id,
           s.record:line_of_business::STRING            AS line_of_business,
           s.record:claim_type::STRING                  AS claim_type,
           s.record:loss_date::DATE                     AS loss_date,
           s.record:reported_at::TIMESTAMP_NTZ          AS reported_at,
           s.record:channel::STRING                     AS channel,
           ARRAY_SIZE(s.record:line_items)              AS line_items,
           li.total_amount,
           CASE WHEN p.policy_id IS NULL                      THEN 'UNKNOWN_POLICY'
                WHEN s.record:loss_date::DATE > CURRENT_DATE() THEN 'FUTURE_LOSS_DATE' END AS reject_reason,
           s.file_name                                   AS source_file
    FROM s
    LEFT JOIN li                         ON li.claim_id = s.record:claim_id::STRING
    LEFT JOIN smith_ins.core.policies p  ON p.policy_id = s.record:policy_id::STRING
) src
ON t.claim_id = src.claim_id
WHEN NOT MATCHED THEN INSERT VALUES (
    src.claim_id, src.policy_id, src.holder_id, src.line_of_business, src.claim_type,
    src.loss_date, src.reported_at, src.channel, src.line_items, src.total_amount,
    IFF(src.reject_reason IS NULL, 'ACCEPTED', 'REJECTED'), src.reject_reason,
    src.source_file, CURRENT_TIMESTAMP());


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Child Task and Finalizer → a Task Graph
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- AFTER makes a dependency (a DAG). A FINALIZE task runs once when the graph
-- completes — success OR failure — ideal for logging, alerts and cleanup.
-- Resume children first; SYSTEM$TASK_DEPENDENTS_ENABLE does the whole graph.

CREATE OR REPLACE TABLE siu_review_queue (claim_id VARCHAR(20), total_amount NUMBER(12,2), queued_at TIMESTAMP_LTZ);

CREATE OR REPLACE TASK t_siu_queue
    AFTER t_load_intake
AS
INSERT INTO smith_ins.core.siu_review_queue
SELECT i.claim_id, i.total_amount, CURRENT_TIMESTAMP()
FROM smith_ins.core.claims_intake i
WHERE i.intake_status = 'ACCEPTED'
  AND i.total_amount > 7500
  AND NOT EXISTS (SELECT 1 FROM smith_ins.core.siu_review_queue q WHERE q.claim_id = i.claim_id);

CREATE OR REPLACE TASK t_finalize
    FINALIZE = t_load_intake
AS
INSERT INTO smith_ins.core.pipeline_log
SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'),
       CURRENT_TIMESTAMP(),
       (SELECT COUNT(*) FROM smith_ins.core.claims_intake),
       (SELECT COUNT_IF(intake_status = 'REJECTED') FROM smith_ins.core.claims_intake);

SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('smith_ins.core.t_load_intake');

-- Don't wait 5 minutes — run the graph now:
EXECUTE TASK t_load_intake;

-- Re-run until the graph shows SUCCEEDED (≈ 30–60 s):
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
        SCHEDULED_TIME_RANGE_START => DATEADD(minute, -15, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;

SELECT intake_status, reject_reason, COUNT(*) FROM claims_intake GROUP BY 1, 2;
SELECT COUNT(*) AS pending_rows FROM smith_ins.raw.claims_feed_stream;          -- 0: stream advanced
SELECT * FROM pipeline_log;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Dynamic Tables
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Declarative BATCH processing: write the SELECT, set a TARGET_LAG (a
-- freshness goal, not a schedule), and Snowflake works out the
-- refresh (incremental when it can). DOWNSTREAM = refresh only when a
-- consumer needs it. No streams or tasks to manage.

CREATE OR REPLACE DYNAMIC TABLE smith_ins.analytics.dt_intake_enriched
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE  = smith_wh
AS
SELECT i.claim_id, i.loss_date, i.channel, i.line_of_business, i.total_amount,
       r.region_name
FROM smith_ins.core.claims_intake i
JOIN smith_ins.core.policies p      ON p.policy_id = i.policy_id
JOIN smith_ins.core.policyholders h ON h.holder_id = p.holder_id
JOIN smith_ins.core.regions r       ON r.region_id = h.region_id
WHERE i.intake_status = 'ACCEPTED';

CREATE OR REPLACE DYNAMIC TABLE smith_ins.analytics.dt_intake_daily
    TARGET_LAG = '1 minute'
    WAREHOUSE  = smith_wh
AS
SELECT loss_date, region_name, line_of_business,
       COUNT(*) AS claims, SUM(total_amount) AS reported_amount
FROM smith_ins.analytics.dt_intake_enriched
GROUP BY 1, 2, 3;

SHOW DYNAMIC TABLES IN SCHEMA smith_ins.analytics;        -- target_lag, refresh_mode, scheduling_state

SELECT name, state, refresh_action, refresh_trigger, data_timestamp
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
ORDER BY data_timestamp DESC
LIMIT 10;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Standard vs. Append-Only Streams
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Create a STANDARD stream CLAIMS_INTAKE_CHANGES on CORE.CLAIMS_INTAKE.
--       Then UPDATE one REJECTED claim to ACCEPTED. Query the stream: how many
--       rows appear for that one update, and what are METADATA$ACTION and
--       METADATA$ISUPDATE on each?


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Inspect the Task Graph
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: (a) List the tasks in the graph with TASK_DEPENDENTS.
--       (b) From TASK_HISTORY, show each task's run duration in seconds for the
--           most recent graph run (use GRAPH_RUN_GROUP_ID).
--       (c) Why does T_SIU_QUEUE have no SCHEDULE of its own?


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Refresh Modes
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Create dynamic table ANALYTICS.DT_INTAKE_TOP_CLAIM returning the single
--       largest accepted claim per channel (QUALIFY ROW_NUMBER() ...) with
--       TARGET_LAG = '5 minutes'. Check its REFRESH_MODE with SHOW DYNAMIC
--       TABLES and compare it with DT_INTAKE_DAILY. Then run
--       ALTER DYNAMIC TABLE ... REFRESH to force a refresh.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — End-to-End Latency
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Push 2 new batches with Hands-on #06a (set batches = 2), then trigger
--       the graph with EXECUTE TASK (or wait for the schedule). For the new
--       claims, report the average seconds from REPORTED_AT → LOADED_AT (pipe),
--       LOADED_AT → PROCESSED_AT (task), and confirm they reached
--       DT_INTAKE_DAILY. Which stage dominates, and which setting would you
--       change to cut it?


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP  — stop everything that runs on a schedule (keep the tables)
================================================================================
*/
USE SCHEMA smith_ins.core;
ALTER TASK t_load_intake SUSPEND;
ALTER TASK t_siu_queue   SUSPEND;
ALTER TASK t_finalize    SUSPEND;
ALTER DYNAMIC TABLE smith_ins.analytics.dt_intake_daily    SUSPEND;
ALTER DYNAMIC TABLE smith_ins.analytics.dt_intake_enriched SUSPEND;
