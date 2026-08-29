# Deployment

## Where this should run

**A second n8n container beside Clinibot's, on the same droplet, with its own
database on the same Postgres server.**

The reasoning, since the brief asks for it explicitly:

### Not inside Clinibot's existing n8n

Four reasons, in order of how much they will actually hurt:

1. **Blast radius.** This system runs loops over hundreds of leads with `Wait`
   nodes. A runaway execution consumes workers. If those workers are shared with
   Clinibot's production automations, a prospecting bug becomes a patient-facing
   outage.
2. **Credential scope.** n8n credentials are visible to every workflow in the
   instance. Outbound SMTP and a Places billing key should not sit next to
   whatever Clinibot's workflows hold. A separate instance means a compromised
   sales workflow reaches nothing else.
3. **Upgrade cadence.** You will iterate on this daily for weeks. Clinibot's n8n
   should be boring and rarely touched. Sharing an instance couples those.
4. **Different failure tolerance.** A failed discovery run is a shrug. A failed
   appointment confirmation is a patient who shows up on the wrong day. They
   should not share an alerting channel or an error workflow.

### Not a separate server, yet

A second container costs essentially nothing on a droplet that already exists.
n8n at this volume — a few hundred executions a day — needs a few hundred MB.
Move it to its own droplet when the current one is genuinely constrained, or
when you want the sales system to survive Clinibot maintenance windows. On a
2 GB droplet already running Clinibot, budget ~$12-18/month for a separate one.

### Not a custom worker service

Everything here is scheduled I/O against APIs and a database. That is precisely
what n8n is for. Writing a NestJS worker would mean rebuilding scheduling,
retries, execution history and a visual debugger — and you would still want the
SQL functions, which are where the real logic lives.

### Separate database, same server

See [the audit, finding 9](00-architecture-audit.md#9-do-not-put-sales-data-in-clinibots-database).
Same Postgres server, `zenvexa_acq` database, `acq_app` role with no grant on
any Clinibot object. Costs nothing, and means an n8n credential leak cannot
reach patient data.

## Compose

`docker-compose.yml` at the repo root defines the second n8n plus an optional
Postgres for local development. Alongside an existing Clinibot stack you would
normally use only the n8n service and point it at the existing database server.

```bash
cp .env.example .env
# fill in .env — it is gitignored
docker compose up -d n8n
```

The n8n service is configured with:

- `GENERIC_TIMEZONE=Asia/Karachi` — so cron expressions mean local time.
- `N8N_ENCRYPTION_KEY` — **set this and back it up.** Lose it and every stored
  credential becomes unreadable.
- `EXECUTIONS_DATA_PRUNE=true` with a 14-day window — execution history grows
  fast with loops.
- `N8N_PROTOCOL=https` and `WEBHOOK_URL` — the unsubscribe link is built from
  this, and it must be the public URL.

## Bringing it up

```bash
# 1. database
createdb zenvexa_acq
for f in db/migrations/*.sql; do
  psql -v ON_ERROR_STOP=1 -d zenvexa_acq -f "$f"
done
python3 scripts/load_prompts.py | psql -v ON_ERROR_STOP=1 -d zenvexa_acq

# 2. verify it works before trusting it
psql -v ON_ERROR_STOP=1 -d zenvexa_acq -f scripts/smoke_test.sql

# 3. n8n
docker compose up -d n8n
```

Then, in the n8n UI:

1. **Create credentials** with these exact names: `acq-postgres`,
   `zenvexa-smtp`, `zenvexa-imap`, `acq-telegram`, `gemini-api-key`
   (Header Auth, `x-goog-api-key`), `google-places-key` (Query Auth, `key`).
2. **Import** all 13 files from `n8n/workflows/`.
3. **Fix the placeholders.** Each imported workflow flags nodes whose credential
   id does not exist — open each and select the real credential. The
   *Execute Workflow* nodes have `REPLACE_WITH_ID__…` placeholders; point each
   at the named workflow.
4. **Set the error workflow.** On every workflow except 00, open
   Settings → Error workflow → *ACQ 00 — Error Handler*.
5. **Copy the webhook URLs** for workflows 110 and 100 and store them:
   ```sql
   UPDATE acq.settings SET value = to_jsonb('https://n8n.you.tld/webhook/unsubscribe'::text)
    WHERE key = 'unsubscribe.base_url';
   ```
6. **Fill the required settings** — `company.postal_address`,
   `notify.telegram_chat_id`, `demo.booking_url`, and prune
   `product.capabilities`.
7. **Activate in stages.** See [09-build-order.md](09-build-order.md). Do not
   turn all thirteen on at once.

## Reverse proxy

Workflows 100 and 110 need public HTTPS endpoints. Behind Caddy:

```
n8n.yourdomain.tld {
    reverse_proxy n8n-acq:5678
}
```

Only `/webhook/*` needs to be public. The n8n UI should sit behind
authentication or, better, be reachable only over a VPN or SSH tunnel.

## Backups

Two things matter, and only two:

1. **The database.** Everything reconstructible lives here — leads, research,
   suppression, history. The suppression list especially: losing
   `acq.opt_outs` means re-contacting people who asked you to stop.
   ```bash
   pg_dump -Fc zenvexa_acq > acq-$(date +%F).dump
   ```
2. **`N8N_ENCRYPTION_KEY`.** Without it, restoring n8n's own volume gives you
   workflows with permanently unreadable credentials.

The workflow definitions are in git, so the n8n volume itself is not critical.

## Resource expectations

At ~500 leads/month with 20 emails/day:

| | |
|---|---|
| n8n memory | 300-500 MB |
| n8n CPU | negligible except during discovery |
| Database | < 1 GB for the first year |
| Executions | ~150-250/day, mostly small |

Prune execution data — the loops in workflows 10, 30 and 50 generate a lot of
it, and n8n's own database grows faster than yours.
