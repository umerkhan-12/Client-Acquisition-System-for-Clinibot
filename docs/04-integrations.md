# API integrations

Everything here is chosen on the axis the audit sets out: cheapest option that
is actually reliable, and never one whose terms of service this use would
violate.

## Lead discovery

### OpenStreetMap / Overpass — free, start here

- **Endpoint** `https://overpass-api.de/api/interpreter`
- **Auth** none
- **Cost** free
- **Licence** ODbL. You may use the data; if you redistribute a derived
  database you must attribute and share alike. Internal prospecting is fine.

Karachi coverage of `amenity=clinic` / `doctors` / `dentist` is decent. Coverage
of `healthcare:speciality` is **poor**, which is why OSM finds you dentists and
general clinics but is close to useless for "dermatology clinics in Clifton".

It is a free volunteer service with real capacity limits. Workflow 10 makes one
call per area, pauses 4 seconds between areas, and sends an honest `User-Agent`.
Do not raise the rate. If you need volume, run your own Overpass instance.

### Google Places API (New) — paid, for specialty targeting

- **Endpoints** `places:searchText`, then `places/{id}` for details
- **Auth** API key, restricted by API and by IP
- **Cost** billed per call, per SKU. **Verify current pricing** — Google
  replaced the flat $200/month credit with per-SKU monthly free quotas in 2025.

The critical detail is the field mask. Text Search uses a minimal mask
(`places.id,places.displayName,places.formattedAddress,places.primaryType`) to
stay on the cheapest SKU. Enriching fields come from Details, which runs **only
for place IDs not already in `acq.lead_identity_keys`**.

**Places never returns an email address**, under any field mask. Emails come
from clinic websites in workflow 30, or not at all.

Enable when ready:
```sql
UPDATE acq.discovery_tasks SET enabled = true WHERE provider = 'GOOGLE_PLACES';
```

### Considered and rejected

| Option | Why not |
|---|---|
| Scraping Google Maps HTML | Violates ToS, breaks constantly, and section 3 rules it out |
| Facebook/Instagram page scraping | Platform terms; also personal data |
| Purchased lead lists | Provenance unverifiable, and consent claims are usually fiction |
| Yellow-pages-style directories | Mostly stale; may be worth a manual pass, not an automated one |

## Business research

**The clinic's own website**, read politely by workflow 30: `robots.txt` first,
at most 3 named pages, honest `User-Agent`, paced requests, no crawling.

No third-party enrichment provider. Clearbit/Apollo-class services are priced
for a different volume, their coverage of Pakistani private clinics is thin, and
their data provenance is exactly what section 6 says not to trust.

## Email verification

**Cloudflare DNS-over-HTTPS** — `https://cloudflare-dns.com/dns-query?name=<domain>&type=MX`
with `Accept: application/dns-json`. Free, no account, no key.

An MX check catches the failure that matters most: a domain that cannot receive
mail at all. It does not prove a specific mailbox exists. At 20-40/day that
trade is right — paid verification (ZeroBounce, MillionVerifier, ~$0.0004-0.004
per address) becomes worth it somewhere north of a few hundred sends a day.

A lookup that itself fails is treated as inconclusive and allowed through, not
as evidence against the domain.

## Email sending

**SMTP from a real mailbox.** Zoho Mail Lite (~$1/user/month, IMAP + SMTP) or
Google Workspace (~$6-7/user/month).

Do **not** use a transactional ESP. Postmark bans cold email outright; SendGrid,
Resend and most others prohibit unsolicited mail. See
[the audit, finding 5](00-architecture-audit.md#5-transactional-email-providers-prohibit-cold-outreach).

Known limitation, stated plainly: n8n's SMTP node cannot set custom headers, so
`List-Unsubscribe` and `List-Unsubscribe-Post` are not set. At your volume that
is acceptable — those are bulk-sender requirements enforced at 5,000+/day. The
visible unsubscribe link in every body does the work. Revisit if you pass
~1,000/day.

## Email receiving

**IMAP** on the same mailbox, via n8n's IMAP trigger in idle mode. One
connection sees replies and bounces. No webhook endpoint to host, no provider
event format to parse, no signature verification.

## AI

**Google Gemini** via the Generative Language API, called with
`responseMimeType: application/json` and a `responseSchema`, so the model is
constrained to the shape rather than asked politely for it.

- `gemini-2.5-flash` — the default. Fast, cheap, good enough for all six prompts.
- `gemini-2.5-flash-lite` — cheaper still; reasonable for classification.
- `gemini-2.5-pro` — not needed here; the tasks are not hard, they are numerous.

There is a free tier with rate limits, which is enough for development.

`responseSchema` accepts only a subset of JSON Schema. Workflow 01 strips
unsupported keywords (`additionalProperties`, `maxLength`, `pattern`, `minimum`,
`$ref`) before calling, so the prompt files can use full JSON Schema for
documentation purposes.

Costs are recorded per call in `acq.ai_calls` using rates from the
`ai.pricing` setting. **Those rates are indicative — verify them.**

## Calendar and demo booking

**Cal.com** (open source, free tier, self-hostable) or **Calendly** (free tier).
Both POST a JSON body on booking creation; workflow 100 accepts either shape.

Set `demo.booking_url` in `acq.settings`. While it is empty, every prompt is
told `booking_url_or_none: "none — do not invent availability"`, and the models
are instructed never to invent a time. **Nothing offers a slot the calendar
does not have.**

## Notifications

**Telegram Bot API.** Free, instant, arrives on a phone, supports Markdown, and
needs no inbound webhook. Create a bot with @BotFather, message it once, then
read your chat id from `getUpdates` and store it in `notify.telegram_chat_id`.

Email is the documented fallback (`notify.email_to`). A Telegram failure never
masks the underlying event — the dead-letter row is written first.

## Credential summary

| n8n credential name | Type | Used by |
|---|---|---|
| `acq-postgres` | Postgres | every workflow |
| `zenvexa-smtp` | SMTP | 50, 90 |
| `zenvexa-imap` | IMAP | 60 |
| `acq-telegram` | Telegram API | 00, 90, 100 |
| `gemini-api-key` | Header Auth (`x-goog-api-key`) | 01 |
| `google-places-key` | Query Auth (`key`) | 10 |

No secret appears in this repository. The ids in the workflow JSON are
placeholders; you set the real credential on each flagged node once at import.
