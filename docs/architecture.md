# Repair Triage: app structure

How the whole product fits together: the web app, the API, the three data agents, the AI assistant,
the dashboard, and how everything is configured and deployed on Databricks.

For how the triage percentages themselves are calculated, see [triage-calculation.md](triage-calculation.md).

---

## 1. Big picture

```
                      ┌──────────────────────────── Databricks workspace ────────────────────────────┐
                      │                                                                               │
 Technician /         │   Databricks App: repair-triage-ui                                            │
 manager browser ───► │   ┌──────────────────────┐      SQL (parameterized)    ┌───────────────────┐  │
                      │   │ React UI (static)    │ ───► FastAPI /api/* ──────► │ SQL warehouse     │  │
                      │   │ 6 tabs               │                             │ Serverless Starter│  │
                      │   └──────────────────────┘      /api/chat              └─────────┬─────────┘  │
                      │                                    │                             │            │
                      │                                    ▼                             ▼            │
                      │                       Agent Bricks supervisor        Unity Catalog: ultraviolet│
                      │                       mas-65748dd7-endpoint          ├─ shpe.sap_… (raw SAP)  │
                      │                         └─ 3 Genie spaces ─────────► ├─ silver_real.*        │
                      │                                                      └─ gold_real.*          │
                      │                                                               ▲              │
                      │   Job: repair-triage-agents                                   │              │
                      │   agent1_extract ─► agent2_patterns ─► agent3_insights ───────┘              │
                      │                                                                               │
                      │   Lakeview dashboard (Technician + Manager views) ──reads──► gold_real.*      │
                      └───────────────────────────────────────────────────────────────────────────────┘
```

| Layer | What it is | Where it lives |
|---|---|---|
| **Data agents** | Three SQL stages that turn raw SAP repair lines into patterns, recommendations and accuracy scores | `pipeline/*.sql`, job `repair-triage-agents` |
| **Data** | Unity Catalog tables and functions | `ultraviolet.silver_real`, `ultraviolet.gold_real` |
| **API** | FastAPI backend that runs parameterized SQL and calls the AI assistant | `backend/main.py` |
| **UI** | React single-page app, served by the same FastAPI process | `frontend/` |
| **AI assistant** | Agent Bricks multi-agent supervisor routing to Genie spaces | `mas-65748dd7-endpoint` (configured in Databricks) |
| **Dashboard** | Lakeview dashboard built by script | `pipeline/dashboard.py` |
| **Deployment** | Databricks Asset Bundle: app + job | `databricks.yml`, `app.yaml` |

---

## 2. Repository layout

```
Hackthon/
├── app.py                    # Entrypoint: runs uvicorn on $DATABRICKS_APP_PORT (default 8000)
├── app.yaml                  # Databricks App runtime config: start command + env vars
├── databricks.yml            # Asset Bundle: the app, its resources, and the agents job
├── requirements.txt          # Python deps: fastapi, uvicorn, databricks-sdk
├── backend/
│   └── main.py               # All API routes + serves frontend/dist
├── frontend/
│   ├── index.html            # Page shell
│   ├── vite.config.js        # Dev server proxies /api → :8000
│   ├── package.json          # react, react-dom, react-markdown, vite
│   ├── dist/                 # Built UI (committed; deployed with the app)
│   └── src/
│       ├── main.jsx          # React bootstrap
│       ├── App.jsx           # Sidebar, tab registry, "not configured" states
│       ├── api.js            # fetch wrapper for /api/*
│       ├── index.css         # Design tokens (light/dark) + all component styles
│       └── views/            # One file per tab
│           ├── Triage.jsx        # Intake form + TriageCard (also reused by Simulator)
│           ├── Simulator.jsx     # Agent flow + step-through of one repair
│           ├── Chat.jsx          # Assistant chat (markdown replies)
│           ├── Patterns.jsx      # Causes / parts / areas by family
│           ├── Accuracy.jsx      # KPI tiles, accuracy by match level, case table
│           └── RepeatReturns.jsx # Serials repaired 2+ times
├── pipeline/
│   ├── agent1_extract.sql    # Agent 1: raw SAP → silver_real
│   ├── agent2_patterns.sql   # Agent 2: silver_real → patterns, recommendations, triage functions
│   ├── agent3_insights.sql   # Agent 3: evaluation + dashboard tables
│   ├── run.py                # Run the 3 agent files locally against the warehouse
│   └── dashboard.py          # Rebuild + publish the Lakeview dashboard
├── docs/
│   ├── architecture.md       # This file
│   └── triage-calculation.md # How the card's numbers are computed
└── presentation/index.html   # 5-minute pitch deck
```

