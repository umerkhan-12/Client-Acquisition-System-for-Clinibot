-- =====================================================================
-- Migration 003: deduplication, scoring, and the send choke point
-- =====================================================================

SET search_path = acq, public;

-- ---------------------------------------------------------------------
-- acq.upsert_lead — the single entry point for every discovery source
--
-- Guarantees:
--   * one business = one lead, regardless of how many sources found it
--   * an email address is only ever stored with citable provenance
--   * merging never overwrites data a human or a better source already set
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION acq.upsert_lead(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_market      uuid;
  v_cc          text;
  v_name        text := btrim(coalesce(p->>'clinic_name', ''));
  v_norm_name   text;
  v_domain      text;
  v_phone       text;
  v_whatsapp    text;
  v_email       text;
  v_email_src   text;
  v_email_url   text;
  v_city        text := btrim(coalesce(p->>'city', ''));
  v_name_city   text;
  v_lead        uuid;
  v_matched_by  text;
  v_existing    acq.leads%ROWTYPE;
  v_key         jsonb;
  v_keys        jsonb := '[]'::jsonb;
  v_contact     jsonb;
  v_dropped     text[] := '{}';
  v_is_new      boolean := false;
BEGIN
  IF v_name = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'clinic_name_required');
  END IF;

  SELECT id, phone_cc INTO v_market, v_cc
    FROM acq.markets WHERE code = upper(coalesce(p->>'market_code', 'PK'));
  IF v_market IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_market',
                              'market_code', p->>'market_code');
  END IF;

  v_norm_name := coalesce(acq.normalize_name(v_name), lower(v_name));
  v_domain    := acq.normalize_domain(p->>'website');
  v_phone     := acq.normalize_phone(p->>'phone', v_cc);
  v_whatsapp  := acq.normalize_phone(p->>'whatsapp', v_cc);
  v_email     := acq.normalize_email(p->>'public_email');
  v_email_src := p->>'email_source';
  v_email_url := p->>'email_evidence_url';

  -- PROVENANCE GATE. An address without a citable public source is discarded
  -- outright rather than stored — this is what makes "never guess an email"
  -- an enforced property instead of a prompt instruction.
  IF v_email IS NOT NULL THEN
    IF v_email_src IS NULL OR v_email_url IS NULL
       OR v_email_src NOT IN ('CLINIC_WEBSITE','GOOGLE_BUSINESS','OSM',
                              'PUBLIC_DIRECTORY','MANUAL','INBOUND_REPLY') THEN
      v_dropped := v_dropped || 'public_email:no_provenance'::text;
      v_email := NULL; v_email_src := NULL; v_email_url := NULL;
    END IF;
  END IF;

  -- ---- candidate identity keys, strongest first -----------------------
  IF (p->>'source_ref') IS NOT NULL AND (p->>'source_ref_type') IS NOT NULL THEN
    v_keys := v_keys || jsonb_build_array(
      jsonb_build_object('t', p->>'source_ref_type', 'v', p->>'source_ref'));
  END IF;
  IF v_domain   IS NOT NULL THEN v_keys := v_keys || jsonb_build_array(jsonb_build_object('t','DOMAIN','v',v_domain));   END IF;
  IF v_email    IS NOT NULL THEN v_keys := v_keys || jsonb_build_array(jsonb_build_object('t','EMAIL','v',v_email));      END IF;
  IF v_phone    IS NOT NULL THEN v_keys := v_keys || jsonb_build_array(jsonb_build_object('t','PHONE','v',v_phone));      END IF;
  IF v_whatsapp IS NOT NULL THEN v_keys := v_keys || jsonb_build_array(jsonb_build_object('t','WHATSAPP','v',v_whatsapp));END IF;

  FOR v_key IN SELECT * FROM jsonb_array_elements(v_keys) LOOP
    SELECT k.lead_id INTO v_lead
      FROM acq.lead_identity_keys k
     WHERE k.key_type = (v_key->>'t')::acq.identity_key_type
       AND k.key_value = (v_key->>'v');
    IF v_lead IS NOT NULL THEN
      v_matched_by := v_key->>'t';
      EXIT;
    END IF;
  END LOOP;

  -- ---- weak key: normalized name + city -------------------------------
  -- Only trusted when the name still carries at least two meaningful tokens
  -- after stripping generic words, and only when the domains do not conflict.
  IF v_norm_name IS NOT NULL AND v_city <> ''
     AND array_length(string_to_array(v_norm_name, ' '), 1) >= 2 THEN
    v_name_city := v_norm_name || '|' || lower(v_city);

    IF v_lead IS NULL THEN
      SELECT k.lead_id INTO v_lead
        FROM acq.lead_identity_keys k
        JOIN acq.leads l ON l.id = k.lead_id
       WHERE k.key_type = 'NAME_CITY'
         AND k.key_value = v_name_city
         -- two different clinics can share a generic name; a conflicting
         -- domain proves they are not the same business.
         AND (v_domain IS NULL OR l.domain IS NULL OR l.domain = v_domain);
      IF v_lead IS NOT NULL THEN v_matched_by := 'NAME_CITY'; END IF;
    END IF;

    v_keys := v_keys || jsonb_build_array(
      jsonb_build_object('t','NAME_CITY','v', v_name_city));
  END IF;

  -- ---- merge or insert -------------------------------------------------
  IF v_lead IS NOT NULL THEN
    SELECT * INTO v_existing FROM acq.leads WHERE id = v_lead FOR UPDATE;

    UPDATE acq.leads l SET
      website        = coalesce(l.website, p->>'website'),
      city           = coalesce(nullif(l.city, ''), nullif(v_city, '')),
      area           = coalesce(nullif(l.area, ''), nullif(btrim(coalesce(p->>'area','')), '')),
      address        = coalesce(nullif(l.address, ''), nullif(btrim(coalesce(p->>'address','')), '')),
      lat            = coalesce(l.lat, nullif(p->>'lat','')::numeric),
      lng            = coalesce(l.lng, nullif(p->>'lng','')::numeric),
      phone          = coalesce(l.phone, v_phone),
      whatsapp       = coalesce(l.whatsapp, v_whatsapp),
      -- all three email columns move together or not at all (CHECK constraint)
      public_email       = CASE WHEN l.public_email IS NULL AND v_email IS NOT NULL
                                THEN v_email::citext ELSE l.public_email END,
      email_source       = CASE WHEN l.public_email IS NULL AND v_email IS NOT NULL
                                THEN v_email_src::acq.contact_source ELSE l.email_source END,
      email_evidence_url = CASE WHEN l.public_email IS NULL AND v_email IS NOT NULL
                                THEN v_email_url ELSE l.email_evidence_url END,
      doctor_count   = coalesce(l.doctor_count, nullif(p->>'doctor_count','')::int),
      booking_method = coalesce(l.booking_method, p->>'booking_method'),
      category       = coalesce(l.category, p->>'category'),
      specialties    = ARRAY(SELECT DISTINCT unnest(
                         l.specialties || coalesce(
                           ARRAY(SELECT jsonb_array_elements_text(coalesce(p->'specialties','[]'::jsonb))), '{}'))),
      services       = ARRAY(SELECT DISTINCT unnest(
                         l.services || coalesce(
                           ARRAY(SELECT jsonb_array_elements_text(coalesce(p->'services','[]'::jsonb))), '{}'))),
      raw            = l.raw || jsonb_build_object(
                         coalesce(p->>'source','unknown'), coalesce(p->'raw','{}'::jsonb))
    WHERE l.id = v_lead;

    INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
    VALUES (v_lead, 'DUPLICATE_MERGED', 'SYSTEM',
            format('duplicate from %s matched on %s', coalesce(p->>'source','?'), v_matched_by),
            jsonb_build_object('matched_by', v_matched_by, 'source', p->>'source',
                               'source_url', p->>'source_url'));
  ELSE
    v_is_new := true;
    INSERT INTO acq.leads (
      market_id, clinic_name, website, city, area, address, lat, lng,
      phone, whatsapp, public_email, email_source, email_evidence_url,
      specialties, services, doctor_count, booking_method, category, priority_tier,
      source, source_url, source_ref, raw, status
    ) VALUES (
      v_market, v_name, p->>'website', nullif(v_city,''),
      nullif(btrim(coalesce(p->>'area','')),''), nullif(btrim(coalesce(p->>'address','')),''),
      nullif(p->>'lat','')::numeric, nullif(p->>'lng','')::numeric,
      v_phone, v_whatsapp, v_email::citext,
      v_email_src::acq.contact_source, v_email_url,
      coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(p->'specialties','[]'::jsonb))), '{}'),
      coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(p->'services','[]'::jsonb))), '{}'),
      nullif(p->>'doctor_count','')::int, p->>'booking_method', p->>'category',
      coalesce(nullif(p->>'priority_tier','')::smallint, 2),
      coalesce(p->>'source','unknown'), p->>'source_url', p->>'source_ref',
      jsonb_build_object(coalesce(p->>'source','unknown'), coalesce(p->'raw','{}'::jsonb)),
      'NEW'
    ) RETURNING id INTO v_lead;

    INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
    VALUES (v_lead, 'LEAD_DISCOVERED', 'SYSTEM',
            format('discovered via %s', coalesce(p->>'source','?')),
            jsonb_build_object('source', p->>'source', 'source_url', p->>'source_url'));
  END IF;

  -- ---- register identity keys (idempotent) ----------------------------
  FOR v_key IN SELECT * FROM jsonb_array_elements(v_keys) LOOP
    INSERT INTO acq.lead_identity_keys (lead_id, key_type, key_value)
    VALUES (v_lead, (v_key->>'t')::acq.identity_key_type, v_key->>'v')
    ON CONFLICT (key_type, key_value) DO NOTHING;
  END LOOP;

  -- ---- contacts (every one carries a citable source_url) --------------
  FOR v_contact IN SELECT * FROM jsonb_array_elements(coalesce(p->'contacts','[]'::jsonb)) LOOP
    CONTINUE WHEN (v_contact->>'value') IS NULL OR (v_contact->>'source_url') IS NULL;
    INSERT INTO acq.lead_contacts (
      lead_id, contact_type, value, normalized_value, label, is_primary,
      verification_status, source, source_url
    ) VALUES (
      v_lead,
      (v_contact->>'contact_type')::acq.contact_type,
      v_contact->>'value',
      CASE (v_contact->>'contact_type')
        WHEN 'EMAIL' THEN acq.normalize_email(v_contact->>'value')
        WHEN 'PHONE' THEN coalesce(acq.normalize_phone(v_contact->>'value', v_cc), v_contact->>'value')
        WHEN 'WHATSAPP' THEN coalesce(acq.normalize_phone(v_contact->>'value', v_cc), v_contact->>'value')
        ELSE lower(btrim(v_contact->>'value'))
      END,
      v_contact->>'label',
      coalesce((v_contact->>'is_primary')::boolean, false),
      coalesce((v_contact->>'verification_status')::acq.verification_status, 'PUBLICLY_LISTED'),
      (v_contact->>'source')::acq.contact_source,
      v_contact->>'source_url'
    )
    ON CONFLICT (lead_id, contact_type, normalized_value) DO NOTHING;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'lead_id', v_lead,
    'is_new', v_is_new,
    'duplicate', NOT v_is_new,
    'matched_by', v_matched_by,
    'dropped_fields', to_jsonb(v_dropped)
  );
