---
description: Read the database and report which phase this system is actually in
---

Work out, from evidence rather than from what anyone remembers, where this
system stands — then say what to do next.

Do not guess and do not trust this file's ordering over what you find.

## 1. Is there a database to read?

Try in this order, stopping at the first that answers:

```bash
psql -d zenvexa_acq -c 'SELECT 1'                  # local
docker compose -f docker-compose.prod.yml exec -T postgres psql -U acq_app -d zenvexa_acq -c 'SELECT 1'
ssh acq 'cd /opt/acq && docker compose -f docker-compose.prod.yml exec -T postgres psql -U acq_app -d zenvexa_acq -c "SELECT 1"'
```

If none answer, the system is **not deployed**. Say so plainly, point at
`docs/08-deployment.md`, and stop — everything below needs a database.

## 2. Readiness

```sql
SELECT severity, check_name, detail FROM acq.readiness() ORDER BY severity;
```

Report every `BLOCKER` and `WARN` verbatim. These are the things that are
silent when wrong, which is exactly why they are checked.

## 3. Where the funnel actually is

```sql
SELECT status, count(*) FROM acq.leads GROUP BY 1 ORDER BY 2 DESC;

SELECT count(*)                                            AS leads,
       count(*) FILTER (WHERE public_email IS NOT NULL)     AS with_email,
       round(100.0 * count(*) FILTER (WHERE public_email IS NOT NULL)
             / nullif(count(*),0), 1)                       AS emailable_pct
FROM acq.leads;

SELECT (SELECT count(*) FROM acq.emails WHERE sent_at IS NOT NULL)   AS sent,
       (SELECT count(*) FROM acq.replies)                            AS replies,
       (SELECT count(*) FROM acq.leads WHERE replied_at IS NOT NULL) AS leads_replied,
       (SELECT count(*) FROM acq.opt_outs)                           AS opt_outs;
```

`emailable_pct` is the number the whole project turns on
(`docs/12-getting-your-first-client.md`). Always report it once there are
leads.

## 4. Which workflows are actually on

Ask n8n, not the repo — a workflow can exist and be inactive:

```bash
ssh acq 'docker exec n8n-acq n8n list:workflow' 2>/dev/null
```

## 5. Say where things stand

Map the evidence to a phase, using `docs/09-build-order.md`:

| Phase | Looks like |
|---|---|
| Not deployed | no database answers |
| 0 — Foundations | database up, blockers unresolved, no leads |
| 1 — Discovery | leads accumulating, no AI research rows, nothing sent |
| 2 — Research + drafting | `acq.lead_research` populated, drafts exist, `sent = 0` |
| 3 — First sends | `sent > 0`, `auto_send_enabled = false` |
| 4 — Replies + demos | replies exist, follow-ups scheduled |
| 5 — More autonomy | `auto_send_enabled = true` |

Finish with **the single next action**, not a list. If blockers exist, the next
action is clearing the first one.
