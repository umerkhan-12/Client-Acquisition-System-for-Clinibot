-- =====================================================================
-- Migration 013: what each business is missing, and what to sell it
--
-- For every lead, acq.lead_intel() answers the questions a person asks
-- before writing to a business:
--
--   opportunities        what is missing, each with the evidence it rests on
--   recommended_service  the one thing to pitch first, with a complexity
--   why                  why this business is worth contacting, in facts only
--   priority             HOT / HIGH / MEDIUM / LOW from the lead score
--   best_channel         WhatsApp, a call, or email
--
-- Deterministic, from data already collected (the Google Maps listing and
-- workflow 25's homepage audit), so it costs nothing and is the same every
-- time it is asked. Nothing is claimed that was not observed: a feature not
-- seen on a homepage is "not found on the homepage", and on a page too thin
-- to judge (a JavaScript-rendered shell) it is unknown and claims nothing.
--
-- The rules are rows in acq.settings, so retuning which business types need
-- ordering or booking, or what each service is called, is not a migration.
-- =====================================================================

SET search_path = acq, public;

INSERT INTO acq.settings (key, value, description) VALUES
('web.services', '{
   "WEBSITE":              {"label": "Business website with a WhatsApp button", "complexity": "LOW"},
   "WEBSITE_ORDERING":     {"label": "Website with menu and online ordering",   "complexity": "MEDIUM"},
   "WEBSITE_BOOKING":      {"label": "Website with online booking",             "complexity": "MEDIUM"},
   "WEBSITE_SHOP":         {"label": "Website with an online shop",             "complexity": "HIGH"},
   "REDESIGN":             {"label": "Website redesign: mobile-friendly, secure and fast", "complexity": "MEDIUM"},
   "ONLINE_ORDERING":      {"label": "Online ordering system",                  "complexity": "MEDIUM"},
   "BOOKING":              {"label": "Online booking system",                   "complexity": "MEDIUM"},
   "ECOMMERCE":            {"label": "Online shop (e-commerce)",                "complexity": "HIGH"},
   "WHATSAPP_INTEGRATION": {"label": "WhatsApp button and enquiry form",        "complexity": "LOW"}
 }'::jsonb,
 'Services a lead can be recommended, with the label shown and pitched, and a build complexity.'),
('web.category_needs', '{
   "ORDERING": ["CAFE", "RESTAURANT", "BAKERY"],
   "BOOKING":  ["SALON", "FITNESS", "EDUCATION", "DENTAL", "DERMATOLOGY", "AESTHETIC",
                "PHYSIOTHERAPY", "GENERAL_PRACTICE", "SPECIALIST", "FERTILITY",
                "PLASTIC_SURGERY", "COSMETIC", "DIAGNOSTIC"],
   "SHOP":     ["RETAIL"]
 }'::jsonb,
 'Which business categories are expected to take orders, bookings or sales online.'),
('web.priority_bands', '{"HOT": 90, "HIGH": 75, "MEDIUM": 50}'::jsonb,
 'Lead-score floors for each priority label; anything below MEDIUM is LOW.')
ON CONFLICT (key) DO NOTHING;

-- SECURITY DEFINER with a pinned search_path, like transition_lead() in 010:
-- the dashboard reads this through a view, and a function in a view runs with
-- the CALLER's rights, which for acq_dashboard exclude acq.leads.
CREATE OR REPLACE FUNCTION acq.lead_intel(p_lead_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
DECLARE
  l          acq.leads%ROWTYPE;
  a          acq.website_audits%ROWTYPE;
  has_audit  boolean := false;
  svc        jsonb;
  needs      jsonb;
  bands      jsonb;
  stats      jsonb;
  v_rating   numeric;
  v_reviews  int;
  real_site  boolean;
  f          jsonb := '{}'::jsonb;
  need       text;
  opps       jsonb := '[]'::jsonb;
  why        text[] := '{}';
  rec        text;
  chan       jsonb;
  best       text;
  prio       text;
  site_state text;
  issue_txt  text;
  labels     jsonb := '{
    "site_unreachable":    "does not load",
    "site_parked":         "shows a parked or under-construction page",
    "no_https":            "is not secure (no https)",
    "not_mobile_friendly": "is not set up for phones",
    "slow_or_heavy":       "is slow or very heavy",
    "outdated":            "looks outdated",
    "no_contact_cta":      "has no call, WhatsApp or enquiry button"
  }'::jsonb;
