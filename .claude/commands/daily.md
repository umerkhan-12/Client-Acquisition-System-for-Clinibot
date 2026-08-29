---
description: The two-minute daily operator check
---

Daily check on the acquisition system. Be brief — lead with anything wrong.

```sql
SELECT * FROM acq.readiness() WHERE severity IN ('BLOCKER','WARN');
SELECT * FROM acq.v_overview;
SELECT * FROM acq.v_deliverability;
SELECT * FROM acq.v_approval_queue LIMIT 10;
SELECT workflow_key, node_name, left(error,100), count(*)
FROM acq.dead_letters WHERE resolved_at IS NULL GROUP BY 1,2,3;
```

Flag immediately, in this order:
- complaint rate above 0.1% — stop sending today
- bounce rate above 2% — pause and clean the list
- any unresolved dead letter
- drafts waiting for approval
- reply rate below 1% over 50+ sends — the targeting or the message is wrong,
  and sending more carefully will not fix it

If nothing needs attention, say so in one line. Do not pad it.
