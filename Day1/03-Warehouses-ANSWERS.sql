/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #03 — Warehouse Sizing and Concurrency
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Data Science Warehouse
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE WAREHOUSE smith_ds_wh
    WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 120 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Actuarial data science';
GRANT USAGE ON WAREHOUSE smith_ds_wh TO ROLE smith_engineer;

SHOW WAREHOUSES LIKE 'SMITH_DS_WH'
->> SELECT "name", "type", "size", "auto_suspend", "state" FROM $1;
-- [TEACHING NOTE]
-- Snowpark-optimized warehouses give ~16x memory per node for ML training and
-- large UDF/UDTF workloads. They cost more per hour; MEDIUM is the smallest size
-- in many regions. Use only for memory-bound code, not ordinary SQL.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Does Size Fix Spilling?
-- ──────────────────────────────────────────────────────────────────────────────
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
ALTER SESSION SET QUERY_TAG = 'lab03-ex2';
USE WAREHOUSE smith_etl_wh;
SELECT l_orderkey, l_extendedprice,
       ROW_NUMBER() OVER (ORDER BY l_extendedprice DESC, l_orderkey) AS rn
FROM snowflake_sample_data.tpch_sf10.lineitem
QUALIFY rn <= 10;

SELECT operator_type,
       operator_statistics:spilling:bytes_spilled_local_storage::NUMBER  AS spilled_local,
       operator_statistics:spilling:bytes_spilled_remote_storage::NUMBER AS spilled_remote
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID()))
WHERE operator_statistics:spilling IS NOT NULL;      -- usually no rows on Large

ALTER WAREHOUSE smith_etl_wh SUSPEND;
ALTER SESSION UNSET QUERY_TAG;
-- [TEACHING NOTE]
-- A larger warehouse has more memory and local SSD per query, so spilling drops
-- or disappears. The other fix is processing less data: filter earlier, select
-- fewer columns, or avoid a global sort (a TOP-N with QUALIFY is still a sort).


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Economy vs. Standard
-- ──────────────────────────────────────────────────────────────────────────────
ALTER WAREHOUSE smith_bi_wh SET SCALING_POLICY = 'ECONOMY' MAX_CLUSTER_COUNT = 4;
-- STANDARD starts a new cluster as soon as queries queue — best for interactive
-- dashboards where users wait. ECONOMY starts a cluster only when it estimates
-- there is enough load to keep it busy ~6 minutes — saves credits for batch or
-- tolerant workloads at the cost of some queuing.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Workload Report
-- ──────────────────────────────────────────────────────────────────────────────
SELECT warehouse_name,
       COUNT(*)                                        AS queries,
       ROUND(AVG(total_elapsed_time) / 1000, 2)        AS avg_elapsed_s,
       SUM(bytes_spilled_to_local_storage)             AS spilled_local_bytes,
       SUM(bytes_spilled_to_remote_storage)            AS spilled_remote_bytes,
       ROUND(AVG(queued_overload_time) / 1000, 2)      AS avg_queued_s
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE user_name = CURRENT_USER()
  AND start_time >= DATEADD(hour, -2, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
GROUP BY warehouse_name
ORDER BY spilled_local_bytes DESC;
-- [TEACHING NOTE]
-- Spilling → scale UP that warehouse (or tune the query).
-- Queued overload time with many concurrent queries → scale OUT (multi-cluster).
-- Both rarely appear in a single-user lab; in production use
-- SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY and WAREHOUSE_LOAD_HISTORY over weeks.
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
USE WAREHOUSE smith_wh;


