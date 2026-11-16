/*----------------SnowPro Advanced: Architect 3-day class Lab:-----------------------
-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
Hands-on #06a — Claims Feed Generator (used by Hands-on #06, Demo 4)
Simulates Smith's mobile app and agency systems dropping claim files into the
internal landing stage. Each batch writes one JSON file of 5,000 new claims to
@SMITH_INS.RAW.CLAIMS_LANDING/feed/. Snowpipe picks them up automatically.
Default: 20 batches = 100,000 claims (~20 files). Change BATCHES below.
Prerequisite: Hands-on #06 Demo 3 (stage, table and pipe exist).
----------------------------------------------------------------------------------*/

USE ROLE sysadmin;
USE WAREHOUSE smith_wh;
USE SCHEMA smith_ins.raw;

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 1 │ A view that produces one batch of random new claims as JSON
-- ──────────────────────────────────────────────────────────────────────────────
-- Unseeded RANDOM() → every query of the view returns different claims.
CREATE OR REPLACE VIEW smith_ins.raw.v_claims_feed_generator AS
WITH g AS (
    SELECT UNIFORM(1, 12000, RANDOM())        AS pnum,
           UNIFORM(0, 3, RANDOM())            AS t,
           UNIFORM(1, 3, RANDOM())            AS n_items,
           UNIFORM(0, 1000, RANDOM()) / 1000  AS r,
           UNIFORM(1, 30, RANDOM())           AS days_ago
    FROM TABLE(GENERATOR(ROWCOUNT => 5000))
)
SELECT OBJECT_CONSTRUCT(
         'claim_id',         'FD-' || UPPER(LEFT(REPLACE(UUID_STRING(), '-', ''), 10)),
         'policy_id',        p.policy_id,
         'line_of_business', p.line_of_business,
         'claim_type',       CASE p.line_of_business
                                 WHEN 'AUTO' THEN GET(ARRAY_CONSTRUCT('Collision','Glass Damage','Theft','Liability - Bodily Injury'), g.t)
                                 WHEN 'HOME' THEN GET(ARRAY_CONSTRUCT('Water Damage','Fire','Wind and Hail','Burglary'), g.t)
                                 ELSE GET(ARRAY_CONSTRUCT('Property Damage','General Liability','Excess Liability','Personal Injury'), g.t) END,
         'loss_date',        DATEADD(day, -g.days_ago, CURRENT_DATE()),
         'reported_at',      CURRENT_TIMESTAMP(),
         'channel',          GET(ARRAY_CONSTRUCT('MOBILE_APP','AGENT','PHONE','WEB'), MOD(g.pnum, 4)),
         'claimant',         OBJECT_CONSTRUCT('holder_id', p.holder_id,
                                              'contact_pref', GET(ARRAY_CONSTRUCT('EMAIL','SMS','PHONE'), MOD(g.pnum, 3))),
         'line_items',       ARRAY_SLICE(ARRAY_CONSTRUCT(
                                 OBJECT_CONSTRUCT('item', 'Labor',  'amount', ROUND(200 + 3000 * g.r, 2)),
                                 OBJECT_CONSTRUCT('item', 'Parts',  'amount', ROUND(100 + 5000 * g.r, 2)),
                                 OBJECT_CONSTRUCT('item', 'Rental', 'amount', ROUND(50 + 900 * g.r, 2))), 0, g.n_items)
       ) AS rec
FROM g
JOIN smith_ins.core.policies p ON p.policy_id = 'POL-' || LPAD(g.pnum, 6, '0');

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 2 │ Push the batches into the landing stage
-- ──────────────────────────────────────────────────────────────────────────────
EXECUTE IMMEDIATE $$
DECLARE
    batches INTEGER DEFAULT 20;          -- 20 x 5,000 = 100,000 claims
    stmt    VARCHAR;
    prefix  VARCHAR;
BEGIN
    FOR i IN 1 TO batches DO
        prefix := 'feed/claims_' || TO_CHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS') || '_b' || LPAD(i::VARCHAR, 3, '0') || '_';
        stmt := 'COPY INTO @smith_ins.raw.claims_landing/' || prefix ||
                ' FROM (SELECT rec FROM smith_ins.raw.v_claims_feed_generator)' ||
                ' FILE_FORMAT = (TYPE = JSON) SINGLE = FALSE MAX_FILE_SIZE = 16000000';
        EXECUTE IMMEDIATE :stmt;
    END FOR;
    RETURN 'Pushed ' || batches || ' batches (' || (batches * 5000) || ' claims) to @RAW.CLAIMS_LANDING/feed/';
END;
$$;

-- ──────────────────────────────────────────────────────────────────────────────
-- STEP 3 │ What landed?
-- ──────────────────────────────────────────────────────────────────────────────
LIST @smith_ins.raw.claims_landing/feed/;
