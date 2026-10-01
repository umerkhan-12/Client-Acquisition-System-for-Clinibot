---
description: Run every check in the repo and report honestly what passed
---

Run the full verification suite. Report what actually happened — including
anything skipped and why. A skipped check reported as a pass is worse than a
failure, because it is trusted.

## The suite

```bash
./scripts/bootstrap.sh acq_test                  # migrations, prompts, 21 assertions, readiness
node scripts/test_code_nodes.mjs                 # 76 tests over the real Code-node JS
python3 n8n/build_workflows.py                   # rebuild + structural validation
python3 scripts/validate_workflow_sql.py | psql -d acq_test   # type-check all 73 statements
./scripts/check_deliverability.sh --self-test    # 19 self-tests
(cd dashboard && npx tsc --noEmit)
```

## On Windows

`bootstrap.sh` and `psql` need a Postgres. If there is none locally, use a
throwaway container — this is exactly how the suite was last verified:

```bash
export MSYS_NO_PATHCONV=1        # or Git Bash rewrites /paths into C:\paths
docker run -d --name acq-verify -e POSTGRES_PASSWORD=verify \
  -e POSTGRES_DB=acq_test -e POSTGRES_USER=acq postgres:16-alpine
docker cp db/migrations acq-verify:/mig
for f in db/migrations/*.sql; do
  docker exec acq-verify psql -v ON_ERROR_STOP=1 -U acq -d acq_test -q -f "/mig/$(basename $f)"
done
python scripts/load_prompts.py > prompts.sql   # writes UTF-8 explicitly; see below
docker cp prompts.sql acq-verify:/p.sql
docker exec acq-verify psql -v ON_ERROR_STOP=1 -U acq -d acq_test -q -f /p.sql
```

Tear it down with `docker rm -f acq-verify` when finished.

**`(cd dashboard && npx tsc --noEmit)` needs `npm install` first.** If
`dashboard/node_modules` is missing, either install or report the check as
skipped. Do not report it as passing.

## Interpreting failures

- **`invalid byte sequence for encoding "UTF8": 0x97`** — a generator wrote
  cp1252. `load_prompts.py`, `validate_workflow_sql.py` and
  `gen_workflow_docs.py` all pin their output to UTF-8 for this reason; if a
  new script emits SQL, it needs the same.
- **`UnicodeDecodeError: 'charmap' codec`** — a `read_text()`/`write_text()`
  without `encoding="utf-8"`.
- **A readiness `BLOCKER`** is not a test failure. It means configuration is
  missing, which is the expected state until deployment.

## Report

State the actual numbers — 11 migrations, 9 prompts, 21 assertions, 76 tests,
15 workflows / 217 nodes, 73 statements, 19 self-tests — and name anything
skipped. If everything passes, say so plainly without hedging.
