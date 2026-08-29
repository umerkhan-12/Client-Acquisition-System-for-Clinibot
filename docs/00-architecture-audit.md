# Architecture audit

*Written before the implementation, and the reason the implementation looks the
way it does.*

---

## What I could actually inspect

You pointed me at the Clinibot repository. **I could not read it.** `list_repos`
returns 20 repositories under `umerkhan-12` — it does surface private repos, and
Clinibot is not among them — and `add_repo` for `umerkhan-12/Clinibot` returned
an authorization failure. To make it readable in a future session, grant access
at <https://claude.ai/admin-settings/claude-tag>, or reconnect GitHub under
claude.ai → Settings → Connectors.

So this system is designed against your stated stack (NestJS, PostgreSQL,
Next.js, n8n, Gemini, Docker, DigitalOcean) rather than against your code. That
turns out to matter less than it sounds, because the audit's conclusion is that
this system should be **decoupled from Clinibot anyway** — see finding 9. Every
place where it would touch Clinibot is marked in the docs as a seam.

---

## Ten findings that changed the design

### 1. n8n is the wrong place to put the decisions

The obvious build is one big workflow per stage with IF nodes for the logic. It
does not survive contact with production, for a specific reason: **n8n
executions overlap and retry.** A scheduled workflow that takes 12 minutes and
runs every 10 will have two copies running. A node that fails halfway re-runs
from a checkpoint.

Any invariant expressed as "count rows, check a limit, then act" is broken by
that. Two executions both read `sent_today = 18`, both conclude they have budget
for 2 more, and 22 emails go out against a cap of 20. The same applies to
deduplication, to claiming leads, and to "has this lead already been emailed".

**So the deterministic logic lives in SQL**, and n8n calls it. `claim_send_slots`
checks the cap, claims the rows and increments the counter in one transaction.
`upsert_lead` resolves identity and merges in one transaction. `claim_leads` uses
`FOR UPDATE SKIP LOCKED` so overlapping runs take disjoint work instead of
colliding.

This is also why the workflows are small. 178 nodes across 13 workflows, where a
node-centric design would need several hundred — and every one of those would be
a place for the logic to drift.

### 2. The expensive API is Google Places, not Gemini

The brief spends a whole section on controlling Gemini costs. At your volumes
that is not where the money goes.

Rough per-1,000-new-leads figures, **which you must verify against current
published pricing** — Google restructured Maps Platform billing in 2025,
replacing the flat $200/month credit with per-SKU monthly free quotas:

| | Calls | Indicative unit | Indicative cost |
|---|---|---|---|
| Places Text Search | ~200 | ~$32/1k | ~$6 |
| Places Details | ~1,000 | ~$17/1k | ~$17 |
| Gemini (research + email + classify) | ~2,200 | Flash rates | **~$8** |

Gemini is the *cheapest* line. The lever that matters is **not paying for Place
Details on a business you already have.** Places Text Search returns place IDs
cheaply; Details is what costs. So workflow 10 does the dedup check *between*
those two calls, against `acq.lead_identity_keys`.

The effect compounds: month one pays Details on ~everything, month two pays on
only genuinely new listings. Without that ordering you re-pay for your whole
database every cycle.

### 3. Email coverage is the real bottleneck, not lead volume

The pipeline as specified is email-only, and it refuses to guess an address —
correctly. But in Karachi, a large share of private clinics publish a phone and
a WhatsApp number and a Facebook page, and **no email address at all.** Google
Places does not return email under any field mask.

Realistically, expect something like: Places/OSM finds the clinic → maybe 50-60%
have a website → of those, maybe 50-70% publish an email on it. **A plausible
end-to-end yield is 25-40% of discovered clinics being emailable.** I have not
measured this for your specific areas; run Phase 1 and count, because it
determines whether 20 good emails a day is even reachable from your funnel.

Two consequences, both built in:

- Discovery must be broad enough to survive that attrition. The scoring
  thresholds are set so a lead without an email still gets scored and stored —
  it is just never queued for sending.
