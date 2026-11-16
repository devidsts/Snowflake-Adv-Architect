/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #01 — RBAC Design for Smith Insurance            (30 minutes)
1) Access roles vs. functional roles, rolled up to SYSADMIN
2) Object grants, future grants and managed access schemas
3) Testing access with primary and secondary roles
4) Network rules and policies scoped to a service user
5) Key-pair authentication for service users
----------------------------------------------------------------------------------*/

/*
  TARGET DESIGN
                     SYSADMIN
        ┌──────────────┼──────────────┬──────────────┐
  SMITH_CLAIMS_ANALYST  SMITH_UNDERWRITER  SMITH_COMPLIANCE  SMITH_ENGINEER   ← functional roles (granted to people)
        │                    │                  │                 │
  SMITH_CORE_RO  SMITH_ANALYTICS_RO  SMITH_ANALYTICS_RW  SMITH_CORE_RW        ← access roles (hold privileges)
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Create Access Roles and Functional Roles
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- USERADMIN creates roles and users; SECURITYADMIN manages grants.
-- Access roles describe WHAT can be done to WHICH objects; functional roles
-- describe a JOB. People only ever get functional roles.
-- Every custom role must roll up to SYSADMIN, or SYSADMIN cannot manage the
-- objects those roles create.

USE ROLE useradmin;

CREATE ROLE IF NOT EXISTS smith_core_ro        COMMENT = 'Access: read CORE';
CREATE ROLE IF NOT EXISTS smith_core_rw        COMMENT = 'Access: read/write CORE';
CREATE ROLE IF NOT EXISTS smith_analytics_ro   COMMENT = 'Access: read ANALYTICS';
CREATE ROLE IF NOT EXISTS smith_analytics_rw   COMMENT = 'Access: build in ANALYTICS';

CREATE ROLE IF NOT EXISTS smith_claims_analyst COMMENT = 'Functional: claims analytics';
CREATE ROLE IF NOT EXISTS smith_underwriter    COMMENT = 'Functional: underwriting';
CREATE ROLE IF NOT EXISTS smith_compliance     COMMENT = 'Functional: compliance and audit';
CREATE ROLE IF NOT EXISTS smith_engineer       COMMENT = 'Functional: data engineering';

USE ROLE securityadmin;

GRANT ROLE smith_core_ro      TO ROLE smith_core_rw;           -- RW includes RO
GRANT ROLE smith_analytics_ro TO ROLE smith_analytics_rw;

GRANT ROLE smith_core_ro      TO ROLE smith_claims_analyst;
GRANT ROLE smith_analytics_ro TO ROLE smith_claims_analyst;
GRANT ROLE smith_analytics_ro TO ROLE smith_underwriter;
GRANT ROLE smith_core_ro      TO ROLE smith_compliance;
GRANT ROLE smith_core_rw      TO ROLE smith_engineer;
GRANT ROLE smith_analytics_rw TO ROLE smith_engineer;

GRANT ROLE smith_claims_analyst, smith_underwriter, smith_compliance, smith_engineer TO ROLE sysadmin;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Object Grants and Future Grants
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- "ON ALL" covers objects that exist today; "ON FUTURE" covers objects created
-- later. If future grants exist at both database and schema level, the
-- SCHEMA-level grants win for that schema — a common exam trap.

GRANT USAGE ON WAREHOUSE smith_wh TO ROLE smith_claims_analyst;
GRANT USAGE ON WAREHOUSE smith_wh TO ROLE smith_underwriter;
GRANT USAGE ON WAREHOUSE smith_wh TO ROLE smith_compliance;
GRANT USAGE, OPERATE ON WAREHOUSE smith_wh TO ROLE smith_engineer;

GRANT USAGE ON DATABASE smith_ins TO ROLE smith_core_ro;
GRANT USAGE ON DATABASE smith_ins TO ROLE smith_analytics_ro;

GRANT USAGE  ON SCHEMA smith_ins.core TO ROLE smith_core_ro;
GRANT SELECT ON ALL TABLES    IN SCHEMA smith_ins.core TO ROLE smith_core_ro;
GRANT SELECT ON FUTURE TABLES IN SCHEMA smith_ins.core TO ROLE smith_core_ro;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA smith_ins.core TO ROLE smith_core_ro;

GRANT INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES    IN SCHEMA smith_ins.core TO ROLE smith_core_rw;
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA smith_ins.core TO ROLE smith_core_rw;

GRANT USAGE  ON SCHEMA smith_ins.analytics TO ROLE smith_analytics_ro;
GRANT SELECT ON ALL TABLES    IN SCHEMA smith_ins.analytics TO ROLE smith_analytics_ro;
GRANT SELECT ON FUTURE TABLES IN SCHEMA smith_ins.analytics TO ROLE smith_analytics_ro;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA smith_ins.analytics TO ROLE smith_analytics_ro;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Grant Functional Roles to Yourself and Test
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- IDENTIFIER($var) lets one script work for every student's user name.
-- The INSERT should fail: claims analysts only have read access.

SET me = CURRENT_USER();
GRANT ROLE smith_claims_analyst TO USER IDENTIFIER($me);
GRANT ROLE smith_underwriter    TO USER IDENTIFIER($me);
GRANT ROLE smith_compliance     TO USER IDENTIFIER($me);
GRANT ROLE smith_engineer       TO USER IDENTIFIER($me);

USE ROLE smith_claims_analyst;
USE WAREHOUSE smith_wh;
SELECT status, COUNT(*) FROM smith_ins.core.claims GROUP BY status;

INSERT INTO smith_ins.core.regions VALUES (7, 'Test', 'US', 'US');   -- expected: insufficient privileges


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Secondary Roles
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- With secondary roles, privileges from all of a user's roles apply to queries
-- (object CREATION still uses the primary role). Useful for people with several
-- jobs; architects should decide whether to allow it per user.

USE ROLE smith_underwriter;
SELECT COUNT(*) FROM smith_ins.core.claims;          -- fails: underwriter has no CORE access

USE SECONDARY ROLES ALL;
SELECT COUNT(*) FROM smith_ins.core.claims;          -- works through the claims analyst role
USE SECONDARY ROLES NONE;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Network Rule and Policy for a Service User
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- NEVER attach a test network policy to the ACCOUNT in class — you can lock
-- yourself out. Attach it to a service user instead.
-- TYPE = SERVICE users cannot use passwords or MFA; they authenticate with key
-- pair, OAuth or workload identity. The key below is a sample public key.

USE ROLE accountadmin;

CREATE OR REPLACE NETWORK RULE smith_ins.governance.claims_feed_ips
    MODE = INGRESS TYPE = IPV4
    VALUE_LIST = ('203.0.113.0/24')
    COMMENT = 'Claims feed servers (documentation range)';

CREATE OR REPLACE NETWORK POLICY smith_claims_feed_policy
    ALLOWED_NETWORK_RULE_LIST = ('smith_ins.governance.claims_feed_ips');

USE ROLE useradmin;
CREATE OR REPLACE USER smith_etl_svc
    TYPE = SERVICE
    DEFAULT_ROLE = smith_engineer
    DEFAULT_WAREHOUSE = smith_wh
    RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArYQ01R/nIAEPQB/jB+ESUVu/e/tV9H38FemDnoqmIo66l3EsG1g7DFs6rPYlUNBgyN8Nc8aGpHTqb3se5UtXSR1SvWWz487VUrUhdxymcb4NwmQCLVJ86+EcoIICGc1BP+PYGjEp6e5FKV/uPMHILso8ccJ7TAeRIKTNdA5Bp/+CTIyOusR/2HP6W2XqG5XPTkWU0GcMpsDUdwaYeuldlvfAlAMWn5WnD3Sf2pNX0yYj1x6WrX2hhm1tYATW1VedzuHmK0x9zLooucuiQMqFDmP41D3lNknTOYfF8IYtuV7/OJ9o2sXCNh5W0z9bLij7CdfuzAao+rW9fATnKR/0XwIDAQAB'
    COMMENT = 'Claims feed service user (key pair only)';

USE ROLE securityadmin;
GRANT ROLE smith_engineer TO USER smith_etl_svc;

USE ROLE accountadmin;                       -- owner of the network policy
ALTER USER smith_etl_svc SET NETWORK_POLICY = smith_claims_feed_policy;

DESC USER smith_etl_svc
->> SELECT "property", "value" FROM $1
    WHERE "property" IN ('TYPE', 'DEFAULT_ROLE', 'RSA_PUBLIC_KEY_FP', 'NETWORK_POLICY', 'HAS_PASSWORD');


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 6 │ Audit the Design
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- SHOW GRANTS answers "what can this role do" and "who has this role".
-- SHOW FUTURE GRANTS confirms new objects will be covered.

SHOW GRANTS TO ROLE smith_core_ro;
SHOW GRANTS OF ROLE smith_engineer;
SHOW FUTURE GRANTS IN SCHEMA smith_ins.core;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Underwriter Access (table level)
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Underwriters need to read CORE.POLICIES and CORE.POLICYHOLDERS only —
--       not claims. Create access role SMITH_POLICY_RO with exactly that access
--       (plus the database and schema USAGE it needs), grant it to
--       SMITH_UNDERWRITER, then prove it: as SMITH_UNDERWRITER, count policies
--       (works) and count claims (fails).


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Future Grants in Action
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Give SMITH_ANALYTICS_RW the CREATE TABLE and CREATE VIEW privileges on
--       the ANALYTICS schema. As SMITH_ENGINEER, create table
--       ANALYTICS.CLAIMS_BY_REGION (claims count and paid amount per region).
--       Then switch to SMITH_CLAIMS_ANALYST and query it — no extra grant needed.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Access Review with ->>
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Using SHOW GRANTS TO ROLE SMITH_CORE_RO and ->>, return one row per
--       privilege type with the number of objects it applies to.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Compliance Role Without Write Paths
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Compliance auditors must be able to read CORE and run queries, but must
--       never modify data, even through secondary roles.
--       a) Confirm SMITH_COMPLIANCE cannot UPDATE CORE.CLAIMS.
--       b) Find which of YOUR roles could perform that UPDATE (hint: which
--          functional role inherits SMITH_CORE_RW?).
--       c) Explain in a comment why USE SECONDARY ROLES ALL matters for this
--          requirement, and how you would prevent it for auditors.


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP
  Keep all roles, grants and the service user — later labs use them.
================================================================================
*/
USE ROLE sysadmin;
