# Self-hosted stack — the alternative path

**Not the current deployment.** The system runs on Supabase (database), an
existing DigitalOcean n8n (workflows), and Vercel (dashboard). See
[`docs/08-deployment.md`](../../docs/08-deployment.md).

These two files stand up the whole thing on one droplet instead: Postgres, n8n
and Caddy in containers, provisioned from bare Ubuntu.

| File | Does |
|---|---|
| `provision-droplet.sh` | Bare Ubuntu 24.04 → Docker, 2 GB swap, ufw (22/80/443), log caps, unattended upgrades, deploy user |
| `docker-compose.prod.yml` | Postgres + n8n + Caddy, everything but Caddy on loopback |

## When you would come back to this

- **Supabase's free tier stops fitting.** 500 MB, and a project pauses after
  about a week idle. The daily cron keeps it awake, but `acq.ai_calls` and
  `acq.lead_research` hold raw JSONB and are what will grow.
- **You want the data on infrastructure you control** — a decision that gets
  easier to justify as the suppression list grows, since `acq.opt_outs` is the
  one table whose loss has consequences for other people.
- **Egress or connection limits bite.** A single droplet has neither.

## What still applies from the current setup

Migration `010_roles_grants.sql` is not Supabase-specific — `acq_n8n` and
`acq_dashboard` are worth having on a self-hosted Postgres too, and the
`anon`/`authenticated` revocations simply no-op where those roles do not exist.

`ops/Caddyfile` stays where it is. It is not part of this alternative; it is
how the n8n you already run exposes only `/webhook/*`, which is true either
way.

## Using it

```bash
ssh root@<droplet-ip> 'bash -s' < ops/self-hosted/provision-droplet.sh
docker compose -f ops/self-hosted/docker-compose.prod.yml up -d
```

`docker-compose.prod.yml` expects to sit at the repo root — it references
`./db/migrations`, `./n8n/workflows` and `./ops/Caddyfile` relative to the
compose file. Run it with `--project-directory .` from the root, or move it
back up, before relying on those mounts.
