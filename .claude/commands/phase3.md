---
description: Phase 3 — first real emails, approved one at a time
---

Phase 3 from `docs/09-build-order.md`. **The irreversible step.** Mail reaches
real clinics and cannot be recalled. Small and supervised.

## Refuse to proceed unless all of these hold

Check each. If any fails, stop and say which — do not work around it.

1. **Phase 2 is genuinely done.** You would send 8 of 10 drafts unchanged.
2. **Deliverability passes.** `./scripts/check_deliverability.sh` against the
   real sending domain — SPF, DKIM and DMARC all present. Without all three, a
   large share lands in spam and you will misread it as a copy problem.
3. **The sending domain is not `zenvexa.tech`.** Cold mail from the product's
   own domain risks Clinibot's transactional mail to real clinics.
4. **`acq.readiness()` has zero BLOCKER rows.**
5. **You have clicked your own unsubscribe link and seen the row appear:**

   ```sql
   SELECT * FROM acq.opt_outs ORDER BY created_at DESC LIMIT 5;
   ```

   Deploy **ACQ 110**, set `unsubscribe.base_url`, then actually click it. An
   opt-out link that 404s is worse than none: it converts someone politely
   leaving into a spam complaint.

## Then

```sql
UPDATE acq.settings SET value = 'false'::jsonb WHERE key = 'outreach.dry_run';
UPDATE acq.mailboxes SET warmup_started_on = CURRENT_DATE WHERE active;
-- auto_send stays OFF. Every email is approved by a person in this phase.
```

Activate **ACQ 50** and **ACQ 60**.

**Send yourself one first and read it on a phone.** Check the from-name, the
subject at narrow width, the unsubscribe footer, and whether the postal address
is right.

## Approving, 5/day in week one

```sql
SELECT * FROM acq.v_approval_queue;

UPDATE acq.emails SET status = 'READY_TO_SEND', approved_by = 'umer', approved_at = now()
 WHERE id = '…';
UPDATE acq.approvals SET status = 'APPROVED', decided_at = now(), decided_by = 'umer'
 WHERE email_id = '…';
```

Read each one before approving. That is the entire point of this phase.

## Watch daily

```sql
SELECT * FROM acq.v_deliverability;
```

**Stop sending immediately** if bounces exceed 2% or any spam complaint
arrives. A damaged domain takes weeks to recover and costs more than the leads
are worth.

## Done when

~50 emails sent, bounce rate under 2%, and at least one real reply.

Then `/phase4`.
