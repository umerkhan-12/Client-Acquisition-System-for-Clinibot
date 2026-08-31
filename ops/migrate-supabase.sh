#!/usr/bin/env bash
#
# Apply the schema and prompts to Supabase.
#
#   ops/migrate-supabase.sh              # migrate + load prompts + readiness
#   ops/migrate-supabase.sh --dry-run    # show what would run, touch nothing
#
# Reads SUPABASE_ADMIN_URL from .env — the connection string for a role that
# may run DDL (Supabase's `postgres`). This is NOT the credential n8n or the
# dashboard use: migration 010 creates `acq_n8n` and `acq_dashboard` for them,
# and neither may run DDL.
#
# Idempotent. Every migration is written to be safely re-runnable, so this is
# the normal way to bring an existing database up to date, not just a
# first-time install.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '')        ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

[ -f .env ] || die ".env missing — cp .env.example .env and fill it in"
set -a; . ./.env; set +a

[ -n "${SUPABASE_ADMIN_URL:-}" ] || die "SUPABASE_ADMIN_URL not set in .env"
command -v psql >/dev/null 2>&1 || die "psql not installed"

# ---------------------------------------------------------------------
# Supabase installs extensions into the `extensions` schema rather than
# public. 001_schema_core.sql declares seven `citext` columns and a
# `gin_trgm_ops` index by bare name, so without `extensions` on the search
# path those fail with "type citext does not exist" — which reads like a
# missing extension when the extension is in fact installed and simply not
# visible.
# ---------------------------------------------------------------------
export PGOPTIONS="-c search_path=acq,public,extensions"

# Fail on the first error rather than continuing and reporting success at the
# end, and never wrap the whole run in one transaction: CREATE INDEX
# CONCURRENTLY and similar cannot run inside one.
PSQL=(psql "$SUPABASE_ADMIN_URL" -v ON_ERROR_STOP=1 --no-psqlrc -q)

step "Target"
if [ "$DRY" -eq 1 ]; then
  echo "    DRY RUN — nothing will be written"
fi
# Prove the credential works and say out loud which database is about to be
# changed. Running migrations against the wrong project is the mistake this
# line exists to prevent.
"${PSQL[@]}" -tAc "SELECT current_database() || ' as ' || current_user" \
  | sed 's/^/    /' || die "cannot connect with SUPABASE_ADMIN_URL"

step "Migrations"
for f in db/migrations/*.sql; do
  if [ "$DRY" -eq 1 ]; then
    echo "    would apply $(basename "$f")"
    continue
  fi
  printf '    %-32s' "$(basename "$f")"
  if "${PSQL[@]}" -f "$f" >/dev/null 2>/tmp/acq_mig_err; then
    echo "ok"
  else
    echo "FAILED"
    sed 's/^/      /' /tmp/acq_mig_err >&2
    die "migration $(basename "$f")"
  fi
done

step "Extensions"
# Reported after the migrations, because 001_schema_core.sql is what creates
# them. Worth printing: on Supabase these land in the `extensions` schema
# rather than public, which is why PGOPTIONS above puts it on the search path.
"${PSQL[@]}" -tAc \
  "SELECT extname || ' -> ' || n.nspname
     FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE extname IN ('pgcrypto','citext','pg_trgm') ORDER BY 1" \
  | sed 's/^/    /'

step "Prompts"
# load_prompts.py pins its stdout to UTF-8. Without that, on Windows the
# default code page emits byte 0x97 for an em dash and Postgres rejects the
# statement carrying it — inside a transaction that still reports success.
if [ "$DRY" -eq 1 ]; then
  python3 scripts/load_prompts.py >/dev/null || die "prompt generation"
  echo "    would load $(grep -c 'INSERT INTO acq.prompts' <(python3 scripts/load_prompts.py) || true) prompts"
else
  python3 scripts/load_prompts.py | "${PSQL[@]}" || die "prompt load"
  "${PSQL[@]}" -tAc "SELECT count(*) || ' prompts active' FROM acq.prompts WHERE active" \
    | sed 's/^/    /'
fi

[ "$DRY" -eq 1 ] && { echo; echo "  Dry run complete."; exit 0; }

step "Role passwords"
# Migration 010 creates acq_n8n and acq_dashboard without passwords, so that
# no credential is ever committed. Until somebody sets them, neither can
# connect — which is a confusing failure if you have forgotten this step.
"${PSQL[@]}" -tAc \
  "SELECT rolname || CASE WHEN rolpassword IS NULL THEN '  NO PASSWORD SET — run: ALTER ROLE ' || rolname || ' PASSWORD ''…'';' ELSE '  ok' END
     FROM pg_authid WHERE rolname IN ('acq_n8n','acq_dashboard') ORDER BY 1" \
  2>/dev/null | sed 's/^/    /' \
  || echo "    (cannot read pg_authid as this role — check passwords manually)"

step "Readiness"
"${PSQL[@]}" -c \
  "SELECT severity, check_name, left(detail, 76) AS detail
     FROM acq.readiness()
    WHERE severity IN ('BLOCKER','WARN')
    ORDER BY severity, check_name;"

cat <<'EOF'

  Schema is up to date.

  BLOCKER rows above are configuration, not breakage — nothing sends while
  they stand. Next: point n8n's `acq-postgres` credential at the SESSION
  pooler (:5432) as acq_n8n, and Vercel's ACQ_DATABASE_URL at the
  TRANSACTION pooler (:6543) as acq_dashboard.

  See docs/08-deployment.md.
EOF
