-- =============================================================================
-- AGENT 2 - PATTERNS
-- Takes Agent 1's structured lines and finds the patterns: cause frequencies by
-- catalog/family/symptom, parts and areas per cause, repeat returns, recommendations,
-- and the triage_card function technicians (and the Genie agents) call.
-- Part of the repair-triage-agents job: agent1_extract -> agent2_patterns -> agent3_insights.
-- Each agent logs what it handed off in ultraviolet.gold_real.agent_handoffs.
-- Statements are separated by lines containing only ';'.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Gold: triage patterns (full history) and train patterns (2023-2025 only)
-- total = labeled lines in the group; cases = lines with that cause (multi-label, so shares can sum > 100%)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.gold_real.triage_patterns
COMMENT 'Real data (Agent 2): cause frequencies at catalog+symptom, family+symptom, family and all levels. total = labeled lines in group'
AS
WITH lab AS (
  SELECT o.order_number, o.line_number, o.catalog, o.family, o.symptom, c.cause
  FROM ultraviolet.silver_real.repair_orders_clean o
  JOIN ultraviolet.silver_real.repair_cause c USING (order_number, line_number)
),
g AS (
  SELECT 'catalog+symptom' AS level, catalog, family, symptom, cause, order_number, line_number FROM lab WHERE symptom IS NOT NULL
  UNION ALL SELECT 'family+symptom', NULL, family, symptom, cause, order_number, line_number FROM lab WHERE symptom IS NOT NULL
  UNION ALL SELECT 'family', NULL, family, NULL, cause, order_number, line_number FROM lab
  UNION ALL SELECT 'all', NULL, NULL, NULL, cause, order_number, line_number FROM lab
),
totals AS (
  SELECT level, catalog, family, symptom, count(DISTINCT order_number, line_number) AS total FROM g GROUP BY ALL
)
SELECT c.level, c.catalog, c.family, c.symptom, c.cause, c.cases, t.total
FROM (SELECT level, catalog, family, symptom, cause, count(DISTINCT order_number, line_number) AS cases FROM g GROUP BY ALL) c
JOIN totals t
  ON c.level = t.level AND c.catalog <=> t.catalog AND c.family <=> t.family AND c.symptom <=> t.symptom
;

CREATE OR REPLACE TABLE ultraviolet.gold_real.triage_patterns_train
COMMENT 'Real data (Agent 2): same as triage_patterns but built from 2023-2025 orders ONLY (used for evaluation on 2026)'
AS
WITH lab AS (
  SELECT o.order_number, o.line_number, o.catalog, o.family, o.symptom, c.cause
  FROM ultraviolet.silver_real.repair_orders_clean o
  JOIN ultraviolet.silver_real.repair_cause c USING (order_number, line_number)
  WHERE o.submit_date < DATE'2026-01-01'
),
g AS (
  SELECT 'catalog+symptom' AS level, catalog, family, symptom, cause, order_number, line_number FROM lab WHERE symptom IS NOT NULL
  UNION ALL SELECT 'family+symptom', NULL, family, symptom, cause, order_number, line_number FROM lab WHERE symptom IS NOT NULL
  UNION ALL SELECT 'family', NULL, family, NULL, cause, order_number, line_number FROM lab
  UNION ALL SELECT 'all', NULL, NULL, NULL, cause, order_number, line_number FROM lab
),
totals AS (
  SELECT level, catalog, family, symptom, count(DISTINCT order_number, line_number) AS total FROM g GROUP BY ALL
)
SELECT c.level, c.catalog, c.family, c.symptom, c.cause, c.cases, t.total
FROM (SELECT level, catalog, family, symptom, cause, count(DISTINCT order_number, line_number) AS cases FROM g GROUP BY ALL) c
JOIN totals t
  ON c.level = t.level AND c.catalog <=> t.catalog AND c.family <=> t.family AND c.symptom <=> t.symptom
;

-- ---------------------------------------------------------------------------
-- Gold: parts and areas by family + cause
-- part rows have area NULL and vice versa
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.gold_real.parts_by_cause
COMMENT 'Real data (Agent 2): how often each standardized part type / affected area appears per family and cause. part rows have area NULL, area rows have part NULL'
AS
SELECT o.family, c.cause,
       CASE WHEN p.kind = 'part' THEN p.item END AS part,
       CASE WHEN p.kind = 'area' THEN p.item END AS area,
       count(*) AS `count`
