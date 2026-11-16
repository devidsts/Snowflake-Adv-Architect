/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #14 — Cortex AI for Claims                            (30 minutes)
PART A  (works in every trial account — no AI credits)
  1) Build the semantic layer: a semantic view over the claims star schema
  2) Inspect, govern and query it with SQL
PART B  (needs AI features enabled — see TRIAL NOTE)
  3) Cortex Analyst: a Cortex Agent that answers questions from the semantic view
  4) AI functions on adjuster notes
  5) Documents: extract fields from FNOL claim-form PDFs
  6) Cortex Search over adjuster notes
Files: data/claim_forms/FNOL-26-0001.pdf … FNOL-26-0006.pdf
----------------------------------------------------------------------------------*/

/*
  TRIAL NOTE — WHAT WORKS IN A TRIAL ACCOUNT
  • Semantic views (Part A) are ordinary schema objects: they work in any
    trial, cost only warehouse time, and are what Cortex Analyst reads.
  • AI features (Cortex AI functions, Cortex Analyst, Cortex Agents, Cortex
    Search) are DISABLED by default on self-service trials until a credit card
    is added: Snowsight » Admin » Billing » Snowflake billing » Payment method »
    + Credit Card. Adding a card does NOT end the trial or upgrade the account;
    AI usage is then paid from the free trial credits.
  • Cortex Fine-tuning is not used (region-limited; deprecation announced).
  • Run CHECK 0 below. If it errors, do Part A, and the instructor demonstrates
    Part B from an AI-enabled account.

  COST NOTE — Part B works on samples (LIMIT 25–50 rows). Keep the limits.
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
-- CHECK 0 │ Is AI Enabled in This Account?
-- ──────────────────────────────────────────────────────────────────────────────
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;      -- set in Hands-on #00
SELECT AI_COMPLETE('claude-sonnet-4-5', 'Reply with the single word READY.') AS ai_status;
-- Error mentioning AI features / trial / payment → add a credit card or use Part A only.

-- Privileges used in this lab (both AI gates are granted to PUBLIC by default):
GRANT DATABASE ROLE snowflake.cortex_user       TO ROLE sysadmin;
GRANT DATABASE ROLE snowflake.cortex_agent_user TO ROLE sysadmin;
GRANT CREATE SEMANTIC VIEW, CREATE AGENT, CREATE CORTEX SEARCH SERVICE
    ON SCHEMA smith_ins.cortex TO ROLE sysadmin;

USE ROLE sysadmin;
USE SCHEMA smith_ins.cortex;

/*==============================================================================
  PART A — THE SEMANTIC LAYER  (no AI required)
==============================================================================*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 1 │ Model the Business, Not the Tables
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Cortex Analyst writes SQL from a question. Accuracy depends on the semantic
-- layer: which tables join how, what each column MEANS, which words users say
-- for it, and how each KPI is calculated. A semantic view stores exactly that,
-- in the database, governed like any other object.
--
--   Logical table   → a business entity on a physical table, with a key
--   Relationship    → how logical tables join (many-to-one)
--   Fact            → row-level numeric value (claim amount)
--   Dimension       → attribute to group/filter by (line of business, year)
--   Metric          → aggregated KPI defined once (paid losses, severity)
--   Synonyms/Comment→ the words and meaning Cortex Analyst matches questions to
--
-- Built on the Hands-on #07 star schema. Check it exists:
SELECT (SELECT COUNT(*) FROM smith_ins.analytics.fact_claims)      AS fact_rows,
       (SELECT COUNT(*) FROM smith_ins.analytics.dim_policyholder) AS holder_versions,
       (SELECT COUNT(*) FROM smith_ins.analytics.dim_policy)       AS policies,
       (SELECT COUNT(*) FROM smith_ins.analytics.dim_date)         AS dates;
-- Missing objects? Run Hands-on #07 Demos 1–4 first.

-- Step 1: a region dimension table so "region" is answerable (small reference table).
CREATE OR REPLACE VIEW smith_ins.analytics.dim_region AS
SELECT region_id, region_name, country, data_residency FROM smith_ins.core.regions;

-- Step 2: the semantic view — built clause by clause.
CREATE OR REPLACE SEMANTIC VIEW smith_ins.cortex.claims_sv

    -- 2a. Logical tables: business names over physical tables, with keys
    TABLES (
        claims  AS smith_ins.analytics.fact_claims      PRIMARY KEY (claim_id)
                WITH SYNONYMS = ('loss', 'insurance claim')
                COMMENT = 'One row per claim submitted to Smith Insurance',
        holders AS smith_ins.analytics.dim_policyholder PRIMARY KEY (holder_sk)
                WITH SYNONYMS = ('customer', 'insured')
                COMMENT = 'Policyholder, as they were on the claim date (Type 2 history)',
        pol     AS smith_ins.analytics.dim_policy       PRIMARY KEY (policy_id)
                WITH SYNONYMS = ('policy', 'contract')
                COMMENT = 'Insurance policy with product line, premium and limits',
        regions AS smith_ins.analytics.dim_region       PRIMARY KEY (region_id)
                COMMENT = 'Sales and claims region',
        dates   AS smith_ins.analytics.dim_date         PRIMARY KEY (date_key)
                COMMENT = 'Calendar for the claim (loss) date'
    )

    -- 2b. Relationships: many claims → one holder version / policy / region / date
    RELATIONSHIPS (
        claim_to_holder AS claims (holder_sk)          REFERENCES holders,
        claim_to_policy AS claims (policy_id)          REFERENCES pol,
        claim_to_region AS claims (region_id_at_claim) REFERENCES regions,
        claim_to_date   AS claims (claim_date_key)     REFERENCES dates
    )

    -- 2c. Facts: row-level numbers that metrics aggregate
    FACTS (
        claims.claim_amount_f AS claims.claim_amount
            COMMENT = 'Amount claimed (incurred) in USD',
        claims.paid_amount_f  AS claims.paid_amount
            COMMENT = 'Amount paid to date in USD',
        pol.premium_f         AS pol.annual_premium
            COMMENT = 'Annual written premium in USD',
        claims.siu_ind_f      AS IFF(claims.fraud_flag, 1, 0)
            COMMENT = '1 when the claim was referred to SIU, else 0'
    )

    -- 2d. Dimensions: what people group and filter by, in their words
    DIMENSIONS (
        dates.claim_year       AS dates.year
            WITH SYNONYMS = ('year', 'accident year', 'loss year'),
        dates.claim_month      AS dates.month_name
            WITH SYNONYMS = ('month'),
        pol.product_line   AS pol.line_of_business
            WITH SYNONYMS = ('LOB', 'product', 'product line', 'line')
            COMMENT = 'AUTO, HOME, LIFE, COMMERCIAL or UMBRELLA',
        claims.loss_type      AS claims.claim_type
            WITH SYNONYMS = ('peril', 'cause of loss'),
        claims.claim_status    AS claims.status
            WITH SYNONYMS = ('status')
            COMMENT = 'OPEN, IN_REVIEW, CLOSED or DENIED',
        claims.siu_flag      AS claims.fraud_flag
            WITH SYNONYMS = ('SIU', 'suspected fraud', 'fraud referral')
            COMMENT = 'TRUE when referred to the special investigations unit',
        regions.region    AS regions.region_name
            WITH SYNONYMS = ('region', 'territory'),
        regions.country_code        AS regions.country,
        holders.holder_city           AS holders.city
            COMMENT = 'Policyholder city at the time of the claim'
    )

    -- 2e. Metrics: KPIs defined ONCE, reused by every question
    METRICS (
        claims.claim_count     AS COUNT(claims.claim_id)
            WITH SYNONYMS = ('number of claims', 'claim frequency count'),
        claims.total_incurred  AS SUM(claims.claim_amount_f)
            WITH SYNONYMS = ('incurred losses', 'claimed amount'),
        claims.total_paid      AS SUM(claims.paid_amount_f)
            WITH SYNONYMS = ('paid losses', 'payouts', 'losses paid'),
        claims.avg_severity    AS AVG(claims.claim_amount_f)
            WITH SYNONYMS = ('severity', 'average claim size')
            COMMENT = 'Average claim amount',
        claims.fraud_rate      AS AVG(claims.siu_ind_f)
            COMMENT = 'Share of claims referred to SIU (0–1)',
        pol.written_premium    AS SUM(pol.premium_f)
            WITH SYNONYMS = ('premium', 'GWP')
    )

    COMMENT = 'Smith Insurance claims — governed business definitions for BI and Cortex Analyst'
    AI_SQL_GENERATION 'Amounts are in USD. "Losses" means paid losses unless the user says incurred. Years are accident (claim) years. Round currency to whole dollars.';


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 2 │ Inspect, Govern and Query the Semantic View
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- The semantic view is metadata you can inspect and grant. Consumers need
-- SELECT on the semantic view only — base-table masking and row access
-- policies still apply to them. Query it with SEMANTIC_VIEW(): pick metrics
-- and dimensions; Snowflake writes the joins and GROUP BY.

DESC SEMANTIC VIEW claims_sv;
SHOW SEMANTIC METRICS    IN claims_sv;
SHOW SEMANTIC DIMENSIONS IN claims_sv;

SELECT * FROM SEMANTIC_VIEW(
    smith_ins.cortex.claims_sv
    DIMENSIONS pol.product_line, dates.claim_year
    METRICS    claims.claim_count, claims.total_paid, claims.avg_severity
    WHERE dates.claim_year >= 2025)
ORDER BY product_line, claim_year;

-- Governance: the claims analyst (Hands-on #01/#02) gets the business layer
GRANT USAGE  ON SCHEMA smith_ins.cortex TO ROLE smith_claims_analyst;
GRANT SELECT ON SEMANTIC VIEW smith_ins.cortex.claims_sv TO ROLE smith_claims_analyst;


/*==============================================================================
  PART B — CORTEX AI  (requires AI features enabled; see TRIAL NOTE)
==============================================================================*/

