/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #04 — Caching, Time Travel and Recovery
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Prove the Result Cache Rules
-- ──────────────────────────────────────────────────────────────────────────────
ALTER SESSION SET QUERY_TAG = 'lab04-ex1';
SELECT region_id, COUNT(*) FROM claims GROUP BY 1;
SELECT region_id, COUNT(*) FROM claims GROUP BY 1;

USE ROLE smith_claims_analyst;
USE SECONDARY ROLES NONE;
SELECT region_id, COUNT(*) FROM smith_ins.core.claims GROUP BY 1;

USE ROLE sysadmin;
SELECT role_name, query_text, bytes_scanned, total_elapsed_time AS ms
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE query_tag = 'lab04-ex1' AND query_type = 'SELECT'
ORDER BY start_time;
ALTER SESSION UNSET QUERY_TAG;
-- [TEACHING NOTE]
-- Run 2 scans 0 bytes (result reuse). The analyst's run cannot reuse it.
-- Reuse does not require the same role (Demo 1) — the reason here is that
--   * CLAIMS has a row access policy, so the analyst gets different rows
--     (regions 1–4) — reuse would leak data.
-- Queries with policies, non-deterministic functions (CURRENT_TIMESTAMP,
-- RANDOM) or changed underlying data are not served from the result cache.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Point-in-Time Recovery by Timestamp
-- ──────────────────────────────────────────────────────────────────────────────
SET before_delete = CURRENT_TIMESTAMP()::TIMESTAMP_LTZ;
SELECT COUNT(*) FROM claims_work WHERE status = 'DENIED';

DELETE FROM claims_work WHERE status = 'DENIED';

INSERT INTO claims_work
SELECT * FROM claims_work AT (TIMESTAMP => $before_delete) WHERE status = 'DENIED';

SELECT COUNT(*) FROM claims_work WHERE status = 'DENIED';      -- same as before
-- [TEACHING NOTE]
-- Students who run the SET and DELETE within the same second can hit the
-- "time travel to a point before the table existed / too close" edge. Use
-- BEFORE (STATEMENT => LAST_QUERY_ID()) as the precise alternative.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Retention Strategy
-- ──────────────────────────────────────────────────────────────────────────────
ALTER SCHEMA smith_ins.core SET DATA_RETENTION_TIME_IN_DAYS = 14;
ALTER SCHEMA smith_ins.raw  SET DATA_RETENTION_TIME_IN_DAYS = 1;

SHOW TABLES IN DATABASE smith_ins
->> SELECT "schema_name", "name", "kind", "retention_time" FROM $1
    WHERE "name" IN ('CLAIMS', 'POLICIES', 'CLAIMS_STAGING') ORDER BY 1, 2;
-- [TEACHING NOTE]
-- CLAIMS = 30 (table-level setting wins), POLICIES = 14 (inherits schema),
-- RAW.CLAIMS_STAGING = 0 (explicit table setting; transient max is 1).
-- Longer retention = more Time Travel storage on high-churn tables.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Recover with a Name Collision
-- ──────────────────────────────────────────────────────────────────────────────
DROP TABLE claims_work;
CREATE TABLE claims_work LIKE claims;            -- new, empty

ALTER TABLE claims_work RENAME TO claims_work_new;
UNDROP TABLE claims_work;

SELECT 'original' AS t, COUNT(*) FROM claims_work UNION ALL
SELECT 'new',           COUNT(*) FROM claims_work_new;

SHOW GRANTS ON TABLE claims_work;
-- [TEACHING NOTE]
-- UNDROP fails if a table with that name exists, so rename the new one first.
-- SMITH_CORE_RO's SELECT came from the FUTURE grant on schema CORE (Lab 01): it
-- fired when the table was created by CLONE in Demo 2, and UNDROP restores the
-- table with its grants. A clone does not copy the source table's own grants
-- unless COPY GRANTS is specified. Lesson: manage access with schema-level
-- future grants rather than table-by-table grants.
DROP TABLE IF EXISTS claims_work_restored;
DROP TABLE IF EXISTS claims_work_new;
