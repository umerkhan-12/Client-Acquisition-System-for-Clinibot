---
description: Where the acquisition system stands and what to do next
---

Report the current state of the acquisition system, concisely. Do not change anything.

1. Read `CLAUDE.md` for context if you have not already.
2. Find the database (default `zenvexa_acq`; ask if `psql -l` shows nothing obvious).
3. Run and summarise:
   - `SELECT * FROM acq.readiness();` — group by severity, lead with BLOCKERs
   - `SELECT * FROM acq.v_overview;`
   - `SELECT * FROM acq.v_funnel ORDER BY stage;`
   - `SELECT * FROM acq.v_deliverability;`
   - `SELECT count(*) FROM acq.dead_letters WHERE resolved_at IS NULL;`
4. Work out which phase of `docs/09-build-order.md` is actually complete, from the
   data rather than from what I claim.
5. Tell me: the phase I am in, the single most useful next action, and anything
   that looks wrong.

If the database does not exist yet, say so and tell me to run
`./scripts/bootstrap.sh zenvexa_acq`. Do not create it silently.
