/*----------------SnowPro Advanced: Architect 3-day class Lab Setup:------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Smith Insurance — course dataset (replaces the SCOTT schema used in Fundamentals)
1) Warehouse, database and schemas
2) Reference data: regions, offices, agents (hierarchy), adjusters
3) Policyholders (with PII and planted duplicates), policies, claims, payments
4) Row-count verification
Run time: about 1 minute on an X-Small warehouse. Safe to re-run.
----------------------------------------------------------------------------------*/

/*
  SMITH INSURANCE DATA MODEL (schema CORE)

  REGIONS ──< OFFICES ──< AGENTS (manager_id → AGENTS)  ADJUSTERS
     │                       │                              │
     └──< POLICYHOLDERS ──< POLICIES (agent_id) ──< CLAIMS ─┘──< CLAIM_PAYMENTS

  Schemas:  RAW (landing)  CORE (operational)  ANALYTICS (reporting)
            GOVERNANCE (policies, tags, mappings)  CORTEX (AI objects)
  All names, SSNs, emails and addresses are fictitious.
*/

USE ROLE sysadmin;

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 1 │ Warehouse, Database and Schemas
-- ──────────────────────────────────────────────────────────────────────────────
CREATE WAREHOUSE IF NOT EXISTS smith_wh
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Smith Insurance course warehouse';
USE WAREHOUSE smith_wh;

CREATE OR REPLACE DATABASE smith_ins COMMENT = 'Smith Insurance — SnowPro Advanced Architect course data';
CREATE SCHEMA smith_ins.raw        COMMENT = 'Landing zone for files and feeds';
CREATE SCHEMA smith_ins.core       COMMENT = 'Operational policy and claims system';
CREATE SCHEMA smith_ins.analytics  COMMENT = 'Reporting and star schema';
CREATE SCHEMA smith_ins.governance WITH MANAGED ACCESS COMMENT = 'Policies, tags and access mappings';
CREATE SCHEMA smith_ins.cortex     COMMENT = 'Cortex AI objects';
DROP SCHEMA IF EXISTS smith_ins.public;

USE SCHEMA smith_ins.core;

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 2 │ Reference Data
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE regions (
    region_id    NUMBER(2)    PRIMARY KEY,
    region_name  VARCHAR(30),
    country      VARCHAR(2),
    data_residency VARCHAR(2)  -- US or EU: drives the account-strategy discussion
);
INSERT INTO regions VALUES
    (1, 'Northeast', 'US', 'US'), (2, 'Southeast', 'US', 'US'),
    (3, 'Midwest',   'US', 'US'), (4, 'West',      'US', 'US'),
    (5, 'Ireland',   'IE', 'EU'), (6, 'Germany',   'DE', 'EU');

CREATE OR REPLACE TABLE offices (
    office_id    NUMBER(3)    PRIMARY KEY,
    office_name  VARCHAR(40),
    city         VARCHAR(30),
    region_id    NUMBER(2)    REFERENCES regions
);
INSERT INTO offices VALUES
    ( 1, 'Boston Agency',      'Boston',     1), ( 2, 'Hartford HQ',       'Hartford',   1),
    ( 3, 'Atlanta Agency',     'Atlanta',    2), ( 4, 'Charlotte Agency',  'Charlotte',  2),
    ( 5, 'Chicago Agency',     'Chicago',    3), ( 6, 'Columbus Agency',   'Columbus',   3),
    ( 7, 'Denver Agency',      'Denver',     4), ( 8, 'Seattle Agency',    'Seattle',    4),
    ( 9, 'Dublin Office',      'Dublin',     5), (10, 'Cork Office',       'Cork',       5),
    (11, 'Munich Office',      'Munich',     6), (12, 'Berlin Office',     'Berlin',     6);

