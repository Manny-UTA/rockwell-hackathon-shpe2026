"""Agent 3 dashboard: (re)build the Lakeview "Repair Triage" dashboard on gold_real / silver_real and publish it.

Usage: .venv/bin/python pipeline/dashboard.py [--dashboard-id <id>]
Keeps the dashboard's existing theme (uiSettings) and replaces its datasets and pages.
"""

import argparse
import json

from databricks.sdk import WorkspaceClient
from databricks.sdk.service.dashboards import Dashboard

parser = argparse.ArgumentParser()
parser.add_argument("--dashboard-id", default="01f1d3a19aa41dce8af01210b93e60f5")
parser.add_argument("--warehouse", default="6e4f969ac71d3b26")
args = parser.parse_args()

G, S = "ultraviolet.gold_real", "ultraviolet.silver_real"


def ds(name, display, sql):
    return {"name": name, "displayName": display, "queryLines": [l + "\n" for l in sql.strip().splitlines()]}


DATASETS = [
    ds("triage_lookup", "Triage Lookup (eval, 2026)", f"""
SELECT order_number, line_number, catalog, family, coalesce(symptom, 'vague') AS symptom,
       concat_ws(', ', predicted_top3) AS predicted_causes, predicted_top3[0] AS top_prediction,
       concat_ws(', ', actual_causes) AS actual_causes, confidence, level_used, n AS pattern_cases,
       CASE WHEN hit_at_1 THEN 'Yes' ELSE 'No' END AS correct_top1,
       CASE WHEN hit_at_3 THEN 'Yes' ELSE 'No' END AS correct_top3
FROM {G}.eval_results"""),
    ds("family_causes", "Root causes by family", f"""
SELECT family, cause, cases, total, round(100.0 * cases / total, 1) AS share_pct
FROM {G}.triage_patterns WHERE level = 'family' AND total >= 20"""),
    ds("recommendations", "Recommendations (Agent 2)", f"""
SELECT family, cause, share_pct, cases, parts_to_stage, areas_to_inspect, recommendation
FROM {G}.recommendations"""),
    ds("repeat_returns", "Repeat returns", f"""
SELECT serial, catalog, {G}.lookup_family(catalog) AS family, prior_repairs, prior_order_number,
       prior_repair_date, prior_cause, prior_parts
FROM {G}.repeat_returns WHERE prior_repairs >= 2"""),
    ds("eval_summary", "Accuracy summary", f"""
SELECT count(*) AS cases,
       round(100 * avg(CAST(hit_at_1 AS INT)), 1) AS top1_pct,
       round(100 * avg(CAST(hit_at_3 AS INT)), 1) AS top3_pct,
       round(100 * avg(CAST(baseline_hit AS INT)), 1) AS baseline_pct
FROM {G}.eval_results"""),
    ds("eval_by_level", "Accuracy by match level", f"""
SELECT level_used AS match_level, metric, pct, cases FROM (
  SELECT level_used, count(*) AS cases,
         round(100 * avg(CAST(hit_at_1 AS INT)), 1) AS `Top-1`,
         round(100 * avg(CAST(hit_at_3 AS INT)), 1) AS `Top-3`,
         round(100 * avg(CAST(baseline_hit AS INT)), 1) AS `Baseline`
  FROM {G}.eval_results GROUP BY level_used
) UNPIVOT (pct FOR metric IN (`Top-1`, `Top-3`, `Baseline`))"""),
    ds("family_insights", "Family scorecards", f"""
SELECT family, order_lines, labeled_lines, top_cause, top_cause_pct, no_problem_found_pct,
       repeat_serials, median_cycle_days, avg_net_price, vague_complaint_pct
FROM {G}.family_insights WHERE order_lines >= 100"""),
    ds("monthly_volume", "Monthly repair volume (top families)", f"""
WITH top AS (SELECT family FROM {S}.repair_orders_clean GROUP BY family ORDER BY count(*) DESC LIMIT 6)
SELECT date_trunc('month', submit_date) AS month, family, count(*) AS order_lines
FROM {S}.repair_orders_clean WHERE family IN (SELECT family FROM top) AND submit_date IS NOT NULL
GROUP BY ALL"""),
]


def q(dataset, fields, name="main_query"):
    return {"name": name, "query": {"datasetName": dataset, "fields": [{"name": n, "expression": e} for n, e in fields],
                                    "disaggregated": False}}


def widget(name, pos, spec, queries=None):
    w = {"name": name, "spec": spec}
    if queries:
        w["queries"] = queries
    return {"widget": w, "position": dict(zip(["x", "y", "width", "height"], pos))}


def text(name, pos, lines):
    return {"widget": {"name": name, "multilineTextboxSpec": {"lines": lines}}, "position": dict(zip(["x", "y", "width", "height"], pos))}


def table(name, pos, title, dataset, cols):
    return widget(name, pos, {"version": 2, "widgetType": "table", "frame": {"showTitle": True, "title": title},
                              "encodings": {"columns": [{"fieldName": c} for c in cols]}},
                  [{"name": "main_query", "query": {"datasetName": dataset, "fields": [{"name": c, "expression": f"`{c}`"} for c in cols],
                                                    "disaggregated": True}}])


def filt(name, pos, title, field, datasets):
    queries = [q(d, [(field, f"`{field}`"), (f"{field}_associativity", "COUNT_IF(`associative_filter_predicate_group`)")],
                 name=f"filter_{name}_{d}") for d in datasets]
    return widget(name, pos, {"version": 2, "widgetType": "filter-multi-select", "frame": {"showTitle": True, "title": title},
                              "encodings": {"fields": [{"fieldName": field, "queryName": qq["name"]} for qq in queries]}}, queries)


