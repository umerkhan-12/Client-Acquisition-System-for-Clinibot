#!/usr/bin/env bash
#
# Move the acquisition n8n (and a fresh WAHA) onto the Hetzner server.
#
#   ops/hetzner/deploy.sh root@46.225.181.214            # first move: carries n8n's state
#   ops/hetzner/deploy.sh root@46.225.181.214 --update   # later: files + restart only
#
# First move: stops the local n8n (and leaves it stopped, so no schedule runs
# in two places), snapshots its SQLite database — owner login, encrypted
# credentials, workflows with their IDs — and restores it on the server under
# the same N8N_ENCRYPTION_KEY. Secrets travel in a root-only .env; nothing is
# printed and nothing enters the repository.
set -euo pipefail

HOST="${1:?usage: deploy.sh user@host [--update]}"
MODE="${2:-}"
LOCAL=n8n-acq
DEST=/opt/acq
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
die()  { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
PY=""; for c in python3 python; do "$c" -c "import sqlite3" >/dev/null 2>&1 && { PY=$c; break; }; done
[ -n "$PY" ] || die "python with sqlite3 needed (the Windows Store alias does not count)"

envval() { sed -n "s/^$1=//p" "$root/.env" | tr -d '\r' | tail -1; }
[ -n "$(envval N8N_ENCRYPTION_KEY)" ] || die "N8N_ENCRYPTION_KEY missing from .env"
[ -n "$(envval WAHA_API_KEY)" ]       || die "WAHA_API_KEY missing from .env"

step "Stage files"
cp "$here/docker-compose.acq.yml" "$stage/docker-compose.yml"
cp "$root/ops/supabase-root-2021.crt" "$stage/"
mkdir -p "$stage/workflows" && cp "$root"/n8n/workflows/*.json "$stage/workflows/"
umask 077
{
  printf 'N8N_ENCRYPTION_KEY=%s\n'      "$(envval N8N_ENCRYPTION_KEY)"
  printf 'WAHA_API_KEY=%s\n'            "$(envval WAHA_API_KEY)"
  printf 'WAHA_DASHBOARD_PASSWORD=%s\n' "$(envval WAHA_DASHBOARD_PASSWORD)"
} > "$stage/.env"

if [ "$MODE" != "--update" ]; then
  step "Snapshot local n8n ($LOCAL) and leave it stopped"
  docker stop "$LOCAL" >/dev/null
  mkdir -p "$stage/seed"
  for f in database.sqlite database.sqlite-wal database.sqlite-shm; do
    docker cp "$LOCAL:/home/node/.n8n/$f" "$stage/seed/$f" 2>/dev/null || true
  done
  "$PY" - "$stage/seed" <<'PY'
import sqlite3, sys, os
d = sys.argv[1]
src = sqlite3.connect(os.path.join(d, "database.sqlite"))
dst = sqlite3.connect(os.path.join(d, "snapshot.sqlite"))
src.backup(dst)
print("    %d workflows, %d credentials" % (dst.execute("select count(*) from workflow_entity").fetchone()[0],
                                         dst.execute("select count(*) from credentials_entity").fetchone()[0]))
dst.execute("pragma journal_mode=delete"); dst.close(); src.close()
for f in ("database.sqlite", "database.sqlite-wal", "database.sqlite-shm"):
    if os.path.exists(os.path.join(d, f)): os.remove(os.path.join(d, f))
os.rename(os.path.join(d, "snapshot.sqlite"), os.path.join(d, "database.sqlite"))
PY
fi

step "Copy to $HOST:$DEST"
ssh -o BatchMode=yes "$HOST" "mkdir -p $DEST/n8n-data $DEST/waha-sessions"
# n8n runs as uid 1000 and must read the CA certificate and workflows; only
# .env is private. (A root-only /opt/acq made n8n skip the Supabase CA.)
tar -C "$stage" --owner=0 --group=0 -cf - . | ssh -o BatchMode=yes "$HOST"   "tar -C $DEST -xf - && chmod 755 $DEST && chmod 644 $DEST/supabase-root-2021.crt && chmod -R a+rX $DEST/workflows && chmod 600 $DEST/.env"

step "Start"
ssh -o BatchMode=yes "$HOST" "set -e; cd $DEST
  if [ -f seed/database.sqlite ]; then
    if [ -s n8n-data/database.sqlite ]; then echo '    server already has an n8n database; seed NOT applied'
    else cp seed/database.sqlite n8n-data/database.sqlite; echo '    n8n state restored from the snapshot'; fi
    rm -rf seed
  fi
  chown -R 1000:1000 n8n-data
  docker compose up -d --remove-orphans
  sleep 8; docker ps --filter name=acq- --format '    {{.Names}}  {{.Status}}'"

echo
echo "  n8n UI:  ssh -L 5679:127.0.0.1:5679 $HOST   then open http://localhost:5679"
