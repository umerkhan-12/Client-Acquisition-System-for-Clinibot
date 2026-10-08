-- =====================================================================
-- Migration 012: Treg as a discovery source, and listing stats that score
--
-- 1. TREG_MAPS discovery. Google Maps results through treg.to's proxy
--    (endpoint anyapi.google.serp.maps): name, phone, website, rating and
--    review count for any city in the world, about $0.00175 per search of up
--    to 20 places. Measured on the first live call: 20 of 20 Karachi
--    restaurants came with a phone number, where OpenStreetMap had one for
--    roughly one clinic in ten. The provider credential stays inside treg;
--    n8n holds only a capped treg agent token.
--
-- 2. Every paid tool call is recorded in acq.tool_calls with treg's own
--    reported cost, and workflow 10 refuses to start once the day's spend
--    reaches treg.daily_cost_cap_usd. Like the AI cap, the check runs at the
--    start of a run, so one run can overshoot by at most its own calls
--    (discovery.max_tasks_per_run searches, each capped per call by
--    treg.max_cost_per_call_usd through X-Treg-Route-Max-Cost).
--
-- 3. A bug fix found while adding the "popular venue" signal: upsert_lead
--    stores each source's raw payload under its source name, and the
--    normalizers already wrap theirs the same way, so a Places listing is
--    stored as raw.GOOGLE_PLACES.GOOGLE_PLACES.userRatingCount. compute_score
--    read raw.GOOGLE_PLACES.userRatingCount, which is always NULL for a
--    discovered lead: the active_listing and well_rated points never fired.
--    The smoke test missed it because it inserts raw in the flat shape.
--    acq.listing_stats() reads every shape that exists, so no stored row
--    needs rewriting.
-- =====================================================================

SET search_path = acq, public;

