---
description: Phase 5 — hand more of the loop over, carefully
---

Phase 5 from `docs/09-build-order.md`. Ongoing, not a milestone.

## The gate

**Only after the approval queue has been boring for two weeks.** Boring means
you approved nearly everything without editing it. If you are still rewriting
drafts, you are not here yet — say so and stay in Phase 4.

## Raise autonomy, in this order

```sql
UPDATE acq.settings SET value = '0.8'::jsonb  WHERE key = 'ai.min_email_confidence';
UPDATE acq.settings SET value = 'true'::jsonb WHERE key = 'outreach.auto_send_enabled';
```

Raise the confidence floor **before** turning auto-send on, not after. That
ordering means only low-confidence drafts still need you; reversing it sends a
batch you would have caught.

Then let the warm-up ramp reach 25-40/day on its own. Do not force it — the
ramp is what keeps a new domain out of spam folders, and there is no way to
hurry reputation.

Deploy the dashboard (`dashboard/`) once sending is autonomous — that is when
reading state matters more than approving individual mail.

## What to consider next, in this order

1. **Google Places for specialty targeting** — narrower, better-scoring leads.
2. **A second market.** Insert a row in `acq.markets`, seed discovery tasks,
   create a campaign.

   **Read `docs/10-compliance.md` first.** UAE, Saudi Arabia and the UK have
   consent models Pakistan does not share — several require opt-in before the
   first message, which this system's design does not assume. They ship
   disabled deliberately. Enabling one is a legal decision, not a config change.
3. **A second mailbox** — only if you are consistently hitting the daily cap
   *with a healthy reply rate*. A second mailbox multiplies volume, and volume
   without a good reply rate multiplies domain damage.

## What not to do

- Do not raise the daily cap to "catch up". The cap is a deliverability limit,
  not a throughput setting.
- Do not turn off the approval queue for high-value leads. The clinics worth
  most are the ones worth reading an email to.
- Do not add a second send path. `acq.claim_send_slots()` is the only route to
  SMTP, and every cap, window, per-domain limit, warm-up ramp and suppression
  check lives inside that one transaction.

## Watch continuously

```sql
SELECT * FROM acq.v_deliverability;
SELECT * FROM acq.dead_letters WHERE resolved_at IS NULL;
```

Autonomy means failures accumulate silently. The dead-letter table is where
they land.
