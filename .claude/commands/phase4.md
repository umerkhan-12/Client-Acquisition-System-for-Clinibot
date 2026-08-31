---
description: Phase 4 — replies, follow-ups, hot-lead alerts and demos
---

Phase 4 from `docs/09-build-order.md`. The loop closes: someone replies, it is
classified, follow-ups stop, and an interested clinic reaches your phone.

## Preconditions

Phase 3 is done — ~50 sent, bounces under 2%, at least one real reply.

## Activate

**ACQ 70**, **ACQ 80**, **ACQ 90**, **ACQ 100**.

Configure Cal.com, set `demo.booking_url`, and point its webhook at ACQ 100.
Without that link every email asks for a demo the reply cannot book.

## Two tests you must run yourself, from another address

Both are the kind of thing that looks fine until it matters.

1. **A positive reply.** Confirm the classification is right, the scheduled
   follow-ups stop, and the Telegram card arrives with usable context.
2. **An opt-out.** Reply "please remove me". Confirm the lead is suppressed and
   genuinely unreachable afterwards:

   ```sql
   SELECT status, opt_out FROM acq.leads WHERE id = '…';
   SELECT * FROM acq.opt_outs ORDER BY created_at DESC LIMIT 5;
   ```

   `acq.transition_lead()` refuses to move a suppressed lead back toward
   contact for *any* actor, including an explicit `HUMAN`. Confirm that holds
   rather than assuming it.

Remember the ordering guarantee in workflow 60: `acq.record_reply()` runs
*before* the AI call and cancels scheduled follow-ups and already-queued mail.
A Gemini outage therefore cannot cause someone who replied to keep receiving
mail. Worth verifying once, since it is the invariant that protects you from
the worst-looking failure.

## Read every classification for two weeks

```sql
SELECT r.from_email, rc.class, rc.confidence, rc.requires_human,
       left(r.body_text, 200)
FROM acq.reply_classifications rc JOIN acq.replies r ON r.id = rc.reply_id
ORDER BY rc.created_at DESC;
```

**A single misclassified `OPT_OUT` is worth stopping to fix.** Everything else
can be tuned later.

## When a hot lead arrives

The brief on your phone comes from `prompts/06_hot_lead_brief.md`. Its
`open_questions` field carries anything the clinic asked that falls under
`product.not_yet` — with the honest answer, before you reply.

Trust that field. It exists because the alternative is improvising an answer
about, say, payment processing, and Clinibot does not process payments.

## Done when

A full cycle — send, follow-up, reply, classify, notify — has run without your
intervention and you trust it.

Then `/phase5`.