-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 3 │ Cortex Analyst on the Semantic View (via a Cortex Agent)
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- An agent with a Cortex Analyst (text-to-SQL) tool answers questions from
-- the semantic view. Then chat in Snowsight: AI & ML » Agents » "Smith Claims
-- Analyst". Ask: "What were paid losses by product in 2026?",
-- "Which region has the highest SIU rate?", "Average severity of home
-- claims by year". Open the generated SQL — it uses your metric definitions.

CREATE OR REPLACE AGENT smith_ins.cortex.claims_agent
    COMMENT = 'Answers claims questions from the governed semantic view'
    PROFILE = '{"display_name": "Smith Claims Analyst"}'
    FROM SPECIFICATION
$$
models:
  orchestration: auto
instructions:
  response: "Answer concisely for an insurance claims manager. Show amounts in USD."
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "Claims_Analyst"
      description: "Claims counts, paid and incurred losses, severity, fraud rate and premium by product, region, year, status and city."
tool_resources:
  Claims_Analyst:
    semantic_view: "smith_ins.cortex.claims_sv"
    execution_environment:
      type: "warehouse"
      warehouse: "SMITH_WH"
$$;

SHOW AGENTS IN SCHEMA smith_ins.cortex;
-- ▶ Snowsight: AI & ML » Agents » Smith Claims Analyst — ask the questions above.
-- ▶ Improve accuracy: in the semantic view editor (AI & ML » Cortex Analyst /
--   Semantic views) add a VERIFIED QUERY for a question the agent got wrong.


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 4 │ AI Functions on Adjuster Notes
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Task-specific functions are cheaper and more predictable than free-form
-- prompts. Score once into a table; don't re-score on every query.

