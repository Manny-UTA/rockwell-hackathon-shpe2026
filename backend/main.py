"""FastAPI backend for the Repair Triage Databricks App.

  /api/triage          - technician triage card (UC function ultraviolet.gold.triage_card)
  /api/catalogs        - known catalog numbers for the intake form
  /api/chat            - chat with the Agent Bricks supervisor endpoint
  /api/accuracy        - manager view: eval_results + summary KPIs
  /api/repeat-returns  - units that came back after a prior repair
  /api/recommendations - what to do per family + cause, with the family's risk scorecard and accuracy
  /api/agents          - what each agent (extract -> patterns -> insights) handed off in the last job run
  /api/simulate/...    - walk one real (or typed-in) repair through the three agents

Inside a Databricks App, WorkspaceClient() authenticates as the app's service
principal. Locally it uses your ~/.databrickscfg profile.
"""

import json
import os
from pathlib import Path
from typing import Any

from databricks.sdk import WorkspaceClient
from databricks.sdk.service.sql import StatementParameterListItem, StatementState
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

WAREHOUSE_ID = os.getenv("DATABRICKS_WAREHOUSE_ID", "")
AGENT_ENDPOINT = os.getenv("AGENT_ENDPOINT", "")
CATALOG = os.getenv("UC_CATALOG", "ultraviolet")
SILVER = f'{CATALOG}.{os.getenv("SILVER_SCHEMA", "silver_real")}'
GOLD = f'{CATALOG}.{os.getenv("GOLD_SCHEMA", "gold_real")}'
APP_TITLE = os.getenv("APP_TITLE", "Repair Triage")

app = FastAPI(title=APP_TITLE)
_client: WorkspaceClient | None = None


def ws() -> WorkspaceClient:
    global _client
    if _client is None:
        _client = WorkspaceClient()
    return _client


def require(value: str, name: str) -> str:
    if not value:
        raise HTTPException(400, f"{name} is not configured. Set it in app.yaml.")
    return value


def sql(statement: str, params: dict[str, str | None] | None = None) -> list[dict[str, Any]]:
    """Run a parameterized query on the SQL warehouse and return rows as dicts."""
    resp = ws().statement_execution.execute_statement(
        warehouse_id=require(WAREHOUSE_ID, "DATABRICKS_WAREHOUSE_ID"),
        statement=statement,
        parameters=[StatementParameterListItem(name=k, value=v) for k, v in (params or {}).items()],
        wait_timeout="50s",
    )
    if resp.status.state != StatementState.SUCCEEDED:
        msg = resp.status.error.message if resp.status.error else resp.status.state.value
        raise HTTPException(500, f"Query failed: {msg}")
    cols = [c.name for c in resp.manifest.schema.columns]
    rows = (resp.result.data_array or []) if resp.result else []
    return [dict(zip(cols, r)) for r in rows]


@app.get("/api/config")
def config():
    return {
        "title": APP_TITLE,
        "features": {"data": bool(WAREHOUSE_ID), "chat": bool(AGENT_ENDPOINT)},
    }


# ---------- technician triage ----------

class TriageRequest(BaseModel):
    catalog: str
    serial: str | None = None
    failure_text: str | None = None


@app.get("/api/catalogs")
def catalogs():
    return {"catalogs": sql(
        f"""SELECT catalog, max(family) AS family FROM {SILVER}.repair_orders_clean
            WHERE catalog IS NOT NULL GROUP BY catalog HAVING count(*) >= 5
            ORDER BY count(*) DESC LIMIT 2000"""
    )}


@app.post("/api/triage")
def triage(req: TriageRequest):
    if not req.catalog.strip():
        raise HTTPException(400, "Catalog number is required.")
    rows = sql(
        f"SELECT * FROM {GOLD}.triage_card(:catalog, :serial, :failure_text) ORDER BY rnk",
        {
            "catalog": req.catalog.strip(),
            "serial": (req.serial or "").strip() or None,
            "failure_text": (req.failure_text or "").strip() or None,
        },
    )
    if not rows:
        return {"found": False}
    first = rows[0]
    # Agent 3's procedure from the synthetic troubleshooting manual for each predicted cause in this family
    recs = {
        r["cause"]: _manual_rec(r)
        for r in sql(
            f"""SELECT cause, manual_section, section_title, matched_area, to_json(steps) AS steps
                FROM {GOLD}.manual_recommendations WHERE family = :f""",
            {"f": first["family"]},
        )
    } if first["family"] else {}
    return {
        "found": True,
        "family": first["family"],
        "symptom": first["symptom"],
        "confidence": first["card_confidence"],
        "level": first["level"],
        "cases": int(first["n"] or 0),
        "repeat_warning": first["repeat_warning"],
        "causes": [
            {
                "rank": int(r["rnk"]),
                "cause": r["cause"],
                "share_pct": float(r["share_pct"] or 0),
                "parts": r["parts_to_stage"],
                "areas": r["areas_to_inspect"],
                "recommendation": recs.get(r["cause"]),
            }
            for r in rows
        ],
    }