- Leads with a WhatsApp number but no email are **not** dropped. They sit in the
  database with their research attached, and the dashboard can list them as a
  manual-outreach queue. What the system will not do is message them
  automatically — see finding 4.

### 4. Do not cold-message clinics on WhatsApp, and especially not from Clinibot's WABA

This is the one place where the obvious next step would genuinely hurt you.

Most discovered clinics have WhatsApp and no email. It is very tempting to close
the gap by messaging them there. Do not:

- Unsolicited business-initiated messages to numbers that never opted in violate
  the WhatsApp Business Messaging Policy. Enforcement is account-level.
- **Your product is a WhatsApp receptionist.** If outbound sales gets a number
  or a Business Account restricted, the blast radius is not a sales channel —
  it is Clinibot's ability to function, and potentially your Meta business
  verification.

The asymmetry is brutal: a marginal increase in outreach reach, against an
existential risk to the product. If you ever do WhatsApp outreach, it must be a
completely separate business account, separate number, separate legal entity if
possible — and it still violates the policy.

**Email plus a phone-call queue for the no-email leads is the right shape.**

### 5. Transactional email providers prohibit cold outreach

The instinct is to reach for SendGrid, Postmark, Resend or Brevo. Read their
acceptable-use policies: **Postmark bans cold email outright; SendGrid, Resend
and most transactional ESPs prohibit unsolicited or purchased-list mail.** Using
one for this gets the account terminated, usually mid-campaign, and you lose the
sending history you spent weeks building.

At 20-40 emails/day the correct answer is also the cheapest and the best for
deliverability: **send over SMTP from a real, human mailbox** — the same thing a
salesperson does. Zoho Mail Lite is about $1/user/month with IMAP and SMTP;
Google Workspace is ~$6-7 if you prefer it.

This has a real limitation, documented rather than hidden: n8n's SMTP node
cannot set custom headers, so you **cannot** add `List-Unsubscribe` /
`List-Unsubscribe-Post`. At your volume that is acceptable — one-click
unsubscribe headers are a bulk-sender requirement (Gmail/Yahoo enforce at
5,000+/day) and you are two orders of magnitude below it. The visible
unsubscribe link in every body is what does the work. If you ever scale past
~1,000/day, that is the moment to move to a provider that permits cold outreach
and supports the header, not before.

### 6. Send from a different domain than the product

`zenvexa.tech` will eventually carry Clinibot's transactional mail: appointment
confirmations, reminders, password resets. Those must arrive.

Cold outreach, done carefully, still attracts some spam complaints. Reputation
is tracked per domain and, to a degree, per organisational domain.

**Use a separate domain for outbound sales.** Buy something adjacent
(`zenvexa.co`, `getzenvexa.com`), authenticate it properly, warm it, and send
from there. If it takes a reputation hit, product mail is unaffected. A
subdomain is second-best; the same root domain is the option to avoid.

### 7. AI should supply the signals, not the score

The brief asks for AI lead scoring, 0-100, configurable. I built it slightly
differently, deliberately.

A model asked for a number gives a plausible one, and it is not reproducible,
not explainable after the fact, and not re-tunable — change your mind about how
much WhatsApp matters and you must re-run every lead through the model to find
out what it would say now.

So: **`acq.compute_score()` owns the arithmetic**, reading weights from a
versioned config row. The AI's job is to decide which *signals* are present,
each backed by a cited fact. Consequences:

- Every score decomposes into a stored breakdown you can read.
- Re-tuning is one `UPDATE` to the weights, then re-score from cached research —
  no new AI spend at all.
- Two clinics with identical signals always get identical scores.

The `score_lead` prompt exists and is production-ready; it returns signals,
disqualifiers and a fit tier rather than a number.

### 8. Ship with the human approval gate ON

The brief wants autonomy, and also says "I would rather send 20 highly relevant
emails than 500 generic ones". Those pull in opposite directions at the start,
because you have no evidence yet about draft quality.

`outreach.auto_send_enabled` ships **false**. Every draft lands in
`READY_FOR_REVIEW` with a Telegram card. Approve or reject a few dozen; when the
rejection rate is near zero, flip it to true. From then on the gate only catches
low-confidence drafts.

