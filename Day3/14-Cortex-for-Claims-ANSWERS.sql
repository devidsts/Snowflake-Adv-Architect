/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- INSTRUCTOR ANSWER KEY — DO NOT DISTRIBUTE TO STUDENTS
Hands-on #14 — Cortex AI for Claims
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.cortex;

-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 1 │ Extend the Semantic Layer
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE SEMANTIC VIEW smith_ins.cortex.claims_sv
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
    RELATIONSHIPS (
        claim_to_holder AS claims (holder_sk)          REFERENCES holders,
        claim_to_policy AS claims (policy_id)          REFERENCES pol,
        claim_to_region AS claims (region_id_at_claim) REFERENCES regions,
        claim_to_date   AS claims (claim_date_key)     REFERENCES dates
    )
    FACTS (
        claims.claim_amount_f AS claims.claim_amount COMMENT = 'Amount claimed (incurred) in USD',
        claims.paid_amount_f  AS claims.paid_amount  COMMENT = 'Amount paid to date in USD',
        pol.premium_f         AS pol.annual_premium  COMMENT = 'Annual written premium in USD',
        claims.siu_ind_f      AS IFF(claims.fraud_flag, 1, 0) COMMENT = '1 when referred to SIU',
        claims.open_ind_f     AS IFF(claims.status IN ('OPEN', 'IN_REVIEW'), 1, 0) COMMENT = '1 while the claim is open'
    )
    DIMENSIONS (
        dates.claim_year     AS dates.year          WITH SYNONYMS = ('year', 'accident year', 'loss year'),
        dates.claim_month    AS dates.month_name    WITH SYNONYMS = ('month'),
        pol.product_line AS pol.line_of_business WITH SYNONYMS = ('LOB', 'product', 'product line', 'line')
                             COMMENT = 'AUTO, HOME, LIFE, COMMERCIAL or UMBRELLA',
        claims.loss_type    AS claims.claim_type   WITH SYNONYMS = ('peril', 'cause of loss'),
        claims.claim_status  AS claims.status       WITH SYNONYMS = ('status')
                             COMMENT = 'OPEN, IN_REVIEW, CLOSED or DENIED',
        claims.siu_flag    AS claims.fraud_flag   WITH SYNONYMS = ('SIU', 'suspected fraud', 'fraud referral'),
        regions.region  AS regions.region_name WITH SYNONYMS = ('region', 'territory'),
        regions.country_code      AS regions.country,
        holders.holder_city         AS holders.city        COMMENT = 'Policyholder city at the time of the claim'
    )
    METRICS (
        claims.claim_count      AS COUNT(claims.claim_id) WITH SYNONYMS = ('number of claims'),
        claims.open_claim_count AS SUM(claims.open_ind_f)
                                WITH SYNONYMS = ('open claims', 'pending claims'),
        claims.total_incurred   AS SUM(claims.claim_amount_f) WITH SYNONYMS = ('incurred losses'),
        claims.total_paid       AS SUM(claims.paid_amount_f)  WITH SYNONYMS = ('paid losses', 'payouts'),
        claims.avg_severity     AS AVG(claims.claim_amount_f) WITH SYNONYMS = ('severity', 'average claim size'),
        claims.fraud_rate       AS AVG(claims.siu_ind_f) COMMENT = 'Share of claims referred to SIU (0–1)',
        pol.written_premium     AS SUM(pol.premium_f)         WITH SYNONYMS = ('premium', 'GWP'),
        loss_ratio              AS claims.total_paid / NULLIF(pol.written_premium, 0)
                                WITH SYNONYMS = ('LR', 'paid loss ratio')
                                COMMENT = 'Paid losses divided by written premium'
    )
    COMMENT = 'Smith Insurance claims — governed business definitions for BI and Cortex Analyst'
    AI_SQL_GENERATION 'Amounts are in USD. "Losses" means paid losses unless the user says incurred. Years are accident (claim) years. Round currency to whole dollars.';

SELECT * FROM SEMANTIC_VIEW(
    smith_ins.cortex.claims_sv
    DIMENSIONS pol.product_line
    METRICS    loss_ratio, claims.open_claim_count
    WHERE dates.claim_year = 2025)