-- AGENTS replaces SCOTT.EMP: 1 CEO → 6 regional VPs → 12 office managers → 61 agents
CREATE OR REPLACE TABLE agents (
    agent_id        NUMBER(4)    PRIMARY KEY,
    agent_name      VARCHAR(40),
    title           VARCHAR(30),
    manager_id      NUMBER(4),
    hire_date       DATE,
    office_id       NUMBER(3)    REFERENCES offices,
    commission_rate NUMBER(4,3)
);
INSERT INTO agents
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS id FROM TABLE(GENERATOR(ROWCOUNT => 80))),
     n AS (SELECT ARRAY_CONSTRUCT('Avery','Jordan','Morgan','Casey','Riley','Taylor','Quinn','Harper','Rowan','Emerson',
                                  'Parker','Reese','Sawyer','Hayden','Logan','Kendall','Blake','Drew','Elliot','Finley') AS f,
                  ARRAY_CONSTRUCT('Smith','Okafor','Lindqvist','Moreau','Brennan','Kowalski','Nakamura','Alvarez','Fischer','Murphy',
                                  'Haddad','Petrov','Osei','Larsen','Duarte','Keane','Schulz','Romero','Byrne','Whitfield') AS l)
SELECT g.id,
       GET(n.f, MOD(g.id * 7, 20))::STRING || ' ' || GET(n.l, MOD(g.id * 3 + FLOOR(g.id / 20), 20))::STRING,   -- unique names
       CASE WHEN g.id = 1 THEN 'CEO' WHEN g.id <= 7 THEN 'Regional VP' WHEN g.id <= 19 THEN 'Office Manager' ELSE 'Agent' END,
       CASE WHEN g.id = 1 THEN NULL
            WHEN g.id <= 7 THEN 1
            WHEN g.id <= 19 THEN 1 + CEIL((g.id - 7) / 2)            -- manager reports to the VP of the office's region
            ELSE 8 + MOD(g.id - 20, 12) END,                         -- agent reports to an office manager
       DATEADD(day, -UNIFORM(200, 7000, RANDOM(101)), '2026-01-01'::DATE),
       CASE WHEN g.id = 1 THEN 2
            WHEN g.id <= 7 THEN (g.id - 1) * 2
            WHEN g.id <= 19 THEN g.id - 7
            ELSE 1 + MOD(g.id - 20, 12) END,
       CASE WHEN g.id <= 19 THEN 0 ELSE UNIFORM(4, 12, RANDOM(102)) / 100 END
FROM g, n;

