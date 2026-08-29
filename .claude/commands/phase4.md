---
description: Phase 4 — replies, follow-ups, hot-lead alerts and demo booking
---

Run Phase 4 from `docs/09-build-order.md`.

Preconditions: ~50 emails sent, bounce rate under 2%, at least one real reply.

1. Activate workflows 70, 80, 90 and 100.
2. Configure Cal.com (or Calendly), set `demo.booking_url`, and point its webhook
   at workflow 100. Verify with a test booking that a row appears in
   `acq.demo_bookings` and the lead moves to `DEMO_BOOKED`.
3. Set `notify.telegram_chat_id` and confirm a test alert reaches my phone.

**Then test the paths that matter, using a mailbox I control — not a clinic:**

- Reply positively. Confirm: classified correctly, follow-ups cancelled, Telegram
  card arrives with the quote and score.
- Reply **"please remove me from your list"**. Confirm: classified `OPT_OUT`, a
  row in `acq.opt_outs`, lead status `OPTED_OUT`, every queued email cancelled,
  and that `acq.transition_lead()` refuses to move it back even for a HUMAN actor.
  This is the single most important test in the whole system — show me the
  evidence, do not just assert it passed.
- Send an out-of-office. Confirm it is logged as an auto-reply and the sequence
  continues.

For the first two weeks, show me every classification each day:

```sql
SELECT r.from_email, rc.class, rc.confidence, rc.requires_human,
       left(r.body_text, 200) AS excerpt
FROM acq.reply_classifications rc JOIN acq.replies r ON r.id = rc.reply_id
ORDER BY rc.created_at DESC;
```

A single misclassified opt-out is worth stopping to fix.
