---
description: Phase 1 — discovery only. No AI, no email. Measures the number that decides everything.
---

Run Phase 1 from `docs/09-build-order.md`. **No AI calls and no email in this
phase.** Only workflows 00, 10 and 20 may be active.

Before starting, confirm with me:
- The database exists and `./scripts/bootstrap.sh` passed.
- n8n is running and the 13 workflows are imported.
- The `acq-postgres` credential is set on every flagged node.

Then:

1. **Check the search areas are real.** `acq.discovery_tasks.bbox` holds
   approximate Karachi area centroids that I have not verified. Show me each
   area with its lat/lng and radius, and flag any that look wrong for the
   neighbourhood named. Correct the ones I confirm.

2. **Activate workflows 00, 10, 20 only.** Confirm 30–110 are inactive. If any
   AI or send workflow is active, stop and tell me.

3. **Run discovery a few times** and let qualification follow.

4. **Report the number that decides the project:**

```sql
SELECT city, area, category, count(*) AS found,
       count(*) FILTER (WHERE website IS NOT NULL)      AS with_website,
       count(*) FILTER (WHERE public_email IS NOT NULL) AS with_email,
       round(100.0 * count(*) FILTER (WHERE public_email IS NOT NULL) / count(*), 1) AS pct_emailable,
       round(avg(lead_score)) AS avg_score
FROM acq.leads GROUP BY 1,2,3 ORDER BY 4 DESC;
```

Tell me the overall emailable percentage. My estimate was 25–40%. If it is far
below that, say so plainly — it means the email-only pipeline will starve, and
we should discuss enabling Google Places or building a phone-outreach queue
before writing a single email.

5. **Spot-check 20 leads by hand.** Are they real clinics? Right category? Show
   me a sample with `source_url` so I can click through.

6. Tell me whether the scoring is ranking sensibly, and propose weight changes
   to `acq.scoring_configs` if not. Do not change them without asking.

Do not proceed to Phase 2. Stop and report.
