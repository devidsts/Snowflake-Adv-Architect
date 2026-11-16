/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #00 — Intro and Smith Insurance Setup            (15 minutes)
1) Account facts an architect checks first: edition, region, identifiers
2) Session context: role, warehouse, database, schema
3) Course warehouse and account settings
4) Building the Smith Insurance dataset (SetUp/SMITH-INSURANCE-SETUP.sql)
5) Exploring the data model with SHOW, DESC and the ->> pipe operator
----------------------------------------------------------------------------------*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Know Your Account
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- This class uses a Business Critical trial. Edition decides which features an
-- architect can design with (Enterprise: masking, multi-cluster, 90-day Time
-- Travel; Business Critical adds failover groups, Tri-Secret Secure, private
-- connectivity). Region decides Cortex model availability and data residency.

USE ROLE accountadmin;

SELECT CURRENT_ORGANIZATION_NAME()          AS org_name,
       CURRENT_ACCOUNT_NAME()               AS account_name,
       CURRENT_ACCOUNT()                    AS account_locator,
       CURRENT_REGION()                     AS region,
       CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS account_identifier,
       CURRENT_VERSION()                    AS snowflake_version;

-- Edition is shown in Snowsight (Admin > Accounts) or with SHOW ORGANIZATION ACCOUNTS (ORGADMIN).


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Session Context and the Role Hierarchy
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Architects design for least privilege from day one. ACCOUNTADMIN is only for
-- account-level settings; objects are created by SYSADMIN (or roles under it).
-- CURRENT_AVAILABLE_ROLES shows every role this session could switch to.

SELECT CURRENT_ROLE(), CURRENT_SECONDARY_ROLES(), CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();

SELECT VALUE::STRING AS available_role
FROM TABLE(FLATTEN(INPUT => PARSE_JSON(CURRENT_AVAILABLE_ROLES())))
ORDER BY 1;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Account Settings for This Course
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Cross-region inference lets Cortex use models hosted in other regions when a
-- model is not available locally (needed for Module 11). Review this with any
-- customer before enabling it: data is processed outside the account's region.
-- A statement timeout protects trial credits from runaway queries.

ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 1800;
SHOW PARAMETERS LIKE 'STATEMENT_TIMEOUT%' IN ACCOUNT;

-- AI features (Cortex functions, Analyst, Agents, Search) are DISABLED on
-- self-service trials until a credit card is added (Admin » Billing »
-- Snowflake billing » + Credit Card). That does not end the trial; AI usage is
-- paid from trial credits. Hands-on #14 Part A (semantic views) works without
-- it. Test now — an error here means AI is still disabled:
SELECT AI_COMPLETE('claude-sonnet-4-5', 'Reply with the single word READY.') AS ai_status;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Build the Smith Insurance Dataset
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Open SetUp/SMITH-INSURANCE-SETUP.sql and Run All (about 1 minute, X-Small).
-- It runs as SYSADMIN and creates warehouse SMITH_WH and database SMITH_INS.
-- Walk through the data model diagram at the top of that script:
--   REGIONS, OFFICES, AGENTS (hierarchy), ADJUSTERS, POLICYHOLDERS (PII),
--   POLICIES, CLAIMS (with adjuster notes), CLAIM_PAYMENTS.
-- Every later lab builds on this database.

-- >>> Run SetUp/SMITH-INSURANCE-SETUP.sql now, then continue here. <<<

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Explore the Model
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- SHOW and DESC are metadata operations answered by the cloud services layer.
-- The ->> pipe operator feeds the SHOW result into SQL without RESULT_SCAN.
-- Point out PRIMARY KEY / REFERENCES: informational only (not enforced) except
-- NOT NULL — an architecture point that appears on the exam.

SHOW TABLES IN SCHEMA smith_ins.core
->> SELECT "name" AS table_name, "rows" AS row_count, "bytes" AS bytes, "comment"
    FROM $1 ORDER BY "rows" DESC;

DESC TABLE claims;

SELECT line_of_business, COUNT(*) AS claims, SUM(claim_amount) AS claimed, SUM(paid_amount) AS paid
FROM claims
GROUP BY line_of_business
ORDER BY claimed DESC;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Context Check
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Return your role, warehouse, database, schema and region in one row.
--       Expected: SYSADMIN | SMITH_WH | SMITH_INS | CORE | <your region>


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Data Residency Snapshot
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Count policyholders by data residency (US or EU) using POLICYHOLDERS
--       and REGIONS. This drives Module 2's account-strategy discussion.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Schema Inventory with ->>
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: List every schema in SMITH_INS with its comment and whether it is a
--       managed access schema. Use SHOW SCHEMAS and the ->> operator.
--       (Hint: look for the "options" column.)


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Loss Ratio by Line of Business
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Loss ratio = paid claims / earned premium. For each line of business,
--       return total annual premium (POLICIES), total paid (CLAIMS) and the
--       loss ratio as a percentage rounded to 1 decimal.
--       Careful: aggregate each table before joining, or premiums double count.


-- YOUR CODE HERE
