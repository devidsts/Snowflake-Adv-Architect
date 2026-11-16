/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #03 — Warehouse Sizing and Concurrency             (25 minutes)
1) Workload isolation: one warehouse per workload
2) Scaling up: X-Small vs. Large on the same query (cache off)
3) Diagnosing spilling with QUERY_HISTORY and GET_QUERY_OPERATOR_STATS
4) Scaling out: multi-cluster warehouse with a scaling policy
5) Guardrails: statement timeout, queued timeout, query acceleration
Credits: Demos use a LARGE warehouse for under a minute. Suspend it after.
----------------------------------------------------------------------------------*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ One Warehouse per Workload
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Smith's ETL, BI dashboards and actuarial data science must not slow each other.
-- Separate warehouses = isolation + clean cost attribution. Same data, no copies.

USE ROLE sysadmin;

CREATE OR REPLACE WAREHOUSE smith_etl_wh
    WAREHOUSE_SIZE = 'LARGE' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Batch ETL';
CREATE OR REPLACE WAREHOUSE smith_bi_wh
    WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 300 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    MIN_CLUSTER_COUNT = 1 MAX_CLUSTER_COUNT = 3 SCALING_POLICY = 'STANDARD'
    COMMENT = 'BI dashboards — multi-cluster';

SHOW WAREHOUSES LIKE 'SMITH%'
->> SELECT "name", "size", "min_cluster_count", "max_cluster_count", "scaling_policy", "auto_suspend" FROM $1;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Scale Up: Same Query, Two Sizes
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Turn the result cache off so both runs do real work. TPCH_SF10 LINEITEM has
-- ~60M rows. Compare elapsed time; credits per hour double with each size, so a
-- LARGE run that is 8x faster costs about the same as X-Small.

ALTER SESSION SET USE_CACHED_RESULT = FALSE;
ALTER SESSION SET QUERY_TAG = 'lab03-scale-up';

USE WAREHOUSE smith_wh;                        -- X-Small
SELECT l_returnflag, l_linestatus, COUNT(*), SUM(l_extendedprice * (1 - l_discount)) AS revenue
FROM snowflake_sample_data.tpch_sf10.lineitem
GROUP BY 1, 2;

USE WAREHOUSE smith_etl_wh;                    -- Large
SELECT l_returnflag, l_linestatus, COUNT(*), SUM(l_extendedprice * (1 - l_discount)) AS revenue
FROM snowflake_sample_data.tpch_sf10.lineitem
GROUP BY 1, 2;

SELECT warehouse_name, warehouse_size, total_elapsed_time / 1000 AS seconds
FROM TABLE(snowflake_sample_data.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE query_tag = 'lab03-scale-up' AND query_type = 'SELECT'
ORDER BY start_time;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Diagnose Spilling
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- A large sort on X-Small exceeds memory, spills to local disk and possibly
-- remote storage. Open the Query Profile in Snowsight too: look for
-- "Bytes spilled to local/remote storage" under Statistics.
-- GET_QUERY_OPERATOR_STATS returns the same profile data in SQL.

ALTER SESSION SET QUERY_TAG = 'lab03-spill';
USE WAREHOUSE smith_wh;
SELECT l_orderkey, l_extendedprice,
       ROW_NUMBER() OVER (ORDER BY l_extendedprice DESC, l_orderkey) AS rn
FROM snowflake_sample_data.tpch_sf10.lineitem
QUALIFY rn <= 10;

SET spill_qid = LAST_QUERY_ID();

SELECT operator_type,
       operator_statistics:spilling:bytes_spilled_local_storage::NUMBER  AS spilled_local,
       operator_statistics:spilling:bytes_spilled_remote_storage::NUMBER AS spilled_remote
FROM TABLE(GET_QUERY_OPERATOR_STATS($spill_qid))
WHERE operator_statistics:spilling IS NOT NULL;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Guardrails
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Statement and queue timeouts stop runaway or stuck work per warehouse.
-- Query Acceleration Service (QAS) offloads parts of large scans to serverless
-- compute — good for outlier queries on a small warehouse. Enterprise+.

ALTER WAREHOUSE smith_bi_wh SET
    STATEMENT_TIMEOUT_IN_SECONDS = 300
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 120
    ENABLE_QUERY_ACCELERATION = TRUE
    QUERY_ACCELERATION_MAX_SCALE_FACTOR = 4;

SELECT PARSE_JSON(SYSTEM$ESTIMATE_QUERY_ACCELERATION($spill_qid)) AS qas_estimate;

ALTER WAREHOUSE smith_etl_wh SUSPEND;
ALTER SESSION UNSET QUERY_TAG;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Data Science Warehouse
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Smith's actuaries train pricing models with memory-hungry Python code.
--       Create SMITH_DS_WH as a Snowpark-optimized MEDIUM warehouse that
--       auto-suspends after 120 seconds, starts suspended, and grant USAGE on
--       it to SMITH_ENGINEER. (Snowpark-optimized: WAREHOUSE_TYPE =
--       'SNOWPARK-OPTIMIZED'.) Then show its type and size with SHOW + ->>.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Does Size Fix Spilling?
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Re-run the Demo 3 spill query on SMITH_ETL_WH (Large) with
--       QUERY_TAG 'lab03-ex2', then use GET_QUERY_OPERATOR_STATS to compare
--       spilled bytes with the X-Small run. Suspend SMITH_ETL_WH afterwards.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Economy vs. Standard
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Smith's month-end claims reports can tolerate a short queue to save
--       credits. Change SMITH_BI_WH to the ECONOMY scaling policy with a maximum
--       of 4 clusters, then write a comment explaining when Standard is the
--       better choice.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Workload Report
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Using INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER (your user, last
--       2 hours), report per warehouse: query count, average elapsed seconds,
--       total bytes spilled to local storage and average queued overload
--       seconds. Which warehouse would you resize, and which would you make
--       multi-cluster? Answer in a comment.


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP
================================================================================
*/
ALTER WAREHOUSE smith_etl_wh SUSPEND;
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
USE WAREHOUSE smith_wh;
