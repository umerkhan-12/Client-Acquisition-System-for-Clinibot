#!/usr/bin/env bash
# Drops and rebuilds a throwaway database from the migration sequence, then
# runs the smoke test. Verifies the migrations are a clean, ordered, re-runnable
# sequence rather than a set of files that only worked once.
set -euo pipefail
DB="${1:-acq_test}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL="psql -v ON_ERROR_STOP=1 -q"

echo "==> rebuilding $DB"
dropdb --if-exists "$DB"
createdb "$DB"

for f in "$ROOT"/db/migrations/*.sql; do
  echo "==> $(basename "$f")"
  $PSQL -d "$DB" -f "$f"
done

echo "==> re-applying migrations a second time (idempotency check)"
for f in "$ROOT"/db/migrations/*.sql; do
  $PSQL -d "$DB" -f "$f"
done

echo "==> smoke test"
psql -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/scripts/smoke_test.sql"
