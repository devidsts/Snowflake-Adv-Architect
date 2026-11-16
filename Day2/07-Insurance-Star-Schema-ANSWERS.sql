/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #07 — An Insurance Star Schema with History
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.analytics;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Agent Dimension
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE dim_agent AS
SELECT a.agent_id, a.agent_name, a.title,
       m.agent_name AS manager_name,
       o.office_name, o.city, r.region_name
FROM smith_ins.core.agents a
LEFT JOIN smith_ins.core.agents  m ON m.agent_id  = a.manager_id
JOIN      smith_ins.core.offices o ON o.office_id = a.office_id
JOIN      smith_ins.core.regions r ON r.region_id = o.region_id;

SELECT title, COUNT(*) FROM dim_agent GROUP BY 1;     -- 1 CEO, 6 VPs, 12 managers, 61 agents
-- [TEACHING NOTE]
-- LEFT JOIN keeps the CEO. A flattened hierarchy (manager name) suits BI;
-- Hands-on #09 walks the full chain with a recursive CTE.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Second Change Run
-- ──────────────────────────────────────────────────────────────────────────────
UPDATE smith_ins.core.policyholders
SET city = 'Denver', state_code = 'CO', region_id = 4, updated_at = CURRENT_TIMESTAMP()
WHERE holder_id IN (104, 204);

SET change_date = '2026-10-01'::DATE;

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

SELECT COUNT(*) AS holders_without_exactly_one_current
FROM (SELECT holder_id FROM dim_policyholder GROUP BY holder_id HAVING COUNT_IF(is_current) <> 1);   -- 0

SELECT holder_id, city, effective_from, effective_to, is_current
FROM dim_policyholder WHERE holder_id IN (104, 204) ORDER BY 1, effective_from;
-- [TEACHING NOTE]
-- "Exactly one current row per key" is the invariant to monitor — a good
-- candidate for a custom data metric function in Hands-on #08.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Star Schema Report
-- ──────────────────────────────────────────────────────────────────────────────
SELECT dt.year, p.line_of_business, r.region_name AS region_at_claim,
       COUNT(*) AS claims, SUM(f.paid_amount) AS paid
FROM fact_claims f
JOIN dim_date dt          ON dt.date_key = f.claim_date_key
JOIN dim_policy p         ON p.policy_id = f.policy_id
JOIN dim_policyholder h   ON h.holder_sk = f.holder_sk
JOIN smith_ins.core.regions r ON r.region_id = h.region_id
WHERE dt.year IN (2025, 2026)
GROUP BY 1, 2, 3
ORDER BY 1, 2, paid DESC;
-- [TEACHING NOTE]
-- The fact carries only keys and measures; every label comes from a dimension.
-- REGIONS is a small reference table — in a fuller model REGION_NAME would be
-- an attribute of DIM_POLICYHOLDER (snowflaking vs. denormalizing trade-off). This star schema is what
-- the Cortex semantic view in Hands-on #14 sits on.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — One-Statement SCD Type 2
-- ──────────────────────────────────────────────────────────────────────────────
UPDATE smith_ins.core.policyholders
SET city = 'Seattle', state_code = 'WA', region_id = 4, updated_at = CURRENT_TIMESTAMP()
WHERE holder_id = 304;
SET change_date = CURRENT_DATE();

MERGE INTO dim_policyholder d
USING (
    WITH src AS (
        SELECT holder_id, first_name || ' ' || last_name AS full_name, street, city, state_code, region_id,
               HASH(street, city, state_code, region_id) AS hash_diff
        FROM smith_ins.core.policyholders WHERE source_system = 'CORE_PAS')
    SELECT holder_id AS merge_key, src.* FROM src
    UNION ALL
    SELECT NULL AS merge_key, src.*
    FROM src
    JOIN dim_policyholder cur ON cur.holder_id = src.holder_id AND cur.is_current
    WHERE cur.hash_diff <> src.hash_diff
) s
ON d.holder_id = s.merge_key AND d.is_current
WHEN MATCHED AND d.hash_diff <> s.hash_diff THEN
    UPDATE SET d.is_current = FALSE, d.effective_to = DATEADD(day, -1, $change_date)
WHEN NOT MATCHED THEN
    INSERT (holder_id, full_name, street, city, state_code, region_id, hash_diff, effective_from, effective_to, is_current)
    VALUES (s.holder_id, s.full_name, s.street, s.city, s.state_code, s.region_id, s.hash_diff, $change_date, '9999-12-31', TRUE);

SELECT holder_id, city, effective_from, effective_to, is_current
FROM dim_policyholder WHERE holder_id = 304 ORDER BY effective_from;
-- [TEACHING NOTE]
-- One atomic statement = no window where a holder has zero current rows.
-- In production consider a stream on POLICYHOLDERS so only changed rows are
-- processed (Hands-on #10), or dbt snapshots.
