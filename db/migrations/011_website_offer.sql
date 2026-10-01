-- =====================================================================
-- Migration 011: a second offer — websites for businesses that lack one
--
-- Until now every lead was a Clinibot prospect, and the pipeline treated a
-- missing website as a reason to stop: nothing to research, nothing to
-- personalise from. For the website-services offer that same lead is the
-- best prospect there is.
--
-- So a lead now carries an `offer`:
--
--   CLINIBOT  the original pipeline, unchanged: research -> email -> SMTP.
--   WEB       businesses with no website, or a weak one. Found by discovery
--             tasks tagged WEB, or rerouted from CLINIBOT at qualification
--             when a clinic has no website and no public email (workflow 20
--             would otherwise reject it).
--
-- WEB leads are contacted by a HUMAN, by WhatsApp or phone, from a queue of
-- drafted messages (acq.manual_outreach). The system drafts and tracks; it
-- never sends. That is deliberate:
--
--   * Most of these businesses publish a phone number and no email, so the
--     email path cannot reach them anyway.
--   * Automated WhatsApp from a personal number gets the number banned, and
--     a cold bulk message is spam. One person sending twenty considered
--     messages a day is neither.
--   * It keeps invariant 4 intact: acq.claim_send_slots() remains the only
--     path to SMTP. Nothing here sends mail.
--
-- Everything that decides — which offer, the score, the daily draft cap,
-- the state transitions — is SQL, for the usual reason: n8n runs overlap.
-- =====================================================================

SET search_path = acq, public;

-- ---------------------------------------------------------------------
-- The offer dimension
-- ---------------------------------------------------------------------
ALTER TABLE acq.leads           ADD COLUMN IF NOT EXISTS offer text NOT NULL DEFAULT 'CLINIBOT';
ALTER TABLE acq.discovery_tasks ADD COLUMN IF NOT EXISTS offer text NOT NULL DEFAULT 'CLINIBOT';
ALTER TABLE acq.scoring_configs ADD COLUMN IF NOT EXISTS offer text NOT NULL DEFAULT 'CLINIBOT';

-- Overpass selectors for WEB discovery, e.g. '["shop"~"^(hairdresser|beauty)$"]'.
-- CLINIBOT tasks leave it NULL and keep the healthcare query.
ALTER TABLE acq.discovery_tasks ADD COLUMN IF NOT EXISTS osm_selectors text[];

