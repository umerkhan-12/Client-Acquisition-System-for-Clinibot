---
description: Phase 2 — research and draft emails, still sending nothing
---

Run Phase 2 from `docs/09-build-order.md`. First AI spend. **Nothing leaves the
building in this phase.**

Preconditions — verify each and stop if any fails:
- Phase 1 done and I am happy with the leads.
- `outreach.dry_run = true`
- `outreach.auto_send_enabled = false`
- `ai.daily_cost_cap_usd` set low (start at `0.50`)
- A Gemini API key exists as the `gemini-api-key` credential.

**Before any AI call, make me prune the claim whitelist.** Show me:

```sql
SELECT jsonb_pretty(value) FROM acq.settings WHERE key = 'product.capabilities';
SELECT jsonb_pretty(value) FROM acq.settings WHERE key = 'product.capabilities_unverified';
```

Every line in `product.capabilities` will be asserted to real clinics. Ask me,
line by line, whether each is shipped and working in Clinibot today. Remove the
ones that are not. Do not skip this.

Also set `company.postal_address` to a real, reachable address.

Then activate workflows 01, 30 and 40, let them run, and show me the output as a
reviewer would read it:

```sql
SELECT l.clinic_name, r.confidence, r.pain_point, r.relevance_reason,
       jsonb_array_length(r.facts) AS facts
FROM acq.lead_research r JOIN acq.leads l ON l.id = r.lead_id
WHERE r.is_current ORDER BY r.created_at DESC LIMIT 15;

SELECT l.clinic_name, e.subject, e.body_text, e.ai_confidence,
       e.personalization_reason
FROM acq.emails e JOIN acq.leads l ON l.id = e.lead_id
ORDER BY e.created_at DESC LIMIT 10;
```

For five of the research rows, open the cited `evidence_url` and tell me whether
the "fact" is actually supported by that page. Report honestly — a fabricated
fact here becomes a false claim in an email to a real clinic.

Then ask me the only question that matters: **would I send each of these ten
emails myself, unchanged?** If fewer than eight, the prompt is not ready.
Propose specific edits to `prompts/03_email_personalize.md`, bump its version,
reload, and regenerate. Iterate until I say yes.

Do not proceed to Phase 3.
