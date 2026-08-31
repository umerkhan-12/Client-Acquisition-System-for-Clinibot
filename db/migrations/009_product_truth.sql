-- =====================================================================
-- Migration 009: replace the claim whitelist with what the product does
--
-- WHY THIS EXISTS
--
-- `product.capabilities` shipped as a transcription of the original brief,
-- including three lines the brief itself only called "potentially" available.
-- Every line in it is injected into the personalisation prompt as
-- {{capabilities}} and asserted to a real clinic as fact. Three of them were
-- wrong, and one was wrong in the direction that loses a customer at the demo.
--
-- Each line below was checked on 2026-08-29 against the Clinibot source at
-- ../clinibot/clinibot-backend/src, not against the brief. The file path that
-- justifies each claim is in the comment beside it, so the next person can
-- re-check rather than re-trust.
--
-- THE THREE THAT WERE FLAGGED UNVERIFIED, RESOLVED
--
--   "Can collect an appointment fee before confirming a booking"
--       FALSE AS WRITTEN, and the most dangerous line in the file. Clinibot
--       does not collect, hold or process money. payments.service.ts is
--       explicit: the clinic is the merchant, funds move directly to its own
--       Easypaisa/JazzCash/bank account, and a patient saying "paid, TRX
--       883421" is recorded as a *claim* that a human at the desk verifies.
--       The service deliberately never changes the appointment's status.
--       Telling a clinic we take payment and then showing them a screen that
--       records a claim is how a good demo turns into a lost deal. Rewritten
--       to what it does.
--
--   "Connects to clinic scheduling and calendar systems"
--       TRUE BUT TOO BROAD. The plural implies an integration catalogue.
--       calendar.service.ts speaks to exactly one thing: Google Calendar, via
--       a service account, with a per-doctor calendarId. Narrowed to that.
--
--   "Reads prescription images"
--       TRUE, and undersold. ocr.service.ts is a real Gemini vision call with
--       a structured schema, and it carries a detail worth more than the
--       feature: Pakistani doctors write the drug in English and the dosing in
--       Urdu, so it returns `frequencyEnglish` alongside the original script.
--       Sharpened rather than removed.
--
-- WHAT WAS MISSING
--
-- Four capabilities are live, in code, with tests, and were not on the list —
-- so the AI was forbidden from mentioning them. Two of them (Roman Urdu,
-- voice notes) are the strongest things this product does in this market.
--
-- The rule stays what it was: if it is not on this list, it cannot be said.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The claim whitelist, rebuilt from source.
--
-- DO UPDATE, not DO NOTHING: 006 already inserted the brief's version, so an
-- existing database must be corrected rather than left alone. This is the one
-- setting where a stale value is actively harmful.
-- ---------------------------------------------------------------------
INSERT INTO acq.settings (key, value, description) VALUES
('product.capabilities',
 '[
   "Answers patient WhatsApp messages at any hour, including nights and weekends",
   "Replies in the same language and script the patient used, including Roman Urdu",
   "Understands voice notes, not just typed messages",
   "Books appointments into the clinic''s real schedule",
   "Checks live availability across multiple doctors and services before offering a time",
   "Handles rescheduling as a single move, without the patient losing their slot",
   "Handles cancellations",
   "Sends appointment confirmations",
   "Sends appointment reminders before the visit",
   "Messages back automatically when someone rings the clinic''s WhatsApp number and nobody answers",
   "Recognises messages describing a medical emergency and tells the patient to seek urgent care instead of offering a booking",
   "Answers common questions about the clinic — timings, location, fees, doctors and services",
   "Reads a photo of a handwritten prescription into a structured list of medicines, including dosing written in Urdu",
   "Sends follow-up recall messages when a prescription says the patient should return",
   "Records the advance payment a patient says they have sent, for clinic staff to verify — the clinic stays the merchant and receives funds directly",
   "Syncs with each doctor''s Google Calendar, so times already blocked there are never offered",
   "Provides a clinic dashboard showing appointments and conversations",
   "Never tells a patient an appointment is confirmed unless the booking actually succeeded",
   "Reduces routine receptionist workload"
 ]'::jsonb,
 'CLAIM WHITELIST. The only statements the AI may make about Clinibot. Every line verified against clinibot-backend/src on 2026-08-29 — see migration 009 for the file behind each. Re-verify before adding.')
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value, description = EXCLUDED.description;

