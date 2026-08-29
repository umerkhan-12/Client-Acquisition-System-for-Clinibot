-- =====================================================================
-- Migration 002: normalization, deduplication, state machine, rate limits
--
-- Design note: the deterministic logic of this system lives in SQL, not in
-- n8n nodes. Overlapping and retried n8n executions make in-workflow counters
-- and in-workflow dedup unreliable; a single transaction in Postgres is the
-- only place these invariants can actually hold.
-- =====================================================================

SET search_path = acq, public;

-- ---------------------------------------------------------------------
-- Normalization helpers
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION acq.normalize_domain(p_url text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT NULLIF(
    regexp_replace(                                   -- drop port / trailing dot
      regexp_replace(                                 -- drop path, query, fragment
        regexp_replace(                               -- drop scheme and www.
          lower(btrim(coalesce(p_url, ''))),
          '^(https?://)?(www\.)?', ''
        ),
        '[/?#].*$', ''
      ),
      '[:.]+$|:[0-9]+$', ''
    ),
  '');
$fn$;

CREATE OR REPLACE FUNCTION acq.normalize_email(p_email text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT NULLIF(lower(btrim(coalesce(p_email, ''))), '');
$fn$;

-- Converts local Pakistani/Gulf/UK formats to a stable E.164-ish string.
-- Deliberately conservative: anything it cannot confidently normalize is
-- returned as NULL rather than as a wrong number that could cause a bad merge.
CREATE OR REPLACE FUNCTION acq.normalize_phone(p_phone text, p_cc text DEFAULT '92')
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  d text;
BEGIN
  IF p_phone IS NULL OR btrim(p_phone) = '' THEN
    RETURN NULL;
  END IF;

  d := regexp_replace(btrim(p_phone), '[^0-9+]', '', 'g');

  IF d LIKE '+%' THEN
    d := substring(d FROM 2);
  ELSIF d LIKE '00%' THEN
    d := substring(d FROM 3);
  ELSIF d LIKE '0%' THEN
    d := p_cc || substring(d FROM 2);
  ELSIF position(p_cc IN d) <> 1 THEN
    d := p_cc || d;
  END IF;

  d := regexp_replace(d, '[^0-9]', '', 'g');

  IF length(d) < 8 OR length(d) > 15 THEN
    RETURN NULL;
  END IF;

  RETURN '+' || d;
END;
$fn$;

-- Strips generic venue/corporate words so "Dr. Ahmed's Dental Clinic (Pvt) Ltd"
-- and "Ahmed Dental" collapse to comparable tokens.
CREATE OR REPLACE FUNCTION acq.normalize_name(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT NULLIF(
    btrim(
      regexp_replace(
        regexp_replace(
          regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', ' ', 'g'),
          '\y(the|and|of|dr|doctor|prof|professor|mr|mrs|ms|pvt|private|ltd|limited|llc|inc|co|company|clinic|clinics|centre|center|hospital|medical|medicare|healthcare|health|care|surgery|surgeries|polyclinic|associates)\y',
          ' ', 'g'
        ),
        '\s+', ' ', 'g'
      )
    ),
  '');
$fn$;

-- ---------------------------------------------------------------------
-- Maintained columns
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION acq.tg_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.tg_leads_normalize()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  v_cc text;
BEGIN
  SELECT phone_cc INTO v_cc FROM acq.markets WHERE id = NEW.market_id;
  v_cc := coalesce(v_cc, '92');

  NEW.normalized_name := coalesce(acq.normalize_name(NEW.clinic_name), lower(btrim(NEW.clinic_name)));
  NEW.domain          := acq.normalize_domain(NEW.website);
  NEW.phone           := acq.normalize_phone(NEW.phone, v_cc);
  NEW.whatsapp        := acq.normalize_phone(NEW.whatsapp, v_cc);
  NEW.public_email    := acq.normalize_email(NEW.public_email)::citext;
  NEW.updated_at      := now();

  -- A lead that has opted out or been marked do-not-contact can never be
  -- flipped back on by an automated path.
  IF NEW.opt_out OR NEW.do_not_contact THEN
    NEW.next_follow_up_at := NULL;
  END IF;

  RETURN NEW;
END;
$fn$;

CREATE OR REPLACE TRIGGER leads_normalize
  BEFORE INSERT OR UPDATE ON acq.leads
  FOR EACH ROW EXECUTE FUNCTION acq.tg_leads_normalize();

CREATE OR REPLACE TRIGGER emails_touch
  BEFORE UPDATE ON acq.emails
  FOR EACH ROW EXECUTE FUNCTION acq.tg_touch_updated_at();

CREATE OR REPLACE TRIGGER follow_ups_touch
  BEFORE UPDATE ON acq.follow_ups
  FOR EACH ROW EXECUTE FUNCTION acq.tg_touch_updated_at();

CREATE OR REPLACE TRIGGER demo_bookings_touch
  BEFORE UPDATE ON acq.demo_bookings
  FOR EACH ROW EXECUTE FUNCTION acq.tg_touch_updated_at();

-- ---------------------------------------------------------------------
-- State machine
-- ---------------------------------------------------------------------

INSERT INTO acq.status_transitions (from_status, to_status) VALUES
  ('NEW','RESEARCHING'), ('NEW','QUALIFIED'), ('NEW','REJECTED'), ('NEW','INVALID'),
  ('NEW','DO_NOT_CONTACT'), ('NEW','OPTED_OUT'),
  ('RESEARCHING','QUALIFIED'), ('RESEARCHING','REJECTED'), ('RESEARCHING','INVALID'),
  ('RESEARCHING','READY_FOR_REVIEW'),
  ('QUALIFIED','RESEARCHING'), ('QUALIFIED','READY_FOR_REVIEW'), ('QUALIFIED','APPROVED'),
  ('QUALIFIED','REJECTED'), ('QUALIFIED','INVALID'),
  ('READY_FOR_REVIEW','APPROVED'), ('READY_FOR_REVIEW','REJECTED'),
  ('READY_FOR_REVIEW','QUALIFIED'), ('READY_FOR_REVIEW','DO_NOT_CONTACT'),
  ('APPROVED','CONTACTED'), ('APPROVED','REJECTED'), ('APPROVED','READY_FOR_REVIEW'),
  ('CONTACTED','FOLLOW_UP_1'), ('CONTACTED','REPLIED'), ('CONTACTED','BOUNCED'),
  ('CONTACTED','OPTED_OUT'), ('CONTACTED','NOT_INTERESTED'), ('CONTACTED','LATER'),
  ('FOLLOW_UP_1','FOLLOW_UP_2'), ('FOLLOW_UP_1','REPLIED'), ('FOLLOW_UP_1','BOUNCED'),
  ('FOLLOW_UP_1','OPTED_OUT'), ('FOLLOW_UP_1','NOT_INTERESTED'), ('FOLLOW_UP_1','LATER'),
  ('FOLLOW_UP_2','FOLLOW_UP_3'), ('FOLLOW_UP_2','REPLIED'), ('FOLLOW_UP_2','BOUNCED'),
  ('FOLLOW_UP_2','OPTED_OUT'), ('FOLLOW_UP_2','NOT_INTERESTED'), ('FOLLOW_UP_2','LATER'),
  ('FOLLOW_UP_3','REPLIED'), ('FOLLOW_UP_3','BOUNCED'), ('FOLLOW_UP_3','OPTED_OUT'),
  ('FOLLOW_UP_3','NOT_INTERESTED'), ('FOLLOW_UP_3','LATER'),
  ('REPLIED','INTERESTED'), ('REPLIED','NOT_INTERESTED'), ('REPLIED','LATER'),
  ('REPLIED','OPTED_OUT'), ('REPLIED','DEMO_REQUESTED'), ('REPLIED','DO_NOT_CONTACT'),
  ('INTERESTED','DEMO_REQUESTED'), ('INTERESTED','DEMO_BOOKED'), ('INTERESTED','CUSTOMER'),
  ('INTERESTED','NOT_INTERESTED'), ('INTERESTED','LATER'), ('INTERESTED','OPTED_OUT'),
  ('DEMO_REQUESTED','DEMO_BOOKED'), ('DEMO_REQUESTED','NOT_INTERESTED'),
  ('DEMO_REQUESTED','LATER'), ('DEMO_REQUESTED','OPTED_OUT'),
  ('DEMO_BOOKED','CUSTOMER'), ('DEMO_BOOKED','NOT_INTERESTED'), ('DEMO_BOOKED','LATER'),
  ('DEMO_BOOKED','DEMO_REQUESTED'),
  ('LATER','QUALIFIED'), ('LATER','CONTACTED'), ('LATER','NOT_INTERESTED'),
  ('LATER','OPTED_OUT'), ('LATER','DO_NOT_CONTACT'),
  ('NOT_INTERESTED','OPTED_OUT'), ('NOT_INTERESTED','DO_NOT_CONTACT'),
  ('BOUNCED','INVALID'), ('BOUNCED','DO_NOT_CONTACT'),
  ('REJECTED','QUALIFIED'), ('REJECTED','DO_NOT_CONTACT')
ON CONFLICT DO NOTHING;

-- Terminal states. Nothing automated may ever move a lead out of these.
CREATE OR REPLACE FUNCTION acq.is_terminal_status(p_status acq.lead_status)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT p_status IN ('OPTED_OUT','DO_NOT_CONTACT','INVALID','CUSTOMER');
$fn$;

CREATE OR REPLACE FUNCTION acq.transition_lead(
  p_lead_id   uuid,
  p_to        acq.lead_status,
  p_reason    text DEFAULT NULL,
  p_actor     acq.actor DEFAULT 'SYSTEM',
  p_execution text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_from    acq.lead_status;
  v_optout  boolean;
  v_dnc     boolean;
  v_allowed boolean;
  -- These four can always be reached from any state: they only ever remove a
  -- lead from contact, never restore it.
  v_always  boolean;
BEGIN
  SELECT status, opt_out, do_not_contact
    INTO v_from, v_optout, v_dnc
    FROM acq.leads WHERE id = p_lead_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'lead_not_found');
  END IF;

  IF v_from = p_to THEN
    RETURN jsonb_build_object('ok', true, 'from', v_from, 'to', p_to, 'noop', true);
  END IF;

  v_always := p_to IN ('OPTED_OUT','DO_NOT_CONTACT','INVALID','BOUNCED');

  -- A lead that opted out or is marked do-not-contact can only ever move
  -- FURTHER away from contact. No actor -- not even a human operator -- can
  -- walk it back through this function; clearing acq.leads.opt_out is a
  -- separate, deliberate act that leaves its own audit trail.
  IF (v_optout OR v_dnc) AND NOT v_always AND p_to <> 'NOT_INTERESTED' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'lead_suppressed',
                              'from', v_from, 'to', p_to,
                              'opt_out', v_optout, 'do_not_contact', v_dnc);
  END IF;

  IF acq.is_terminal_status(v_from) AND NOT v_always AND p_actor <> 'HUMAN' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'terminal_status', 'from', v_from);
  END IF;

  SELECT v_always OR EXISTS (
    SELECT 1 FROM acq.status_transitions
    WHERE from_status = v_from AND to_status = p_to
  ) INTO v_allowed;

  IF NOT v_allowed AND p_actor <> 'HUMAN' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'illegal_transition',
                              'from', v_from, 'to', p_to);
  END IF;

  UPDATE acq.leads
     SET status = p_to,
         status_reason = p_reason,
         locked_by = NULL,
         locked_at = NULL
   WHERE id = p_lead_id;

  INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload, execution_id)
  VALUES (p_lead_id, 'STATUS_CHANGE', p_actor,
          format('%s -> %s', v_from, p_to),
          jsonb_build_object('from', v_from, 'to', p_to, 'reason', p_reason),
          p_execution);

  RETURN jsonb_build_object('ok', true, 'from', v_from, 'to', p_to);
