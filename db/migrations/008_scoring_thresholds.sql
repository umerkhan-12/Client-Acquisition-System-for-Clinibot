-- =====================================================================
-- Migration 008: separate thresholds for the two scoring phases
--
-- Fixes a calibration bug that made the pipeline produce nothing.
--
-- acq.compute_score() runs twice: DETERMINISTIC before any AI spend, and
-- BLENDED after research. Both were compared against the same `qualify`
-- threshold of 45 — but that number was calibrated against the blended score,
-- which is 40-plus points higher because it includes signals only available
-- after research.
--
-- Observed on a real workflow-20 execution against six seeded leads: a dental
-- clinic with a website, a phone and a published WhatsApp number scored 38
-- (website 8 + phone 3 + WhatsApp 15 + tier-1 12) and was REJECTED before it
-- was ever researched. All six leads were rejected. The system would have
-- discovered clinics and thrown every one of them away.
--
-- The two phases are asking different questions:
--
--   DETERMINISTIC — "is this worth ~$0.01 of research?"  Should be permissive.
--                   The hard filtering already happened in workflow 20's
--                   triage: no contact channel, hospital, pharmacy, no website.
--
--   BLENDED       — "is this worth an email?"  Should be selective, and by then
--                   the AI-confirmed signals are actually present.
--
-- At 20: a tier-1 clinic with a website and any contact channel gets researched
-- (23+), while a tier-2 or tier-3 listing without WhatsApp (11-15) does not.
-- WhatsApp presence is the strongest single signal for a WhatsApp receptionist,
-- so it is what lifts a general clinic over the line.
-- =====================================================================

SET search_path = acq, public;

UPDATE acq.scoring_configs
   SET thresholds = thresholds || jsonb_build_object('qualify_deterministic', 20)
 WHERE version = 'v1'
   AND NOT thresholds ? 'qualify_deterministic';

