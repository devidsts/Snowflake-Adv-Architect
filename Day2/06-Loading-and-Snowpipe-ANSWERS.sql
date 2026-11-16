/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #06 — Loading Claims: Batch and Snowpipe
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.raw;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Query Files Before Loading
-- ──────────────────────────────────────────────────────────────────────────────
SELECT $1:claim_id::STRING           AS claim_id,
       $1:channel::STRING            AS channel,
       ARRAY_SIZE($1:line_items)     AS line_items,
       METADATA$FILENAME             AS file_name
FROM @claims_landing/feed/manual/ (FILE_FORMAT => 'smith_ins.raw.ff_json');
-- [TEACHING NOTE]
-- Querying staged files is handy for profiling a new feed before designing the
-- target table. For repeated access, an external table or a directory table
-- over the stage is the better design.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Reject Policy for a Bad File
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE premium_updates_strict LIKE premium_updates;

COPY INTO premium_updates_strict (policy_id, status, annual_premium, file_name)
FROM (SELECT $1, $2, $3, METADATA$FILENAME FROM @batch_stage/premium_updates/)
ON_ERROR = 'SKIP_FILE_1%';

SELECT file_name, status, row_count, error_count, first_error_message
FROM TABLE(smith_ins.information_schema.copy_history(
        TABLE_NAME => 'SMITH_INS.RAW.PREMIUM_UPDATES_STRICT',
        START_TIME => DATEADD(hour, -1, CURRENT_TIMESTAMP())));
-- [TEACHING NOTE]
-- good_* → LOADED. bad_* has ~2% bad rows (every 50th row: policy numbers where MOD(n, 300) = 1) → LOAD_FAILED
-- (skipped). Note the new table has its own load metadata, so the files load
-- even though PREMIUM_UPDATES already loaded them.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Pipe Monitoring Report
-- ──────────────────────────────────────────────────────────────────────────────
SELECT DATE_TRUNC('minute', last_load_time)        AS load_minute,
       COUNT(*)                                    AS files,
       SUM(row_count)                              AS rows_loaded,
       COUNT_IF(error_count > 0)                   AS files_with_errors
FROM TABLE(smith_ins.information_schema.copy_history(
        TABLE_NAME => 'SMITH_INS.RAW.CLAIMS_FEED_RAW',
        START_TIME => DATEADD(hour, -2, CURRENT_TIMESTAMP())))
GROUP BY 1
ORDER BY 1;

SELECT COUNT(*) FROM claims_feed_raw WHERE file_name LIKE 'feed/manual/%';   -- still 25
-- [TEACHING NOTE]
-- Re-uploading a file with the same name and contents is skipped: the pipe keeps
-- 14 days of load history per file path (and ETag). To reload a corrected file,
-- give it a new name, or follow Snowflake's documented reload procedure.
-- Long-term monitoring: SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY / PIPE_USAGE_HISTORY.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Feed Quality Check
-- ──────────────────────────────────────────────────────────────────────────────
WITH c AS (
    SELECT claim_id, policy_id, loss_date,
           COUNT(*)     AS line_items,
           SUM(amount)  AS line_total
    FROM v_claims_feed_lines
    GROUP BY claim_id, policy_id, loss_date
)
SELECT c.*,
       (p.policy_id IS NULL)         AS unknown_policy,
       (c.loss_date > CURRENT_DATE()) AS future_loss_date
FROM c
LEFT JOIN smith_ins.core.policies p ON p.policy_id = c.policy_id
WHERE p.policy_id IS NULL OR c.loss_date > CURRENT_DATE()
ORDER BY c.claim_id;
-- [TEACHING NOTE]
-- The manual file has 2 unknown policies and 1 future loss date. Raw zones keep
-- everything (with lineage columns) and quality rules run downstream — Module 6
-- turns these checks into scheduled data metric functions.