-- ---------------------------------------------------------------------
-- Nothing is unverified any more. Emptied rather than dropped: acq.readiness()
-- counts this array, and the count being zero is the signal that the pruning
-- actually happened.
--
-- If a capability is ever added on the strength of a plan rather than a file,
-- put it here too and readiness will keep warning until it is resolved.
-- ---------------------------------------------------------------------
INSERT INTO acq.settings (key, value, description) VALUES
('product.capabilities_unverified',
 '[]'::jsonb,
 'Capabilities claimed but not yet confirmed in the product source. Empty since 009. Anything added here makes acq.readiness() warn until it is checked off.')
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value, description = EXCLUDED.description;

-- ---------------------------------------------------------------------
-- The things the product does NOT do.
--
-- A whitelist stops the model inventing features. It does nothing about the
-- second failure mode, which is subtler and costs more: answering a clinic's
-- direct question with a hedge, or with silence, when the honest answer is
-- "no, not yet". A prospect who is told "not yet, here is what it does instead"
-- stays in the conversation. One who is dodged does not, and stops trusting
-- everything else in the email.
--
-- Exposed to every prompt as {{not_yet}}, and actually used by
-- prompts/06_hot_lead_brief.md (v2) — the brief a human reads on their phone
-- before replying to an interested clinic. That is the moment the answer is
-- about to be needed out loud.
--
-- Deliberately NOT referenced by the cold-email prompt: a first email should
-- not volunteer its own weaknesses unprompted.
-- ---------------------------------------------------------------------
INSERT INTO acq.settings (key, value, description) VALUES
('product.not_yet',
 '[
   "Clinibot does not process payments. It records what a patient says they paid; staff verify it against the clinic''s own account.",
   "There is no self-serve signup yet. Onboarding a clinic is done by hand, with us.",
   "There is no patient-facing mobile app. Patients use WhatsApp, which they already have.",
   "It does not answer calls to a landline or a non-WhatsApp mobile — only messages and calls on the clinic''s WhatsApp number.",
   "It does not read or write to hospital HIS/EMR systems.",
   "It is not a diagnosis tool and does not give medical advice."
 ]'::jsonb,
 'Honest answers to "can it do X?" — used when a clinic asks directly. Prevents a hedge where a plain no belongs.')
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value, description = EXCLUDED.description;

-- =====================================================================
-- A silent hole in the AI cost cap.
--
-- 01_ai_call costs every call with:
--     const rate = (ctx.pricing || {})[ctx.model] || {};
--
-- An unknown model therefore costs exactly $0.00, forever. Nothing errors and
-- nothing looks wrong — acq.ai_calls fills with real token counts beside a zero
-- cost, and `ai.daily_cost_cap_usd` (2.00) can never be exceeded, so the pause
-- that is supposed to stop a runaway research loop never fires.
--
-- This stopped being hypothetical the moment this repo learned that the
-- Clinibot droplet pins GEMINI_MODEL=gemini-3.5-flash-lite. That is the
-- obvious value to copy into ai.model, it is not in ai.pricing, and copying it
-- silently disables the spend cap on the same key that answers real patients.
--
-- No price is invented here. The check reports the gap; a human fills in the
-- rate from ai.google.dev/pricing.
-- =====================================================================
CREATE OR REPLACE FUNCTION acq.readiness()
RETURNS TABLE (severity text, check_name text, detail text)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v text;
  n int;