FROM ultraviolet.silver_real.repair_parts p
JOIN ultraviolet.silver_real.repair_orders_clean o USING (order_number, line_number)
JOIN ultraviolet.silver_real.repair_cause c USING (order_number, line_number)
GROUP BY ALL
HAVING count(*) >= 3
;

-- ---------------------------------------------------------------------------
-- Gold: repeat returns - one row per serial with its most recent completed repair
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.gold_real.repeat_returns
COMMENT 'Real data (Agent 2): one row per serial with its most recent completed repair. prior_repairs = completed repairs on record for the serial'
AS
WITH done AS (
  SELECT o.serial, o.catalog, o.order_number, o.line_number, o.repair_complete_date,
         (SELECT array_join(array_sort(collect_list(c.cause)), ', ') FROM ultraviolet.silver_real.repair_cause c
           WHERE c.order_number = o.order_number AND c.line_number = o.line_number) AS cause,
         (SELECT array_join(array_sort(collect_list(p.item)), '; ') FROM ultraviolet.silver_real.repair_parts p
           WHERE p.order_number = o.order_number AND p.line_number = o.line_number AND p.kind = 'part') AS parts
  FROM ultraviolet.silver_real.repair_orders_clean o
  WHERE o.repair_complete_date IS NOT NULL
    AND length(o.serial) >= 5
    AND NOT o.serial RLIKE '^(N/?A|NONE|UNKNOWN|TBD|NO ?SERIAL.*|X+|0+|1234.*)$'
)
SELECT serial,
       max_by(catalog, repair_complete_date)                 AS catalog,
       max_by(order_number, repair_complete_date)            AS prior_order_number,
       max(repair_complete_date)                             AS prior_repair_date,
       coalesce(nullif(max_by(cause, repair_complete_date), ''), 'Not recorded') AS prior_cause,
       coalesce(nullif(max_by(parts, repair_complete_date), ''), 'Not recorded') AS prior_parts,
       CAST(count(*) AS INT)                                 AS prior_repairs
FROM done
GROUP BY serial
;

-- ---------------------------------------------------------------------------
-- Gold: triage functions over real patterns
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ultraviolet.gold_real.triage(p_catalog STRING, p_family STRING, p_symptom STRING)
RETURNS TABLE (rnk INT, cause STRING, share_pct DOUBLE, n BIGINT, level STRING, confidence STRING)
COMMENT 'Top 3 likely causes from real historical patterns, backing off catalog+symptom -> family+symptom -> family -> all until a group has >= 20 labeled cases'
RETURN
WITH lvl AS (
  SELECT tp.*, CASE tp.level WHEN 'catalog+symptom' THEN 1 WHEN 'family+symptom' THEN 2 WHEN 'family' THEN 3 ELSE 4 END AS pri
  FROM ultraviolet.gold_real.triage_patterns tp
  WHERE (tp.level = 'catalog+symptom' AND tp.catalog = p_catalog AND tp.symptom = p_symptom)
     OR (tp.level = 'family+symptom' AND tp.family = p_family AND tp.symptom = p_symptom)
     OR (tp.level = 'family' AND tp.family = p_family)
     OR tp.level = 'all'
),
best AS (SELECT min(pri) AS pri FROM lvl WHERE total >= 20),
ranked AS (
  SELECT l.cause, l.cases, l.total, l.level,
         CAST(row_number() OVER (ORDER BY l.cases DESC, l.cause) AS INT) AS rnk,
         100.0 * l.cases / l.total AS share
  FROM lvl l JOIN best b ON l.pri = b.pri
),
gapped AS (SELECT *, share - coalesce(lead(share) OVER (ORDER BY rnk), 0) AS gap FROM ranked)
SELECT rnk, cause, round(share, 1) AS share_pct, total AS n, level,
  CASE WHEN level = 'all' THEN 'Low'
       WHEN rnk = 1 AND total >= 50 AND gap >= 15 THEN 'High'
       WHEN total >= 20 THEN 'Medium' ELSE 'Low' END AS confidence
FROM gapped WHERE rnk <= 3
;

CREATE OR REPLACE FUNCTION ultraviolet.gold_real.triage_card(p_catalog STRING, p_serial STRING, p_failure_text STRING)
RETURNS TABLE (rnk INT, cause STRING, share_pct DOUBLE, n BIGINT, level STRING, card_confidence STRING,
               family STRING, symptom STRING, parts_to_stage STRING, areas_to_inspect STRING, repeat_warning STRING)