CREATE OR REPLACE FUNCTION acq.listing_stats(p_raw jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $fn$
  SELECT coalesce(
    p_raw #> '{TREG_MAPS,GOOGLE_PLACES}',
    p_raw #> '{GOOGLE_PLACES,GOOGLE_PLACES}',
    CASE WHEN jsonb_typeof(p_raw -> 'GOOGLE_PLACES') = 'object'
              AND (p_raw -> 'GOOGLE_PLACES') ? 'userRatingCount'
         THEN p_raw -> 'GOOGLE_PLACES' END,
    '{}'::jsonb);
$fn$;

INSERT INTO acq.settings (key, value, description) VALUES
('treg.daily_cost_cap_usd',   '0.25'::jsonb,
 'Workflow 10 will not start a run once today''s treg spend (acq.tool_calls) reaches this.'),
('treg.max_cost_per_call_usd', '0.01'::jsonb,
 'Sent as X-Treg-Route-Max-Cost: treg refuses, unbilled, any single call that would cost more.'),
('treg.maps_endpoint',        '"anyapi.google.serp.maps"'::jsonb,
 'Catalog id used for TREG_MAPS discovery. Chosen 2026-10-08: $0.00175/search, 100% of 116k calls succeeded.')
ON CONFLICT (key) DO NOTHING;

-- The popular-venue signal. Data, so it can be tuned without a migration.
UPDATE acq.scoring_configs
   SET weights    = weights    || '{"popular_venue": 15}'::jsonb,
       thresholds = thresholds || '{"popular_rating_min": 4.3, "popular_reviews_min": 300}'::jsonb
 WHERE version = 'web-v1' AND NOT weights ? 'popular_venue';

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
  -- Read through acq.listing_stats(): upsert_lead nests each source's raw
  -- payload under its source name, so the flat path this used to read was
  -- always NULL for discovered leads. See the header of migration 012.
  v_reviews  := coalesce((acq.listing_stats(v_l.raw)->>'userRatingCount')::int,
                         (v_l.raw #>> '{OSM,OSM,review_count}')::int,
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
    v_rating := nullif(acq.listing_stats(v_l.raw)->>'rating', '')::numeric;
    IF v_rating IS NOT NULL AND v_rating >= coalesce((th->>'well_rated_min')::numeric, 4.0) THEN
      v_score := v_score + coalesce((w->>'well_rated')::int, 0);
      v_break := v_break || jsonb_build_object('well_rated', (w->>'well_rated')::int);
    END IF;

    -- A busy, highly rated venue has the customers and the margin to pay for
    -- ordering, booking or loyalty software, whether or not it has a website.
    IF v_rating IS NOT NULL
       AND v_rating >= coalesce((th->>'popular_rating_min')::numeric, 4.3)
       AND v_reviews >= coalesce((th->>'popular_reviews_min')::int, 300) THEN
      v_score := v_score + coalesce((w->>'popular_venue')::int, 0);
      v_break := v_break || jsonb_build_object('popular_venue', (w->>'popular_venue')::int);
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
-- Paid tool calls. One row per call, keyed by treg's call id, so a retried
-- n8n node that records the same answer twice counts it once.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS acq.tool_calls (
  id            bigserial PRIMARY KEY,
  provider      text NOT NULL,             -- 'treg'
  endpoint      text NOT NULL,             -- catalog id
  call_id       text,
  cost_usd      numeric(12,6) NOT NULL DEFAULT 0,
  http_status   int,
  ok            boolean NOT NULL,
  items         int,
  workflow_key  text,
  execution_id  text,
  error         text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS tool_calls_call_id ON acq.tool_calls (provider, call_id)
  WHERE call_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS tool_calls_created_idx ON acq.tool_calls (created_at DESC);

CREATE OR REPLACE FUNCTION acq.record_tool_call(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO acq.tool_calls (provider, endpoint, call_id, cost_usd, http_status, ok,
                              items, workflow_key, execution_id, error)
  VALUES (coalesce(p->>'provider', 'treg'), coalesce(p->>'endpoint', '?'),
          nullif(p->>'call_id', ''),
          coalesce(nullif(p->>'cost_micro', '')::numeric / 1000000, 0),
          nullif(p->>'http_status', '')::int,
          coalesce((p->>'ok')::boolean, false),
          nullif(p->>'items', '')::int,
          p->>'workflow_key', p->>'execution_id', left(p->>'error', 500))
  ON CONFLICT (provider, call_id) WHERE call_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'duplicate', v_id IS NULL);
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.tool_spend_today(p_provider text DEFAULT 'treg')
RETURNS numeric LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(sum(cost_usd), 0) FROM acq.tool_calls
   WHERE provider = p_provider AND created_at >= date_trunc('day', now());
$fn$;

-- The dashboard view, now reading rating and reviews through listing_stats.
CREATE OR REPLACE VIEW acq.v_manual_outreach AS
SELECT
  m.id, m.lead_id, m.step_no, m.channel, m.to_value, m.message, m.status,
  m.due_at, m.sent_at, m.draft_source, m.personalization_reason,
  l.clinic_name AS business_name, l.category, l.area, l.city,
  l.lead_score, l.status AS lead_status, l.website, l.source_url AS listing_url,
  nullif(acq.listing_stats(l.raw) ->> 'rating', '')::numeric          AS rating,
  nullif(acq.listing_stats(l.raw) ->> 'userRatingCount', '')::int     AS review_count,
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

-- ---------------------------------------------------------------------
-- Premium, busy cafes and restaurants in Karachi: the venues with the
-- customers and margins to pay for websites, ordering and booking systems.
-- ENABLED: each search costs about $0.00175 and the daily cap bounds it.
-- 7 searches x 7 areas = 49 tasks, about $0.09 for one full sweep, revisited
-- every 30 days. Add any city in the world as more rows; the location text
-- is passed to Google Maps as written.
-- ---------------------------------------------------------------------
INSERT INTO acq.discovery_tasks
  (market_id, city, area, query_term, category, provider, priority_tier,
   cadence_days, enabled, offer)
SELECT m.id, 'Karachi', a.area, q.query_term, q.category, 'TREG_MAPS', 1, 30, true, 'WEB'
FROM acq.markets m
CROSS JOIN (VALUES ('DHA'), ('Clifton'), ('Gulshan-e-Iqbal'), ('PECHS'),
                   ('Bahadurabad'), ('Saddar'), ('North Nazimabad')) AS a(area)
CROSS JOIN (VALUES ('specialty coffee cafe', 'CAFE'),
                   ('aesthetic cafe',        'CAFE'),
                   ('dessert cafe',          'CAFE'),
                   ('fine dining restaurant','RESTAURANT'),
                   ('rooftop restaurant',    'RESTAURANT'),
                   ('steakhouse',            'RESTAURANT'),
                   ('brunch restaurant',     'RESTAURANT')) AS q(query_term, category)
WHERE m.code = 'PK'
  AND NOT EXISTS (
    SELECT 1 FROM acq.discovery_tasks d
     WHERE d.provider = 'TREG_MAPS' AND d.city = 'Karachi' AND d.area = a.area
       AND d.query_term = q.query_term);

GRANT SELECT, INSERT, UPDATE, DELETE ON acq.tool_calls TO acq_n8n;
GRANT USAGE, SELECT ON SEQUENCE acq.tool_calls_id_seq TO acq_n8n;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA acq TO acq_n8n;
GRANT SELECT ON acq.v_manual_outreach TO acq_dashboard;
