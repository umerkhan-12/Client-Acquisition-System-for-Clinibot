# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

An n8n + PostgreSQL system that finds private clinics (Karachi first, geography
configurable), researches them from public sources, scores them, writes one
personal email per clinic, sends inside deliverability-safe limits, reads the
replies, and escalates to a human when someone is interested.

Since migration 011 every lead carries an `offer`. `CLINIBOT` is the pipeline
above. `WEB` sells websites to businesses that lack one: discovered by WEB
tasks or rerouted from website-less clinics, audited (workflow 25), drafted as
a WhatsApp message (45), and **sent by a person by hand** from the dashboard's
`/outreach` page. See `docs/13-website-prospects.md`.

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
   transaction. The WEB offer's `acq.manual_outreach` queue is not a send path:
   the system drafts, a person sends from their own phone. Keep it that way;
   automated WhatsApp from a personal number gets the number banned.
5. **Sending is refused while `company.postal_address` or
   `unsubscribe.base_url` is empty.** Both ship unset on purpose.

## Verify before you commit

```bash
./scripts/bootstrap.sh acq_test          # migrations, prompts, 21 assertions, readiness
node scripts/test_code_nodes.mjs         # 77 tests over the real Code-node JS
python3 n8n/build_workflows.py           # rebuild + structural validation
python3 scripts/validate_workflow_sql.py | psql -d acq_test   # type-check all 73 statements
./scripts/check_deliverability.sh --self-test                 # 19 self-tests
(cd dashboard && npx tsc --noEmit)       # deps installed; also: npx next build
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
  Every claimer filters on `offer` too: a WEB lead with a website is QUALIFIED
  with a website, which is exactly what workflow 30 looks for.
- **An empty claim is not empty.** `alwaysOutputData` makes n8n emit one
  blank item when a claim returns nothing, and a loop treats it as work —
  workflow 30 made a paid Gemini call for a blank clinic every idle hour.
  Put `nonempty_gate()` between any claim and its loop.
- **One active scoring config per offer, not overall.** `compute_score()`
  selects by `offer`. A query that reads "the" active config gets two rows.
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
- **An unpriced model silently disables the AI cost cap.** `01_ai_call` costs a
  call with `(ctx.pricing || {})[ctx.model] || {}`, so a model missing from
  `ai.pricing` costs $0.00 forever and `ai.daily_cost_cap_usd` can never trip.
  It bites specifically when copying Clinibot's pinned `GEMINI_MODEL`, which is
  not in the default table. `acq.readiness()` now BLOCKS on it (migration 009).
- **Python file I/O must name its encoding.** Every `read_text`/`write_text` and
  every script that pipes SQL to psql pins `utf-8` explicitly. Without it, on
  Windows the builder dies on its own em dashes and `load_prompts.py` emits
  byte `0x97`, which Postgres rejects as invalid UTF-8 — so a prompt fails to
  register inside a transaction that reports success.

## Layout

```
db/migrations/   11 SQL migrations — the actual logic. Idempotent, ordered.
db/prisma/       Prisma models for the NestJS backend later. NOT a migration source.
n8n/             build_workflows.py -> workflows/*.json (15 workflows, 217 nodes)
prompts/         7 files / 9 prompt keys, loaded by scripts/load_prompts.py
dashboard/       Next.js admin view on Vercel; magic-link auth + allowlist,
                 reads 5 views as acq_dashboard, writes only the approval queue
scripts/         bootstrap, smoke test, SQL validator, code-node tests, deliverability
ops/             migrate-supabase.sh, Caddyfile, docker-compose.n8n.yml
                 oracle/ = Always Free host; self-hosted/ = one-droplet fallback
.claude/commands/ /status /verify /deploy /phase1..5 /daily — operator entry points
docs/            00 is the audit — read it first; 12 is the go-to-market path;
                 13 is the WEB offer
```

## Conventions

- SQL: `$1` placeholders via `options.queryReplacement`, never string
  interpolation. Prefer one `jsonb` argument (`upsert_lead($1::jsonb)`).
- Node-level `retryOnFail` on HTTP and Postgres nodes; never on Code nodes.
- `alwaysOutputData` on claim queries so an empty batch still reaches the
  run-recording node.
- No secret in this repository. Workflow JSON carries placeholder credential
  ids (`REPLACE_PG`); real values live in n8n's encrypted store, and migration
  010 creates both database roles without passwords so none is ever committed.
- Least privilege at the database. `acq_n8n` runs the workflows; `acq_dashboard`
  reads five views and decides the approval queue, and cannot read `acq.leads`,
  `acq.opt_outs` or cached research. Neither may run DDL — only
  `SUPABASE_ADMIN_URL`, from a laptop, can.
- **Never add `acq` to Supabase's exposed-schema list.** PostgREST over scraped
  contact data, gated by RLS somebody has to get right every time, is how a
  Supabase project leaks. Keeping the schema off that list removes the class.
- Sending stays off by default: `outreach.auto_send_enabled` and
  `outreach.auto_reply_enabled` are both `false`.

## Operating it

`.claude/commands/` holds slash commands for each phase: `/status`, `/verify`,
`/phase1` through `/phase5`, `/daily`. They check their own preconditions and
stop rather than running ahead — `/phase3` will not send until the
deliverability checks pass and the unsubscribe link has been clicked.

`docs/12-getting-your-first-client.md` lists what only a human can do (domain,
mailbox, DNS, keys, and deciding what Clinibot actually does today) and the
funnel arithmetic behind the timeline.

## Current state

Branch `claude/n8n-clinic-acquisition-k0tb6s`. Built and verified; **not
deployed yet** — no email ever sent.

Target: Supabase (database) + an existing DigitalOcean n8n (workflows) +
Vercel (dashboard). `ops/self-hosted/` still holds the one-droplet stack as a
fallback. See `docs/08-deployment.md`.

Verified: 11 migrations on a clean database (and re-run idempotently), 9
prompts, 21 behavioural assertions, 73 SQL statements type-checked (0 errors),
77 Code-node tests, 15 workflows / 217 nodes, 19 deliverability self-tests,
dashboard `tsc` and `next build`.

Not verified: anything needing credentials (Google Places, Gemini, SMTP, IMAP),
prompt output quality — that is Phase 2 and needs human judgement — and the
`/outreach` page rendered against live data (it needs Supabase auth).

`product.capabilities` was rebuilt in migration 009 from the Clinibot source at
`../clinibot/clinibot-backend/src`, not from the brief. Three of the brief's
claims were wrong; the payment one materially so — Clinibot records a claimed
advance payment for staff to verify, and never processes money.

Next: `docs/09-build-order.md`. Phase 1 is discovery only, no AI and no email.
The number that matters is what share of discovered clinics publish a usable
email address; it decides whether the funnel supports 20 emails a day.