COMMENT 'Technician triage card over real data. Inputs: catalog number, serial number, customer failure text. Returns top 3 likely causes with % and past case count, parts to stage, areas to inspect, card confidence and a repeat-return warning if the serial was repaired in the last 180 days.'
RETURN
WITH ctx AS (
  SELECT ultraviolet.gold_real.lookup_family(p_catalog) AS family,
         upper(trim(p_catalog)) AS catalog,
         ultraviolet.gold_real.classify_symptom(ultraviolet.gold_real.clean_failure_text(p_failure_text)) AS symptom,
         nullif(regexp_replace(upper(trim(coalesce(p_serial, ''))), '^0+', ''), '') AS serial
),
lvl AS (
  SELECT tp.level, tp.cause, tp.cases, tp.total,
         CASE tp.level WHEN 'catalog+symptom' THEN 1 WHEN 'family+symptom' THEN 2 WHEN 'family' THEN 3 ELSE 4 END AS pri
  FROM ultraviolet.gold_real.triage_patterns tp CROSS JOIN ctx
  WHERE (tp.level = 'catalog+symptom' AND tp.catalog = ctx.catalog AND tp.symptom = ctx.symptom)
     OR (tp.level = 'family+symptom' AND tp.family = ctx.family AND tp.symptom = ctx.symptom)
     OR (tp.level = 'family' AND tp.family = ctx.family)
     OR tp.level = 'all'
),
best AS (SELECT min(pri) AS pri FROM lvl WHERE total >= 20),
ranked AS (
  SELECT l.cause, l.cases, l.total, l.level,
         CAST(row_number() OVER (ORDER BY l.cases DESC, l.cause) AS INT) AS rnk,
         100.0 * l.cases / l.total AS share
  FROM lvl l JOIN best b ON l.pri = b.pri
),
t AS (
  SELECT rnk, cause, round(share, 1) AS share_pct, total AS n, level,
    CASE WHEN level = 'all' THEN 'Low'
         WHEN rnk = 1 AND total >= 50 AND share - coalesce(lead(share) OVER (ORDER BY rnk), 0) >= 15 THEN 'High'
         WHEN total >= 20 THEN 'Medium' ELSE 'Low' END AS confidence
  FROM ranked
),
-- Parts / areas ranked by lift: how much more often they show up for this cause than for the family
-- overall, so universally-replaced items (covers, boards) don't crowd out cause-specific ones.
cause_n AS (
  SELECT tp.cause, tp.cases AS n_cause, sum(tp.cases) OVER () AS n_family
  FROM ultraviolet.gold_real.triage_patterns tp JOIN ctx ON tp.level = 'family' AND tp.family = ctx.family
),
pc AS (
  SELECT pb.cause, coalesce(pb.part, pb.area) AS item, CASE WHEN pb.part IS NOT NULL THEN 'part' ELSE 'area' END AS kind,
         pb.`count` AS cnt, cn.n_cause, cn.n_family,
         sum(pb.`count`) OVER (PARTITION BY pb.part, pb.area) AS item_total
  FROM ultraviolet.gold_real.parts_by_cause pb
  JOIN ctx ON pb.family = ctx.family
  JOIN cause_n cn ON cn.cause = pb.cause
),
scored AS (
  SELECT cause, kind, item, cnt,
         (cnt / n_cause) / (item_total / n_family) AS lift
  FROM pc
  WHERE cnt >= 5 AND cnt / n_cause >= 0.05
),
parts AS (
  SELECT cause, array_join(slice(transform(array_sort(collect_list(named_struct('l', -lift, 'c', -cnt, 'p', item))), x -> x.p), 1, 3), ', ') AS parts_to_stage
  FROM scored WHERE kind = 'part' GROUP BY cause
),
areas AS (
  SELECT cause, array_join(slice(transform(array_sort(collect_list(named_struct('l', -lift, 'c', -cnt, 'a', item))), x -> x.a), 1, 3), ', ') AS areas_to_inspect
  FROM scored WHERE kind = 'area' GROUP BY cause
),
rep AS (
  SELECT max(concat('REPEAT RETURN: serial ', r.serial, ' was repaired on ', CAST(r.prior_repair_date AS STRING),
                ' (', CAST(datediff(current_date(), r.prior_repair_date) AS STRING), ' days ago, order ', r.prior_order_number,
                '). Prior cause: ', r.prior_cause, '. Parts replaced: ', r.prior_parts, '.')) AS repeat_warning
  FROM ultraviolet.gold_real.repeat_returns r JOIN ctx ON r.serial = ctx.serial
  WHERE datediff(current_date(), r.prior_repair_date) <= 180
)
SELECT t.rnk, t.cause, t.share_pct, t.n, t.level,
       first_value(t.confidence) OVER (ORDER BY t.rnk) AS card_confidence,
       ctx.family, ctx.symptom, p.parts_to_stage, a.areas_to_inspect, rep.repeat_warning
