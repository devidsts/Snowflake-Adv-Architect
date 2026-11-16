/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #13 — Cost Controls and Monitoring
----------------------------------------------------------------------------------*/

USE ROLE accountadmin;
USE WAREHOUSE smith_wh;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ A Weekly Cap for BI
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE RESOURCE MONITOR smith_bi_weekly_rm
    WITH CREDIT_QUOTA = 10
         FREQUENCY = WEEKLY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 75  PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND
             ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE smith_bi_wh SET RESOURCE_MONITOR = smith_bi_weekly_rm;
ALTER WAREHOUSE smith_ds_wh SET RESOURCE_MONITOR = smith_bi_weekly_rm;   -- allowed

SHOW WAREHOUSES ->> SELECT "name", "resource_monitor" FROM $1 WHERE "name" LIKE 'SMITH%';
-- [TEACHING NOTE]
-- One monitor can cover many warehouses (their credits are pooled); a warehouse
-- can have only ONE warehouse-level monitor — setting a new one replaces the
-- old. The account monitor applies on top of it. Exam favourite: monitors
-- never control serverless or AI credits — use budgets for those.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Cost by Job
-- ──────────────────────────────────────────────────────────────────────────────
ALTER SESSION SET QUERY_TAG = 'underwriting-review';
SELECT line_of_business, AVG(annual_premium) FROM smith_ins.core.policies GROUP BY 1;
SELECT status, COUNT(*) FROM smith_ins.core.policies GROUP BY 1;
ALTER SESSION SET QUERY_TAG = 'claims-monthly-close';
SELECT claim_type, SUM(paid_amount) FROM smith_ins.core.claims GROUP BY 1;
ALTER SESSION UNSET QUERY_TAG;

SELECT query_tag,
       COUNT(*)                        AS executions,
       SUM(total_elapsed_time) / 1000  AS elapsed_seconds
FROM TABLE(smith_ins.information_schema.query_history(
        END_TIME_RANGE_START => DATEADD(hour, -1, CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 10000))
WHERE query_tag <> ''
GROUP BY query_tag
ORDER BY elapsed_seconds DESC;
-- [TEACHING NOTE]
-- Elapsed time is a proxy. For credits per query use
-- SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY (latency applies), which
-- also carries QUERY_TAG — the standard chargeback source.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Find Idle Spend
-- ──────────────────────────────────────────────────────────────────────────────
SHOW WAREHOUSES
->> SELECT "name", "auto_suspend", "resource_monitor"
    FROM $1
    WHERE "auto_suspend" > 60 OR "auto_suspend" IS NULL OR "resource_monitor" = 'null';

ALTER WAREHOUSE smith_wh     SET AUTO_SUSPEND = 60;
ALTER WAREHOUSE smith_etl_wh SET AUTO_SUSPEND = 60;
ALTER WAREHOUSE smith_bi_wh  SET AUTO_SUSPEND = 60;
ALTER WAREHOUSE IF EXISTS smith_ds_wh SET AUTO_SUSPEND = 60;
-- [TEACHING NOTE]
-- A NULL/0 AUTO_SUSPEND means "never suspend" — the most expensive setting in
-- Snowflake. Very short values lose the local disk cache (Hands-on #04):
-- 60 s suits ad hoc BI; batch warehouses can go lower, steady dashboards higher.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Alert by E-mail
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE NOTIFICATION INTEGRATION smith_email_int
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('student@example.com');          -- your verified address

GRANT USAGE ON INTEGRATION smith_email_int TO ROLE sysadmin;

CREATE OR REPLACE ALERT smith_ins.governance.smith_long_query_alert
    SCHEDULE = '15 MINUTE'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(smith_ins.information_schema.query_history(
                END_TIME_RANGE_START => DATEADD(minute, -15, CURRENT_TIMESTAMP())))
        WHERE total_elapsed_time > 60000))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'smith_email_int',
            'student@example.com',
            'Smith Insurance: long-running query detected',
            'A query in the last 15 minutes ran longer than 60 seconds. Check Query History in Snowsight.');

ALTER ALERT smith_ins.governance.smith_long_query_alert RESUME;   -- new alerts start suspended
EXECUTE ALERT smith_ins.governance.smith_long_query_alert;         -- optional: run once now

SELECT name, state, sql_error_message, scheduled_time
FROM TABLE(smith_ins.information_schema.alert_history(
        SCHEDULED_TIME_RANGE_START => DATEADD(hour, -1, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;

ALTER ALERT smith_ins.governance.smith_long_query_alert SUSPEND;   -- after class, to stop the schedule
-- [TEACHING NOTE]
-- E-mail recipients must be verified users of the account. Serverless alerts
-- bill only for the seconds the condition runs — no warehouse waking every
-- 15 minutes. Run Hands-on #12's exploding join to see the alert fire.
-- Production: SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME() avoids
-- re-alerting on the same queries.
