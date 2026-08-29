# Client Acquisition System — Clinibot

An n8n + PostgreSQL system that finds private clinics, researches them from
public sources, scores them, writes a genuinely personal email to each, sends
within deliverability-safe limits, reads the replies, and gets out of the way
until someone says yes.

Built for **Zenvexa / Clinibot** — an AI WhatsApp receptionist for clinics —
starting with Karachi and configurable to any market.

> **Read [`docs/00-architecture-audit.md`](docs/00-architecture-audit.md) first.**
> It is the audit requested before implementation, and it explains why the
> system is shaped the way it is — including where it departs from the brief,
> and one thing you should not do.

---

## What it does

```
discover → deduplicate → qualify → research → score → draft → approve
   → send → monitor → classify → follow up (or stop) → notify → book
```

13 n8n workflows over one PostgreSQL schema. The workflows are deliberately
thin: deduplication, scoring, rate limiting and state transitions are single SQL
calls, because n8n executions overlap and retry, and an invariant expressed as
"count rows, then act" does not survive that.

## What is verified, and what is not

Everything in this repository was executed, not just written:

| | Status |
|---|---|
| SQL migrations | Applied to PostgreSQL 16.13, idempotent, rebuild clean from scratch |
| Dedup, scoring, rate limits, opt-out, state machine | **8 assertions in `scripts/smoke_test.sql`, all passing** |
| SQL inside the workflows | **All 65 statements `PREPARE`-checked against the live schema** |
| Workflow JSON | Structurally validated — no duplicate names, no dangling connections, no unreachable nodes |
| Prompt loader | Round-trips all 8 registrations through `acq.get_prompt()` |
| Deliverability checker | **21 self-tests over SPF/DKIM/DMARC/MX evaluation, all passing** |
| Dashboard | Typechecks, builds, and renders live data over a least-privilege role |
| `docker-compose.yml` | `docker compose config` valid, required-variable guards fire |
| **The workflows running end to end in n8n** | **Not verified** — needs your credentials and a live n8n |
| **Gemini prompt output quality** | **Not verified** — that is Phase 2's job, and it needs your judgement |

Two real bugs were caught by that verification and fixed: a two-statement query
the Postgres driver cannot execute, and a state-machine hole that let an
opted-out lead be moved back toward contact.

## Quickstart

```bash
# 1. database
createdb zenvexa_acq
for f in db/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -d zenvexa_acq -f "$f"; done
python3 scripts/load_prompts.py | psql -v ON_ERROR_STOP=1 -d zenvexa_acq

# 2. prove it works before trusting it (asserts, then rolls back)
psql -v ON_ERROR_STOP=1 -d zenvexa_acq -f scripts/smoke_test.sql

# 3. check the sending domain BEFORE any of this touches a real clinic
./scripts/check_deliverability.sh your-sending-domain.tld <dkim-selector>

# 4. n8n
cp .env.example .env      # fill it in
docker compose up -d n8n
# then import n8n/workflows/*.json — see n8n/README.md
```

Then follow [`docs/09-build-order.md`](docs/09-build-order.md). **Do not
activate all 13 workflows at once.** Nothing reaches a real clinic before
Phase 3.

## Layout

```
db/migrations/     6 SQL migrations — the actual logic lives here
db/prisma/         Prisma models, for the NestJS backend later
n8n/               build_workflows.py → workflows/*.json (13 workflows)
prompts/           6 production prompts, loaded into the database
dashboard/         Next.js admin view + approval queue
scripts/           smoke test, prompt loader, SQL validator, deliverability check
docs/              audit, architecture, workflows, costs, deployment, compliance
```

## Documentation

| | |
|---|---|
| [00 — Architecture audit](docs/00-architecture-audit.md) | **Start here.** Ten findings, the cheapest reliable approach, what not to build |
| [01 — Architecture](docs/01-architecture.md) | Data flow, state machine, concurrency, failure handling |
| [02 — Workflow reference](docs/02-workflows.md) | All 13 workflows, node by node *(generated from the JSON)* |
| [03 — Database](docs/03-database.md) | Schema, the four design decisions, configuration |
| [04 — Integrations](docs/04-integrations.md) | Which APIs, why, and which to avoid |
| [05 — Prompts](docs/05-prompts.md) | The six prompts and the JSON contract |
| [06 — Deliverability](docs/06-deliverability.md) | SPF, DKIM, DMARC, warm-up, bounces, unsubscribe |
| [07 — Cost](docs/07-costs.md) | $0 dev, and 100 / 500 / 1,000 / 5,000 leads a month |
| [08 — Deployment](docs/08-deployment.md) | Where this should run, and why not inside Clinibot's n8n |
| [09 — Build order](docs/09-build-order.md) | Six phases, minimum viable system first |
| [10 — Compliance](docs/10-compliance.md) | Per-market consent, deletion, AI disclosure |
| [11 — Runbook](docs/11-runbook.md) | Daily checks and what to do when something breaks |

## The rules, and how they are enforced

The brief's hard constraints are enforced by construction, not by intent —
intent does not survive a refactor:

- **Never guess an email address.** A `CHECK` constraint refuses any address
  without a citable source URL, and `acq.contact_source` has no `GUESSED`
  member. The smoke test proves a direct `UPDATE` attempting it is rejected.
- **Never contact someone who opted out.** One suppression table, consulted in
  four places. `transition_lead()` refuses to move a suppressed lead toward
  contact for *any* actor, including an explicit `HUMAN`.
- **A reply stops everything.** `record_reply()` runs before classification is
  attempted, cancelling scheduled follow-ups *and* mail already sitting in the
  queue — so an AI outage cannot cause someone who replied to keep getting mail.
- **Limits cannot be exceeded.** One transaction claims slots and increments
  counters. Verified by asking for 10 sends against an hourly cap of 4, twice.
- **Quality over quantity.** `outreach.auto_send_enabled` ships `false`. Every
  draft waits for you until you decide otherwise.

## Three things blocking your first send

By design — the system refuses rather than send something non-compliant:

1. **`company.postal_address` is empty.** Most anti-spam regimes require a real
   postal address in commercial email. Workflow 50 throws until it is set.
2. **`unsubscribe.base_url` is empty.** Deploy workflow 110, set its public URL,
   and click the link once to verify it works.
3. **`product.capabilities` lists everything from the brief**, including the
   three described as only "potentially" available. Every line will be asserted
   to real clinics — prune it. `product.capabilities_unverified` flags which
   three to check.

## One thing not to do

**Do not run cold outreach on WhatsApp from any account connected to Clinibot.**
Most Karachi clinics have WhatsApp and no email, so it is the obvious way to
close the gap — and it violates the WhatsApp Business Messaging Policy, with
account-level enforcement. The product *is* a WhatsApp receptionist. The
downside is not a lost sales channel; it is the product.

[The reasoning in full.](docs/00-architecture-audit.md#4-do-not-cold-message-clinics-on-whatsapp-and-especially-not-from-clinibots-waba)