---

## 3. The UI (`frontend/`)

A single-page React app (Vite build). `App.jsx` holds the tab registry. Each tab declares which backend
feature it needs (`data` = SQL warehouse, `chat` = assistant endpoint), and the tab shows a "Not configured"
hint instead of breaking if that feature's env var is missing.

| Tab | View file | Calls | Shows |
|---|---|---|---|
| 🔧 **Triage** | `Triage.jsx` | `GET /api/catalogs`, `POST /api/triage` | Intake form (catalog autocomplete, serial, complaint) → triage card: top 3 causes with %, parts to stage, areas to inspect, confidence, repeat-return warning |
| 🔁 **Simulator** | `Simulator.jsx` | `GET /api/agents`, `GET /api/simulate/samples`, `GET /api/simulate/{order}/{line}`, `POST /api/simulate/custom` | Agent pipeline with live handoff counts; step one real 2026 repair (or a typed-in unit) through raw report → Agent 1 → Agent 2 → Agent 3 |
| 💬 **Assistant** | `Chat.jsx` | `POST /api/chat` | Chat with the supervisor agent; starter questions; markdown answers |
| 🧩 **Patterns** | `Patterns.jsx` | `GET /api/patterns` | Family picker → root-cause shares, parts replaced, areas affected |
| 📊 **Accuracy** | `Accuracy.jsx` | `GET /api/accuracy` | Top-1 / top-3 / baseline tiles, accuracy by match level, latest 300 scored cases |
| ↩️ **Repeat Returns** | `RepeatReturns.jsx` | `GET /api/repeat-returns` | Searchable list of serials repaired 2+ times |

Styling: `index.css` defines color tokens on `:root` with a dark-mode override. The layout collapses to a
top nav bar and single column under 860px.

---

## 4. The API (`backend/main.py`)

FastAPI app, run by `app.py`. It authenticates with `WorkspaceClient()`: as the **app's service principal** when
deployed, or with your `~/.databrickscfg` profile locally. All SQL goes through one helper, `sql()`, which
uses **named parameters** (`:catalog`, `:serial`…), so user input is never concatenated into SQL.

