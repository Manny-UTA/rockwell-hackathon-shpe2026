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

-- ---------------------------------------------------------------------------
-- Gold: troubleshooting recommendations from the synthetic troubleshooting manual
-- Source: /Volumes/prism/shpe/workingarea/lifecycle/stopgap_data/Synthetic_Troubleshooting_Manual.docx
-- ZS-authored hackathon stand-in, NOT Rockwell documentation. Each section covers one
-- (affected area category, cause category) pair; anything else falls back to the general protocol.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.gold_real.troubleshooting_manual (
  section INT, section_title STRING, area_category STRING, cause_category STRING, step_no INT, step_text STRING
)
COMMENT 'Synthetic Troubleshooting Manual (ZS stand-in for hackathon use, NOT Rockwell documentation): one row per procedure step'
;
INSERT INTO ultraviolet.gold_real.troubleshooting_manual VALUES
  (1, 'PCBA / Circuitry - Component Failure', 'pcba_circuitry', 'component_failure', 1, 'Power down and discharge the unit per lockout/tagout procedure before opening the enclosure.'),
  (1, 'PCBA / Circuitry - Component Failure', 'pcba_circuitry', 'component_failure', 2, 'Visually inspect the affected PCBA for obvious component damage: scorching, cracked packages, bulging/leaking electrolytic capacitors, lifted or cold solder joints.'),
  (1, 'PCBA / Circuitry - Component Failure', 'pcba_circuitry', 'component_failure', 3, 'Before re-energizing, check for shorts/continuity issues across primary power rails with a multimeter.'),
  (1, 'PCBA / Circuitry - Component Failure', 'pcba_circuitry', 'component_failure', 4, 'If a specific component is visually suspect, confirm with an in-circuit or out-of-circuit component test before replacing it.'),
  (1, 'PCBA / Circuitry - Component Failure', 'pcba_circuitry', 'component_failure', 5, 'Replace the failed component at the board level by reference designator where feasible, rather than the whole assembly.'),
  (1, 'PCBA / Circuitry - Component Failure', 'pcba_circuitry', 'component_failure', 6, 'Re-run the full functional test sequence against standard acceptance criteria before return to service.'),
  (2, 'PCBA / Circuitry - Contamination', 'pcba_circuitry', 'contamination', 1, 'Before addressing the board itself, inspect and remedy the contamination ingress path: enclosure door seals/gaskets and cooling-fan filtration.'),
  (2, 'PCBA / Circuitry - Contamination', 'pcba_circuitry', 'contamination', 2, 'Remove the affected PCBA and inspect for visible residue, corrosion, or conductive debris on traces and connector pins.'),
  (2, 'PCBA / Circuitry - Contamination', 'pcba_circuitry', 'contamination', 3, 'Clean per an approved electronics-safe, no-residue solvent procedure. Do not rely on compressed air alone if the contamination is conductive/particulate, since that can redistribute rather than remove it.'),
  (2, 'PCBA / Circuitry - Contamination', 'pcba_circuitry', 'contamination', 4, 'Inspect for corrosion-related trace damage under magnification before re-installing.'),
  (2, 'PCBA / Circuitry - Contamination', 'pcba_circuitry', 'contamination', 5, 'Re-test and monitor. If contamination recurs on the same unit, escalate the environmental root cause rather than repeatedly repairing the symptom.'),
  (3, 'PCBA / Circuitry - Configuration Error', 'pcba_circuitry', 'configuration_error', 1, 'Do not replace hardware. This is a configuration issue, not a component failure.'),
  (3, 'PCBA / Circuitry - Configuration Error', 'pcba_circuitry', 'configuration_error', 2, 'Verify the unit\'s firmware/parameter set against the current approved configuration baseline for its catalog/model.'),
  (3, 'PCBA / Circuitry - Configuration Error', 'pcba_circuitry', 'configuration_error', 3, 'Re-apply the correct configuration profile using the approved configuration tool, not manual field edits.'),
  (3, 'PCBA / Circuitry - Configuration Error', 'pcba_circuitry', 'configuration_error', 4, 'Document the incorrect configuration found, to support root-causing how it was introduced.'),
  (3, 'PCBA / Circuitry - Configuration Error', 'pcba_circuitry', 'configuration_error', 5, 'Re-run the full functional test after reconfiguration.'),
  (4, 'PCBA / Circuitry - Worn / End of Life', 'pcba_circuitry', 'wear_out', 1, 'For a Worn/End-of-Life cause code on a PCB assembly, inspect electrolytic capacitors first (bulging, leaking, or discoloration at the vent) before assuming the whole board needs replacement.'),
  (4, 'PCBA / Circuitry - Worn / End of Life', 'pcba_circuitry', 'wear_out', 2, 'Measure capacitance/ESR if test equipment is available and compare against nominal spec.'),
  (4, 'PCBA / Circuitry - Worn / End of Life', 'pcba_circuitry', 'wear_out', 3, 'If capacitors test within spec, check other age-related wear points: connector contact oxidation, relay contact wear.'),
  (4, 'PCBA / Circuitry - Worn / End of Life', 'pcba_circuitry', 'wear_out', 4, 'Replace only the confirmed worn component(s) where board-level rework is feasible.'),
  (5, 'Motors - Worn / End of Life', 'motor_mechanical', 'wear_out', 1, 'Check for audible or vibration signs of bearing wear before disassembly.'),
  (5, 'Motors - Worn / End of Life', 'motor_mechanical', 'wear_out', 2, 'Measure shaft runout and bearing play against the motor\'s service-manual tolerance.'),
  (5, 'Motors - Worn / End of Life', 'motor_mechanical', 'wear_out', 3, 'If an encoder/resolver is implicated, verify signal integrity and mounting alignment before replacing the sensor itself.'),
  (5, 'Motors - Worn / End of Life', 'motor_mechanical', 'wear_out', 4, 'Replace bearings as a matched set, not individually, and re-grease per the motor\'s lubrication spec.'),
  (5, 'Motors - Worn / End of Life', 'motor_mechanical', 'wear_out', 5, 'Re-test running current draw and vibration signature against baseline after reassembly.'),
  (6, 'Fan / Cooling - Worn / End of Life', 'fan_cooling', 'wear_out', 1, 'For a Worn/End-of-Life cause code on a fan assembly, check first for elevated bearing noise/vibration and reduced RPM under load: the classic signature of fan-bearing wear.'),
  (6, 'Fan / Cooling - Worn / End of Life', 'fan_cooling', 'wear_out', 2, 'Verify airflow/RPM against the unit\'s rated spec. A worn fan often still spins but underperforms before it fully seizes.'),
  (6, 'Fan / Cooling - Worn / End of Life', 'fan_cooling', 'wear_out', 3, 'Do not attempt to lubricate sealed fan bearings not designed for field relubrication. Replace the fan assembly as a unit once wear is confirmed.'),
  (6, 'Fan / Cooling - Worn / End of Life', 'fan_cooling', 'wear_out', 4, 'Where available, check the fan\'s duty-cycle/runtime hours against its rated service life to distinguish premature failure (investigate airflow/temperature root cause) from expected end-of-life wear-out.'),
  (6, 'Fan / Cooling - Worn / End of Life', 'fan_cooling', 'wear_out', 5, 'After replacement, verify airflow/RPM against spec before closing up the unit.'),
  (7, 'Fan / Cooling - Component Failure', 'fan_cooling', 'component_failure', 1, 'Determine whether the failure is mechanical (bearing/blade) or electrical (drive circuitry) before replacing the whole fan assembly.'),
  (7, 'Fan / Cooling - Component Failure', 'fan_cooling', 'component_failure', 2, 'For a suspected mechanical failure, check for physical obstruction, blade damage, and bearing freeplay.'),
  (7, 'Fan / Cooling - Component Failure', 'fan_cooling', 'component_failure', 3, 'For a suspected electrical failure, verify fan drive voltage is present at the connector before condemning the fan motor itself.'),
  (7, 'Fan / Cooling - Component Failure', 'fan_cooling', 'component_failure', 4, 'Replace the fan assembly as a unit if the motor has failed; if only the drive circuit failed, board-level repair may be possible (see Section 1).'),
  (7, 'Fan / Cooling - Component Failure', 'fan_cooling', 'component_failure', 5, 'After replacement, verify airflow/RPM against spec before closing up the unit.'),
  (8, 'HMI / Display - Worn / End of Life', 'hmi_display', 'wear_out', 1, 'For touchscreen wear-out symptoms (reduced sensitivity, dead zones), clean the surface and check for protective-film degradation before assuming a hardware failure.'),
  (8, 'HMI / Display - Worn / End of Life', 'hmi_display', 'wear_out', 2, 'Test touch response across the full surface in a diagnostic/calibration mode if available.'),
  (8, 'HMI / Display - Worn / End of Life', 'hmi_display', 'wear_out', 3, 'For display backlight dimming, compare against a known-good unit\'s brightness rather than subjective judgment alone.'),
  (8, 'HMI / Display - Worn / End of Life', 'hmi_display', 'wear_out', 4, 'Replace the touchscreen/display assembly as a unit. Field-level component repair is not typically supported at this level.')
