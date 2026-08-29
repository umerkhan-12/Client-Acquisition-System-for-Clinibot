---
description: Phase 3 — the first real emails, approved one at a time
---

Run Phase 3 from `docs/09-build-order.md`. **This is the irreversible step.**
Real email reaches real clinics. Go slowly and confirm with me at each gate.

**Deliverability pre-flight — all must pass before anything sends:**

```bash
./scripts/check_deliverability.sh <sending-domain> <dkim-selector>
```

SPF, DKIM, DMARC and MX must all pass. If DMARC is not yet at `p=none` with a
`rua` address I read, stop.

**Then, in order, confirming each with me:**

1. Deploy workflow 110, set `unsubscribe.base_url` to its public URL, **click the
   link yourself** and show me the resulting row in `acq.opt_outs`. An opt-out
   link that does not work is worse than none.
2. Confirm `company.postal_address` is set to a real address.
3. Set `mailboxes.warmup_started_on = CURRENT_DATE`. The ramp caps week 1 at
   5/day and that is deliberate.
4. Set `outreach.dry_run = false`. Keep `outreach.auto_send_enabled = false`.
5. Activate workflows 50 and 60.
6. **Send one email to me first.** I will read it on a phone before any clinic
   sees one.

Then, for each of the first sends, show me the draft and wait for my explicit
approval before marking it `READY_TO_SEND`. Five a day in week one. Do not batch
approve. Do not raise the cap.

After each day, report:

```sql
SELECT * FROM acq.v_deliverability;
SELECT * FROM acq.v_daily_metrics LIMIT 3;
```

If bounce rate goes above 2% or any complaint arrives, pause the campaign
immediately (`UPDATE acq.campaigns SET status = 'PAUSED';`) and tell me before
doing anything else.
