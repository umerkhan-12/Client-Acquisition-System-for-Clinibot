# Getting your first client

What to type, what only you can do, and what the funnel actually produces.

---

## What to type in Claude Code

Open the repo in VS Code, run `claude` in the terminal, and use these. They live
in `.claude/commands/` and are real slash commands, not suggestions.

| Command | What it does |
|---|---|
| `/status` | Where the system stands, from the data rather than from memory |
| `/verify` | Runs every check in the repo and reports what passes |
| `/phase1` | Discovery only. No AI, no email. Produces the number that decides everything |
| `/phase2` | Research and drafting, still sending nothing |
| `/phase3` | The first real emails, approved one at a time |
| `/phase4` | Replies, follow-ups, hot-lead alerts, demo booking |
| `/phase5` | Hand more of the loop to the system |
| `/daily` | The two-minute operator check |

Start with `/status`. It will tell you which phase you are actually in.

The phase commands are deliberately gated: each one checks its preconditions and
stops rather than running ahead. `/phase3` in particular will refuse to send
until the deliverability checks pass and you have clicked your own unsubscribe
link.

---

## What Claude Code cannot do for you

These need a card, an identity, or a decision. Nothing in the repo works until
they exist.

| | Why it has to be you | Rough cost |
|---|---|---|
| **Buy a sending domain** | Separate from `zenvexa.tech`, so a reputation hit never touches Clinibot's transactional mail | ~$12/year |
| **Create the mailbox** | Zoho Mail Lite gives IMAP + SMTP. Do not use a transactional ESP — Postmark bans cold email outright and most others prohibit it | ~$1/month |
| **Publish SPF, DKIM, DMARC** | DNS records on a domain you own. `./scripts/check_deliverability.sh` verifies them | free |
| **Get a Gemini API key** | Google account, billing | free tier is enough to start |
| **Get a Google Places key** | Only if OSM coverage proves too thin in Phase 1 | ~$20/month at 1,000 leads |
| **Create a Telegram bot** | @BotFather, then read your chat id | free |
| **Set up Cal.com** | So the AI can offer a real booking link instead of inventing times | free tier |
| **A real postal address** | Required in commercial email in most jurisdictions. Sending is blocked until it is set | — |
| **Decide what Clinibot actually does today** | `product.capabilities` currently lists everything from the brief, including three features described as only "potentially" available. Every line will be asserted to real clinics | — |

That last one is not administrative. It is the single most consequential thing
you will do in this project, and no amount of code can do it for you.

---

## What the funnel actually produces

Rough arithmetic, so the timeline is not a surprise. These are estimates, and
Phase 1 replaces the first one with a measurement.

```
  1,000 clinics discovered          Karachi tier-1 areas, OSM + Places
      ↓  ~25-40% publish an email   ← Phase 1 measures this. It decides everything.
    300 emailable
      ↓  score + research gates
    200 worth writing to
      ↓  20/day, ramping from 5
     10 working days of sending
      ↓  3-10% reply rate
   6-20 replies
      ↓  roughly a third are positive
    3-8 genuinely interested
      ↓
    2-5 demos booked
      ↓
    1-2 customers
```

**So: plan on four to eight weeks from a working system to a first paying
clinic**, and on needing a couple of hundred good emails to get there. Not two
thousand mediocre ones — the reply rate is what carries this, and it collapses
the moment the emails stop being specific.

If Phase 1 shows the emailable share is far below 25%, the honest read is that
an email-only pipeline will starve in Karachi. The fix then is a phone-outreach
queue for the WhatsApp-only clinics, worked by a human. **Not** automated
WhatsApp messaging — see `docs/00-architecture-audit.md`, finding 4.

---

## What this system does and does not do

It does the repetitive work: finding clinics, deduplicating them across sources,
researching each one from its own public pages, scoring them against weights you
control, writing one email per clinic from that clinic's verified facts, sending
inside limits that protect your domain, reading every reply, stopping the moment
someone says no, and putting the interested ones on your phone with the context
you need.

It does not close. When a clinic replies "yes, show me", a person has to run that
demo, answer the pricing question, and ask for the business. The system's job is
to make sure that conversation happens with the right clinic, at the right
moment, with everything you need to walk into it — and to make sure the other
several hundred never feel spammed.

That is the trade the whole design makes: fewer, better conversations. It is also
why `outreach.auto_send_enabled` ships `false`. The first hundred emails should
be the best hundred, because they are the ones that teach you whether the message
works at all.
