/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #06c — Snowpark with Python                           (30 minutes)
1) A service user with key-pair authentication for code (no passwords)
2) Snowpark DataFrames: lazy, pushed down to the warehouse as SQL
3) Write results, register a UDF and a stored procedure from Python
4) Verify in Snowflake what the client actually ran
Notebook — choose ONE environment (same Parts 1–7 and Exercises A–C):
  Option A  Snowflake Notebook in Snowsight Workspaces: notebooks/06c-Snowpark-Python-SnowflakeNotebook.ipynb
  Option B  SageMaker Studio JupyterLab:  notebooks/06c-Snowpark-Python.ipynb  (Setup/AWS-Setup-Guide.md)
Prerequisite: Hands-on #06b (RAW.AGENCY_CLAIMS_RAW is loaded)
----------------------------------------------------------------------------------*/

/*
  HOW THIS LAB FLOWS
  SQL worksheet (this file)  →  Demo 1 creates the user, schema and grants
  Notebook (Option A or B)   →  Parts 1–7 + notebook exercises
  SQL worksheet (this file)  →  Part 2 exercises check what the notebook did
*/

/*
================================================================================
  PART 1 – INSTRUCTOR DEMO
  Each numbered demo illustrates one concept.  Students follow along in their
  own worksheets and are not expected to type anything until Part 2.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ A Service User for Python Code
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Code connects as a SERVICE user with an RSA key pair: no password, no MFA
-- prompt. The private key stays in SageMaker Studio (~/.snowflake/rsa_key.p8);
-- Snowflake stores only the public key. Paste the value printed by
-- data/aws/sagemaker-setup.sh.

USE ROLE sysadmin;
CREATE SCHEMA IF NOT EXISTS smith_ins.snowpark COMMENT = 'Objects created from Snowpark (Hands-on #06c)';
CREATE STAGE IF NOT EXISTS smith_ins.snowpark.code COMMENT = 'Code for permanent UDFs and procedures';

GRANT USAGE ON SCHEMA smith_ins.raw TO ROLE smith_engineer;
GRANT SELECT ON TABLE smith_ins.raw.agency_claims_raw TO ROLE smith_engineer;
GRANT ALL ON SCHEMA smith_ins.snowpark TO ROLE smith_engineer;
GRANT READ, WRITE ON STAGE smith_ins.snowpark.code TO ROLE smith_engineer;

USE ROLE useradmin;
CREATE USER IF NOT EXISTS smith_snowpark_svc
    TYPE = SERVICE
    DEFAULT_ROLE = smith_engineer
    DEFAULT_WAREHOUSE = smith_wh
    COMMENT = 'Snowpark notebook in SageMaker Studio (key-pair only)';

ALTER USER smith_snowpark_svc SET RSA_PUBLIC_KEY = '<paste the public key printed by sagemaker-setup.sh>';

USE ROLE securityadmin;
GRANT ROLE smith_engineer TO USER smith_snowpark_svc;

-- OPTION A (Snowflake Notebook): the notebook runs as YOUR user, so give
-- yourself the lab role. Skip the service user above if you only use Option A.
USE ROLE securityadmin;
SET me = CURRENT_USER();
GRANT ROLE smith_engineer TO USER IDENTIFIER($me);
-- Also grant the role USAGE on the compute pool if it is not already PUBLIC:
--   GRANT USAGE ON COMPUTE POOL system_compute_pool_cpu TO ROLE smith_engineer;

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
-- OPTION B only — the account identifier for the notebook's connection settings:
SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS account_identifier;

DESC USER smith_snowpark_svc ->> SELECT "property", "value" FROM $1 WHERE "property" IN ('TYPE', 'RSA_PUBLIC_KEY_FP', 'DEFAULT_ROLE');


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Run the Notebook
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- OPTION A — Snowsight › Projects › Workspaces: upload
--   notebooks/06c-Snowpark-Python-SnowflakeNotebook.ipynb, open it, choose the
--   SYSTEM_COMPUTE_POOL_CPU compute pool and SMITH_WH as the query warehouse.
--   Snowpark is preinstalled; get_active_session() replaces the key pair.
--   Container Runtime bills the compute pool node while the notebook is
--   connected — shut it down after the lab.
-- OPTION B — In SageMaker Studio: JupyterLab space (ml.t3.medium) › terminal:
--   bash data/aws/sagemaker-setup.sh        (Snowpark + key pair)
--   then open notebooks/06c-Snowpark-Python.ipynb with the Python 3 kernel.
-- Walk through notebook Parts 1–7 together: connect, lazy DataFrames, the SQL
-- they generate, writing a table, a UDF and a stored procedure. Students then
-- do notebook Exercises A–C and come back here for Part 2.


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ What Did Python Send to Snowflake?
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Every DataFrame action became SQL that ran on SMITH_WH — nothing was pulled
-- into the notebook except the final, small results.
-- (Empty result? Run this demo as ACCOUNTADMIN. Option A: replace
--  'SMITH_SNOWPARK_SVC' with your own user name — SELECT CURRENT_USER().)

SELECT start_time, query_type, LEFT(query_text, 120) AS query_text, rows_produced,
       total_elapsed_time / 1000 AS seconds
FROM TABLE(smith_ins.information_schema.query_history_by_user(
        USER_NAME => 'SMITH_SNOWPARK_SVC',
        END_TIME_RANGE_START => DATEADD(hour, -2, CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 200))
ORDER BY start_time;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Do these after the notebook (Parts 1–7 and Exercises A–C).
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Check the Notebook's Output
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: The notebook wrote SNOWPARK.AGENCY_CLAIMS_CURATED (one row per claim).
--       Prove its claim count equals the distinct claim_ref count in
--       RAW.AGENCY_CLAIMS_RAW, and that every row has a non-null total_amount.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Python Objects, Used from SQL
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: (a) Use the permanent UDF SNOWPARK.SEVERITY_BAND (notebook Part 5) in a
--       plain SQL query: claims per severity band and line of business.
--       (b) CALL the stored procedure SNOWPARK.REFRESH_AGENCY_CURATED()
--       (notebook Part 6) and check the row count it returns.
--       (c) Run SHOW USER FUNCTIONS IN SCHEMA smith_ins.snowpark and look at the
--       language column.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Find the Pushed-Down SQL
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: From QUERY_HISTORY_BY_USER for SMITH_SNOWPARK_SVC (Option A: your own
--       user), find the query that
--       created SNOWPARK.LATE_REPORTS (notebook Exercise B). How many seconds
--       did it take, and which warehouse ran it?


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Least Privilege for Code
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: SMITH_SNOWPARK_SVC currently uses SMITH_ENGINEER, which can also write
--       to CORE. Create role SMITH_SNOWPARK_RL that can only read
--       RAW.AGENCY_CLAIMS_RAW and CORE.POLICIES, build in SNOWPARK, and use
--       SMITH_WH; make it the user's default role. Re-run notebook Part 1 with
--       role = SMITH_SNOWPARK_RL and confirm Parts 2–4 still work.
--       (Option A: grant the new role to yourself and use it in session.use_role.)


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP — shut down the Snowflake Notebook service (Option A) or stop the
  JupyterLab space in SageMaker Studio (Option B). Keep the SNOWPARK schema.
  Optional: ALTER USER smith_snowpark_svc SET DISABLED = TRUE;
================================================================================
*/
