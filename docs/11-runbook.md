# Runbook

## Daily — two minutes

The 18:00 Telegram digest is designed so that nothing else is needed on a normal
day. It warns explicitly when bounce rate exceeds 2%, complaint rate exceeds
0.1%, dead letters are open, or approvals are waiting.

If you would rather look yourself:

```sql
SELECT * FROM acq.v_overview;
SELECT * FROM acq.v_deliverability;
SELECT * FROM acq.v_approval_queue LIMIT 20;
```

## Weekly — fifteen minutes

```sql
-- Is the funnel converting, or just moving?
SELECT * FROM acq.v_funnel ORDER BY stage;

-- Read replies yourself for the first month. The classifier is good; you are
-- checking it against reality, especially on anything near an opt-out.
SELECT r.received_at, l.clinic_name, rc.class, rc.confidence,
       left(r.body_text, 240) AS excerpt
FROM acq.replies r
JOIN acq.leads l ON l.id = r.lead_id
LEFT JOIN acq.reply_classifications rc ON rc.reply_id = r.id
WHERE r.received_at > now() - interval '7 days' AND NOT r.is_auto_reply
ORDER BY r.received_at DESC;

-- Spend
SELECT purpose, count(*), round(sum(cost_usd)::numeric, 4) AS usd
FROM acq.ai_calls WHERE created_at > now() - interval '7 days'
GROUP BY 1 ORDER BY 3 DESC;

-- Anything unresolved
SELECT workflow_key, node_name, left(error, 120), count(*)
FROM acq.dead_letters WHERE resolved_at IS NULL
GROUP BY 1,2,3 ORDER BY 4 DESC;
```

---

## Incidents

### Bounce rate above 2%

**Stop sending first, diagnose second.**

```sql
UPDATE acq.campaigns SET status = 'PAUSED' WHERE key = 'pk-karachi-tier1';

SELECT split_part(e.to_email::text, '@', 2) AS domain, count(*),
       left(ev.detail, 100)
FROM acq.email_events ev JOIN acq.emails e ON e.id = ev.email_id
WHERE ev.event = 'HARD_BOUNCE' AND ev.occurred_at > now() - interval '7 days'
GROUP BY 1, 3 ORDER BY 2 DESC;
```

Usual causes, in order of likelihood: addresses scraped from stale directory
pages; a catch-all domain that later started rejecting; the MX check being
skipped because the DoH lookup was failing (check `mx_checked` behaviour in
workflow 40).

Resume at half the previous volume once the bounce source is removed.

### Complaint rate above 0.1%

**Stop, and do not resume on the same day.** Complaints are the signal that
matters most to providers and the slowest to recover from.

Read the last 50 emails you sent as though you received one. The failure is
almost always relevance, not deliverability — a message that is obviously
generic gets marked as spam even when it is technically compliant.

Consider: raising `min_score_to_send`, turning `outreach.auto_send_enabled` back
off, and narrowing to one category until reply rate recovers.

### Someone says they were contacted after unsubscribing

Treat this as a serious bug. Establish the facts first:

```sql
SELECT * FROM acq.opt_outs WHERE normalized_value = 'them@clinic.pk';

SELECT e.id, e.status, e.sent_at, e.step_no, e.subject
FROM acq.emails e WHERE e.to_email = 'them@clinic.pk' ORDER BY e.created_at;

SELECT * FROM acq.sales_activities
WHERE lead_id = (SELECT lead_id FROM acq.opt_outs WHERE normalized_value = 'them@clinic.pk')
ORDER BY occurred_at;
```

If a send timestamp is after the opt-out timestamp, that is a real defect —
`is_sendable()` and `claim_send_slots()` both check suppression, so find out
which path bypassed them before sending anything else.

The more likely explanation is a *second lead record* with a different address
for the same clinic. Suppress at the domain level:

```sql
SELECT acq.apply_opt_out('DOMAIN', 'clinic.pk', 'OPT_OUT_REQUEST', 'MANUAL', NULL,
                         '{"reason":"complaint about repeat contact"}'::jsonb);
```

Then apologise, in person, from your own mailbox.

### Discovery stopped producing leads

Usually correct behaviour: every area has been swept and tasks are on a 30-day
cadence.

```sql
SELECT city, area, provider, enabled, next_run_at, last_result_count
FROM acq.discovery_tasks ORDER BY next_run_at LIMIT 20;

SELECT * FROM acq.workflow_runs
WHERE workflow_key = '10_lead_discovery' ORDER BY started_at DESC LIMIT 5;
```

