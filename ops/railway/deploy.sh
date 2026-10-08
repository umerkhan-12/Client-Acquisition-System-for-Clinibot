#!/usr/bin/env bash
#
# Deploy n8n to Railway, carrying over the local n8n's state on first deploy.
#
#   railway login                     # once, yourself — opens a browser
#   ops/railway/deploy.sh             # first deploy: project, volume, domain, vars, seed
#   ops/railway/deploy.sh --no-seed   # later redeploys: image only, volume untouched
#
# The seed is a snapshot of the local container's database.sqlite: owner
# login, encrypted credentials, workflows with their IDs, published state. It
# is decrypted on Railway with the same N8N_ENCRYPTION_KEY, which this script
# pipes from the local container into Railway without printing it. The seed is
# staged in a temp directory and never written into the repository.
#
# After the Railway copy is verified, stop the local one (docker stop n8n-acq)
# so the schedules do not run twice. The SQL claimers make a double run safe,
# but it would still double the API calls.
set -euo pipefail

SERVICE=n8n
PROJECT_NAME=zenvexa-n8n
LOCAL=n8n-acq
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$here"

die()  { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

SEED=1
[ "${1:-}" = "--no-seed" ] && SEED=0

command -v railway >/dev/null || die "Railway CLI missing: npm i -g @railway/cli"
railway whoami >/dev/null 2>&1 || die "not logged in: run  railway login"
PY=$(command -v python3 || command -v python) || die "python needed to snapshot SQLite"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$here/Dockerfile" "$here/entrypoint.sh" "$root/ops/supabase-root-2021.crt" "$stage/"
mkdir -p "$stage/seed"

if [ "$SEED" = 1 ]; then
  step "Snapshot local n8n ($LOCAL)"
  docker inspect "$LOCAL" >/dev/null 2>&1 || die "container $LOCAL not found"
  # Stopped for a few seconds so the database and its WAL are consistent.
  docker stop "$LOCAL" >/dev/null
  for f in database.sqlite database.sqlite-wal database.sqlite-shm; do
    docker cp "$LOCAL:/home/node/.n8n/$f" "$stage/seed/$f" 2>/dev/null || true
  done
  docker start "$LOCAL" >/dev/null
  # Fold the WAL into one self-contained file.
  "$PY" - "$stage/seed" <<'PY'
import sqlite3, sys, os
d = sys.argv[1]
src = sqlite3.connect(os.path.join(d, "database.sqlite"))
dst = sqlite3.connect(os.path.join(d, "snapshot.sqlite"))
src.backup(dst)
n = dst.execute("select count(*) from workflow_entity").fetchone()[0]
c = dst.execute("select count(*) from credentials_entity").fetchone()[0]
dst.execute("pragma journal_mode=delete"); dst.close(); src.close()
for f in ("database.sqlite", "database.sqlite-wal", "database.sqlite-shm"):
    p = os.path.join(d, f)
    if os.path.exists(p): os.remove(p)
os.rename(os.path.join(d, "snapshot.sqlite"), os.path.join(d, "database.sqlite"))
print(f"    {n} workflows, {c} credentials")
PY
fi

if ! railway status >/dev/null 2>&1; then
  step "Create project $PROJECT_NAME"
  railway init --name "$PROJECT_NAME"
  railway add --service "$SERVICE"
  railway service link "$SERVICE"
  railway volume add --mount-path /data
  railway domain --service "$SERVICE" --port 5678
fi

domain="$(railway domain --service "$SERVICE" --json 2>/dev/null \
  | "$PY" -c 'import json,sys
d=json.load(sys.stdin)
d=d if isinstance(d,list) else d.get("domains", [d])
print(next((x.get("domain") or x.get("host") or "" for x in d), ""))' 2>/dev/null || true)"
[ -n "$domain" ] || die "could not read the service domain; run  railway domain --service $SERVICE --port 5678"
echo "    https://$domain"

step "Variables"
railway variable set --service "$SERVICE" --skip-deploys \
  RAILWAY_RUN_UID=0 \
  N8N_USER_FOLDER=/data \
  N8N_PORT=5678 PORT=5678 \
  N8N_HOST="$domain" N8N_PROTOCOL=https WEBHOOK_URL="https://$domain/" \
  N8N_PROXY_HOPS=1 N8N_SECURE_COOKIE=true \
  GENERIC_TIMEZONE=Asia/Karachi TZ=Asia/Karachi \
  NODE_EXTRA_CA_CERTS=/opt/certs/supabase-root-2021.crt \
  NODE_OPTIONS=--max-old-space-size=512 \
  DB_TYPE=sqlite \
  N8N_DIAGNOSTICS_ENABLED=false N8N_PERSONALIZATION_ENABLED=false \
  N8N_VERSION_NOTIFICATIONS_ENABLED=false N8N_HIRING_BANNER_ENABLED=false \
  N8N_TEMPLATES_ENABLED=false N8N_PUBLIC_API_DISABLED=true \
  N8N_BLOCK_ENV_ACCESS_IN_NODE=true N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true \
  N8N_RESTRICT_FILE_ACCESS_TO=/tmp N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true \
  N8N_PAYLOAD_SIZE_MAX=16 \
  EXECUTIONS_DATA_PRUNE=true EXECUTIONS_DATA_MAX_AGE=336 \
  EXECUTIONS_DATA_SAVE_ON_ERROR=all EXECUTIONS_DATA_SAVE_ON_SUCCESS=all \
  EXECUTIONS_DATA_SAVE_ON_PROGRESS=false >/dev/null

# The key that decrypts the credentials in the seed. Piped, never printed.
if docker inspect "$LOCAL" >/dev/null 2>&1; then
  docker inspect "$LOCAL" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n 's/^N8N_ENCRYPTION_KEY=//p' | tr -d '\r\n' \
    | railway variable set --service "$SERVICE" --skip-deploys --stdin N8N_ENCRYPTION_KEY >/dev/null
  echo "    N8N_ENCRYPTION_KEY copied from $LOCAL"
fi

step "Deploy"
railway up "$stage" --path-as-root --service "$SERVICE" --detach
echo
echo "  Building. Follow it with:  railway logs --service $SERVICE"
echo "  Then open https://$domain and sign in with your existing n8n login."
