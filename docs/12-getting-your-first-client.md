# Getting your first client

Everything else in `docs/` describes the machine. This describes the part of the
job the machine cannot do, and what it actually produces if you run it properly.

Read [09-build-order.md](09-build-order.md) for the phase gates. This is the
layer above: what to buy, what to decide, and what to expect.

---

## The setup you have to do yourself

About $25 and an afternoon. None of it is optional, and none of it can be
automated from inside this repo.

| # | Thing | Cost | Why it cannot be skipped |
|---|---|---|---|
| 1 | A **separate sending domain** | ~$12/yr | If cold mail is sent from `zenvexa.tech` and the domain gets filtered, Clinibot's own transactional mail to real clinics goes with it. Buy something adjacent — `zenvexa.co`, `getclinibot.com`. This is the single highest-value $12 here. |
| 2 | A **Zoho Mail mailbox** on that domain | ~$1/mo | SMTP + IMAP. Workflow 60 reads replies over IMAP; there is no other inbox. |
| 3 | **SPF, DKIM, DMARC** | free | Without all three, a meaningful share of mail lands in spam and you will misread a deliverability problem as a message problem — and rewrite good copy for weeks. |
| 4 | A **Gemini API key** | ~$2-5/mo at this volume | Research, scoring, drafting, reply classification. |
| 5 | A **Google Places key** | free tier is enough | Discovery. Phase 1 uses this and nothing else. |
| 6 | A **Telegram bot + chat id** | free | Where hot leads and errors land. Without it, an interested clinic waits while nobody notices. |
| 7 | A **Cal.com booking link** | free | `demo.booking_url`. Every email asks for a demo; without a link the reply has nowhere to go. |
| 8 | A **droplet** | ~$12/mo | See [08-deployment.md](08-deployment.md). |

Verify 3 with `./scripts/check_deliverability.sh` before sending anything. It
exists because SPF/DKIM/DMARC failures are invisible from the sending side.

---

## The one decision no code can make for you

`product.capabilities` is the list of things the AI is allowed to say about
Clinibot. Every line is asserted to a real clinic as fact.

Migration 009 replaced the original brief-derived list with one checked
line-by-line against `clinibot-backend/src`. Three lines were wrong; one badly:

> **"Can collect an appointment fee before confirming a booking."**
>
> Clinibot does not collect money. `payments.service.ts` records what a patient
> *claims* they sent, for a human at the desk to verify against the clinic's own
> account, and deliberately never changes the appointment's status. The clinic
> is the merchant throughout.
>
> A clinic that books a demo because it thinks you handle payments finds out in
> the demo. That is the worst possible moment.

**Re-check that list whenever the product changes.** It is the difference
between a demo that confirms what the email promised and one that walks it back.

The counterpart is `product.not_yet` — the honest answers to "can it do X?".
It feeds `06_hot_lead_brief`, so when a clinic asks, the brief on your phone
tells you the true answer *before* you reply, instead of leaving you to
improvise.

---

## What the funnel actually produces

```
1,000 clinics discovered
  ↓  ~25-40% publish a usable email address   ← Phase 1 measures this
  200-400 worth writing to
  ↓  20 emails/day inside deliverability limits
  ↓  3-10% reply rate on genuinely specific mail
  6-40 replies
  ↓  roughly half are positive
  3-20 interested
  ↓
  2-8 demos  →  1-2 paying clinics
```

**Four to eight weeks** from working system to first paying clinic. The number
that decides everything is the emailable share in Phase 1 — measure it before
building anything on top.

If it comes in **well under 25%**, an email-only pipeline starves in Karachi.
The fix is a phone queue: export WhatsApp-only clinics and have a human work
them. Do **not** automate WhatsApp outreach — it would put the Meta account
Clinibot's own transport depends on at risk, and that transport is already
[the product's largest single point of failure](../../clinibot/ARCHITECTURE.md).

### Why 20/day and not 200

The reply rate carries this entire funnel, and it collapses the moment the
emails stop being specific. A couple of hundred good emails beat two thousand
mediocre ones, and the mediocre ones cost you the domain as well.

---

## What this system does not do

It does not close.

It finds the right clinics, writes to each one about *that clinic*, protects
your domain, stops instantly when someone asks it to, and puts the interested
ones on your phone with enough context to walk into the conversation.

When a clinic replies "show me" — the demo, the pricing answer, the ask for the
business — that is you. That is the trade the whole design makes: fewer, better
conversations. It is also why sending ships switched off.

---

## First-week sequence

1. `./scripts/bootstrap.sh acq_test` — everything green before anything real.
2. Buy the domain, mailbox, DNS records. `./scripts/check_deliverability.sh`.
3. Provision and deploy the droplet ([08](08-deployment.md)).
4. **Phase 1 only.** Discovery. No AI, no email. Measure the emailable share.
5. Decide, from that number, whether the funnel supports 20 emails/day.
6. Phase 2: research and drafting, sending still off. Read twenty drafts
   yourself. If they are not specific, fix the prompt, not the volume.
7. Phase 3: send, one approved email at a time.

Do not skip 4. Every later decision depends on the number it produces, and it
costs nothing but a day.
