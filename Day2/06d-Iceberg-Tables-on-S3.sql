/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #06d — Claims History as Apache Iceberg Tables on S3  (25 minutes)
1) External volume: Snowflake writes to YOUR S3 bucket through an IAM role
2) Snowflake-managed Iceberg table (CATALOG = 'SNOWFLAKE') built with CTAS
3) DML creates new snapshots — see the Parquet and metadata files in S3
4) Time Travel on an Iceberg table; the metadata location other engines read
AWS tools: AWS CloudShell + IAM console (see Setup/AWS-Setup-Guide.md)
Prerequisite: Hands-on #06b (bucket exists; RAW.AGENCY_CLAIMS_RAW is loaded)
----------------------------------------------------------------------------------*/

/*
  SCENARIO
  Smith's data-science team uses Spark and Athena on the S3 data lake. They want
  the claims history in an open format they can read directly — without a
  nightly export — while Snowflake stays the place where it is governed and
  updated. Apache Iceberg tables give both: Parquet data + Iceberg metadata in
  Smith's bucket, with Snowflake as the catalog.

  BEFORE YOU START: create IAM policy smith-snowflake-iceberg-rw from
  ~/smith-aws/iceberg-rw-policy.json (CloudShell) and role
  smith-snowflake-iceberg-role (external ID 0000 for now). Replace
  <YOUR_BUCKET> and <ICEBERG_ROLE_ARN> below.
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ External Volume — Snowflake's Write Access to S3
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- A storage integration (Hands-on #06b) lets Snowflake READ files. An external
-- volume lets Snowflake WRITE and manage Iceberg data and metadata in your
-- bucket. Same trust pattern: an IAM role, Snowflake's IAM user, an external ID.

USE ROLE accountadmin;

CREATE OR REPLACE EXTERNAL VOLUME smith_iceberg_vol
    STORAGE_LOCATIONS = (
        (
            NAME = 'smith-s3-iceberg'
            STORAGE_PROVIDER = 'S3'
            STORAGE_BASE_URL = 's3://<YOUR_BUCKET>/iceberg/'
            STORAGE_AWS_ROLE_ARN = '<ICEBERG_ROLE_ARN>'           -- arn:aws:iam::123456789012:role/smith-snowflake-iceberg-role
        )
    )
    ALLOW_WRITES = TRUE
    COMMENT = 'Smith lakehouse — Snowflake-managed Iceberg tables';

-- The two values for the role's trust policy:
DESC EXTERNAL VOLUME smith_iceberg_vol
->> SELECT PARSE_JSON("property_value") AS loc FROM $1 WHERE "property" = 'STORAGE_LOCATION_1'
->> SELECT loc:STORAGE_AWS_IAM_USER_ARN::STRING AS iam_user_arn,
           loc:STORAGE_AWS_EXTERNAL_ID::STRING  AS external_id
    FROM $1;
-- ▶ IAM console › smith-snowflake-iceberg-role › Trust relationships: paste
--   data/aws/snowflake-trust-policy.json with these two values, then:

SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('smith_iceberg_vol');      -- "success": true

GRANT USAGE ON EXTERNAL VOLUME smith_iceberg_vol TO ROLE sysadmin;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ A Snowflake-Managed Iceberg Table, Built with CTAS
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- CATALOG = 'SNOWFLAKE': Snowflake owns the metadata and all writes; other
-- engines read. BASE_LOCATION is the folder under the volume and can't be
-- changed later. Cast to Iceberg-friendly types: STRING, DECIMAL, DATE and
-- microsecond timestamps (TIMESTAMP_NTZ(6)).

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
CREATE SCHEMA IF NOT EXISTS smith_ins.lakehouse COMMENT = 'Open-format (Iceberg) tables on Smith S3';
USE SCHEMA smith_ins.lakehouse;

CREATE OR REPLACE ICEBERG TABLE claims_history_ice
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'smith_iceberg_vol'
    BASE_LOCATION = 'claims_history'
AS
SELECT claim_id::STRING            AS claim_id,
       policy_id::STRING           AS policy_id,
       region_id::NUMBER(4,0)      AS region_id,
       line_of_business::STRING    AS line_of_business,
       claim_type::STRING          AS claim_type,
       claim_date,
       status::STRING              AS status,
       claim_amount,
       paid_amount,
       fraud_flag,
       updated_at::TIMESTAMP_NTZ(6) AS updated_at
FROM smith_ins.core.claims;

SHOW ICEBERG TABLES IN SCHEMA smith_ins.lakehouse;
SELECT line_of_business, COUNT(*), SUM(paid_amount) FROM claims_history_ice GROUP BY 1 ORDER BY 1;

-- Where other engines (Spark, Athena, Trino) find the table:
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('smith_ins.lakehouse.claims_history_ice');
-- ▶ CloudShell:  aws s3 ls s3://$BUCKET/iceberg/ --recursive | head -20
--   data/ holds Parquet files, metadata/ holds the Iceberg metadata JSON, manifests and snapshots.


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ DML Writes New Snapshots
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Full DML works on Snowflake-managed Iceberg tables. Each commit writes new
-- data files and a new metadata file; earlier files stay for Time Travel until
-- Snowflake's maintenance removes them. Compare metadataLocation before/after.

UPDATE claims_history_ice SET status = 'CLOSED', updated_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(6)
WHERE status = 'IN_REVIEW' AND claim_date < '2026-10-01';

DELETE FROM claims_history_ice WHERE line_of_business = 'UMBRELLA' AND claim_amount < 50000;

SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('smith_ins.lakehouse.claims_history_ice');   -- new vN.metadata.json
-- ▶ CloudShell:  aws s3 ls s3://$BUCKET/iceberg/ --recursive | grep -c metadata.json


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Time Travel on Iceberg
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Snowflake-managed Iceberg tables support AT / BEFORE like native tables
-- (Hands-on #04). The history lives in the Iceberg snapshots in your bucket.

SET last_update = (
    SELECT query_id FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
    WHERE query_type = 'UPDATE' AND query_text ILIKE '%claims_history_ice%'
    ORDER BY start_time DESC LIMIT 1);
SET last_delete = (
    SELECT query_id FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
    WHERE query_type = 'DELETE' AND query_text ILIKE '%claims_history_ice%'
    ORDER BY start_time DESC LIMIT 1);

SELECT COUNT(*) AS rows_now FROM claims_history_ice;
SELECT COUNT(*) AS rows_before_delete FROM claims_history_ice BEFORE (STATEMENT => $last_delete);
SELECT status, COUNT(*) FROM claims_history_ice BEFORE (STATEMENT => $last_update) GROUP BY 1;   -- IN_REVIEW is back
SELECT status, COUNT(*) FROM claims_history_ice AT (OFFSET => -30) GROUP BY 1;                   -- 30 seconds ago


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Agency Claims in Open Format
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Create Snowflake-managed Iceberg table LAKEHOUSE.AGENCY_CLAIMS_ICE
--       (BASE_LOCATION 'agency_claims') from RAW.AGENCY_CLAIMS_RAW with one row
--       per claim: claim_ref, agency_id, state, policy_id, line_of_business,
--       loss_date, reported_at and the number of line items. Iceberg has no
--       VARIANT here — extract and cast every column. Check the row count
--       against the raw table.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Undo a Bad Delete
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Someone ran the Demo 3 DELETE by mistake. Put the deleted UMBRELLA
--       claims back into CLAIMS_HISTORY_ICE using Time Travel (BEFORE
--       STATEMENT) — without re-reading CORE.CLAIMS — and prove the row count
--       matches CORE.CLAIMS again.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Native or Iceberg?
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: (a) Run the same aggregate (paid amount by region and year) on
--       CORE.CLAIMS and on CLAIMS_HISTORY_ICE and compare elapsed time and
--       partitions scanned (GET_QUERY_OPERATOR_STATS).
--       (b) In a comment: who bills the storage for each table, and name two
--       reasons Smith would keep a table native rather than Iceberg.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Partitioned for the Lake
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Spark jobs always filter claims by month. Create
--       LAKEHOUSE.CLAIMS_BY_MONTH_ICE (BASE_LOCATION 'claims_by_month') as a copy
--       of CLAIMS_HISTORY_ICE with an Iceberg partition on MONTH(claim_date).
--       In CloudShell, list its data/ folder: what changed in the layout?


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP — keep the tables for discussion. After class (in this order):
  DROP SCHEMA smith_ins.lakehouse;   DROP EXTERNAL VOLUME smith_iceberg_vol;
  then empty the bucket and delete the IAM role (Setup/AWS-Setup-Guide.md).
================================================================================
*/
