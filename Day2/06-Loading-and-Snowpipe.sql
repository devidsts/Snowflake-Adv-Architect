/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #06 — Loading Claims: Batch and Snowpipe           (30 minutes)
1) File formats and stages for batch files
2) Validate first, then load: VALIDATION_MODE, ON_ERROR, VALIDATE()
3) Load metadata and idempotent loads
4) Snowpipe with AUTO_INGEST on an INTERNAL stage
5) Pushing a high-volume feed (06a generator) and a manual file drop
6) Flattening nested claim line items
Files: data/claims_manual_upload.json (upload in Demo 5)
Note: AUTO_INGEST on internal stages is in public preview for AWS-hosted
      accounts. A fallback (ALTER PIPE ... REFRESH) is shown for other clouds.
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
USE SCHEMA smith_ins.raw;

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Batch Stage, File Formats and Test Files
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Named file formats keep parsing rules in one place. We create the batch files
-- ourselves by unloading (COPY INTO @stage) so no outside bucket is needed:
-- one good file of policy premium updates and one file with bad premiums.

CREATE OR REPLACE FILE FORMAT ff_csv_header
    TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL');
CREATE OR REPLACE FILE FORMAT ff_json TYPE = JSON STRIP_OUTER_ARRAY = TRUE;

CREATE OR REPLACE STAGE batch_stage FILE_FORMAT = ff_csv_header COMMENT = 'Daily batch files';

COPY INTO @batch_stage/premium_updates/good_
FROM (SELECT policy_id, status, annual_premium FROM smith_ins.core.policies WHERE MOD(TO_NUMBER(SUBSTR(policy_id, 5)), 6) = 0)
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"') HEADER = TRUE SINGLE = TRUE;

COPY INTO @batch_stage/premium_updates/bad_
FROM (SELECT policy_id, status,
             IFF(MOD(TO_NUMBER(SUBSTR(policy_id, 5)), 50) = 0, 'N/A', annual_premium::VARCHAR) AS annual_premium
      FROM smith_ins.core.policies WHERE MOD(TO_NUMBER(SUBSTR(policy_id, 5)), 6) = 1)
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"') HEADER = TRUE SINGLE = TRUE;

LIST @batch_stage;

CREATE OR REPLACE TABLE premium_updates (
    policy_id      VARCHAR(12),
    status         VARCHAR(10),
    annual_premium NUMBER(10,2),
    file_name      VARCHAR,
    loaded_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Validate, Load, Inspect Errors, Reload
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- VALIDATION_MODE parses without loading. ON_ERROR = CONTINUE loads the good
-- rows and records the rest; VALIDATE() returns the rejected rows of a job.
-- Re-running the same COPY loads 0 files: load metadata (64 days) prevents
-- duplicates. FORCE = TRUE overrides it — and creates duplicates.
-- LIMITATION: VALIDATION_MODE and VALIDATE() do not support COPY statements that
-- transform data (a column list, or a SELECT with METADATA$FILENAME). Both fail with
-- "Expression 'POLICY_ID' not supported within a VALIDATE expression". So we
-- validate against a CHECK table whose columns match the file exactly, and run the
-- real load (with lineage columns) into PREMIUM_UPDATES.

CREATE OR REPLACE TABLE premium_updates_check (
    policy_id      VARCHAR(12),
    status         VARCHAR(10),
    annual_premium NUMBER(10,2)
);

-- 1) Dry run: parse the files, load nothing, return the errors (no column list, no SELECT).
COPY INTO premium_updates_check
FROM @batch_stage/premium_updates/
VALIDATION_MODE = RETURN_ERRORS;

-- 2) Real load with lineage (this is a transforming COPY, so it cannot be validated).
COPY INTO premium_updates (policy_id, status, annual_premium, file_name)
FROM (SELECT $1, $2, $3, METADATA$FILENAME FROM @batch_stage/premium_updates/)
ON_ERROR = CONTINUE;

-- 3) Rejected rows of a job: load the check table with ON_ERROR = CONTINUE, then VALIDATE it.
COPY INTO premium_updates_check
FROM @batch_stage/premium_updates/
ON_ERROR = CONTINUE;
SELECT * FROM TABLE(VALIDATE(premium_updates_check, JOB_ID => '_last'));

COPY INTO premium_updates (policy_id, status, annual_premium, file_name)
FROM (SELECT $1, $2, $3, METADATA$FILENAME FROM @batch_stage/premium_updates/)
ON_ERROR = CONTINUE;                                   -- 0 files: already loaded


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Snowpipe on an Internal Stage
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- The landing stage receives claim files from the mobile app and agencies.
-- AUTO_INGEST = TRUE makes Snowpipe load new files automatically — no cloud
-- event setup needed for internal stages (preview, AWS).
-- The pipe captures lineage columns: file name, row number, load time.
-- Snowpipe is serverless: it does not use SMITH_WH.

CREATE OR REPLACE STAGE claims_landing
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing zone for claim files (JSON)';

CREATE OR REPLACE TABLE claims_feed_raw (
    record     VARIANT,
    file_name  VARCHAR,
    file_row   NUMBER,
    loaded_at  TIMESTAMP_LTZ
);

