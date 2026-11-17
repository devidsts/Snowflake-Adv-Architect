/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #04 — Caching, Time Travel and Recovery            (30 minutes)
1) Result cache vs. warehouse (local disk) cache vs. metadata
2) Time Travel: AT / BEFORE with OFFSET, TIMESTAMP and STATEMENT
3) Recovering from a bad UPDATE and a dropped table (UNDROP)
4) Retention design: DATA_RETENTION_TIME_IN_DAYS, transient tables, storage cost
5) Business continuity on Business Critical: replication and failover groups
----------------------------------------------------------------------------------*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Three Ways a Query Avoids Work
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- (a) Metadata: COUNT(*) / MIN / MAX on a table can be answered by cloud
--     services without the warehouse.
-- (b) Result cache: identical SQL text, unchanged data, and a role with the
--     required privileges (it does not have to be the same role) → served from
--     cloud services for 24 hours, renewed each time it is reused (max 31 days).
-- (c) Warehouse cache: data read from remote storage stays on the warehouse SSD
--     while it runs; different queries over the same columns read it locally.
-- Check each in Query Profile ("Percentage scanned from cache", "QUERY RESULT REUSE").

ALTER SESSION SET QUERY_TAG = 'lab04-cache';

SELECT COUNT(*), MIN(claim_date), MAX(claim_date) FROM claims;                 -- (a) metadata

SELECT line_of_business, SUM(paid_amount) FROM claims GROUP BY 1;              -- run twice:
SELECT line_of_business, SUM(paid_amount) FROM claims GROUP BY 1;              -- (b) result cache

ALTER SESSION SET USE_CACHED_RESULT = FALSE;
SELECT claim_type, AVG(paid_amount) FROM claims GROUP BY 1;                    -- (c) warehouse cache
ALTER SESSION SET USE_CACHED_RESULT = TRUE;

SELECT query_text, execution_status, total_elapsed_time AS ms, bytes_scanned, warehouse_name
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE query_tag = 'lab04-cache' AND query_type = 'SELECT'
ORDER BY start_time;
-- Result-cache hits show 0 bytes scanned; metadata-only queries may show no warehouse.


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ The Bad UPDATE
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- A developer forgets the WHERE clause and closes every claim.
-- Capture the statement's query ID — BEFORE(STATEMENT => ...) is the most
-- precise recovery point.

CREATE OR REPLACE TABLE claims_work CLONE claims;          -- practice copy (zero-copy)
SELECT status, COUNT(*) FROM claims_work GROUP BY 1;

UPDATE claims_work SET status = 'CLOSED';                  -- oops
SET bad_qid = LAST_QUERY_ID();

SELECT status, COUNT(*) FROM claims_work GROUP BY 1;                                  -- all CLOSED
SELECT status, COUNT(*) FROM claims_work BEFORE (STATEMENT => $bad_qid) GROUP BY 1;   -- history


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Restore Options
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Option 1: clone the table as of the earlier point, then swap — keeps the bad
--           version for investigation and is instant (metadata only).
-- Option 2: INSERT OVERWRITE from the historical query — rewrites the data.
-- SWAP WITH exchanges the two tables in one transaction — consumers keep using
-- the same name and never see a half-restored table.

CREATE OR REPLACE TABLE claims_work_restored CLONE claims_work BEFORE (STATEMENT => $bad_qid);
ALTER TABLE claims_work SWAP WITH claims_work_restored;

SELECT status, COUNT(*) FROM claims_work GROUP BY 1;                     -- fixed
SELECT status, COUNT(*) FROM claims_work_restored GROUP BY 1;            -- bad version kept


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ UNDROP and Name Collisions
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- UNDROP restores the most recently dropped version. If an object with the
-- same name exists, rename it first. SHOW TABLES HISTORY lists dropped tables.

DROP TABLE claims_work_restored;
SHOW TABLES HISTORY LIKE 'CLAIMS_WORK%' IN SCHEMA smith_ins.core
->> SELECT "name", "created_on", "dropped_on", "retention_time" FROM $1;
UNDROP TABLE claims_work_restored;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Retention Design and Storage Cost
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Permanent tables: Time Travel 0–90 days (Enterprise+) PLUS 7 days Fail-safe.
-- Transient: 0–1 day Time Travel, NO Fail-safe — right for re-creatable
-- staging data. Retention can be set per account, database, schema or table;
-- the most specific setting wins.

