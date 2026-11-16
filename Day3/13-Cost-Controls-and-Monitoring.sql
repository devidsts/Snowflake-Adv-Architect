/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #13 — Cost Controls and Monitoring                    (25 minutes)
1) Where the credits go: metering history and cost attribution
2) Resource monitors on a warehouse and on the account
3) Alerts: a scheduled condition that takes an action
4) Budgets for serverless and AI spend
----------------------------------------------------------------------------------*/

/*
  SCENARIO
  Smith's finance team wants three things before the platform goes to every
  claims office: a hard stop on runaway warehouses, an early warning when the
  ETL warehouse burns more than expected, and a cap on serverless/AI spend
  (Snowpipe, DMFs, clustering, Cortex) that resource monitors cannot see.

  NOTE  Only ACCOUNTADMIN can create resource monitors. To receive the e-mails,
  verify your e-mail address and turn on notifications in Snowsight:
  your name (bottom left) » Settings/Profile » Notifications » "Enable
  notifications from resource monitors".
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

USE ROLE accountadmin;
USE WAREHOUSE smith_wh;

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Where Did the Credits Go?
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- INFORMATION_SCHEMA table functions are near real-time (good for the class);
-- ACCOUNT_USAGE keeps a year but lags by up to a few hours. Note the split
-- between compute credits and cloud-services credits.

SELECT warehouse_name,
       ROUND(SUM(credits_used_compute), 3)        AS compute_credits,
       ROUND(SUM(credits_used_cloud_services), 3) AS cloud_services_credits,
       ROUND(SUM(credits_used), 3)                AS total_credits
FROM TABLE(smith_ins.information_schema.warehouse_metering_history(
        DATE_RANGE_START => DATEADD(day, -3, CURRENT_TIMESTAMP())))
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- Serverless features have their own history views (latency applies):
SELECT service_type, ROUND(SUM(credits_used), 3) AS credits
FROM snowflake.account_usage.metering_history
WHERE start_time >= DATEADD(day, -3, CURRENT_TIMESTAMP())
GROUP BY service_type
ORDER BY credits DESC;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Cost Attribution with Tags
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Two attribution tools: an object TAG on the warehouse (who owns this
-- compute?) and a QUERY_TAG on the session (which job ran this query?).
-- Both appear in ACCOUNT_USAGE and in Snowsight cost management.

CREATE TAG IF NOT EXISTS smith_ins.governance.cost_center
    ALLOWED_VALUES 'CLAIMS', 'UNDERWRITING', 'DATA_PLATFORM', 'ANALYTICS';

ALTER WAREHOUSE smith_etl_wh SET TAG smith_ins.governance.cost_center = 'DATA_PLATFORM';
ALTER WAREHOUSE smith_bi_wh  SET TAG smith_ins.governance.cost_center = 'ANALYTICS';
ALTER WAREHOUSE smith_wh     SET TAG smith_ins.governance.cost_center = 'CLAIMS';

SELECT SYSTEM$GET_TAG('smith_ins.governance.cost_center', 'smith_etl_wh', 'warehouse') AS etl_wh_cost_center;

ALTER SESSION SET QUERY_TAG = 'claims-monthly-close';
SELECT line_of_business, SUM(paid_amount) FROM smith_ins.core.claims GROUP BY 1;
ALTER SESSION UNSET QUERY_TAG;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Resource Monitors
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- A warehouse monitor caps the warehouses assigned to it; an account monitor
-- caps ALL warehouses together. Actions: NOTIFY, SUSPEND (lets running queries
-- finish) and SUSPEND_IMMEDIATE (cancels them). Monitors track WAREHOUSE
-- credits only — not Snowpipe, clustering, DMFs, serverless tasks or Cortex.

CREATE OR REPLACE RESOURCE MONITOR smith_etl_daily_rm
    WITH CREDIT_QUOTA = 5
         FREQUENCY = DAILY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 50  PERCENT DO NOTIFY
             ON 90  PERCENT DO SUSPEND
             ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE smith_etl_wh SET RESOURCE_MONITOR = smith_etl_daily_rm;

-- Account-wide safety net for the trial (generous, so class work is not blocked):
CREATE OR REPLACE RESOURCE MONITOR smith_account_rm
    WITH CREDIT_QUOTA = 100
         FREQUENCY = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 75  PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND;

ALTER ACCOUNT SET RESOURCE_MONITOR = smith_account_rm;

SHOW RESOURCE MONITORS;      -- credit_quota, used_credits, remaining_credits, level, frequency
SHOW WAREHOUSES ->> SELECT "name", "size", "resource_monitor" FROM $1;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ An Alert That Watches Spend
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- An alert = schedule + condition (a query) + action (any SQL). Here the action
-- writes to a log table so it works in every account; swap it for
-- SYSTEM$SEND_EMAIL once a notification integration exists (Exercise 4).
-- No WAREHOUSE → serverless alert.

GRANT EXECUTE ALERT ON ACCOUNT TO ROLE sysadmin;

CREATE TABLE IF NOT EXISTS smith_ins.governance.cost_alert_log (
    logged_at TIMESTAMP_LTZ, alert_name VARCHAR, detail VARCHAR);

CREATE OR REPLACE ALERT smith_ins.governance.etl_spend_alert
    SCHEDULE = '60 MINUTE'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(smith_ins.information_schema.warehouse_metering_history(
                DATE_RANGE_START => DATEADD(hour, -24, CURRENT_TIMESTAMP()),
                WAREHOUSE_NAME   => 'SMITH_ETL_WH'))
        HAVING SUM(credits_used) > 0.1))
    THEN
        INSERT INTO smith_ins.governance.cost_alert_log
        SELECT CURRENT_TIMESTAMP(), 'ETL_SPEND_ALERT',
               'SMITH_ETL_WH used more than 0.1 credits in the last 24 hours';

ALTER ALERT smith_ins.governance.etl_spend_alert RESUME;
EXECUTE ALERT smith_ins.governance.etl_spend_alert;       -- run now instead of waiting

-- Wait ~30 seconds, then:
SELECT name, state, condition_query_id, scheduled_time, completed_time
FROM TABLE(smith_ins.information_schema.alert_history(
        SCHEDULED_TIME_RANGE_START => DATEADD(hour, -1, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;
SELECT * FROM smith_ins.governance.cost_alert_log;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Budgets for Serverless and AI Spend
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Budgets cover what resource monitors can't: serverless features and AI.
-- The account budget is activated once; custom budgets track a group of
-- objects. Budgets notify — they do not suspend. If the budget calls fail in
-- your trial, do this part in Snowsight: Admin » Cost Management » Budgets.

CALL snowflake.local.account_root_budget!ACTIVATE();
CALL snowflake.local.account_root_budget!SET_SPENDING_LIMIT(50);

CREATE SNOWFLAKE.CORE.BUDGET IF NOT EXISTS smith_ins.governance.claims_pipeline_budget();
CALL smith_ins.governance.claims_pipeline_budget!SET_SPENDING_LIMIT(10);
CALL smith_ins.governance.claims_pipeline_budget!ADD_RESOURCE(
        SYSTEM$REFERENCE('DATABASE', 'SMITH_INS', 'SESSION', 'APPLYBUDGET'));

CALL smith_ins.governance.claims_pipeline_budget!GET_SPENDING_LIMIT();
CALL smith_ins.governance.claims_pipeline_budget!GET_LINKED_RESOURCES();


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Complete each exercise independently.  Run your query and verify the result.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ A Weekly Cap for BI
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Create resource monitor SMITH_BI_WEEKLY_RM: 10 credits per WEEK,
--       notify at 75%, suspend at 100%, suspend immediately at 110%.
--       Assign it to SMITH_BI_WH and prove the assignment with SHOW WAREHOUSES.
--       Can one warehouse have two monitors? Can one monitor cover two
--       warehouses? (Try it with SMITH_DS_WH.)


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Cost by Job
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Run two queries with QUERY_TAG 'underwriting-review' and one with
--       'claims-monthly-close'. Then, from INFORMATION_SCHEMA.QUERY_HISTORY
--       (last hour), report execution count and total elapsed seconds per
--       QUERY_TAG (exclude empty tags).


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Find Idle Spend
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: List every warehouse with AUTO_SUSPEND greater than 60 seconds or no
--       resource monitor (SHOW WAREHOUSES + the ->> pipe operator). Fix them:
--       AUTO_SUSPEND = 60 for every SMITH_* warehouse.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Alert by E-mail
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Create an e-mail NOTIFICATION INTEGRATION allowed to send to your own
--       (verified) address, then create alert SMITH_LONG_QUERY_ALERT that runs
--       every 15 minutes and e-mails you when any query in the last 15 minutes
--       ran longer than 60 seconds. Execute it once, check ALERT_HISTORY, then
--       SUSPEND it. Why is a serverless alert a good fit here?


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP — keep the monitors (they protect your trial); stop the alerts
================================================================================
*/
USE ROLE accountadmin;
ALTER ALERT IF EXISTS smith_ins.governance.etl_spend_alert SUSPEND;
ALTER ALERT IF EXISTS smith_ins.governance.smith_long_query_alert SUSPEND;
