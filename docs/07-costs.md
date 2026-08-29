# Cost

**Every figure here is indicative and must be verified against current
published pricing.** Google restructured Maps Platform billing in 2025, and
model pricing moves. The point of this page is the *shape* of the cost, which is
stable: discovery dominates, AI is cheap, and deduplication is what actually
controls the bill.

## $0 development

Genuinely zero, and enough to build and test the whole pipeline:

| | Choice |
|---|---|
| Discovery | OSM / Overpass — free |
| AI | Gemini free tier — rate-limited, adequate for development |
| Database | Local Postgres or the existing DigitalOcean instance |
| n8n | Self-hosted, already running |
| Email | MailHog or Mailtrap — captures mail, sends nothing |
| Notifications | Telegram — free |
| Booking | Cal.com free tier |

Set `outreach.dry_run = true` and the send workflow does everything except the
SMTP call. You can run the entire pipeline end to end, inspect every generated
email, and never touch a real clinic.

## Low-cost production

| | Monthly |
|---|---|
| Sending domain | ~$1 (amortised, ~$12/yr) |
| Zoho Mail Lite, 1 mailbox | ~$1 |
| n8n | $0 — a container beside the existing one |
| Postgres | $0 — a database on the existing instance |
| Telegram, Cal.com, Cloudflare DoH | $0 |
| **Fixed** | **~$2** |

Everything else is per-lead.

## Per-volume

Assumes OSM discovery, Gemini Flash, research cached 90 days, and the
dedup-before-Details ordering.

### 100 new leads/month

| | Cost |
|---|---|
| Discovery (OSM) | $0 |
| Gemini: ~100 research + ~100 qualify + ~40 emails + ~10 classifications | ~$1 |
| Fixed | ~$2 |
| **Total** | **~$3/month** |

### 500 new leads/month

| | Cost |
|---|---|
| Discovery (OSM) | $0 |
| Gemini | ~$4 |
| Fixed | ~$2 |
| **Total** | **~$6/month** |

Adding Google Places for specialty targeting: **~$12-15** on top in month one,
dropping sharply afterwards as dedup filters known businesses out before the
billed Details call.

### 1,000 new leads/month

| | Cost |
|---|---|
| Places text search (~200 calls) | ~$6 |
| Places details (~1,000 month 1, ~250 steady state) | ~$17 → ~$4 |
| Gemini | ~$10 |
| Fixed | ~$2 |
| **Month 1** | **~$35** |
| **Steady state** | **~$22** |

At this point 1,000 leads/month produces maybe 250-400 emailable leads, which at
20/day is about right for one mailbox.

### 5,000 new leads/month

| | Cost |
|---|---|
| Places | ~$110 month 1, ~$40 steady |
| Gemini | ~$40 |
| Mailboxes (5-8, because 20-40/day each) | ~$8 |
| Separate droplet, likely needed | ~$12-18 |
| **Total** | **~$100-180/month** |

**Think hard before running at this volume.** 5,000 leads/month means roughly
1,500 emails/month across many mailboxes, and that is a different operation:
multiple domains, per-domain reputation management, and a real risk of becoming
the generic outreach the brief explicitly rules out. The constraint is not cost.

## Where the money actually goes

At 1,000 leads/month, month one:

```
Places Details   ██████████████████████    ~$17   49%
Gemini           █████████████             ~$10   29%
Places Search    ████████                  ~$6    17%
Fixed            ███                       ~$2     5%
```

Two things follow:

1. **Deduplication is the cost control**, not prompt engineering. Filtering
   known place IDs before the Details call is worth more than every AI
   optimisation combined. It is why workflow 10 is ordered the way it is.
2. **Research caching compounds.** `ai.research_ttl_days = 90` means a clinic is
   researched roughly four times a year, not every time it appears in a search.

## Controls that are already wired

| Control | Setting | Effect |
|---|---|---|
| Daily AI budget | `ai.daily_cost_cap_usd` | Discovery halts rather than overspend |
| Research cache | `ai.research_ttl_days` | 90 days |
| Leads per run | `discovery.max_new_leads_per_run` | Caps a runaway discovery |
| Research per run | `ai.max_research_per_run` | Caps AI calls per cycle |
| Model choice | `ai.model` | `flash-lite` is ~3× cheaper than `flash` |
| Dedup before billing | workflow 10 ordering | The big one |

Cost per call is recorded in `acq.ai_calls`. Track it:

```sql
SELECT date_trunc('day', created_at)::date AS day,
       purpose, count(*), round(sum(cost_usd)::numeric, 4) AS usd
FROM acq.ai_calls
WHERE created_at > now() - interval '30 days'
GROUP BY 1, 2 ORDER BY 1 DESC, 4 DESC;
```

## The comparison worth making

An outbound SDR in Karachi costs meaningfully more per month than any row on
this page. This system does the repetitive part — finding, deduplicating,
researching, drafting, sequencing, classifying — and hands you the part that
needs a human: the conversation with someone who said yes.

That is the trade the brief asks for, and the cost structure supports it. What
it does not support, and should not, is using the savings to send ten times as
much mail.