MANUAL_SOURCE = "Synthetic Troubleshooting Manual (ZS hackathon stand-in, not Rockwell documentation)"


def _manual_rec(r: dict[str, Any]) -> dict[str, Any]:
    return {
        "section": int(r["manual_section"]) if r["manual_section"] else None,
        "title": r["section_title"],
        "matched_area": r["matched_area"],
        "steps": json.loads(r["steps"] or "[]"),
        "source": MANUAL_SOURCE,
    }


@app.get("/api/recommendations")
def recommendations(family: str | None = None):
    """Agent 3: synthetic-manual procedure per cause, with the family's risk scorecard and held-out accuracy."""
    families = sql(
        f"""SELECT family, order_lines, labeled_lines FROM {GOLD}.family_insights
            WHERE family IN (SELECT DISTINCT family FROM {GOLD}.manual_recommendations)
            ORDER BY order_lines DESC"""
    )
    if not families:
        return {"families": []}
    family = family or families[0]["family"]
    recs = [
        {"cause": r["cause"], "cases": int(r["cases"]), "family_cases": int(r["family_cases"]),
         "share_pct": float(r["share_pct"]), "area_share_pct": r["area_share_pct"], **_manual_rec(r)}
        for r in sql(
            f"""SELECT cause, cases, family_cases, share_pct, manual_section, section_title, matched_area,
                       area_share_pct, to_json(steps) AS steps
                FROM {GOLD}.manual_recommendations WHERE family = :f ORDER BY share_pct DESC""",
            {"f": family},
        )
    ]
    insight = _family_insight(family)
    # Depot-wide averages, weighted by volume, so each family's risk numbers have a reference point
    depot = sql(
        f"""SELECT round(sum(no_problem_found_pct * labeled_lines) / sum(labeled_lines), 1) AS no_problem_found_pct,
                   round(sum(vague_complaint_pct * order_lines) / sum(order_lines), 1) AS vague_complaint_pct,
                   percentile_approx(median_cycle_days, 0.5) AS median_cycle_days
            FROM {GOLD}.family_insights WHERE labeled_lines > 0"""
    )[0]
    accuracy = sql(
        f"""SELECT count(*) AS n,
                   round(100 * avg(CAST(hit_at_1 AS INT)), 1) AS top1,
                   round(100 * avg(CAST(hit_at_3 AS INT)), 1) AS top3
            FROM {GOLD}.eval_results WHERE family = :f""",
        {"f": family},
    )[0]
    return {"families": families, "family": family, "recommendations": recs,
            "insight": insight, "depot": depot, "accuracy": accuracy}


# ---------- manager views ----------

@app.get("/api/accuracy")
def accuracy():
    rates = """count(*) AS cases,
               round(avg(CAST(hit_at_1 AS INT)), 3) AS hit_at_1,
               round(avg(CAST(hit_at_3 AS INT)), 3) AS hit_at_3,
               round(avg(CAST(baseline_hit AS INT)), 3) AS baseline"""
    summary = sql(f"SELECT {rates}, max(baseline_cause) AS baseline_cause FROM {GOLD}.eval_results")[0]
    by_level = sql(
        f"""SELECT level_used, {rates} FROM {GOLD}.eval_results GROUP BY level_used
            ORDER BY CASE level_used WHEN 'catalog+symptom' THEN 1 WHEN 'family+symptom' THEN 2
                                     WHEN 'family' THEN 3 ELSE 4 END"""
    )
    rows = sql(
        f"""SELECT order_number, line_number, catalog, family, symptom, is_vague,
                   predicted_top3, actual_causes, level_used, n, confidence,
                   hit_at_1, hit_at_3, baseline_cause, baseline_hit
            FROM {GOLD}.eval_results ORDER BY order_number DESC, line_number LIMIT 300"""
    )
    return {"summary": summary, "by_level": by_level, "rows": rows}


