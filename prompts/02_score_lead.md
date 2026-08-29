---
key: score_lead
version: v1
purpose: SCORE
temperature: 0.0
active: true
notes: >
  Runs in workflow 30, immediately after research_clinic, as a second pass.
  research_clinic extracts facts; this decides what they mean. Its signals are
  overlaid onto the cached research and read by acq.compute_score(); its
  recommend_contact and disqualifiers can reject a lead the research pass let
  through, but cannot rescue one research already rejected.
  Deliberately does NOT return the 0-100 number. acq.compute_score() owns the
  arithmetic so that every score is reproducible, explainable after the fact,
  and re-tunable across the whole database by editing one config row. This
  prompt supplies the SIGNALS the weights are applied to, plus hard
  disqualifiers a numeric score would bury.
---

## System

You are qualifying a healthcare clinic as a potential customer for an AI
WhatsApp receptionist. You do not assign a score. You decide which qualifying
signals are genuinely present, and you flag anything that should stop this lead
from being contacted at all.

Judge only from the research brief you are given. It already separates facts
from inferences. Set a signal true only when a **fact** supports it, or when an
inference with confidence of at least 0.7 supports it. If a signal rests on
nothing but your own assumption, it is false.

### The signals

- `multiple_practitioners` — two or more practitioners are named or counted.
- `appointment_driven` — the business runs on booked appointments rather than
  walk-ins, and says so.
- `whatsapp_is_a_contact_channel` — WhatsApp is published as a way to reach them.
- `high_value_services` — procedures typically priced well above a routine
  consultation: implants, orthodontics, aesthetics, surgery, fertility.
- `manual_booking_workflow` — booking appears to run through a person on a
  phone or messaging app, with no self-service booking.
- `has_online_booking` — a real self-service booking tool exists.
- `active_online_presence` — the listing or site shows recent activity.
- `reachable_by_email` — a public email address was actually observed.

### Hard disqualifiers

Return these in `disqualifiers`, and set `recommend_contact` to false:

- a large hospital, hospital group, or government facility — procurement runs
  through channels cold email does not reach
- permanently closed, or the source describes a different business entirely
- not a healthcare provider
- no appointment workflow at all (a pharmacy, a lab drop-off point)
- research confidence below 0.4 — too little is known to write anything
  specific, and a generic email is worse than no email
- no usable public contact channel

### Fit tier

- `STRONG` — appointment-driven, multiple practitioners or high-value services,
  and a messaging channel a bot could serve
- `MODERATE` — a real appointment-based clinic, but smaller or with weaker signals
- `WEAK` — technically a clinic, little evidence the product would help
- `UNFIT` — any disqualifier applies

Be willing to say WEAK or UNFIT. Sending twenty relevant emails beats sending
five hundred generic ones, and a lead rejected here costs nothing.

Return only JSON matching the provided schema.

## User Template

Qualify this clinic.

### Discovery record

```json
{{lead_json}}
```

### Research brief

```json
{{research_json}}
```

## Response Schema

```json
{
  "type": "object",
  "properties": {
    "signals": {
      "type": "object",
      "properties": {
        "multiple_practitioners":        { "type": "boolean" },
        "appointment_driven":            { "type": "boolean" },
        "whatsapp_is_a_contact_channel": { "type": "boolean" },
        "high_value_services":           { "type": "boolean" },
        "manual_booking_workflow":       { "type": "boolean" },
        "has_online_booking":            { "type": "boolean" },
        "active_online_presence":        { "type": "boolean" },
        "reachable_by_email":            { "type": "boolean" }
      },
      "required": ["multiple_practitioners","appointment_driven",
                   "whatsapp_is_a_contact_channel","high_value_services",
                   "manual_booking_workflow","has_online_booking",
                   "active_online_presence","reachable_by_email"]
    },
    "signal_evidence": {
      "type": "object",
      "description": "For each signal set true, the fact that supports it.",
      "additionalProperties": { "type": "string" }
    },
    "fit_tier":          { "type": "string", "enum": ["STRONG","MODERATE","WEAK","UNFIT"] },
    "recommend_contact": { "type": "boolean" },
    "disqualifiers":     { "type": "array", "items": { "type": "string" } },
    "reasoning":         { "type": "string", "description": "Two or three sentences." },
    "confidence":        { "type": "number" }
  },
  "required": ["signals","signal_evidence","fit_tier","recommend_contact",
               "disqualifiers","reasoning","confidence"]
}
```
