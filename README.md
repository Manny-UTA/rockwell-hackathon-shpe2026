# Repair Triage UI

A Databricks App with a **FastAPI** backend and a **React** (Vite) frontend for the depot repair-triage system.
It reads real-data tables in `ultraviolet.silver_real` / `ultraviolet.gold_real`, built from the SAP repair order lines by `pipeline/`.

| Tab | What it does | Backed by |
|---|---|---|
| Triage | Technician intake: catalog, serial and failure text give the top 3 causes, parts to stage, areas to inspect, and a repeat-return warning | UC function `gold_real.triage_card` |
| Assistant | Chat with the triage supervisor agent | Serving endpoint `mas-65748dd7-endpoint` |
| Simulator | Follow one real (or typed-in) repair through Agent 1 → 2 → 3, with the latest handoff counts | `gold_real.agent_handoffs`, silver + gold tables |
| Patterns | Root causes, parts and affected areas by product family | `gold_real.triage_patterns`, `gold_real.parts_by_cause` |
| Accuracy | Top-1 / top-3 vs baseline on 2026 repairs scored with 2023–2025 patterns, by match level | `gold_real.eval_results` |
| Repeat Returns | Serials repaired 2+ times | `gold_real.repeat_returns` |

## The three agents

Full app structure (UI, API, data, agents, assistant, dashboard, config, permissions): [docs/architecture.md](docs/architecture.md).
How every number on the triage card is calculated, with a worked example: [docs/triage-calculation.md](docs/triage-calculation.md).

| Agent | File | Reads | Writes |
|---|---|---|---|
| 1 · Extract | `pipeline/agent1_extract.sql` | `ultraviolet.shpe.sap_economy_repair_order_lines` (raw SAP) | `silver_real.repair_orders_clean`, `repair_cause`, `repair_parts`: deduplicated lines with family, symptom, cleaned complaint, normalized serial, causes, standardized parts and areas |
| 2 · Patterns | `pipeline/agent2_patterns.sql` | Agent 1's silver tables | `gold_real.triage_patterns(_train)`, `parts_by_cause`, `repeat_returns`, `recommendations`, plus functions `triage` and `triage_card` |
| 3 · Insights | `pipeline/agent3_insights.sql` | Agent 2's gold tables | `gold_real.eval_results` (2026 repairs scored with 2023–2025 patterns), `family_insights`, `monthly_trends` |

Each agent logs what it handed to the next one in `gold_real.agent_handoffs`, which the app's **Simulator** tab displays.
They run in order as the Databricks job **repair-triage-agents** (about 45 seconds):

```bash
databricks bundle run repair_triage_agents     # or locally: .venv/bin/python pipeline/run.py
.venv/bin/python pipeline/dashboard.py          # rebuild + publish the Lakeview dashboard (Technician + Manager views)
```

Notes:
- This repo owns `silver_real` / `gold_real`. Don't write to them from elsewhere. Genie spaces and the supervisor agent read them,
  so keep `triage_card`'s name, signature and output columns stable.
- About 5% of SAP `failure_details` contain the technician's repair report (post-repair findings). Agent 1 flags these
  (`has_repair_notes`) and leaves their symptom blank, so outcome text can't leak into triage or evaluation.
- The source has duplicate (order, line) keys. Agent 1 keeps one row per key.
- Symptoms are rule-based (`gold_real.classify_symptom`). Parts and areas are ranked by lift vs the family overall.

## Layout

```
app.py              # entrypoint (uvicorn on DATABRICKS_APP_PORT)
app.yaml            # Databricks App config: command + env vars/resources
requirements.txt
backend/main.py     # FastAPI routes under /api/*, serves frontend/dist
frontend/           # React app (src/views/*.jsx = one file per tab)
```

## Run locally

```bash
# 1. Authenticate to your workspace (once)
databricks auth login --host https://<your-workspace>.cloud.databricks.com

# 2. Backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
export DATABRICKS_WAREHOUSE_ID=6e4f969ac71d3b26 AGENT_ENDPOINT=mas-65748dd7-endpoint
.venv/bin/python app.py                # http://localhost:8000

# 3. Frontend with hot reload (proxies /api to :8000)
cd frontend && npm install && npm run dev   # http://localhost:5173
```

## Deploy as a Databricks App

```bash
cd frontend && npm run build && cd ..
databricks bundle deploy
databricks bundle run repair_triage_app
```

`databricks.yml` attaches the SQL warehouse and the agent endpoint to the app. The app's service principal also needs Unity Catalog access:

```sql
GRANT USE CATALOG ON CATALOG ultraviolet TO `<app-service-principal-id>`;
GRANT USE SCHEMA, SELECT ON SCHEMA ultraviolet.silver_real TO `<app-service-principal-id>`;
GRANT USE SCHEMA, SELECT, EXECUTE ON SCHEMA ultraviolet.gold_real TO `<app-service-principal-id>`;
```

## Customizing

- **Example units:** edit `EXAMPLES` in `frontend/src/views/Triage.jsx` and `STARTERS` in `frontend/src/views/Chat.jsx`.
- **Branding:** set `APP_TITLE` in `app.yaml` and edit colors at the top of `frontend/src/index.css`.
- **New API calls:** add a route in `backend/main.py` and call it with `api('/your-route')` from React.
