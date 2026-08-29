# Architecture

## The shape of it

```
  ┌──────────────────────────────────────────────────────────────────┐
  │ LEAD SOURCES                                                     │
  │   OpenStreetMap / Overpass  (free, broad, weak on specialties)   │
  │   Google Places API (New)   (paid, precise, no email addresses)  │
  │   Clinic websites           (robots-respecting, ≤3 pages, the    │
  │                              only place emails are discovered)   │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │  n8n  (13 workflows)     │  orchestration only:
                    │  scheduling, API calls,  │  fetch a batch, call
                    │  routing, retries        │  something, write back
                    └────────────┬─────────────┘
                                 │  every decision that must hold
                                 │  under concurrency is ONE SQL call
                    ┌────────────▼─────────────┐
                    │  PostgreSQL — schema acq │  ◄── SOURCE OF TRUTH
                    │                          │
                    │  upsert_lead()      dedup + provenance
                    │  compute_score()    explainable scoring
                    │  claim_leads()      SKIP LOCKED work claiming
                    │  claim_send_slots() the single send choke point
                    │  transition_lead()  state machine
                    │  stop_follow_ups()  reply kill-switch
                    │  is_suppressed()    one suppression lookup
                    └──┬────────────┬──────────┬────────────┬─────────┘
                       │            │          │            │
          ┌────────────▼──┐  ┌──────▼─────┐ ┌──▼─────────┐ ┌▼──────────────┐
          │ Gemini Flash  │  │ SMTP       │ │ IMAP       │ │ Telegram      │
          │ structured    │  │ one real   │ │ replies +  │ │ hot leads,    │
          │ JSON only     │  │ mailbox    │ │ bounces    │ │ digest, alerts│
          └───────────────┘  └────────────┘ └────────────┘ └───────────────┘
                                                  │
                                          ┌───────▼────────┐
                                          │ Cal.com webhook│
                                          │ → DEMO_BOOKED  │
                                          └────────────────┘
                       ┌──────────────────────────┐
                       │ Next.js dashboard        │  reads views only,
                       │ (read-mostly, + approve) │  never raw tables
                       └──────────────────────────┘
```

## Who owns what

| Concern | Owner | Why not elsewhere |
|---|---|---|
| Scheduling, HTTP, routing, retries | n8n | What it is good at |
| Deduplication | Postgres | Needs one transaction across a unique index |
| Rate limits | Postgres | Overlapping n8n runs each think they have budget |
| Work claiming | Postgres | `FOR UPDATE SKIP LOCKED` has no n8n equivalent |
| State transitions | Postgres | The legal-transition table is data, not nodes |
| Suppression | Postgres | One lookup, consulted from four places |
| Scoring arithmetic | Postgres | Must be reproducible and re-tunable without AI spend |
| Judgement about a clinic | Gemini | Genuinely needs a model |
| Prose | Gemini | Genuinely needs a model |
| Whether prose is *allowed out* | Code guardrails | A model must not police itself |

The rule of thumb: **if it must still be true when two copies of the workflow
run at once, it belongs in SQL.**

## Pipeline state machine

Legal transitions live in `acq.status_transitions` and are enforced by
`acq.transition_lead()`, which refuses anything not listed.

```
   NEW ──► RESEARCHING ──► QUALIFIED ──► READY_FOR_REVIEW ──► APPROVED
                                │                                 │
                                └──────────────►──────────────────┘
                                                                  │
                            CONTACTED ◄───────────────────────────┘
                                │
                     FOLLOW_UP_1 ──► FOLLOW_UP_2 ──► FOLLOW_UP_3
                                │         │              │
                                └────►  REPLIED  ◄───────┘
                                          │
              ┌────────────┬──────────────┼──────────────┬─────────────┐
              ▼            ▼              ▼              ▼             ▼
        INTERESTED   NOT_INTERESTED     LATER        OPTED_OUT    DO_NOT_CONTACT
              │                           │
       DEMO_REQUESTED                (one bounded
              │                       revisit, 30d+)
        DEMO_BOOKED
              │
          CUSTOMER
```

Three rules the code enforces rather than documents:

1. **`OPTED_OUT`, `DO_NOT_CONTACT`, `INVALID` and `CUSTOMER` are terminal.**
2. **A suppressed lead can only move further from contact.** No actor — not even
   an explicit `HUMAN` — can walk an opt-out back through `transition_lead()`.
   Clearing `acq.leads.opt_out` is a separate, deliberate act.
3. **`OPTED_OUT`, `DO_NOT_CONTACT`, `INVALID` and `BOUNCED` are reachable from
   anywhere.** They only ever remove a lead from contact.

## Concurrency model

Every scheduled workflow assumes a previous run may still be going.

- **Claiming work** — `acq.claim_leads()` stamps `locked_by`/`locked_at` under
  `FOR UPDATE SKIP LOCKED`. Overlapping runs take disjoint sets. Locks older
  than 15 minutes are reclaimable; the nightly sweep clears anything over 2
  hours from an execution that died.
- **Claiming send slots** — `acq.claim_send_slots()` checks caps, claims rows
  and increments counters in one transaction. The `UPDATE … WHERE status =
  'READY_TO_SEND'` means a concurrent claimer loses harmlessly rather than
  double-sending.
- **Idempotency** — `acq.emails` is `UNIQUE (lead_id, campaign_id, step_no)`.
  Re-running personalization or the follow-up engine cannot produce a second
  email for the same step. `acq.replies.message_id` and
  `acq.notifications.dedupe_key` are unique for the same reason.
- **Discovery tasks** — `acq.next_discovery_tasks()` claims and reschedules in
  one statement, so two runs never process the same area.

## Failure handling

| Failure | Response |
|---|---|
| Gemini malformed JSON | One corrective retry showing the rejection; then `ok:false`, dead letter, no email |
| Gemini timeout / 5xx | Node-level retry ×3 with backoff, then as above |
| Places or Overpass down | Node retry, then the error workflow; tasks stay claimed and reschedule next cycle |
| SMTP failure | `record_email_failed()` returns it to `READY_TO_SEND` for 2 more attempts, then `FAILED` + dead letter |
| Hard bounce | Address suppressed, lead `BOUNCED` |
| Soft bounce | Recorded only — a `4.x.x` is temporary and must not suppress |
| Database down | Node retry ×3; the execution fails into the error workflow |
| Reply arrives mid-send | `is_sendable()` immediately before SMTP catches it |
| Guardrail rejection | Approval row + dead letter; never sent, never discarded |
| Lead stuck in a state | Nightly sweep un-sticks and releases locks |
| Unmatched inbound mail | Dead letter with the excerpt — never dropped |

Every workflow has *ACQ 00 — Error Handler* set as its error workflow, so
anything unhandled still produces an `acq.dead_letters` row.

## Autonomy boundary

Autonomous: discovery, dedup, research, scoring, drafting, sending within caps,
reply capture, classification, follow-up scheduling and cancellation, bounce and
opt-out handling, booking capture, daily reporting.

Escalated to you (section 21 of the brief), via `acq.approvals` + Telegram:

- AI confidence below threshold, for a draft or a classification
- Guardrail rejection
- Pricing, contract, legal or data-deletion questions
- Custom-integration requests
- Clinical or medical questions
- Complaints or hostility
- Wrong-person replies
- Conflicting lead data, or an email address the system is unsure about
- A qualified lead with no website to personalise from

While `outreach.auto_send_enabled` is `false`, **every** draft is escalated.
That is the intended starting state.