@app.get("/api/patterns")
def patterns():
    causes = sql(
        f"""SELECT family, cause, cases, total FROM {GOLD}.triage_patterns
            WHERE level = 'family' AND total >= 50 ORDER BY total DESC, family, cases DESC"""
    )
    items = sql(
        f"""SELECT family, cause, part, area, `count` FROM {GOLD}.parts_by_cause
            WHERE family IN (SELECT family FROM {GOLD}.triage_patterns WHERE level = 'family' AND total >= 50)
            ORDER BY family, `count` DESC"""
    )
    return {
        "causes": causes,
        "parts": [i for i in items if i["part"]],
        "areas": [i for i in items if i["area"]],
    }


@app.get("/api/repeat-returns")
def repeat_returns():
    return {"rows": sql(
        f"""SELECT * FROM {GOLD}.repeat_returns WHERE prior_repairs >= 2
            ORDER BY prior_repair_date DESC, prior_repairs DESC LIMIT 1000"""
    )}


# ---------- agents + simulator ----------

@app.get("/api/agents")
def agents():
    """What each agent handed to the next one in the most recent job run."""
    rows = sql(
        f"""SELECT agent, output_table, rows, summary, run_at FROM {GOLD}.agent_handoffs
            WHERE run_at >= (SELECT max(run_at) FROM {GOLD}.agent_handoffs) - INTERVAL 30 MINUTES
            QUALIFY row_number() OVER (PARTITION BY agent, output_table ORDER BY run_at DESC) = 1
            ORDER BY agent, run_at"""
    )
    return {"handoffs": rows}


@app.get("/api/simulate/samples")
def simulate_samples():
    """A handful of real held-out 2026 repairs that show different paths through the agents."""
    return {"samples": sql(
        f"""WITH e AS (
              SELECT e.*, o.serial, r.prior_repairs,
                     CASE WHEN e.level_used = 'catalog+symptom' AND e.hit_at_1 THEN 'Specific match, correct'
                          WHEN e.level_used = 'family+symptom' AND e.hit_at_1 THEN 'Family + symptom match, correct'
                          WHEN r.prior_repairs >= 2 THEN 'Repeat-return unit'
                          WHEN e.is_vague AND e.hit_at_3 THEN 'Vague complaint, still in top 3'
                          WHEN NOT e.hit_at_3 THEN 'Missed: actual cause not in top 3'
                          WHEN NOT e.hit_at_1 AND e.hit_at_3 THEN 'Right cause ranked 2nd or 3rd' END AS story
              FROM {GOLD}.eval_results e
              JOIN {SILVER}.repair_orders_clean o USING (order_number, line_number)
              LEFT JOIN {GOLD}.repeat_returns r ON r.serial = o.serial
            )
            SELECT story, order_number, line_number, catalog, family, symptom
            FROM e WHERE story IS NOT NULL
            QUALIFY row_number() OVER (PARTITION BY story ORDER BY hash(order_number, line_number)) <= 2
            ORDER BY story"""
    )}


def _causes_parts(order_number: str, line_number: str):
    causes = sql(
        f"SELECT cause FROM {SILVER}.repair_cause WHERE order_number = :o AND line_number = :l ORDER BY cause",
        {"o": order_number, "l": line_number},
    )
    items = sql(
        f"SELECT kind, item FROM {SILVER}.repair_parts WHERE order_number = :o AND line_number = :l ORDER BY kind, item",
        {"o": order_number, "l": line_number},
    )
    return (
        [c["cause"] for c in causes],
        [i["item"] for i in items if i["kind"] == "part"],
        [i["item"] for i in items if i["kind"] == "area"],
    )


def _family_insight(family: str | None):
    if not family:
        return None
    rows = sql(f"SELECT * FROM {GOLD}.family_insights WHERE family = :f", {"f": family})
    return rows[0] if rows else None


