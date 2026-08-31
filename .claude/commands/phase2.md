---
description: Phase 2 — research and drafting with AI. Still sends nothing.
---

Phase 2 from `docs/09-build-order.md`. First AI spend. **Nothing leaves the
building.**

## Preconditions

- Phase 1 is done and you know the emailable percentage. If you do not, run
  `/phase1` first — Phase 2 costs money and Phase 1 tells you whether to spend
  it.
- `acq.readiness()` shows no `BLOCKER` on `ai.pricing`.

## Settings before activating anything

```sql
UPDATE acq.settings SET value = '0.50'::jsonb WHERE key = 'ai.daily_cost_cap_usd';
UPDATE acq.settings SET value = 'true'::jsonb WHERE key = 'outreach.dry_run';
-- confirm, do not assume:
SELECT key, value FROM acq.settings
 WHERE key IN ('outreach.auto_send_enabled','outreach.dry_run','ai.model','ai.daily_cost_cap_usd');
```

`outreach.auto_send_enabled` must be `false`. It ships false.

### The cost cap only works if the model has a price

```sql
SELECT severity, detail FROM acq.readiness() WHERE check_name = 'ai.pricing';
```

An unpriced model is costed at $0.00 forever, so `ai.daily_cost_cap_usd` never
trips and there is no brake at all. This bites specifically when copying the
Clinibot droplet's pinned `GEMINI_MODEL`, which is not in the default pricing
table. Add the rate from ai.google.dev/pricing before continuing.

## Check the claim whitelist

Migration 009 rebuilt `product.capabilities` from the Clinibot source, so it no
longer needs pruning — but **re-read it if the product has changed since**:

```sql
SELECT jsonb_array_elements_text(value) FROM acq.settings WHERE key = 'product.capabilities';
SELECT jsonb_array_elements_text(value) FROM acq.settings WHERE key = 'product.not_yet';
```

Every line in the first list is asserted to a real clinic as fact. Anything you
cannot point at working code for, remove.

Also set `company.postal_address` now — the send path refuses without it.

## Activate

**ACQ 01**, **ACQ 30**, **ACQ 40**. Nothing else.

## Read the output like a reviewer, not an owner

```sql
SELECT l.clinic_name, r.confidence, r.pain_point,
       jsonb_array_length(r.facts) AS facts, r.relevance_reason
FROM acq.lead_research r JOIN acq.leads l ON l.id = r.lead_id
WHERE r.is_current ORDER BY r.created_at DESC LIMIT 20;

SELECT clinic_name, subject, body_text, ai_confidence, personalization_reason
FROM acq.emails e JOIN acq.leads l ON l.id = e.lead_id
ORDER BY e.created_at DESC LIMIT 20;
```

Two questions, and answer them honestly:

1. **Open five cited URLs.** Is each "fact" actually on the page? A fabricated
   fact in a cold email is unrecoverable — it is the one error the recipient can
   verify instantly.
2. **Would you send this exact email to this exact clinic?**

Iterate on `prompts/03_email_personalize.md`, bump `version:` in the
frontmatter, reload with `python3 scripts/load_prompts.py | psql -d <db>`.

## Done when

You would personally send **8 of 10** drafts unchanged.

If not, the prompt is not ready, and no amount of infrastructure fixes that.
Say so rather than proceeding — Phase 3 is the irreversible one.
