"""FastAPI backend for the Repair Triage Databricks App.

  /api/triage          - technician triage card (UC function ultraviolet.gold.triage_card)
  /api/catalogs        - known catalog numbers for the intake form
  /api/chat            - chat with the Agent Bricks supervisor endpoint
  /api/accuracy        - manager view: eval_results + summary KPIs
  /api/repeat-returns  - units that came back after a prior repair

Inside a Databricks App, WorkspaceClient() authenticates as the app's service
principal. Locally it uses your ~/.databrickscfg profile.
"""

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
        f"SELECT DISTINCT catalog, family FROM {CATALOG}.silver.repair_orders_clean "
        "WHERE catalog IS NOT NULL ORDER BY catalog"
    )}


@app.post("/api/triage")
def triage(req: TriageRequest):
    if not req.catalog.strip():
        raise HTTPException(400, "Catalog number is required.")
    rows = sql(
        f"SELECT * FROM {CATALOG}.gold.triage_card(:catalog, :serial, :failure_text) ORDER BY rnk",
        {
            "catalog": req.catalog.strip(),
            "serial": (req.serial or "").strip() or None,
            "failure_text": (req.failure_text or "").strip() or None,
        },
    )
    if not rows:
        return {"found": False}
    first = rows[0]
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
            }
            for r in rows
        ],
    }


# ---------- manager views ----------

@app.get("/api/accuracy")
def accuracy():
    rows = sql(
        f"""SELECT order_number, line_number, catalog, family, symptom, is_vague,
                   predicted_top3, actual_causes, level_used, n, confidence,
                   hit_at_1, hit_at_3, baseline_cause, baseline_hit
            FROM {CATALOG}.gold.eval_results ORDER BY order_number, line_number"""
    )
    n = len(rows)

    def rate(col):
        return round(sum(r[col] == "true" for r in rows) / n, 3) if n else None

    return {
        "summary": {"cases": n, "hit_at_1": rate("hit_at_1"), "hit_at_3": rate("hit_at_3"), "baseline": rate("baseline_hit")},
        "rows": rows,
    }


@app.get("/api/repeat-returns")
def repeat_returns():
    return {"rows": sql(f"SELECT * FROM {CATALOG}.gold.repeat_returns ORDER BY prior_repairs DESC, prior_repair_date DESC")}


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