FROM t CROSS JOIN ctx CROSS JOIN rep
LEFT JOIN parts p ON p.cause = t.cause LEFT JOIN areas a ON a.cause = t.cause
WHERE t.rnk <= 3
;

-- ---------------------------------------------------------------------------
-- Gold: recommendations - for every family + cause, what to stage and inspect (ranked by lift)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.gold_real.recommendations
COMMENT 'Real data (Agent 2): per family and cause, the parts to stage and areas to inspect (ranked by lift vs the family overall) plus a plain-language recommendation'
AS
WITH fam AS (
  SELECT family, cause, cases AS n_cause, total AS n_family_lines, sum(cases) OVER (PARTITION BY family) AS n_family
  FROM ultraviolet.gold_real.triage_patterns WHERE level = 'family' AND total >= 20
),
pc AS (
  SELECT pb.family, pb.cause, coalesce(pb.part, pb.area) AS item,
         CASE WHEN pb.part IS NOT NULL THEN 'part' ELSE 'area' END AS kind, pb.`count` AS cnt,
         f.n_cause, f.n_family, sum(pb.`count`) OVER (PARTITION BY pb.family, pb.part, pb.area) AS item_total
  FROM ultraviolet.gold_real.parts_by_cause pb JOIN fam f ON f.family = pb.family AND f.cause = pb.cause
),
scored AS (
  SELECT family, cause, kind, item, cnt, (cnt / n_cause) / (item_total / n_family) AS lift
  FROM pc WHERE cnt >= 5 AND cnt / n_cause >= 0.05
),
agg AS (
  SELECT family, cause,
    array_join(slice(transform(array_sort(collect_list(CASE WHEN kind = 'part' THEN named_struct('l', -lift, 'c', -cnt, 'i', item) END)), x -> x.i), 1, 3), ', ') AS parts_to_stage,
    array_join(slice(transform(array_sort(collect_list(CASE WHEN kind = 'area' THEN named_struct('l', -lift, 'c', -cnt, 'i', item) END)), x -> x.i), 1, 3), ', ') AS areas_to_inspect
  FROM scored GROUP BY ALL
)
SELECT f.family, f.cause, f.n_cause AS cases, f.n_family_lines AS family_cases,
       round(100.0 * f.n_cause / f.n_family_lines, 1) AS share_pct,
       a.parts_to_stage, a.areas_to_inspect,
       CASE
         WHEN f.cause = 'No Problem Found' THEN 'Run a full functional test before replacing anything; confirm the failure with the customer.'
         WHEN f.cause = 'Product Update / ECN' THEN 'Check the unit against open product notices / ECNs and apply required updates first.'
         WHEN f.cause = 'Firmware / Software' THEN 'Verify and reflash firmware before replacing hardware.'
         WHEN f.cause = 'Configuration Error' THEN 'Review parameters / configuration before teardown.'
         ELSE concat('Inspect ', coalesce(a.areas_to_inspect, 'the unit'), CASE WHEN a.parts_to_stage IS NOT NULL THEN concat('; stage ', a.parts_to_stage) ELSE '' END, '.')
       END AS recommendation
FROM fam f LEFT JOIN agg a USING (family, cause)
;

INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '2 Patterns', 'gold_real.triage_patterns', (SELECT count(*) FROM ultraviolet.gold_real.triage_patterns), (SELECT concat(format_number(count(*), 0), ' cause patterns across ', format_number(count(DISTINCT family), 0), ' families (', format_number(count_if(level = 'catalog+symptom'), 0), ' catalog+symptom specific)') FROM ultraviolet.gold_real.triage_patterns)
;
INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '2 Patterns', 'gold_real.recommendations', (SELECT count(*) FROM ultraviolet.gold_real.recommendations), (SELECT concat(format_number(count(*), 0), ' family x cause recommendations with parts to stage and areas to inspect') FROM ultraviolet.gold_real.recommendations)
;
INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '2 Patterns', 'gold_real.repeat_returns', (SELECT count(*) FROM ultraviolet.gold_real.repeat_returns), (SELECT concat(format_number(count_if(prior_repairs >= 2), 0), ' serials repaired 2+ times') FROM ultraviolet.gold_real.repeat_returns)
;
