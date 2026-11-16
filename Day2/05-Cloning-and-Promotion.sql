/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #05 — Cloning, Environments and Promotion          (25 minutes)
1) Zero-copy clone of a whole environment (PROD → DEV)
2) What a clone keeps: child objects, grants, policies; what it does not
3) Storage after cloning: shared vs. owned micro-partitions
4) Declarative change with CREATE OR ALTER TABLE
5) Blue/green promotion with ALTER SCHEMA ... SWAP WITH
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

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Clone PROD into DEV
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- A database clone copies metadata only: it finishes in seconds whatever the
-- data size. Child objects (schemas, tables, views, policies, tasks — suspended)
-- are cloned. Internal named stages and their files are NOT cloned; external
-- stages are. Pipes on internal stages are not cloned.

CREATE OR REPLACE DATABASE smith_ins_dev CLONE smith_ins
    COMMENT = 'DEV environment cloned from PROD';

SHOW SCHEMAS IN DATABASE smith_ins_dev ->> SELECT "name" FROM $1 ORDER BY 1;
SELECT COUNT(*) FROM smith_ins_dev.core.claims;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Grants on a Clone
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Cloning a database or schema: CHILD objects keep their granted privileges;
-- the cloned CONTAINER itself does not. So SMITH_CORE_RO has SELECT on
-- DEV tables but no USAGE on the DEV database — DEV is closed until you open it.

SHOW GRANTS ON DATABASE smith_ins     ->> SELECT "privilege", "grantee_name" FROM $1;
SHOW GRANTS ON DATABASE smith_ins_dev ->> SELECT "privilege", "grantee_name" FROM $1;
SHOW GRANTS ON TABLE smith_ins_dev.core.claims ->> SELECT "privilege", "grantee_name" FROM $1;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Shared vs. Owned Storage
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Clones share micro-partitions with the source. Only changed partitions become
-- owned by the clone. TABLE_STORAGE_METRICS shows CLONE_GROUP_ID and
-- RETAINED_FOR_CLONE_BYTES (data kept because a clone still references it).
-- Metrics refresh with a short delay.

UPDATE smith_ins_dev.core.claims SET adjuster_id = 1 WHERE region_id = 1;

SELECT table_catalog, table_name, clone_group_id, active_bytes, retained_for_clone_bytes
FROM snowflake.account_usage.table_storage_metrics
WHERE table_name = 'CLAIMS' AND table_catalog IN ('SMITH_INS', 'SMITH_INS_DEV') AND NOT deleted;
-- ACCOUNT_USAGE has latency; if empty, re-run at the end of the lab.


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Declarative Change in DEV: CREATE OR ALTER TABLE
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- CREATE OR ALTER TABLE compares the definition with the existing table and
-- applies only the difference (here: add a column), keeping the data.
-- Source-controlled DDL in this form is idempotent — ideal for CI/CD
-- (Snowflake CLI, dbt, schemachange, Git integration).

-- Release 1: a new table for the claim review process
CREATE OR ALTER TABLE smith_ins_dev.core.claim_reviews (
    review_id   NUMBER,
    claim_id    VARCHAR(12),
    reviewer    VARCHAR(40),
    review_date DATE
);
INSERT INTO smith_ins_dev.core.claim_reviews
SELECT ROW_NUMBER() OVER (ORDER BY claim_id), claim_id, 'Grace Liu', CURRENT_DATE()
FROM smith_ins_dev.core.claims WHERE fraud_flag LIMIT 25;

-- Release 2: same statement, one more column — data is kept
CREATE OR ALTER TABLE smith_ins_dev.core.claim_reviews (
    review_id   NUMBER,
    claim_id    VARCHAR(12),
    reviewer    VARCHAR(40),
    review_date DATE,
    outcome     VARCHAR(20)
);
DESC TABLE smith_ins_dev.core.claim_reviews;
SELECT COUNT(*) FROM smith_ins_dev.core.claim_reviews;            -- still 25 rows


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Blue/Green Promotion with SWAP
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Build the next version of a reporting schema next to the live one, test it,
-- then swap names in one atomic statement. Rollback = swap again.
-- (Run with care: consumers are switched instantly.)

CREATE OR REPLACE SCHEMA smith_ins.analytics_next CLONE smith_ins_dev.analytics;
CREATE OR REPLACE VIEW smith_ins.analytics_next.v_open_claims AS
SELECT claim_id, region_id, claim_type, claim_amount, reported_date
FROM smith_ins.core.claims WHERE status IN ('OPEN', 'IN_REVIEW');

ALTER SCHEMA smith_ins.analytics SWAP WITH smith_ins.analytics_next;
SHOW VIEWS IN SCHEMA smith_ins.analytics ->> SELECT "name" FROM $1;     -- new release is live
-- Rollback would be: ALTER SCHEMA smith_ins.analytics SWAP WITH smith_ins.analytics_next;
-- [INSTRUCTOR NOTE] Views keep their definition text through CLONE and SWAP.
-- A view cloned from SMITH_INS_DEV that names SMITH_INS_DEV tables still reads
-- DEV data after it goes live in SMITH_INS.ANALYTICS. Check every view's
-- references before promoting (and recreate any that point at DEV):
SELECT table_name AS view_name, view_definition
FROM smith_ins.information_schema.views
WHERE table_schema = 'ANALYTICS' AND view_definition ILIKE '%SMITH_INS_DEV%';   -- expect no rows


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Point-in-Time Test Data
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: QA needs CORE exactly as it was 5 minutes ago. Clone SMITH_INS.CORE
--       into SMITH_INS_DEV as schema CORE_SNAPSHOT using AT (OFFSET => -300),
--       and compare the claim count with PROD.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Hand DEV to the Engineers
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Transfer ownership of database SMITH_INS_DEV to SMITH_ENGINEER while
--       keeping existing grants (COPY CURRENT GRANTS), then confirm as
--       SMITH_ENGINEER that you can create a table in SMITH_INS_DEV.CORE.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Idempotent DDL
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Run the Demo 4 "Release 2" statement a second time. What changes?
--       Then use CREATE OR ALTER to also add column ESCALATED BOOLEAN DEFAULT FALSE.
--       Verify the existing 25 rows are still there and ESCALATED is FALSE.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Roll Back the Release
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: The new ANALYTICS release has a bug. Roll back with one statement,
--       confirm V_OPEN_CLAIMS is gone from SMITH_INS.ANALYTICS, and confirm
--       SMITH_CLAIMS_ANALYST can still read ANALYTICS.CLAIMS_BY_REGION
--       (created in Hands-on #01). If not, explain why in a comment.


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP
================================================================================
*/
USE ROLE sysadmin;
DROP SCHEMA IF EXISTS smith_ins.analytics_next;
-- Keep SMITH_INS_DEV until the end of Day 2 (used for discussion), then:
-- DROP DATABASE smith_ins_dev;