CREATE OR REPLACE TABLE adjusters (
    adjuster_id   NUMBER(3) PRIMARY KEY,
    adjuster_name VARCHAR(40),
    region_id     NUMBER(2) REFERENCES regions,
    specialty     VARCHAR(20)
);
INSERT INTO adjusters VALUES
    ( 1, 'Dana Whitaker',   1, 'AUTO'),       ( 2, 'Luis Ortega',     2, 'HOME'),
    ( 3, 'Priya Raman',     3, 'COMMERCIAL'), ( 4, 'Sam Holloway',    4, 'AUTO'),
    ( 5, 'Aoife Gallagher', 5, 'HOME'),       ( 6, 'Jonas Becker',    6, 'AUTO'),
    ( 7, 'Grace Liu',       1, 'LIFE'),       ( 8, 'Marcus Reed',     2, 'AUTO'),
    ( 9, 'Nina Albrecht',   6, 'COMMERCIAL'), (10, 'Owen Clarke',     4, 'HOME');

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 3 │ Policyholders (5,000 + 40 planted duplicates for the MDM lab)
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE policyholders (
    holder_id     NUMBER(7)    PRIMARY KEY,
    first_name    VARCHAR(30),
    last_name     VARCHAR(30),
    ssn           VARCHAR(11),          -- PII (fictitious)
    date_of_birth DATE,                 -- PII
    email         VARCHAR(80),          -- PII
    phone         VARCHAR(20),          -- PII
    street        VARCHAR(60),
    city          VARCHAR(30),
    state_code    VARCHAR(3),
    postal_code   VARCHAR(10),
    region_id     NUMBER(2) REFERENCES regions,
    source_system VARCHAR(20),
    updated_at    TIMESTAMP_NTZ
);
INSERT INTO policyholders
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 5000))),
     a AS (SELECT
        ARRAY_CONSTRUCT('James','Mary','Robert','Patricia','John','Jennifer','Michael','Linda','David','Elizabeth',
                        'William','Barbara','Richard','Susan','Joseph','Jessica','Thomas','Sarah','Charles','Karen',
                        'Daniel','Nancy','Matthew','Lisa','Anthony','Betty','Mark','Sandra','Steven','Ashley',
                        'Sean','Siobhan','Liam','Niamh','Lukas','Anna','Felix','Lena','Conor','Aisling') AS fn,
        ARRAY_CONSTRUCT('Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez','Hernandez',
                        'Lopez','Gonzalez','Wilson','Anderson','Thomas','Moore','Jackson','Martin','Lee','Thompson',
                        'White','Harris','Clark','Lewis','Robinson','Walker','Young','Allen','King','Wright',
                        'O''Brien','Kelly','Walsh','Doyle','Muller','Schmidt','Wagner','Becker','Hoffmann','Ryan') AS ln,
        ARRAY_CONSTRUCT(
            OBJECT_CONSTRUCT('c','Boston','s','MA','r',1), OBJECT_CONSTRUCT('c','Hartford','s','CT','r',1),
            OBJECT_CONSTRUCT('c','Albany','s','NY','r',1), OBJECT_CONSTRUCT('c','Providence','s','RI','r',1),
            OBJECT_CONSTRUCT('c','Atlanta','s','GA','r',2), OBJECT_CONSTRUCT('c','Charlotte','s','NC','r',2),
            OBJECT_CONSTRUCT('c','Tampa','s','FL','r',2), OBJECT_CONSTRUCT('c','Nashville','s','TN','r',2),
            OBJECT_CONSTRUCT('c','Chicago','s','IL','r',3), OBJECT_CONSTRUCT('c','Columbus','s','OH','r',3),
            OBJECT_CONSTRUCT('c','Detroit','s','MI','r',3), OBJECT_CONSTRUCT('c','Madison','s','WI','r',3),
            OBJECT_CONSTRUCT('c','Denver','s','CO','r',4), OBJECT_CONSTRUCT('c','Seattle','s','WA','r',4),
            OBJECT_CONSTRUCT('c','Phoenix','s','AZ','r',4), OBJECT_CONSTRUCT('c','Portland','s','OR','r',4),
            OBJECT_CONSTRUCT('c','Dublin','s','D','r',5),   OBJECT_CONSTRUCT('c','Cork','s','CO','r',5),
            OBJECT_CONSTRUCT('c','Munich','s','BY','r',6),  OBJECT_CONSTRUCT('c','Berlin','s','BE','r',6)) AS loc,
        ARRAY_CONSTRUCT('Main St','Oak Ave','Maple Dr','Cedar Ln','Elm St','Park Rd','Lake View','Hill St','River Rd','Church St') AS st)
SELECT g.n,
       GET(a.fn, UNIFORM(0, 39, RANDOM(11)))::STRING,
       GET(a.ln, UNIFORM(0, 39, RANDOM(12)))::STRING,
       LPAD(UNIFORM(100, 899, RANDOM(13)), 3, '0') || '-' || LPAD(UNIFORM(10, 99, RANDOM(14)), 2, '0') || '-' || LPAD(UNIFORM(1000, 9999, RANDOM(15)), 4, '0'),
       DATEADD(day, -UNIFORM(18 * 365, 85 * 365, RANDOM(16)), '2026-01-01'::DATE),
       NULL,  -- email filled below (needs the names)
       '+1-555-' || LPAD(UNIFORM(0, 9999, RANDOM(17)), 4, '0'),
       UNIFORM(1, 9999, RANDOM(18)) || ' ' || GET(a.st, UNIFORM(0, 9, RANDOM(19)))::STRING,
       GET(GET(a.loc, MOD(g.n, 20)), 'c')::STRING,
       GET(GET(a.loc, MOD(g.n, 20)), 's')::STRING,
       LPAD(UNIFORM(1000, 99999, RANDOM(20)), 5, '0'),
       GET(GET(a.loc, MOD(g.n, 20)), 'r')::NUMBER,
       'CORE_PAS',
       DATEADD(minute, -UNIFORM(0, 525600, RANDOM(21)), '2026-11-01 00:00:00'::TIMESTAMP_NTZ)
