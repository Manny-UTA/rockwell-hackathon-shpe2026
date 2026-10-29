# Repair Triage UI

A Databricks App with a **FastAPI** backend and a **React** (Vite) frontend for the depot repair-triage system.

| Tab | What it does | Backed by |
|---|---|---|
| Triage | Technician intake: catalog, serial and failure text give the top 3 causes, parts to stage, areas to inspect, and a repeat-return warning | UC function `ultraviolet.gold.triage_card` |
| Assistant | Chat with the triage supervisor agent | Serving endpoint `mas-65748dd7-endpoint` |
| Accuracy | Manager view: top-1 and top-3 accuracy against the baseline, plus per-case results | `ultraviolet.gold.eval_results` |
| Repeat Returns | Units that came back after a prior repair | `ultraviolet.gold.repeat_returns` |

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
GRANT USE SCHEMA, SELECT ON SCHEMA ultraviolet.gold TO `<app-service-principal-id>`;
GRANT USE SCHEMA, SELECT ON SCHEMA ultraviolet.silver TO `<app-service-principal-id>`;
GRANT EXECUTE ON FUNCTION ultraviolet.gold.triage_card TO `<app-service-principal-id>`;
GRANT EXECUTE ON FUNCTION ultraviolet.gold.triage TO `<app-service-principal-id>`;
```

## Customizing

- **Example units:** edit `EXAMPLES` in `frontend/src/views/Triage.jsx` and `STARTERS` in `frontend/src/views/Chat.jsx`.
- **Branding:** set `APP_TITLE` in `app.yaml` and edit colors at the top of `frontend/src/index.css`.
- **New API calls:** add a route in `backend/main.py` and call it with `api('/your-route')` from React.