BEGIN
  SELECT * INTO l FROM acq.leads WHERE id = p_lead_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT value INTO svc   FROM acq.settings WHERE key = 'web.services';
  SELECT value INTO needs FROM acq.settings WHERE key = 'web.category_needs';
  SELECT value INTO bands FROM acq.settings WHERE key = 'web.priority_bands';

  SELECT * INTO a FROM acq.website_audits WHERE lead_id = l.id AND is_current;
  has_audit := FOUND;
  IF has_audit THEN f := coalesce(a.raw -> 'features', '{}'::jsonb); END IF;

  stats     := acq.listing_stats(l.raw);
  v_rating  := nullif(stats ->> 'rating', '')::numeric;
  v_reviews := nullif(stats ->> 'userRatingCount', '')::int;
  real_site := acq.has_real_website(l.website);

  need := CASE
            WHEN coalesce(needs -> 'ORDERING', '[]') ? l.category THEN 'ORDERING'
            WHEN coalesce(needs -> 'BOOKING',  '[]') ? l.category THEN 'BOOKING'
            WHEN coalesce(needs -> 'SHOP',     '[]') ? l.category THEN 'SHOP'
          END;

  -- ---- the website itself ----------------------------------------------
  IF l.website IS NULL THEN
    site_state := 'NO_WEBSITE';
    opps := opps || jsonb_build_array(jsonb_build_object(
      'code', 'NO_WEBSITE', 'detail', 'No website on its Google Maps listing', 'evidence', l.source_url));
  ELSIF NOT real_site THEN
    site_state := 'SOCIAL_ONLY';
    opps := opps || jsonb_build_array(jsonb_build_object(
      'code', 'SOCIAL_ONLY', 'detail', 'Only a social media page, no website of its own', 'evidence', l.website));
  ELSIF NOT has_audit THEN
    site_state := 'NOT_CHECKED';
  ELSIF NOT coalesce(a.reachable, true) THEN
    site_state := 'BROKEN';
  ELSIF cardinality(a.issues) > 0 THEN
    site_state := 'WEAK';
  ELSE
    site_state := 'OK';
  END IF;

  IF site_state IN ('BROKEN', 'WEAK') THEN
    SELECT string_agg(coalesce(labels ->> i, i), ', ') INTO issue_txt FROM unnest(a.issues) i;
    opps := opps || jsonb_build_array(jsonb_build_object(
      'code', 'WEAK_WEBSITE', 'detail', 'Its website ' || issue_txt, 'evidence', a.url));
  END IF;

  -- ---- what the business type needs online -----------------------------
  -- Only claimed when there is no website at all, or the audit judged the
  -- homepage and did not find it ('false'). Unknown (null) claims nothing.
  IF need = 'ORDERING' AND (NOT real_site OR f ->> 'online_ordering' = 'false') THEN
    opps := opps || jsonb_build_array(jsonb_build_object(
      'code', 'NO_ONLINE_ORDERING',
      'detail', CASE WHEN real_site THEN 'No online ordering found on its homepage'
                     ELSE 'No way to order online' END,
      'evidence', coalesce(a.url, l.source_url)));
  ELSIF need = 'BOOKING' AND (NOT real_site OR f ->> 'booking' = 'false') THEN
    opps := opps || jsonb_build_array(jsonb_build_object(
      'code', 'NO_ONLINE_BOOKING',
      'detail', CASE WHEN real_site THEN 'No online booking found on its homepage'
                     ELSE 'No way to book online' END,
      'evidence', coalesce(a.url, l.source_url)));
  ELSIF need = 'SHOP' AND (NOT real_site OR f ->> 'ecommerce' = 'false') THEN
    opps := opps || jsonb_build_array(jsonb_build_object(
      'code', 'NO_ONLINE_SHOP',
      'detail', CASE WHEN real_site THEN 'No online shop found on its homepage'
                     ELSE 'No way to buy online' END,
      'evidence', coalesce(a.url, l.source_url)));
  END IF;

  IF real_site AND has_audit AND coalesce(a.reachable, false)
     AND NOT coalesce(a.has_whatsapp_link, false) AND NOT coalesce(a.has_tel_link, false)
     AND NOT (a.issues @> ARRAY['no_contact_cta']) THEN
    opps := opps || jsonb_build_array(jsonb_build_object(
      'code', 'NO_WHATSAPP_BUTTON', 'detail', 'No WhatsApp or call button on its homepage', 'evidence', a.url));
  END IF;

  -- ---- the one thing to pitch first -------------------------------------
  rec := CASE
    WHEN NOT real_site AND need = 'ORDERING' THEN 'WEBSITE_ORDERING'
    WHEN NOT real_site AND need = 'BOOKING'  THEN 'WEBSITE_BOOKING'
    WHEN NOT real_site AND need = 'SHOP'     THEN 'WEBSITE_SHOP'
    WHEN NOT real_site                       THEN 'WEBSITE'
    WHEN opps @> '[{"code": "WEAK_WEBSITE"}]'::jsonb       THEN 'REDESIGN'
    WHEN opps @> '[{"code": "NO_ONLINE_ORDERING"}]'::jsonb THEN 'ONLINE_ORDERING'
    WHEN opps @> '[{"code": "NO_ONLINE_BOOKING"}]'::jsonb  THEN 'BOOKING'
    WHEN opps @> '[{"code": "NO_ONLINE_SHOP"}]'::jsonb     THEN 'ECOMMERCE'
    WHEN opps @> '[{"code": "NO_WHATSAPP_BUTTON"}]'::jsonb THEN 'WHATSAPP_INTEGRATION'
  END;

  -- ---- why, in facts only -------------------------------------------------
  IF v_reviews IS NOT NULL AND v_reviews >= 15 AND v_rating IS NOT NULL THEN
    why := why || format('%s stars from %s Google reviews', trim(to_char(v_rating, 'FM9.0')),
                         trim(to_char(v_reviews, 'FM999,999,999')));
  END IF;
  IF jsonb_array_length(opps) > 0 THEN
    why := why || (SELECT array_agg(lower(left(o ->> 'detail', 1)) || substr(o ->> 'detail', 2))
                     FROM jsonb_array_elements(opps) o);
  END IF;

  chan := acq.manual_channel(l);
  best := coalesce(chan ->> 'channel', CASE WHEN l.public_email IS NOT NULL THEN 'EMAIL' END, 'NONE');

  prio := CASE
    WHEN l.lead_score >= coalesce((bands ->> 'HOT')::int, 90)    THEN 'HOT'
    WHEN l.lead_score >= coalesce((bands ->> 'HIGH')::int, 75)   THEN 'HIGH'
    WHEN l.lead_score >= coalesce((bands ->> 'MEDIUM')::int, 50) THEN 'MEDIUM'
    ELSE 'LOW'
  END;

  RETURN jsonb_build_object(
    'lead_id',             l.id,
    'website_status',      site_state,
    'platform',            CASE WHEN has_audit THEN a.raw ->> 'platform' END,
    'opportunities',       opps,
    'recommended_service', rec,
    'service_label',       svc -> rec ->> 'label',
    'complexity',          svc -> rec ->> 'complexity',
    'why',                 nullif(array_to_string(why, '; '), ''),
    'priority',            prio,
    'best_channel',        best
  );
