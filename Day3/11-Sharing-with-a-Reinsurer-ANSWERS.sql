/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #11 — Sharing Ceded Claims with a Reinsurer
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_re_share.ceded;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Only Secure Objects Can Be Shared
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_ceded_totals AS
SELECT YEAR(c.claim_date) AS claim_year, c.line_of_business,
       COUNT(*) AS claims, SUM(c.ceded_amount) AS ceded_amount
FROM ceded_claims c
JOIN entitlements e ON e.region_id = c.region_id AND e.consumer_account = CURRENT_ACCOUNT()
GROUP BY 1, 2;

GRANT SELECT ON VIEW v_ceded_totals TO DATABASE ROLE smith_re_share.reinsurer_read;
-- Error: a non-secure view cannot be granted to a share (directly or via a
-- database role granted to a share).

ALTER VIEW v_ceded_totals SET SECURE;
GRANT SELECT ON VIEW v_ceded_totals TO DATABASE ROLE smith_re_share.reinsurer_read;
-- [TEACHING NOTE]
-- Secure views hide the definition (GET_DDL, SHOW VIEWS) from non-owners and
-- block optimizations that could leak filtered rows. The cost: some pushdown
-- optimizations are disabled — test performance on large shared views.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ A New Treaty for the EU
-- ──────────────────────────────────────────────────────────────────────────────
INSERT INTO entitlements VALUES ('RHINERE7', 'Rhine Re (EU treaty)', 5), ('RHINERE7', 'Rhine Re (EU treaty)', 6);

ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'RHINERE7';
SELECT region_id, COUNT(*) FROM v_ceded_claims GROUP BY 1 ORDER BY 1;     -- 5, 6
ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'ATLRE01';
SELECT region_id, COUNT(*) FROM v_ceded_claims GROUP BY 1 ORDER BY 1;     -- 1–4
ALTER SESSION UNSET SIMULATED_DATA_SHARING_CONSUMER;
-- [TEACHING NOTE]
-- Data-driven entitlements scale: onboarding a reinsurer is an INSERT, not a
-- new view or share. Same idea as the region mapping table in Hands-on #02.
-- Discussion: EU claims data shared to an EU reinsurer — where must the
-- provider account live for residency? (Account strategy, Module 1.)


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Consume a Share
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE accountadmin;                 -- IMPORT SHARE is held by ACCOUNTADMIN by default
SHOW SHARES;                           -- kind = INBOUND rows come from providers
-- CREATE DATABASE reinsurance_from_partner FROM SHARE <provider_org>.<provider_account>.smith_reinsurance_share;
-- GRANT DATABASE ROLE reinsurance_from_partner.reinsurer_read TO ROLE sysadmin;
-- USE ROLE sysadmin;
-- SELECT region_id, COUNT(*) FROM reinsurance_from_partner.ceded.v_ceded_claims GROUP BY 1;
-- [TEACHING NOTE]
-- Zero rows usually means the provider has not inserted the consumer's
-- LOCATOR (not the account name) into ENTITLEMENTS. The consumer cannot see
-- ENTITLEMENTS or CEDED_CLAIMS — only what the database role exposes.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Who Is Using Our Data?
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE sysadmin;
SHOW GRANTS TO SHARE smith_reinsurance_share;
SHOW GRANTS OF SHARE smith_reinsurance_share;        -- consumer accounts
SHOW GRANTS TO DATABASE ROLE smith_re_share.reinsurer_read;
-- Account-level history: SNOWFLAKE.DATA_SHARING_USAGE views (listings) and
-- consumer-side ACCESS_HISTORY.
-- (b) CEDED_CLAIMS is a CTAS snapshot — frozen at Demo 1. The share is live,
--     but the table is not. Make the shared object current: a DYNAMIC TABLE
--     over CORE.CLAIMS with a TARGET_LAG (or a secure view directly over a
--     policy-free source). The reinsurer sees new rows automatically — no
--     action on their side.
CREATE OR REPLACE DYNAMIC TABLE smith_re_share.ceded.ceded_claims_live
    TARGET_LAG = '1 hour'
    WAREHOUSE  = smith_wh
AS
SELECT claim_id, region_id, line_of_business, claim_type, claim_date, status,
       claim_amount, paid_amount, GREATEST(claim_amount - 100000, 0) AS ceded_amount
FROM smith_ins.core.claims
WHERE claim_amount > 100000;
ALTER DYNAMIC TABLE smith_re_share.ceded.ceded_claims_live SUSPEND;   -- class cleanup
-- [TEACHING NOTE]
-- The dynamic table is refreshed as its owner, SYSADMIN, which inherits
-- SMITH_COMPLIANCE — so REGION_RAP lets every region through and the secure
-- view + entitlements do the filtering. Deliberate, but document and review it.
