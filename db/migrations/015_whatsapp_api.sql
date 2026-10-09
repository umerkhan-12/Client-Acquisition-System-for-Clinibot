-- =====================================================================
-- Migration 015: one-click WhatsApp sending through WAHA, still one at a time
--
-- Until now a person sent every WEB message from their own phone. This adds
-- a second way to send the same drafts: the person reviews the message in the
-- dashboard and clicks Send, the message joins a queue, and workflow 47 hands
-- it to a self-hosted WAHA (WhatsApp HTTP API) linked to a SEPARATE outreach
-- number, never the owner's personal one.
--
-- Nothing is sent that a person did not click. What the queue adds is pace:
-- WAHA drives WhatsApp Web, and a number that sends a burst of cold messages
-- gets banned. So, as with acq.claim_send_slots() for email, every limit lives
-- in one claimer that runs under an advisory lock:
--
--   whatsapp.api_enabled        off until WAHA is paired and checked
--   whatsapp.window_start/_end  local sending hours
--   whatsapp.daily_cap          messages per local day
--   whatsapp.min_gap_seconds    floor between two sends, plus per-message
--   whatsapp.jitter_seconds     jitter so the rhythm is not machine-regular
--
-- Two copies of workflow 47 running at once still send one message per gap.
--
-- A send whose outcome is unknown (the workflow died after claiming) is never
-- retried automatically: it may have gone out, and a business that receives
-- the same pitch twice reports the number. It surfaces in the dashboard as
-- FAILED for a person to check the phone and decide.
--
-- Replies arrive from WAHA's webhook (workflow 48) and go through
-- record_manual_outcome(), which cancels any pending follow-up first, the
-- WhatsApp twin of acq.record_reply().
-- =====================================================================

SET search_path = acq, public;

ALTER TABLE acq.manual_outreach ADD COLUMN IF NOT EXISTS queued_at      timestamptz;
ALTER TABLE acq.manual_outreach ADD COLUMN IF NOT EXISTS queued_by      text;
ALTER TABLE acq.manual_outreach ADD COLUMN IF NOT EXISTS claimed_at     timestamptz;
ALTER TABLE acq.manual_outreach ADD COLUMN IF NOT EXISTS send_attempts  int NOT NULL DEFAULT 0;
ALTER TABLE acq.manual_outreach ADD COLUMN IF NOT EXISTS api_message_id text;
ALTER TABLE acq.manual_outreach ADD COLUMN IF NOT EXISTS last_error     text;

ALTER TABLE acq.manual_outreach DROP CONSTRAINT IF EXISTS manual_outreach_status;
ALTER TABLE acq.manual_outreach ADD CONSTRAINT manual_outreach_status
  CHECK (status IN ('READY','SCHEDULED','QUEUED','SENDING','FAILED','SENT','SKIPPED','CANCELLED'));

CREATE INDEX IF NOT EXISTS manual_outreach_api_queue_idx
  ON acq.manual_outreach (queued_at) WHERE status IN ('QUEUED','SENDING');
CREATE INDEX IF NOT EXISTS manual_outreach_api_sent_idx
  ON acq.manual_outreach (sent_at) WHERE api_message_id IS NOT NULL;

INSERT INTO acq.settings (key, value, description) VALUES
('whatsapp.api_enabled',      'false'::jsonb,
 'Send queued WEB messages through WAHA. Off until the outreach number is paired and a test message has gone out.'),
('whatsapp.api_base_url',     '"http://waha:3000"'::jsonb,
 'WAHA base URL as n8n sees it. Inside the same Docker network this is http://waha:3000.'),
('whatsapp.session',          '"default"'::jsonb,
 'WAHA session name. WAHA Core supports one session, called default.'),
('whatsapp.default_country_code', '"92"'::jsonb,
 'Prefix for local numbers written with a leading 0 (0300... becomes 92300...).'),
('whatsapp.timezone',         '"Asia/Karachi"'::jsonb, 'Clock the sending window and the daily cap use.'),
('whatsapp.window_start',     '"10:00"'::jsonb, 'Earliest local time a message may be sent.'),
('whatsapp.window_end',       '"20:00"'::jsonb, 'Latest local time a message may be sent.'),
('whatsapp.daily_cap',        '20'::jsonb,
 'Messages per local day through the API. A new number should start lower and rise slowly.'),
