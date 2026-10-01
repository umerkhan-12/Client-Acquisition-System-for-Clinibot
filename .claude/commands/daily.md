---
description: Two-minute operator check — anything needing a human today
---

The daily check. Answer in under a page, and lead with anything that needs a
person today.

Full procedures in `docs/11-runbook.md`.

## 1. Anyone waiting on you

This is the only part that is urgent. A clinic that replied and heard nothing
is the most expensive failure in the system.

```sql
-- everything escalated to a person, oldest first
SELECT kind, title, clinic_name, city, lead_score, ai_confidence, requested_at
FROM acq.v_approval_queue
ORDER BY requested_at;

-- replies the classifier itself flagged for a human
SELECT r.from_email, rc.class, rc.confidence, rc.escalation_reason,
       left(r.body_text, 200)
FROM acq.reply_classifications rc
JOIN acq.replies r ON r.id = rc.reply_id
WHERE rc.requires_human
ORDER BY rc.created_at DESC
LIMIT 20;
```

**Website outreach (WEB offer).** Messages are sent by hand from the
dashboard's `/outreach` page, so the queue only moves if a person works it.

```sql
SELECT * FROM acq.v_web_overview;

-- follow-ups due today
SELECT business_name, step_no, channel, due_at
FROM acq.v_manual_outreach WHERE queue = 'TO_SEND' AND step_no > 0
ORDER BY due_at;
```

## 2. Deliverability

```sql
SELECT * FROM acq.v_deliverability;
```

**Stop sending today** if bounces exceed 2% or a spam complaint appeared. Say
so first and loudly; everything else can wait.

## 3. Did anything fail silently

```sql
SELECT workflow_key, node_name, count(*), max(created_at) AS latest
FROM acq.dead_letters WHERE resolved_at IS NULL
GROUP BY 1,2 ORDER BY latest DESC;
```

## 4. Spend

```sql
SELECT date_trunc('day', created_at)::date AS day,
       round(sum(cost_usd)::numeric, 3) AS usd, count(*) AS calls
FROM acq.ai_calls WHERE created_at > now() - interval '7 days'
GROUP BY 1 ORDER BY 1 DESC;
```

**A flat $0.000 with non-zero calls is a bug, not thrift.** It means `ai.model`
has no `ai.pricing` entry, so the daily cap cannot trip. Check:

```sql
SELECT severity, detail FROM acq.readiness() WHERE check_name = 'ai.pricing';
```

## 5. Is the queue moving

```sql
SELECT status, count(*) FROM acq.emails GROUP BY 1;
SELECT count(*) AS awaiting_approval FROM acq.v_approval_queue;
```

## Report

Lead with what needs a human. Then one line each on deliverability, failures,
spend and queue depth. If nothing needs attention, say that in one sentence —
do not pad it.
