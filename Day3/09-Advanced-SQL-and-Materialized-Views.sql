/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #09 — Advanced SQL and Materialized Views             (25 minutes)
1) Recursive hierarchy: the agency org chart
2) Window functions: running totals, moving averages, year-over-year
3) QUALIFY and PIVOT
4) Materialized views: when they help, what they cost
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
USE SCHEMA smith_ins.analytics;

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Recursive CTE — Who Reports to Whom
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- AGENTS is Smith's version of SCOTT.EMP: CEO → regional VPs → office managers
-- → agents. The anchor selects the root; the recursive member walks down.
-- CONNECT BY is the Oracle-style equivalent.

WITH RECURSIVE org (agent_id, agent_name, title, manager_id, lvl, path) AS (
    SELECT agent_id, agent_name, title, manager_id, 1, agent_name::VARCHAR
    FROM smith_ins.core.agents
    WHERE manager_id IS NULL
    UNION ALL
    SELECT a.agent_id, a.agent_name, a.title, a.manager_id, o.lvl + 1,
           o.path || ' > ' || a.agent_name
    FROM smith_ins.core.agents a
    JOIN org o ON a.manager_id = o.agent_id
)
SELECT lvl, LPAD('', (lvl - 1) * 2, ' ') || agent_name AS org_chart, title, path
FROM org
ORDER BY path
LIMIT 25;

SELECT LEVEL, agent_name, title, SYS_CONNECT_BY_PATH(agent_name, ' > ') AS path
FROM smith_ins.core.agents
START WITH manager_id IS NULL
CONNECT BY PRIOR agent_id = manager_id
ORDER BY path
LIMIT 10;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Window Functions — Claim Cost Trends
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Aggregate first, then window over the aggregate. Three frames in one query:
-- year-to-date running total, 3-month moving average, and LAG for YoY.

WITH monthly AS (
    SELECT line_of_business,
           DATE_TRUNC('month', claim_date) AS month,
           SUM(claim_amount)               AS incurred
    FROM smith_ins.core.claims
    GROUP BY 1, 2
)
SELECT line_of_business, month, incurred,
       SUM(incurred) OVER (PARTITION BY line_of_business, YEAR(month) ORDER BY month)            AS ytd_incurred,
       AVG(incurred) OVER (PARTITION BY line_of_business ORDER BY month
                           ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)                              AS moving_avg_3m,
       incurred / NULLIF(LAG(incurred, 12) OVER (PARTITION BY line_of_business ORDER BY month), 0) - 1 AS yoy_change
FROM monthly
WHERE line_of_business = 'HOME'
ORDER BY month;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ QUALIFY and PIVOT
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- QUALIFY filters on a window function without a subquery — the idiom for
-- "top N per group" and for de-duplication. PIVOT turns rows into columns.

-- Largest claim per region per year
SELECT r.region_name, YEAR(c.claim_date) AS yr, c.claim_id, c.claim_type, c.claim_amount
FROM smith_ins.core.claims c
JOIN smith_ins.core.regions r ON r.region_id = c.region_id
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.region_id, YEAR(c.claim_date) ORDER BY c.claim_amount DESC) = 1
ORDER BY yr, region_name;

-- Paid amount by year (rows) and line of business (columns)
SELECT *
FROM (SELECT YEAR(claim_date) AS yr, line_of_business, paid_amount FROM smith_ins.core.claims)
PIVOT (SUM(paid_amount) FOR line_of_business IN (ANY ORDER BY line_of_business))
ORDER BY yr;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Materialized View on Claim Payments
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Finance runs the same monthly payment rollup all day. An MV stores the
-- result and a background service keeps it current (serverless credits +
-- storage). MVs: single table, no joins, limited functions — Enterprise+.
-- The optimizer can even rewrite queries on the BASE table to use the MV.

CREATE OR REPLACE MATERIALIZED VIEW mv_payments_monthly AS
SELECT DATE_TRUNC('month', payment_date) AS pay_month,
       payee_type,
       COUNT(*)    AS payments,
       SUM(amount) AS paid
FROM smith_ins.core.claim_payments
GROUP BY 1, 2;

SELECT * FROM mv_payments_monthly ORDER BY pay_month DESC, payee_type LIMIT 12;

-- Query the BASE table — look for MV_PAYMENTS_MONTHLY in the plan:
EXPLAIN
SELECT DATE_TRUNC('month', payment_date), SUM(amount)
FROM smith_ins.core.claim_payments
GROUP BY 1;

SHOW MATERIALIZED VIEWS LIKE 'MV_PAYMENTS_MONTHLY';     -- note behind_by, is_secure, refreshed_on


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ What Does Freshness Cost?
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Insert payments and the MV is still correct immediately — Snowflake combines
-- the stored result with the not-yet-maintained rows at query time. The
-- background refresh is billed separately: check the refresh history.

INSERT INTO smith_ins.core.claim_payments
SELECT 900000000 + ROW_NUMBER() OVER (ORDER BY claim_id), claim_id, CURRENT_DATE(), 100, 'CLAIMANT'
FROM smith_ins.core.claims
WHERE status = 'OPEN'
LIMIT 500;

SELECT pay_month, SUM(payments) FROM mv_payments_monthly
WHERE pay_month = DATE_TRUNC('month', CURRENT_DATE()) GROUP BY 1;   -- includes the 500 rows already

SELECT * FROM TABLE(INFORMATION_SCHEMA.MATERIALIZED_VIEW_REFRESH_HISTORY(
        MATERIALIZED_VIEW_NAME => 'SMITH_INS.ANALYTICS.MV_PAYMENTS_MONTHLY'));


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Span of Control
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Using a recursive CTE, return each regional VP with the TOTAL number
--       of people below them (managers and agents, all levels).


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Adjuster Workload Ranking
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: For 2026, rank adjusters within their region by number of claims
--       handled (DENSE_RANK) and show each adjuster's share of the region's
--       total paid amount (RATIO_TO_REPORT). Return only the top adjuster per
--       region using QUALIFY.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Materialized View or Not?
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: (a) Try to create a materialized view that joins CLAIM_PAYMENTS to
--       CLAIMS to get paid amount by LINE_OF_BUSINESS. Read the error.
--       (b) Build the same result a different way that IS supported and stays
--       fresh automatically. (Hint: Module 8 — and Hands-on #10.)


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Frequency and Severity
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Actuaries split loss cost into FREQUENCY (claims per 100 active
--       policies) and SEVERITY (average claim amount). For each line of
--       business and claim year 2023–2026 compute both, plus the year-over-year
--       change in severity using LAG. A policy counts as active in a year if
--       its effective/expiration dates overlap that year.


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP
================================================================================
*/
DELETE FROM smith_ins.core.claim_payments WHERE payment_id >= 900000000;
