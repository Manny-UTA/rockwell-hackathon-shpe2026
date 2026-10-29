-- =============================================================================
-- AGENT 3 - INSIGHTS
-- Takes Agent 2's patterns and turns them into evidence and visuals: scores the triage
-- card on held-out 2026 repairs, and builds dashboard-ready summaries for the app and Lakeview.
-- Part of the repair-triage-agents job: agent1_extract -> agent2_patterns -> agent3_insights.
-- Each agent logs what it handed off in ultraviolet.gold_real.agent_handoffs.
-- Statements are separated by lines containing only ';'.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Gold: evaluation - predict every labeled 2026 line from 2023-2025 patterns
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.gold_real.eval_results
COMMENT 'Real data (Agent 3): every labeled 2026 order line scored against triage_patterns_train (2023-2025). baseline = always predict the most common training cause'
AS
WITH ev AS (
  SELECT o.order_number, o.line_number, o.catalog, o.family, o.symptom, o.is_vague,
         array_sort(collect_set(c.cause)) AS actual_causes
  FROM ultraviolet.silver_real.repair_orders_clean o
  JOIN ultraviolet.silver_real.repair_cause c USING (order_number, line_number)
  WHERE o.submit_date >= DATE'2026-01-01'
  GROUP BY ALL
),
cand AS (
  SELECT ev.order_number, ev.line_number, tp.level, tp.cause, tp.cases, tp.total,
         CASE tp.level WHEN 'catalog+symptom' THEN 1 WHEN 'family+symptom' THEN 2 WHEN 'family' THEN 3 ELSE 4 END AS pri
  FROM ev JOIN ultraviolet.gold_real.triage_patterns_train tp
    ON (tp.level = 'catalog+symptom' AND tp.catalog = ev.catalog AND tp.symptom = ev.symptom)
    OR (tp.level = 'family+symptom' AND tp.family = ev.family AND tp.symptom = ev.symptom)
    OR (tp.level = 'family' AND tp.family = ev.family)
    OR tp.level = 'all'
),
best AS (SELECT order_number, line_number, min(pri) AS pri FROM cand WHERE total >= 20 GROUP BY ALL),
ranked AS (
  SELECT c.*, 100.0 * c.cases / c.total AS share,
         row_number() OVER (PARTITION BY c.order_number, c.line_number ORDER BY c.cases DESC, c.cause) AS rnk
  FROM cand c JOIN best b USING (order_number, line_number, pri)
),
pred AS (
  SELECT order_number, line_number,
         transform(array_sort(collect_list(named_struct('r', rnk, 'c', cause))), x -> x.c) AS predicted_top3,
         max(level) AS level_used, max(total) AS n,
         CASE WHEN max(level) = 'all' THEN 'Low'
              WHEN max(total) >= 50 AND max(CASE WHEN rnk = 1 THEN share END) - coalesce(max(CASE WHEN rnk = 2 THEN share END), 0) >= 15 THEN 'High'
              WHEN max(total) >= 20 THEN 'Medium' ELSE 'Low' END AS confidence
  FROM ranked WHERE rnk <= 3 GROUP BY ALL
),
base AS (
  SELECT cause FROM ultraviolet.gold_real.triage_patterns_train WHERE level = 'all' ORDER BY cases DESC LIMIT 1
)
SELECT ev.order_number, ev.line_number, ev.catalog, ev.family, ev.symptom, ev.is_vague,
       p.predicted_top3, ev.actual_causes, p.level_used, p.n, p.confidence,
       array_contains(ev.actual_causes, p.predicted_top3[0])                    AS hit_at_1,
       size(array_intersect(ev.actual_causes, p.predicted_top3)) > 0             AS hit_at_3,
       base.cause                                                                AS baseline_cause,
       array_contains(ev.actual_causes, base.cause)                              AS baseline_hit
FROM ev JOIN pred p USING (order_number, line_number) CROSS JOIN base
;

-- ---------------------------------------------------------------------------
-- Gold: dashboard-ready insights
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.gold_real.family_insights
COMMENT 'Real data (Agent 3): one row per product family - volume, top cause, no-problem-found rate, repeat returns, cycle time, price'
AS
WITH o AS (SELECT * FROM ultraviolet.silver_real.repair_orders_clean),
lab AS (SELECT DISTINCT order_number, line_number FROM ultraviolet.silver_real.repair_cause),
npf AS (SELECT DISTINCT order_number, line_number FROM ultraviolet.silver_real.repair_cause WHERE cause = 'No Problem Found'),
top AS (
  SELECT family, max_by(cause, cases) AS top_cause, round(100.0 * max(cases) / max(total), 1) AS top_cause_pct
  FROM ultraviolet.gold_real.triage_patterns WHERE level = 'family' GROUP BY family
),
rep AS (
  SELECT ultraviolet.gold_real.lookup_family(catalog) AS family, count_if(prior_repairs >= 2) AS repeat_serials
  FROM ultraviolet.gold_real.repeat_returns GROUP BY 1
)
SELECT o.family,
       count(*) AS order_lines,
       count(lab.order_number) AS labeled_lines,
       t.top_cause, t.top_cause_pct,
       round(100.0 * count(npf.order_number) / nullif(count(lab.order_number), 0), 1) AS no_problem_found_pct,
       coalesce(max(r.repeat_serials), 0) AS repeat_serials,
       percentile_approx(CASE WHEN datediff(o.repair_complete_date, o.received_date) BETWEEN 0 AND 365
                              THEN datediff(o.repair_complete_date, o.received_date) END, 0.5) AS median_cycle_days,
       round(avg(o.net_price), 0) AS avg_net_price,
       round(100.0 * count_if(o.is_vague) / count(*), 1) AS vague_complaint_pct
FROM o
LEFT JOIN lab USING (order_number, line_number)
LEFT JOIN npf USING (order_number, line_number)
LEFT JOIN top t ON t.family = o.family
LEFT JOIN rep r ON r.family = o.family
GROUP BY o.family, t.top_cause, t.top_cause_pct
;

CREATE OR REPLACE TABLE ultraviolet.gold_real.monthly_trends
COMMENT 'Real data (Agent 3): order lines per month and family, with labeled cause mix'
AS
SELECT date_trunc('month', o.submit_date) AS month, o.family, c.cause,
       count(DISTINCT o.order_number, o.line_number) AS order_lines
FROM ultraviolet.silver_real.repair_orders_clean o
LEFT JOIN ultraviolet.silver_real.repair_cause c USING (order_number, line_number)
WHERE o.submit_date IS NOT NULL
GROUP BY ALL
;

INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '3 Insights', 'gold_real.eval_results', (SELECT count(*) FROM ultraviolet.gold_real.eval_results), (SELECT concat('Scored ', format_number(count(*), 0), ' held-out 2026 repairs: top-1 ', round(100 * avg(CAST(hit_at_1 AS INT)), 1), '%, top-3 ', round(100 * avg(CAST(hit_at_3 AS INT)), 1), '% vs baseline ', round(100 * avg(CAST(baseline_hit AS INT)), 1), '%') FROM ultraviolet.gold_real.eval_results)
;
INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '3 Insights', 'gold_real.family_insights', (SELECT count(*) FROM ultraviolet.gold_real.family_insights), (SELECT concat(format_number(count(*), 0), ' family scorecards and ', format_number((SELECT count(*) FROM ultraviolet.gold_real.monthly_trends), 0), ' monthly trend rows for dashboards') FROM ultraviolet.gold_real.family_insights)
;
