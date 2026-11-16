/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #06d — Claims History as Apache Iceberg Tables on S3
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.lakehouse;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Agency Claims in Open Format
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE ICEBERG TABLE agency_claims_ice
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'smith_iceberg_vol'
    BASE_LOCATION = 'agency_claims'
AS
SELECT record:claim_ref::STRING                     AS claim_ref,
       record:agency.agency_id::STRING              AS agency_id,
       record:agency.state::STRING                  AS state,
       record:policy_id::STRING                     AS policy_id,
       record:line_of_business::STRING              AS line_of_business,
       record:loss_date::DATE                       AS loss_date,
       record:reported_at::TIMESTAMP_NTZ(6)         AS reported_at,
       ARRAY_SIZE(record:line_items)::NUMBER(4,0)   AS line_items
FROM smith_ins.raw.agency_claims_raw;

SELECT (SELECT COUNT(*) FROM agency_claims_ice)                AS iceberg_rows,
       (SELECT COUNT(*) FROM smith_ins.raw.agency_claims_raw)  AS raw_rows;
-- [TEACHING NOTE]
-- Equal counts (12,048, or 12,528 with the late files). Semi-structured
-- columns must be modeled before they go to Iceberg for other engines; that is
-- usually a good thing — the lake gets typed, documented columns.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Undo a Bad Delete
-- ──────────────────────────────────────────────────────────────────────────────
SET bad_delete = (
    SELECT query_id
    FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
    WHERE query_type = 'DELETE' AND query_text ILIKE '%claims_history_ice%'
    ORDER BY start_time DESC LIMIT 1);

INSERT INTO claims_history_ice
SELECT b.*
FROM claims_history_ice BEFORE (STATEMENT => $bad_delete) b
WHERE b.line_of_business = 'UMBRELLA' AND b.claim_amount < 50000
  AND NOT EXISTS (SELECT 1 FROM claims_history_ice c WHERE c.claim_id = b.claim_id);

SELECT (SELECT COUNT(*) FROM claims_history_ice) AS iceberg_rows,
       (SELECT COUNT(*) FROM smith_ins.core.claims) AS core_rows;
-- [TEACHING NOTE]
-- Same pattern as the native-table recovery in Hands-on #04: read the old
-- version with BEFORE (STATEMENT) and re-insert. The INSERT is itself a new
-- Iceberg snapshot. If students ran the session in a new worksheet, look the
-- query ID up in Query History instead of QUERY_HISTORY_BY_SESSION.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Native or Iceberg?
-- ──────────────────────────────────────────────────────────────────────────────
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

SELECT region_id, YEAR(claim_date) AS yr, SUM(paid_amount) FROM smith_ins.core.claims GROUP BY 1, 2;
SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID())) WHERE operator_type = 'TableScan';

SELECT region_id, YEAR(claim_date) AS yr, SUM(paid_amount) FROM claims_history_ice GROUP BY 1, 2;
SELECT operator_statistics:pruning:partitions_scanned::NUMBER AS scanned,
       operator_statistics:pruning:partitions_total::NUMBER   AS total
FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID())) WHERE operator_type = 'TableScan';

ALTER SESSION UNSET USE_CACHED_RESULT;
-- (b) Native table: storage billed by Snowflake. Iceberg on an external
--     volume: storage (and S3 requests) billed by AWS to Smith's account;
--     Snowflake bills the compute. Reasons to stay native: Fail-safe
--     protection, no bucket or IAM role to operate, and no other engine needs
--     to read the data — the simplest fully managed option.
-- [TEACHING NOTE]
-- At 20,000 rows both are fast; the point is that Iceberg queries are
-- first-class in Snowflake (same warehouse, pruning on Parquet statistics).
-- Exam angle: choose Iceberg for open-format interoperability, native for the
-- simplest fully managed option.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Partitioned for the Lake
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE ICEBERG TABLE claims_by_month_ice
    PARTITION BY (MONTH(claim_date))
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'smith_iceberg_vol'
    BASE_LOCATION = 'claims_by_month'
AS
SELECT * FROM claims_history_ice;

SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('smith_ins.lakehouse.claims_by_month_ice');
-- CloudShell:  aws s3 ls s3://$BUCKET/iceberg/ --recursive | grep claims_by_month | grep data/ | head
-- [TEACHING NOTE]
-- Data files are now grouped by month partition (folders such as
-- claim_date_month=2026-03 under data/), so Spark/Athena can skip whole months
-- from the Iceberg metadata. Snowflake also prunes on the partition values.
-- Iceberg partitioning is "hidden": queries filter on CLAIM_DATE, not on a
-- separate month column. If the PARTITION BY clause errors in your account,
-- check the CREATE ICEBERG TABLE (Snowflake catalog) page for the current
-- transform syntax.