('whatsapp.min_gap_seconds',  '240'::jsonb, 'Minimum seconds between two API sends.'),
('whatsapp.jitter_seconds',   '240'::jsonb, 'Up to this many extra seconds, varied per message.'),
('whatsapp.stop_words',       '["stop","unsubscribe","dont message","do not message","remove me","not interested"]'::jsonb,
 'An inbound reply consisting of one of these (case-insensitive) is recorded as an opt-out, not a reply.')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION acq.setting_text(p_key text, p_default text)
RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT coalesce((SELECT value #>> '{}' FROM acq.settings WHERE key = p_key), p_default)
$fn$;

-- 0300-1234567 / +92 300 1234567 / 0092... -> 923001234567. NULL if unusable.
CREATE OR REPLACE FUNCTION acq.whatsapp_digits(p_number text)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  d  text := regexp_replace(coalesce(p_number, ''), '[^0-9]', '', 'g');
  cc text := acq.setting_text('whatsapp.default_country_code', '92');
BEGIN
  IF d LIKE '00%' THEN d := substr(d, 3); END IF;
  IF d LIKE '0%'  THEN d := cc || substr(d, 2); END IF;
  IF length(d) = 10 AND cc = '92' AND d LIKE '3%' THEN d := cc || d; END IF;
  IF length(d) < 10 OR length(d) > 15 THEN RETURN NULL; END IF;
  RETURN d;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Dashboard: "Send via WhatsApp". Stores the text as the person left it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.queue_whatsapp_send(p_outreach_id uuid, p_final_message text, p_by text)
RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
DECLARE
  v_m    acq.manual_outreach%ROWTYPE;
  v_lead acq.leads%ROWTYPE;
  v_text text := btrim(coalesce(p_final_message, ''));
BEGIN
  IF NOT coalesce((SELECT (value #>> '{}')::boolean FROM acq.settings WHERE key = 'whatsapp.api_enabled'), false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'api_disabled');
  END IF;
  SELECT * INTO v_m FROM acq.manual_outreach WHERE id = p_outreach_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_m.channel <> 'WHATSAPP' THEN RETURN jsonb_build_object('ok', false, 'error', 'not_whatsapp'); END IF;
  IF v_m.status NOT IN ('READY','SCHEDULED') OR (v_m.status = 'SCHEDULED' AND v_m.due_at > now()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_due', 'status', v_m.status);
  END IF;
  IF acq.whatsapp_digits(v_m.to_value) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_number');
  END IF;

  SELECT * INTO v_lead FROM acq.leads WHERE id = v_m.lead_id;
  IF v_lead.opt_out OR v_lead.do_not_contact OR acq.is_suppressed(NULL, NULL, v_m.to_value, v_lead.id) THEN
    UPDATE acq.manual_outreach SET status = 'CANCELLED', closed_reason = 'suppressed' WHERE id = v_m.id;
    RETURN jsonb_build_object('ok', false, 'error', 'lead_suppressed');
  END IF;
  IF v_lead.replied_at IS NOT NULL AND v_m.step_no > 0 THEN
    UPDATE acq.manual_outreach SET status = 'CANCELLED', closed_reason = 'already_replied' WHERE id = v_m.id;
    RETURN jsonb_build_object('ok', false, 'error', 'lead_already_replied');
  END IF;

  UPDATE acq.manual_outreach
     SET status = 'QUEUED', queued_at = now(), queued_by = p_by, last_error = NULL,
         message = coalesce(nullif(v_text, ''), message)
   WHERE id = v_m.id;
  INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
  VALUES (v_m.lead_id, 'WHATSAPP_QUEUED', 'HUMAN', format('Queued for WhatsApp by %s', coalesce(p_by, '?')),
          jsonb_build_object('outreach_id', v_m.id, 'step_no', v_m.step_no));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Take a message back out of the queue before it goes.
CREATE OR REPLACE FUNCTION acq.unqueue_whatsapp_send(p_outreach_id uuid, p_by text)
RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
BEGIN
  UPDATE acq.manual_outreach SET status = 'READY', queued_at = NULL, queued_by = NULL
   WHERE id = p_outreach_id AND status = 'QUEUED';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_queued'); END IF;
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- A FAILED send: try again, record that it went out after all, or hand it
-- back to the by-hand queue.
CREATE OR REPLACE FUNCTION acq.resolve_whatsapp_failure(p_outreach_id uuid, p_action text, p_by text)
RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
DECLARE
  v_action text := upper(coalesce(p_action, ''));
BEGIN
  IF v_action NOT IN ('RETRY','SENT_BY_HAND','BACK_TO_MANUAL') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_action');
  END IF;
  UPDATE acq.manual_outreach SET status = 'READY' WHERE id = p_outreach_id AND status = 'FAILED';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_failed'); END IF;
  IF v_action = 'RETRY'        THEN RETURN acq.queue_whatsapp_send(p_outreach_id, NULL, p_by); END IF;
  IF v_action = 'SENT_BY_HAND' THEN RETURN acq.mark_manual_sent(p_outreach_id, NULL, p_by); END IF;
  UPDATE acq.manual_outreach SET queued_at = NULL, queued_by = NULL WHERE id = p_outreach_id;
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- ---------------------------------------------------------------------
-- Workflow 47: the only path from the queue to WAHA. At most one message
-- per call, and only when every limit allows it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.claim_whatsapp_send(p_execution_id text)
RETURNS TABLE (outreach_id uuid, lead_id uuid, chat_id text, message text,
               base_url text, session text, reason text)
LANGUAGE plpgsql AS $fn$
#variable_conflict use_column
DECLARE
  v_tz     text := acq.setting_text('whatsapp.timezone', 'Asia/Karachi');
  v_local  timestamp := now() AT TIME ZONE v_tz;
  v_cap    int  := acq.setting_text('whatsapp.daily_cap', '20')::int;
  v_gap    int  := acq.setting_text('whatsapp.min_gap_seconds', '240')::int;
  v_jit    int  := greatest(acq.setting_text('whatsapp.jitter_seconds', '240')::int, 0);
  v_today  int;
  v_last   timestamptz;
  v_m      acq.manual_outreach%ROWTYPE;
  v_lead   acq.leads%ROWTYPE;
  v_digits text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('acq.claim_whatsapp_send'));

  -- Claimed but never reported back: outcome unknown, so not retried.
  UPDATE acq.manual_outreach
     SET status = 'FAILED', last_error = 'no result recorded: check the outreach phone before retrying'
   WHERE status = 'SENDING' AND claimed_at < now() - interval '10 minutes';

  IF NOT coalesce((SELECT (value #>> '{}')::boolean FROM acq.settings WHERE key = 'whatsapp.api_enabled'), false) THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::text, 'disabled'::text; RETURN;
  END IF;
  IF v_local::time < acq.setting_text('whatsapp.window_start', '10:00')::time
     OR v_local::time >= acq.setting_text('whatsapp.window_end', '20:00')::time THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::text, 'outside_window'::text; RETURN;
  END IF;

  SELECT count(*) INTO v_today FROM acq.manual_outreach m
   WHERE m.claimed_at IS NOT NULL
     AND (m.claimed_at AT TIME ZONE v_tz)::date = v_local::date
     AND (m.api_message_id IS NOT NULL OR m.status IN ('SENDING','FAILED'));
  IF v_today >= v_cap THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::text, 'daily_cap'::text; RETURN;
  END IF;

  SELECT max(m.claimed_at) INTO v_last FROM acq.manual_outreach m WHERE m.claimed_at IS NOT NULL;

  LOOP
    SELECT * INTO v_m FROM acq.manual_outreach m
     WHERE m.status = 'QUEUED' ORDER BY m.queued_at, m.id LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::text, 'queue_empty'::text; RETURN;
    END IF;

    IF v_last IS NOT NULL AND now() < v_last
         + make_interval(secs => v_gap + (abs(hashtext(v_m.id::text)) % (v_jit + 1))) THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::text, 'waiting_gap'::text; RETURN;
    END IF;

    SELECT * INTO v_lead FROM acq.leads l WHERE l.id = v_m.lead_id;
    v_digits := acq.whatsapp_digits(v_m.to_value);
    IF v_lead.opt_out OR v_lead.do_not_contact OR acq.is_suppressed(NULL, NULL, v_m.to_value, v_lead.id) THEN
      UPDATE acq.manual_outreach SET status = 'CANCELLED', closed_reason = 'suppressed' WHERE id = v_m.id;
      CONTINUE;
    END IF;
    IF v_lead.replied_at IS NOT NULL AND v_m.step_no > 0 THEN
      UPDATE acq.manual_outreach SET status = 'CANCELLED', closed_reason = 'already_replied' WHERE id = v_m.id;
      CONTINUE;
    END IF;
    IF v_digits IS NULL THEN
      UPDATE acq.manual_outreach SET status = 'FAILED', last_error = 'number is not a usable WhatsApp number' WHERE id = v_m.id;
      CONTINUE;
    END IF;

    UPDATE acq.manual_outreach
       SET status = 'SENDING', claimed_at = now(), send_attempts = send_attempts + 1
     WHERE id = v_m.id;
    RETURN QUERY SELECT v_m.id, v_m.lead_id, v_digits || '@c.us', v_m.message,
                        rtrim(acq.setting_text('whatsapp.api_base_url', 'http://waha:3000'), '/'),
                        acq.setting_text('whatsapp.session', 'default'), 'claimed'::text;
    RETURN;
  END LOOP;
END;
$fn$;

-- What WAHA answered. Success goes through mark_manual_sent(), so the lead
-- moves and the follow-up is scheduled exactly as for a message sent by hand.
CREATE OR REPLACE FUNCTION acq.record_whatsapp_result(
  p_outreach_id uuid, p_ok boolean, p_api_message_id text, p_error text
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_m   acq.manual_outreach%ROWTYPE;
  v_res jsonb;
BEGIN
  SELECT * INTO v_m FROM acq.manual_outreach WHERE id = p_outreach_id FOR UPDATE;
  IF NOT FOUND OR v_m.status <> 'SENDING' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_sending', 'status', v_m.status);
  END IF;

  IF NOT coalesce(p_ok, false) THEN
    UPDATE acq.manual_outreach SET status = 'FAILED', last_error = left(coalesce(p_error, 'unknown error'), 500)
     WHERE id = v_m.id;
    RETURN jsonb_build_object('ok', true, 'recorded', 'FAILED');
  END IF;

  UPDATE acq.manual_outreach SET status = 'READY' WHERE id = v_m.id;
  v_res := acq.mark_manual_sent(v_m.id, NULL, 'whatsapp-api:' || coalesce(v_m.queued_by, '?'));
  -- Already out of the door even if the lead opted out mid-flight; keep the truth.
  UPDATE acq.manual_outreach
     SET api_message_id = coalesce(nullif(p_api_message_id, ''), 'sent'),
         status = CASE WHEN status = 'CANCELLED' THEN 'SENT' ELSE status END,
         sent_at = coalesce(sent_at, now())
   WHERE id = v_m.id;
  RETURN jsonb_build_object('ok', true, 'recorded', 'SENT', 'mark', v_res);
END;
$fn$;

-- ---------------------------------------------------------------------
-- Workflow 48: a WAHA webhook event. Everything is decided here, not in n8n:
-- which events count, who it is from, whether it is a stop request.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.record_whatsapp_inbound(p_event jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_ev     text := p_event ->> 'event';
  v_p      jsonb := coalesce(p_event -> 'payload', '{}'::jsonb);
  v_from   text := acq.whatsapp_digits(split_part(coalesce(v_p ->> 'from', ''), '@', 1));
  v_body   text := btrim(coalesce(v_p ->> 'body', ''));
  v_lead   uuid;
  v_status acq.lead_status;
  v_stop   boolean;
  v_res    jsonb;
BEGIN
  IF v_ev NOT IN ('message', 'message.any') OR coalesce((v_p ->> 'fromMe')::boolean, false)
     OR coalesce(v_p ->> 'from', '') LIKE '%@g.us' OR v_from IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'ignored', true);
  END IF;

  SELECT m.lead_id INTO v_lead FROM acq.manual_outreach m
   WHERE m.status = 'SENT' AND acq.whatsapp_digits(m.to_value) = v_from
   ORDER BY m.sent_at DESC LIMIT 1;
  IF v_lead IS NULL THEN RETURN jsonb_build_object('ok', true, 'ignored', true, 'reason', 'unknown_sender'); END IF;

  INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
  VALUES (v_lead, 'WHATSAPP_INBOUND', 'PROSPECT', left(coalesce(nullif(v_body, ''), '(media or empty message)'), 500),
          jsonb_build_object('wa_id', v_p ->> 'id', 'from', v_from));

  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements_text(
            coalesce((SELECT value FROM acq.settings WHERE key = 'whatsapp.stop_words'), '[]'::jsonb)) w
          WHERE lower(regexp_replace(v_body, '[^a-zA-Z ]', '', 'g')) = lower(w))
    INTO v_stop;

  SELECT status INTO v_status FROM acq.leads WHERE id = v_lead;
  IF v_stop THEN
    v_res := acq.record_manual_outcome(v_lead, 'OPT_OUT', 'whatsapp-api', v_body);
  ELSIF v_status IN ('CONTACTED', 'FOLLOW_UP_1', 'FOLLOW_UP_2', 'FOLLOW_UP_3') THEN
    v_res := acq.record_manual_outcome(v_lead, 'REPLIED', 'whatsapp-api', v_body);
  ELSE
    v_res := jsonb_build_object('ok', true, 'note', 'logged only; lead already past first reply');
  END IF;
  RETURN jsonb_build_object('ok', true, 'lead_id', v_lead, 'stop', v_stop, 'result', v_res);
END;
$fn$;

-- ---------------------------------------------------------------------
-- Dashboard views: the queue and the switch, without acq.settings access.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW acq.v_whatsapp_queue AS
SELECT m.id, m.lead_id, l.clinic_name AS business_name, m.step_no, m.to_value, m.message,
       m.status, m.queued_at, m.queued_by, m.claimed_at, m.send_attempts, m.last_error
FROM acq.manual_outreach m
JOIN acq.leads l ON l.id = m.lead_id
WHERE m.status IN ('QUEUED', 'SENDING', 'FAILED');

CREATE OR REPLACE VIEW acq.v_whatsapp_status AS
SELECT
  coalesce((SELECT (value #>> '{}')::boolean FROM acq.settings WHERE key = 'whatsapp.api_enabled'), false) AS api_enabled,
  acq.setting_text('whatsapp.daily_cap', '20')::int       AS daily_cap,
  acq.setting_text('whatsapp.window_start', '10:00')      AS window_start,
  acq.setting_text('whatsapp.window_end', '20:00')        AS window_end,
  acq.setting_text('whatsapp.min_gap_seconds', '240')::int AS min_gap_seconds,
  (SELECT count(*) FROM acq.manual_outreach m
    WHERE m.claimed_at IS NOT NULL
      AND (m.claimed_at AT TIME ZONE acq.setting_text('whatsapp.timezone', 'Asia/Karachi'))::date
          = (now() AT TIME ZONE acq.setting_text('whatsapp.timezone', 'Asia/Karachi'))::date
      AND (m.api_message_id IS NOT NULL OR m.status IN ('SENDING','FAILED')))::int AS sent_today,
  (SELECT count(*) FROM acq.manual_outreach WHERE status = 'QUEUED')::int AS queued,
  (SELECT count(*) FROM acq.manual_outreach WHERE status = 'FAILED')::int AS failed;

GRANT SELECT ON acq.v_whatsapp_queue, acq.v_whatsapp_status TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.queue_whatsapp_send(uuid, text, text)       TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.unqueue_whatsapp_send(uuid, text)           TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.resolve_whatsapp_failure(uuid, text, text)  TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.claim_whatsapp_send(text)                   TO acq_n8n;
GRANT EXECUTE ON FUNCTION acq.record_whatsapp_result(uuid, boolean, text, text) TO acq_n8n;
GRANT EXECUTE ON FUNCTION acq.record_whatsapp_inbound(jsonb)              TO acq_n8n;
