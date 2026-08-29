# Workflow reference

*Generated from `n8n/workflows/*.json` by `scripts/gen_workflow_docs.py`.*
*Edit `n8n/build_workflows.py` and regenerate rather than editing this file.*

Thirteen workflows: the ten stages the brief specifies, plus three pieces of
infrastructure they all depend on — the error handler (00), the shared AI-call
sub-workflow (01), and the unsubscribe webhook (110).

**Credential names** referenced below are what to call them when you create
them in n8n. No secret is stored in this repository; the ids in the JSON are
placeholders you replace once on import.

---

## Contents

- [ACQ 00 — Error Handler](#acq-00-error-handler) — `00_error_handler.json`
- [ACQ 01 — AI Call](#acq-01-ai-call) — `01_ai_call.json`
- [ACQ 10 — Lead Discovery](#acq-10-lead-discovery) — `10_lead_discovery.json`
- [ACQ 20 — Lead Qualification](#acq-20-lead-qualification) — `20_lead_qualification.json`
- [ACQ 30 — AI Research](#acq-30-ai-research) — `30_ai_research.json`
- [ACQ 40 — Personalization](#acq-40-personalization) — `40_personalization.json`
- [ACQ 50 — Outreach Send](#acq-50-outreach-send) — `50_outreach_send.json`
- [ACQ 60 — Inbox Monitor](#acq-60-inbox-monitor) — `60_inbox_monitor.json`
- [ACQ 70 — Reply Classification](#acq-70-reply-classification) — `70_reply_classification.json`
- [ACQ 80 — Follow-up Engine](#acq-80-follow-up-engine) — `80_followup_engine.json`
- [ACQ 90 — Hot Lead Notification](#acq-90-hot-lead-notification) — `90_hot_lead_notification.json`
- [ACQ 100 — Demo & CRM Pipeline](#acq-100-demo-&-crm-pipeline) — `100_demo_crm_pipeline.json`
- [ACQ 110 — Unsubscribe](#acq-110-unsubscribe) — `110_unsubscribe.json`

---

## ACQ 00 — Error Handler

**File** `n8n/workflows/00_error_handler.json` · **7 nodes**

Set this as the **Error Workflow** on every other workflow (Workflow settings → Error workflow). It is the reason section 24's "never silently lose a lead or an email event" holds: any execution that dies anywhere lands here.

It distinguishes transient failures (a dropped socket, a 429, a 503) from real ones. Both are recorded; only real ones send a Telegram alert, because an alert channel that cries wolf gets muted, and then it protects nothing.

**Trigger** — Error trigger ()

**Credentials** — `acq-postgres`, `acq-telegram`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | On Any Workflow Error | Error trigger |  |
| 2 | Shape Error | Code |  |
| 3 | Record Dead Letter | Postgres | `INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, error, pa` |
| 4 | Worth Waking Someone? | IF |  |
| 5 | Get Alert Target | Postgres | `SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegra` |
| 6 | Telegram Alert | Telegram |  |
| 7 | Transient — Logged Only | No-op |  |

**Database operations**

- **Record Dead Letter** — `INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, error, pa`<br>If this insert itself fails the execution is still visible in n8n's own log.
- **Get Alert Target** — `SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegra`

**Error handling** — retries on: `Record Dead Letter`, `Get Alert Target`, `Telegram Alert`. continues past failure at: `Telegram Alert`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 01 — AI Call

**File** `n8n/workflows/01_ai_call.json` · **15 nodes**

Every AI request in the system goes through here, which is what makes section 25's JSON contract enforceable in one place rather than five.

Gemini is called with `responseMimeType: application/json` and the prompt's own `responseSchema`, so malformed output is rare to begin with. When it happens anyway, the retry is *corrective*: it shows the model the exact rejection reason and drops temperature to 0, which fixes far more failures than asking the same question twice. After two attempts it returns `ok: false` — deliberately not an exception, because a failed research call and a failed email call mean different things to their callers.

Gemini's `responseSchema` only accepts a subset of JSON Schema, so unsupported keywords (`additionalProperties`, `maxLength`, `pattern`) are stripped from the schema before the call.

**Trigger** — Sub-workflow trigger ()

**Credentials** — `acq-postgres`, `gemini-api-key`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | When Called | Sub-workflow trigger |  |
| 2 | Load Prompt + Settings | Postgres | `SELECT acq.get_prompt($1) AS prompt,` |
| 3 | Build Request | Code |  |
| 4 | Gemini | HTTP | `POST =https://generativelanguage.googleapis.com/v1beta/models/…:generateCon` |
| 5 | Parse & Validate | Code |  |
| 6 | Valid? | IF |  |
| 7 | Build Retry Request | Code |  |
| 8 | Gemini Retry | HTTP | `POST =https://generativelanguage.googleapis.com/v1beta/models/…:generateCon` |
| 9 | Parse & Validate (Retry) | Code |  |
| 10 | Valid After Retry? | IF |  |
| 11 | Log AI Call | Postgres | `INSERT INTO acq.ai_calls (purpose, model, lead_id, prompt_version, input_token` |
| 12 | Log Failed AI Call | Postgres | `INSERT INTO acq.ai_calls (purpose, model, lead_id, prompt_version, ok, error, ` |
| 13 | Record AI Dead Letter | Postgres | `INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, lead_id, ` |
| 14 | Return Result | Code |  |
| 15 | Return Failure | Code |  |

**Database operations**

- **Load Prompt + Settings** — `SELECT acq.get_prompt($1) AS prompt,`
- **Log AI Call** — `INSERT INTO acq.ai_calls (purpose, model, lead_id, prompt_version, input_token`<br>Cost accounting must never block a successful result.
- **Log Failed AI Call** — `INSERT INTO acq.ai_calls (purpose, model, lead_id, prompt_version, ok, error, `
- **Record AI Dead Letter** — `INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, lead_id, `<br>Nothing is dropped: unrecoverable items land here for review.

**Error handling** — retries on: `Load Prompt + Settings`, `Gemini`, `Gemini Retry`, `Log AI Call`, `Log Failed AI Call`, `Record AI Dead Letter`. continues past failure at: `Log AI Call`, `Log Failed AI Call`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 10 — Lead Discovery

**File** `n8n/workflows/10_lead_discovery.json` · **18 nodes**

The ordering is the whole point. Text Search returns place IDs cheaply; **Place Details is the billed call**, and it runs only for businesses that survived `acq.filter_unknown_refs`. After the first pass most search results are already in the CRM, so this ordering is the difference between paying once per clinic and paying every month.

OSM needs no such split — one Overpass call returns full tags — so the OSM branch goes straight to `upsert_lead`. Overpass is a free volunteer service: one call per area, a four-second pause between areas, and an honest User-Agent are the terms of using it.

**Trigger** — Schedule trigger (cron `0 8 * * 1-5`)

**Credentials** — `acq-postgres`, `google-places-key`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | Every Weekday 08:00 | Schedule trigger | cron `0 8 * * 1-5` |
| 2 | Check Budget + Settings | Postgres | `SELECT` |
| 3 | Within Budget? | IF |  |
| 4 | Log Budget Halt | Postgres | `INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, finished_at` |
| 5 | Claim Discovery Tasks | Postgres | `SELECT id, city, area, query_term, category, provider, priority_tier, bbox,` |
| 6 | Per Task | Loop | batch size 1 |
| 7 | Route Provider | Switch | routes: `OSM`, `GOOGLE_PLACES`, `fallback` |
| 8 | Build Overpass Query | Code |  |
| 9 | Overpass API | HTTP | `GET https://overpass-api.de/api/interpreter` |
| 10 | Normalize OSM Results | Code |  |
| 11 | Places Text Search | HTTP | `POST https://places.googleapis.com/v1/places:searchText` |
| 12 | Collect Place IDs | Code |  |
| 13 | Drop Already-Known Places | Postgres | `SELECT ref` |
| 14 | Place Details (new only) | HTTP | `GET =https://places.googleapis.com/v1/places/…` |
| 15 | Normalize Place Details | Code |  |
| 16 | Upsert Lead | Postgres | `SELECT acq.upsert_lead($1::jsonb) AS result` |
| 17 | Pause Between Areas | Wait | 4 seconds |
| 18 | Record Run | Postgres | `INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, items_out, ` |

**Database operations**

- **Check Budget + Settings** — `SELECT`
- **Log Budget Halt** — `INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, finished_at`<br>Discovery stops rather than quietly overspending. Raise ai.daily_cost_cap_usd to resume.
- **Claim Discovery Tasks** — `SELECT id, city, area, query_term, category, provider, priority_tier, bbox,`<br>next_discovery_tasks() claims and reschedules atomically, so two overlapping runs never process the same area twice.
- **Drop Already-Known Places** — `SELECT ref`<br>THE cost lever. Place Details is billed per call; this removes every business already in the CRM before a single Details request is made.
- **Upsert Lead** — `SELECT acq.upsert_lead($1::jsonb) AS result`<br>One entry point for every source. Deduplication, provenance checking and contact recording all happen inside this call.
- **Record Run** — `INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, items_out, `

**Error handling** — retries on: `Check Budget + Settings`, `Log Budget Halt`, `Claim Discovery Tasks`, `Overpass API`, `Places Text Search`, `Drop Already-Known Places`, `Place Details (new only)`, `Upsert Lead`, `Record Run`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 20 — Lead Qualification

**File** `n8n/workflows/20_lead_qualification.json` · **7 nodes**

Zero AI calls, by design. This is section 19's "deterministic logic first": most leads are rejected here for reasons that need no model and no network request — no contact channel, a hospital, a pharmacy, a score below threshold.

A lead that qualifies but has no website goes to `READY_FOR_REVIEW` rather than forward. There is nothing public to write a specific email from, and the system will not send a generic one.

**Trigger** — Schedule trigger (cron `*/30 * * * *`)

**Credentials** — `acq-postgres`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | Every 30 Minutes | Schedule trigger | cron `*/30 * * * *` |
| 2 | Claim New Leads | Postgres | `SELECT id, clinic_name, website, city, area, phone, whatsapp, public_email,` |
| 3 | Deterministic Triage | Code |  |
| 4 | Score (Deterministic) | Postgres | `SELECT acq.compute_score($1::uuid, 'DETERMINISTIC') AS score` |
| 5 | Decide Next Status | Code |  |
| 6 | Apply Status | Postgres | `SELECT acq.transition_lead($1::uuid, $2::acq.lead_status, $3, 'SYSTEM', $4) AS` |
| 7 | Record Run | Postgres | `INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, items_out, ` |

**Database operations**

- **Claim New Leads** — `SELECT id, clinic_name, website, city, area, phone, whatsapp, public_email,`<br>FOR UPDATE SKIP LOCKED inside claim_leads means overlapping runs take disjoint work instead of colliding.
- **Score (Deterministic)** — `SELECT acq.compute_score($1::uuid, 'DETERMINISTIC') AS score`
- **Apply Status** — `SELECT acq.transition_lead($1::uuid, $2::acq.lead_status, $3, 'SYSTEM', $4) AS`
- **Record Run** — `INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, items_out, `

**Error handling** — retries on: `Claim New Leads`, `Score (Deterministic)`, `Apply Status`, `Record Run`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 30 — AI Research

**File** `n8n/workflows/30_ai_research.json` · **25 nodes**

The only workflow that reads clinic websites, and the only place a hallucination can enter the pipeline.

It fetches `robots.txt` first and honours `Disallow` for both `*` and its own agent; on any doubt it fetches nothing. It requests at most three specific pages (home, contact, about/services/team) — never a crawl — identifies itself honestly, and paces requests.

Email addresses found verbatim on a clinic's own page are recorded with **that page's URL as evidence**, which is what makes them facts rather than guesses. An address on the clinic's own domain is preferred, since a stray address on a clinic site is more often the web designer's.

Results cache for `ai.research_ttl_days` (90 by default), so no clinic is researched twice for free.

Research is followed by a separate **qualification pass** (`score_lead`). Extraction and judgement are deliberately different calls: a prompt asked to both find facts and decide whether to contact someone starts promoting its inferences to facts, because that makes the decision easier to justify. The qualification pass can only be more restrictive than research — it rejects on `recommend_contact: false` or any disqualifier, and sends a `WEAK` fit tier to human review — and if it fails, the research verdict stands with no signals patched.

**Trigger** — Schedule trigger (cron `0 6-14 * * 1-5`)

**Credentials** — `acq-postgres`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | Hourly (Business Hours) | Schedule trigger | cron `0 6-14 * * 1-5` |
| 2 | Claim Leads Needing Research | Postgres | `SELECT l.id, l.clinic_name, l.website, l.domain, l.city, l.area, l.category,` |
| 3 | Per Lead | Loop | batch size 1 |
| 4 | Plan Fetch | Code |  |
| 5 | Fetch robots.txt | HTTP | `GET =…` |
| 6 | Load Crawl Settings | Postgres | `SELECT (SELECT  value #>> '{}'       FROM acq.settings WHERE key = 'discovery.` |
| 7 | Apply robots.txt | Code |  |
| 8 | Any Pages Allowed? | IF |  |
| 9 | Expand Page URLs | Code |  |
| 10 | Fetch Page | HTTP | `GET =…` |
| 11 | Nothing Fetchable | No-op |  |
| 12 | Extract Text + Emails | Code |  |
| 13 | Build AI Input | Code |  |
| 14 | AI: Research Clinic | Call workflow | → ACQ 01 — AI Call |
| 15 | Handle Research Result | Code |  |
| 16 | Record Discovered Email | Postgres | `UPDATE acq.leads` |
| 17 | Save Research | Postgres | `WITH archived AS (` |
| 18 | Build Qualification Input | Code |  |
| 19 | AI: Qualify Lead | Call workflow | → ACQ 01 — AI Call |
| 20 | Merge Qualification | Code |  |
| 21 | Apply Qualification Signals | Postgres | `UPDATE acq.lead_research` |
| 22 | Score (Blended) | Postgres | `SELECT acq.compute_score($1::uuid, 'BLENDED') AS score` |
| 23 | Apply Status | Postgres | `SELECT acq.transition_lead($1::uuid, $2::acq.lead_status, $3, 'AI', $4) AS res` |
| 24 | Pace Requests | Wait | 3 seconds |
| 25 | Research Sweep Complete | No-op |  |

**Database operations**

- **Claim Leads Needing Research** — `SELECT l.id, l.clinic_name, l.website, l.domain, l.city, l.area, l.category,`
- **Load Crawl Settings** — `SELECT (SELECT  value #>> '{}'       FROM acq.settings WHERE key = 'discovery.`
- **Record Discovered Email** — `UPDATE acq.leads`
- **Save Research** — `WITH archived AS (`
- **Apply Qualification Signals** — `UPDATE acq.lead_research`
- **Score (Blended)** — `SELECT acq.compute_score($1::uuid, 'BLENDED') AS score`
- **Apply Status** — `SELECT acq.transition_lead($1::uuid, $2::acq.lead_status, $3, 'AI', $4) AS res`

**Error handling** — retries on: `Claim Leads Needing Research`, `Fetch robots.txt`, `Load Crawl Settings`, `Fetch Page`, `Record Discovered Email`, `Save Research`, `Apply Qualification Signals`, `Score (Blended)`, `Apply Status`. continues past failure at: `Fetch robots.txt`, `Fetch Page`, `Record Discovered Email`, `Apply Qualification Signals`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 40 — Personalization

**File** `n8n/workflows/40_personalization.json` · **21 nodes**

Two things stand between the model and a real clinic's inbox.

First a **free MX check** over Cloudflare DNS-over-HTTPS. A domain with no mail exchanger will hard-bounce, and hard bounces are the fastest way to wreck a young sending domain. A domain that fails is suppressed and the lead marked `INVALID`; a lookup that itself failed is treated as inconclusive rather than as evidence.

Then the **guardrails** — a deterministic pass the prompt cannot talk its way past: banned hype phrases, length bounds, the unsubscribe token, no price, no medical claim, no invented statistic, no fabricated prior contact, at most one link, and a configured postal address. A failing draft becomes a review item, never a discarded one.

**Trigger** — Schedule trigger (cron `*/20 * * * *`)

**Credentials** — `acq-postgres`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | Every 20 Minutes | Schedule trigger | cron `*/20 * * * *` |
| 2 | Load Settings | Postgres | `SELECT` |
| 3 | Claim Researched Leads | Postgres | `SELECT l.id, l.clinic_name, l.website, l.city, l.area, l.category, l.phone,` |
| 4 | Per Lead | Loop | batch size 1 |
| 5 | Check MX Records | HTTP | `GET =https://cloudflare-dns.com/dns-query?name=…&type=MX` |
| 6 | Evaluate MX | Code |  |
| 7 | Deliverable Domain? | IF |  |
| 8 | Suppress Undeliverable Domain | Postgres | `SELECT acq.apply_opt_out('DOMAIN', $1, 'NO_MX', 'MANUAL', $2::uuid, $3::jsonb)` |
| 9 | Build AI Input | Code |  |
| 10 | AI: Write Email | Call workflow | → ACQ 01 — AI Call |
| 11 | Guardrails | Code |  |
| 12 | Guardrails Passed? | IF |  |
| 13 | Queue Email | Postgres | `INSERT INTO acq.emails (` |
| 14 | Mark Lead Approved | Postgres | `SELECT acq.transition_lead($1::uuid,` |
| 15 | Needs Human Approval? | IF |  |
| 16 | Create Approval Request | Postgres | `INSERT INTO acq.approvals (kind, lead_id, email_id, title, payload, ai_confide` |
| 17 | Record Guardrail Failure | Postgres | `WITH a AS (` |
| 18 | Return Lead to Review | Postgres | `SELECT acq.transition_lead($1::uuid, 'READY_FOR_REVIEW', $2, 'SYSTEM', $3) AS ` |
| 19 | Awaiting Approval | No-op |  |
| 20 | Queued For Sending | No-op |  |
| 21 | Batch Complete | No-op |  |

**Database operations**

- **Load Settings** — `SELECT`<br>Campaign key is the one thing to change when you add a second market.
- **Claim Researched Leads** — `SELECT l.id, l.clinic_name, l.website, l.city, l.area, l.category, l.phone,`<br>Leads with no public email are never reached here — nothing invents one.
- **Suppress Undeliverable Domain** — `SELECT acq.apply_opt_out('DOMAIN', $1, 'NO_MX', 'MANUAL', $2::uuid, $3::jsonb)`
- **Queue Email** — `INSERT INTO acq.emails (`<br>ON CONFLICT DO NOTHING makes a re-run harmless: one email per lead per step.
- **Mark Lead Approved** — `SELECT acq.transition_lead($1::uuid,`
- **Create Approval Request** — `INSERT INTO acq.approvals (kind, lead_id, email_id, title, payload, ai_confide`
- **Record Guardrail Failure** — `WITH a AS (`<br>A rejected draft is never silently discarded — it becomes a review item.
- **Return Lead to Review** — `SELECT acq.transition_lead($1::uuid, 'READY_FOR_REVIEW', $2, 'SYSTEM', $3) AS `

**Error handling** — retries on: `Load Settings`, `Claim Researched Leads`, `Check MX Records`, `Suppress Undeliverable Domain`, `Queue Email`, `Mark Lead Approved`, `Create Approval Request`, `Record Guardrail Failure`, `Return Lead to Review`. continues past failure at: `Check MX Records`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 50 — Outreach Send

**File** `n8n/workflows/50_outreach_send.json` · **16 nodes**

The only workflow permitted to talk to SMTP. Initial emails and follow-ups both arrive as rows in `acq.emails`, so the daily cap applies to the operation as a whole rather than separately to each.

`acq.claim_send_slots()` applies every limit in one transaction — daily and hourly caps, the sending window, sending days, per-domain limits, the warm-up ramp and suppression. `acq.is_sendable()` runs again immediately before the SMTP call, catching a reply or opt-out that arrived in the seconds between.

Sends are spaced 40-160 seconds apart at random. A perfectly regular cadence looks like exactly what it is.

**Trigger** — Schedule trigger (cron `*/15 * * * *`)

**Credentials** — `acq-postgres`, `zenvexa-smtp`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | Every 15 Minutes | Schedule trigger | cron `*/15 * * * *` |
| 2 | Active Campaigns | Postgres | `SELECT c.id AS campaign_id, c.key, c.timezone,` |
| 3 | Claim Send Slots | Postgres | `SELECT e.id AS email_id, e.lead_id, e.to_email, e.subject, e.body_text,` |
| 4 | Per Email | Loop | batch size 1 |
| 5 | Final Pre-Send Check | Postgres | `SELECT acq.is_sendable($1::uuid) AS check` |
| 6 | Still Sendable? | IF |  |
| 7 | Render Final Email | Code |  |
| 8 | Dry Run? | IF |  |
| 9 | Send Email (SMTP) | SMTP send |  |
| 10 | Dry Run — Not Sent | Code |  |
| 11 | Record Sent | Postgres | `SELECT acq.record_email_sent($1::uuid, $2, $3) AS result` |
| 12 | Record Failure | Postgres | `SELECT acq.record_email_failed($1::uuid, $2, $3) AS result` |
| 13 | Cancel Unsendable | Postgres | `UPDATE acq.emails SET status = 'CANCELLED', error = $2` |
| 14 | Human Pacing Delay | Code |  |
| 15 | Wait (Jittered) | Wait | ={{ $json.wait_seconds }} seconds |
| 16 | Send Batch Complete | No-op |  |

**Database operations**

- **Active Campaigns** — `SELECT c.id AS campaign_id, c.key, c.timezone,`
- **Claim Send Slots** — `SELECT e.id AS email_id, e.lead_id, e.to_email, e.subject, e.body_text,`<br>Daily and hourly caps, the sending window, per-domain limits, the warm-up ramp and suppression are all applied inside this one transaction. Two overlapping runs cannot both think they have budget.
- **Final Pre-Send Check** — `SELECT acq.is_sendable($1::uuid) AS check`<br>Catches a reply or opt-out that landed in the seconds between claiming the slot and reaching the SMTP call.
- **Record Sent** — `SELECT acq.record_email_sent($1::uuid, $2, $3) AS result`<br>Also schedules the next follow-up and advances the lead's status.
- **Record Failure** — `SELECT acq.record_email_failed($1::uuid, $2, $3) AS result`<br>Returns the email to READY_TO_SEND for two more attempts, then marks it FAILED and writes a dead letter.
- **Cancel Unsendable** — `UPDATE acq.emails SET status = 'CANCELLED', error = $2`

**Error handling** — retries on: `Active Campaigns`, `Claim Send Slots`, `Final Pre-Send Check`, `Send Email (SMTP)`, `Record Sent`, `Record Failure`, `Cancel Unsendable`. continues past failure at: `Send Email (SMTP)`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 60 — Inbox Monitor

**File** `n8n/workflows/60_inbox_monitor.json` · **12 nodes**

Watches the outreach mailbox over IMAP — cheaper and more reliable at this volume than provider webhooks, and it sees replies *and* bounces on one connection.

Its most important property: **`acq.record_reply()` runs before classification is attempted.** Follow-ups stop the moment a human reply is recognised, whatever it says and whether or not Gemini is reachable. An AI outage can never cause someone who replied to keep receiving mail.

Bounces are separated into permanent (`5.x.x`, suppresses the address) and temporary (`4.x.x`, recorded only). Auto-replies are logged and the sequence continues — an out-of-office is not a reply. Mail that matches no lead still gets a durable record.

**Trigger** — IMAP trigger ()

**Credentials** — `acq-postgres`, `zenvexa-imap`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | New Mail (IMAP) | IMAP trigger |  |
| 2 | Triage Message | Code |  |
| 3 | Match To Lead | Postgres | `SELECT e.id AS email_id, e.lead_id, e.subject AS sent_subject,` |
| 4 | Merge Match | Code |  |
| 5 | Route Message | Switch | routes: `HUMAN_REPLY`, `BOUNCE`, `AUTO_REPLY`, `fallback` |
| 6 | Store Reply | Postgres | `INSERT INTO acq.replies (lead_id, email_id, message_id, in_reply_to, reference` |
| 7 | Stop Follow-Ups Immediately | Postgres | `SELECT acq.record_reply($1::uuid) AS result` |
| 8 | Classify Reply | Call workflow | → ACQ 70 — Reply Classification |
| 9 | Prepare Classification Input | Code |  |
| 10 | Record Bounce | Postgres | `SELECT acq.record_bounce(NULLIF($1,'')::uuid, $2::boolean, $3, $4) AS result` |
| 11 | Log Auto-Reply | Postgres | `INSERT INTO acq.replies (lead_id, email_id, message_id, from_email, from_name,` |
| 12 | Record Unmatched Mail | Postgres | `INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, error, pa` |

**Database operations**

- **Match To Lead** — `SELECT e.id AS email_id, e.lead_id, e.subject AS sent_subject,`
- **Store Reply** — `INSERT INTO acq.replies (lead_id, email_id, message_id, in_reply_to, reference`<br>ON CONFLICT on message_id makes redelivery from IMAP harmless.
- **Stop Follow-Ups Immediately** — `SELECT acq.record_reply($1::uuid) AS result`<br>Runs BEFORE classification on purpose. Whatever the reply says, and whether or not the AI is reachable, the sequence stops here.
- **Record Bounce** — `SELECT acq.record_bounce(NULLIF($1,'')::uuid, $2::boolean, $3, $4) AS result`<br>Only 5.x.x permanent failures suppress the address. A 4.x.x temporary failure is recorded and retried.
- **Log Auto-Reply** — `INSERT INTO acq.replies (lead_id, email_id, message_id, from_email, from_name,`<br>An out-of-office is not a reply: it is logged, and the sequence continues.
- **Record Unmatched Mail** — `INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, error, pa`<br>Mail from a stranger still gets a durable record — never dropped.

**Error handling** — retries on: `Match To Lead`, `Store Reply`, `Stop Follow-Ups Immediately`, `Record Bounce`, `Log Auto-Reply`, `Record Unmatched Mail`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 70 — Reply Classification

**File** `n8n/workflows/70_reply_classification.json` · **18 nodes**

Routes an inbound reply into one of five outcomes. Two safety rules override the model's own choice:

- If the classifier reports *any* opt-out signal, the class becomes `OPT_OUT` regardless of what it actually chose. A message that asks a question *and* asks to be removed has asked to be removed.
- Confidence below `ai.min_classification_confidence` forces human escalation.

An interested prospect who also asks something a human must answer is still routed as hot — the notification carries the open question rather than burying it in an approval queue.

**Trigger** — Sub-workflow trigger ()

**Credentials** — `acq-postgres`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | When Called | Sub-workflow trigger |  |
| 2 | Load Reply Context | Postgres | `SELECT r.id AS reply_id, r.body_text, r.subject AS reply_subject, r.from_email` |
| 3 | Build AI Input | Code |  |
| 4 | AI: Classify | Call workflow | → ACQ 01 — AI Call |
| 5 | Interpret Classification | Code |  |
| 6 | Save Classification | Postgres | `INSERT INTO acq.reply_classifications (` |
| 7 | Route Outcome | Switch | routes: `OPT_OUT`, `HOT`, `LATER`, `NEGATIVE`, `HUMAN`, `fallback` |
| 8 | Apply Opt-Out | Postgres | `SELECT acq.apply_opt_out('EMAIL',` |
| 9 | Notify Hot Lead | Call workflow | → ACQ 90 — Hot Lead Notification |
| 10 | Snooze Lead | Postgres | `WITH moved AS (` |
| 11 | Close Lead | Postgres | `SELECT acq.transition_lead($1::uuid, 'NOT_INTERESTED', $2, 'AI', $3) AS result` |
| 12 | Escalate To Human | Postgres | `INSERT INTO acq.approvals (kind, lead_id, reply_id, title, payload, ai_confide` |
| 13 | Notify (Needs Human) | Call workflow | → ACQ 90 — Hot Lead Notification |
| 14 | Auto-Reply — No Action | No-op |  |
| 15 | Prepare Notification Input | Code |  |
| 16 | Prepare Notification Input (Human) | Code |  |
| 17 | Notify Opt-Out | Call workflow | → ACQ 90 — Hot Lead Notification |
| 18 | Prepare Opt-Out Notice | Code |  |

**Database operations**

- **Load Reply Context** — `SELECT r.id AS reply_id, r.body_text, r.subject AS reply_subject, r.from_email`
- **Save Classification** — `INSERT INTO acq.reply_classifications (`
- **Apply Opt-Out** — `SELECT acq.apply_opt_out('EMAIL',`<br>apply_opt_out also moves the lead to OPTED_OUT and cancels everything queued. There is no path back into the pipeline afterwards.
- **Snooze Lead** — `WITH moved AS (`<br>One bounded revisit, at least 30 days out. Not a fourth follow-up.
- **Close Lead** — `SELECT acq.transition_lead($1::uuid, 'NOT_INTERESTED', $2, 'AI', $3) AS result`
- **Escalate To Human** — `INSERT INTO acq.approvals (kind, lead_id, reply_id, title, payload, ai_confide`

**Error handling** — retries on: `Load Reply Context`, `Save Classification`, `Apply Opt-Out`, `Snooze Lead`, `Close Lead`, `Escalate To Human`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 80 — Follow-up Engine

**File** `n8n/workflows/80_followup_engine.json` · **10 nodes**

Generates follow-ups; never sends them. It writes rows into `acq.emails` and workflow 50 does the sending, which is what keeps one choke point for all outbound mail.

`acq.due_follow_ups()` already excludes replied, opted-out, bounced and over-cap leads, so nothing here re-checks them. The guardrails are tuned for the specific ways follow-ups go wrong: filler openers ("just following up"), guilt ("I haven't heard back"), false urgency, and repeating the previous email. A draft that fails is **skipped**, not retried — the sequence simply ends a step early.

**Trigger** — Schedule trigger (cron `5 * * * *`)

**Credentials** — `acq-postgres`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | Hourly | Schedule trigger | cron `5 * * * *` |
| 2 | Due Follow-Ups | Postgres | `SELECT f.follow_up_id, f.lead_id, f.campaign_id, f.step_no, f.clinic_name, f.p` |
| 3 | Per Follow-Up | Loop | batch size 1 |
| 4 | Build AI Input | Code |  |
| 5 | AI: Write Follow-Up | Call workflow | → ACQ 01 — AI Call |
| 6 | Guardrails | Code |  |
| 7 | Follow-Up Usable? | IF |  |
| 8 | Queue Follow-Up Email | Postgres | `INSERT INTO acq.emails (lead_id, campaign_id, mailbox_id, step_no, to_email,` |
| 9 | Skip This Follow-Up | Postgres | `WITH s AS (` |
| 10 | Follow-Up Sweep Complete | No-op |  |

**Database operations**

- **Due Follow-Ups** — `SELECT f.follow_up_id, f.lead_id, f.campaign_id, f.step_no, f.clinic_name, f.p`<br>due_follow_ups() already excludes replied, opted-out, bounced and over-cap leads, so nothing here needs to re-check them.
- **Queue Follow-Up Email** — `INSERT INTO acq.emails (lead_id, campaign_id, mailbox_id, step_no, to_email,`
- **Skip This Follow-Up** — `WITH s AS (`<br>A bad follow-up is skipped, not retried into the prospect's inbox. The lead keeps its status and the sequence simply ends one step early.

**Error handling** — retries on: `Due Follow-Ups`, `Queue Follow-Up Email`, `Skip This Follow-Up`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 90 — Hot Lead Notification

**File** `n8n/workflows/90_hot_lead_notification.json` · **15 nodes**

Produces the notification you actually read on a phone. If the briefing model fails, it still notifies with the raw reply: a hot lead going unannounced because a summariser timed out is the worst failure available here.

A unique `dedupe_key` per (lead, reply) means a retried execution cannot notify twice.

Auto-reply requires four things at once: `outreach.auto_reply_enabled` on, the briefing judging the draft safe, a draft existing, and no open questions. It bypasses the send caps deliberately — replying to someone who wrote to you is not cold outreach.

**Trigger** — Sub-workflow trigger ()

**Credentials** — `acq-postgres`, `acq-telegram`, `zenvexa-smtp`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | When Called | Sub-workflow trigger |  |
| 2 | Load Lead Profile | Postgres | `SELECT acq.lead_profile($1::uuid) AS profile,` |
| 3 | Build AI Input | Code |  |
| 4 | AI: Brief Me | Call workflow | → ACQ 01 — AI Call |
| 5 | Format Notification | Code |  |
| 6 | Record Notification | Postgres | `INSERT INTO acq.notifications (channel, target, body, lead_id, dedupe_key, sta` |
| 7 | First Time For This Reply? | IF |  |
| 8 | Send Telegram | Telegram |  |
| 9 | Mark Notified | Postgres | `UPDATE acq.notifications SET status = 'SENT', sent_at = now()` |
| 10 | Notification Failed | Postgres | `WITH marked AS (` |
| 11 | Auto-Reply Allowed? | IF |  |
| 12 | Send Auto-Reply | SMTP send |  |
| 13 | Log Auto-Reply | Postgres | `INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payl` |
| 14 | Already Notified | No-op |  |
| 15 | Human Will Reply | No-op |  |

**Database operations**

- **Load Lead Profile** — `SELECT acq.lead_profile($1::uuid) AS profile,`
- **Record Notification** — `INSERT INTO acq.notifications (channel, target, body, lead_id, dedupe_key, sta`<br>The unique dedupe_key means a retried execution cannot notify twice for the same reply.
- **Mark Notified** — `UPDATE acq.notifications SET status = 'SENT', sent_at = now()`
- **Notification Failed** — `WITH marked AS (`<br>A hot lead that could not be announced is a dead letter, not a shrug.
- **Log Auto-Reply** — `INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payl`

**Error handling** — retries on: `Load Lead Profile`, `Record Notification`, `Send Telegram`, `Mark Notified`, `Notification Failed`, `Send Auto-Reply`, `Log Auto-Reply`. continues past failure at: `Send Telegram`, `Send Auto-Reply`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 100 — Demo & CRM Pipeline

**File** `n8n/workflows/100_demo_crm_pipeline.json` · **13 nodes**

Three independent paths in one workflow.

**Booking webhook** — accepts Cal.com and Calendly shapes, matches the invitee address to a lead, records the booking, moves the lead to `DEMO_BOOKED` and cancels remaining follow-ups. A booking from an address you never emailed is still recorded, with a null `lead_id`.

**Daily digest** at 18:00 — pipeline counts, spend, and deliverability, with explicit warnings when bounce rate exceeds 2% or complaint rate exceeds 0.1%.

**Nightly sweep** at 02:00 — releases locks held by executions that died, un-sticks leads stranded in `RESEARCHING`, and expires stale approvals.

**Trigger** — Webhook (`POST /demo-booked`), Schedule trigger (cron `0 18 * * 1-5`), Schedule trigger (cron `0 2 * * *`)

**Credentials** — `acq-postgres`, `acq-telegram`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | Booking Webhook | Webhook | `POST /demo-booked` |
| 2 | Parse Booking | Code |  |
| 3 | Record Booking | Postgres | `WITH matched AS (` |
| 4 | Announce Booking | Telegram |  |
| 5 | Load Notify Target | Postgres | `SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegra` |
| 6 | Daily Digest 18:00 | Schedule trigger | cron `0 18 * * 1-5` |
| 7 | Collect Metrics | Postgres | `SELECT` |
| 8 | Format Digest | Code |  |
| 9 | Send Digest | Telegram |  |
| 10 | Load Notify Target 2 | Postgres | `SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegra` |
| 11 | Nightly Sweep 02:00 | Schedule trigger | cron `0 2 * * *` |
| 12 | Release Stale Locks & Leads | Postgres | `WITH unlocked AS (` |
| 13 | Log Sweep | Postgres | `INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, finished_at` |

**Database operations**

- **Record Booking** — `WITH matched AS (`<br>Booking with an address we never emailed still gets recorded, with a null lead_id, rather than being discarded.
- **Load Notify Target** — `SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegra`
- **Collect Metrics** — `SELECT`
- **Load Notify Target 2** — `SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegra`
- **Release Stale Locks & Leads** — `WITH unlocked AS (`
- **Log Sweep** — `INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, finished_at`

**Error handling** — retries on: `Record Booking`, `Load Notify Target`, `Collect Metrics`, `Load Notify Target 2`, `Release Stale Locks & Leads`, `Log Sweep`. continues past failure at: `Announce Booking`, `Send Digest`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---

## ACQ 110 — Unsubscribe

**File** `n8n/workflows/110_unsubscribe.json` · **5 nodes**

Small, and the most important workflow for staying legitimate.

One click, no confirmation step, no login. Unsubscribing must be easier than replying or it is not a real opt-out. The token is a random 36-hex string on the email row, so the URL carries no personal data and cannot be guessed.

**Workflow 50 refuses to send anything while `unsubscribe.base_url` is unset.** An opt-out link that does not work is worse than none at all.

**Trigger** — Webhook (`GET /unsubscribe`)

**Credentials** — `acq-postgres`

| # | Node | Type | Detail |
|---|---|---|---|
| 1 | Unsubscribe Request | Webhook | `GET /unsubscribe` |
| 2 | Apply Opt-Out | Postgres | `WITH found AS (` |
| 3 | Build Confirmation Page | Code |  |
| 4 | Respond | Webhook response |  |
| 5 | Log Opt-Out | Postgres | `INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payl` |

**Database operations**

- **Apply Opt-Out** — `WITH found AS (`
- **Log Opt-Out** — `INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payl`

**Error handling** — retries on: `Apply Opt-Out`, `Log Opt-Out`. continues past failure at: `Log Opt-Out`. Unhandled failures go to *ACQ 00 — Error Handler*, which writes an `acq.dead_letters` row and alerts.

---
