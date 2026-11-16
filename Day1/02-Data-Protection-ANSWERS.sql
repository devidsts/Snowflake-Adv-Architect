/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #02 — Protecting Policyholder Data
----------------------------------------------------------------------------------*/

USE WAREHOUSE smith_wh;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Conditional Masking on Fraud Notes
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE smith_policy_admin;
USE SCHEMA smith_ins.governance;

CREATE OR REPLACE MASKING POLICY fraud_notes_mask AS (notes STRING, fraud BOOLEAN) RETURNS STRING ->
    CASE WHEN fraud AND NOT IS_ROLE_IN_SESSION('SMITH_COMPLIANCE') THEN '*** Restricted: SIU case ***'
         ELSE notes END;

ALTER TABLE smith_ins.core.claims MODIFY COLUMN adjuster_notes
    SET MASKING POLICY fraud_notes_mask USING (adjuster_notes, fraud_flag);

USE ROLE smith_claims_analyst;
USE SECONDARY ROLES NONE;
SELECT fraud_flag, LEFT(adjuster_notes, 60) AS notes
FROM smith_ins.core.claims
WHERE fraud_flag
LIMIT 5;
-- [TEACHING NOTE]
-- Conditional masking: the first argument is the masked column, later arguments
-- are other columns of the same row that drive the decision. Common uses:
-- consent flags, record sensitivity, tenant IDs.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Entitlements as Data
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE securityadmin;
GRANT ROLE smith_core_ro TO ROLE smith_underwriter;

USE ROLE smith_policy_admin;
INSERT INTO smith_ins.governance.region_access VALUES ('SMITH_UNDERWRITER', 1), ('SMITH_UNDERWRITER', 5);

USE ROLE smith_underwriter;
USE SECONDARY ROLES NONE;
SELECT region_id, COUNT(*) FROM smith_ins.core.claims GROUP BY 1 ORDER BY 1;   -- 1 and 5 only
-- [TEACHING NOTE]
-- No policy change, no downtime. Mapping tables are themselves sensitive:
-- they live in the managed-access GOVERNANCE schema owned by the policy team.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Extend Tag-Based Masking to Addresses
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE smith_policy_admin;
ALTER TAG smith_ins.governance.pii_type ADD ALLOWED_VALUES 'address';
ALTER TABLE smith_ins.core.policyholders MODIFY COLUMN street SET TAG smith_ins.governance.pii_type = 'address';

USE ROLE smith_claims_analyst;
SELECT holder_id, street, city FROM smith_ins.core.policyholders LIMIT 3;     -- street = ***MASKED***
-- [TEACHING NOTE]
-- This is the scale benefit of tag-based masking: protecting a new column is a
-- tagging decision, not a policy change. Pair with classification to find
-- columns that should be tagged.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Protection Report for the Auditors
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE smith_policy_admin;
SELECT 'POLICYHOLDERS' AS table_name, ref_column_name, ref_arg_column_names, policy_kind, policy_name,
       IFF(tag_name IS NULL, 'DIRECT', 'TAG: ' || tag_name || ' = ' || tag_value) AS applied_through
FROM TABLE(smith_ins.information_schema.policy_references(
        ref_entity_name => 'smith_ins.core.policyholders', ref_entity_domain => 'table'))
UNION ALL
SELECT 'CLAIMS', ref_column_name, ref_arg_column_names, policy_kind, policy_name,
       IFF(tag_name IS NULL, 'DIRECT', 'TAG: ' || tag_name || ' = ' || tag_value)
FROM TABLE(smith_ins.information_schema.policy_references(
        ref_entity_name => 'smith_ins.core.claims', ref_entity_domain => 'table'))
ORDER BY table_name, policy_kind, ref_column_name;
-- [TEACHING NOTE]
-- Expect: SSN (direct), EMAIL/PHONE/STREET/DATE_OF_BIRTH (tag), ADJUSTER_NOTES
-- (direct, conditional on FRAUD_FLAG) and the REGION_RAP row access policy on
-- CLAIMS.REGION_ID. For an account-wide view use
-- SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES (with latency).
USE ROLE sysadmin;