@app.get("/api/simulate/{order_number}/{line_number}")
def simulate_order(order_number: str, line_number: str):
    # Agent 1 keeps the original report fields (PO numbers masked), so the app never reads the raw SAP table
    raw = sql(
        f"""SELECT order_number, line_number, submit_date AS order_submit_date, sap_status, catalog, part_description,
                   raw_serial_number AS serial_number, raw_failure_details AS failure_details,
                   raw_cause_code AS probable_cause_code, left(parts_replaced, 300) AS parts_replaced, affected_areas, depot
            FROM {SILVER}.repair_orders_clean
            WHERE order_number = :o AND line_number = :l""",
        {"o": order_number, "l": line_number},
    )
    if not raw:
        raise HTTPException(404, "Order line not found (service SKUs are skipped by Agent 1).")
    clean = sql(
        f"""SELECT catalog, family, symptom, is_vague, failure_text, serial, submit_date, repair_complete_date
            FROM {SILVER}.repair_orders_clean WHERE order_number = :o AND line_number = :l""",
        {"o": order_number, "l": line_number},
    )
    if not clean:
        raise HTTPException(404, "Agent 1 skipped this line (service SKU, not hardware).")
    c = clean[0]
    causes, parts, areas = _causes_parts(order_number, line_number)
    card = triage(TriageRequest(catalog=c["catalog"], serial=c["serial"], failure_text=raw[0]["failure_details"]))
    if card.get("found"):
        # Replaying a past order: only repairs finished before this unit arrived count as a repeat return
        # (the live warning would otherwise point at this very repair).
        prior = sql(
            f"""SELECT order_number, repair_complete_date, count(*) OVER () AS n
                FROM {SILVER}.repair_orders_clean
                WHERE serial = :serial AND length(serial) >= 5 AND repair_complete_date < :submitted
                ORDER BY repair_complete_date DESC LIMIT 1""",
            {"serial": c["serial"], "submitted": c["submit_date"]},
        ) if c["serial"] and c["submit_date"] else []
        card["repeat_warning"] = (
            f"REPEAT RETURN: serial {c['serial']} had {prior[0]['n']} earlier repair(s); the last finished "
            f"{prior[0]['repair_complete_date']} (order {prior[0]['order_number']}), before this unit arrived."
            if prior else None
        )
    ev = sql(
        f"""SELECT predicted_top3, actual_causes, level_used, n, confidence, hit_at_1, hit_at_3, baseline_cause, baseline_hit
            FROM {GOLD}.eval_results WHERE order_number = :o AND line_number = :l""",
        {"o": order_number, "l": line_number},
    )
    return {
        "mode": "order",
        "raw": raw[0],
        "agent1": {**c, "causes": causes, "parts": parts, "areas": areas},
        "agent2": card,
        "agent3": {"eval": ev[0] if ev else None, "family": _family_insight(c["family"])},
    }


@app.post("/api/simulate/custom")
def simulate_custom(req: TriageRequest):
    if not req.catalog.strip():
        raise HTTPException(400, "Catalog number is required.")
    a1 = sql(
        f"""SELECT upper(trim(:catalog)) AS catalog,
                   {GOLD}.lookup_family(:catalog) AS family,
                   nullif({GOLD}.clean_failure_text(:failure_text), '') AS failure_text,
                   {GOLD}.classify_symptom({GOLD}.clean_failure_text(:failure_text)) AS symptom,
                   nullif(regexp_replace(upper(trim(coalesce(:serial, ''))), '^0+', ''), '') AS serial""",
        {"catalog": req.catalog, "serial": req.serial or "", "failure_text": req.failure_text or ""},
    )[0]
    a1["is_vague"] = a1["symptom"] is None
    card = triage(req)
    return {
        "mode": "custom",
        "raw": {"catalog": req.catalog, "serial_number": req.serial, "failure_details": req.failure_text},
        "agent1": a1,
        "agent2": card,
        "agent3": {"eval": None, "family": _family_insight(a1["family"])},
    }


# ---------- assistant (Agent Bricks / serving endpoint) ----------

class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage]


_endpoint_task: str | None = None


def _reply_text(result: dict) -> str:
    # Responses-style agents (Agent Bricks supervisor)
    texts = [
        part["text"]
        for item in result.get("output", [])
        if item.get("type") == "message"
        for part in item.get("content", [])
        if part.get("type") == "output_text"
    ]
    if texts:
        return texts[-1]
    # Chat-completions style (foundation models)
    if result.get("choices"):
        return result["choices"][0]["message"]["content"]
    if result.get("messages"):
        return result["messages"][-1].get("content", "")
    return str(result)


@app.post("/api/chat")
def chat(req: ChatRequest):
    global _endpoint_task
    endpoint = require(AGENT_ENDPOINT, "AGENT_ENDPOINT")
    if _endpoint_task is None:
        _endpoint_task = ws().serving_endpoints.get(endpoint).task or ""
    messages = [m.model_dump() for m in req.messages]
    body = {"input": messages} if "responses" in _endpoint_task else {"messages": messages}
    try:
        result = ws().api_client.do("POST", f"/serving-endpoints/{endpoint}/invocations", body=body)
    except Exception as e:
        raise HTTPException(502, f"Agent endpoint error: {e}")
    return {"reply": _reply_text(result)}


# ---------- static frontend ----------

DIST = Path(__file__).resolve().parent.parent / "frontend" / "dist"

if DIST.exists():
    app.mount("/assets", StaticFiles(directory=DIST / "assets"), name="assets")

    @app.get("/{path:path}")
    def spa(path: str):
        file = DIST / path
        if path and file.is_file():
            return FileResponse(file)
        return FileResponse(DIST / "index.html")
