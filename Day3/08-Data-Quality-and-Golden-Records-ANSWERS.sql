/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #08 — Data Quality and Policyholder Golden Records
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.core;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Monitor the Feed
-- ──────────────────────────────────────────────────────────────────────────────
ALTER TABLE smith_ins.raw.claims_feed_raw SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE smith_ins.raw.claims_feed_raw ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();
ALTER TABLE smith_ins.raw.claims_feed_raw ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (loaded_at);

SELECT metric_name, ref_arguments, schedule, schedule_status
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
        REF_ENTITY_NAME => 'smith_ins.raw.claims_feed_raw', REF_ENTITY_DOMAIN => 'table'));
-- [TEACHING NOTE]
-- TRIGGER_ON_CHANGES fits a Snowpipe target: the DMFs run after each load,
-- not on an idle clock. FRESHNESS answers "is the feed stalled?" — alerting on
-- it (Module 8 alerts) is the natural next step.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Custom DMF: Exactly One Current Version
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DATA METRIC FUNCTION smith_ins.governance.scd_current_violations(
    t TABLE(holder_id NUMBER, is_current BOOLEAN))
RETURNS NUMBER
AS 'SELECT COUNT(*) FROM (SELECT holder_id FROM t GROUP BY holder_id HAVING COUNT_IF(is_current) <> 1)';

ALTER TABLE smith_ins.analytics.dim_policyholder SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE smith_ins.analytics.dim_policyholder
    ADD DATA METRIC FUNCTION smith_ins.governance.scd_current_violations
    ON (holder_id, is_current)
    EXPECTATION one_current_row (VALUE = 0);

SELECT * FROM TABLE(SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS(
        REF_ENTITY_NAME => 'smith_ins.analytics.dim_policyholder'));
-- [TEACHING NOTE]
-- Custom DMFs can contain any aggregate query over the argument table — this
-- one encodes the SCD2 invariant from Hands-on #07. The DMF lives in the
-- managed-access GOVERNANCE schema, so stewards own the rules, not the
-- pipeline engineers.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Find the Near Misses
-- ──────────────────────────────────────────────────────────────────────────────
SELECT master_id, duplicate_id, master_name, duplicate_name, name_score,
       EDITDISTANCE(master_name, duplicate_name) AS edits
FROM policyholder_match
WHERE name_score < 100
ORDER BY name_score;
-- [TEACHING NOTE]
-- UPPER() removes the case variation and TRIM() removes the trailing space —
-- only the dropped-last-letter typo (holder_id MOD 4 = 1, ~10 pairs) remains.
-- Lesson: normalize aggressively before scoring, and keep the score so stewards
-- review only the uncertain pairs.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Claims Follow the Golden Record
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW smith_ins.analytics.v_claims_golden AS
SELECT c.*, x.golden_id
FROM smith_ins.core.claims c
JOIN smith_ins.core.policyholder_xref x ON x.source_holder_id = c.holder_id;

SELECT g.golden_id, g.first_name || ' ' || g.last_name AS name, g.sources,
       COUNT(*) AS claims, SUM(v.paid_amount) AS total_paid
FROM smith_ins.analytics.v_claims_golden v
JOIN smith_ins.analytics.policyholder_golden g ON g.golden_id = v.golden_id
GROUP BY 1, 2, 3
ORDER BY total_paid DESC
LIMIT 5;
-- [TEACHING NOTE]
-- In this dataset claims reference CORE_PAS IDs only, so the XREF join is an
-- identity mapping — in real life the duplicate IDs would carry their own
-- claims and the golden ID is what unifies them. The view inherits the
-- region row access policy on CLAIMS (Hands-on #02): governance follows the data.