ALTER TABLE claims SET DATA_RETENTION_TIME_IN_DAYS = 30;       -- critical table
CREATE OR REPLACE TRANSIENT TABLE smith_ins.raw.claims_staging
    DATA_RETENTION_TIME_IN_DAYS = 0 AS SELECT * FROM claims;

SHOW TABLES IN DATABASE smith_ins
->> SELECT "schema_name", "name", "kind", "retention_time" FROM $1
    WHERE "name" IN ('CLAIMS', 'CLAIMS_STAGING') ORDER BY 1;

SELECT table_catalog, table_schema, table_name, is_transient,
       active_bytes, time_travel_bytes, failsafe_bytes
FROM snowflake.account_usage.table_storage_metrics
WHERE table_catalog = 'SMITH_INS'
  AND table_name IN ('CLAIMS', 'CLAIMS_WORK', 'CLAIMS_STAGING')
  AND NOT deleted;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 6 │ Business Continuity (Business Critical)
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Time Travel and Fail-safe protect against mistakes, not region outages.
-- Business Critical adds FAILOVER GROUPS: replicate databases plus account
-- objects (roles, users, warehouses, policies) to another account in the
-- organization, and promote it if the primary region fails.
-- A trial has one account, so the CREATE below is shown, not run.

USE ROLE accountadmin;
SHOW REPLICATION ACCOUNTS;          -- accounts in the org that can be targets

/*  Run in an organization with a second account (e.g. SMITH_DR in another region):
CREATE FAILOVER GROUP smith_fg
    OBJECT_TYPES = DATABASES, ROLES, USERS, WAREHOUSES, NETWORK POLICIES
    ALLOWED_DATABASES = smith_ins
    ALLOWED_ACCOUNTS = <org_name>.smith_dr
    REPLICATION_SCHEDULE = '10 MINUTE';
-- In the target account:
CREATE FAILOVER GROUP smith_fg AS REPLICA OF <org_name>.<primary_account>.smith_fg;
ALTER FAILOVER GROUP smith_fg PRIMARY;           -- failover
*/
USE ROLE sysadmin;
ALTER SESSION UNSET QUERY_TAG;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Prove the Result Cache Rules
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Run SELECT region_id, COUNT(*) FROM claims GROUP BY 1 twice as SYSADMIN,
--       then once as SMITH_CLAIMS_ANALYST (secondary roles NONE).
--       Use QUERY_HISTORY_BY_SESSION to show which runs scanned 0 bytes, and
--       explain in a comment why the analyst run did not reuse SYSADMIN's result.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Point-in-Time Recovery by Timestamp
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: In CLAIMS_WORK, record the current time in a variable, then DELETE all
--       DENIED claims. Recover them by inserting back only the deleted rows
--       using AT (TIMESTAMP => $your_variable). Verify the DENIED count matches.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Retention Strategy
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Smith's policy: CORE data keeps 14 days of Time Travel, RAW keeps 1 day,
--       and the CLAIMS table keeps 30 days. Set retention at the schema level
--       for CORE and RAW, then show the effective retention of CLAIMS,
--       POLICIES and RAW.CLAIMS_STAGING. Which setting wins for CLAIMS?


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Recover a Dropped Schema Object Chain
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Drop CLAIMS_WORK, then create a NEW empty table named CLAIMS_WORK.
--       Recover the original dropped table without losing the new one, so that
--       both exist (original as CLAIMS_WORK, new one as CLAIMS_WORK_NEW).
--       Then run SHOW GRANTS ON TABLE CLAIMS_WORK: SMITH_CORE_RO has SELECT on
--       it although nobody granted it on this table. Where did it come from?


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP
================================================================================
*/
DROP TABLE IF EXISTS smith_ins.core.claims_work_restored;
DROP TABLE IF EXISTS smith_ins.core.claims_work_new;
-- Keep CLAIMS_WORK and RAW.CLAIMS_STAGING for Hands-on #05.