ORDER BY loss_ratio DESC;
-- [TEACHING NOTE]
-- A derived metric (no table prefix) combines metrics from different logical
-- tables. Caveat to discuss: written premium here is aggregated over the
-- policies that HAD claims in the filter — an actuarial loss ratio needs
-- earned premium over all policies. Semantic layers make such definitions
-- explicit and reviewable; that is the point. Any grants on the old view are
-- lost by CREATE OR REPLACE unless you add COPY GRANTS — re-run the Demo 2
-- grants.
GRANT SELECT ON SEMANTIC VIEW smith_ins.cortex.claims_sv TO ROLE smith_claims_analyst;


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 2 │ Governed Access to the Semantic Layer
-- ──────────────────────────────────────────────────────────────────────────────
USE ROLE securityadmin;
SET me = CURRENT_USER();
GRANT ROLE smith_claims_analyst TO USER IDENTIFIER($me);

USE ROLE smith_claims_analyst;
USE SECONDARY ROLES NONE;
USE WAREHOUSE smith_wh;
SELECT * FROM SEMANTIC_VIEW(
    smith_ins.cortex.claims_sv
    DIMENSIONS regions.region
    METRICS    claims.claim_count)
ORDER BY region;

USE ROLE sysadmin;
SELECT * FROM SEMANTIC_VIEW(
    smith_ins.cortex.claims_sv
    DIMENSIONS regions.region
    METRICS    claims.claim_count)
ORDER BY region;
-- [TEACHING NOTE]
-- FACT_CLAIMS is a table built by SYSADMIN (CTAS), so it carries no row access
-- policy: both roles see every region! Contrast with CORE.CLAIMS, where
-- REGION_RAP filters. Fix options: attach REGION_RAP to FACT_CLAIMS
-- (ON region_id_at_claim) or build the star schema as views/dynamic tables
-- whose policies are applied deliberately. The semantic view itself never
-- bypasses or adds security — it inherits whatever the tables enforce.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 3 │ Extract What the Intake Team Needs
-- ──────────────────────────────────────────────────────────────────────────────
WITH x AS (
    SELECT relative_path AS file_name,
           AI_EXTRACT(
               file => TO_FILE('@claim_docs', relative_path),
               responseFormat => {
                   'policy_number':        'What is the policy number?',
                   'police_report_number': 'What is the police report number? Answer N/A if none.',
                   'injuries':             'Were any injuries reported? Answer yes or no.'
               }):response AS f
    FROM DIRECTORY(@claim_docs)
)
SELECT x.file_name,
       x.f:police_report_number::STRING AS police_report_number,
       x.f:injuries::STRING             AS injuries,
       p.policy_id IS NULL              AS policy_not_on_file
FROM x
LEFT JOIN smith_ins.core.policies p ON p.policy_id = x.f:policy_number::STRING
WHERE LOWER(x.f:injuries::STRING) LIKE 'yes%'
   OR COALESCE(x.f:police_report_number::STRING, 'N/A') NOT IN ('N/A', 'None', '')
ORDER BY x.file_name;
-- [TEACHING NOTE]
-- Expected: 0002 (theft, police report), 0004 (collision, injury + report),
-- 0005 (burglary, report, policy POL-099007 NOT on file). Always validate
-- extracted keys against master data before creating a claim.


-- ──────────────────────────────────────────────────────────────────────────────
-- EXERCISE 4 │ CHALLENGE — Teach the Agent
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE AGENT smith_ins.cortex.claims_agent
    COMMENT = 'Answers claims questions from the semantic view and searches adjuster notes'
    PROFILE = '{"display_name": "Smith Claims Analyst"}'
    FROM SPECIFICATION
$$
models:
  orchestration: auto
instructions:
  response: "Answer concisely for an insurance claims manager. Show amounts in USD."
  orchestration: "Use Claims_Analyst for numbers and KPIs. Use Notes_Search to find specific claims by what adjusters wrote."
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "Claims_Analyst"
      description: "Claims counts, losses, severity, fraud rate, premium and loss ratio by product, region, year, status and city."
  - tool_spec:
      type: "cortex_search"
      name: "Notes_Search"
      description: "Searches adjuster notes on 2026 claims. Filter by line_of_business, region_name or status."
tool_resources:
  Claims_Analyst:
    semantic_view: "smith_ins.cortex.claims_sv"
    execution_environment:
      type: "warehouse"
      warehouse: "SMITH_WH"
  Notes_Search:
    search_service: "smith_ins.cortex.claim_notes_search"
    id_column: "claim_id"
    max_results: 5
$$;
-- [TEACHING NOTE]
-- Two tools, one agent: structured questions go to Cortex Analyst (semantic
-- view → SQL), unstructured ones to Cortex Search. Orchestration instructions
-- tell the agent which tool to choose. Resume the search service first if it
-- was suspended in CLEANUP:
--   ALTER CORTEX SEARCH SERVICE claim_notes_search RESUME SERVING;
-- Governance: grant USAGE on the agent and the search service only to roles
-- allowed to see every region (NOTES_CORPUS has no row access policy).
