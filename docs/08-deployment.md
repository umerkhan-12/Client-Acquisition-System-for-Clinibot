# Deployment

Three managed pieces, none of which you have to run:

```
  Vercel — Next.js dashboard
     │  auth on every route AND every Server Action
     │  pg Pool, max:1, TLS verified, as acq_dashboard
     ▼
  Supabase ── TRANSACTION pooler :6543  ← Vercel (serverless, constant cold starts)
     │
     └─────── SESSION pooler :5432      ← n8n (long-lived connections)
                  ▲
                  │ acq-postgres credential, SSL required, as acq_n8n
     n8n host — Oracle Always Free, a $6 droplet, or the existing one
                  │
                  └── public surface: /webhook/* and nothing else
                        · 110 unsubscribe   · 100 demo-booked
```

**Gemini needs no work.** Workflow 01 already calls
`generativelanguage.googleapis.com` with header auth, one corrective retry and
per-call costing. It needs a key in n8n's credential store and a priced entry in
`ai.pricing` — see step 6.

---

## Why the pieces are split this way

### The `acq` schema is never exposed over PostgREST

Supabase serves only the schemas listed in its API settings, and `acq` must
never be one of them. It holds scraped clinic contact details, drafted email
bodies and the suppression list. Serving that over a public REST API gated by
RLS policies — which have to be right every time, forever — is the most common
way a Supabase project leaks. Leaving the schema off the list means the `anon`
and `service_role` keys reach none of it, and there is no policy to get wrong.

Migration 010 adds a second line of defence: it revokes everything on `acq`
from `anon` and `authenticated`, so an accidental exposure still grants
nothing.

### No n8n API layer for the dashboard

Next.js Server Components and Server Actions execute only on the server, so the
database credential never reaches the browser. Routing the dashboard through
n8n webhooks instead would add a second internet-facing endpoint holding full
database rights, authenticated by a header secret — more attack surface, no
less. n8n keeps only the two public webhooks it genuinely needs.

### Two different poolers

Use the **pooler host** for both, never the direct `db.<ref>.supabase.co`
connection: direct connections are IPv6-only on the free tier and a
DigitalOcean droplet usually cannot reach them.

| | Mode | Port | Why |
|---|---|---|---|
| n8n | session | 5432 | One host, long-lived connections, closest to direct |
| Vercel | transaction | 6543 | Cold-starts constantly; built for that churn |

Transaction mode still supports transactions — `approveDraft()` runs
BEGIN/COMMIT and the pooler pins a backend for its duration. The system is safe
under pooling generally: no advisory locks, no session state, no temp tables,
no `LISTEN/NOTIFY`, and `FOR UPDATE SKIP LOCKED` appears only inside functions.

---

## 1. Supabase

Create a project. Then, from **Settings → Database → Connection string**, copy
the pooler values into `.env` — read them off the dashboard rather than
assembling them by hand, since hostnames and ports vary by region.

```bash
cp .env.example .env
# fill in SUPABASE_ADMIN_URL
./ops/migrate-supabase.sh --dry-run    # see what it would do
./ops/migrate-supabase.sh
```

This applies all 11 migrations, loads the 9 prompts, reports whether the two
roles have passwords, and prints `acq.readiness()`.

It sets `search_path` to include `extensions` before running. Supabase installs
extensions there rather than in `public`, and `001_schema_core.sql` declares
seven `citext` columns and a `gin_trgm_ops` index by bare name — without that,
they fail with "type citext does not exist" while the extension is installed
and merely invisible.

### Set the role passwords

Migration 010 creates `acq_n8n` and `acq_dashboard` **without passwords**, so
no credential is ever committed. Neither can connect until you assign them:

```sql
ALTER ROLE acq_n8n       PASSWORD '…';   -- openssl rand -base64 24
ALTER ROLE acq_dashboard PASSWORD '…';
```

Neither may run DDL. `acq_dashboard` additionally cannot read `acq.leads`,
`acq.opt_outs`, `acq.mailboxes` or cached research, and can update only four
columns on `acq.emails` — so it cannot alter an approved email's recipient.
That is deliberate: it means a leaked Vercel connection string is a bad day
rather than every clinic's contact details.

### Confirm `acq` is not on the API

In **Settings → API → Exposed schemas**, `acq` must be absent. Verify from
outside:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://<ref>.supabase.co/rest/v1/leads?select=*" \
  -H "apikey: <anon-key>"          # expect 404, never 200
