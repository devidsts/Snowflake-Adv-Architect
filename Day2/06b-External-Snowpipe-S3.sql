/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #06b — Agency Claims from Amazon S3 with Snowpipe     (30 minutes)
1) Storage integration: Snowflake ↔ IAM role trust, no keys in SQL
2) External stage over an S3 prefix; LIST and query files in place
3) Snowpipe AUTO_INGEST with PATTERN — load only the JSON files
4) Backfill with ALTER PIPE ... REFRESH, then watch new files load by event
5) Monitoring: SYSTEM$PIPE_STATUS, COPY_HISTORY, failed files
AWS tools: AWS CloudShell (see Setup/AWS-Setup-Guide.md)
Files: data/s3_agency_claims/ (60 JSON + 2 CSV)  ·  data/s3_agency_claims_late/ (5 JSON)
----------------------------------------------------------------------------------*/

/*
  SCENARIO
  Eight partner agencies drop daily claim files into Smith's S3 landing bucket.
  The folder also receives an agency directory and a monthly manifest as CSV.
  Snowflake must pick up every JSON file automatically, ignore the CSVs, and
  never hold an AWS secret.

  BEFORE YOU START (AWS CloudShell, in the unzipped lab folder):
      export BUCKET=smith-ins-landing-<your-initials>-<4 digits>
      bash data/aws/cloudshell-setup.sh
  Then create the IAM policy + role in the AWS console (guide, "IAM role").
  Replace <YOUR_BUCKET> and <ROLE_ARN> below before running.
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Storage Integration and the IAM Trust
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- The integration stores the IAM role ARN; Snowflake assumes the role through
-- its own AWS user (STORAGE_AWS_IAM_USER_ARN) with an external ID. No access
-- keys ever appear in SQL. STORAGE_ALLOWED_LOCATIONS limits where stages may
-- point. Only ACCOUNTADMIN (or CREATE INTEGRATION) can create it.

USE ROLE accountadmin;

CREATE OR REPLACE STORAGE INTEGRATION smith_s3_int
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = '<ROLE_ARN>'                       -- arn:aws:iam::123456789012:role/smith-snowflake-s3-role
    STORAGE_ALLOWED_LOCATIONS = ('s3://<YOUR_BUCKET>/agency_claims/')
    COMMENT = 'Partner agency claim drops';

DESC STORAGE INTEGRATION smith_s3_int;
-- ▶ Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID into the role's
--   trust policy (data/aws/snowflake-trust-policy.json) in the AWS console.

GRANT USAGE ON INTEGRATION smith_s3_int TO ROLE sysadmin;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ External Stage — Look Before You Load
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- LIST proves the trust works (an AccessDenied here = trust policy or bucket
-- name). The folder holds 62 files: 60 JSON claim drops and 2 CSVs.

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.raw;

CREATE OR REPLACE FILE FORMAT ff_ndjson TYPE = JSON;       -- one claim per line
CREATE OR REPLACE FILE FORMAT ff_csv_skip_header TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"';

CREATE OR REPLACE STAGE agency_s3_stage
    URL = 's3://<YOUR_BUCKET>/agency_claims/'
    STORAGE_INTEGRATION = smith_s3_int
    FILE_FORMAT = ff_ndjson;

LIST @agency_s3_stage;                                       -- 62 files
LIST @agency_s3_stage PATTERN = '.*[.]json';                 -- 60 files
LIST @agency_s3_stage PATTERN = '.*[.]csv';                  -- 2 files

SELECT $1:claim_ref::STRING          AS claim_ref,
       $1:agency.agency_name::STRING AS agency,
       $1:line_of_business::STRING   AS lob,
       METADATA$FILENAME             AS file_name
FROM @agency_s3_stage (PATTERN => '.*2026-09-01[.]json')
LIMIT 5;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ The Pipe — JSON Only
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- PATTERN in the pipe's COPY filters every file the pipe sees, so the CSVs in
-- the same prefix are never loaded. (Snowflake recommends also filtering at
-- the S3 event — prefix/suffix — to cut event noise; we keep the CSVs in the
-- folder on purpose.) The default ON_ERROR for Snowpipe is SKIP_FILE.

CREATE OR REPLACE TABLE agency_claims_raw (
    record     VARIANT,
    file_name  VARCHAR,
    file_row   NUMBER,
    loaded_at  TIMESTAMP_LTZ
);

CREATE OR REPLACE PIPE agency_claims_pipe
    AUTO_INGEST = TRUE
    COMMENT = 'Partner agency JSON claim drops from S3'
AS
COPY INTO agency_claims_raw (record, file_name, file_row, loaded_at)
FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
      FROM @agency_s3_stage)
PATTERN = '.*[.]json'
FILE_FORMAT = (FORMAT_NAME = 'smith_ins.raw.ff_ndjson');

DESC PIPE agency_claims_pipe;
-- ▶ Copy notification_channel (an SQS queue ARN) into the bucket's event
--   notification: prefix agency_claims/, All object create events
--   (console, or data/aws/s3-event-notification.json with the AWS CLI).


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Backfill the Files That Were Already There
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Events only fire for NEW objects. Files uploaded before the notification
-- existed are queued with REFRESH (files staged in the last 7 days only).
-- REFRESH is for one-off backfills, not a schedule.

ALTER PIPE agency_claims_pipe REFRESH;

SELECT SYSTEM$PIPE_STATUS('smith_ins.raw.agency_claims_pipe');   -- pendingFileCount

-- After ~1 minute:
SELECT COUNT(*) AS claims, COUNT(DISTINCT file_name) AS files FROM agency_claims_raw;   -- 12,048 / 60


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ New Files Load by Themselves
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- In CloudShell:   aws s3 cp data/s3_agency_claims_late/ s3://$BUCKET/agency_claims/ --recursive
-- S3 sends one event per object to the pipe's queue; nothing in Snowflake is
-- scheduled. One of the five files is malformed — see what happens to it.

SELECT file_name, status, row_count, row_parsed, first_error_message, last_load_time
FROM TABLE(smith_ins.information_schema.copy_history(
        TABLE_NAME => 'SMITH_INS.RAW.AGENCY_CLAIMS_RAW',
        START_TIME => DATEADD(hour, -2, CURRENT_TIMESTAMP())))
WHERE file_name LIKE '%2026-11-%'
ORDER BY last_load_time DESC;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Prove the CSVs Were Skipped
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: (a) Compare the files on the stage with the files in COPY_HISTORY and
--       return the names that were NOT loaded.
--       (b) Query AGENCY_DIRECTORY.CSV straight from the stage with the
--       FF_CSV_SKIP_HEADER file format (columns $1..$5) — no table needed.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ The File That Failed
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Find the late-arrival file with status LOAD_FAILED and its first error.
--       Then list every error in it with VALIDATE_PIPE_LOAD. How many good
--       records in that file were NOT loaded, and why?


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ From Raw JSON to Rows
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Create view RAW.V_AGENCY_CLAIM_LINES with claim_ref, agency_id, state,
--       policy_id, line_of_business, loss_date and ONE ROW PER LINE ITEM (item,
--       amount) using LATERAL FLATTEN. Then report total claimed amount and
--       claim count by agency for September 2026.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Reconcile Against the Manifest
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: The agencies' DAILY_MANIFEST_2026-09.CSV lists every JSON file and its
--       record count. Load it into RAW.AGENCY_MANIFEST with ONE COPY INTO that
--       uses PATTERN, then report any file whose manifest count differs from
--       the rows Snowpipe loaded (expected: none).


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP — pause the pipe so new S3 objects are not loaded after class
================================================================================
*/
ALTER PIPE smith_ins.raw.agency_claims_pipe SET PIPE_EXECUTION_PAUSED = TRUE;
-- Hands-on #06c reads RAW.AGENCY_CLAIMS_RAW — keep the table.