def counter(name, pos, title, field, desc):
    return widget(name, pos, {"version": 2, "widgetType": "counter",
                              "frame": {"showTitle": True, "title": title, "showDescription": True, "description": desc},
                              "encodings": {"value": {"fieldName": f"sum({field})", "displayName": title}}},
                  [q("eval_summary", [(f"sum({field})", f"SUM(`{field}`)")])])


technician = [
    text("header", (0, 0, 12, 1), ["## Technician View\n",
         "Real SAP repair data. Agent 1 extracts, Agent 2 finds patterns and recommendations, Agent 3 scores them. Pick a family to focus every chart."]),
    filt("filter_family", (0, 1, 4, 1), "Product family", "family",
         ["triage_lookup", "family_causes", "recommendations", "repeat_returns"]),
    filt("filter_confidence", (4, 1, 3, 1), "Card confidence", "confidence", ["triage_lookup"]),
    widget("top_causes_bar", (0, 2, 5, 5), {
        "version": 3, "widgetType": "bar", "frame": {"showTitle": True, "title": "Root causes (share of labeled repairs)"},
        "encodings": {"y": {"fieldName": "cause", "displayName": "Cause", "scale": {"type": "categorical", "sort": {"by": "x-reversed"}}},
                      "x": {"fieldName": "sum(cases)", "displayName": "Repairs with this cause", "scale": {"type": "quantitative"}}}},
        [q("family_causes", [("cause", "`cause`"), ("sum(cases)", "SUM(`cases`)")])]),
    table("recommendations_table", (5, 2, 7, 5), "What to inspect and stage (Agent 2 recommendations)", "recommendations",
          ["family", "cause", "share_pct", "recommendation", "parts_to_stage", "areas_to_inspect"]),
    table("triage_table", (0, 7, 12, 5), "Triage card vs actual outcome (2026 repairs)", "triage_lookup",
          ["order_number", "catalog", "family", "symptom", "top_prediction", "actual_causes", "correct_top1", "correct_top3",
           "confidence", "level_used", "pattern_cases"]),
    table("repeat_returns_table", (0, 12, 12, 5), "Repeat returns (serials repaired 2+ times)", "repeat_returns",
          ["serial", "catalog", "family", "prior_repairs", "prior_repair_date", "prior_order_number", "prior_cause", "prior_parts"]),
]

manager = [
    text("mgr_header", (0, 0, 12, 1), ["## Manager View: Agent 3 insights\n",
         "Triage card accuracy on held-out 2026 repairs (patterns learned from 2023-2025 only), plus family scorecards and volume trends."]),
    counter("c_top1", (0, 1, 3, 2), "Top-1 accuracy %", "top1_pct", "First prediction matched an actual cause"),
    counter("c_top3", (3, 1, 3, 2), "Top-3 accuracy %", "top3_pct", "Actual cause was in the top 3"),
    counter("c_base", (6, 1, 3, 2), "Baseline %", "baseline_pct", "Always guessing the most common cause"),
    counter("c_cases", (9, 1, 3, 2), "Eval cases", "cases", "2026 repairs with a confirmed cause"),
    widget("level_bar", (0, 3, 6, 5), {
        "version": 3, "widgetType": "bar", "frame": {"showTitle": True, "title": "Accuracy by match level (%)"},
        "encodings": {"x": {"fieldName": "match_level", "displayName": "Matched at", "scale": {"type": "categorical"}},
                      "y": {"fieldName": "sum(pct)", "displayName": "%", "scale": {"type": "quantitative"}},
                      "color": {"fieldName": "metric", "displayName": "Metric", "scale": {"type": "categorical"}}},
        "mark": {"layout": "group"}},
        [q("eval_by_level", [("match_level", "`match_level`"), ("metric", "`metric`"), ("sum(pct)", "SUM(`pct`)")])]),
    widget("volume_line", (6, 3, 6, 5), {
        "version": 3, "widgetType": "line", "frame": {"showTitle": True, "title": "Monthly repair volume, top 6 families"},
        "encodings": {"x": {"fieldName": "month", "displayName": "Month", "scale": {"type": "temporal"}},
                      "y": {"fieldName": "sum(order_lines)", "displayName": "Order lines", "scale": {"type": "quantitative"}},
                      "color": {"fieldName": "family", "displayName": "Family", "scale": {"type": "categorical"}}}},
        [q("monthly_volume", [("month", "`month`"), ("family", "`family`"), ("sum(order_lines)", "SUM(`order_lines`)")])]),
    table("scorecards", (0, 8, 12, 6), "Family scorecards", "family_insights",
          ["family", "order_lines", "labeled_lines", "top_cause", "top_cause_pct", "no_problem_found_pct", "repeat_serials",
           "median_cycle_days", "avg_net_price", "vague_complaint_pct"]),
]

w = WorkspaceClient()
current = w.lakeview.get(args.dashboard_id)
old = json.loads(current.serialized_dashboard)
new = {
    "datasets": DATASETS,
    "pages": [
        {"name": "technician", "displayName": "Technician View", "pageType": "PAGE_TYPE_CANVAS", "layout": technician},
        {"name": "manager", "displayName": "Manager View", "pageType": "PAGE_TYPE_CANVAS", "layout": manager},
    ],
    "uiSettings": old.get("uiSettings", {}),
}
w.lakeview.update(args.dashboard_id, dashboard=Dashboard(
    display_name="Repair Triage - Technician and Manager View (real data)",
    serialized_dashboard=json.dumps(new), warehouse_id=args.warehouse))
w.lakeview.publish(args.dashboard_id, warehouse_id=args.warehouse, embed_credentials=True)
print("updated + published", args.dashboard_id)
