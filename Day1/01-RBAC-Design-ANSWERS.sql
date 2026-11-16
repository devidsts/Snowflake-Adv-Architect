/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #01 — RBAC Design for Smith Insurance
----------------------------------------------------------------------------------*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Underwriter Access (table level)
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE useradmin;
CREATE ROLE IF NOT EXISTS smith_policy_ro COMMENT = 'Access: read policies and policyholders';

USE ROLE securityadmin;
GRANT USAGE  ON DATABASE smith_ins                     TO ROLE smith_policy_ro;
GRANT USAGE  ON SCHEMA   smith_ins.core                TO ROLE smith_policy_ro;
GRANT SELECT ON TABLE    smith_ins.core.policies       TO ROLE smith_policy_ro;
GRANT SELECT ON TABLE    smith_ins.core.policyholders  TO ROLE smith_policy_ro;
GRANT ROLE smith_policy_ro TO ROLE smith_underwriter;

USE ROLE smith_underwriter;
USE SECONDARY ROLES NONE;
USE WAREHOUSE smith_wh;
SELECT COUNT(*) FROM smith_ins.core.policies;   -- 12,000
SELECT COUNT(*) FROM smith_ins.core.claims;     -- error: does not exist or not authorized
-- [TEACHING NOTE]
-- The error says "does not exist or not authorized" on purpose: Snowflake does
-- not reveal whether an object exists to roles that cannot see it.
-- Table-level grants are precise but add maintenance; schema-level access roles
-- scale better. Discuss when each is worth it.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Future Grants in Action
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE securityadmin;
GRANT USAGE ON DATABASE smith_ins TO ROLE smith_analytics_rw;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA smith_ins.analytics TO ROLE smith_analytics_rw;

USE ROLE smith_engineer;
USE WAREHOUSE smith_wh;
CREATE OR REPLACE TABLE smith_ins.analytics.claims_by_region AS
SELECT r.region_name, COUNT(*) AS claims, SUM(c.paid_amount) AS paid
FROM smith_ins.core.claims c
JOIN smith_ins.core.regions r ON r.region_id = c.region_id
GROUP BY r.region_name;

USE ROLE smith_claims_analyst;
SELECT * FROM smith_ins.analytics.claims_by_region ORDER BY paid DESC;
-- [TEACHING NOTE]
-- The table is owned by SMITH_ENGINEER, yet the analyst can read it because the
-- FUTURE grant on ANALYTICS fired at creation time. Because SMITH_ENGINEER rolls
-- up to SYSADMIN, administrators can still manage the new table.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Access Review with ->>
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE securityadmin;
SHOW GRANTS TO ROLE smith_core_ro
->> SELECT "privilege", "granted_on", COUNT(*) AS objects
    FROM $1
    GROUP BY 1, 2
    ORDER BY 1, 2;
-- [TEACHING NOTE]
-- Expect USAGE on 1 database and 1 schema, and SELECT on 8 tables. Future
-- grants do not appear here — use SHOW FUTURE GRANTS IN SCHEMA for those.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Compliance Role Without Write Paths
-- ──────────────────────────────────────────────────────────────────────────────
-- a)
USE ROLE smith_compliance;
USE SECONDARY ROLES NONE;
UPDATE smith_ins.core.claims SET status = status WHERE 1 = 0;   -- error: insufficient privileges

-- b)
USE ROLE securityadmin;
SHOW GRANTS OF ROLE smith_core_rw;          -- granted to SMITH_ENGINEER
-- With secondary roles enabled, a person holding both SMITH_COMPLIANCE and
-- SMITH_ENGINEER could update CORE while "acting as" compliance.

-- c)
-- Secondary roles combine the privileges of every role granted to the user.
-- Separation of duties therefore depends on WHICH roles a person holds, not on
-- which role is primary. Options:
--   * Never grant SMITH_ENGINEER (or any RW role) to auditors.
--   * Restrict secondary roles for auditors with a SESSION POLICY:
--       CREATE SESSION POLICY smith_ins.governance.no_secondary_roles
--         ALLOWED_SECONDARY_ROLES = ();
--       ALTER USER <auditor> SET SESSION POLICY smith_ins.governance.no_secondary_roles;
--     (DEFAULT_SECONDARY_ROLES only sets the default; users could still run
--      USE SECONDARY ROLES ALL.)
--   * Review SHOW GRANTS OF ROLE regularly (Module 2: governance procedures).
USE ROLE sysadmin;