A run with `error = 'daily_cost_cap_reached'` means `ai.daily_cost_cap_usd` was
hit. If you genuinely need more coverage: add areas, shorten `cadence_days`, or
enable the Google Places tasks.

### Emails stuck in READY_TO_SEND

Work down this list:

```sql
-- 1. Is the campaign active and is it inside the sending window?
SELECT key, status, sending_window_start, sending_window_end, sending_days, timezone,
       (now() AT TIME ZONE timezone)::time AS local_now,
       extract(isodow FROM now() AT TIME ZONE timezone) AS local_dow
FROM acq.campaigns;

-- 2. Is the daily budget spent, or is warm-up capping it?
SELECT m.key, acq.warmup_daily_cap(m.id) AS cap_today, sc.sent_count
FROM acq.mailboxes m
LEFT JOIN acq.send_counters sc
  ON sc.mailbox_id = m.id AND sc.bucket_date = CURRENT_DATE AND sc.bucket_hour = -1;

-- 3. What does the send gate itself say about one of them?
SELECT acq.is_sendable(id) FROM acq.emails WHERE status = 'READY_TO_SEND' LIMIT 5;
```

Blocked with an empty `company.postal_address` or `unsubscribe.base_url` is
intentional — workflow 50 throws rather than send a non-compliant email.

### AI returning invalid JSON repeatedly

```sql
SELECT purpose, error, count(*) FROM acq.ai_calls
WHERE NOT ok AND created_at > now() - interval '1 day'
GROUP BY 1,2 ORDER BY 3 DESC;
```

- `gemini_http_429` — rate limited. Lower `ai.max_research_per_run`.
- `missing_required_fields` — a schema change and the prompt disagree. Reload
  prompts after editing.
- `truncated_output` — the response hit the token ceiling; usually a page dump
  too large in the research prompt.
- `finish_reason_SAFETY` — the model refused. Check what page content was fed
  in; medical sites occasionally trip filters.

Nothing was sent in any of these cases. That is the design.

### A workflow keeps failing

```sql
SELECT workflow_key, node_name, left(error, 200), count(*), max(created_at)
FROM acq.dead_letters WHERE resolved_at IS NULL
GROUP BY 1,2,3 ORDER BY 5 DESC;
```

Once fixed:

```sql
UPDATE acq.dead_letters SET resolved_at = now(), resolved_by = 'umer'
WHERE id IN (…);
```

Dead letters record the payload, so a lead can be re-queued by hand rather than
lost.

### Leads stuck in a status

The nightly sweep handles most of this. To force it:

```sql
UPDATE acq.leads SET locked_by = NULL, locked_at = NULL
 WHERE locked_at < now() - interval '2 hours';

UPDATE acq.leads SET status = 'QUALIFIED'
 WHERE status = 'RESEARCHING' AND updated_at < now() - interval '1 day';
```

---

## Routine changes

**Pause everything, immediately**
```sql
UPDATE acq.campaigns SET status = 'PAUSED';
```
Deactivating workflow 50 in the UI also works, but this survives a restart.

**Adjust volume** — remember the warm-up ramp is a separate ceiling.
```sql
UPDATE acq.campaigns SET daily_send_limit = 30 WHERE key = 'pk-karachi-tier1';
UPDATE acq.mailboxes SET daily_cap = 40 WHERE key = 'primary';
```

**Re-tune scoring, free** — no AI spend; it re-reads cached research.
```sql
UPDATE acq.scoring_configs
   SET weights = jsonb_set(weights, '{has_whatsapp}', '20')
 WHERE version = 'v1';

SELECT acq.compute_score(id, 'BLENDED')
FROM acq.leads WHERE status IN ('QUALIFIED','READY_FOR_REVIEW');
```

**Add a market**
```sql
UPDATE acq.markets SET enabled = true WHERE code = 'AE';
```
Read [10-compliance.md](10-compliance.md) first. `AE`, `SA` and `GB` ship
disabled for reasons that are about consent law, not configuration.

**Approve a draft by hand**
```sql
UPDATE acq.emails SET status = 'READY_TO_SEND', approved_by = 'umer', approved_at = now()
 WHERE id = '…';
UPDATE acq.approvals SET status = 'APPROVED', decided_at = now(), decided_by = 'umer'
 WHERE email_id = '…';
```

**Blacklist a clinic permanently**
```sql
UPDATE acq.leads SET do_not_contact = true WHERE id = '…';
```
`transition_lead()` will then refuse to move it toward contact, for any actor.
