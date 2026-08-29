# Email deliverability

The one part of this system where a mistake is expensive and slow to undo. A
burned sending domain takes months to recover, and the recovery is mostly
waiting.

## Use a separate domain

`zenvexa.tech` will carry Clinibot's transactional mail — appointment
confirmations, reminders, password resets. **Those must arrive.** Cold outreach,
however careful, attracts some complaints, and reputation is tracked per domain.

Buy an adjacent domain for outbound sales (`zenvexa.co`, `getzenvexa.com`,
`zenvexahq.com`), authenticate it properly, warm it, send from it. If it takes a
hit, product mail is untouched. A subdomain is second best. The same root domain
for both is the option to avoid.

The rest of this document says `sending-domain.tld`; substitute yours.

## DNS records

### SPF

One record, one lookup chain. Copy the `include:` from your provider's docs —
Zoho and Google differ.

```
sending-domain.tld.  TXT  "v=spf1 include:zoho.com ~all"
```

- `~all` (softfail) while warming; move to `-all` (hardfail) once stable.
- **Never publish two SPF records** on one domain — that is a permanent error,
  not a merge.
- Stay under 10 DNS lookups. Each `include:` costs at least one.

### DKIM

Generate the key in your provider's admin console, publish what it gives you.

```
<selector>._domainkey.sending-domain.tld.  TXT  "v=DKIM1; k=rsa; p=MIIBIjANBg…"
```

Use a 2048-bit key. Some DNS hosts require splitting long TXT values into
multiple quoted strings — that is the host's syntax, not two records.

### DMARC

Start in monitoring mode. You want the reports before you enforce anything.

```
_dmarc.sending-domain.tld.  TXT  "v=DMARC1; p=none; rua=mailto:dmarc@sending-domain.tld; fo=1; adkim=r; aspf=r"
```

Progression, over roughly six weeks:

| Week | Policy | Move on when |
|---|---|---|
| 1-2 | `p=none` | Reports show your own mail passing SPF and DKIM |
| 3-4 | `p=quarantine; pct=25` | No legitimate mail quarantined |
| 5-6 | `p=quarantine; pct=100` | Still clean |
| 7+ | `p=reject` | Steady state |

Do not skip to `p=reject`. If alignment is subtly wrong you will silently lose
your own mail, including replies to prospects.

### MX and PTR

Publish your provider's MX records — a sending domain that cannot receive mail
looks like a throwaway, and you need to receive replies and bounces anyway.

Reverse DNS is your provider's responsibility when you send through their SMTP.
Check it only if you ever move to your own MTA, which you should not.

## Verify before sending anything

```bash
./scripts/check_deliverability.sh sending-domain.tld <dkim-selector>
```

It checks SPF (present, single, syntax), DKIM (selector resolves, key present),
DMARC (present, policy, `rua`), MX, and a handful of DNS blocklists. It exits
non-zero if anything required is missing, so it works as a pre-flight gate.

## Warm-up

`acq.warmup_daily_cap()` enforces this in the database. No workflow edit can
bypass it — set `mailboxes.warmup_started_on` and the ramp applies itself.

| Week | Max/day |
|---|---|
| 1 | 5 |
| 2 | 10 |
| 3 | 15 |
| 4 | 25 |
| 5+ | `mailboxes.daily_cap` (40) |

What actually warms a domain is **engagement**, not volume. Five emails that get
two replies do more than fifty that get none. This is another reason the
approval gate ships on: your first hundred emails should be your best hundred.

Do not buy a warm-up service that exchanges mail between fake inboxes. Providers
detect the pattern, and it teaches you nothing about whether your message works.

## Numbers to watch

`SELECT * FROM acq.v_deliverability;` — also in the 18:00 Telegram digest.

| Metric | Healthy | Act at | Stop at |
|---|---|---|---|
| Hard bounce rate | < 1% | 2% | 5% |
| Complaint rate | < 0.05% | 0.1% | 0.3% |
| Reply rate | 3-10% | < 1% | — |

A reply rate under 1% is not a deliverability problem to fix by sending more
carefully — it means the targeting or the message is wrong. Stop and change
those.

The digest raises a warning above 2% bounces and above 0.1% complaints. Both
are worth acting on the same day.

## Bounce handling

Workflow 60 reads bounces off the same IMAP connection as replies.

- **Permanent (`5.x.x`)** — address suppressed via
  `acq.apply_opt_out(..., 'HARD_BOUNCE', ...)`, lead → `BOUNCED`, never
  contacted again by any path.
- **Temporary (`4.x.x`)** — recorded as a `SOFT_BOUNCE` event only. A full
  mailbox or a greylist is not a dead address, and suppressing on it throws away
  good leads.

The distinction is made on the SMTP enhanced status code in the report body, not
on the subject line.

## Unsubscribe

Workflow 110 handles it: one click, no confirmation, no login. The token is 36
random hex characters on the email row, so the URL carries no personal data and
cannot be guessed or enumerated.

**Workflow 50 refuses to send while `unsubscribe.base_url` is unset.** An
opt-out link that does not work is worse than no link at all.

`acq.apply_opt_out()` suppresses the address, cancels every scheduled follow-up
and every queued email, and moves the lead to `OPTED_OUT` — from which
`transition_lead()` will not let any actor return it.

### About `List-Unsubscribe`

Not set, and this is a real limitation rather than an oversight: n8n's SMTP node
cannot add custom headers.

It is acceptable here because one-click unsubscribe headers are a **bulk-sender**
requirement — Gmail and Yahoo enforce them at 5,000+ messages/day, and you are
two orders of magnitude below that. The visible link does the work.

If you ever pass ~1,000/day, that is when to move to a provider whose API
accepts custom headers *and* permits cold outreach. Not before.

## Content

The guardrails in workflows 40 and 80 enforce most of this automatically:

- Plain text, not HTML. A cold email that looks like a newsletter gets filed
  like one.
- **At most one link.** Multiple links is a strong spam signal.
- No tracking pixel. It lowers deliverability, and Apple Mail Privacy Protection
  has made open rates meaningless anyway.
- No attachments, ever.
- No hype vocabulary — the `guardrails.banned_phrases` list.
- 350-1,400 characters.
- A real postal address in the footer. **Sending is blocked while
  `company.postal_address` is empty.**
- A real reply-to that a human reads.

## Pre-flight checklist

- [ ] Separate sending domain registered
- [ ] Mailbox created (Zoho Mail Lite or Google Workspace)
- [ ] SPF published, single record, correct `include:`
- [ ] DKIM key generated and published, 2048-bit
- [ ] DMARC at `p=none` with a `rua` address you read
- [ ] MX published
- [ ] `./scripts/check_deliverability.sh` exits 0
- [ ] `company.postal_address` set to a real address
- [ ] `unsubscribe.base_url` set to the deployed workflow 110 URL
- [ ] Unsubscribe link clicked end-to-end and verified in `acq.opt_outs`
- [ ] `product.capabilities` pruned to what actually ships
- [ ] `mailboxes.warmup_started_on` set to today
- [ ] Sent yourself a test and read it on a phone
- [ ] `outreach.auto_send_enabled` still `false`
