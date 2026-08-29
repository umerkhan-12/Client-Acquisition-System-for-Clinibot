#!/usr/bin/env bash
# Imports the workflows into a real n8n and executes one against a real
# database, so the JSON is validated by n8n itself rather than by our own idea
# of what n8n accepts.
#
#   npm install n8n                                  # once, ~2.7 GB
#   ./scripts/validate_in_n8n.sh ./node_modules/.bin/n8n acq_test
#
# This is how two bugs were found that nothing else caught: a tag collision that
# aborted the import, and a scoring gate that rejected every lead.
set -euo pipefail

N8N_BIN="${1:-n8n}"
DB="${2:-acq_test}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v "$N8N_BIN" >/dev/null 2>&1 || [ -x "$N8N_BIN" ] || {
  echo "n8n not found at '$N8N_BIN'. Install it with: npm install n8n" >&2; exit 2; }

export N8N_USER_FOLDER="${N8N_USER_FOLDER:-$(mktemp -d)}"
export N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-validation-only-key}"
export DB_TYPE=sqlite
export N8N_DIAGNOSTICS_ENABLED=false
export GENERIC_TIMEZONE="${GENERIC_TIMEZONE:-Asia/Karachi}"

quiet() { grep -viE "migration|deprecat|Custom API|license SDK|task runner|Task Broker" || true; }

echo "==> importing all workflows into n8n ($N8N_USER_FOLDER)"
"$N8N_BIN" import:workflow --separate --input="$ROOT/n8n/workflows" 2>&1 | quiet | tail -3

echo "==> importing a Postgres credential matching the placeholder id"
CRED="$(mktemp)"
cat > "$CRED" <<JSON
[{ "id": "REPLACE_PG", "name": "acq-postgres", "type": "postgres",
   "data": { "host": "${PGHOST:-127.0.0.1}", "port": ${PGPORT:-5432},
             "database": "$DB", "user": "${PGUSER:-acq_app}",
             "password": "${PGPASSWORD:-devonly}", "ssl": "disable",
             "allowUnauthorizedCerts": false, "maxConnections": 5 } }]
JSON
"$N8N_BIN" import:credentials --input="$CRED" 2>&1 | quiet | tail -2
rm -f "$CRED"

# The CLI cannot start a workflow from a Schedule Trigger, so run a copy whose
# trigger is swapped. Every other node, query and expression is untouched.
echo "==> executing workflow 20 against $DB"
TMPDIR_WF="$(mktemp -d)"
python3 - "$ROOT" "$TMPDIR_WF" <<'PY'
import json, pathlib, sys
root, out = sys.argv[1], sys.argv[2]
d = json.loads((pathlib.Path(root) / "n8n/workflows/20_lead_qualification.json").read_text())
for n in d["nodes"]:
    if n["type"] == "n8n-nodes-base.scheduleTrigger":
        n["type"] = "n8n-nodes-base.executeWorkflowTrigger"
        n["typeVersion"] = 1.1
        n["parameters"] = {"inputSource": "passthrough"}
d["name"] = "VALIDATION RUN — ACQ 20"
d.pop("meta", None)
(pathlib.Path(out) / "wf20.json").write_text(json.dumps(d, indent=2))
PY
"$N8N_BIN" import:workflow --separate --input="$TMPDIR_WF" 2>&1 | quiet | tail -2
WF_ID="$("$N8N_BIN" list:workflow 2>/dev/null | grep 'VALIDATION RUN' | cut -d'|' -f1 | head -1)"
[ -n "$WF_ID" ] || { echo "could not find the validation workflow" >&2; exit 1; }

STATUS="$("$N8N_BIN" execute --id "$WF_ID" 2>&1 | grep -oE '"status": "[a-z]+"' | tail -1)"
rm -rf "$TMPDIR_WF"

echo "==> result: $STATUS"
case "$STATUS" in
  *success*) echo "n8n imported all workflows and executed one successfully." ;;
  *)         echo "FAILED: $STATUS" >&2; exit 1 ;;
esac
