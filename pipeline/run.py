"""Run the three agent SQL files in order on the SQL warehouse (same as the repair-triage-agents job).

Usage: .venv/bin/python pipeline/run.py [--warehouse <id>] [--only agent2_patterns]
"""

import argparse
import time
from pathlib import Path

from databricks.sdk import WorkspaceClient

parser = argparse.ArgumentParser()
parser.add_argument("--warehouse", default="6e4f969ac71d3b26")
parser.add_argument("--only", help="run a single agent file, e.g. agent2_patterns")
args = parser.parse_args()

w = WorkspaceClient()
AGENTS = ["agent1_extract", "agent2_patterns", "agent3_insights"]
statements = []
for name in [args.only] if args.only else AGENTS:
    sql = (Path(__file__).parent / f"{name}.sql").read_text()
    statements += [s.strip() for s in sql.split("\n;\n") if s.strip() and not all(
        line.startswith("--") or not line.strip() for line in s.strip().splitlines())]

for i, stmt in enumerate(statements, 1):
    head = next(l for l in stmt.splitlines() if l.strip() and not l.startswith("--"))
    print(f"[{i}/{len(statements)}] {head[:90]}", flush=True)
    t0 = time.time()
    r = w.statement_execution.execute_statement(warehouse_id=args.warehouse, statement=stmt, wait_timeout="50s")
    while r.status.state.value in ("PENDING", "RUNNING"):
        time.sleep(3)
        r = w.statement_execution.get_statement(r.statement_id)
    if r.status.state.value != "SUCCEEDED":
        raise SystemExit(f"  FAILED: {r.status.error.message if r.status.error else r.status.state}")
    print(f"  ok ({time.time() - t0:.0f}s)", flush=True)
print("done")
