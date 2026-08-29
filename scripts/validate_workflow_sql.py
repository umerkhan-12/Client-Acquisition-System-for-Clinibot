#!/usr/bin/env python3
"""
Type-checks every SQL statement embedded in the n8n workflows against a real
database, by PREPAREing each one.

    python3 scripts/validate_workflow_sql.py | psql -v ON_ERROR_STOP=0 -d acq_test

A workflow that imports cleanly can still fail on its first run because of a
mistyped column name. PREPARE catches exactly that class of error without
executing anything or touching a row.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WF = ROOT / "n8n" / "workflows"

print("\\set ON_ERROR_STOP 0")
print("SET search_path = acq, public;")

count = 0
for path in sorted(WF.glob("*.json")):
    doc = json.loads(path.read_text())
    for node in doc["nodes"]:
        if node["type"] != "n8n-nodes-base.postgres":
            continue
        query = node["parameters"].get("query", "").strip()
        if not query:
            continue
        # Statements separated by ';' at the end of a line are prepared apart:
        # PREPARE takes exactly one statement.
        parts = [p.strip() for p in query.split(";\n") if p.strip()]
        for i, part in enumerate(parts):
            part = part.rstrip(";").strip()
            if not part:
                continue
            count += 1
            label = f"{path.stem} :: {node['name']}" + (f" [{i+1}]" if len(parts) > 1 else "")
            name = f"chk_{count}"
            print(f"\\echo '--- {label}'")
            print(f"PREPARE {name} AS\n{part};")
            print(f"DEALLOCATE {name};")

print(f"-- {count} statements checked", file=sys.stderr)
