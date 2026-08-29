# Database

PostgreSQL 14+. Everything lives in the `acq` schema and **nothing touches
Clinibot's tables**. Verified against PostgreSQL 16.13.

```bash
createdb zenvexa_acq
for f in db/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -d zenvexa_acq -f "$f"; done
python3 scripts/load_prompts.py | psql -v ON_ERROR_STOP=1 -d zenvexa_acq
psql -v ON_ERROR_STOP=1 -d zenvexa_acq -f scripts/smoke_test.sql   # asserts, then rolls back
```

Migrations are idempotent — re-running the whole sequence is a no-op, verified
by `scripts/rebuild_test_db.sh`.

## Where it should live

**Same Postgres server as Clinibot, separate database, separate role.** See
[the audit, finding 9](00-architecture-audit.md#9-do-not-put-sales-data-in-clinibots-database).
The schema is namespaced so it also works as a schema inside an existing
database, but a leaked n8n credential should not be able to reach patient data.

```sql
CREATE ROLE acq_app LOGIN PASSWORD '…';
CREATE DATABASE zenvexa_acq OWNER acq_app;
-- n8n connects as acq_app; it has no grant on any Clinibot object.
```

## Tables

**Configuration** — `settings`, `markets`, `scoring_configs`, `mailboxes`,
`campaigns`, `sequence_steps`, `discovery_tasks`, `prompts`, `status_transitions`

**Leads** — `leads`, `lead_identity_keys`, `lead_contacts`, `lead_research`,
`lead_scores`

**Outbound** — `emails`, `email_events`, `send_counters`, `follow_ups`

**Inbound** — `replies`, `reply_classifications`, `opt_outs`

**Human loop** — `approvals`, `sales_activities`, `notifications`,
`demo_bookings`

**Observability** — `ai_calls`, `workflow_runs`, `dead_letters`

## Claiming work

`acq.claim_leads()` is the generic claimer, used where every claimed lead is
usable (workflow 20). Workflows 30 and 40 use purpose-built claimers instead —
`claim_leads_for_research()` and `claim_leads_for_personalization()` — because
filtering *after* a generic claim locks leads the workflow cannot use.

Measured before this was fixed: asking for 15 leads of which 3 were researchable
returned 3 rows but left **15 locked**, 11 of them uselessly, for 15 minutes.
The next workflow, claiming the same `QUALIFIED` status, then found 5 leads
instead of 16. Running hourly and every twenty minutes, the two would have
starved each other indefinitely. Section 7 of the smoke test guards it.

## Is it ready to send?

```sql
SELECT * FROM acq.readiness();
```

Returns one row per check, severity `BLOCKER` / `WARN` / `OK` / `INFO`. A
`BLOCKER` is a condition the workflows themselves refuse to run past — not
advice. `scripts/bootstrap.sh` prints it as its last step.

## Four design decisions worth explaining

### Identity keys, not a pile of unique columns

`acq.lead_identity_keys` is `UNIQUE (key_type, key_value)`. A business claims a
row per identifier it has: `PLACE_ID`, `OSM_ID`, `DOMAIN`, `EMAIL`, `PHONE`,
`WHATSAPP`, and a guarded `NAME_CITY`.

`upsert_lead()` walks them strongest-first. The smoke test proves the case that
matters: the same clinic arriving from OSM (phone only), Google Places (phone in
international format, plus a website), and a directory (website plus email)
collapses to **one** lead, matching on `PHONE` then `DOMAIN`.

`NAME_CITY` is deliberately weak — it only applies when the normalised name
still has two meaningful tokens after stripping generic words, and it is
**ignored when the two records have conflicting domains**, because two different
clinics can share a generic name.

### Email provenance is a CHECK constraint

```sql
CONSTRAINT leads_email_must_have_provenance CHECK (
  public_email IS NULL
  OR (email_source IS NOT NULL AND email_evidence_url IS NOT NULL)
)
```

Section 6 of the brief says never guess an email address. A prompt instruction
would be a request. This makes it an invariant: there is no code path, present
or future, that can store an address without recording where it was read. The
smoke test asserts that a direct `UPDATE` attempting it is rejected.

`acq.contact_source` has no `GUESSED` member, so the type system agrees.

### One suppression table

`acq.opt_outs` covers opt-out requests, complaints, hard bounces, dead domains
and manual blocks, scoped to an email, a domain, a phone or a lead.
`acq.is_suppressed()` is the single lookup, consulted by `claim_send_slots()`,
`is_sendable()`, `due_follow_ups()` and the personalization claim query.

One table means there is no second list to forget to check.

### Rate limiting is accounted in the database

`acq.send_counters` is keyed `(mailbox_id, bucket_date, bucket_hour)`, with hour
`-1` as the daily rollup. `claim_send_slots()` reads, decides and increments in
one transaction. The smoke test asks for 10 emails against an hourly cap of 4,
twice, and asserts the counter never exceeds 4.

Counting happens at *claim* time, not send time. That is deliberately
conservative: a failed send consumes its slot rather than risking a burst.

## Configuration you will actually change

| Key | Default | Meaning |
|---|---|---|
| `outreach.auto_send_enabled` | `false` | Ships off. Every draft awaits approval. |
| `outreach.auto_reply_enabled` | `false` | Replies drafted, not sent. |
| `outreach.dry_run` | `false` | Everything except the SMTP call. |
| `limits.daily_send_limit` | `20` | Outer ceiling. |
| `ai.min_email_confidence` | `0.70` | Below this a draft goes to review. |
| `ai.daily_cost_cap_usd` | `2.00` | Discovery halts rather than overspend. |
| `ai.research_ttl_days` | `90` | Cache lifetime for research. |
| `company.postal_address` | `""` | **Blocks all sending until set.** |
| `unsubscribe.base_url` | `""` | **Blocks all sending until set.** |
| `product.capabilities` | full list | Claim whitelist. **Prune before sending.** |

Scoring weights live in `acq.scoring_configs`. Re-tuning is one `UPDATE` plus a
re-score from cached research — no new AI spend.

## Prisma

`db/prisma/schema.prisma` models the same schema for use from NestJS if you
later fold this into the Clinibot backend. It is `@@schema("acq")`-scoped and
**introspection-derived in shape** — the SQL migrations are authoritative.
Prisma does not model SQL functions, so `upsert_lead`, `claim_send_slots` and
friends stay `$queryRaw` calls. See the header comment in that file.
