/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #09 — Advanced SQL and Materialized Views
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.analytics;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Span of Control
-- ──────────────────────────────────────────────────────────────────────────────
WITH RECURSIVE below (vp_id, agent_id) AS (
    SELECT agent_id, agent_id
    FROM smith_ins.core.agents
    WHERE title = 'Regional VP'
    UNION ALL
    SELECT b.vp_id, a.agent_id
    FROM smith_ins.core.agents a
    JOIN below b ON a.manager_id = b.agent_id
)
SELECT b.vp_id, v.agent_name AS vp, COUNT(*) - 1 AS people_below
FROM below b
JOIN smith_ins.core.agents v ON v.agent_id = b.vp_id
GROUP BY b.vp_id, v.agent_name
ORDER BY people_below DESC;
-- [TEACHING NOTE]
-- Carry the root (VP_ID) down through the recursion, then aggregate. Subtract 1
-- for the VP's own anchor row. Check the title value with
-- SELECT DISTINCT title FROM smith_ins.core.agents if students get zero rows.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Adjuster Workload Ranking
-- ──────────────────────────────────────────────────────────────────────────────
WITH a AS (
    SELECT c.region_id, j.adjuster_name,
           COUNT(*)           AS claims,
           SUM(c.paid_amount) AS paid
    FROM smith_ins.core.claims c
    JOIN smith_ins.core.adjusters j ON j.adjuster_id = c.adjuster_id
    WHERE YEAR(c.claim_date) = 2026
    GROUP BY 1, 2
)
SELECT r.region_name, a.adjuster_name, a.claims,
       DENSE_RANK()   OVER (PARTITION BY a.region_id ORDER BY a.claims DESC) AS workload_rank,
       ROUND(RATIO_TO_REPORT(a.paid) OVER (PARTITION BY a.region_id) * 100, 1) AS pct_of_region_paid
FROM a
JOIN smith_ins.core.regions r ON r.region_id = a.region_id
QUALIFY workload_rank = 1
ORDER BY r.region_name;
-- [TEACHING NOTE]
-- QUALIFY can reference the window alias. Claims are assigned to adjusters at
-- random across regions, so every region shows many adjusters — a good prompt
-- to discuss whether data quality rules should catch "adjuster outside region".


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Materialized View or Not?
-- ──────────────────────────────────────────────────────────────────────────────
-- (a) Fails: materialized views cannot contain joins.
CREATE OR REPLACE MATERIALIZED VIEW mv_paid_by_lob AS
SELECT c.line_of_business, SUM(p.amount) AS paid
FROM smith_ins.core.claim_payments p
JOIN smith_ins.core.claims c ON c.claim_id = p.claim_id
GROUP BY 1;

-- (b) A dynamic table supports joins and refreshes to a target lag.
CREATE OR REPLACE DYNAMIC TABLE dt_paid_by_lob
    TARGET_LAG = '15 minutes'
    WAREHOUSE  = smith_wh
AS
SELECT c.line_of_business, SUM(p.amount) AS paid, COUNT(*) AS payments
FROM smith_ins.core.claim_payments p
JOIN smith_ins.core.claims c ON c.claim_id = p.claim_id
GROUP BY 1;

SELECT * FROM dt_paid_by_lob ORDER BY paid DESC;
-- [TEACHING NOTE]
-- MV: single table, always current, serverless, may be used by query rewrite.
-- Dynamic table: joins/complex SQL, freshness bounded by TARGET_LAG, uses your
-- warehouse. Note: CLAIMS has a row access policy — the dynamic table is
-- refreshed as its owner (SYSADMIN, which inherits SMITH_COMPLIANCE), so it
-- holds every region. Anything materialized from protected data needs its own
-- protection; ask students who would see this table.
-- Suspend it so it does not keep refreshing:
ALTER DYNAMIC TABLE dt_paid_by_lob SUSPEND;


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Frequency and Severity
-- ──────────────────────────────────────────────────────────────────────────────
WITH yrs AS (
    SELECT column1 AS yr FROM VALUES (2023), (2024), (2025), (2026)
),
exposure AS (
    SELECT y.yr, p.line_of_business, COUNT(*) AS active_policies
    FROM yrs y
    JOIN smith_ins.core.policies p
      ON p.effective_date  <= DATE_FROM_PARTS(y.yr, 12, 31)
     AND p.expiration_date >= DATE_FROM_PARTS(y.yr, 1, 1)
    GROUP BY 1, 2
),
losses AS (
    SELECT YEAR(claim_date) AS yr, line_of_business,
           COUNT(*) AS claims, AVG(claim_amount) AS severity
    FROM smith_ins.core.claims
    GROUP BY 1, 2
)
SELECT e.line_of_business, e.yr, e.active_policies, l.claims,
       ROUND(100 * l.claims / e.active_policies, 2)                       AS frequency_per_100,
       ROUND(l.severity, 0)                                               AS severity,
       ROUND(l.severity / LAG(l.severity) OVER (PARTITION BY e.line_of_business ORDER BY e.yr) - 1, 3) AS severity_yoy
FROM exposure e
JOIN losses l ON l.yr = e.yr AND l.line_of_business = e.line_of_business
ORDER BY 1, 2;
-- [TEACHING NOTE]
-- The overlap test (start <= period end AND end >= period start) is the
-- standard interval join. Frequency × severity = pure premium — tie it back
-- to the loss ratio from Hands-on #00.
