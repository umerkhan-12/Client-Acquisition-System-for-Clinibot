#!/usr/bin/env bash
# One command from nothing to a verified, ready-to-configure database.
#
#   ./scripts/bootstrap.sh [database-name]        # default: zenvexa_acq
#
# Creates the database if needed, applies every migration in order, loads the
# prompts, runs the smoke test, and finishes by telling you exactly what is
# still blocking the first send.
#
# Safe to re-run: migrations are idempotent and the smoke test rolls back.
set -euo pipefail

DB="${1:-zenvexa_acq}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

command -v psql   >/dev/null || { bad "psql not found"; exit 2; }
command -v python3 >/dev/null || { bad "python3 not found"; exit 2; }

bold "Bootstrapping $DB"

step "1/5  Database"
if psql -lqt 2>/dev/null | cut -d\| -f1 | grep -qw "$DB"; then
  ok "$DB already exists"
else
  createdb "$DB"
  ok "created $DB"
fi

step "2/5  Migrations"
for f in "$ROOT"/db/migrations/*.sql; do
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
  ok "$(basename "$f")"
done

step "3/5  Prompts"
python3 "$ROOT/scripts/load_prompts.py" | psql -v ON_ERROR_STOP=1 -q -d "$DB"
N=$(psql -tAq -d "$DB" -c "SELECT count(*) FROM acq.prompts WHERE active;")
ok "$N active prompts loaded"

step "4/5  Smoke test"
if psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/scripts/smoke_test.sql" > /tmp/acq_smoke.$$ 2>&1; then
  grep -c 'PASS:' /tmp/acq_smoke.$$ | xargs -I{} echo "  $(printf '\033[32m✓\033[0m') {} assertions passed"
  rm -f /tmp/acq_smoke.$$
else
  bad "smoke test FAILED — do not proceed"
  tail -25 /tmp/acq_smoke.$$
  rm -f /tmp/acq_smoke.$$
  exit 1
fi

step "5/5  Readiness"
psql -q -d "$DB" -c "\
SELECT severity, check_name, left(detail, 72) AS detail \
FROM acq.readiness() ORDER BY \
  CASE severity WHEN 'BLOCKER' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END, \
  check_name;"

BLOCKERS=$(psql -tAq -d "$DB" -c "SELECT count(*) FROM acq.readiness() WHERE severity='BLOCKER';")

printf '\n'
if [ "$BLOCKERS" -gt 0 ]; then
  bold "Database is ready. $BLOCKERS setting(s) still block sending — by design."
  cat <<'NEXT'

  Set them when you are ready (docs/09-build-order.md, Phase 3):

    UPDATE acq.settings SET value = to_jsonb('Your real postal address'::text)
     WHERE key = 'company.postal_address';

    UPDATE acq.settings SET value = to_jsonb('https://n8n.you.tld/webhook/unsubscribe'::text)
     WHERE key = 'unsubscribe.base_url';

  And prune the claim whitelist before any real send — every line in it will
  be asserted to real clinics:

    SELECT jsonb_pretty(value) FROM acq.settings WHERE key = 'product.capabilities';

NEXT
else
  bold "No blockers. Re-read docs/06-deliverability.md before switching sending on."
fi

cat <<'NEXT'
  Next:
    ./scripts/check_deliverability.sh your-sending-domain.tld <dkim-selector>
    node scripts/test_code_nodes.mjs          # workflow logic
    docker compose up -d n8n                  # then import n8n/workflows/*.json
NEXT