```

---

## 2. n8n — where to run it

Only n8n and Caddy run on this host: the database is Supabase and the dashboard
is Vercel. `ops/docker-compose.n8n.yml` serves all three options below, and
starts no Postgres.

| Host | Cost | Notes |
|---|---|---|
| **Oracle Cloud Always Free** | $0 | 1 OCPU / 6 GB arm64. Biggest and free — see [`ops/oracle/`](../ops/oracle/). Capacity is often unavailable; two-layer firewall. |
| **$6 DigitalOcean droplet** | $6/mo | 1 GB is enough. Boring and reliable. |
| **Second container on the existing droplet** | $0 | Fixes credential scope and upgrade cadence, not memory. ~725 MB free there. |

Measured on the existing droplet, n8n sits at **329 MB and 0.16% CPU** with a
60 MB SQLite after two weeks. This workload is I/O-bound, so 1 vCPU is not a
constraint.

n8n's own state stays in **SQLite on the host**, deliberately not Supabase —
the loops in workflows 10, 30 and 50 generate execution history that would
become the fastest-growing thing in a 500 MB free tier.

```bash
docker compose -f ops/docker-compose.n8n.yml --project-directory . up -d
```

### Then, in the n8n UI

No workflow rebuild is needed. Create these credentials with these exact names:
`acq-postgres`, `zenvexa-smtp`, `zenvexa-imap`, `acq-telegram`,
`gemini-api-key` (Header Auth, `x-goog-api-key`), `google-places-key`
(Query Auth, `key`).

`acq-postgres` points at the **session** pooler:

| | |
|---|---|
| Host | `aws-0-<region>.pooler.supabase.com` |
| Port | `5432` |
| Database | `postgres` |
| User | `acq_n8n.<project-ref>` |
| SSL | require |

Then:

1. **Import** all 13 files from `n8n/workflows/`.
2. **Fix the placeholders.** Each imported workflow flags nodes whose
   credential id does not exist — open each and select the real credential. The
   *Execute Workflow* nodes have `REPLACE_WITH_ID__…` placeholders; point each
   at the named workflow.
3. **Set the error workflow.** On every workflow except 00, open
   Settings → Error workflow → *ACQ 00 — Error Handler*.
4. **Copy the webhook URLs** for workflows 110 and 100 and store them:
   ```sql
   UPDATE acq.settings SET value = to_jsonb('https://n8n.you.tld/webhook/unsubscribe'::text)
    WHERE key = 'unsubscribe.base_url';
   ```
5. **Fill the required settings** — `company.postal_address`,
   `notify.telegram_chat_id`, `demo.booking_url`.
6. **Confirm `ai.model` has a price.** `acq.readiness()` blocks if it does not.
   An unpriced model is costed at $0.00 forever, which silently disables
   `ai.daily_cost_cap_usd`. This bites specifically when copying the Clinibot
   droplet's pinned `GEMINI_MODEL`, which is not in the default `ai.pricing`.
7. **Activate in stages.** See [09-build-order.md](09-build-order.md). Do not
   turn all thirteen on at once.

### Lock down the public surface

Only `/webhook/*` should be reachable. `ops/Caddyfile` does this — it
whitelists paths rather than proxying the host, and 404s everything else,
including the UI.

**The n8n UI must not be public.** Its only authentication is an owner account
created on first visit, so between `docker compose up` and that first visit an
exposed instance is an unauthenticated remote-code-execution console. Reach it
over a tunnel:

```bash
ssh -L 5678:127.0.0.1:5678 <your-droplet>
```

Validate a Caddyfile change before shipping it — a broken one takes the
unsubscribe endpoint offline:

```bash
docker run --rm -v "$PWD/ops/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e ACME_EMAIL=you@example.tld -e ACQ_DOMAIN=example.tld \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```

---

## 3. Vercel — the dashboard

Import the repo, set **Root Directory** to `dashboard`. Framework detection and
build command need no changes.

Environment variables:

| Variable | Value | Secret? |
|---|---|---|
| `ACQ_DATABASE_URL` | transaction pooler `:6543`, as `acq_dashboard` | **yes** |
| `NEXT_PUBLIC_SUPABASE_URL` | `https://<ref>.supabase.co` | no |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | the anon key | no |
| `NEXT_PUBLIC_SITE_URL` | `https://<app>.vercel.app` | no |
| `ACQ_ALLOWED_EMAILS` | comma-separated allowlist | no |

Anything prefixed `NEXT_PUBLIC_` is compiled into the browser bundle. Never put
`ACQ_DATABASE_URL` behind that prefix.

### Authentication

Supabase magic-link, with a hard allowlist. Two properties worth knowing
because they are easy to undo:

- **An empty `ACQ_ALLOWED_EMAILS` denies everyone.** Treating "unset" as
  "allow all" would turn a missing environment variable into an open door.
- **Every Server Action re-checks, not just middleware.** A Server Action is
  an individually addressable POST endpoint; a gate that lives only in
  middleware is bypassable if a route matcher ever changes.

In Supabase → Authentication → URL Configuration, add
`https://<app>.vercel.app/auth/callback` as a redirect URL. Sign-up is
disabled in code (`shouldCreateUser: false`), so a link only works for a user
that already exists — create yours in the Supabase dashboard.

Also switch on **Vercel Deployment Protection** as an outer layer. It is not a
substitute for the above; it is the thing that keeps preview deployments from
being a way around it.

---

## Backups

Two things matter, and only two:

1. **The database.** Losing `acq.opt_outs` means re-contacting people who asked
   you to stop.
   ```bash
   pg_dump -Fc "$SUPABASE_ADMIN_URL" > acq-$(date +%F).dump
   ```
   The free tier has no point-in-time recovery, so this matters more here than
   it did on a self-managed box, not less. Put it on a schedule.
2. **n8n's encryption key.** Without it, restoring n8n's volume gives you
   workflows whose credentials are permanently unreadable.

Workflow definitions live in git, so n8n's volume itself is not critical.

---

## Resource expectations

At ~500 leads/month with 20 emails/day:

| | |
|---|---|
| Supabase | well inside the 500 MB free tier for the first year |
| Vercel | inside the free tier; the dashboard is one dynamic page |
| Gemini | ~$2-5/month, capped by `ai.daily_cost_cap_usd` |

Two free-tier limits to watch. **A Supabase project pauses after about a week
idle** — the daily cron workflows keep it awake, but a long pause in outreach
will not. And `acq.ai_calls` and `acq.lead_research` hold raw JSONB and are what
actually grow; add a retention policy before they matter rather than after.

If either stops fitting, [`ops/self-hosted/`](../ops/self-hosted/) puts the
whole stack back on one droplet.
