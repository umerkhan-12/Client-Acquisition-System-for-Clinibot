# Build order

Six phases. Each ends with something working that you can judge, and nothing
reaches a real clinic until Phase 3.

The ordering principle: **the last thing you switch on is the thing that is
hardest to undo.** Sending is irreversible; everything before it is not.

---

## Phase 0 — Foundations (1-2 days)

Nothing runs yet.

- [ ] Register the separate sending domain
- [ ] Create the mailbox (Zoho Mail Lite ~$1/mo, or Google Workspace)
- [ ] Publish SPF, DKIM, DMARC (`p=none`), MX — [06-deliverability.md](06-deliverability.md)
- [ ] `./scripts/check_deliverability.sh sending-domain.tld <selector>` exits 0
- [ ] `createdb zenvexa_acq`, run all migrations, load prompts
- [ ] `psql -f scripts/smoke_test.sql` — all assertions pass
- [ ] Second n8n container up, credentials created, workflows imported
- [ ] Telegram bot created, `notify.telegram_chat_id` set

**Done when** the smoke test passes and a Telegram test message arrives.

---

## Phase 1 — Discovery only (3-5 days)

No AI. No email. You are testing whether the funnel produces enough real
Karachi clinics to be worth the rest.

- [ ] Check the seeded area centroids against a map and correct them
- [ ] Activate **ACQ 00**, **ACQ 10**, **ACQ 20**
- [ ] Let discovery run a few cycles

Then look at what you actually got:

```sql
SELECT city, area, category, count(*),
       count(*) FILTER (WHERE public_email IS NOT NULL) AS with_email,
       count(*) FILTER (WHERE website IS NOT NULL)      AS with_website,
       round(avg(lead_score))                           AS avg_score
FROM acq.leads GROUP BY 1,2,3 ORDER BY 4 DESC;
```

**The number that decides the project: `with_email` as a share of the total.**
The audit estimates 25-40% end to end; measure yours. If OSM alone gives you too
few, this is the moment to enable Google Places, not later.

- [ ] Spot-check 20 leads by hand. Are they real clinics? Right category?
- [ ] Tune `acq.scoring_configs` weights if the ranking looks wrong

**Done when** you have 100+ deduplicated leads and believe the top-scoring ones.

---

## Phase 2 — Research and drafting, still no sending (3-5 days)

First AI spend. Still nothing leaves the building.

- [ ] Set `ai.daily_cost_cap_usd` low (`0.50`) to start
- [ ] Confirm `outreach.auto_send_enabled = false` — it is the default
- [ ] Set `outreach.dry_run = true`
- [ ] **Prune `product.capabilities`** to what actually ships today
- [ ] Set `company.postal_address`
- [ ] Activate **ACQ 01**, **ACQ 30**, **ACQ 40**

Then read the output like a reviewer:

```sql
SELECT l.clinic_name, r.confidence, r.pain_point,
       jsonb_array_length(r.facts) AS facts, r.relevance_reason
FROM acq.lead_research r JOIN acq.leads l ON l.id = r.lead_id
WHERE r.is_current ORDER BY r.created_at DESC LIMIT 20;

SELECT clinic_name, subject, body_text, ai_confidence, personalization_reason
FROM acq.emails e JOIN acq.leads l ON l.id = e.lead_id
ORDER BY e.created_at DESC LIMIT 20;
```

- [ ] Are the "facts" actually supported by the cited URL? Check five.
- [ ] Would you send each email to that clinic yourself?
- [ ] Iterate on `prompts/03_email_personalize.md`, bump the version, reload

**Done when** you would personally send 8 of 10 drafts unchanged. If not, the
prompt is not ready and no amount of infrastructure fixes that.

---

## Phase 3 — First real sends, human-approved (1-2 weeks)

The irreversible step. Small and supervised.

- [ ] Deploy **ACQ 110**, set `unsubscribe.base_url`, **click the link and
      verify a row appears in `acq.opt_outs`**
- [ ] Set `outreach.dry_run = false`
- [ ] Keep `outreach.auto_send_enabled = false`
- [ ] Set `mailboxes.warmup_started_on = CURRENT_DATE`
- [ ] Activate **ACQ 50**, **ACQ 60**
- [ ] Send yourself one first. Read it on a phone.

Then approve individually, 5/day in week 1:

```sql
SELECT * FROM acq.v_approval_queue;
-- approve:
UPDATE acq.emails SET status = 'READY_TO_SEND', approved_by = 'umer', approved_at = now()
 WHERE id = '…';
UPDATE acq.approvals SET status = 'APPROVED', decided_at = now(), decided_by = 'umer'
 WHERE email_id = '…';
```

Watch `acq.v_deliverability` daily.

**Done when** ~50 emails have gone out, bounce rate is under 2%, and you have
had at least one real reply.

---

## Phase 4 — Replies, follow-ups, demos (1-2 weeks)

- [ ] Activate **ACQ 70**, **ACQ 80**, **ACQ 90**, **ACQ 100**
- [ ] Configure Cal.com, set `demo.booking_url`, point its webhook at ACQ 100
- [ ] Send yourself a reply from another address and confirm: classification is
      right, follow-ups stop, the Telegram card arrives
- [ ] **Test the opt-out path end to end** — reply "please remove me" from a
      test address and confirm the lead is suppressed and unreachable

Read every classification for the first two weeks:

```sql
SELECT r.from_email, rc.class, rc.confidence, rc.requires_human,
       left(r.body_text, 200)
FROM acq.reply_classifications rc JOIN acq.replies r ON r.id = rc.reply_id
ORDER BY rc.created_at DESC;
```

A single misclassified `OPT_OUT` is worth stopping to fix.

**Done when** a full cycle — send, follow-up, reply, classify, notify — has run
without your intervention, and you trust it.

---

## Phase 5 — Increase autonomy (ongoing)

Only after the approval queue has been boring for two weeks.

- [ ] Raise `ai.min_email_confidence` to `0.8`
- [ ] Set `outreach.auto_send_enabled = true`
- [ ] Now only low-confidence drafts need you
- [ ] Let the warm-up ramp reach 25-40/day
- [ ] Deploy the dashboard (`dashboard/`)

Consider, in this order:

- Enable Google Places for specialty targeting
- A second market: insert a row in `acq.markets`, seed discovery tasks, create a
  campaign. **Read [10-compliance.md](10-compliance.md) first** — UAE, Saudi and
  the UK have consent models that Pakistan's does not share, which is why they
  ship disabled.
- A second mailbox, only if you are consistently hitting the daily cap with a
  healthy reply rate.

---

## What not to do

| Temptation | Why not |
|---|---|
| Turn on all 13 workflows at once | You will not know which is wrong |
| Skip Phase 2's manual review | The prompt is the product; infrastructure cannot save a bad email |
| Raise the daily cap early | Warm-up is time, not volume |
| Enable a second market before reading the compliance page | Different consent models |
| Add WhatsApp outreach | [Audit, finding 4](00-architecture-audit.md#4-do-not-cold-message-clinics-on-whatsapp-and-especially-not-from-clinibots-waba) |
| Turn off the approval gate in week 1 | It costs a week and buys a clean domain |
