# n8n on Oracle Cloud Always Free

The only genuinely free-forever host that actually fits this workload. n8n
needs three things that kill most free tiers: **cron firing 24/7**,
**persistent state** (the encryption key and credentials), and **no sleeping
on idle**. Oracle's Always Free tier gives all three.

## What you get, free, indefinitely

| | |
|---|---|
| Compute | **VM.Standard.A1.Flex** — up to 4 OCPU / 24 GB RAM total (arm64) |
| Also free | 2 × AMD `E2.1.Micro`, 1 OCPU / 1 GB each (x86) |
| Storage | 200 GB block volume total |
| Egress | 10 TB/month |

**1 OCPU / 6 GB of A1 is more machine than the $6 DigitalOcean droplet**, which
is 1 vCPU / 1 GB. For reference, the existing n8n runs at 329 MB and 0.16% CPU.

Do not use the AMD micro shape for this. 1 GB works on DigitalOcean because
nothing else runs there, but the A1 is free *and* bigger — take it.

## Read this before you commit to it

Four real drawbacks. None is a dealbreaker; all are worth knowing first.

1. **A1 capacity is frequently unavailable.** "Out of host capacity" on Always
   Free Ampere is common in popular regions and can persist for days. This is
   the single biggest practical risk — see the workaround below.
2. **Always Free resources can be reclaimed when genuinely idle.** This system
   runs cron every day, so it is not idle. Still, it is Oracle's policy and not
   a guarantee you control.
3. **Region-locked.** Always Free lives in your account's home region, chosen
   at signup and not changeable afterwards. Pick one near you.
4. **A card is required** for identity verification. Always Free resources are
   not charged, but make sure the account stays on the free tier rather than
   being upgraded to Pay As You Go by accident.

If any of that makes you uneasy for a system that feeds your sales pipeline,
the $6 droplet is the boring answer and it is enough.

### Working around "out of host capacity"

- Try a **different availability domain** in your region — capacity is
  per-AD.
- Ask for **less**: 1 OCPU / 6 GB succeeds far more often than 4 OCPU / 24 GB,
  and 6 GB is already generous here.
- Retry on a schedule. Capacity frees up constantly; a request that fails now
  often succeeds within a day.
- Ubuntu images tend to be available when others are not.

## Setup

1. Create the instance: **Ubuntu 22.04 or 24.04 (aarch64)**,
   VM.Standard.A1.Flex, 1 OCPU / 6 GB, 50 GB boot volume. Add your SSH key.

2. Provision it:
   ```bash
   ssh ubuntu@<ip> 'bash -s' < ops/oracle/provision-oracle.sh
   ```

3. **Open 80 and 443 in the VCN Security List** — Networking → Virtual Cloud
   Networks → your VCN → Security Lists → Default → Add Ingress Rules.

   > **The trap.** Oracle filters in *two* places: the VCN Security List and
   > the instance's own iptables. Oracle's Ubuntu images ship a restrictive
   > iptables ruleset that persists across reboots, so opening the Security
   > List alone is not enough — the packet arrives and is dropped locally. The
   > symptom is a Let's Encrypt challenge that times out while `curl localhost`
   > works perfectly. `provision-oracle.sh` handles the iptables half,
   > inserting rules *above* the trailing REJECT; you must do the console half
   > yourself.

4. Point DNS at the instance and wait for it to resolve. Caddy requests a
   certificate on first start, and a failed ACME challenge counts against a
   rate limit measured in hours.

5. Deploy:
   ```bash
   rsync -az --exclude .git --exclude node_modules ./ acq:/opt/acq/
   ssh acq "cd /opt/acq && docker compose -f ops/docker-compose.n8n.yml \
              --project-directory . up -d"
   ```

6. Raise the memory ceiling, since this box has room the defaults assume it
   does not. In `.env`:
   ```bash
   N8N_MEM_LIMIT=2g
   N8N_HEAP_MB=1536
   ```

Then follow [`docs/08-deployment.md`](../../docs/08-deployment.md) from
**"2. n8n — the instance you already run"**: create the credentials, import the
15 workflows, fix the placeholders, set the error workflow, and write the
webhook URLs back into `acq.settings`.

## arm64

n8n publishes multi-arch images, so `docker.n8n.io/n8nio/n8n` runs natively on
A1 with nothing special required — as do `caddy:2-alpine` and `postgres:16-alpine`.

The one thing to watch is **community nodes with native dependencies**, which
occasionally ship x86-only binaries. None of the 15 workflows uses one: they
are all stock nodes (HTTP Request, Postgres, Code, Email, Telegram, Schedule,
Webhook, Execute Workflow).

## What still lives elsewhere

This host runs n8n and Caddy. Nothing else moves:

- **Database** — Supabase. `ops/docker-compose.n8n.yml` starts no Postgres.
- **Dashboard** — Vercel.
- **n8n's own state** — SQLite in a Docker volume on this box, deliberately
  not Supabase, so execution history never eats the 500 MB free tier.

Back up `N8N_ENCRYPTION_KEY` somewhere other than this instance. Without it, a
restored volume gives you workflows whose credentials are permanently
unreadable.