BEGIN
  -- ---- blockers: the send path refuses while these are unset -----------
  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'company.postal_address';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'BLOCKER', 'company.postal_address',
      'Empty. Workflow 50 throws rather than send mail with no postal address.';
  ELSE
    RETURN QUERY SELECT 'OK', 'company.postal_address', v;
  END IF;

  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'unsubscribe.base_url';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'BLOCKER', 'unsubscribe.base_url',
      'Empty. Deploy workflow 110 and set its public URL; an opt-out link that does not work is worse than none.';
  ELSE
    RETURN QUERY SELECT 'OK', 'unsubscribe.base_url', v;
  END IF;

  SELECT count(*) INTO n FROM acq.prompts WHERE active;
  IF n < 8 THEN
    RETURN QUERY SELECT 'BLOCKER', 'prompts',
      format('%s of 8 active. Run: python3 scripts/load_prompts.py | psql', n);
  ELSE
    RETURN QUERY SELECT 'OK', 'prompts', format('%s active', n);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.scoring_configs WHERE active) THEN
    RETURN QUERY SELECT 'BLOCKER', 'scoring_config', 'No active scoring config; compute_score() will fail.';
  ELSE
    RETURN QUERY SELECT 'OK', 'scoring_config',
      (SELECT version FROM acq.scoring_configs WHERE active);
  END IF;

  -- ---- new in 009: the model must have a price ------------------------
  -- A BLOCKER, not a warning. The failure is invisible at runtime and the
  -- thing it disables is the only automatic brake on AI spend.
  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'ai.model';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'BLOCKER', 'ai.model', 'Unset. Every AI workflow will fall back to a default that may not match your key.';
  ELSIF NOT EXISTS (
    SELECT 1 FROM acq.settings s
     WHERE s.key = 'ai.pricing' AND s.value ? v
  ) THEN
    RETURN QUERY SELECT 'BLOCKER', 'ai.pricing',
      format(
        'ai.model is "%s" but ai.pricing has no rate for it, so every call is costed at $0.00 and ai.daily_cost_cap_usd can never trip. Add the rate from ai.google.dev/pricing: '
        'UPDATE acq.settings SET value = jsonb_set(value, ''{%s}'', ''{"input_per_1m":0.0,"output_per_1m":0.0}''::jsonb) WHERE key = ''ai.pricing'';',
        v, v);
  ELSE
    RETURN QUERY SELECT 'OK', 'ai.pricing', format('%s is priced', v);
  END IF;

  -- ---- warnings: it will run, but not as intended ----------------------
  SELECT count(*) INTO n
    FROM acq.settings s,
         LATERAL jsonb_array_elements_text(s.value) c
   WHERE s.key = 'product.capabilities_unverified';
  IF n > 0 THEN
    RETURN QUERY SELECT 'WARN', 'product.capabilities',
      format('%s capabilities are flagged unverified and will still be claimed to real clinics. Prune product.capabilities.', n);
  END IF;

  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'notify.telegram_chat_id';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'WARN', 'notify.telegram_chat_id',
      'Empty. Hot-lead notifications and error alerts have nowhere to go.';
  ELSE
    RETURN QUERY SELECT 'OK', 'notify.telegram_chat_id', 'set';
  END IF;

  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'demo.booking_url';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'WARN', 'demo.booking_url',
      'Empty. Every email asks for a demo; without a link the reply has nowhere to go.';
  ELSE
    RETURN QUERY SELECT 'OK', 'demo.booking_url', v;
  END IF;

  IF EXISTS (SELECT 1 FROM acq.mailboxes WHERE active AND warmup_started_on IS NULL) THEN
    RETURN QUERY SELECT 'WARN', 'mailbox.warmup',
      'warmup_started_on is unset, so the ramp caps sending at 5/day.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.markets WHERE enabled) THEN
    RETURN QUERY SELECT 'WARN', 'markets', 'No market is enabled; discovery will find nothing.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.discovery_tasks WHERE enabled) THEN
    RETURN QUERY SELECT 'WARN', 'discovery_tasks', 'No discovery task is enabled.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.campaigns WHERE status = 'ACTIVE') THEN
    RETURN QUERY SELECT 'WARN', 'campaigns', 'No active campaign; nothing will be sent.';
  END IF;

  SELECT count(*) INTO n FROM acq.dead_letters WHERE resolved_at IS NULL;
  IF n > 0 THEN
    RETURN QUERY SELECT 'WARN', 'dead_letters', format('%s unresolved.', n);
  END IF;

  -- ---- informational ---------------------------------------------------
  RETURN QUERY
  SELECT 'INFO', 'outreach.auto_send_enabled',
         CASE WHEN (SELECT (value)::boolean FROM acq.settings WHERE key='outreach.auto_send_enabled')
              THEN 'ON — drafts send without review'
              ELSE 'OFF — every draft waits for approval (the intended starting state)' END;

  RETURN QUERY
  SELECT 'INFO', 'outreach.dry_run',
         CASE WHEN (SELECT (value)::boolean FROM acq.settings WHERE key='outreach.dry_run')
              THEN 'ON — nothing is actually sent'
              ELSE 'OFF — real mail will leave the building' END;

  RETURN QUERY SELECT 'INFO', 'leads',
    format('%s total, %s qualified, %s contacted',
      (SELECT count(*) FROM acq.leads),
      (SELECT count(*) FROM acq.leads WHERE status = 'QUALIFIED'),
      (SELECT count(*) FROM acq.leads WHERE last_contacted_at IS NOT NULL));
END;
$fn$;

COMMENT ON FUNCTION acq.readiness() IS
  'Pre-flight checklist as a query. BLOCKER rows are conditions the workflows refuse to run past. 009 added the ai.pricing check.';