END;
$fn$;

-- One row per lead, for the dashboard and for export.
CREATE OR REPLACE VIEW acq.v_lead_intel AS
SELECT
  l.id, l.clinic_name AS business_name, l.offer, l.category, l.area, l.city,
  l.lead_score, l.status, l.website, l.source_url AS listing_url, l.created_at,
  nullif(acq.listing_stats(l.raw) ->> 'rating', '')::numeric      AS rating,
  nullif(acq.listing_stats(l.raw) ->> 'userRatingCount', '')::int AS review_count,
  i ->> 'website_status'      AS website_status,
  i ->> 'platform'            AS platform,
  i -> 'opportunities'        AS opportunities,
  i ->> 'recommended_service' AS recommended_service,
  i ->> 'service_label'       AS service_label,
  i ->> 'complexity'          AS complexity,
  i ->> 'why'                 AS why,
  i ->> 'priority'            AS priority,
  i ->> 'best_channel'        AS best_channel
FROM acq.leads l
CROSS JOIN LATERAL acq.lead_intel(l.id) i
WHERE NOT l.opt_out AND NOT l.do_not_contact;

-- The outreach queue with the recommendation alongside. A separate view on
-- top of v_manual_outreach, not new columns on it: migration 011 re-creates
-- v_manual_outreach with its original columns on every re-run, and Postgres
-- refuses to drop columns from a view, so extending it would break re-runs.
CREATE OR REPLACE VIEW acq.v_manual_outreach_intel AS
SELECT o.*,
       i ->> 'service_label' AS service_label,
       i ->> 'complexity'    AS complexity,
       i ->> 'why'           AS why,
       i ->> 'priority'      AS priority
FROM acq.v_manual_outreach o
CROSS JOIN LATERAL acq.lead_intel(o.lead_id) i;

GRANT EXECUTE ON FUNCTION acq.lead_intel(uuid) TO acq_n8n;
GRANT SELECT ON acq.v_lead_intel, acq.v_manual_outreach_intel TO acq_dashboard;
