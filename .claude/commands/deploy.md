---
description: Deploy — Supabase schema, n8n workflows, Vercel dashboard
---

Three managed pieces. Full reference: `docs/08-deployment.md`.

```
Vercel (dashboard) ──► Supabase ◄── n8n (DigitalOcean, already deployed)
   transaction :6543              session :5432
   as acq_dashboard               as acq_n8n
```

## Every time — the schema

```bash
./ops/migrate-supabase.sh --dry-run   # see what it would do first
./ops/migrate-supabase.sh
```

Idempotent: all 10 migrations replay safely. It loads prompts, reports whether
the two roles have passwords, and prints `acq.readiness()`. Report the BLOCKER
and WARN rows verbatim — they are configuration, not breakage.

Needs `SUPABASE_ADMIN_URL` in `.env` (Supabase's `postgres` role — the only
credential here allowed to run DDL) and `psql` on PATH.

## First time only

1. **Set the role passwords.** Migration 010 creates `acq_n8n` and
   `acq_dashboard` with none, so neither can connect until you do:
   ```sql
   ALTER ROLE acq_n8n       PASSWORD '…';
   ALTER ROLE acq_dashboard PASSWORD '…';
   ```
2. **Confirm `acq` is not an exposed schema** in Supabase → Settings → API.
   Verify from outside, do not just read the setting:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' \
     "https://<ref>.supabase.co/rest/v1/leads?select=*" -H "apikey: <anon-key>"
   ```
   Expect 404. A 200 means the schema is exposed and every lead is public.
3. **n8n** — point `acq-postgres` at the session pooler (`:5432`, SSL require,
   user `acq_n8n.<ref>`), import the 15 workflows, fix credential placeholders,
   set the error workflow, write the webhook URLs back into `acq.settings`.
4. **Vercel** — Root Directory `dashboard`. Set `ACQ_DATABASE_URL` (transaction
   pooler, as `acq_dashboard`), the three `NEXT_PUBLIC_*` vars, and
   `ACQ_ALLOWED_EMAILS`. Add `/auth/callback` as a Supabase redirect URL.

**Never put `ACQ_DATABASE_URL` behind a `NEXT_PUBLIC_` prefix** — that prefix
compiles a value into the browser bundle.

## Before calling it deployed

Check these rather than assuming:

- `acq_dashboard` is denied on the base tables:
  ```sql
  -- as acq_dashboard: must ERROR
  SELECT * FROM acq.leads;
  -- must succeed
  SELECT * FROM acq.v_lead_dashboard;
  ```
- A Server Action rejects an unauthenticated caller — `curl -X POST` it
  directly, do not just check that the browser redirects.
- The unsubscribe link works end to end and lands a row in `acq.opt_outs`.
- n8n's UI is **not** reachable publicly; only `/webhook/*` is.

## What is deliberately not automated

Workflow import. Each workflow needs real credentials selected by hand, and
doing that once beats a script that pretends to.

Nothing sends while `outreach.auto_send_enabled` is false and the BLOCKER rows
stand. Then go to `/phase1`.
