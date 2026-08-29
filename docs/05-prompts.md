# AI prompts

Six prompts, in `prompts/*.md`. They are the **source of truth**; the database
is a deployment target.

```bash
python3 scripts/load_prompts.py | psql -v ON_ERROR_STOP=1 -d zenvexa_acq
```

## Why they live in the database

Editing a prompt is the thing you will do most often, and it should not require
exporting a workflow, finding a string inside a node, editing it, and
re-importing. `acq.prompts` holds them; `acq.get_prompt(key)` returns the system
prompt, user template, response schema and temperature in one call.

Every generated artefact records the `prompt_version` that produced it —
`lead_research.prompt_version`, `emails.prompt_version`,
`reply_classifications.prompt_version` — so a quality regression can be traced
to the exact text that caused it. A partial unique index enforces one active
version per key, so promoting v2 is one transaction and rolling back is another.

## The six

| File | Keys | Purpose | Temp |
|---|---|---|---|
| `01_research_clinic.md` | `research_clinic` | Facts vs inferences, pain point, signals | 0.15 |
| `02_score_lead.md` | `score_lead` | Qualifying signals + hard disqualifiers | 0.0 |
| `03_email_personalize.md` | `email_initial` | First-contact email | 0.55 |
| `04_classify_reply.md` | `classify_reply` | 11-class reply classification | 0.0 |
| `05_followup_generate.md` | `followup_1_value`, `followup_2_different_angle`, `followup_3_breakup` | Step-aware follow-ups | 0.6 |
| `06_hot_lead_brief.md` | `hot_lead_brief` | The notification you read on a phone | 0.2 |

## Structural choices that matter

### Facts and inferences are separate fields, not separate paragraphs

`research_clinic` returns `facts[]` — each with `claim`, `evidence_url` and a
supporting `quote` — and `inferences[]` — each with `claim`, `basis` and its own
`confidence`. Downstream, the email prompt is told it may **let an inference
shape which capability to lead with, but never state one as though it were
known**. Because they are different fields, that instruction is enforceable
rather than aspirational.

### The claim whitelist

`product.capabilities` in `acq.settings` is injected into every generation
prompt as `{{capabilities}}`, with the instruction that nothing outside the list
may be claimed. This is what stops the model inventing integrations,
certifications, customer counts or results.

**Prune it before your first send.** Every line in it will be asserted to real
clinics. `product.capabilities_unverified` flags the three items your brief
described as only "potentially" available.

### Scoring returns signals, not a number

`score_lead` deliberately returns booleans, evidence for each, a fit tier and
disqualifiers. `acq.compute_score()` does the arithmetic. See
[the audit, finding 7](00-architecture-audit.md#7-ai-should-supply-the-signals-not-the-score).

It runs in workflow 30 as a **second pass over the research brief**, not over
raw web pages. Splitting extraction from judgement matters: a prompt asked to
both find facts and decide whether to contact someone starts promoting its
inferences to facts, because that makes the decision easier to justify.

Its signals are overlaid onto the cached research under the same keys
`compute_score()` already reads, and the full verdict is kept in
`lead_research.raw.qualification` so a score can be explained months later. The
pass can only ever be **more** restrictive than research: `recommend_contact:
false` or any disqualifier rejects the lead, and a `WEAK` fit tier sends it to
human review — but it cannot rescue a lead research already rejected.

If the call fails, the research verdict stands and no signals are patched. The
lead proceeds on weaker evidence rather than being silently approved.

### Opt-out beats everything in classification

`classify_reply` is instructed that any removal request makes the class
`OPT_OUT` regardless of what else the message contains, in any language, and
that when torn it must choose `OPT_OUT`. Workflow 70 then enforces it a second
time in code: if `opt_out_signal_detected` is true, the class becomes `OPT_OUT`
whatever the model actually chose.

Two layers, because the asymmetry is stark — a wrongly suppressed lead costs one
prospect; the reverse costs a complaint and a damaged domain.

### The follow-up prompt knows how follow-ups fail

Explicit bans on "just following up", "circling back", "in case you missed it",
guilt ("I haven't heard back"), and false urgency. Step 3 is a genuine breakup
email: no new offer, no discount, no final-chance hook. Workflow 80's guardrails
check for each of these in the output, plus whether the first sentence repeats a
previous email.

### Confidence is used, not decorative

Every prompt returns `confidence`, and each is wired to a real consequence:

| Prompt | Threshold | Consequence |
|---|---|---|
| `research_clinic` | < 0.4 | Lead → `READY_FOR_REVIEW`, no email written |
| `research_clinic` | < 0.6 | AI signals excluded from the blended score |
| `email_initial` | < `ai.min_email_confidence` | Draft → human approval |
| `classify_reply` | < `ai.min_classification_confidence` | Reply → human |

## Editing a prompt

1. Edit the file in `prompts/`.
2. Bump `version` in its frontmatter (`v1` → `v2`).
3. `python3 scripts/load_prompts.py | psql -d zenvexa_acq` — the loader
   deactivates the old version and activates the new one.
4. Watch `acq.emails.prompt_version` to compare outcomes between versions.

Rolling back:
```sql
UPDATE acq.prompts SET active = (version = 'v1') WHERE key = 'email_initial';
```

## The JSON contract

Section 25 of the brief, implemented in workflow 01:

1. Gemini is called with `responseMimeType: application/json` and the prompt's
   `responseSchema`.
2. The response is parsed and checked against the schema's own `required` list.
   A truncated response (`finishReason: MAX_TOKENS`) is invalid even if it
   happens to parse.
3. On failure: **one** retry, at temperature 0, showing the model the exact
   rejection reason. A corrective retry fixes far more than a repeated one.
4. Still invalid → log to `acq.ai_calls`, write a dead letter, return
   `ok: false`. **No email is sent.**
