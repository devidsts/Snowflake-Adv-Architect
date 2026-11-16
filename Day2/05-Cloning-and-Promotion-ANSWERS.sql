/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #05 — Cloning, Environments and Promotion
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Point-in-Time Test Data
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE SCHEMA smith_ins_dev.core_snapshot
    CLONE smith_ins.core AT (OFFSET => -300);

SELECT 'snapshot' AS src, COUNT(*) FROM smith_ins_dev.core_snapshot.claims UNION ALL
SELECT 'prod',            COUNT(*) FROM smith_ins.core.claims;
-- [TEACHING NOTE]
-- Fails if any table in CORE did not exist 5 minutes ago (for example a table
-- created during Lab 04). Then pick a smaller offset or clone individual tables.
-- Time Travel + cloning = reproducible test data without copying.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Hand DEV to the Engineers
-- ──────────────────────────────────────────────────────────────────────────────
GRANT OWNERSHIP ON DATABASE smith_ins_dev TO ROLE smith_engineer COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA smith_ins_dev.core TO ROLE smith_engineer COPY CURRENT GRANTS;

USE ROLE smith_engineer;
CREATE OR REPLACE TABLE smith_ins_dev.core.engineer_test (id NUMBER);
DROP TABLE smith_ins_dev.core.engineer_test;
USE ROLE sysadmin;
-- [TEACHING NOTE]
-- Ownership of the database does not imply ownership of its schemas; CREATE
-- TABLE needs ownership of (or CREATE TABLE on) the schema. Because
-- SMITH_ENGINEER rolls up to SYSADMIN, administrators keep control.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Idempotent DDL
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER TABLE smith_ins_dev.core.claim_reviews (
    review_id   NUMBER,
    claim_id    VARCHAR(12),
    reviewer    VARCHAR(40),
    review_date DATE,
    outcome     VARCHAR(20)
);                                                   -- no change: definition already matches

CREATE OR ALTER TABLE smith_ins_dev.core.claim_reviews (
    review_id   NUMBER,
    claim_id    VARCHAR(12),
    reviewer    VARCHAR(40),
    review_date DATE,
    outcome     VARCHAR(20),
    escalated   BOOLEAN DEFAULT FALSE
);
SELECT COUNT(*), COUNT_IF(NOT escalated) FROM smith_ins_dev.core.claim_reviews;   -- 25, 25
-- [TEACHING NOTE]
-- Compare with CREATE OR REPLACE, which would drop the data. Idempotent DDL is
-- what lets a pipeline run the same script in DEV, TEST and PROD.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Roll Back the Release
-- ──────────────────────────────────────────────────────────────────────────────
ALTER SCHEMA smith_ins.analytics SWAP WITH smith_ins.analytics_next;

SHOW VIEWS IN SCHEMA smith_ins.analytics ->> SELECT "name" FROM $1;   -- no V_OPEN_CLAIMS

USE ROLE smith_claims_analyst;
USE SECONDARY ROLES NONE;
SELECT * FROM smith_ins.analytics.claims_by_region;
USE ROLE sysadmin;
-- [TEACHING NOTE]
-- After rollback the original ANALYTICS schema is back with its own schema-level
-- grants, so the analyst can read it again. Ask the class to test access WHILE
-- the release was live: the swapped-in schema was a clone, whose container
-- grants (USAGE for SMITH_ANALYTICS_RO) were not cloned — a classic
-- promotion-day outage. Fix: apply schema grants as part of the deployment
-- script, or grant at the database level with future grants.
