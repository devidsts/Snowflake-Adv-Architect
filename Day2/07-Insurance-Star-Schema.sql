/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #07 — An Insurance Star Schema with History        (30 minutes)
1) Date dimension from GENERATOR
2) Type 2 slowly changing dimension for policyholders (hash diff + MERGE)
3) Fact table joined to the dimension version valid at the claim date
4) "As it was" vs. "as it is" reporting
----------------------------------------------------------------------------------*/

/*
  TARGET (schema ANALYTICS)
      DIM_DATE ──┐
  DIM_POLICYHOLDER (SCD2) ──< FACT_CLAIMS >── DIM_POLICY
                                  │
                              DIM_AGENT (Exercise 1)
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.analytics;

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Date Dimension
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- A generated calendar makes time slicing consistent across every fact table.
-- An integer DATE_KEY (YYYYMMDD) is a common, readable surrogate.

CREATE OR REPLACE TABLE dim_date AS
SELECT TO_NUMBER(TO_CHAR(d, 'YYYYMMDD'))  AS date_key,
       d                                  AS calendar_date,
       YEAR(d)                            AS year,
       QUARTER(d)                         AS quarter,
       MONTH(d)                           AS month,
       MONTHNAME(d)                       AS month_name,
       DAYOFWEEKISO(d)                    AS day_of_week,
       DAYOFWEEKISO(d) IN (6, 7)          AS is_weekend
FROM (SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2022-01-01'::DATE) AS d
      FROM TABLE(GENERATOR(ROWCOUNT => 2191)));          -- 2022-01-01 → 2027-12-31


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Policyholder Dimension — Initial Load (Type 2)
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Each version of a policyholder gets its own surrogate key (HOLDER_SK) and an
-- effective date range. HASH_DIFF over the tracked attributes makes change
-- detection one comparison. Only address attributes are tracked here.

CREATE OR REPLACE TABLE dim_policyholder (
    holder_sk      NUMBER IDENTITY(1, 1),
    holder_id      NUMBER(7),
    full_name      VARCHAR(70),
    street         VARCHAR(60),
    city           VARCHAR(30),
    state_code     VARCHAR(3),
    region_id      NUMBER(2),
    hash_diff      NUMBER(19),
    effective_from DATE,
    effective_to   DATE,
    is_current     BOOLEAN
);

INSERT INTO dim_policyholder (holder_id, full_name, street, city, state_code, region_id,
                              hash_diff, effective_from, effective_to, is_current)
SELECT holder_id, first_name || ' ' || last_name, street, city, state_code, region_id,
       HASH(street, city, state_code, region_id), '2000-01-01', '9999-12-31', TRUE
FROM smith_ins.core.policyholders
WHERE source_system = 'CORE_PAS';


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Customers Move — Apply SCD Type 2
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- 50 policyholders moved to Boston on July 1, 2026. Step 1: MERGE closes
-- the current row of anyone whose hash changed (and inserts brand-new holders).
-- Step 2: INSERT a new current row for everyone without one.

SET change_date = '2026-07-01'::DATE;

UPDATE smith_ins.core.policyholders
SET street = '1 Harbor Way', city = 'Boston', state_code = 'MA', region_id = 1,
    updated_at = CURRENT_TIMESTAMP()
WHERE MOD(holder_id, 100) = 5 AND region_id <> 1 AND source_system = 'CORE_PAS';   -- 50 rows (all in Charlotte)

MERGE INTO dim_policyholder d
USING (SELECT holder_id, first_name || ' ' || last_name AS full_name, street, city, state_code, region_id,
              HASH(street, city, state_code, region_id) AS hash_diff
       FROM smith_ins.core.policyholders WHERE source_system = 'CORE_PAS') s
ON d.holder_id = s.holder_id AND d.is_current
WHEN MATCHED AND d.hash_diff <> s.hash_diff THEN
    UPDATE SET d.is_current = FALSE, d.effective_to = DATEADD(day, -1, $change_date)
WHEN NOT MATCHED THEN
    INSERT (holder_id, full_name, street, city, state_code, region_id, hash_diff, effective_from, effective_to, is_current)
    VALUES (s.holder_id, s.full_name, s.street, s.city, s.state_code, s.region_id, s.hash_diff, $change_date, '9999-12-31', TRUE);

INSERT INTO dim_policyholder (holder_id, full_name, street, city, state_code, region_id,
                              hash_diff, effective_from, effective_to, is_current)
SELECT s.holder_id, s.first_name || ' ' || s.last_name, s.street, s.city, s.state_code, s.region_id,
       HASH(s.street, s.city, s.state_code, s.region_id), $change_date, '9999-12-31', TRUE
FROM smith_ins.core.policyholders s
WHERE s.source_system = 'CORE_PAS'
  AND NOT EXISTS (SELECT 1 FROM dim_policyholder d WHERE d.holder_id = s.holder_id AND d.is_current);

SELECT holder_id, city, effective_from, effective_to, is_current
FROM dim_policyholder
WHERE holder_id IN (SELECT holder_id FROM dim_policyholder GROUP BY holder_id HAVING COUNT(*) > 1)
ORDER BY holder_id, effective_from
LIMIT 10;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Policy Dimension and Claims Fact
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- The fact joins to the policyholder version whose date range contains the
-- claim date — this is what "report against the address at the time of loss"
-- means (knowledge check on Type 2 dimensions).

CREATE OR REPLACE TABLE dim_policy AS
SELECT policy_id, line_of_business, status, effective_date, expiration_date,
       annual_premium, deductible, coverage_limit, agent_id
FROM smith_ins.core.policies;

CREATE OR REPLACE TABLE fact_claims AS
SELECT c.claim_id,
       TO_NUMBER(TO_CHAR(c.claim_date, 'YYYYMMDD')) AS claim_date_key,
       d.holder_sk,
       c.policy_id,
       c.region_id   AS region_id_at_claim,
       c.claim_type,
       c.status,
       c.claim_amount,
       c.paid_amount,
       c.fraud_flag
FROM smith_ins.core.claims c
JOIN dim_policyholder d
  ON d.holder_id = c.holder_id
 AND c.claim_date BETWEEN d.effective_from AND d.effective_to;

SELECT COUNT(*) AS facts, (SELECT COUNT(*) FROM smith_ins.core.claims) AS claims FROM fact_claims;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ As It Was vs. As It Is
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Same claims, two answers. "As it was" uses the fact's own HOLDER_SK.
-- "As it is" re-joins to the CURRENT version — both are valid questions.

SELECT 'as it was' AS view_type, d.city, COUNT(*) AS claims
FROM fact_claims f JOIN dim_policyholder d ON d.holder_sk = f.holder_sk
WHERE d.holder_id IN (SELECT holder_id FROM dim_policyholder WHERE NOT is_current)
GROUP BY d.city
UNION ALL
SELECT 'as it is', cur.city, COUNT(*)
FROM fact_claims f
JOIN dim_policyholder v   ON v.holder_sk = f.holder_sk
JOIN dim_policyholder cur ON cur.holder_id = v.holder_id AND cur.is_current
WHERE v.holder_id IN (SELECT holder_id FROM dim_policyholder WHERE NOT is_current)
GROUP BY cur.city
ORDER BY view_type, claims DESC;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Agent Dimension
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Build ANALYTICS.DIM_AGENT with agent_id, agent_name, title,
--       manager_name (self-join on CORE.AGENTS), office_name, city and
--       region_name. The CEO has no manager — keep that row.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Second Change Run
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Policyholders 104 and 204 moved to Denver, CO (region 4) on
--       October 1, 2026. Update CORE, set $change_date, re-run the Demo 3 MERGE
--       and INSERT, and prove every holder now has exactly ONE current row.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Star Schema Report
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Using only ANALYTICS tables, report paid amount and claim count by
--       claim year, line of business and the policyholder's region AT THE TIME
--       OF THE CLAIM (from DIM_POLICYHOLDER), for 2025 and 2026.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — One-Statement SCD Type 2
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Rewrite the two-step load as a SINGLE MERGE. Hint: the USING clause
--       returns each source row once with MERGE_KEY = holder_id (to close the
--       current row) and, for changed holders only, a second time with
--       MERGE_KEY = NULL (which never matches, so it is inserted as the new
--       version). Test it with holder 304 moving to Seattle, WA (region 4).


-- YOUR CODE HERE
