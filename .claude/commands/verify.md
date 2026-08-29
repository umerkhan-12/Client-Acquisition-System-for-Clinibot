---
description: Run every check in the repo and report what passes
---

Run the full verification suite and report results as a table. Fix nothing yet —
report first, then ask me what to fix.

```bash
./scripts/bootstrap.sh acq_test                    # migrations, prompts, 12 assertions
node scripts/test_code_nodes.mjs                   # 57 tests over the Code-node JS
python3 n8n/build_workflows.py                     # rebuild + structural validation
python3 scripts/validate_workflow_sql.py | psql -d acq_test
./scripts/check_deliverability.sh --self-test
(cd dashboard && npm install --silent && npx tsc --noEmit)
```

If n8n is installed locally, also run:

```bash
./scripts/validate_in_n8n.sh ./node_modules/.bin/n8n acq_test
./scripts/check_n8n_env.sh ./node_modules/n8n
```

For each: pass/fail and the count. If anything fails, show the actual error, tell
me whether it is a real defect or an environment problem, and stop.
