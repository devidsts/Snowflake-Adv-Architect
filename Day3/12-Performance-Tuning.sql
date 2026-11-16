/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #12 — Performance Tuning the Claims Event Log         (30 minutes)
1) Micro-partition pruning and clustering depth
2) Natural ordering vs. a clustering key
3) Search optimization for point lookups
4) Finding the expensive query patterns
----------------------------------------------------------------------------------*/

/*
  SCENARIO
  Every claim produces a stream of events (FNOL, inspection, reserve change,
  payment, note...). CLAIM_EVENTS will hold ~30 million rows. Analysts filter by
  date; the call center looks up a single claim. Both are slow. Fix them.
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

USE ROLE sysadmin;
USE SCHEMA smith_ins.core;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;     -- measure real work, not the result cache

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Build a Large, Badly Ordered Table
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Rows are generated in random date order — like events arriving from many
-- systems out of order. Uses the LARGE ETL warehouse from Hands-on #03
-- (≈ 1 minute). Scale ROWCOUNT down for slower classes.

USE WAREHOUSE smith_etl_wh;

CREATE OR REPLACE TABLE claim_events AS
SELECT SEQ8()                                                              AS event_id,
       'CLM-' || LPAD(UNIFORM(1, 20000, RANDOM()), 7, '0')                 AS claim_id,
       DATEADD(second, UNIFORM(0, 155000000, RANDOM()), '2022-01-01'::TIMESTAMP_NTZ) AS event_ts,
       GET(ARRAY_CONSTRUCT('FNOL','INSPECTION','RESERVE_CHANGE','PAYMENT','NOTE','DOCUMENT','CLOSE'),
           UNIFORM(0, 6, RANDOM()))::STRING                                AS event_type,
       ROUND(UNIFORM(0, 500000, RANDOM()) / 100, 2)                        AS amount,
       UNIFORM(1, 10, RANDOM())                                            AS adjuster_id,
       RANDSTR(60, RANDOM())                                               AS payload
FROM TABLE(GENERATOR(ROWCOUNT => 30000000));

USE WAREHOUSE smith_wh;

SELECT SYSTEM$CLUSTERING_INFORMATION('claim_events', '(TO_DATE(event_ts))');
-- Look at total_partition_count, average_overlaps and average_depth: high depth
-- = almost every partition holds almost every date = no pruning.


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Measure Pruning
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- One week of events. Open the Query Profile, or read the TableScan operator
-- statistics programmatically.

SELECT event_type, COUNT(*), SUM(amount)
FROM claim_events
WHERE event_ts >= '2026-03-01' AND event_ts < '2026-03-08'
GROUP BY 1;

SELECT operator_type,
       operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total,
       execution_time_breakdown:overall_percentage::FLOAT     AS pct_time
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID()))
WHERE operator_type = 'TableScan';


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Order the Data — Two Ways
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- (a) A one-time sort on load (CTAS ... ORDER BY): free afterwards, but decays
--     as new, out-of-order rows arrive.
-- (b) A clustering key: Automatic Clustering keeps it ordered in the
--     background (serverless credits). Worth it for large, frequently
--     filtered, not-constantly-rewritten tables. Low/medium cardinality key —
--     a DATE, not the TIMESTAMP.

USE WAREHOUSE smith_etl_wh;
CREATE OR REPLACE TABLE claim_events_sorted AS
SELECT * FROM claim_events ORDER BY event_ts;
USE WAREHOUSE smith_wh;

SELECT event_type, COUNT(*), SUM(amount)
FROM claim_events_sorted
WHERE event_ts >= '2026-03-01' AND event_ts < '2026-03-08'
GROUP BY 1;

SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID()))
WHERE operator_type = 'TableScan';

SELECT SYSTEM$CLUSTERING_INFORMATION('claim_events_sorted', '(TO_DATE(event_ts))');

-- (b) The clustering key — defined now, maintained in the background:
ALTER TABLE claim_events_sorted CLUSTER BY (TO_DATE(event_ts));
SHOW TABLES LIKE 'CLAIM_EVENTS_SORTED';                -- cluster_by, automatic_clustering = ON


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Search Optimization for Point Lookups
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- The call center asks "show me every event for CLM-0004242". CLAIM_ID is
-- high-cardinality and random across partitions — clustering by date won't
-- help. The search optimization service builds a persistent search access
-- path (Enterprise+, serverless build + storage). Estimate before enabling.

SELECT * FROM claim_events_sorted WHERE claim_id = 'CLM-0004242' ORDER BY event_ts;
SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID())) WHERE operator_type = 'TableScan';

SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS('smith_ins.core.claim_events_sorted', 'EQUALITY(claim_id)');

ALTER TABLE claim_events_sorted ADD SEARCH OPTIMIZATION ON EQUALITY(claim_id);
SHOW TABLES LIKE 'CLAIM_EVENTS_SORTED';                -- search_optimization_progress → 100
-- The build takes a few minutes: continue with the exercises and come back
-- to Exercise 3.


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
  Keep USE_CACHED_RESULT = FALSE for the session.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Prune by Month
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Sum PAYMENT amounts for January 2025 from BOTH tables. For each run,
--       capture partitions scanned vs. total with GET_QUERY_OPERATOR_STATS.
--       Then wrap the filter in a function — WHERE TO_CHAR(event_ts,'YYYY-MM')
--       = '2025-01' — on the sorted table. Does pruning still work?


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ The Exploding Join
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: This query is slow and its total looks wrong. Run it, find the
--       operator where rows multiply (GET_QUERY_OPERATOR_STATS: output_rows
--       per operator), explain why, and rewrite it so it is fast AND correct.
--
--   SELECT c.line_of_business, SUM(p.amount) AS paid, COUNT(e.event_id) AS events
--   FROM claims c
--   JOIN claim_payments p      ON p.claim_id = c.claim_id
--   JOIN claim_events_sorted e ON e.claim_id = c.claim_id
--   GROUP BY 1;


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Did Search Optimization Help?
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: When SEARCH_OPTIMIZATION_PROGRESS reaches 100, re-run the Demo 4 point
--       lookup on a different claim and compare partitions scanned. Then run
--       the same lookup against CLAIM_EVENTS (no search optimization).


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Tune the Workload, Not the Query
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: As ACCOUNTADMIN, using SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY for the
--       whole class (last 3 days, your user only), group SELECT queries by
--       QUERY_PARAMETERIZED_HASH and return the top 5 patterns
--       by total elapsed time with execution count, average bytes scanned,
--       partitions scanned/total and any remote spill. For the top pattern,
--       name ONE design change (clustering, SOS, MV/dynamic table, warehouse
--       size, QAS) and justify it from the numbers.


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP — background services cost credits; turn them off after class
================================================================================
*/
ALTER SESSION UNSET USE_CACHED_RESULT;
ALTER TABLE smith_ins.core.claim_events_sorted DROP SEARCH OPTIMIZATION;
ALTER TABLE smith_ins.core.claim_events_sorted SUSPEND RECLUSTER;
ALTER WAREHOUSE smith_etl_wh SUSPEND;