DO $mig$ BEGIN
  ALTER TABLE acq.leads ADD CONSTRAINT leads_offer_known
    CHECK (offer IN ('CLINIBOT','WEB'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  ALTER TABLE acq.discovery_tasks ADD CONSTRAINT discovery_tasks_offer_known
    CHECK (offer IN ('CLINIBOT','WEB'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  ALTER TABLE acq.scoring_configs ADD CONSTRAINT scoring_configs_offer_known
    CHECK (offer IN ('CLINIBOT','WEB'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

-- One active scoring config PER OFFER, replacing one active config overall.
--
-- The replacement keeps the old index's NAME on purpose. Every migration is
-- re-run by bootstrap.sh, and 001 says `CREATE UNIQUE INDEX IF NOT EXISTS
-- scoring_configs_one_active ON (active)`. Under a new name, a re-run of 001
-- would try to rebuild the one-active-overall index over two active rows and
-- abort. Under the same name it finds the index present and skips it.
DROP INDEX IF EXISTS acq.scoring_configs_one_active;
CREATE UNIQUE INDEX scoring_configs_one_active
  ON acq.scoring_configs (offer) WHERE active;

CREATE INDEX IF NOT EXISTS leads_offer_status_idx ON acq.leads (offer, status, lead_score DESC);

-- ---------------------------------------------------------------------
-- Settings for the WEB offer
-- ---------------------------------------------------------------------
INSERT INTO acq.settings (key, value, description) VALUES
('web.adopt_clinics_without_website', 'true'::jsonb,
 'At qualification, a CLINIBOT lead with no website and no public email becomes a WEB lead instead of being rejected.'),
('web.portfolio_url',          '""'::jsonb,
 'Link included in website pitches. Leave empty and the message mentions no link at all.'),
('web.message_language',       '"simple English, with a short Roman Urdu greeting (Assalamualaikum)"'::jsonb,
 'Language the WhatsApp draft is written in.'),
('web.max_drafts_per_day',     '20'::jsonb,
 'Upper bound on new WhatsApp/phone drafts per day. Keep it at what one person can send carefully; a new WhatsApp number that messages strangers in bulk gets banned.'),
('web.max_drafts_per_run',     '8'::jsonb,  'Drafts written per scheduled run of workflow 45.'),
('web.followup_enabled',       'true'::jsonb, 'Schedule one follow-up message after a pitch goes unanswered.'),
('web.followup_days',          '3'::jsonb,  'Days after the first message before the follow-up is due.'),
('web.whatsapp_mobile_prefixes', '["+923"]'::jsonb,
 'E.164 prefixes treated as mobile (WhatsApp-capable). A number outside these gets a call script instead.'),
('web.fallback_template',
 to_jsonb('Assalamualaikum! I came across {{name}}{{area_clause}} and noticed you don''t have a proper website yet. I''m {{sender}}, a web developer. I build simple, mobile-friendly business websites with a WhatsApp button, your services and your location. I can make a free sample design for {{name}} first, so you can see how it would look before deciding anything. Would you like me to make one?{{portfolio_clause}}'::text),
 'Used when the AI draft is unavailable or fails its checks. Placeholders: {{name}} {{area_clause}} {{sender}} {{portfolio_clause}}.'),
('web.followup_template',
 to_jsonb('Assalamualaikum, just following up on my message about a website for {{name}}. Happy to make the free sample whenever suits you. If it''s not something you need, no problem at all, just let me know and I won''t message again.'::text),
 'Follow-up message. Placeholders: {{name}}.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Scoring for the WEB offer
--
-- The question is different from Clinibot's. Not "does this clinic run on
-- WhatsApp?" but "does this business need a website, and is it active
-- enough to pay for one?" A busy listing with no website is the best case.
-- ---------------------------------------------------------------------
INSERT INTO acq.scoring_configs (version, offer, active, weights, thresholds) VALUES
('web-v1', 'WEB', true,
 '{
    "no_website": 35,
    "has_whatsapp": 10,
    "has_phone": 6,
    "has_public_email": 4,
    "active_listing": 12,
    "well_rated": 5,
    "category_tier": { "1": 15, "2": 8, "3": 0 },

    "site_unreachable": 25,
    "site_parked": 25,
    "no_https": 8,
    "not_mobile_friendly": 15,
    "slow_or_heavy": 6,
    "outdated": 8,
    "no_contact_cta": 6,

    "no_contact_channel": -60,
    "large_institution": -20
  }'::jsonb,
 '{
    "qualify_deterministic": 25,
    "qualify": 45,
    "hot": 75,
    "auto_send": 101,
    "active_listing_reviews": 15,
    "well_rated_min": 4.0
  }'::jsonb)
ON CONFLICT (version) DO NOTHING;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- A Facebook page or a link-in-bio is not a website, for the purpose of
-- deciding whether a business needs one.
CREATE OR REPLACE FUNCTION acq.is_social_only_url(p_url text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT coalesce(acq.normalize_domain(p_url), '') ~
    '(^|\.)(facebook\.com|fb\.com|fb\.me|instagram\.com|linktr\.ee|wa\.me|whatsapp\.com|tiktok\.com|youtube\.com|twitter\.com|x\.com|linkedin\.com|google\.com|business\.site|g\.page|daraz\.pk|foodpanda\.pk)$';
$fn$;

CREATE OR REPLACE FUNCTION acq.has_real_website(p_url text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT nullif(btrim(coalesce(p_url, '')), '') IS NOT NULL
     AND NOT acq.is_social_only_url(p_url);
$fn$;

-- Which number to put in front of a human, and how to use it.
CREATE OR REPLACE FUNCTION acq.manual_channel(p_lead acq.leads)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_prefixes jsonb;
  v_mobile   boolean;
BEGIN
  SELECT value INTO v_prefixes FROM acq.settings WHERE key = 'web.whatsapp_mobile_prefixes';
  v_prefixes := coalesce(v_prefixes, '[]'::jsonb);

  IF p_lead.whatsapp IS NOT NULL THEN
    RETURN jsonb_build_object('channel', 'WHATSAPP', 'to_value', p_lead.whatsapp);
  END IF;

  IF p_lead.phone IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(v_prefixes) pfx
       WHERE p_lead.phone LIKE pfx || '%'
    ) INTO v_mobile;
    RETURN jsonb_build_object('channel', CASE WHEN v_mobile THEN 'WHATSAPP' ELSE 'PHONE_CALL' END,
                              'to_value', p_lead.phone);
  END IF;

  RETURN NULL;
END;
$fn$;

-- Single entry point for discovery, so a WEB task produces WEB leads.
--
-- The first offer to discover a business keeps it. A clinic found by both a
-- CLINIBOT task and a WEB task is one lead, not two pitches.
CREATE OR REPLACE FUNCTION acq.upsert_lead_for_offer(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_offer text := upper(coalesce(nullif(p->>'offer', ''), 'CLINIBOT'));
  v_res   jsonb;
BEGIN
  IF v_offer NOT IN ('CLINIBOT','WEB') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_offer', 'offer', v_offer);
  END IF;

  v_res := acq.upsert_lead(p);

  IF (v_res->>'ok')::boolean AND (v_res->>'is_new')::boolean AND v_offer <> 'CLINIBOT' THEN
    UPDATE acq.leads SET offer = v_offer WHERE id = (v_res->>'lead_id')::uuid;
  END IF;

  RETURN v_res || jsonb_build_object('offer', v_offer);
END;
$fn$;

-- Workflow 20 calls this first for every NEW lead. A clinic with nothing to
-- research and no address to email cannot be a Clinibot prospect, but it can
-- be a website prospect. Returns the (possibly rerouted) lead.
CREATE OR REPLACE FUNCTION acq.route_offer(p_lead_id uuid)
RETURNS SETOF acq.leads LANGUAGE plpgsql AS $fn$
DECLARE
  v_adopt boolean;
  v_moved uuid;
BEGIN
  SELECT (value)::boolean INTO v_adopt FROM acq.settings
   WHERE key = 'web.adopt_clinics_without_website';

  IF coalesce(v_adopt, false) THEN
    UPDATE acq.leads l
       SET offer = 'WEB'
     WHERE l.id = p_lead_id
       AND l.offer = 'CLINIBOT'
       AND l.status = 'NEW'
       AND NOT acq.has_real_website(l.website)
       AND l.public_email IS NULL
       AND (l.phone IS NOT NULL OR l.whatsapp IS NOT NULL)
    RETURNING l.id INTO v_moved;

    IF v_moved IS NOT NULL THEN
      INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
      VALUES (v_moved, 'OFFER_ROUTED', 'SYSTEM',
              'CLINIBOT -> WEB: no website and no public email',
              jsonb_build_object('from', 'CLINIBOT', 'to', 'WEB'));
    END IF;
  END IF;

  RETURN QUERY SELECT * FROM acq.leads WHERE id = p_lead_id;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Website audits — the WEB offer's equivalent of acq.lead_research.
-- Deterministic: workflow 25 reads one public page and records what it
-- saw. No AI.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS acq.website_audits (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id          uuid NOT NULL REFERENCES acq.leads(id) ON DELETE CASCADE,
  is_current       boolean NOT NULL DEFAULT true,
  url              text,
  final_url        text,
  robots_allowed   boolean,
  reachable        boolean,
  status_code      int,
  https            boolean,
  has_viewport     boolean,
  title            text,
  page_bytes       int,
  elapsed_ms       int,
  copyright_year   int,
  has_tel_link     boolean,
  has_whatsapp_link boolean,
  has_form         boolean,
  generator        text,
  parked           boolean,
  issues           text[] NOT NULL DEFAULT '{}',
  raw              jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  stale_after      timestamptz NOT NULL DEFAULT (now() + interval '90 days')
);

CREATE UNIQUE INDEX IF NOT EXISTS website_audits_one_current
  ON acq.website_audits (lead_id) WHERE is_current;

-- ---------------------------------------------------------------------
-- Manual outreach — drafted messages a person sends by WhatsApp or phone.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS acq.manual_outreach (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id                uuid NOT NULL REFERENCES acq.leads(id) ON DELETE CASCADE,
  step_no                int NOT NULL DEFAULT 0,
  channel                text NOT NULL,
  to_value               text NOT NULL,
  message                text NOT NULL,
  status                 text NOT NULL DEFAULT 'READY',
  due_at                 timestamptz NOT NULL DEFAULT now(),
  personalization_reason text,
  ai_confidence          numeric(4,3),
  model                  text,
  prompt_version         text,
  draft_source           text NOT NULL DEFAULT 'AI',      -- AI | TEMPLATE
  draft_notes            text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  sent_at                timestamptz,
  sent_by                text,
  closed_reason          text,
  -- Idempotent like acq.emails: one message per lead per step, so a retried
  -- run of workflow 45 cannot queue a second pitch.
  CONSTRAINT manual_outreach_idempotent UNIQUE (lead_id, step_no),
  CONSTRAINT manual_outreach_channel CHECK (channel IN ('WHATSAPP','PHONE_CALL')),
  CONSTRAINT manual_outreach_status CHECK (status IN ('READY','SCHEDULED','SENT','SKIPPED','CANCELLED')),
  CONSTRAINT manual_outreach_source CHECK (draft_source IN ('AI','TEMPLATE')),
  CONSTRAINT manual_outreach_confidence CHECK (ai_confidence IS NULL OR ai_confidence BETWEEN 0 AND 1)
);

CREATE INDEX IF NOT EXISTS manual_outreach_queue_idx
  ON acq.manual_outreach (status, due_at) WHERE status IN ('READY','SCHEDULED');
CREATE INDEX IF NOT EXISTS manual_outreach_created_idx ON acq.manual_outreach (created_at DESC);

-- ---------------------------------------------------------------------
-- compute_score, now offer-aware.
--
-- CLINIBOT scoring is unchanged from migration 008 line for line; it only
-- selects the CLINIBOT config instead of "the" active config, of which there
-- are now two. The WEB branch is new.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.compute_score(
  p_lead_id uuid,
  p_phase   text DEFAULT 'DETERMINISTIC'
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_l        acq.leads%ROWTYPE;
  v_r        acq.lead_research%ROWTYPE;
  v_a        acq.website_audits%ROWTYPE;
  v_cfg      acq.scoring_configs%ROWTYPE;
  w          jsonb;
  th         jsonb;
  v_break    jsonb := '{}'::jsonb;
  v_score    int := 0;
  v_min_conf numeric;
  v_gate     int;
  v_gate_key text;
  v_reviews  int;
  v_rating   numeric;
  v_real_site boolean;
  v_issue    text;
BEGIN
  SELECT * INTO v_l FROM acq.leads WHERE id = p_lead_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'lead_not_found'); END IF;

  SELECT * INTO v_cfg FROM acq.scoring_configs WHERE active AND offer = v_l.offer LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_active_scoring_config', 'offer', v_l.offer);
  END IF;

  w  := v_cfg.weights;
  th := v_cfg.thresholds;
  v_min_conf := coalesce((th->>'min_research_confidence')::numeric, 0.5);
  v_reviews  := coalesce((v_l.raw #>> '{GOOGLE_PLACES,userRatingCount}')::int,
                         (v_l.raw #>> '{OSM,review_count}')::int, 0);

  IF v_l.offer = 'WEB' THEN
    -- ================= WEB: does this business need a website? ==========
    v_real_site := acq.has_real_website(v_l.website);

    IF NOT v_real_site THEN
      v_score := v_score + coalesce((w->>'no_website')::int, 0);
      v_break := v_break || jsonb_build_object('no_website', (w->>'no_website')::int);
      IF v_l.website IS NOT NULL THEN
        v_break := v_break || jsonb_build_object('social_only_website', 0);
      END IF;
    END IF;

    IF v_l.whatsapp IS NOT NULL THEN
      v_score := v_score + coalesce((w->>'has_whatsapp')::int, 0);
      v_break := v_break || jsonb_build_object('has_whatsapp', (w->>'has_whatsapp')::int);
    END IF;
    IF v_l.phone IS NOT NULL THEN
      v_score := v_score + coalesce((w->>'has_phone')::int, 0);
      v_break := v_break || jsonb_build_object('has_phone', (w->>'has_phone')::int);
    END IF;
    IF v_l.public_email IS NOT NULL THEN
      v_score := v_score + coalesce((w->>'has_public_email')::int, 0);
      v_break := v_break || jsonb_build_object('has_public_email', (w->>'has_public_email')::int);
    END IF;

    -- An active listing is a business with customers, i.e. one that can pay.
    IF v_reviews >= coalesce((th->>'active_listing_reviews')::int, 15) THEN
      v_score := v_score + coalesce((w->>'active_listing')::int, 0);
      v_break := v_break || jsonb_build_object('active_listing', (w->>'active_listing')::int);
    END IF;
    v_rating := nullif(v_l.raw #>> '{GOOGLE_PLACES,rating}', '')::numeric;
    IF v_rating IS NOT NULL AND v_rating >= coalesce((th->>'well_rated_min')::numeric, 4.0) THEN
      v_score := v_score + coalesce((w->>'well_rated')::int, 0);
      v_break := v_break || jsonb_build_object('well_rated', (w->>'well_rated')::int);
    END IF;

    v_score := v_score + coalesce((w->'category_tier'->>(v_l.priority_tier::text))::int, 0);
    v_break := v_break || jsonb_build_object(
      'category_tier_' || v_l.priority_tier,
      coalesce((w->'category_tier'->>(v_l.priority_tier::text))::int, 0));

    IF v_l.public_email IS NULL AND v_l.whatsapp IS NULL AND v_l.phone IS NULL THEN
      v_score := v_score + coalesce((w->>'no_contact_channel')::int, -60);
      v_break := v_break || jsonb_build_object('no_contact_channel', (w->>'no_contact_channel')::int);
    END IF;
    IF v_l.clinic_name ~* '(hospital|trust|foundation|government|govt|welfare|charitable|university)' THEN
      v_score := v_score + coalesce((w->>'large_institution')::int, 0);
      v_break := v_break || jsonb_build_object('large_institution', (w->>'large_institution')::int);
    END IF;

    -- Audit findings: the weaker the site, the stronger the pitch.
    IF p_phase = 'BLENDED' AND v_real_site THEN
      SELECT * INTO v_a FROM acq.website_audits WHERE lead_id = p_lead_id AND is_current LIMIT 1;
      IF FOUND THEN
        FOREACH v_issue IN ARRAY v_a.issues LOOP
          IF w ? v_issue THEN
            v_score := v_score + (w->>v_issue)::int;
            v_break := v_break || jsonb_build_object(v_issue, (w->>v_issue)::int);
          END IF;
        END LOOP;
      ELSE
        v_break := v_break || jsonb_build_object('audit_signals_skipped', 'no_current_audit');
      END IF;
    END IF;

    -- A business with no website has nothing to audit, so its deterministic
    -- score is already the final answer and is held to the selective gate.
    -- One WITH a website only has to be worth the (free) audit at this point.
    IF p_phase = 'BLENDED' OR NOT v_real_site THEN
      v_gate_key := 'qualify';
      v_gate := coalesce((th->>'qualify')::int, 45);
    ELSE
      v_gate_key := 'qualify_deterministic';
      v_gate := coalesce((th->>'qualify_deterministic')::int, 25);
    END IF;

  ELSE
    -- ================= CLINIBOT: unchanged from migration 008 ============
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

    IF v_reviews >= coalesce((th->>'active_listing_reviews')::int, 20) THEN
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

    IF p_phase = 'BLENDED' THEN
      v_gate_key := 'qualify';
      v_gate := coalesce((th->>'qualify')::int, 45);
    ELSE
      v_gate_key := 'qualify_deterministic';
      v_gate := coalesce((th->>'qualify_deterministic')::int, 20);
    END IF;
  END IF;

  v_score := greatest(0, least(100, v_score));

  INSERT INTO acq.lead_scores (lead_id, score, breakdown, scorer, scoring_version)
  VALUES (p_lead_id, v_score, v_break, p_phase, v_cfg.version);

  UPDATE acq.leads
     SET lead_score = v_score,
         score_breakdown = v_break,
         scoring_version = v_cfg.version,
         ai_score = CASE WHEN p_phase = 'BLENDED' AND v_l.offer = 'CLINIBOT'
                         THEN v_score ELSE ai_score END
   WHERE id = p_lead_id;

  RETURN jsonb_build_object(
    'ok', true,
    'lead_id', p_lead_id,
    'offer', v_l.offer,
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

-- ---------------------------------------------------------------------
-- The Clinibot claimers must never pick up a WEB lead. A WEB lead with a
-- website is QUALIFIED and has a website, which is exactly what workflow 30
-- looks for — so the offer goes into the predicate, inside the claim
-- (see "Claim, then filter" in CLAUDE.md).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.claim_leads_for_research(
  p_limit  int,
  p_worker text,
  p_stale_lock_minutes int DEFAULT 15
) RETURNS SETOF acq.leads LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  UPDATE acq.leads l
     SET locked_by = p_worker, locked_at = now()
   WHERE l.id IN (
     SELECT c.id FROM acq.leads c
      WHERE c.status = 'QUALIFIED'
        AND c.offer = 'CLINIBOT'
        AND NOT c.opt_out
        AND NOT c.do_not_contact
        AND c.website IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM acq.lead_research r
           WHERE r.lead_id = c.id AND r.is_current AND r.stale_after > now()
        )
        AND (c.locked_at IS NULL
             OR c.locked_at < now() - make_interval(mins => p_stale_lock_minutes))
      ORDER BY c.lead_score DESC, c.created_at
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
   )
  RETURNING l.*;
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.claim_leads_for_personalization(
  p_limit     int,
  p_worker    text,
  p_min_score int DEFAULT 0,
  p_stale_lock_minutes int DEFAULT 15
) RETURNS SETOF acq.leads LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  UPDATE acq.leads l
     SET locked_by = p_worker, locked_at = now()
   WHERE l.id IN (
     SELECT c.id FROM acq.leads c
      WHERE c.status = 'QUALIFIED'
        AND c.offer = 'CLINIBOT'
        AND NOT c.opt_out
        AND NOT c.do_not_contact
        AND c.public_email IS NOT NULL
        AND c.lead_score >= p_min_score
        AND EXISTS (
          SELECT 1 FROM acq.lead_research r
           WHERE r.lead_id = c.id AND r.is_current
        )
        AND NOT acq.is_suppressed(c.public_email::text, c.domain, NULL, c.id)
        AND NOT EXISTS (
          SELECT 1 FROM acq.emails e WHERE e.lead_id = c.id AND e.step_no = 0
        )
        AND (c.locked_at IS NULL
             OR c.locked_at < now() - make_interval(mins => p_stale_lock_minutes))
      ORDER BY c.lead_score DESC, c.created_at
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
   )
  RETURNING l.*;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Workflow 25: WEB leads whose website has not been audited yet
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.claim_leads_for_audit(
  p_limit  int,
  p_worker text,
  p_stale_lock_minutes int DEFAULT 15
) RETURNS SETOF acq.leads LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  UPDATE acq.leads l
     SET locked_by = p_worker, locked_at = now()
   WHERE l.id IN (
     SELECT c.id FROM acq.leads c
      WHERE c.status = 'QUALIFIED'
        AND c.offer = 'WEB'
        AND NOT c.opt_out
        AND NOT c.do_not_contact
        AND acq.has_real_website(c.website)
        AND NOT EXISTS (
          SELECT 1 FROM acq.website_audits a
           WHERE a.lead_id = c.id AND a.is_current AND a.stale_after > now()
        )
        AND (c.locked_at IS NULL
             OR c.locked_at < now() - make_interval(mins => p_stale_lock_minutes))
      ORDER BY c.lead_score DESC, c.created_at
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
   )
  RETURNING l.*;
END;
$fn$;

-- Records one audit and decides, in the same transaction, whether the site is
-- weak enough to pitch. An address found on the site is stored with the page
-- it was read from, exactly as workflow 30 does — never without it.
CREATE OR REPLACE FUNCTION acq.record_website_audit(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_lead  uuid := nullif(p->>'lead_id', '')::uuid;
  v_score jsonb;
  v_move  jsonb;
  v_email text := acq.normalize_email(p->>'email');
  v_eurl  text := nullif(p->>'email_url', '');
BEGIN
  IF v_lead IS NULL OR NOT EXISTS (SELECT 1 FROM acq.leads WHERE id = v_lead) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'lead_not_found');
  END IF;

  UPDATE acq.website_audits SET is_current = false WHERE lead_id = v_lead AND is_current;

  INSERT INTO acq.website_audits (
    lead_id, url, final_url, robots_allowed, reachable, status_code, https,
    has_viewport, title, page_bytes, elapsed_ms, copyright_year, has_tel_link,
    has_whatsapp_link, has_form, generator, parked, issues, raw)
  VALUES (
    v_lead, p->>'url', p->>'final_url',
    (p->>'robots_allowed')::boolean, (p->>'reachable')::boolean,
    nullif(p->>'status_code','')::int, (p->>'https')::boolean,
    (p->>'has_viewport')::boolean, left(p->>'title', 300),
    nullif(p->>'page_bytes','')::int, nullif(p->>'elapsed_ms','')::int,
    nullif(p->>'copyright_year','')::int, (p->>'has_tel_link')::boolean,
    (p->>'has_whatsapp_link')::boolean, (p->>'has_form')::boolean,
    left(p->>'generator', 120), (p->>'parked')::boolean,
    coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(p->'issues','[]'::jsonb))), '{}'),
    coalesce(p->'raw', '{}'::jsonb));

  IF v_email IS NOT NULL AND v_eurl IS NOT NULL THEN
    UPDATE acq.leads
       SET public_email = v_email::citext,
           email_source = 'CLINIC_WEBSITE',
           email_evidence_url = v_eurl
     WHERE id = v_lead AND public_email IS NULL;
  END IF;

  v_score := acq.compute_score(v_lead, 'BLENDED');

  IF (v_score->>'qualifies')::boolean THEN
    -- Stays QUALIFIED; the current audit is what makes it pitchable now.
    PERFORM acq.release_lead(v_lead);
    v_move := jsonb_build_object('ok', true, 'noop', true, 'to', 'QUALIFIED');
  ELSE
    v_move := acq.transition_lead(v_lead, 'REJECTED',
                format('website_good_enough:%s', v_score->>'score'), 'SYSTEM', p->>'execution_id');
  END IF;

  RETURN jsonb_build_object('ok', true, 'lead_id', v_lead,
                            'score', v_score->'score', 'qualifies', v_score->'qualifies',
                            'issues', coalesce(p->'issues','[]'::jsonb), 'move', v_move);
END;
$fn$;

-- ---------------------------------------------------------------------
-- Workflow 45: WEB leads ready for a drafted WhatsApp / phone pitch
--
-- The daily cap is enforced here, not in n8n. An advisory lock serialises
-- concurrent claims, and the count includes leads claimed but not yet
-- drafted, so two overlapping runs cannot both see room for the last slots.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.claim_leads_for_web_pitch(
  p_limit  int,
  p_worker text,
  p_stale_lock_minutes int DEFAULT 15
) RETURNS SETOF acq.leads LANGUAGE plpgsql AS $fn$
DECLARE
  v_cap     int;
  v_used    int;
  v_allowed int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('acq.claim_leads_for_web_pitch'));

  SELECT (value #>> '{}')::int INTO v_cap FROM acq.settings WHERE key = 'web.max_drafts_per_day';
  v_cap := coalesce(v_cap, 20);

  SELECT
    (SELECT count(*) FROM acq.manual_outreach
      WHERE step_no = 0 AND created_at >= date_trunc('day', now()))
  + (SELECT count(*) FROM acq.leads
      WHERE locked_by LIKE 'wf45:%'
        AND locked_at > now() - make_interval(mins => p_stale_lock_minutes))
  INTO v_used;

  v_allowed := least(p_limit, v_cap - v_used);
  IF v_allowed <= 0 THEN RETURN; END IF;

  RETURN QUERY
  UPDATE acq.leads l
     SET locked_by = p_worker, locked_at = now()
   WHERE l.id IN (
     SELECT c.id FROM acq.leads c
      WHERE c.status = 'QUALIFIED'
        AND c.offer = 'WEB'
        AND NOT c.opt_out
        AND NOT c.do_not_contact
        AND (c.phone IS NOT NULL OR c.whatsapp IS NOT NULL)
        AND NOT acq.is_suppressed(NULL, NULL, c.phone, c.id)
        AND NOT acq.is_suppressed(NULL, NULL, c.whatsapp, c.id)
        -- no website at all, or a website already audited and still qualifying
        AND (NOT acq.has_real_website(c.website)
             OR EXISTS (SELECT 1 FROM acq.website_audits a
                         WHERE a.lead_id = c.id AND a.is_current))
        AND NOT EXISTS (
          SELECT 1 FROM acq.manual_outreach m WHERE m.lead_id = c.id AND m.step_no = 0
        )
        AND (c.locked_at IS NULL
             OR c.locked_at < now() - make_interval(mins => p_stale_lock_minutes))
      ORDER BY c.lead_score DESC, c.created_at
      LIMIT v_allowed
      FOR UPDATE SKIP LOCKED
   )
  RETURNING l.*;
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.render_web_template(p_template text, p_lead acq.leads)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_sender    text;
  v_portfolio text;
BEGIN
  SELECT value #>> '{}' INTO v_sender    FROM acq.settings WHERE key = 'company.sender_person';
  SELECT value #>> '{}' INTO v_portfolio FROM acq.settings WHERE key = 'web.portfolio_url';
  RETURN replace(replace(replace(replace(coalesce(p_template, ''),
    '{{name}}',        p_lead.clinic_name),
    '{{area_clause}}', CASE WHEN p_lead.area IS NOT NULL THEN ' in ' || p_lead.area ELSE '' END),
    '{{sender}}',      coalesce(nullif(v_sender, ''), 'a local web developer')),
    '{{portfolio_clause}}', CASE WHEN coalesce(btrim(v_portfolio), '') <> ''
                                 THEN ' You can see my work here: ' || v_portfolio ELSE '' END);
END;
$fn$;

-- Stores the drafted pitch and moves the lead to READY_FOR_REVIEW. A missing
-- or rejected AI draft falls back to the configured template, so a model
-- outage delays nothing: a person reads every message before it is sent.
CREATE OR REPLACE FUNCTION acq.record_web_pitch(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_lead    acq.leads%ROWTYPE;
  v_chan    jsonb;
  v_msg     text := nullif(btrim(coalesce(p->>'message', '')), '');
  v_source  text := 'AI';
  v_tpl     text;
  v_id      uuid;
  v_move    jsonb;
BEGIN
  SELECT * INTO v_lead FROM acq.leads WHERE id = nullif(p->>'lead_id','')::uuid;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'lead_not_found'); END IF;

  IF v_lead.opt_out OR v_lead.do_not_contact THEN
    PERFORM acq.release_lead(v_lead.id);
    RETURN jsonb_build_object('ok', false, 'error', 'lead_suppressed');
  END IF;

  v_chan := acq.manual_channel(v_lead);
  IF v_chan IS NULL THEN
    PERFORM acq.transition_lead(v_lead.id, 'REJECTED', 'web:no_phone_for_manual_outreach',
                                'SYSTEM', p->>'execution_id');
    RETURN jsonb_build_object('ok', false, 'error', 'no_manual_channel');
  END IF;

  IF v_msg IS NULL THEN
    SELECT value #>> '{}' INTO v_tpl FROM acq.settings WHERE key = 'web.fallback_template';
    v_msg := acq.render_web_template(v_tpl, v_lead);
    v_source := 'TEMPLATE';
  END IF;

  INSERT INTO acq.manual_outreach (
    lead_id, step_no, channel, to_value, message, status, personalization_reason,
    ai_confidence, model, prompt_version, draft_source, draft_notes)
  VALUES (
    v_lead.id, 0, v_chan->>'channel', v_chan->>'to_value', v_msg, 'READY',
    nullif(p->>'personalization_reason', ''),
    CASE WHEN v_source = 'AI' THEN nullif(p->>'confidence', '')::numeric END,
    CASE WHEN v_source = 'AI' THEN p->>'model' END,
    CASE WHEN v_source = 'AI' THEN p->>'prompt_version' END,
    v_source,
    nullif(p->>'notes', ''))
  ON CONFLICT (lead_id, step_no) DO NOTHING
  RETURNING id INTO v_id;

  v_move := acq.transition_lead(v_lead.id, 'READY_FOR_REVIEW',
              format('web_pitch_ready:%s', lower(v_source)), 'SYSTEM', p->>'execution_id');

  RETURN jsonb_build_object('ok', true, 'lead_id', v_lead.id, 'outreach_id', v_id,
                            'duplicate', v_id IS NULL, 'draft_source', v_source,
                            'channel', v_chan->>'channel', 'move', v_move);
END;
$fn$;

-- ---------------------------------------------------------------------
-- The three things a person does in the dashboard. SECURITY DEFINER with a
-- pinned search_path, like transition_lead() in migration 010: acq_dashboard
-- gets these narrow entry points and no write access to the tables.
-- ---------------------------------------------------------------------

-- "I sent it." Moves the lead to CONTACTED (or FOLLOW_UP_1) and schedules the
-- one follow-up. The person may have edited the text before sending; the
-- version actually sent is what gets stored.
CREATE OR REPLACE FUNCTION acq.mark_manual_sent(
  p_outreach_id uuid,
  p_final_message text,
  p_by text
) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
DECLARE
  v_m     acq.manual_outreach%ROWTYPE;
  v_lead  acq.leads%ROWTYPE;
  v_days  int;
  v_follow boolean;
  v_tpl   text;
BEGIN
  SELECT * INTO v_m FROM acq.manual_outreach WHERE id = p_outreach_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_m.status NOT IN ('READY','SCHEDULED') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_' || lower(v_m.status));
  END IF;

  SELECT * INTO v_lead FROM acq.leads WHERE id = v_m.lead_id FOR UPDATE;
  IF v_lead.opt_out OR v_lead.do_not_contact
     OR acq.is_suppressed(NULL, NULL, v_m.to_value, v_lead.id) THEN
    UPDATE acq.manual_outreach SET status = 'CANCELLED', closed_reason = 'suppressed'
     WHERE id = v_m.id;
    RETURN jsonb_build_object('ok', false, 'error', 'lead_suppressed');
  END IF;
  IF v_lead.replied_at IS NOT NULL AND v_m.step_no > 0 THEN
    UPDATE acq.manual_outreach SET status = 'CANCELLED', closed_reason = 'already_replied'
     WHERE id = v_m.id;
    RETURN jsonb_build_object('ok', false, 'error', 'lead_already_replied');
  END IF;

  UPDATE acq.manual_outreach
     SET status = 'SENT', sent_at = now(), sent_by = p_by,
         message = coalesce(nullif(btrim(coalesce(p_final_message, '')), ''), message)
   WHERE id = v_m.id;

  UPDATE acq.leads SET last_contacted_at = now(),
                       follow_up_count = greatest(follow_up_count, v_m.step_no)
   WHERE id = v_lead.id;

  IF v_m.step_no = 0 THEN
    PERFORM acq.transition_lead(v_lead.id, 'APPROVED',  'web_pitch_sent_by_hand', 'HUMAN');
    PERFORM acq.transition_lead(v_lead.id, 'CONTACTED', 'web_pitch_sent_by_hand', 'HUMAN');

    SELECT (value)::boolean       INTO v_follow FROM acq.settings WHERE key = 'web.followup_enabled';
    SELECT (value #>> '{}')::int  INTO v_days   FROM acq.settings WHERE key = 'web.followup_days';
    SELECT value #>> '{}'         INTO v_tpl    FROM acq.settings WHERE key = 'web.followup_template';
    IF coalesce(v_follow, false) AND coalesce(v_tpl, '') <> '' THEN
      INSERT INTO acq.manual_outreach (lead_id, step_no, channel, to_value, message,
                                       status, due_at, draft_source)
      VALUES (v_lead.id, 1, v_m.channel, v_m.to_value,
              acq.render_web_template(v_tpl, v_lead), 'SCHEDULED',
              now() + make_interval(days => coalesce(v_days, 3)), 'TEMPLATE')
      ON CONFLICT (lead_id, step_no) DO NOTHING;
    END IF;
  ELSE
    PERFORM acq.transition_lead(v_lead.id, 'FOLLOW_UP_1', 'web_followup_sent_by_hand', 'HUMAN');
  END IF;

  INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
  VALUES (v_lead.id, 'MANUAL_MESSAGE_SENT', 'HUMAN',
          format('%s step %s sent by %s', v_m.channel, v_m.step_no, coalesce(p_by, '?')),
          jsonb_build_object('outreach_id', v_m.id, 'channel', v_m.channel));

  RETURN jsonb_build_object('ok', true, 'lead_id', v_lead.id, 'step_no', v_m.step_no);
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.skip_manual(
  p_outreach_id uuid,
  p_reason text,
  p_by text
) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
DECLARE
  v_m acq.manual_outreach%ROWTYPE;
BEGIN
  UPDATE acq.manual_outreach
     SET status = 'SKIPPED', closed_reason = left(coalesce(p_reason, 'skipped'), 200),
         sent_by = p_by
   WHERE id = p_outreach_id AND status IN ('READY','SCHEDULED')
  RETURNING * INTO v_m;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_pending'); END IF;

  IF v_m.step_no = 0 THEN
    PERFORM acq.transition_lead(v_m.lead_id, 'REJECTED',
              format('web_pitch_skipped:%s', coalesce(p_reason, '')), 'HUMAN');
  END IF;
  RETURN jsonb_build_object('ok', true, 'lead_id', v_m.lead_id);
END;
$fn$;

-- What happened after a message went out. Any response at all cancels the
-- pending follow-up first — the manual-channel twin of acq.record_reply(),
-- so nobody who answered is nudged again.
CREATE OR REPLACE FUNCTION acq.record_manual_outcome(
  p_lead_id uuid,
  p_outcome text,
  p_by text,
  p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
DECLARE
  v_outcome text := upper(coalesce(p_outcome, ''));
  v_to      acq.lead_status;
  v_num     text;
  v_move    jsonb;
BEGIN
  IF v_outcome NOT IN ('REPLIED','INTERESTED','NOT_INTERESTED','OPT_OUT','CUSTOMER','WRONG_NUMBER') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_outcome', 'outcome', v_outcome);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM acq.manual_outreach WHERE lead_id = p_lead_id AND status = 'SENT') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'nothing_sent_yet');
  END IF;

  UPDATE acq.manual_outreach
     SET status = 'CANCELLED', closed_reason = 'outcome:' || lower(v_outcome)
   WHERE lead_id = p_lead_id AND status IN ('READY','SCHEDULED');

  IF v_outcome <> 'WRONG_NUMBER' THEN
    UPDATE acq.leads SET replied_at = coalesce(replied_at, now()) WHERE id = p_lead_id;
  END IF;

  IF v_outcome = 'OPT_OUT' THEN
    FOR v_num IN SELECT DISTINCT to_value FROM acq.manual_outreach WHERE lead_id = p_lead_id LOOP
      PERFORM acq.apply_opt_out('PHONE', v_num, 'OPT_OUT_REQUEST', 'MANUAL', p_lead_id,
                                jsonb_build_object('by', p_by, 'note', p_note));
    END LOOP;
    v_move := jsonb_build_object('ok', true, 'to', 'OPTED_OUT');
  ELSIF v_outcome = 'WRONG_NUMBER' THEN
    FOR v_num IN SELECT DISTINCT to_value FROM acq.manual_outreach WHERE lead_id = p_lead_id LOOP
      PERFORM acq.apply_opt_out('PHONE', v_num, 'MANUAL', 'MANUAL', p_lead_id,
                                jsonb_build_object('by', p_by, 'note', 'wrong number'));
    END LOOP;
    v_move := acq.transition_lead(p_lead_id, 'INVALID', 'web:wrong_number', 'HUMAN');
  ELSE
    v_to := CASE v_outcome
              WHEN 'REPLIED'        THEN 'REPLIED'
              WHEN 'INTERESTED'     THEN 'INTERESTED'
              WHEN 'NOT_INTERESTED' THEN 'NOT_INTERESTED'
              WHEN 'CUSTOMER'       THEN 'CUSTOMER'
            END::acq.lead_status;
    v_move := acq.transition_lead(p_lead_id, v_to, 'web_outcome:' || lower(v_outcome), 'HUMAN');
  END IF;

  INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
  VALUES (p_lead_id, 'MANUAL_OUTCOME', 'HUMAN',
          format('%s (recorded by %s)', v_outcome, coalesce(p_by, '?')),
          jsonb_build_object('outcome', v_outcome, 'note', p_note));

  RETURN jsonb_build_object('ok', coalesce((v_move->>'ok')::boolean, true),
                            'lead_id', p_lead_id, 'outcome', v_outcome, 'move', v_move);
END;
$fn$;

-- ---------------------------------------------------------------------
-- What the dashboard shows. One row per drafted, due or recently sent
-- message, with only the fields a person needs to send it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW acq.v_manual_outreach AS
SELECT
  m.id, m.lead_id, m.step_no, m.channel, m.to_value, m.message, m.status,
  m.due_at, m.sent_at, m.draft_source, m.personalization_reason,
  l.clinic_name AS business_name, l.category, l.area, l.city,
  l.lead_score, l.status AS lead_status, l.website, l.source_url AS listing_url,
  nullif(l.raw #>> '{GOOGLE_PLACES,rating}', '')::numeric           AS rating,
  nullif(l.raw #>> '{GOOGLE_PLACES,userRatingCount}', '')::int      AS review_count,
  a.issues AS website_issues,
  CASE
    WHEN m.status = 'READY' THEN 'TO_SEND'
    WHEN m.status = 'SCHEDULED' AND m.due_at <= now() THEN 'TO_SEND'
    WHEN m.status = 'SCHEDULED' THEN 'SCHEDULED'
    WHEN m.status = 'SENT' AND l.status IN ('CONTACTED','FOLLOW_UP_1') THEN 'AWAITING_REPLY'
    ELSE 'CLOSED'
  END AS queue
FROM acq.manual_outreach m
JOIN acq.leads l ON l.id = m.lead_id
LEFT JOIN acq.website_audits a ON a.lead_id = l.id AND a.is_current
WHERE NOT l.opt_out AND NOT l.do_not_contact;

CREATE OR REPLACE VIEW acq.v_web_overview AS
SELECT
  (SELECT count(*) FROM acq.leads WHERE offer = 'WEB')                                    AS web_leads,
  (SELECT count(*) FROM acq.leads WHERE offer = 'WEB' AND status = 'QUALIFIED')           AS web_qualified,
  (SELECT count(*) FROM acq.manual_outreach WHERE status = 'READY')
  + (SELECT count(*) FROM acq.manual_outreach WHERE status = 'SCHEDULED' AND due_at <= now())
                                                                                          AS to_send,
  (SELECT count(*) FROM acq.manual_outreach
     WHERE status = 'SENT' AND sent_at >= date_trunc('day', now()))                       AS sent_today,
  (SELECT count(*) FROM acq.manual_outreach WHERE status = 'SENT' AND step_no = 0)        AS pitched_total,
  (SELECT count(*) FROM acq.leads WHERE offer = 'WEB' AND replied_at IS NOT NULL)         AS replied,
  (SELECT count(*) FROM acq.leads WHERE offer = 'WEB'
     AND status IN ('INTERESTED','DEMO_REQUESTED','DEMO_BOOKED'))                         AS interested,
  (SELECT count(*) FROM acq.leads WHERE offer = 'WEB' AND status = 'CUSTOMER')            AS customers;

-- ---------------------------------------------------------------------
-- Readiness, now aware of two scoring configs and the WEB offer.
-- Same checks as migration 009 otherwise.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.readiness()
RETURNS TABLE (severity text, check_name text, detail text)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v text;
  n int;
BEGIN
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
  IF n < 9 THEN
    RETURN QUERY SELECT 'BLOCKER', 'prompts',
      format('%s of 9 active. Run: python3 scripts/load_prompts.py | psql', n);
  ELSE
    RETURN QUERY SELECT 'OK', 'prompts', format('%s active', n);
  END IF;

  FOR v IN SELECT unnest(ARRAY['CLINIBOT','WEB']) LOOP
    IF NOT EXISTS (SELECT 1 FROM acq.scoring_configs WHERE active AND offer = v) THEN
      RETURN QUERY SELECT 'BLOCKER', 'scoring_config:' || v,
        format('No active %s scoring config; compute_score() fails for %s leads.', v, v);
    ELSE
      RETURN QUERY SELECT 'OK', 'scoring_config:' || v,
        (SELECT version FROM acq.scoring_configs WHERE active AND offer = v);
    END IF;
  END LOOP;

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

  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'web.portfolio_url';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'WARN', 'web.portfolio_url',
      'Empty. Website pitches will go out with no link to your work.';
  ELSE
    RETURN QUERY SELECT 'OK', 'web.portfolio_url', v;
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

  IF NOT EXISTS (SELECT 1 FROM acq.discovery_tasks WHERE enabled AND offer = 'WEB') THEN
    RETURN QUERY SELECT 'INFO', 'discovery_tasks:WEB',
      'No WEB discovery task enabled. Only clinics without a website will reach the website pipeline. See docs/13-website-prospects.md.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.campaigns WHERE status = 'ACTIVE') THEN
    RETURN QUERY SELECT 'WARN', 'campaigns', 'No active campaign; nothing will be sent.';
  END IF;

  SELECT count(*) INTO n FROM acq.dead_letters WHERE resolved_at IS NULL;
  IF n > 0 THEN
    RETURN QUERY SELECT 'WARN', 'dead_letters', format('%s unresolved.', n);
  END IF;

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
    format('%s total, %s qualified, %s contacted · WEB: %s total, %s messages waiting to be sent',
      (SELECT count(*) FROM acq.leads),
      (SELECT count(*) FROM acq.leads WHERE status = 'QUALIFIED'),
      (SELECT count(*) FROM acq.leads WHERE last_contacted_at IS NOT NULL),
      (SELECT count(*) FROM acq.leads WHERE offer = 'WEB'),
      (SELECT to_send FROM acq.v_web_overview));
END;
$fn$;

COMMENT ON FUNCTION acq.readiness() IS
  'Pre-flight checklist as a query. BLOCKER rows are conditions the workflows refuse to run past. 011 made it offer-aware.';

-- ---------------------------------------------------------------------
-- Discovery tasks for the WEB offer. Seeded DISABLED, like the Places
-- clinic tasks: enabling one is a deliberate act.
--
--   UPDATE acq.discovery_tasks SET enabled = true
--    WHERE offer = 'WEB' AND provider = 'OSM';            -- free
--   UPDATE acq.discovery_tasks SET enabled = true
--    WHERE offer = 'WEB' AND provider = 'GOOGLE_PLACES';  -- needs a Places key
--
-- OSM coverage of small Karachi businesses is thin; Places finds far more,
-- and its listings carry the review counts the score uses.
-- ---------------------------------------------------------------------
INSERT INTO acq.discovery_tasks
  (market_id, city, area, query_term, category, provider, priority_tier, bbox,
   cadence_days, enabled, offer, osm_selectors)
SELECT
  m.id, a.city, a.area, q.query_term, q.category, p.provider, q.tier,
  jsonb_build_object('type','around','lat',a.lat,'lng',a.lng,'radius_m',a.radius),
  45, false, 'WEB',
  CASE WHEN p.provider = 'OSM' THEN q.osm ELSE NULL END
FROM acq.markets m
CROSS JOIN (VALUES
    ('Karachi','Saddar',            24.8560, 67.0300, 2500),
    ('Karachi','Gulshan-e-Iqbal',   24.9200, 67.0900, 4000),
    ('Karachi','North Nazimabad',   24.9400, 67.0400, 3500),
    ('Karachi','PECHS',             24.8700, 67.0600, 2500),
    ('Karachi','Clifton',           24.8138, 67.0300, 3000),
    ('Karachi','DHA',               24.8000, 67.0500, 5000),
    ('Karachi','Bahadurabad',       24.8800, 67.0650, 2500),
    ('Karachi','Federal B Area',    24.9300, 67.0700, 3500)
  ) AS a(city, area, lat, lng, radius)
CROSS JOIN (VALUES
    ('printing press',      'PRINTING',    1, ARRAY['["shop"~"^(copyshop|printing|printer)$"]', '["craft"="printer"]']),
    ('beauty salon',        'SALON',       1, ARRAY['["shop"~"^(hairdresser|beauty|cosmetics)$"]']),
    ('real estate agency',  'REAL_ESTATE', 1, ARRAY['["office"="estate_agent"]']),
    ('tuition academy',     'EDUCATION',   1, ARRAY['["amenity"~"^(language_school|music_school|driving_school|training)$"]', '["office"="educational_institution"]']),
    ('restaurant',          'RESTAURANT',  2, ARRAY['["amenity"~"^(restaurant|cafe|fast_food)$"]']),
    ('boutique',            'RETAIL',      2, ARRAY['["shop"~"^(clothes|boutique|tailor|fabric|shoes|jewelry)$"]']),
    ('gym',                 'FITNESS',     2, ARRAY['["leisure"="fitness_centre"]']),
    ('car workshop',        'AUTOMOTIVE',  2, ARRAY['["shop"~"^(car_repair|car|tyres)$"]']),
    ('furniture shop',      'RETAIL',      2, ARRAY['["shop"="furniture"]']),
    ('travel agency',       'TRAVEL',      2, ARRAY['["shop"="travel_agency"]', '["office"="travel_agent"]'])
  ) AS q(query_term, category, tier, osm)
CROSS JOIN (VALUES ('OSM'), ('GOOGLE_PLACES')) AS p(provider)
WHERE m.code = 'PK'
  AND NOT EXISTS (
    SELECT 1 FROM acq.discovery_tasks d
     WHERE d.offer = 'WEB' AND d.city = a.city AND d.area = a.area
       AND d.query_term = q.query_term AND d.provider = p.provider
  );

-- ---------------------------------------------------------------------
-- Grants. acq_n8n picks up the new tables through migration 010's default
-- privileges, but functions created after 010 need an explicit EXECUTE —
-- default privileges cover functions too, so this is belt and braces. The
-- dashboard gets two views and three narrow functions; nothing else.
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON acq.website_audits, acq.manual_outreach TO acq_n8n;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA acq TO acq_n8n;

GRANT SELECT ON acq.v_manual_outreach, acq.v_web_overview TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.mark_manual_sent(uuid, text, text)          TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.skip_manual(uuid, text, text)               TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.record_manual_outcome(uuid, text, text, text) TO acq_dashboard;

DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA acq FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA acq FROM %I', r);
    END IF;
  END LOOP;
END $$;
