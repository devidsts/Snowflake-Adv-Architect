/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #06c — Snowpark with Python (Snowflake Notebook or SageMaker Studio)
Notebook answers: notebooks/06c-Snowpark-Python-ANSWERS.ipynb
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.snowpark;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Check the Notebook's Output
-- ──────────────────────────────────────────────────────────────────────────────
SELECT (SELECT COUNT(*) FROM agency_claims_curated)                                   AS curated_rows,
       (SELECT COUNT(DISTINCT record:claim_ref) FROM smith_ins.raw.agency_claims_raw)  AS raw_claims,
       (SELECT COUNT_IF(total_amount IS NULL) FROM agency_claims_curated)              AS null_totals;
-- [TEACHING NOTE]
-- Equal counts and 0 nulls. The curated table is the notebook's
-- group_by(claim_ref) over the flattened line items — 12,048 September claims
-- plus 480 good late arrivals (12,528) if Hands-on #06b Demo 5 was run.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Python Objects, Used from SQL
-- ──────────────────────────────────────────────────────────────────────────────
-- (a)
SELECT severity_band(total_amount) AS band, line_of_business, COUNT(*) AS claims
FROM agency_claims_curated
GROUP BY 1, 2
ORDER BY 2, 1;

-- (b)
CALL refresh_agency_curated();

-- (c)
SHOW USER FUNCTIONS IN SCHEMA smith_ins.snowpark;
-- [TEACHING NOTE]
-- A permanent Python UDF is a schema object like any other: any role with
-- USAGE can call it from SQL, BI tools or dbt. Its code lives in @SNOWPARK.CODE
-- and runs inside Snowflake's Python sandbox on the warehouse.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Find the Pushed-Down SQL
-- ──────────────────────────────────────────────────────────────────────────────
SELECT start_time, warehouse_name, total_elapsed_time / 1000 AS seconds, query_text
FROM TABLE(smith_ins.information_schema.query_history_by_user(
        USER_NAME => 'SMITH_SNOWPARK_SVC',          -- Option A (Snowflake Notebook): your own user name
        END_TIME_RANGE_START => DATEADD(hour, -3, CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 500))
WHERE query_text ILIKE '%LATE_REPORTS%'
  AND query_type IN ('CREATE_TABLE_AS_SELECT', 'CREATE_TABLE', 'INSERT')
ORDER BY start_time DESC;
-- [TEACHING NOTE]
-- save_as_table() is one CREATE TABLE ... AS SELECT on SMITH_WH. The UDF call
-- appears inside that SQL. This is the core Snowpark idea: Python builds the
-- plan, Snowflake runs it next to the data.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Least Privilege for Code
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE useradmin;
CREATE ROLE IF NOT EXISTS smith_snowpark_rl COMMENT = 'Functional: Snowpark notebook';
USE ROLE securityadmin;
GRANT USAGE ON WAREHOUSE smith_wh TO ROLE smith_snowpark_rl;
GRANT USAGE ON DATABASE smith_ins TO ROLE smith_snowpark_rl;
GRANT USAGE ON SCHEMA smith_ins.raw  TO ROLE smith_snowpark_rl;
GRANT USAGE ON SCHEMA smith_ins.core TO ROLE smith_snowpark_rl;
GRANT SELECT ON TABLE smith_ins.raw.agency_claims_raw TO ROLE smith_snowpark_rl;
GRANT SELECT ON TABLE smith_ins.core.policies         TO ROLE smith_snowpark_rl;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE FUNCTION, CREATE PROCEDURE ON SCHEMA smith_ins.snowpark TO ROLE smith_snowpark_rl;
GRANT READ, WRITE ON STAGE smith_ins.snowpark.code TO ROLE smith_snowpark_rl;
GRANT ROLE smith_snowpark_rl TO ROLE sysadmin;
GRANT ROLE smith_snowpark_rl TO USER smith_snowpark_svc;
USE ROLE useradmin;
ALTER USER smith_snowpark_svc SET DEFAULT_ROLE = smith_snowpark_rl;
-- [TEACHING NOTE]
-- Objects the notebook already created are owned by SMITH_ENGINEER; to replace
-- them as SMITH_SNOWPARK_RL either transfer ownership or drop them first. Part 4
-- uses mode="overwrite", which needs OWNERSHIP of the existing table. Masking
-- and row access policies still apply to Snowpark queries — they are just SQL.