CREATE OR REPLACE TABLE note_insights AS
SELECT claim_id, status, claim_type, adjuster_notes,
       AI_SENTIMENT(adjuster_notes):categories[0]:sentiment::STRING AS sentiment,
       AI_CLASSIFY(adjuster_notes,
                   ['Fraud referral', 'Coverage denied', 'Paid and closed', 'Awaiting information'])
                  :labels[0]::STRING                                 AS note_category
FROM smith_ins.core.claims
WHERE claim_date >= '2026-01-01'
ORDER BY claim_id
LIMIT 40;

SELECT status, note_category, sentiment, COUNT(*)
FROM note_insights GROUP BY ALL ORDER BY 1, 2;

SELECT AI_AGG(adjuster_notes, 'In two sentences, what are the recurring problems in these home claims?') AS themes
FROM (SELECT adjuster_notes FROM smith_ins.core.claims
      WHERE line_of_business = 'HOME' AND claim_date >= '2026-06-01' LIMIT 50);


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 5 │ Claim Forms: Parse and Extract
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Document functions read FILE objects from an internal stage with
-- server-side encryption. Upload the six PDFs from data/claim_forms in
-- Snowsight (Data » Databases » SMITH_INS » CORTEX » Stages » CLAIM_DOCS »
-- + Files) or: snow stage copy "data/claim_forms/*.pdf" @smith_ins.cortex.claim_docs

CREATE OR REPLACE STAGE claim_docs
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY  = (ENABLE = TRUE);

-- ▶ Upload the PDFs now, then:
ALTER STAGE claim_docs REFRESH;
SELECT relative_path, size FROM DIRECTORY(@claim_docs);

SELECT AI_PARSE_DOCUMENT(TO_FILE('@claim_docs', 'FNOL-26-0001.pdf'), {'mode': 'LAYOUT'}):content::STRING AS form_text;

CREATE OR REPLACE TABLE fnol_extracted AS
SELECT relative_path AS file_name,
       AI_EXTRACT(
           file => TO_FILE('@claim_docs', relative_path),
           responseFormat => {
               'policy_number':    'What is the policy number?',
               'insured_name':     'What is the insured name?',
               'date_of_loss':     'What is the date of loss (YYYY-MM-DD)?',
               'type_of_loss':     'What is the type of loss?',
               'estimated_amount': 'What is the estimated amount, as a number without commas?'
           }):response AS fields
