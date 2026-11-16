/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #06b — Agency Claims from Amazon S3 with Snowpipe
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.raw;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Prove the CSVs Were Skipped
-- ──────────────────────────────────────────────────────────────────────────────
-- (a)
LIST @agency_s3_stage;
WITH staged AS (
    SELECT SPLIT_PART("name", '/', -1) AS file_name
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
loaded AS (
    SELECT DISTINCT SPLIT_PART(file_name, '/', -1) AS file_name
    FROM TABLE(smith_ins.information_schema.copy_history(
            TABLE_NAME => 'SMITH_INS.RAW.AGENCY_CLAIMS_RAW',
            START_TIME => DATEADD(day, -1, CURRENT_TIMESTAMP())))
)
SELECT s.file_name
FROM staged s
LEFT JOIN loaded l ON l.file_name = s.file_name
WHERE l.file_name IS NULL;
-- → agency_directory.csv, daily_manifest_2026-09.csv

-- (b)
SELECT $1 AS agency_id, $2 AS agency_name, $3 AS state, $4::NUMBER(4,3) AS commission_rate, $5::DATE AS contract_start
FROM @agency_s3_stage/agency_directory.csv (FILE_FORMAT => 'smith_ins.raw.ff_csv_skip_header');
-- [TEACHING NOTE]
-- RESULT_SCAN turns the LIST output into rows (run LIST immediately before).
-- Querying staged files directly is perfect for small reference files and for
-- profiling — no table, no load history.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ The File That Failed
-- ──────────────────────────────────────────────────────────────────────────────
SELECT file_name, status, row_count, row_parsed, error_count, first_error_message, first_error_line_number
FROM TABLE(smith_ins.information_schema.copy_history(
        TABLE_NAME => 'SMITH_INS.RAW.AGENCY_CLAIMS_RAW',
        START_TIME => DATEADD(day, -1, CURRENT_TIMESTAMP())))
WHERE status <> 'Loaded';

SELECT error, file, line, character
FROM TABLE(smith_ins.information_schema.validate_pipe_load(
        PIPE_NAME  => 'SMITH_INS.RAW.AGENCY_CLAIMS_PIPE',
        START_TIME => DATEADD(day, -1, CURRENT_TIMESTAMP())));
-- [TEACHING NOTE]
-- agency_claims_2026-11-05.json has 2 bad lines (a truncated record and an
-- unquoted key). Snowpipe's default ON_ERROR = SKIP_FILE, so all 30 records —
-- including the 28 good ones — were skipped. Options: fix the file and upload
-- it under a NEW name (the pipe remembers loaded paths), or define the pipe
-- with ON_ERROR = CONTINUE and quarantine bad rows downstream.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ From Raw JSON to Rows
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_agency_claim_lines AS
SELECT r.record:claim_ref::STRING          AS claim_ref,
       r.record:agency.agency_id::STRING   AS agency_id,
       r.record:agency.state::STRING       AS state,
       r.record:policy_id::STRING          AS policy_id,
       r.record:line_of_business::STRING   AS line_of_business,
       r.record:loss_date::DATE            AS loss_date,
       li.value:item::STRING               AS item,
       li.value:amount::NUMBER(12,2)       AS amount,
       r.file_name
FROM agency_claims_raw r,
     LATERAL FLATTEN(INPUT => r.record:line_items) li;

SELECT agency_id, state,
       COUNT(DISTINCT claim_ref) AS claims,
       SUM(amount)               AS claimed_amount
FROM v_agency_claim_lines
WHERE loss_date >= '2026-09-01' AND loss_date < '2026-10-01'
GROUP BY agency_id, state
ORDER BY claimed_amount DESC;
-- [TEACHING NOTE]
-- COUNT(DISTINCT claim_ref) because FLATTEN multiplies claims by line items —
-- the same grain trap as the exploding join in Hands-on #12.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Reconcile Against the Manifest
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE agency_manifest (file_name VARCHAR, record_count NUMBER, sent_at TIMESTAMP_NTZ);

COPY INTO agency_manifest
FROM @agency_s3_stage
PATTERN = '.*manifest.*[.]csv'
FILE_FORMAT = (FORMAT_NAME = 'smith_ins.raw.ff_csv_skip_header');

SELECT m.file_name, m.record_count AS manifest_rows, COUNT(r.file_row) AS loaded_rows
FROM agency_manifest m
LEFT JOIN agency_claims_raw r ON SPLIT_PART(r.file_name, '/', -1) = m.file_name
GROUP BY m.file_name, m.record_count
HAVING COUNT(r.file_row) <> m.record_count;
-- [TEACHING NOTE]
-- Zero rows = every September file arrived complete. The same pattern-based
-- COPY could be another pipe; bulk COPY is fine for a monthly file. Manifest
-- reconciliation is a cheap, high-value control for partner feeds.
