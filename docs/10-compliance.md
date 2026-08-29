# Compliance and conduct

Not legal advice. This documents what the system does and the assumptions behind
it, so you can take those assumptions to someone qualified before you rely on
them — particularly before enabling a market outside Pakistan.

## The posture

Section 3 of the brief rules out a list of behaviours. Most of them are not
prevented by intent but by construction, because intent does not survive a
refactor:

| Rule | How it is enforced |
|---|---|
| Never guess an email address | `CHECK` constraint on `acq.leads`; `contact_source` has no `GUESSED` member |
| Never email someone who opted out | `acq.is_suppressed()` consulted in four places; `transition_lead()` refuses to move a suppressed lead toward contact for any actor |
| Never send after an unsubscribe | `apply_opt_out()` cancels queued mail and scheduled follow-ups in the same transaction |
| No thousands of identical emails | One draft per lead from that lead's own research; daily caps in the database |
| No deceptive sender identity | A real mailbox, a real person's name, a real reply-to that is read |
| No misleading subject lines | Guardrails reject `Re:`/`Fwd:` prefixes and hype vocabulary |
| No fake testimonials or claims | `product.capabilities` whitelist; guardrails reject statistics and medical claims |
| No invented clinic information | Facts require a citable URL; inferences are a separate field and may never be stated as fact |
| No circumventing provider limits | Warm-up ramp and caps enforced in SQL, unbypassable from a workflow |
| No aggressive scraping | `robots.txt` honoured, ≤3 pages per site, honest User-Agent, paced requests |
| Stop when told no | `OPT_OUT` beats every other classification, twice — in the prompt and again in code |

## Per-market consent models

`acq.markets.consent_model` carries this, and only Pakistan ships enabled.

### Pakistan — `OPT_OUT_B2B`, enabled

B2B outreach to a business address a clinic has published on its own website or
Google Business Profile. PECA 2016 governs electronic communication; a Personal
Data Protection Bill has been in draft for several years — **check its current
status before scaling**, since passage would change this analysis.

What the system does: identifies the sender, states why it is writing, offers a
working one-click opt-out, honours it immediately and permanently, and contacts
a business address about a business matter.

### UAE — `OPT_IN_REQUIRED`, disabled

Federal Decree-Law 45/2021 (PDPL) plus TDRA rules treat unsolicited marketing
restrictively. **Do not enable without a lawful basis and local advice.** The
market row exists so the geography is configurable, not because it is ready.

### Saudi Arabia — `OPT_IN_REQUIRED`, disabled

PDPL requires a lawful basis for marketing contact. Same position as the UAE.

### United Kingdom — `MIXED`, disabled

The trap here is specific and easy to miss. PECR permits unsolicited B2B email
to **corporate subscribers** — limited companies and LLPs — but treats **sole
traders and partnerships as individuals**, who require prior consent.

A large share of UK private clinics are sole practitioners. So a UK campaign
needs an entity-type filter (Companies House lookup) *before* the send gate, not
after. That filter is not built. Enabling the UK market without it would put you
on the wrong side of PECR for a meaningful fraction of the list.

## Personal data

What is collected: business name, address, phone, published business email,
website, services, practitioner count, and public listing metadata.

What is not: named individuals beyond a professional role at the clinic, patient
information of any kind, anything behind a login, anything from a personal
social profile. The research prompt is instructed to ignore personal
information about named people.

The database also holds inbound replies, which may contain whatever the person
chose to write. Treat `acq.replies` as sensitive.

### Deletion requests

`acq.approval_kind` includes `DELETION_REQUEST`, and the classifier escalates
these to a human — deliberately, because deletion should be a considered act
with a record, not an automated one.

To honour a request:

```sql
-- Suppress FIRST and permanently. This row must survive the deletion, or you
-- will re-discover and re-contact them from the next OSM sweep.
SELECT acq.apply_opt_out('EMAIL', 'them@clinic.pk', 'DELETION_REQUEST', 'MANUAL',
                         '<lead-uuid>'::uuid, '{"requested_at":"…"}'::jsonb);

-- Then remove the lead. Cascades clear contacts, research, emails and replies.
DELETE FROM acq.leads WHERE id = '<lead-uuid>';
```

The order matters. `acq.opt_outs.lead_id` is `ON DELETE SET NULL`, so the
suppression survives on the normalised address.

## AI disclosure

The system does not claim a human wrote the emails, and does not claim an AI
did. That reflects how outbound sales actually works — a human decides the
strategy, approves the message, and answers the reply.

Where it is explicit:

- The prompts forbid claiming a phone call, a visit, a referral, or any prior
  conversation that did not happen.
- Auto-replies are off by default. When enabled they only fire on a draft the
  briefing model judged safe, with no open questions.
- The moment a prospect asks anything requiring judgement, a human is involved.

If a prospect asks directly whether they are talking to a bot, answer honestly.
The classifier routes that to `NEEDS_MORE_INFO` → human, so you will see it.

## Anti-spam essentials

Present in every message:

- **Sender identity** — a real name and brand
- **A postal address** — sending is blocked while `company.postal_address` is
  empty, because most regimes require it
- **A working opt-out** — one click, no login, honoured immediately
- **A truthful subject line** — enforced by guardrails
- **A monitored reply-to** — workflow 60 reads it

## Things to check before scaling

- [ ] Is Zenvexa a registered entity? If not, the postal address must still be
      real and reachable, and you should not imply corporate status you do not
      have.
- [ ] Current status of Pakistan's data protection bill
- [ ] Your email provider's AUP — Zoho and Google both permit legitimate
      business email but prohibit bulk unsolicited mail; the line is volume and
      complaint rate
- [ ] Whether any target market has changed its rules since this was written

## The line that matters most

**Do not do WhatsApp outreach from any account connected to Clinibot.** It
violates the WhatsApp Business Messaging Policy, enforcement is account-level,
and your product is a WhatsApp receptionist. The downside is not a lost channel;
it is the product. See
[the audit, finding 4](00-architecture-audit.md#4-do-not-cold-message-clinics-on-whatsapp-and-especially-not-from-clinibots-waba).
