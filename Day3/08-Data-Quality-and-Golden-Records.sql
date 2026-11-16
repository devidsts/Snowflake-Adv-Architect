/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #08 — Data Quality and Policyholder Golden Records  (25 minutes)
1) System data metric functions (DMFs) — ad hoc and scheduled
2) Custom DMFs and expectations
3) Matching duplicate policyholders across source systems
4) Survivorship rules → one golden record per person
----------------------------------------------------------------------------------*/

/*
  SCENARIO
  Smith Insurance acquired an agency whose portal created its own copies of
  existing customers (HOLDER_ID 900001+, SOURCE_SYSTEM = 'AGENCY_PORTAL').
  Names, SSNs, phones and e-mails are formatted differently. Underwriting wants
  one trusted record per person, and monitoring that tells them when quality slips.
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Privileges and Ad Hoc System DMFs
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Scheduling DMFs needs EXECUTE DATA METRIC FUNCTION on the account; reading
-- the results view needs the DATA_QUALITY_MONITORING_VIEWER application role.
-- Every role can call the system DMFs directly — handy for profiling.

USE ROLE accountadmin;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE sysadmin;
GRANT APPLICATION ROLE snowflake.data_quality_monitoring_viewer TO ROLE sysadmin;

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;

SELECT SNOWFLAKE.CORE.NULL_COUNT(SELECT email FROM policyholders)          AS null_emails,
       SNOWFLAKE.CORE.NULL_PERCENT(SELECT email FROM policyholders)        AS null_email_pct,
       SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT ssn FROM policyholders)       AS dup_ssn_exact,
       SNOWFLAKE.CORE.FRESHNESS(SELECT updated_at FROM claims) / 3600      AS claims_hours_stale;
-- dup_ssn_exact is 0 — the portal stores SSNs without dashes, so exact matching
-- misses every duplicate. Remember that for Demo 4.


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Schedule DMFs on a Table
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- One schedule per table; every DMF on that table runs on it. TRIGGER_ON_CHANGES
-- runs after DML instead of on a clock. Results land in
-- SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS (serverless compute).

ALTER TABLE policyholders SET DATA_METRIC_SCHEDULE = '5 MINUTE';

-- Rule from the business: flag the table when more than 2% of e-mails are
-- missing. NULL_PERCENT expresses that directly (NULL_COUNT would need a
-- row count that changes every day).
ALTER TABLE policyholders ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT ON (email)
    EXPECTATION email_null_pct_max_2 (VALUE <= 2);
ALTER TABLE policyholders ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();

SELECT metric_name, ref_arguments, schedule, schedule_status
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
        REF_ENTITY_NAME   => 'smith_ins.core.policyholders',
        REF_ENTITY_DOMAIN => 'table'));

SELECT * FROM TABLE(SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS(
        REF_ENTITY_NAME => 'smith_ins.core.policyholders'));
-- NULL_PERCENT returns a percentage (0–100). 101 of 5,040 e-mails are missing
-- (about 2.0%) — right on the line, because the agency-portal duplicate of
-- holder 7 also lacks one. Read VALUE and EXPECTATION_VIOLATED, then discuss:
-- should a quality limit be a hard "<=" or leave headroom?


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ A Custom DMF with an Expectation
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Business rule: we never pay more than was claimed. A custom DMF takes a
-- TABLE argument (one or more columns) and returns a number. The expectation
-- turns the number into pass/fail.

CREATE OR REPLACE DATA METRIC FUNCTION smith_ins.governance.overpaid_claims(
    t TABLE(claim_amount NUMBER, paid_amount NUMBER))
RETURNS NUMBER
AS 'SELECT COUNT_IF(paid_amount > claim_amount) FROM t';

ALTER TABLE claims SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE claims ADD DATA METRIC FUNCTION smith_ins.governance.overpaid_claims
    ON (claim_amount, paid_amount)
    EXPECTATION never_overpay (VALUE = 0);

-- Evaluate now instead of waiting for the schedule:
SELECT * FROM TABLE(SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS(
        REF_ENTITY_NAME => 'smith_ins.core.claims'));

-- Break the rule on a scratch clone and evaluate again:
CREATE OR REPLACE TABLE claims_dq_test CLONE claims;
UPDATE claims_dq_test SET paid_amount = claim_amount * 1.1 WHERE claim_id = 'CLM-0000042';
SELECT smith_ins.governance.overpaid_claims(SELECT claim_amount, paid_amount FROM claims_dq_test) AS overpaid;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Match Duplicates Across Source Systems
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Normalize first, then match. A deterministic key (SSN digits + DOB) catches
-- most pairs; a similarity score on the name gives a confidence measure for
-- data stewards. JAROWINKLER_SIMILARITY returns 0–100.

CREATE OR REPLACE TABLE smith_ins.core.policyholder_match AS
WITH n AS (
    SELECT holder_id, source_system, updated_at,
           REGEXP_REPLACE(ssn, '[^0-9]', '')              AS ssn_digits,
           date_of_birth,
           UPPER(TRIM(first_name) || ' ' || TRIM(last_name)) AS name_norm
    FROM policyholders
)
SELECT a.holder_id AS master_id,  b.holder_id AS duplicate_id,
       a.name_norm AS master_name, b.name_norm AS duplicate_name,
       JAROWINKLER_SIMILARITY(a.name_norm, b.name_norm) AS name_score
FROM n a
JOIN n b
  ON a.ssn_digits = b.ssn_digits
 AND a.date_of_birth = b.date_of_birth
 AND a.source_system = 'CORE_PAS'
 AND b.source_system = 'AGENCY_PORTAL';

SELECT COUNT(*) AS pairs, MIN(name_score), AVG(name_score) FROM policyholder_match;    -- 40 pairs

-- Scheduled results (after the 5-minute schedule from Demo 2 has fired):
SELECT measurement_time, table_name, metric_name, value
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE table_database = 'SMITH_INS'
ORDER BY measurement_time DESC
LIMIT 10;
SELECT * FROM policyholder_match ORDER BY name_score LIMIT 5;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Survivorship → Golden Record
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Survivorship = which source wins for each attribute. Here: CORE_PAS wins for
-- names and address; e-mail takes the first non-null, CORE first. The XREF
-- table keeps lineage so every source ID still resolves to its golden ID.

CREATE OR REPLACE TABLE smith_ins.core.policyholder_xref AS
SELECT holder_id AS source_holder_id, source_system,
       COALESCE(m.master_id, p.holder_id) AS golden_id
FROM policyholders p
LEFT JOIN policyholder_match m ON m.duplicate_id = p.holder_id;

CREATE OR REPLACE TABLE smith_ins.analytics.policyholder_golden AS
SELECT x.golden_id,
       MAX(IFF(p.source_system = 'CORE_PAS', p.first_name, NULL))  AS first_name,
       MAX(IFF(p.source_system = 'CORE_PAS', p.last_name,  NULL))  AS last_name,
       MAX(IFF(p.source_system = 'CORE_PAS', p.street,     NULL))  AS street,
       MAX(IFF(p.source_system = 'CORE_PAS', p.city,       NULL))  AS city,
       COALESCE(MAX(IFF(p.source_system = 'CORE_PAS', LOWER(p.email), NULL)),
                MAX(LOWER(p.email)))                               AS email,
       COUNT(*)                                                    AS source_records,
       ARRAY_AGG(p.source_system) WITHIN GROUP (ORDER BY p.source_system) AS sources
FROM smith_ins.core.policyholder_xref x
JOIN policyholders p ON p.holder_id = x.source_holder_id
GROUP BY x.golden_id;

SELECT COUNT(*) FROM smith_ins.analytics.policyholder_golden;          -- 5,000 (not 5,040)
SELECT * FROM smith_ins.analytics.policyholder_golden WHERE source_records > 1 LIMIT 5;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Monitor the Feed
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: On SMITH_INS.RAW.CLAIMS_FEED_RAW (Hands-on #06) set the schedule to
--       TRIGGER_ON_CHANGES and add ROW_COUNT plus FRESHNESS on LOADED_AT.
--       Confirm both appear in DATA_METRIC_FUNCTION_REFERENCES.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Custom DMF: Exactly One Current Version
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Create GOVERNANCE.SCD_CURRENT_VIOLATIONS(t TABLE(holder_id NUMBER,
--       is_current BOOLEAN)) that returns how many holder_ids do NOT have
--       exactly one current row. Attach it to ANALYTICS.DIM_POLICYHOLDER
--       (Hands-on #07) with an expectation of VALUE = 0, then evaluate it.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Find the Near Misses
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Data stewards only want to review pairs where the names differ.
--       From POLICYHOLDER_MATCH return pairs with NAME_SCORE < 100 and add
--       EDITDISTANCE(master_name, duplicate_name). Which variation (typo,
--       case, trailing space) survives the normalization in Demo 4 — and why?


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Claims Follow the Golden Record
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Agency-portal holders submit claims too. Create view
--       ANALYTICS.V_CLAIMS_GOLDEN that returns every CORE.CLAIMS row with a
--       GOLDEN_ID column (via POLICYHOLDER_XREF), then report the top 5 golden
--       policyholders by total paid amount with their name and source list.


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP
  Keep the golden tables (used by #14). Remove the scratch clone and the
  5-minute schedule so the serverless DMF credits stay small.
================================================================================
*/
DROP TABLE IF EXISTS smith_ins.core.claims_dq_test;
ALTER TABLE smith_ins.core.policyholders UNSET DATA_METRIC_SCHEDULE;