FROM g, a;

-- Email: ~2% intentionally missing so the data quality lab has something to find
UPDATE policyholders
SET email = CASE WHEN MOD(holder_id, 50) = 7 THEN NULL
                 ELSE LOWER(REPLACE(first_name || '.' || last_name, '''', '')) || holder_id || '@example.com' END;

-- 40 duplicates from a second source system (agency portal) with typical variations
INSERT INTO policyholders
SELECT 900000 + holder_id,
       CASE MOD(holder_id, 4) WHEN 0 THEN UPPER(first_name)
                              WHEN 1 THEN LEFT(first_name, LENGTH(first_name) - 1)   -- typo: last letter dropped
                              WHEN 2 THEN first_name || ' '                          -- trailing space
                              ELSE LOWER(first_name) END,
       last_name,
       REPLACE(ssn, '-', ''),                                                    -- SSN without dashes
       date_of_birth,
       UPPER(email),
       REPLACE(phone, '+1-', ''),
       REPLACE(REPLACE(street, ' Street', ' St'), ' Avenue', ' Ave'),
       city, state_code, postal_code, region_id,
       'AGENCY_PORTAL',
       DATEADD(day, -30, updated_at)
FROM policyholders
WHERE holder_id <= 40;

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 4 │ Policies (12,000)
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE policies (
    policy_id        VARCHAR(12)  PRIMARY KEY,
    holder_id        NUMBER(7)    REFERENCES policyholders,
    agent_id         NUMBER(4)    REFERENCES agents,
    line_of_business VARCHAR(12),
    status           VARCHAR(10),
    effective_date   DATE,
    expiration_date  DATE,
    annual_premium   NUMBER(10,2),
    deductible       NUMBER(8,2),
    coverage_limit   NUMBER(12,2)
);
INSERT INTO policies
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 12000))),
     b AS (SELECT n,
                  UNIFORM(1, 5000, RANDOM(31)) AS holder_id,
                  UNIFORM(20, 80, RANDOM(32)) AS agent_id,
                  GET(ARRAY_CONSTRUCT('AUTO','AUTO','AUTO','HOME','HOME','LIFE','COMMERCIAL','UMBRELLA'), UNIFORM(0, 7, RANDOM(33)))::STRING AS lob,
                  DATEADD(day, UNIFORM(0, 1400, RANDOM(34)), '2022-06-01'::DATE) AS eff,
                  UNIFORM(1, 100, RANDOM(35)) AS r1,
                  UNIFORM(0, 1000, RANDOM(36)) / 1000 AS r2
           FROM g)
SELECT 'POL-' || LPAD(n, 6, '0'),
       holder_id, agent_id, lob,
       CASE WHEN r1 <= 4 THEN 'CANCELLED'
            WHEN DATEADD(year, IFF(lob = 'LIFE', 20, 1), eff) < '2026-11-01' THEN 'LAPSED'
            ELSE 'ACTIVE' END,
       eff,
       DATEADD(year, IFF(lob = 'LIFE', 20, 1), eff),
       ROUND(CASE lob WHEN 'AUTO' THEN 700 + 1900 * r2  WHEN 'HOME' THEN 900 + 2600 * r2
                      WHEN 'LIFE' THEN 300 + 2200 * r2  WHEN 'COMMERCIAL' THEN 4000 + 36000 * r2
                      ELSE 250 + 600 * r2 END, 2),
       CASE lob WHEN 'COMMERCIAL' THEN 5000 WHEN 'HOME' THEN 1000 WHEN 'AUTO' THEN 500 ELSE 0 END,
       CASE lob WHEN 'AUTO' THEN 300000 WHEN 'HOME' THEN 450000 WHEN 'LIFE' THEN 500000
                WHEN 'COMMERCIAL' THEN 2000000 ELSE 1000000 END
FROM b;

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 5 │ Claims (20,000) with adjuster notes for the Cortex lab
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE claims (
    claim_id       VARCHAR(12)  PRIMARY KEY,
    policy_id      VARCHAR(12)  REFERENCES policies,
    holder_id      NUMBER(7),
    region_id      NUMBER(2),            -- denormalized for reporting and materialized views
    line_of_business VARCHAR(12),
    claim_type     VARCHAR(30),
    claim_date     DATE,
    reported_date  DATE,
    status         VARCHAR(10),
    claim_amount   NUMBER(12,2),
    paid_amount    NUMBER(12,2),
    fraud_flag     BOOLEAN,
    adjuster_id    NUMBER(3)    REFERENCES adjusters,
    adjuster_notes VARCHAR(2000),
    updated_at     TIMESTAMP_NTZ
);
INSERT INTO claims
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n,
                  UNIFORM(1, 12000, RANDOM(41)) AS pnum,
                  UNIFORM(0, 3, RANDOM(42))     AS t,
                  UNIFORM(0, 364, RANDOM(43))   AS d,
                  UNIFORM(0, 14, RANDOM(44))    AS lag_days,
                  UNIFORM(0, 1000, RANDOM(45)) / 1000 AS r,
                  UNIFORM(0, 3, RANDOM(46))     AS s,
                  UNIFORM(1, 100, RANDOM(47))   AS f,
                  UNIFORM(1, 10, RANDOM(48))    AS adj,
                  UNIFORM(0, 4, RANDOM(49))     AS o,
                  UNIFORM(60, 100, RANDOM(50))  AS pay_pct
           FROM TABLE(GENERATOR(ROWCOUNT => 20000))),
     c AS (SELECT g.*, p.policy_id, p.holder_id, h.region_id, p.line_of_business AS lob, p.effective_date,
                  CASE p.line_of_business
                      WHEN 'AUTO'       THEN GET(ARRAY_CONSTRUCT('Collision','Glass Damage','Theft','Liability - Bodily Injury'), g.t)::STRING
                      WHEN 'HOME'       THEN GET(ARRAY_CONSTRUCT('Water Damage','Fire','Wind and Hail','Burglary'), g.t)::STRING
                      WHEN 'LIFE'       THEN GET(ARRAY_CONSTRUCT('Death Benefit','Accelerated Benefit','Death Benefit','Waiver of Premium'), g.t)::STRING
                      WHEN 'COMMERCIAL' THEN GET(ARRAY_CONSTRUCT('Property Damage','Business Interruption','General Liability','Equipment Breakdown'), g.t)::STRING
                      ELSE                   GET(ARRAY_CONSTRUCT('Excess Liability','Personal Injury','Excess Liability','Property Damage'), g.t)::STRING
                  END AS claim_type,
                  LEAST(DATEADD(day, g.d, p.effective_date), '2026-11-08'::DATE) AS claim_date
           FROM g
           JOIN policies p      ON p.policy_id = 'POL-' || LPAD(g.pnum, 6, '0')
           JOIN policyholders h ON h.holder_id = p.holder_id),
     s AS (SELECT c.*,
                  CASE WHEN claim_date >= '2026-09-15' THEN IFF(s <= 1, 'OPEN', 'IN_REVIEW')
                       WHEN s = 0 THEN 'DENIED' ELSE 'CLOSED' END AS status,
                  ROUND(CASE lob WHEN 'AUTO' THEN 400 + 24000 * r  WHEN 'HOME' THEN 1500 + 60000 * r
                                 WHEN 'LIFE' THEN 25000 + 475000 * r WHEN 'COMMERCIAL' THEN 5000 + 250000 * r
                                 ELSE 10000 + 400000 * r END, 2) AS amount
           FROM c)
SELECT 'CLM-' || LPAD(n, 7, '0'),
       policy_id, holder_id, region_id, lob, claim_type, claim_date,
       DATEADD(day, lag_days, claim_date),
       status,
       amount,
       CASE status WHEN 'CLOSED' THEN ROUND(amount * pay_pct / 100, 2)
                   WHEN 'DENIED' THEN 0
                   ELSE ROUND(amount * MOD(pay_pct, 40) / 100, 2) END,
       f <= 3,
       adj,
       'Policyholder reported ' || LOWER(claim_type) || ' on ' || TO_CHAR(claim_date, 'Mon DD, YYYY') || '. '
       || GET(ARRAY_CONSTRUCT(
              'Inspection confirmed damage consistent with the description and photos supplied.',
              'Photos were incomplete and a second site visit was scheduled.',
              'Police report and witness statements were received and reviewed.',
              'Contractor estimate appears high compared with similar regional claims.',
              'Customer was cooperative and provided receipts promptly.'), o)::STRING || ' '
       || CASE WHEN f <= 3 THEN 'Several details conflict with the timeline; referred to the special investigations unit for possible fraud.'
               WHEN status = 'DENIED' THEN 'Loss is excluded under the policy terms; denial letter sent to the customer, who was unhappy with the decision.'
               WHEN status = 'CLOSED' THEN 'Payment issued and the claim closed; customer thanked the team for the quick resolution.'
               WHEN status = 'IN_REVIEW' THEN 'Awaiting final estimate before a coverage decision.'
               ELSE 'Claim opened and assigned; initial reserve set.' END,
       DATEADD(minute, UNIFORM(0, 1440, RANDOM(51)), DATEADD(day, lag_days, claim_date)::TIMESTAMP_NTZ)
FROM s;

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 6 │ Claim Payments (1–3 payments per paid claim)
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE claim_payments (
    payment_id   NUMBER(9)    PRIMARY KEY,
    claim_id     VARCHAR(12)  REFERENCES claims,
    payment_date DATE,
    amount       NUMBER(12,2),
    payee_type   VARCHAR(20)
);
INSERT INTO claim_payments
WITH k AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS k FROM TABLE(GENERATOR(ROWCOUNT => 3))),
     c AS (SELECT claim_id, reported_date, paid_amount,
                  1 + MOD(TO_NUMBER(SUBSTR(claim_id, 5)), 3) AS n_pay
           FROM claims WHERE paid_amount > 0)
SELECT ROW_NUMBER() OVER (ORDER BY c.claim_id, k.k),
       c.claim_id,
       DATEADD(day, 10 * k.k, c.reported_date),
       ROUND(c.paid_amount / c.n_pay, 2),
       GET(ARRAY_CONSTRUCT('POLICYHOLDER','REPAIR_SHOP','CONTRACTOR','MEDICAL_PROVIDER'), MOD(k.k + TO_NUMBER(SUBSTR(c.claim_id, 5)), 4))::STRING
FROM c JOIN k ON k.k <= c.n_pay;

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 7 │ Verify
-- ──────────────────────────────────────────────────────────────────────────────
SELECT 'REGIONS' AS table_name, COUNT(*) AS row_count FROM regions UNION ALL
SELECT 'OFFICES', COUNT(*) FROM offices UNION ALL
SELECT 'AGENTS', COUNT(*) FROM agents UNION ALL
SELECT 'ADJUSTERS', COUNT(*) FROM adjusters UNION ALL
SELECT 'POLICYHOLDERS', COUNT(*) FROM policyholders UNION ALL
SELECT 'POLICIES', COUNT(*) FROM policies UNION ALL
SELECT 'CLAIMS', COUNT(*) FROM claims UNION ALL
SELECT 'CLAIM_PAYMENTS', COUNT(*) FROM claim_payments
ORDER BY 1;
-- Expected: ADJUSTERS 10, AGENTS 80, CLAIMS 20000, OFFICES 12, POLICIES 12000,
--           POLICYHOLDERS 5040, REGIONS 6, CLAIM_PAYMENTS ≈ 30000