This costs a week of your attention and buys the thing you cannot buy back: a
sending domain that was never used to send something embarrassing.

### 9. Do not put sales data in Clinibot's database

Clinibot handles patient conversations. Whatever its exact data model, it is in
the neighbourhood of health information.

Putting prospecting data in the same database means every acquisition-system
credential, every n8n node, and every dashboard query lives inside that blast
radius, for no benefit — the two systems share no entities. A lead is not a
patient, a clinic prospect is not a tenant.

**Same Postgres server, separate database, separate role.** Cheap, one line of
config, and it means an n8n credential leak cannot reach patient data. The
schema is namespaced `acq` so it also works as a schema inside an existing
database if you insist, but the separate database is the right call.

### 10. OpenStreetMap is a genuine $0 path — with a specific weakness

Overpass is free and unmetered (within fair use), and Karachi's OSM coverage of
`amenity=clinic` / `doctors` / `dentist` is decent. That makes a true $0
development phase possible: OSM discovery, Gemini free tier, MailHog for
sending, local Postgres.

The weakness is specific: OSM in Pakistan **rarely records
`healthcare:speciality`**. So OSM finds you dentists and general clinics, but is
close to useless for "dermatology clinics in Clifton". Google Places is what you
need for specialty targeting, and specialty clinics are your highest-value
segment.

Hence the seeding: 13 OSM tasks enabled (one per area — one Overpass call
returns every healthcare POI, so splitting by category would issue the same call
eight times), and 80 Places tasks seeded but **disabled** until you add a key.

---

## The cheapest reliable approach

> **Free discovery, paid discovery only where it pays, one real mailbox, and the
> database as referee.**

| Concern | Choice | Why |
|---|---|---|
| Discovery | OSM/Overpass first; Places for specialties | $0 covers ~60% of the need |
| Dedup | Postgres identity keys, before paid calls | The single biggest cost lever |
| Research | Gemini Flash, cached 90 days | Cheapest line item; caching makes it cheaper |
| Scoring | SQL, config-driven | Free, explainable, re-tunable with no AI spend |
| Sending | Real mailbox over SMTP, ~$1/mo | Correct for volume; ESPs would ban it |
| Receiving | IMAP idle | No webhook infrastructure needed |
| Email verify | Cloudflare DNS-over-HTTPS MX check | Free, no account, prevents most bounces |
| Notifications | Telegram Bot API | Free, instant, works on a phone |
| Booking | Cal.com free tier | Webhook lands in workflow 100 |
| Hosting | Second n8n container beside Clinibot's | Marginal cost ~$0 |

**Steady-state running cost at ~500 leads/month: under $20.** Full breakdown in
[07-costs.md](07-costs.md).

---

## What I deliberately did not build

- **WhatsApp outreach.** Finding 4.
- **Open tracking pixels.** They lower deliverability, are increasingly
  meaningless (Apple Mail Privacy Protection pre-fetches them), and at 20/day
  you learn more from replies. The schema records `OPENED` events so a provider
  can supply them later.
- **A UI for editing scoring weights.** It is one `UPDATE` to a JSONB column.
- **Automatic re-engagement beyond one bounded revisit.** `LATER` schedules one
  revisit at least 30 days out. Anything more is a fourth follow-up wearing a
  disguise.
- **Auto-replies on by default.** Drafted, notified, sent only if you enable it.

---

## Three things that will bite you, in order

1. **`company.postal_address` is empty**, and workflow 50 refuses to send until
   you fill it. That is intentional: most anti-spam regimes require a real
   postal address in commercial email. Set it before Phase 3.
2. **`product.capabilities` currently lists everything from your brief**,
   including the three you described as "potentially" available. Every line in
   that list *will* be claimed to real clinics. Prune it before the first send —
   `acq.settings` key `product.capabilities_unverified` flags the three to check.
3. **The area centroids in the seed are approximate.** They are search centres,
   not business data, but a wrong one wastes a discovery cycle. Check them on a
   map before Phase 1.