| Method | Route | Reads | Returns |
|---|---|---|---|
| GET | `/api/config` | env vars | App title and which features are enabled |
| GET | `/api/catalogs` | `silver_real.repair_orders_clean` | Catalogs with ≥ 5 orders (max 2,000) + family, for autocomplete |
| POST | `/api/triage` | `gold_real.triage_card()` | Triage card: family, symptom, confidence, level, cases, repeat warning, top 3 causes with parts/areas |
| GET | `/api/patterns` | `gold_real.triage_patterns`, `parts_by_cause` | Family-level cause shares, parts and areas (families with ≥ 50 labeled cases) |
| GET | `/api/accuracy` | `gold_real.eval_results` | Summary rates, rates by match level, latest 300 cases |
| GET | `/api/repeat-returns` | `gold_real.repeat_returns` | Serials with ≥ 2 repairs, most recent first (max 1,000) |
| GET | `/api/agents` | `gold_real.agent_handoffs` | What each agent handed off in the latest job run |
| GET | `/api/simulate/samples` | `eval_results`, `repeat_returns` | 12 real 2026 repairs covering different outcomes (correct, missed, vague, repeat…) |
| GET | `/api/simulate/{order}/{line}` | silver + gold tables | Raw report (PO masked), Agent 1 record, Agent 2 card (repeat warning limited to repairs *before* this one), Agent 3 evaluation + family scorecard |
| POST | `/api/simulate/custom` | gold functions | Same stages for a typed-in unit (no evaluation, since there's no outcome yet) |
| POST | `/api/chat` | `mas-65748dd7-endpoint` | Assistant reply. Sends `input` for Responses-style agents, `messages` for chat models |
| GET | `/*` | `frontend/dist` | The React app (SPA fallback to `index.html`) |

---

## 5. Data layer (Unity Catalog `ultraviolet`)

| Schema | Owner | Contents |
|---|---|---|
| `shpe` | source | `sap_economy_repair_order_lines`: raw SAP repair lines (41,504 rows). **Only Agent 1 reads it.** |
| `silver_real` | this repo (Agent 1) | Structured order lines, causes, parts/areas |
| `gold_real` | this repo (Agents 2 & 3) | Patterns, recommendations, repeat returns, evaluation, dashboard tables, all functions |
| `silver`, `gold` | legacy | Early **mock** tables. Not used by the app, job, Genie spaces or dashboard. |

### Tables

| Table | Written by | Grain | Used by |
|---|---|---|---|
| `silver_real.repair_orders_clean` | Agent 1 | 1 row per order line (deduplicated) | everything downstream, catalogs, simulator |
| `silver_real.repair_cause` | Agent 1 | 1 row per line × confirmed cause | patterns, evaluation, simulator |
| `silver_real.repair_parts` | Agent 1 | 1 row per line × part type / affected area | parts_by_cause, repeat_returns, simulator |
| `gold_real.triage_patterns` | Agent 2 | level × group × cause → cases, total | triage card, Patterns tab, dashboard |
| `gold_real.triage_patterns_train` | Agent 2 | same, 2023–2025 only | evaluation |
| `gold_real.parts_by_cause` | Agent 2 | family × cause × part *or* area → count | triage card, Patterns tab |
| `gold_real.repeat_returns` | Agent 2 | 1 row per serial (latest completed repair) | repeat warning, Repeat Returns tab |
| `gold_real.recommendations` | Agent 2 | family × cause → parts, areas, action text | dashboard, Genie |
| `gold_real.eval_results` | Agent 3 | 1 row per labeled 2026 line | Accuracy tab, Simulator, dashboard |
| `gold_real.family_insights` | Agent 3 | 1 row per family (scorecard) | Simulator, dashboard |
| `gold_real.monthly_trends` | Agent 3 | month × family × cause | dashboard |
| `gold_real.agent_handoffs` | all agents | 1 row per agent output per run | Simulator |

### Functions (`gold_real`)

| Function | Purpose |
|---|---|
| `lookup_family(catalog)` | Catalog prefix → product family |
| `clean_failure_text(text)` | Strip serial/PO boilerplate, normalize the complaint |
| `is_vague_text(text)` | Detect "unknown / defective / no info" complaints |
| `has_repair_notes(text)` | Detect technician repair reports inside the complaint (leak guard) |
| `classify_symptom(clean_text)` | Rule-based symptom, or NULL when vague |
| `normalize_cause(raw)` | Map raw SAP cause codes to 14 categories |
| `triage(catalog, family, symptom)` | Top 3 causes with back-off + confidence |
| `triage_card(catalog, serial, failure_text)` | The full card: causes, parts, areas, confidence, repeat warning. **The Genie spaces depend on its name, signature and output columns, so keep them stable.** |

> `clean_failure_text`, `is_vague_text` and `normalize_cause` already exist in `gold_real` and the pipeline calls them,
> but no file in this repo creates them. The other five are (re)created by `agent1_extract.sql` / `agent2_patterns.sql`.
> On a fresh workspace, those three would need to be added to `agent1_extract.sql` first.

---

## 6. The three data agents (`pipeline/`)

They run in order as the Databricks job **repair-triage-agents** (about 45 s on the Serverless Starter warehouse).
Each agent reads only the previous agent's tables and appends to `gold_real.agent_handoffs`.

| Agent | File | Input | Output | Key steps |
|---|---|---|---|---|
| **1 · Extract** | `agent1_extract.sql` | raw SAP | `silver_real.*` | Drop service SKUs; dedupe repeated (order, line) keys; derive family, symptom, serial; clean complaint; flag repair notes; split + normalize causes; standardize parts (18 types) and areas; mask PO numbers in the raw text it keeps |
| **2 · Patterns** | `agent2_patterns.sql` | `silver_real.*` | `gold_real` patterns, parts, repeat returns, recommendations, `triage` / `triage_card` | Count causes at 4 levels; train-only copy for evaluation; lift-ranked parts/areas; plain-language recommendations |
| **3 · Insights** | `agent3_insights.sql` | Agent 2's tables | `eval_results`, `family_insights`, `monthly_trends` | Score every labeled 2026 line with 2023–2025 patterns; family scorecards (volume, top cause, no-problem-found %, repeats, cycle time, price) |

Run options:

```bash
databricks bundle run repair_triage_agents          # as a Databricks job (recommended)
.venv/bin/python pipeline/run.py                    # same SQL, from your laptop
.venv/bin/python pipeline/run.py --only agent2_patterns
```

---

## 7. AI assistant (Assistant tab)

```
/api/chat ──► mas-65748dd7-endpoint (Agent Bricks multi-agent supervisor)
                 ├── Genie: "Repair Triage Assistant (Agent 3)"    → gold_real / silver_real, calls triage_card
                 ├── Genie: "Depot Repair Triage Assistant"        → orders, status, cycle times, history
                 ├── Genie: "Lifecycle Services Failure Analysis"  → raw SAP table
                 └── system.ai.python_exec
```

The supervisor and the Genie spaces are configured in the Databricks UI, not in this repo. Their routing
instructions and table lists are maintained separately. The app only sends the conversation and shows the reply.

---

## 8. Dashboard

`pipeline/dashboard.py` rewrites and publishes the Lakeview dashboard **"Repair Triage - Technician and
Manager View (real data)"** (`01f1d3a19aa41dce8af01210b93e60f5`), keeping its theme.

| Page | Widgets |
|---|---|
| Technician View | Family + confidence filters · root causes bar · recommendations table · triage vs actual table · repeat returns |
| Manager View | Top-1 / Top-3 / Baseline / Eval-cases counters · accuracy by match level · monthly volume (top 6 families) · family scorecards |

---

## 9. Configuration

### `app.yaml` (runtime env for the app)

| Variable | Value | Purpose |
|---|---|---|
| `APP_TITLE` | `Repair Triage` | Sidebar title |
| `UC_CATALOG` | `ultraviolet` | Catalog for all queries |
| `SILVER_SCHEMA` / `GOLD_SCHEMA` | default `silver_real` / `gold_real` | Override to point the app at other schemas |
| `DATABRICKS_WAREHOUSE_ID` | from resource `sql-warehouse` | Enables all data tabs |
| `AGENT_ENDPOINT` | from resource `agent-endpoint` | Enables the Assistant tab |

### `databricks.yml` (Asset Bundle)

| Resource | Name | Details |
|---|---|---|
| App | `repair-triage-ui` | Source = repo root; resources: warehouse `6e4f969ac71d3b26` (CAN_USE), endpoint `mas-65748dd7-endpoint` (CAN_QUERY) |
| Job | `repair-triage-agents` | 3 SQL file tasks with `depends_on` chaining, on warehouse `6e4f969ac71d3b26` |
| Target | `dev` | Development mode (resources are prefixed with your user name) |

`sync.exclude` keeps `node_modules`, `frontend/src`, `.venv` and `__pycache__` out of the upload. Only the
built `frontend/dist` is deployed.

---

## 10. Security and permissions

- The deployed app runs as service principal **`app-372otf repair-triage-ui`**
  (`3bbe28b9-4419-4316-809e-be29afc4e452`) with:
  - `USE CATALOG` on `ultraviolet`
  - `USE SCHEMA, SELECT` on `silver_real`
  - `USE SCHEMA, SELECT, EXECUTE` on `gold_real`
  - no access to the raw `shpe` schema (Agent 1 keeps the needed report fields, with PO numbers masked)
- Users reach the app through Databricks login; only people granted access on the app can open it.
- All SQL from the browser is parameterized. The browser can't send its own SQL.
- Customer PII columns in the raw table (`additional_information`, `internal_status_details`) are never selected.

---

## 11. Local development and deploy

```bash
# one-time
databricks auth login --host https://dbc-45c9154d-c76b.cloud.databricks.com
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
(cd frontend && npm install)

# run locally (uses your own Databricks login)
export DATABRICKS_WAREHOUSE_ID=6e4f969ac71d3b26 AGENT_ENDPOINT=mas-65748dd7-endpoint
.venv/bin/python app.py                        # http://localhost:8000
(cd frontend && npm run dev)                   # http://localhost:5173 with hot reload

# deploy
(cd frontend && npm run build)
databricks bundle deploy
databricks bundle run repair_triage_agents     # rebuild data (when the pipeline changed)
databricks bundle run repair_triage_app        # restart the app on the new code
.venv/bin/python pipeline/dashboard.py         # when dashboard queries changed
```

Live app: https://repair-triage-ui-7474652709340945.aws.databricksapps.com

---

## 12. Common changes

| I want to… | Change |
|---|---|
| Add a tab | New file in `frontend/src/views/`, register it in `TABS` in `App.jsx`, add any route to `backend/main.py` |
| Add an API route | Add a function in `backend/main.py` using `sql()` with named parameters |
| Change how symptoms are detected | `classify_symptom` / `has_repair_notes` in `agent1_extract.sql`, then rerun the job |
| Change the back-off threshold or confidence rules | `triage` / `triage_card` in `agent2_patterns.sql` **and** the matching logic in `eval_results` (`agent3_insights.sql`) so the accuracy stays comparable |
| Add a dashboard chart | Add a dataset + widget in `pipeline/dashboard.py`, run it |
| Point the app at other tables | Set `SILVER_SCHEMA` / `GOLD_SCHEMA` in `app.yaml` and grant the service principal access |