END;
$fn$;

-- ---------------------------------------------------------------------
-- Suppression checks
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION acq.is_suppressed(
  p_email  text DEFAULT NULL,
  p_domain text DEFAULT NULL,
  p_phone  text DEFAULT NULL,
  p_lead   uuid DEFAULT NULL
) RETURNS boolean LANGUAGE sql STABLE AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM acq.opt_outs o
    WHERE (o.scope = 'EMAIL'  AND o.normalized_value = acq.normalize_email(p_email))
       OR (o.scope = 'DOMAIN' AND o.normalized_value = acq.normalize_domain(p_domain))
       OR (o.scope = 'PHONE'  AND o.normalized_value = p_phone)
       OR (o.scope = 'LEAD'   AND o.lead_id = p_lead)
  )
  OR EXISTS (
    SELECT 1 FROM acq.leads l
    WHERE l.id = p_lead AND (l.opt_out OR l.do_not_contact)
  );
$fn$;

CREATE OR REPLACE FUNCTION acq.apply_opt_out(
  p_scope    acq.suppression_scope,
  p_value    text,
  p_reason   acq.suppression_reason,
  p_source   text,
  p_lead_id  uuid DEFAULT NULL,
  p_evidence jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
  v_norm text;
  v_id   uuid;
BEGIN
  v_norm := CASE p_scope
              WHEN 'EMAIL'  THEN acq.normalize_email(p_value)
              WHEN 'DOMAIN' THEN acq.normalize_domain(p_value)
              WHEN 'PHONE'  THEN acq.normalize_phone(p_value)
              ELSE lower(btrim(coalesce(p_value, p_lead_id::text)))
            END;

  IF v_norm IS NULL THEN
    RAISE EXCEPTION 'apply_opt_out: value % could not be normalized for scope %', p_value, p_scope;
  END IF;

  INSERT INTO acq.opt_outs (scope, value, normalized_value, reason, source, lead_id, evidence)
  VALUES (p_scope, p_value, v_norm, p_reason, p_source, p_lead_id, p_evidence)
  ON CONFLICT (scope, normalized_value) DO UPDATE
    SET evidence = acq.opt_outs.evidence || EXCLUDED.evidence
  RETURNING id INTO v_id;

  IF p_lead_id IS NOT NULL THEN
    -- Only a genuine request from the prospect sets the opt_out flag and moves
    -- the lead to OPTED_OUT. A hard bounce suppresses the ADDRESS (the row
    -- inserted above) but is not a statement of intent, so the caller --
    -- acq.record_bounce -- owns that status change instead.
    IF p_reason IN ('OPT_OUT_REQUEST','COMPLAINT','DELETION_REQUEST','LEGAL') THEN
      UPDATE acq.leads
         SET opt_out = true, next_follow_up_at = NULL
       WHERE id = p_lead_id;
      PERFORM acq.transition_lead(p_lead_id, 'OPTED_OUT', format('opt_out:%s', p_reason), 'PROSPECT');
    END IF;

    PERFORM acq.stop_follow_ups(p_lead_id, format('suppressed:%s', p_reason));
  END IF;

  RETURN v_id;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Follow-up control
-- ---------------------------------------------------------------------

-- Called the instant a reply or opt-out is detected. Cancels scheduled
-- follow-ups AND any email still sitting in the outbound queue, so a reply
-- that lands between queueing and sending still stops the send.
CREATE OR REPLACE FUNCTION acq.stop_follow_ups(p_lead_id uuid, p_reason text)
RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
  v_cancelled int := 0;
  v_emails    int := 0;
BEGIN
  UPDATE acq.follow_ups
     SET status = 'CANCELLED', cancelled_reason = p_reason
   WHERE lead_id = p_lead_id AND status = 'SCHEDULED';
  GET DIAGNOSTICS v_cancelled = ROW_COUNT;

  UPDATE acq.emails
     SET status = 'CANCELLED', error = p_reason
   WHERE lead_id = p_lead_id
     AND status IN ('DRAFT','PENDING_APPROVAL','READY_TO_SEND','QUEUED');
  GET DIAGNOSTICS v_emails = ROW_COUNT;

  UPDATE acq.leads SET next_follow_up_at = NULL WHERE id = p_lead_id;

  IF v_cancelled + v_emails > 0 THEN
    INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
    VALUES (p_lead_id, 'FOLLOW_UPS_STOPPED', 'SYSTEM',
            format('cancelled %s follow-ups, %s queued emails', v_cancelled, v_emails),
            jsonb_build_object('reason', p_reason));
  END IF;

  RETURN v_cancelled + v_emails;
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.schedule_follow_up(
  p_lead_id     uuid,
  p_campaign_id uuid,
  p_step_no     int
) RETURNS timestamptz LANGUAGE plpgsql AS $fn$
DECLARE
  v_step   acq.sequence_steps%ROWTYPE;
  v_camp   acq.campaigns%ROWTYPE;
  v_days   int;
  v_due    timestamptz;
  v_local  timestamp;
BEGIN
  SELECT * INTO v_camp FROM acq.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT * INTO v_step FROM acq.sequence_steps
   WHERE campaign_id = p_campaign_id AND step_no = p_step_no AND enabled;
  IF NOT FOUND THEN RETURN NULL; END IF;          -- sequence exhausted

  IF p_step_no > v_camp.max_follow_ups THEN
    RETURN NULL;                                   -- hard cap on follow-ups
  END IF;

  -- Jitter the delay so the cadence does not look machine-generated.
  v_days := v_step.min_delay_days
            + floor(random() * (v_step.max_delay_days - v_step.min_delay_days + 1))::int;

  v_local := (now() AT TIME ZONE v_camp.timezone) + (v_days || ' days')::interval;

  -- Land inside the sending window, and roll off non-sending days.
  v_local := date_trunc('day', v_local)
             + v_camp.sending_window_start
             + (random() * extract(epoch FROM (v_camp.sending_window_end - v_camp.sending_window_start)))
               * interval '1 second';

  WHILE NOT (EXTRACT(ISODOW FROM v_local)::int = ANY (v_camp.sending_days)) LOOP
    v_local := v_local + interval '1 day';
  END LOOP;

  v_due := v_local AT TIME ZONE v_camp.timezone;

  INSERT INTO acq.follow_ups (lead_id, campaign_id, step_no, due_at, status)
  VALUES (p_lead_id, p_campaign_id, p_step_no, v_due, 'SCHEDULED')
  ON CONFLICT (lead_id, campaign_id, step_no) DO UPDATE
    SET due_at = EXCLUDED.due_at,
        status = 'SCHEDULED',
        cancelled_reason = NULL
    WHERE acq.follow_ups.status = 'SCHEDULED';

  UPDATE acq.leads SET next_follow_up_at = v_due WHERE id = p_lead_id;

  RETURN v_due;
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.due_follow_ups(p_limit int DEFAULT 25)
RETURNS TABLE (
  follow_up_id uuid, lead_id uuid, campaign_id uuid, step_no int,
  clinic_name text, prompt_key text
) LANGUAGE sql AS $fn$
  SELECT f.id, f.lead_id, f.campaign_id, f.step_no, l.clinic_name, s.prompt_key
    FROM acq.follow_ups f
    JOIN acq.leads l     ON l.id = f.lead_id
    JOIN acq.campaigns c ON c.id = f.campaign_id
    JOIN acq.sequence_steps s
         ON s.campaign_id = f.campaign_id AND s.step_no = f.step_no AND s.enabled
   WHERE f.status = 'SCHEDULED'
     AND f.due_at <= now()
     AND c.status = 'ACTIVE'
     AND l.status IN ('CONTACTED','FOLLOW_UP_1','FOLLOW_UP_2')
     AND NOT l.opt_out
     AND NOT l.do_not_contact
     AND l.replied_at IS NULL
     AND f.step_no <= c.max_follow_ups
     AND NOT acq.is_suppressed(l.public_email::text, l.domain, l.phone, l.id)
     -- never queue a step twice
     AND NOT EXISTS (
       SELECT 1 FROM acq.emails e
        WHERE e.lead_id = f.lead_id AND e.campaign_id = f.campaign_id
          AND e.step_no = f.step_no
     )
   ORDER BY l.lead_score DESC, f.due_at
   LIMIT p_limit;
$fn$;

-- ---------------------------------------------------------------------
-- Work claiming (safe under concurrent / retried executions)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION acq.claim_leads(
  p_statuses acq.lead_status[],
  p_limit    int,
  p_worker   text,
  p_stale_lock_minutes int DEFAULT 15
) RETURNS SETOF acq.leads LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  UPDATE acq.leads l
     SET locked_by = p_worker, locked_at = now()
   WHERE l.id IN (
     SELECT c.id FROM acq.leads c
      WHERE c.status = ANY (p_statuses)
        AND NOT c.opt_out
        AND NOT c.do_not_contact
        AND (c.locked_at IS NULL
             OR c.locked_at < now() - make_interval(mins => p_stale_lock_minutes))
      ORDER BY c.lead_score DESC, c.created_at
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
   )
  RETURNING l.*;
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.release_lead(p_lead_id uuid)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE acq.leads SET locked_by = NULL, locked_at = NULL WHERE id = p_lead_id;
$fn$;

-- Returns the subset of external references we have NOT seen before.
-- Called before paid Place Details lookups so we never pay to re-fetch a
-- business that is already in the CRM. This is the single biggest cost lever
-- in the whole system.
CREATE OR REPLACE FUNCTION acq.filter_unknown_refs(
  p_key_type acq.identity_key_type,
  p_values   text[]
) RETURNS TABLE (ref text) LANGUAGE sql STABLE AS $fn$
  SELECT v
    FROM unnest(p_values) AS v
   WHERE NOT EXISTS (
     SELECT 1 FROM acq.lead_identity_keys k
      WHERE k.key_type = p_key_type AND k.key_value = v
   );
$fn$;

CREATE OR REPLACE FUNCTION acq.next_discovery_tasks(p_limit int DEFAULT 5)
RETURNS SETOF acq.discovery_tasks LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  UPDATE acq.discovery_tasks d
     SET last_run_at = now(),
         next_run_at = now() + make_interval(days => d.cadence_days)
   WHERE d.id IN (
     SELECT t.id FROM acq.discovery_tasks t
       JOIN acq.markets m ON m.id = t.market_id AND m.enabled
      WHERE t.enabled AND t.next_run_at <= now()
      ORDER BY t.priority_tier, t.next_run_at
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
   )
  RETURNING d.*;
END;
$fn$;