CREATE OR REPLACE FUNCTION acq.compute_score(
  p_lead_id uuid,
  p_phase   text DEFAULT 'DETERMINISTIC'
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_l        acq.leads%ROWTYPE;
  v_r        acq.lead_research%ROWTYPE;
  v_cfg      acq.scoring_configs%ROWTYPE;
  w          jsonb;
  th         jsonb;
  v_break    jsonb := '{}'::jsonb;
  v_score    int := 0;
  v_min_conf numeric;
  v_gate     int;
  v_gate_key text;
BEGIN
  SELECT * INTO v_l FROM acq.leads WHERE id = p_lead_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'lead_not_found'); END IF;

  SELECT * INTO v_cfg FROM acq.scoring_configs WHERE active LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'no_active_scoring_config'); END IF;

  w  := v_cfg.weights;
  th := v_cfg.thresholds;
  v_min_conf := coalesce((th->>'min_research_confidence')::numeric, 0.5);

  -- ---- deterministic signals (free) ----------------------------------
  IF v_l.website IS NOT NULL THEN
    v_score := v_score + coalesce((w->>'has_website')::int, 0);
    v_break := v_break || jsonb_build_object('has_website', (w->>'has_website')::int);
  END IF;

  IF v_l.public_email IS NOT NULL THEN
    v_score := v_score + coalesce((w->>'has_public_email')::int, 0);
    v_break := v_break || jsonb_build_object('has_public_email', (w->>'has_public_email')::int);
  END IF;

  IF v_l.whatsapp IS NOT NULL THEN
    v_score := v_score + coalesce((w->>'has_whatsapp')::int, 0);
    v_break := v_break || jsonb_build_object('has_whatsapp', (w->>'has_whatsapp')::int);
  END IF;

  IF v_l.phone IS NOT NULL THEN
    v_score := v_score + coalesce((w->>'has_phone')::int, 0);
    v_break := v_break || jsonb_build_object('has_phone', (w->>'has_phone')::int);
  END IF;

  IF coalesce(v_l.doctor_count, 0) >= 2 THEN
    v_score := v_score + coalesce((w->>'multiple_doctors')::int, 0);
    v_break := v_break || jsonb_build_object('multiple_doctors', (w->>'multiple_doctors')::int);
  END IF;

  v_score := v_score + coalesce((w->'category_tier'->>(v_l.priority_tier::text))::int, 0);
  v_break := v_break || jsonb_build_object(
    'category_tier_' || v_l.priority_tier,
    coalesce((w->'category_tier'->>(v_l.priority_tier::text))::int, 0));

  IF coalesce((v_l.raw #>> '{GOOGLE_PLACES,userRatingCount}')::int,
              (v_l.raw #>> '{OSM,review_count}')::int, 0)
     >= coalesce((th->>'active_listing_reviews')::int, 20) THEN
    v_score := v_score + coalesce((w->>'active_listing')::int, 0);
    v_break := v_break || jsonb_build_object('active_listing', (w->>'active_listing')::int);
  END IF;

  IF v_l.public_email IS NULL AND v_l.whatsapp IS NULL AND v_l.phone IS NULL THEN
    v_score := v_score + coalesce((w->>'no_contact_channel')::int, -40);
    v_break := v_break || jsonb_build_object('no_contact_channel', (w->>'no_contact_channel')::int);
  END IF;

  IF v_l.clinic_name ~* '(hospital|trust|foundation|government|govt|welfare|charitable)' THEN
    v_score := v_score + coalesce((w->>'large_institution')::int, 0);
    v_break := v_break || jsonb_build_object('large_institution', (w->>'large_institution')::int);
  END IF;

  -- ---- AI-confirmed signals (only in BLENDED phase) -------------------
  IF p_phase = 'BLENDED' THEN
    SELECT * INTO v_r FROM acq.lead_research
     WHERE lead_id = p_lead_id AND is_current LIMIT 1;

    IF FOUND AND coalesce(v_r.confidence, 0) >= v_min_conf THEN
      IF coalesce(v_r.doctor_count_estimate, 0) >= 2 THEN
        v_score := v_score + coalesce((w->>'confirmed_multiple_doctors')::int, 0);
        v_break := v_break || jsonb_build_object('confirmed_multiple_doctors', (w->>'confirmed_multiple_doctors')::int);
      END IF;
      IF v_r.has_whatsapp THEN
        v_score := v_score + coalesce((w->>'confirmed_whatsapp')::int, 0);
        v_break := v_break || jsonb_build_object('confirmed_whatsapp', (w->>'confirmed_whatsapp')::int);
      END IF;
      IF coalesce(v_r.has_online_booking, false) = false THEN
        v_score := v_score + coalesce((w->>'no_online_booking_gap')::int, 0);
        v_break := v_break || jsonb_build_object('no_online_booking_gap', (w->>'no_online_booking_gap')::int);
      END IF;
      IF (v_r.raw->>'advertises_appointments')::boolean THEN
        v_score := v_score + coalesce((w->>'advertises_appointments')::int, 0);
        v_break := v_break || jsonb_build_object('advertises_appointments', (w->>'advertises_appointments')::int);
      END IF;
      IF (v_r.raw->>'high_value_services')::boolean THEN
        v_score := v_score + coalesce((w->>'high_value_service')::int, 0);
        v_break := v_break || jsonb_build_object('high_value_service', (w->>'high_value_service')::int);
      END IF;
      IF (v_r.raw->>'active_social_presence')::boolean THEN
        v_score := v_score + coalesce((w->>'active_social')::int, 0);
        v_break := v_break || jsonb_build_object('active_social', (w->>'active_social')::int);
      END IF;
    ELSE
      v_break := v_break || jsonb_build_object('ai_signals_skipped', 'low_or_missing_research_confidence');
    END IF;
  END IF;

  v_score := greatest(0, least(100, v_score));

  -- The gate depends on the phase. DETERMINISTIC asks "worth researching?";
  -- BLENDED asks "worth emailing?". Comparing both to the same number rejected
  -- every lead before it could earn the points that number assumed.
  IF p_phase = 'BLENDED' THEN
    v_gate_key := 'qualify';
    v_gate := coalesce((th->>'qualify')::int, 45);
  ELSE
    v_gate_key := 'qualify_deterministic';
    v_gate := coalesce((th->>'qualify_deterministic')::int, 20);
  END IF;

  INSERT INTO acq.lead_scores (lead_id, score, breakdown, scorer, scoring_version)
  VALUES (p_lead_id, v_score, v_break, p_phase, v_cfg.version);

  UPDATE acq.leads
     SET lead_score = v_score,
         score_breakdown = v_break,
         scoring_version = v_cfg.version,
         ai_score = CASE WHEN p_phase = 'BLENDED' THEN v_score ELSE ai_score END
   WHERE id = p_lead_id;

  RETURN jsonb_build_object(
    'ok', true,
    'lead_id', p_lead_id,
    'score', v_score,
    'phase', p_phase,
    'breakdown', v_break,
    'qualifies', v_score >= v_gate,
    'gate', v_gate,
    'gate_key', v_gate_key,
    'auto_send_eligible', v_score >= coalesce((th->>'auto_send')::int, 70),
    'hot', v_score >= coalesce((th->>'hot')::int, 80),
    'thresholds', th
  );
END;
$fn$;
