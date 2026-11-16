/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #02 — Protecting Policyholder Data                (30 minutes)
1) Centralized policy administration (APPLY privileges)
2) Dynamic data masking with role awareness
3) Row access policies with a mapping table
4) Sensitive data classification and tag-based masking
5) Auditing: POLICY_REFERENCES and ACCESS_HISTORY
Prerequisite: Hands-on #01 (roles)
----------------------------------------------------------------------------------*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ A Central Policy Administrator
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Centralized model: one governance role creates policies and tags in the
-- managed-access GOVERNANCE schema and applies them anywhere using account-level
-- APPLY privileges. Table owners cannot remove the protection.

USE ROLE useradmin;
CREATE ROLE IF NOT EXISTS smith_policy_admin COMMENT = 'Functional: data protection policies';

USE ROLE securityadmin;
GRANT ROLE smith_policy_admin TO ROLE sysadmin;
SET me = CURRENT_USER();
GRANT ROLE smith_policy_admin TO USER IDENTIFIER($me);
GRANT USAGE ON WAREHOUSE smith_wh TO ROLE smith_policy_admin;
GRANT ROLE smith_core_ro TO ROLE smith_policy_admin;               -- read CORE to test
GRANT USAGE ON SCHEMA smith_ins.governance TO ROLE smith_policy_admin;
GRANT CREATE MASKING POLICY, CREATE ROW ACCESS POLICY, CREATE TAG, CREATE TABLE
      ON SCHEMA smith_ins.governance TO ROLE smith_policy_admin;

USE ROLE accountadmin;
GRANT APPLY MASKING POLICY    ON ACCOUNT TO ROLE smith_policy_admin;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE smith_policy_admin;
GRANT APPLY TAG               ON ACCOUNT TO ROLE smith_policy_admin;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Dynamic Data Masking on SSN
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- IS_ROLE_IN_SESSION respects the role hierarchy and secondary roles.
-- Watch the SYSADMIN result: SYSADMIN inherits SMITH_COMPLIANCE (Lab 01), so it
-- sees full SSNs. Role hierarchy design and masking design are the same design.
-- The policy handles both SSN formats in the data (with and without dashes).

USE ROLE smith_policy_admin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.governance;

CREATE OR REPLACE MASKING POLICY ssn_mask AS (val STRING) RETURNS STRING ->
    CASE WHEN IS_ROLE_IN_SESSION('SMITH_COMPLIANCE')     THEN val
         WHEN IS_ROLE_IN_SESSION('SMITH_CLAIMS_ANALYST') THEN 'XXX-XX-' || RIGHT(REPLACE(val, '-', ''), 4)
         ELSE '***MASKED***' END
    COMMENT = 'SSN: full for compliance, last 4 for claims analysts';

ALTER TABLE smith_ins.core.policyholders MODIFY COLUMN ssn SET MASKING POLICY ssn_mask;

USE ROLE smith_compliance;     USE SECONDARY ROLES NONE;
SELECT holder_id, ssn FROM smith_ins.core.policyholders LIMIT 3;
USE ROLE smith_claims_analyst;
SELECT holder_id, ssn FROM smith_ins.core.policyholders LIMIT 3;
USE ROLE smith_policy_admin;
SELECT holder_id, ssn FROM smith_ins.core.policyholders LIMIT 3;
USE ROLE sysadmin;
SELECT holder_id, ssn FROM smith_ins.core.policyholders LIMIT 3;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Row Access Policy with a Mapping Table
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- The mapping table keeps entitlements as data: adding a region to a role is an
-- INSERT, not a policy change. IS_ROLE_IN_SESSION(m.role_name) evaluates the
-- mapping against every role in the session.
-- US claims analysts see US regions only; a new EU role sees EU regions.

USE ROLE useradmin;
CREATE ROLE IF NOT EXISTS smith_eu_claims_analyst COMMENT = 'Functional: EU claims analytics';
USE ROLE securityadmin;
GRANT ROLE smith_core_ro TO ROLE smith_eu_claims_analyst;
GRANT USAGE ON WAREHOUSE smith_wh TO ROLE smith_eu_claims_analyst;
GRANT ROLE smith_eu_claims_analyst TO ROLE sysadmin;
GRANT ROLE smith_eu_claims_analyst TO USER IDENTIFIER($me);

USE ROLE smith_policy_admin;
CREATE OR REPLACE TABLE smith_ins.governance.region_access (role_name VARCHAR, region_id NUMBER);
INSERT INTO smith_ins.governance.region_access VALUES
    ('SMITH_CLAIMS_ANALYST', 1), ('SMITH_CLAIMS_ANALYST', 2), ('SMITH_CLAIMS_ANALYST', 3), ('SMITH_CLAIMS_ANALYST', 4),
    ('SMITH_EU_CLAIMS_ANALYST', 5), ('SMITH_EU_CLAIMS_ANALYST', 6);

CREATE OR REPLACE ROW ACCESS POLICY region_rap AS (p_region_id NUMBER) RETURNS BOOLEAN ->
    IS_ROLE_IN_SESSION('SMITH_COMPLIANCE')
    OR EXISTS (SELECT 1 FROM smith_ins.governance.region_access m
               WHERE IS_ROLE_IN_SESSION(m.role_name) AND m.region_id = p_region_id)
    COMMENT = 'Region entitlements from GOVERNANCE.REGION_ACCESS';

ALTER TABLE smith_ins.core.claims ADD ROW ACCESS POLICY region_rap ON (region_id);