;

CREATE OR REPLACE TABLE ultraviolet.gold_real.manual_recommendations
COMMENT 'Agent 3: for every family x cause, the synthetic-manual procedure for the dominant affected-area category (from parts_by_cause), or the general-protocol fallback'
AS
WITH areas AS (
  SELECT family, cause, area, `count` AS cnt,
         CASE WHEN area RLIKE '(?i)firmware' THEN 'firmware'  -- only matches the configuration-error procedure (below)
              WHEN area RLIKE '(?i)^Motors' THEN 'motor_mechanical'
              WHEN area RLIKE '(?i)fan|heatsink' THEN 'fan_cooling'
              WHEN area RLIKE '(?i)touchscreen|display|monitor|crt|bezel|operator interface' THEN 'hmi_display'
              WHEN area RLIKE '(?i)^(PCBA|Circuitry|Comms PCBA)|capacitor|resistor|igbt|power module|rectifier|scr|current sensor|fuse|inverter|contactor|relay|power pole|power supply|choke|controller assembly|gate driver'
                THEN 'pcba_circuitry'
         END AS area_category
  FROM ultraviolet.gold_real.parts_by_cause WHERE area IS NOT NULL
),
by_cat AS (
  SELECT family, cause, area_category, sum(cnt) AS n, max_by(area, cnt) AS matched_area,
         sum(sum(cnt)) OVER (PARTITION BY family, cause) AS all_area_mentions
  FROM areas GROUP BY ALL
),
sections AS (
  SELECT section, section_title, area_category, cause_category,
         transform(array_sort(collect_list(named_struct('n', step_no, 's', step_text))), x -> x.s) AS steps
  FROM ultraviolet.gold_real.troubleshooting_manual GROUP BY ALL
),
recs AS (
  SELECT r.family, r.cause, r.share_pct, r.cases, r.family_cases,
         CASE r.cause WHEN 'Component Failure' THEN 'component_failure'
                      WHEN 'Contamination / Environmental' THEN 'contamination'
                      WHEN 'Configuration Error' THEN 'configuration_error'
                      WHEN 'Worn / End of Life' THEN 'wear_out' END AS cause_category
  FROM ultraviolet.gold_real.recommendations r
),
matched AS (
  -- the most-reported area category on this family + cause that the manual has a section for
  SELECT r.family, r.cause, s.section, s.section_title, s.area_category, s.steps, c.matched_area,
         round(100.0 * c.n / c.all_area_mentions, 1) AS area_share_pct,
         row_number() OVER (PARTITION BY r.family, r.cause ORDER BY c.n DESC) AS pick
  FROM recs r
  JOIN by_cat c ON c.family = r.family AND c.cause = r.cause
  JOIN sections s ON s.cause_category = r.cause_category
   AND s.area_category = CASE WHEN c.area_category = 'firmware' AND r.cause_category = 'configuration_error'
                              THEN 'pcba_circuitry' ELSE c.area_category END
)
SELECT r.family, r.cause, r.share_pct, r.cases, r.family_cases, r.cause_category,
       m.area_category, m.section AS manual_section, m.section_title, m.matched_area, m.area_share_pct,
       coalesce(m.steps, array('No tailored procedure in the synthetic manual for this failure category; apply the general troubleshooting protocol.')) AS steps,
       'Synthetic Troubleshooting Manual (ZS hackathon stand-in, not Rockwell documentation)' AS source
FROM recs r LEFT JOIN matched m ON m.family = r.family AND m.cause = r.cause AND m.pick = 1
;

INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '3 Insights', 'gold_real.manual_recommendations', (SELECT count(*) FROM ultraviolet.gold_real.manual_recommendations), (SELECT concat(format_number(count_if(manual_section IS NOT NULL), 0), ' of ', format_number(count(*), 0), ' family x cause pairs matched to a synthetic-manual procedure') FROM ultraviolet.gold_real.manual_recommendations)
;
