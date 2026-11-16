/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #00 — Intro and Smith Insurance Setup
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Context Check
-- ──────────────────────────────────────────────────────────────────────────────
SELECT CURRENT_ROLE()      AS current_role,
       CURRENT_WAREHOUSE() AS current_warehouse,
       CURRENT_DATABASE()  AS current_database,
       CURRENT_SCHEMA()    AS current_schema,
       CURRENT_REGION()    AS current_region;
-- [TEACHING NOTE]
-- If the warehouse is NULL, USE WAREHOUSE was skipped. Region matters for
-- Cortex (Module 11) and for internal-stage Snowpipe auto-ingest (Module 5),
-- which is currently available on AWS-hosted accounts.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Data Residency Snapshot
-- ──────────────────────────────────────────────────────────────────────────────
SELECT r.data_residency, COUNT(*) AS policyholders
FROM policyholders h
JOIN regions r ON r.region_id = h.region_id
GROUP BY r.data_residency
ORDER BY 1;
-- [TEACHING NOTE]
-- About 20% of policyholders are EU residents. Ask: "If GDPR requires EU data to
-- stay in the EU with separate administrators, is a separate database enough?"
-- (No — the account is the regional and admin boundary. Revisit in Module 2.)


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Schema Inventory with ->>
-- ──────────────────────────────────────────────────────────────────────────────
SHOW SCHEMAS IN DATABASE smith_ins
->> SELECT "name" AS schema_name,
           "comment",
           CONTAINS(COALESCE("options", ''), 'MANAGED ACCESS') AS is_managed_access
    FROM $1
    ORDER BY 1;
-- [TEACHING NOTE]
-- GOVERNANCE is a managed access schema: only the schema owner (or a role with
-- MANAGE GRANTS) can grant privileges on its objects — object owners cannot.
-- INFORMATION_SCHEMA is created automatically in every database.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Loss Ratio by Line of Business
-- ──────────────────────────────────────────────────────────────────────────────
WITH prem AS (SELECT line_of_business, SUM(annual_premium) AS premium
              FROM policies GROUP BY line_of_business),
     paid AS (SELECT line_of_business, SUM(paid_amount) AS paid
              FROM claims GROUP BY line_of_business)
SELECT p.line_of_business,
       p.premium,
       COALESCE(c.paid, 0)                                  AS paid,
       ROUND(100 * COALESCE(c.paid, 0) / p.premium, 1)      AS loss_ratio_pct
FROM prem p
LEFT JOIN paid c USING (line_of_business)
ORDER BY loss_ratio_pct DESC;
-- [TEACHING NOTE]
-- Joining POLICIES to CLAIMS first and then summing premium counts a policy's
-- premium once per claim — a classic fan-out error. Pre-aggregating avoids it.
-- The synthetic data produces very high loss ratios for LIFE and UMBRELLA
-- (few, large claims); fine for the exercise — real books are far lower.
