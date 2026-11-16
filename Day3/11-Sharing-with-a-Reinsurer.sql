/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #11 — Sharing Ceded Claims with a Reinsurer           (25 minutes)
1) A dedicated share database (and why: policies travel with the data)
2) Secure views with per-consumer entitlements
3) Database roles in a share
4) Testing as a consumer without a second account; consuming a classmate's share
----------------------------------------------------------------------------------*/

/*
  SCENARIO
  Smith Insurance cedes large losses to reinsurers. Each reinsurer may see only
  the claims above Smith's $100,000 retention, and only for the regions in its
  treaty. No copies, no SFTP — live, governed access through Secure Data Sharing.
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

USE ROLE accountadmin;
GRANT CREATE SHARE ON ACCOUNT TO ROLE sysadmin;

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Why a Separate Share Database?
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- CORE.CLAIMS carries REGION_RAP (Hands-on #02). Policies are enforced in the
-- consumer account too — and the consumer's roles are not in Smith's mapping
-- table, so a share of CORE.CLAIMS would return zero rows. Architects publish a
-- purpose-built share database with its own, consumer-aware rules.

SELECT CURRENT_ACCOUNT() AS my_locator, CURRENT_ORGANIZATION_NAME() AS org,
       CURRENT_ACCOUNT_NAME() AS account_name, CURRENT_REGION() AS region;

CREATE OR REPLACE DATABASE smith_re_share COMMENT = 'Outbound data for reinsurance partners';
CREATE OR REPLACE SCHEMA smith_re_share.ceded;

CREATE OR REPLACE TABLE smith_re_share.ceded.ceded_claims AS
SELECT c.claim_id, c.region_id, c.line_of_business, c.claim_type,
       c.claim_date, c.status, c.claim_amount, c.paid_amount,
       GREATEST(c.claim_amount - 100000, 0) AS ceded_amount
FROM smith_ins.core.claims c
WHERE c.claim_amount > 100000;                 -- above retention

SELECT region_id, COUNT(*), SUM(ceded_amount) FROM smith_re_share.ceded.ceded_claims GROUP BY 1 ORDER BY 1;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Entitlements + Secure View
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Inside a share, CURRENT_ACCOUNT() returns the CONSUMER's account locator.
-- One secure view + one entitlement table serves every reinsurer. Shares only
-- accept SECURE views — the definition and optimizer shortcuts stay hidden.

CREATE OR REPLACE TABLE smith_re_share.ceded.entitlements (
    consumer_account VARCHAR,     -- account locator of the reinsurer
    reinsurer_name   VARCHAR,
    region_id        NUMBER
);
INSERT INTO smith_re_share.ceded.entitlements VALUES
    (CURRENT_ACCOUNT(), 'Smith internal test', 1), (CURRENT_ACCOUNT(), 'Smith internal test', 2),
    ('ATLRE01',  'Atlantic Re (US treaty)', 1), ('ATLRE01', 'Atlantic Re (US treaty)', 2),
    ('ATLRE01',  'Atlantic Re (US treaty)', 3), ('ATLRE01', 'Atlantic Re (US treaty)', 4);

CREATE OR REPLACE SECURE VIEW smith_re_share.ceded.v_ceded_claims AS
SELECT c.*
FROM smith_re_share.ceded.ceded_claims c
JOIN smith_re_share.ceded.entitlements e
  ON e.region_id = c.region_id
 AND e.consumer_account = CURRENT_ACCOUNT();

SELECT region_id, COUNT(*) FROM smith_re_share.ceded.v_ceded_claims GROUP BY 1;   -- regions 1, 2 only


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ The Share, with a Database Role
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Database roles let one share expose different object sets to different
-- consumer roles (the consumer grants the database role to its own roles).
-- REFERENCE: shares are read-only, no data is copied, consumer pays compute.

CREATE OR REPLACE DATABASE ROLE smith_re_share.reinsurer_read;
GRANT USAGE  ON SCHEMA smith_re_share.ceded                TO DATABASE ROLE smith_re_share.reinsurer_read;
GRANT SELECT ON VIEW   smith_re_share.ceded.v_ceded_claims TO DATABASE ROLE smith_re_share.reinsurer_read;

CREATE OR REPLACE SHARE smith_reinsurance_share COMMENT = 'Ceded claims above retention';
GRANT USAGE ON DATABASE smith_re_share TO SHARE smith_reinsurance_share;
GRANT DATABASE ROLE smith_re_share.reinsurer_read TO SHARE smith_reinsurance_share;

SHOW GRANTS TO SHARE smith_reinsurance_share;

-- Test as the consumer WITHOUT a second account: SIMULATED_DATA_SHARING_CONSUMER
-- makes secure views in a share evaluate CURRENT_ACCOUNT() as the named consumer.
ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'ATLRE01';
SELECT region_id, COUNT(*) FROM smith_re_share.ceded.v_ceded_claims GROUP BY 1 ORDER BY 1;   -- regions 1–4
ALTER SESSION UNSET SIMULATED_DATA_SHARING_CONSUMER;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Add a Real Consumer
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Direct shares work within the SAME region. Cross-region or cross-cloud
-- consumers need a listing with auto-fulfillment (Module 9). Pair students in
-- the same region: each adds the partner's account and an entitlement row.
-- Reader accounts (Snowflake-managed, provider pays) are shown for reference;
-- some trial accounts cannot create them.

-- ALTER SHARE smith_reinsurance_share ADD ACCOUNTS = <partner_org>.<partner_account>;
-- INSERT INTO smith_re_share.ceded.entitlements VALUES ('<PARTNER_LOCATOR>', 'Classmate Re', 4);

-- CREATE MANAGED ACCOUNT atlantic_re_reader
--     ADMIN_NAME = 're_admin', ADMIN_PASSWORD = '<Strong-Passw0rd!>', TYPE = READER;
-- SHOW MANAGED ACCOUNTS;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Only Secure Objects Can Be Shared
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Create a NON-secure view SMITH_RE_SHARE.CEDED.V_CEDED_TOTALS (ceded
--       amount by year and line of business, filtered by entitlements like the
--       secure view). Try to grant SELECT on it to the database role. Read the
--       error, fix the view, and grant again.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ A New Treaty for the EU
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Reinsurer "Rhine Re" (locator RHINERE7) covers Ireland and Germany
--       (regions 5 and 6). Add the entitlement and prove with
--       SIMULATED_DATA_SHARING_CONSUMER that it sees only those regions and
--       that ATLRE01 still sees only 1–4. No view changes allowed.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Consume a Share
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Pair with a classmate in the same cloud region. Exchange
--       <org>.<account_name> and account locators, add each other to your
--       shares (Demo 4), then in YOUR account:
--       SHOW SHARES; create database REINSURANCE_FROM_<NAME> from their share,
--       grant their database role to SYSADMIN, and query V_CEDED_CLAIMS.
--       (Working alone? Use SHOW SHARES and describe the steps instead.)


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Who Is Using Our Data?
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: (a) Write the query a data steward would use to list every object
--           granted to SMITH_REINSURANCE_SHARE and every consumer account.
--       (b) In 2–3 sentences: Smith's claims table is updated every 5 minutes
--           by the pipeline. How fresh is the reinsurer's view of
--           CEDED_CLAIMS today, and what would you change so it is always
--           current without the reinsurer doing anything?


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP — keep the share for the Cortex lab discussion; nothing is running.
================================================================================
*/