FROM DIRECTORY(@claim_docs);

SELECT f.file_name,
       f.fields:policy_number::STRING                         AS policy_number,
       f.fields:insured_name::STRING                          AS insured_name,
       TRY_TO_DATE(f.fields:date_of_loss::STRING)             AS date_of_loss,
       f.fields:type_of_loss::STRING                          AS type_of_loss,
       TRY_TO_NUMBER(f.fields:estimated_amount::STRING, 12, 2) AS estimated_amount,
       p.policy_id IS NOT NULL                                AS policy_on_file
FROM fnol_extracted f
LEFT JOIN smith_ins.core.policies p ON p.policy_id = f.fields:policy_number::STRING
ORDER BY f.file_name;


-- ──────────────────────────────────────────────────────────────────────────────
-- DEMO 6 │ Cortex Search over Adjuster Notes
-- ──────────────────────────────────────────────────────────────────────────────
-- [INSTRUCTOR NOTE]
-- Managed hybrid (vector + keyword) search: declare the source query, the
-- search column, filterable ATTRIBUTES and a TARGET_LAG. It is the retrieval
-- half of RAG and a second tool an agent can use next to Cortex Analyst.
-- Long documents are chunked first (SPLIT_TEXT_RECURSIVE_CHARACTER).

CREATE OR REPLACE TABLE notes_corpus AS
SELECT c.claim_id, c.adjuster_notes AS note, c.line_of_business, r.region_name, c.status
FROM smith_ins.core.claims c
JOIN smith_ins.core.regions r ON r.region_id = c.region_id
WHERE c.claim_date >= '2026-01-01';

CREATE OR REPLACE CORTEX SEARCH SERVICE claim_notes_search
    ON note
    ATTRIBUTES line_of_business, region_name, status
    WAREHOUSE  = smith_wh
    TARGET_LAG = '1 day'
AS (SELECT claim_id, note, line_of_business, region_name, status FROM notes_corpus);

SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
         'smith_ins.cortex.claim_notes_search',
         '{"query": "timeline does not add up, possible fraud",
           "columns": ["claim_id", "note", "region_name"],
           "filter": {"@eq": {"line_of_business": "AUTO"}},
           "limit": 5}')):results AS results;

SELECT c.value::STRING AS chunk
FROM TABLE(FLATTEN(SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
        (SELECT AI_PARSE_DOCUMENT(TO_FILE('@claim_docs', 'FNOL-26-0003.pdf'), {'mode': 'LAYOUT'}):content::STRING),
        'markdown', 400, 50))) c;


/*
================================================================================
  PART 2 – STUDENT EXERCISES
  Exercises 1 and 2 work in any trial. Exercises 3 and 4 need AI enabled.
================================================================================
*/

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Extend the Semantic Layer   (no AI required)
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Underwriting asks for the LOSS RATIO (paid losses ÷ written premium)
--       and the OPEN CLAIM COUNT. Recreate CLAIMS_SV with:
--         • metric claims.open_claim_count  (claims with status OPEN or IN_REVIEW)
--         • a derived metric loss_ratio = claims.total_paid / pol.written_premium
--           (derived metrics have NO table prefix)
--       Then query loss ratio by line of business for 2025 with SEMANTIC_VIEW().


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Governed Access to the Semantic Layer   (no AI required)
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Switch to SMITH_CLAIMS_ANALYST (grant it to yourself if needed),
--       query claim_count by region through SEMANTIC_VIEW(), and compare
--       with the same query as SYSADMIN. Are the results the same or
--       different, and why? (Hint: Hands-on #02 and Hands-on #07.)


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Extract What the Intake Team Needs   (AI required)
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: Using AI_EXTRACT on the claim forms, pull POLICE_REPORT_NUMBER and
--       INJURIES (yes/no). Return only forms with an injury or a police report,
--       and flag any form whose policy is not on file.


-- YOUR CODE HERE


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Teach the Agent   (AI required)
-- ──────────────────────────────────────────────────────────────────────────────
-- Task: After Exercise 1, ask the agent "What is the loss ratio for home
--       policies in 2025?". Then add Cortex Search as a SECOND tool so the
--       agent can also answer "Find home claims where the contractor estimate
--       looked too high" (tool type "cortex_search", resource key
--       "search_service"). Test both questions in Snowsight.


-- YOUR CODE HERE


/*
================================================================================
  CLEANUP — the search service refreshes on its TARGET_LAG; suspend it
================================================================================
*/
ALTER CORTEX SEARCH SERVICE IF EXISTS smith_ins.cortex.claim_notes_search SUSPEND INDEXING;
ALTER CORTEX SEARCH SERVICE IF EXISTS smith_ins.cortex.claim_notes_search SUSPEND SERVING;
