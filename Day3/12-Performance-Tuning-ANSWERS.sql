/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #12 — Performance Tuning the Claims Event Log
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Prune by Month
-- ──────────────────────────────────────────────────────────────────────────────
SELECT SUM(amount) FROM claim_events
WHERE event_type = 'PAYMENT' AND event_ts >= '2025-01-01' AND event_ts < '2025-02-01';
SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID())) WHERE operator_type = 'TableScan';

SELECT SUM(amount) FROM claim_events_sorted
WHERE event_type = 'PAYMENT' AND event_ts >= '2025-01-01' AND event_ts < '2025-02-01';
SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID())) WHERE operator_type = 'TableScan';

SELECT SUM(amount) FROM claim_events_sorted
WHERE event_type = 'PAYMENT' AND TO_CHAR(event_ts, 'YYYY-MM') = '2025-01';
SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID())) WHERE operator_type = 'TableScan';
-- [TEACHING NOTE]
-- Unsorted: ~all partitions scanned. Sorted with a range predicate: ~2% (one
-- month of ~58). With TO_CHAR the optimizer often cannot use min/max metadata
-- and pruning degrades — keep predicates sargable (range on the raw column).
-- Results vary by run; the ratio is what matters.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ The Exploding Join
-- ──────────────────────────────────────────────────────────────────────────────
SELECT c.line_of_business, SUM(p.amount) AS paid, COUNT(e.event_id) AS events
FROM claims c
JOIN claim_payments p      ON p.claim_id = c.claim_id
JOIN claim_events_sorted e ON e.claim_id = c.claim_id
GROUP BY 1;

SELECT operator_id, operator_type,
       operator_statistics:output_rows::NUMBER AS output_rows,
       operator_attributes:equality_join_condition::STRING AS join_condition
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID()))
ORDER BY operator_id;

-- Correct: aggregate each child to the claim grain BEFORE joining.
WITH p AS (SELECT claim_id, SUM(amount) AS paid   FROM claim_payments      GROUP BY 1),
     e AS (SELECT claim_id, COUNT(*)    AS events FROM claim_events_sorted GROUP BY 1)
SELECT c.line_of_business, SUM(p.paid) AS paid, SUM(e.events) AS events
FROM claims c
LEFT JOIN p ON p.claim_id = c.claim_id
LEFT JOIN e ON e.claim_id = c.claim_id
GROUP BY 1;
-- [TEACHING NOTE]
-- Payments (1–3 per claim) × events (~1,500 per claim) = a many-to-many fan-out:
-- the join outputs tens of millions of rows and SUM(p.amount) is multiplied by
-- the event count. The Query Profile flags it as an "exploding join". Fix the
-- grain first, then join. (CLAIMS has a row access policy; SYSADMIN sees all.)


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Did Search Optimization Help?
-- ──────────────────────────────────────────────────────────────────────────────
SHOW TABLES LIKE 'CLAIM_EVENTS_SORTED';
SELECT "search_optimization_progress" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT * FROM claim_events_sorted WHERE claim_id = 'CLM-0013579';
SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID())) WHERE operator_type = 'TableScan';

SELECT * FROM claim_events WHERE claim_id = 'CLM-0013579';
SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID())) WHERE operator_type = 'TableScan';
-- [TEACHING NOTE]
-- ~1,500 events for one claim are spread over many partitions, so SOS helps
-- less than for a truly unique key — but scanned partitions still drop a lot.
-- SOS shines for highly selective lookups (one or a few rows). Discuss the
-- trade-off: the build and maintenance are serverless and ongoing.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Tune the Workload, Not the Query
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE accountadmin;
SELECT query_parameterized_hash,
       ANY_VALUE(LEFT(query_text, 80))                AS sample_query,
       COUNT(*)                                       AS executions,
       SUM(total_elapsed_time) / 1000                 AS total_seconds,
       AVG(bytes_scanned) / POWER(1024, 2)            AS avg_mb_scanned,
       SUM(partitions_scanned)                        AS partitions_scanned,
       SUM(partitions_total)                          AS partitions_total,
       SUM(bytes_spilled_to_remote_storage)           AS remote_spill
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD(day, -3, CURRENT_TIMESTAMP())
  AND user_name = CURRENT_USER()
  AND execution_status = 'SUCCESS'
  AND query_type = 'SELECT'
GROUP BY 1
ORDER BY total_seconds DESC
LIMIT 5;
-- [TEACHING NOTE]
-- Parameterized hash groups queries that differ only in literals — the right
-- unit for tuning repeated workloads. Typical reasoning: scanned ≈ total on a
-- date-filtered pattern → clustering; a selective lookup → SOS; the same
-- aggregate many times → MV/dynamic table; remote spill → bigger warehouse
-- (or fix the query); bursty large scans → QAS. ACCOUNT_USAGE keeps 365 days
-- but lags up to ~45 minutes, so today's lab queries may not appear yet —
-- the Day 1–2 workload will. Grant IMPORTED PRIVILEGES on the SNOWFLAKE
-- database (or the GOVERNANCE_VIEWER database role) to let other roles see it.
