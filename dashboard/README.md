# Dashboard

A read-mostly admin view over the `acq` schema, plus the outreach approval
queue — the one place the dashboard writes.

```bash
npm install
export ACQ_DATABASE_URL="postgresql://acq_app:…@localhost:5432/zenvexa_acq"
npm run dev          # http://localhost:3001
```

## What it shows

- **Overview tiles** — leads, qualified, sent, replies, interested, demos,
  customers, reply rate, opt-outs, bounces
- **Pipeline** — the six funnel stages
- **Deliverability** — per mailbox: sent today against the effective cap
  (which includes the warm-up ramp), 30-day volume, bounce, complaint and reply
  rates. Bounce above 2% and complaint above 0.1% turn red and raise a banner.
- **Waiting for you** — the approval queue, with the full draft and Approve /
  Reject
- **Leads** — top 60 by score, with the AI's read on each

## It reads views, not tables

Every query hits `acq.v_overview`, `acq.v_funnel`, `acq.v_deliverability`,
`acq.v_approval_queue` and `acq.v_lead_dashboard`. The dashboard has no
knowledge of the schema beyond those five, so a table change does not break it
as long as the views still resolve.

## Approving queues; it does not send

`approveDraft` moves the email to `READY_TO_SEND` and lets workflow 50 pick it
up. The approved email still passes through `acq.claim_send_slots()`, so the
daily cap, the sending window, the per-domain limit, the warm-up ramp and
suppression all still apply.

Approval is permission to send, not an instruction to bypass the limits. It also
means an opt-out arriving between approval and sending still stops the send —
verified: after approval, an opt-out cancels the queued email, moves the lead to
`OPTED_OUT`, and `transition_lead()` refuses to move it back for any actor,
including `HUMAN`.

## Database role

It only needs the `acq` schema:

```sql
CREATE ROLE acq_app LOGIN PASSWORD '…';
GRANT USAGE ON SCHEMA acq TO acq_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA acq TO acq_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA acq TO acq_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA acq TO acq_app;
```

No `DELETE`. Removing a lead is a deliberate act with a suppression row written
first — see [../docs/10-compliance.md](../docs/10-compliance.md).

## Deploying

It reads the pipeline and can approve outreach, so **put it behind
authentication**. The simplest correct answer is not to expose it at all: run it
on the droplet and reach it over an SSH tunnel.

```bash
ssh -L 3001:localhost:3001 you@droplet
```

If you do expose it, add auth at the reverse proxy and use a separate read-only
role for anything that does not need to approve.

## Verified

`npm run typecheck` and `npm run build` both pass, and the page has been run
against a live database with seeded leads and a pending approval: HTTP 200, all
five views resolving, tiles and tables rendering.
