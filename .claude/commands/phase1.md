---
description: Phase 1 — discovery only, no AI and no email. Measure the emailable share.
---

Phase 1 from `docs/09-build-order.md`. **No AI. No email.** You are answering
one question: does the funnel produce enough real Karachi clinics with usable
email addresses to justify building the rest?

## Preconditions — check, and stop if unmet

- `acq.readiness()` has no `BLOCKER` rows other than `company.postal_address`
  and `unsubscribe.base_url`. Those two only gate *sending*, and nothing sends
  in Phase 1, so they are fine to leave for now.
- At least one row in `acq.markets` is enabled, and one in
  `acq.discovery_tasks`.

## Before running discovery

**Check the seeded search areas against a map.** They were seeded by hand, and
a wrong bounding box searches the wrong part of Karachi — producing plausible,
useless leads that cost real API calls to find.

Geography lives on `acq.discovery_tasks` (`city`, `area`, `bbox`), not on
`acq.markets`, which carries country-level policy:

```sql
SELECT t.city, t.area, t.query_term, t.category, t.provider,
       t.priority_tier, t.bbox, t.cadence_days, t.next_run_at
FROM acq.discovery_tasks t
JOIN acq.markets m ON m.id = t.market_id
WHERE t.enabled AND m.enabled
ORDER BY t.priority_tier, t.city, t.area;
```

## Run it

Activate **ACQ 00**, **ACQ 10**, **ACQ 20** in n8n. Nothing else. Let discovery
run a few cycles.

## Then measure — this is the point of the phase

```sql
SELECT city, area, category, count(*),
       count(*) FILTER (WHERE public_email IS NOT NULL) AS with_email,
       count(*) FILTER (WHERE website IS NOT NULL)      AS with_website,
       round(avg(lead_score))                           AS avg_score
FROM acq.leads GROUP BY 1,2,3 ORDER BY 4 DESC;
```

**Report `with_email` as a percentage of total.** State it prominently. It
decides the project:

- **Above ~25%** — the funnel supports 20 emails/day. Continue to `/phase2`.
- **Well under 25%** — an email-only pipeline starves in Karachi. Say so
  directly. The fix is a phone queue for WhatsApp-only clinics worked by a
  human. **Do not propose automated WhatsApp outreach** — it would risk the
  Meta account Clinibot's own patient transport depends on, which is already
  that product's largest single point of failure.
- **Too few leads overall** — enable Google Places now, not later.

## Spot-check by hand

Pull 20 leads and read them. Are they real clinics? Right category? Not
hospitals or pharmacies?

```sql
SELECT clinic_name, category, website, public_email, lead_score
FROM acq.leads ORDER BY lead_score DESC LIMIT 20;
```

If the ranking looks wrong, tune `acq.scoring_configs.weights` — a JSONB row.
Re-scoring costs no AI.

## Done when

100+ deduplicated leads, and you believe the top-scoring ones.

Report the emailable percentage, the lead count, and your read on lead quality.
Do not move to Phase 2 without stating that number.
