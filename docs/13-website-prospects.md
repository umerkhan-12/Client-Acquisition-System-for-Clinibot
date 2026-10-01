# 13 — Website prospects (the WEB offer)

A second offer running through the same database: **websites for local
businesses that don't have one, or have a weak one.** It reuses discovery,
deduplication, scoring, suppression and the state machine. What differs is
the channel: these messages are **sent by you, by hand, from your phone**, from
a queue the system drafts for you.

## Why by hand

- Most small businesses publish a phone number and no email, so the email
  pipeline could not reach them anyway.
- Automated WhatsApp from a personal number gets the number banned within days,
  and a bulk cold message is spam. Twenty considered messages a day from a real
  person is neither, and it gets replies.
- It keeps invariant 4 intact. `acq.claim_send_slots()` is still the only path
  to SMTP. Nothing in the WEB pipeline sends anything.

## How a lead flows

```
discovery (10)  ─ WEB task, or a clinic with no website + no email ─┐
                                                                    ▼
qualification (20)  acq.route_offer() → score with the web-v1 config
        │
        ├─ no website ──────────────────────────────┐
        │                                           ▼
        └─ has a website → audit (25) ─ weak site ─► drafting (45) → dashboard /outreach
                                     └ good site → REJECTED
```

| Step | What happens | Where the decision lives |
|---|---|---|
| Discovery (10) | WEB tasks search for printers, salons, estate agents and so on. Leads are tagged `offer = 'WEB'` | `acq.upsert_lead_for_offer()` |
| Routing (20) | A clinic with no website and no public email becomes a WEB lead instead of being rejected | `acq.route_offer()`, setting `web.adopt_clinics_without_website` |
| Scoring (20) | No website +35, busy listing +12, well rated +5, WhatsApp +10, category tier up to +15 | `acq.compute_score()`, config `web-v1` |
| Audit (25) | Fetches the homepage once (robots.txt honoured). Records unreachable, parked, no https, not mobile-friendly, slow, outdated, no way to call. An email on the page is stored with the page as evidence | `acq.record_website_audit()` |
| Drafting (45) | Gemini writes one WhatsApp message per business (prompt `web_pitch_message`). A failed or rejected draft falls back to `web.fallback_template` | `acq.claim_leads_for_web_pitch()` (daily cap), `acq.record_web_pitch()` |
| Sending (you) | Dashboard `/outreach`: edit, **Open in WhatsApp**, send, **Mark as sent** | `acq.mark_manual_sent()` |
| Follow-up | One follow-up becomes due `web.followup_days` later, unless they answered | scheduled by `mark_manual_sent()` |
| Outcome | Record **Interested / Replied / Not interested / Became a client / Asked to stop / Wrong number**. Any answer cancels the follow-up. "Asked to stop" suppresses the number for good | `acq.record_manual_outcome()` |

## Turning it on

Nothing WEB-specific is enabled by default. Clinics without a website still
flow in automatically once workflow 20 runs.

```sql
-- 1. Your portfolio link goes at the end of every pitch.
UPDATE acq.settings SET value = to_jsonb('https://zenvexa.tech'::text)
 WHERE key = 'web.portfolio_url';

-- 2. Free discovery from OpenStreetMap (thin coverage of small Karachi shops).
UPDATE acq.discovery_tasks SET enabled = true
 WHERE offer = 'WEB' AND provider = 'OSM';

-- 3. Google Places finds far more, with the review counts the score uses.
--    Needs the google-places-key credential in n8n.
UPDATE acq.discovery_tasks SET enabled = true
 WHERE offer = 'WEB' AND provider = 'GOOGLE_PLACES';
```

Then activate workflows **10, 20, 25, 45** (and **01**, which 45 calls). 30, 40,
50 and the rest are the Clinibot email pipeline and are not needed for this.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `web.portfolio_url` | empty | Link added to each pitch. Empty means no link at all |
| `web.max_drafts_per_day` | 20 | Hard cap on new drafts per day, enforced in SQL across overlapping runs |
| `web.max_drafts_per_run` | 8 | Drafts per run of workflow 45 |
| `web.message_language` | English with a Roman Urdu greeting | What the draft is written in |
| `web.followup_enabled` / `web.followup_days` | true / 3 | The single follow-up |
| `web.whatsapp_mobile_prefixes` | `["+923"]` | Numbers treated as WhatsApp-capable; others get a call script |
| `web.fallback_template`, `web.followup_template` | see migration 011 | Fixed texts. Placeholders `{{name}}`, `{{area_clause}}`, `{{sender}}`, `{{portfolio_clause}}` |
| `web.adopt_clinics_without_website` | true | Reroute website-less clinics into this pipeline |

Add more categories or areas as rows in `acq.discovery_tasks` with
`offer = 'WEB'`. For OSM, `osm_selectors` is a list of Overpass tag filters
such as `["shop"~"^(bakery|confectionery)$"]`. Workflow 10 refuses any
selector that does not match that shape. For Places, `query_term` is the
search text.

## A daily routine that works

1. Open `/outreach`. Send the follow-ups first; they are at the top.
2. For each new draft, read it and change anything that doesn't sound like
   you. Then **Open in WhatsApp**, send, and **Mark as sent**.
3. Leave a few minutes between messages. Twenty a day is plenty.
4. When someone answers, record it under **Waiting for a reply**.
5. Anyone interested: make the free sample that day. That is the offer.

## What to measure

```sql
SELECT * FROM acq.v_web_overview;

-- Reply rate by category. Kill categories that never answer.
SELECT l.category,
       count(*) FILTER (WHERE m.status = 'SENT' AND m.step_no = 0) AS pitched,
       count(*) FILTER (WHERE l.replied_at IS NOT NULL)            AS replied,
       count(*) FILTER (WHERE l.status IN ('INTERESTED','CUSTOMER')) AS interested
FROM acq.leads l JOIN acq.manual_outreach m ON m.lead_id = l.id
WHERE l.offer = 'WEB'
GROUP BY 1 ORDER BY 2 DESC;
```

## Not built (yet)

- **Email for WEB leads.** A weak site often publishes an email, and the audit
  stores it with provenance, but workflow 40 drafts only Clinibot emails.
  Pitching websites by email needs its own campaign row, prompt and
  follow-up keys, and must go through `claim_send_slots()` like everything
  else.
- **Markets outside Pakistan.** The WEB tasks are seeded for Karachi. Other
  markets stay disabled in `acq.markets` for the consent reasons in
  [10 — Compliance](10-compliance.md).
