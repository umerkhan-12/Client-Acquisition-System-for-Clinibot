---
description: Phase 5 — hand more of the loop to the system
---

Run Phase 5 from `docs/09-build-order.md`. Only after the approval queue has been
boring for two consecutive weeks.

Before changing anything, show me the evidence that it has been:

```sql
SELECT status, count(*) FROM acq.approvals
WHERE requested_at > now() - interval '14 days' GROUP BY 1;

SELECT * FROM acq.v_deliverability;
SELECT reply_rate_pct, conversion_rate_pct FROM acq.v_overview;
```

If I have rejected more than about one draft in twenty, autonomy is premature.
Say so and stop.

If the numbers support it, then in this order, one at a time, with a day between:

1. Raise `ai.min_email_confidence` to `0.80`.
2. Set `outreach.auto_send_enabled = true`. Only low-confidence drafts now reach
   me.
3. Let the warm-up ramp continue to its cap. Do not raise `daily_cap` by hand.
4. Deploy the dashboard (`dashboard/`) behind an SSH tunnel.

Then, and only if I ask:
- Enable Google Places tasks for specialty targeting.
- Add a second market — **read `docs/10-compliance.md` first**. UAE, Saudi and the
  UK ship disabled because their consent models differ from Pakistan's, and the
  UK needs an entity-type filter that does not exist yet.

Never enable WhatsApp outreach. Explain why if I ask.