CREATE OR REPLACE PIPE claims_feed_pipe
    AUTO_INGEST = TRUE
    COMMENT = 'Loads claim files from @CLAIMS_LANDING'
AS
COPY INTO claims_feed_raw (record, file_name, file_row, loaded_at)
FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
      FROM @claims_landing)
FILE_FORMAT = (FORMAT_NAME = 'smith_ins.raw.ff_json');

SHOW PIPES LIKE 'CLAIMS_FEED_PIPE';
SELECT PARSE_JSON(SYSTEM$PIPE_STATUS('smith_ins.raw.claims_feed_pipe')) AS pipe_status;
-- If CREATE PIPE rejects AUTO_INGEST on an internal stage in your region, create
-- it without AUTO_INGEST and use the REFRESH fallback in Demo 4.


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ Push a High-Volume Feed
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Open Day2/06a-Claims-Feed-Generator.sql and Run All: it writes 20 files of
-- 5,000 claims each into @CLAIMS_LANDING/feed/. Then watch the pipe work.
-- Snowpipe typically loads within a minute or two of the files landing.

-- >>> Run Day2/06a-Claims-Feed-Generator.sql now <<<

SELECT PARSE_JSON(SYSTEM$PIPE_STATUS('smith_ins.raw.claims_feed_pipe')):pendingFileCount AS pending_files;

SELECT COUNT(*) AS rows_loaded, COUNT(DISTINCT file_name) AS files_loaded FROM claims_feed_raw;

SELECT file_name, status, row_count, row_parsed, first_error_message, last_load_time
FROM TABLE(smith_ins.information_schema.copy_history(
        TABLE_NAME => 'SMITH_INS.RAW.CLAIMS_FEED_RAW',
        START_TIME => DATEADD(hour, -1, CURRENT_TIMESTAMP())))
ORDER BY last_load_time DESC;

-- Fallback (no internal auto-ingest in this region): queue staged files manually.
-- ALTER PIPE claims_feed_pipe REFRESH;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Drop One File by Hand — It Loads Itself
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Upload data/claims_manual_upload.json into the SAME stage:
--   Snowsight: Catalog > Database Explorer > SMITH_INS > RAW > Stages >
--              CLAIMS_LANDING > "+ Files", path: feed/manual
--   or Snowflake CLI:
--     snow stage copy data/claims_manual_upload.json @smith_ins.raw.claims_landing/feed/manual/
-- No COPY command is run — Snowpipe sees the new file and loads it.
-- The file contains 25 claims; watch the count increase by 25.

SELECT COUNT(*) FROM claims_feed_raw WHERE file_name LIKE 'feed/manual/%';

SELECT record:claim_id::STRING AS claim_id, record:channel::STRING AS channel, file_name, loaded_at
FROM claims_feed_raw
WHERE file_name LIKE 'feed/manual/%'
ORDER BY file_row
LIMIT 10;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 6 │ Flatten Line Items
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Each claim carries an array of line items. LATERAL FLATTEN turns the array
-- into rows; cast VARIANT paths to native types for performance and pruning.

CREATE OR REPLACE VIEW v_claims_feed_lines AS
SELECT f.record:claim_id::STRING         AS claim_id,
       f.record:policy_id::STRING        AS policy_id,
       f.record:claim_type::STRING       AS claim_type,
       f.record:loss_date::DATE          AS loss_date,
       f.record:channel::STRING          AS channel,
       li.index + 1                      AS line_no,
       li.value:item::STRING             AS item,
       li.value:amount::NUMBER(12,2)     AS amount,
       f.file_name
FROM claims_feed_raw f,
     LATERAL FLATTEN(INPUT => f.record:line_items) li;

SELECT item, COUNT(*) AS lines, SUM(amount) AS total FROM v_claims_feed_lines GROUP BY item;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Query Files Before Loading
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Without loading anything, query the staged JSON in
--       @CLAIMS_LANDING/feed/manual/ directly and return claim_id, channel and
--       the number of line items per claim (ARRAY_SIZE). Use FILE_FORMAT =>.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Reject Policy for a Bad File
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Smith's rule: skip a whole batch file if more than 1% of its rows are
--       bad. Create table PREMIUM_UPDATES_STRICT like PREMIUM_UPDATES and load
--       @batch_stage/premium_updates/ with ON_ERROR = 'SKIP_FILE_1%'.
--       Which file was loaded and which was skipped? (Use COPY_HISTORY.)


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Pipe Monitoring Report
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: From COPY_HISTORY for CLAIMS_FEED_RAW (last 2 hours) report, per
--       minute of LAST_LOAD_TIME: files loaded, rows loaded and files with
--       errors. Then upload claims_manual_upload.json a SECOND time to
--       feed/manual/ — does the row count change? Explain in a comment.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Feed Quality Check
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: For every claim in CLAIMS_FEED_RAW return claim_id, the number of
--       line items and the line-item total, and flag claims whose POLICY_ID
--       does not exist in CORE.POLICIES or whose loss_date is in the future.
--       Return only flagged claims. (The manual file contains a few on purpose.)


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP
  Keep the stage, pipe and tables — Hands-on #10 builds a pipeline on them.
  To stop ingestion temporarily:  ALTER PIPE claims_feed_pipe SET PIPE_EXECUTION_PAUSED = TRUE;
================================================================================
*/
