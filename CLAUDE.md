# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

An n8n + PostgreSQL system that finds private clinics (Karachi first, geography
configurable), researches them from public sources, scores them, writes one
personal email per clinic, sends inside deliverability-safe limits, reads the
replies, and escalates to a human when someone is interested.

It is **standalone**. It does not touch the Clinibot product database. See
`docs/00-architecture-audit.md` before changing anything structural — it records
why the design is what it is.

## The one architectural rule

**Deterministic logic lives in SQL. n8n schedules and calls; it does not decide.**

n8n executions overlap and retry. Anything shaped like "count the rows, check
the limit, then act" breaks under that — two runs both read `sent_today = 18`,
both decide they have room for two more, and 22 emails leave against a cap of 20.

So deduplication, rate limiting, work claiming, scoring and state transitions
are each a single Postgres transaction (`db/migrations/00[2378]_*.sql`).
Workflows are thin: claim a batch, call something, write the result back.

When adding a feature, ask: *must this still be true when two copies of the
workflow run at once?* If yes, it belongs in SQL.

## Invariants — do not break these

These are enforced by the database, not by convention. If a change requires
weakening one, stop and raise it.

1. **An email address cannot be stored without the public page it was read
   from.** `CHECK (public_email IS NULL OR (email_source IS NOT NULL AND
   email_evidence_url IS NOT NULL))`. `acq.contact_source` deliberately has no
   `GUESSED` member.
2. **A suppressed lead can only move further from contact.**
   `acq.transition_lead()` refuses otherwise for *any* actor, including an
   explicit `HUMAN`. Clearing `acq.leads.opt_out` is a separate deliberate act.
3. **A reply stops everything before classification is attempted.**
   `acq.record_reply()` runs in workflow 60 ahead of the AI call, cancelling
   scheduled follow-ups *and* mail already queued, so an AI outage cannot cause
   someone who replied to keep receiving mail.
4. **All outbound mail goes through `acq.claim_send_slots()`.** It is the only
   path to SMTP. Never add a second send path — caps, sending window,
   per-domain limits, warm-up ramp and suppression are applied there in one
   transaction.
5. **Sending is refused while `company.postal_address` or
   `unsubscribe.base_url` is empty.** Both ship unset on purpose.

## Verify before you commit

```bash
./scripts/bootstrap.sh acq_test          # migrations, prompts, 12 assertions, readiness
node scripts/test_code_nodes.mjs         # 57 tests over the real Code-node JS
python3 n8n/build_workflows.py           # rebuild + structural validation
python3 scripts/validate_workflow_sql.py | psql -d acq_test   # type-check all 65 statements
./scripts/check_deliverability.sh --self-test                 # 19 self-tests
(cd dashboard && npx tsc --noEmit)
```

Occasionally, and after any change to the builder:

```bash
npm install n8n                                                  # ~2.7 GB, once
./scripts/validate_in_n8n.sh ./node_modules/.bin/n8n acq_test    # real import + execution
./scripts/check_n8n_env.sh ./node_modules/n8n                    # compose vars still exist?
```

The last two exist because they each found a bug nothing else could — see
"Traps" below.

## How to change things

| To change | Edit | Then |
|---|---|---|
| A workflow | `n8n/build_workflows.py` — **never** the JSON | `python3 n8n/build_workflows.py && python3 scripts/gen_workflow_docs.py` |
| A prompt | `prompts/*.md`, bump `version:` in frontmatter | `python3 scripts/load_prompts.py \| psql -d <db>` |
| Scoring weights | `acq.scoring_configs.weights` (a JSONB row) | re-score from cached research; costs no AI |
| Targeting, limits, geography | rows in `acq.settings` / `acq.markets` / `acq.discovery_tasks` | nothing — read at runtime |
| Schema | a **new** `db/migrations/00N_*.sql` | never edit an applied migration |

`docs/02-workflows.md` is generated. Don't hand-edit it.

## Traps

Each of these was a real bug, found late. They are easy to reintroduce.

- **Claim, then filter.** `acq.claim_leads()` locks every row it picks. Filtering
  afterwards in the outer query leaves unusable leads locked for 15 minutes and
  starves the next workflow. Use a purpose-built claimer with the predicate
  *inside* (`claim_leads_for_research`, `claim_leads_for_personalization`).
- **Two statements in one query.** The Postgres node runs a parameterised query
  as a single statement. Use a data-modifying CTE instead.
- **The two scoring phases have different gates.** `DETERMINISTIC` uses
  `qualify_deterministic` (20, permissive — "worth researching?"), `BLENDED`
  uses `qualify` (45, selective — "worth emailing?"). Sharing one threshold
  rejected every lead while reporting success.
- **n8n ignores unknown environment variables silently.** A removed variable
  makes the config *look* right and do nothing — this is how the compose file
  came to describe the UI as password-protected when it had no auth at all. Run
  `check_n8n_env.sh` after upgrading n8n.
- **Don't put `tags` in exported workflow JSON.** n8n creates tags during import
  and aborts on the second workflow sharing a tag name.
- **Every registered prompt must be reachable from a workflow.** The builder
  fails otherwise; a loaded-but-uncalled prompt reads as part of the pipeline
  and silently is not.

## Layout

```
db/migrations/   8 SQL migrations — the actual logic. Idempotent, ordered.
db/prisma/       Prisma models for the NestJS backend later. NOT a migration source.
n8n/             build_workflows.py -> workflows/*.json (13 workflows, 182 nodes)
prompts/         6 prompts, loaded into acq.prompts by scripts/load_prompts.py
dashboard/       Next.js admin view; reads 5 views, writes only the approval queue
scripts/         bootstrap, smoke test, SQL validator, code-node tests, deliverability
docs/            00 is the audit — read it first
```

## Conventions

- SQL: `$1` placeholders via `options.queryReplacement`, never string
  interpolation. Prefer one `jsonb` argument (`upsert_lead($1::jsonb)`).
- Node-level `retryOnFail` on HTTP and Postgres nodes; never on Code nodes.
- `alwaysOutputData` on claim queries so an empty batch still reaches the
  run-recording node.
- No secret in this repository. Workflow JSON carries placeholder credential
  ids (`REPLACE_PG`); real values live in n8n's encrypted store.
- Sending stays off by default: `outreach.auto_send_enabled` and
  `outreach.auto_reply_enabled` are both `false`.

## Current state

Branch `claude/n8n-clinic-acquisition-k0tb6s`. Built and verified; **not
deployed anywhere** — no container running, no DNS record, no email ever sent.

Verified: migrations, 12 behavioural assertions, 65 SQL statements type-checked,
57 Code-node tests, all 13 workflows importing into real n8n, one executed
against a real database, dashboard building and rendering live data.

Not verified: anything needing credentials (Google Places, Gemini, SMTP, IMAP),
and prompt output quality — that is Phase 2 and needs human judgement.

Next: `docs/09-build-order.md`. Phase 1 is discovery only, no AI and no email.
The number that matters is what share of discovered clinics publish a usable
email address; it decides whether the funnel supports 20 emails a day.