END;
$fn$;

-- ---------------------------------------------------------------------
-- Scoring
--
-- Two phases. DETERMINISTIC runs on every lead using only facts that came
-- free from the discovery source — it costs nothing and rejects most leads
-- before any token is spent. BLENDED runs only for leads that survived, and
-- folds in signals the AI researcher confirmed.
-- ---------------------------------------------------------------------

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

  -- category priority tier, from config so it stays tunable per market
  v_score := v_score + coalesce((w->'category_tier'->>(v_l.priority_tier::text))::int, 0);
  v_break := v_break || jsonb_build_object(
    'category_tier_' || v_l.priority_tier,
    coalesce((w->'category_tier'->>(v_l.priority_tier::text))::int, 0));

  -- public activity proxy: review volume on the source listing
  IF coalesce((v_l.raw #>> '{GOOGLE_PLACES,userRatingCount}')::int,
              (v_l.raw #>> '{OSM,review_count}')::int, 0)
     >= coalesce((th->>'active_listing_reviews')::int, 20) THEN
    v_score := v_score + coalesce((w->>'active_listing')::int, 0);
    v_break := v_break || jsonb_build_object('active_listing', (w->>'active_listing')::int);
  END IF;

  -- penalties
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
        -- no online booking is an OPPORTUNITY for Clinibot, not a demerit
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
    'qualifies', v_score >= coalesce((th->>'qualify')::int, 45),
    'auto_send_eligible', v_score >= coalesce((th->>'auto_send')::int, 70),
    'hot', v_score >= coalesce((th->>'hot')::int, 80),
    'thresholds', th
  );
END;
$fn$;

-- ---------------------------------------------------------------------
-- Sending: warm-up ramp and the atomic slot claim
-- ---------------------------------------------------------------------

-- A brand-new domain that sends 40 emails on day one gets filtered. The ramp
-- is enforced here so no workflow edit can accidentally bypass it.
CREATE OR REPLACE FUNCTION acq.warmup_daily_cap(p_mailbox uuid)
RETURNS int LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_m    acq.mailboxes%ROWTYPE;
  v_week int;
BEGIN
  SELECT * INTO v_m FROM acq.mailboxes WHERE id = p_mailbox;
  IF NOT FOUND THEN RETURN 0; END IF;
  IF v_m.warmup_started_on IS NULL THEN RETURN least(v_m.daily_cap, 5); END IF;

  v_week := floor((CURRENT_DATE - v_m.warmup_started_on) / 7.0)::int + 1;

  RETURN least(
    v_m.daily_cap,
    CASE v_week
      WHEN 1 THEN 5
      WHEN 2 THEN 10
      WHEN 3 THEN 15
      WHEN 4 THEN 25
      ELSE v_m.daily_cap
    END
  );
END;
$fn$;

-- THE single choke point. Every outbound email — initial or follow-up — must
-- pass through this function. Limits, sending windows, suppression and the
-- warm-up ramp are all enforced in one transaction, so two overlapping n8n
-- executions cannot both believe they have budget.
CREATE OR REPLACE FUNCTION acq.claim_send_slots(
  p_campaign_id uuid,
  p_limit       int DEFAULT 5
) RETURNS SETOF acq.emails LANGUAGE plpgsql AS $fn$
DECLARE
  v_camp    acq.campaigns%ROWTYPE;
  v_local   timestamp;
  v_date    date;
  v_hour    smallint;
  v_day_cnt int;
  v_hr_cnt  int;
  v_allowed int;
  v_ids     uuid[];
BEGIN
  SELECT * INTO v_camp FROM acq.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND OR v_camp.status <> 'ACTIVE' THEN RETURN; END IF;

  v_local := now() AT TIME ZONE v_camp.timezone;
  v_date  := v_local::date;
  v_hour  := extract(hour FROM v_local)::smallint;

  -- outside the sending window / on a non-sending day: claim nothing
  IF NOT (extract(isodow FROM v_local)::int = ANY (v_camp.sending_days)) THEN RETURN; END IF;
  IF v_local::time < v_camp.sending_window_start
     OR v_local::time > v_camp.sending_window_end THEN RETURN; END IF;

  SELECT coalesce(sent_count, 0) INTO v_day_cnt FROM acq.send_counters
   WHERE mailbox_id = v_camp.mailbox_id AND bucket_date = v_date AND bucket_hour = -1;
  v_day_cnt := coalesce(v_day_cnt, 0);

  SELECT coalesce(sent_count, 0) INTO v_hr_cnt FROM acq.send_counters
   WHERE mailbox_id = v_camp.mailbox_id AND bucket_date = v_date AND bucket_hour = v_hour;
  v_hr_cnt := coalesce(v_hr_cnt, 0);

  v_allowed := least(
    p_limit,
    acq.warmup_daily_cap(v_camp.mailbox_id) - v_day_cnt,
    v_camp.daily_send_limit  - v_day_cnt,
    (SELECT hourly_cap FROM acq.mailboxes WHERE id = v_camp.mailbox_id) - v_hr_cnt,
    v_camp.hourly_send_limit - v_hr_cnt
  );

  IF v_allowed <= 0 THEN RETURN; END IF;

  SELECT array_agg(id) INTO v_ids FROM (
    SELECT e.id
      FROM (
        SELECT e2.id,
               row_number() OVER (
                 PARTITION BY split_part(e2.to_email::text, '@', 2)
                 ORDER BY l2.lead_score DESC, e2.scheduled_for NULLS FIRST, e2.created_at
               ) AS dom_rank
          FROM acq.emails e2
          JOIN acq.leads  l2 ON l2.id = e2.lead_id
         WHERE e2.campaign_id = p_campaign_id
           AND e2.status = 'READY_TO_SEND'
           AND (e2.scheduled_for IS NULL OR e2.scheduled_for <= now())
           AND NOT l2.opt_out
           AND NOT l2.do_not_contact
           AND l2.replied_at IS NULL
           AND l2.lead_score >= v_camp.min_score_to_send
           AND NOT acq.is_suppressed(e2.to_email::text,
                                     split_part(e2.to_email::text, '@', 2),
                                     NULL, l2.id)
           -- never two emails to the same clinic inside 48h
           AND (l2.last_contacted_at IS NULL
                OR l2.last_contacted_at < now() - interval '2 days')
      ) e
     WHERE e.dom_rank <= v_camp.per_domain_limit
     ORDER BY e.dom_rank
     LIMIT v_allowed
  ) s;

  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN RETURN; END IF;

  RETURN QUERY
  WITH upd AS (
    UPDATE acq.emails e
       SET status = 'QUEUED', queued_at = now(), attempts = e.attempts + 1
     WHERE e.id = ANY (v_ids)
       AND e.status = 'READY_TO_SEND'      -- loses harmlessly to a concurrent claim
    RETURNING e.*
  ),
  bump_hour AS (
    INSERT INTO acq.send_counters (mailbox_id, bucket_date, bucket_hour, sent_count)
    SELECT v_camp.mailbox_id, v_date, v_hour, count(*) FROM upd
    HAVING count(*) > 0
    ON CONFLICT (mailbox_id, bucket_date, bucket_hour)
      DO UPDATE SET sent_count = acq.send_counters.sent_count + EXCLUDED.sent_count
    RETURNING 1
  ),
  bump_day AS (
    INSERT INTO acq.send_counters (mailbox_id, bucket_date, bucket_hour, sent_count)
    SELECT v_camp.mailbox_id, v_date, -1, count(*) FROM upd
    HAVING count(*) > 0
    ON CONFLICT (mailbox_id, bucket_date, bucket_hour)
      DO UPDATE SET sent_count = acq.send_counters.sent_count + EXCLUDED.sent_count
    RETURNING 1
  )
  SELECT * FROM upd;
END;
$fn$;

-- Last line of defence, evaluated immediately before the SMTP call. Catches a
-- reply or opt-out that arrived in the seconds between claiming and sending.
CREATE OR REPLACE FUNCTION acq.is_sendable(p_email_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_e acq.emails%ROWTYPE;
  v_l acq.leads%ROWTYPE;
BEGIN
  SELECT * INTO v_e FROM acq.emails WHERE id = p_email_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('sendable', false, 'reason', 'email_not_found'); END IF;
  IF v_e.status <> 'QUEUED' THEN
    RETURN jsonb_build_object('sendable', false, 'reason', 'status_' || v_e.status);
  END IF;

  SELECT * INTO v_l FROM acq.leads WHERE id = v_e.lead_id;
  IF v_l.opt_out        THEN RETURN jsonb_build_object('sendable', false, 'reason', 'lead_opted_out'); END IF;
  IF v_l.do_not_contact THEN RETURN jsonb_build_object('sendable', false, 'reason', 'do_not_contact'); END IF;
  IF v_l.replied_at IS NOT NULL THEN
    RETURN jsonb_build_object('sendable', false, 'reason', 'lead_already_replied');
  END IF;
  IF acq.is_suppressed(v_e.to_email::text, split_part(v_e.to_email::text,'@',2), NULL, v_l.id) THEN
    RETURN jsonb_build_object('sendable', false, 'reason', 'suppressed');
  END IF;

  RETURN jsonb_build_object('sendable', true, 'email_id', p_email_id,
                            'lead_id', v_l.id, 'step_no', v_e.step_no);
END;
$fn$;

-- ---------------------------------------------------------------------
-- Recording outcomes
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION acq.record_email_sent(
  p_email_id   uuid,
  p_message_id text,
  p_execution  text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_e        acq.emails%ROWTYPE;
  v_next     int;
  v_due      timestamptz;
  v_status   acq.lead_status;
BEGIN
  UPDATE acq.emails
     SET status = 'SENT', sent_at = now(), message_id = p_message_id,
         thread_key = coalesce(thread_key, p_message_id), error = NULL
   WHERE id = p_email_id AND status IN ('QUEUED','SENDING')
  RETURNING * INTO v_e;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'email_not_in_sendable_state');
  END IF;

  INSERT INTO acq.email_events (email_id, lead_id, event, provider, detail)
  VALUES (p_email_id, v_e.lead_id, 'SENT', 'SMTP', p_message_id);

  UPDATE acq.follow_ups
     SET status = 'SENT', email_id = p_email_id
   WHERE lead_id = v_e.lead_id AND campaign_id = v_e.campaign_id
     AND step_no = v_e.step_no AND status = 'SCHEDULED';

  UPDATE acq.leads
     SET last_contacted_at = now(),
         follow_up_count = GREATEST(follow_up_count, v_e.step_no)
   WHERE id = v_e.lead_id;

  v_status := CASE v_e.step_no
                WHEN 0 THEN 'CONTACTED'::acq.lead_status
                WHEN 1 THEN 'FOLLOW_UP_1'::acq.lead_status
                WHEN 2 THEN 'FOLLOW_UP_2'::acq.lead_status
                WHEN 3 THEN 'FOLLOW_UP_3'::acq.lead_status
                ELSE 'FOLLOW_UP_3'::acq.lead_status
              END;
  PERFORM acq.transition_lead(v_e.lead_id, v_status, 'email_sent', 'SYSTEM', p_execution);

  v_next := v_e.step_no + 1;
  v_due  := acq.schedule_follow_up(v_e.lead_id, v_e.campaign_id, v_next);

  INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload, execution_id)
  VALUES (v_e.lead_id, 'EMAIL_SENT', 'SYSTEM',
          format('step %s sent to %s', v_e.step_no, v_e.to_email),
          jsonb_build_object('email_id', p_email_id, 'message_id', p_message_id,
                             'next_follow_up_at', v_due),
          p_execution);

  RETURN jsonb_build_object('ok', true, 'email_id', p_email_id,
                            'lead_status', v_status, 'next_follow_up_at', v_due);
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.record_email_failed(
  p_email_id  uuid,
  p_error     text,
  p_execution text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_e acq.emails%ROWTYPE;
BEGIN
  UPDATE acq.emails
     SET status = CASE WHEN attempts >= 3 THEN 'FAILED'::acq.email_status
                       ELSE 'READY_TO_SEND'::acq.email_status END,
         failed_at = now(),
         error = p_error,
         queued_at = NULL
   WHERE id = p_email_id
  RETURNING * INTO v_e;

  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'email_not_found'); END IF;

  INSERT INTO acq.email_events (email_id, lead_id, event, provider, detail)
  VALUES (p_email_id, v_e.lead_id, 'FAILED', 'SMTP', left(p_error, 500));

  IF v_e.status = 'FAILED' THEN
    INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, lead_id, email_id, error, payload)
    VALUES ('50_outreach_send', p_execution, 'Send Email', v_e.lead_id, p_email_id, p_error,
            jsonb_build_object('attempts', v_e.attempts, 'to', v_e.to_email));
  END IF;

  RETURN jsonb_build_object('ok', true, 'email_id', p_email_id,
                            'status', v_e.status, 'will_retry', v_e.status = 'READY_TO_SEND');
END;
$fn$;

CREATE OR REPLACE FUNCTION acq.record_bounce(
  p_email_id  uuid,
  p_hard      boolean,
  p_detail    text,
  p_to_email  text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_e     acq.emails%ROWTYPE;
  v_addr  text;
BEGIN
  SELECT * INTO v_e FROM acq.emails WHERE id = p_email_id;
  v_addr := coalesce(p_to_email, v_e.to_email::text);

  INSERT INTO acq.email_events (email_id, lead_id, event, provider, detail)
  VALUES (p_email_id, v_e.lead_id,
          CASE WHEN p_hard THEN 'HARD_BOUNCE'::acq.email_event_type
               ELSE 'SOFT_BOUNCE'::acq.email_event_type END,
          'SMTP', left(coalesce(p_detail,''), 500));

  IF p_hard THEN
    UPDATE acq.emails SET status = 'BOUNCED' WHERE id = p_email_id;
    PERFORM acq.apply_opt_out('EMAIL', v_addr, 'HARD_BOUNCE', 'BOUNCE', v_e.lead_id,
                              jsonb_build_object('detail', left(coalesce(p_detail,''), 500)));
    IF v_e.lead_id IS NOT NULL THEN
      PERFORM acq.transition_lead(v_e.lead_id, 'BOUNCED', 'hard_bounce', 'SYSTEM');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'hard', p_hard, 'address', v_addr);
END;
$fn$;

-- Called the moment a human reply is detected, BEFORE classification, so that
-- follow-ups stop even if the AI classifier later fails or times out.
CREATE OR REPLACE FUNCTION acq.record_reply(p_reply_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_r acq.replies%ROWTYPE;
BEGIN
  SELECT * INTO v_r FROM acq.replies WHERE id = p_reply_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'reply_not_found'); END IF;
  IF v_r.lead_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'unmatched', true);
  END IF;

  UPDATE acq.leads SET replied_at = coalesce(replied_at, v_r.received_at)
   WHERE id = v_r.lead_id;

  PERFORM acq.stop_follow_ups(v_r.lead_id, 'prospect_replied');
  PERFORM acq.transition_lead(v_r.lead_id, 'REPLIED', 'inbound_reply', 'SYSTEM');

  INSERT INTO acq.email_events (email_id, lead_id, event, provider, detail)
  VALUES (v_r.email_id, v_r.lead_id, 'REPLIED', 'IMAP', left(coalesce(v_r.subject,''), 300));

  RETURN jsonb_build_object('ok', true, 'lead_id', v_r.lead_id);
END;
$fn$;