USE ROLE smith_claims_analyst;     USE SECONDARY ROLES NONE;
SELECT region_id, COUNT(*) FROM smith_ins.core.claims GROUP BY 1 ORDER BY 1;     -- regions 1–4
USE ROLE smith_eu_claims_analyst;
SELECT region_id, COUNT(*) FROM smith_ins.core.claims GROUP BY 1 ORDER BY 1;     -- regions 5–6


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Classify, Tag and Mask by Tag
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Classification samples the data and proposes semantic and privacy categories.
-- Tag-based masking: attach masking policies to a TAG; every column carrying
-- the tag is protected, including columns tagged in the future. One policy per
-- data type can be attached to a tag (STRING and DATE below).
-- A column-level policy (like SSN above) takes precedence over a tag policy.

USE ROLE accountadmin;      -- classification reads data and may need elevated privileges in class
CALL SYSTEM$CLASSIFY('smith_ins.core.policyholders', {'auto_tag': false});

USE ROLE smith_policy_admin;
CREATE OR REPLACE TAG smith_ins.governance.pii_type
    ALLOWED_VALUES 'email', 'phone', 'date_of_birth'
    COMMENT = 'Personal data category';

CREATE OR REPLACE MASKING POLICY pii_string_mask AS (val STRING) RETURNS STRING ->
    CASE WHEN IS_ROLE_IN_SESSION('SMITH_COMPLIANCE') THEN val
         WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('smith_ins.governance.pii_type') = 'email'
              THEN REGEXP_REPLACE(val, '^[^@]+', '*****')
         ELSE '***MASKED***' END;

CREATE OR REPLACE MASKING POLICY pii_date_mask AS (val DATE) RETURNS DATE ->
    CASE WHEN IS_ROLE_IN_SESSION('SMITH_COMPLIANCE') THEN val
         ELSE DATE_FROM_PARTS(YEAR(val), 1, 1) END;          -- keep year for age analysis

ALTER TAG smith_ins.governance.pii_type SET MASKING POLICY pii_string_mask, MASKING POLICY pii_date_mask;

ALTER TABLE smith_ins.core.policyholders MODIFY
    COLUMN email         SET TAG smith_ins.governance.pii_type = 'email',
    COLUMN phone         SET TAG smith_ins.governance.pii_type = 'phone',
    COLUMN date_of_birth SET TAG smith_ins.governance.pii_type = 'date_of_birth';

USE ROLE smith_claims_analyst;
SELECT holder_id, email, phone, date_of_birth FROM smith_ins.core.policyholders LIMIT 3;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Audit: Which Policies Protect This Table? Who Read It?
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- POLICY_REFERENCES is real time. ACCESS_HISTORY (Enterprise+) records which
-- columns each query read, including the policies applied — but ACCOUNT_USAGE
-- has up to ~3 hours of latency. Run the second query tomorrow morning as a
-- recap, or show it in an account with history.

USE ROLE smith_policy_admin;
SELECT policy_kind, policy_name, ref_column_name, tag_name
FROM TABLE(smith_ins.information_schema.policy_references(
        ref_entity_name => 'smith_ins.core.policyholders', ref_entity_domain => 'table'))
ORDER BY policy_kind, ref_column_name;

USE ROLE accountadmin;
SELECT ah.query_start_time, ah.user_name, col.value:columnName::STRING AS column_name
FROM snowflake.account_usage.access_history ah,
     LATERAL FLATTEN(ah.base_objects_accessed) obj,
     LATERAL FLATTEN(obj.value:columns) col
WHERE obj.value:objectName::STRING = 'SMITH_INS.CORE.POLICYHOLDERS'
  AND col.value:columnName::STRING = 'SSN'
ORDER BY ah.query_start_time DESC
LIMIT 20;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Conditional Masking on Fraud Notes
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Adjuster notes on suspected fraud claims are sensitive. As
--       SMITH_POLICY_ADMIN, create masking policy FRAUD_NOTES_MASK that takes
--       the notes AND the FRAUD_FLAG column, returns '*** Restricted: SIU case ***'
--       when FRAUD_FLAG is TRUE and the role is not SMITH_COMPLIANCE, and the
--       real notes otherwise. Apply it to CORE.CLAIMS.ADJUSTER_NOTES using
--       ... SET MASKING POLICY fraud_notes_mask USING (adjuster_notes, fraud_flag).
--       Verify as SMITH_CLAIMS_ANALYST.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Entitlements as Data
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Smith opened a shared-services team that may see the Northeast (1) and
--       Ireland (5). Without changing REGION_RAP, give SMITH_UNDERWRITER those
--       two regions (grant it SMITH_CORE_RO as well) and verify the counts as
--       SMITH_UNDERWRITER with secondary roles off.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Extend Tag-Based Masking to Addresses
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Add the allowed value 'address' to the PII_TYPE tag, tag the STREET
--       column with it, and confirm a claims analyst now sees it masked —
--       without creating or altering any masking policy.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Protection Report for the Auditors
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Produce one result listing every policy protecting CORE.POLICYHOLDERS
--       and CORE.CLAIMS: table, column(s), policy kind, policy name, and whether
--       it is applied directly or through a tag.
--       Hint: call POLICY_REFERENCES once per table and UNION ALL the results.


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP
  Keep the policies — later labs run as SYSADMIN, which inherits
  SMITH_COMPLIANCE and therefore sees unmasked data.
================================================================================
*/
USE ROLE sysadmin;
