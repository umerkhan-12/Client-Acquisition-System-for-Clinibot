-- =====================================================================
-- Migration 005: seed configuration
--
-- Everything here is DATA, not structure. Changing targeting, scoring weights,
-- sending limits or geography means updating rows — never editing a workflow.
-- Safe to re-run: every statement is idempotent.
-- =====================================================================

SET search_path = acq, public;

-- ---------------------------------------------------------------------
-- Runtime settings
-- ---------------------------------------------------------------------
INSERT INTO acq.settings (key, value, description) VALUES

-- Autonomy switches. Both ship OFF. Turn auto_send on only after a few dozen
-- manually approved emails have shown the drafts are consistently good.
('outreach.auto_send_enabled',   'false'::jsonb,
 'When false every generated email waits in READY_FOR_REVIEW for human approval.'),
('outreach.auto_reply_enabled',  'false'::jsonb,
 'When false, replies to interested prospects are drafted but not sent automatically.'),
('outreach.dry_run',             'false'::jsonb,
 'When true the send workflow does everything except the actual SMTP call.'),

-- Volume ceilings. These are the outer bounds; per-campaign and per-mailbox
-- limits and the warm-up ramp can only make them smaller, never larger.
('limits.daily_send_limit',      '20'::jsonb,  'Global ceiling on emails per day.'),
('limits.hourly_send_limit',     '4'::jsonb,   'Global ceiling on emails per hour.'),
('limits.per_domain_limit',      '1'::jsonb,   'Max simultaneous emails to one recipient domain.'),
('limits.follow_up_limit',       '3'::jsonb,   'Max follow-ups after the initial email.'),
('limits.per_campaign_limit',    'null'::jsonb,'Lifetime cap per campaign, null = uncapped.'),

-- AI budget and quality gates
('ai.model',                     '"gemini-2.5-flash"'::jsonb, 'Model used for research, personalization and classification.'),
('ai.max_research_per_run',      '15'::jsonb,  'Leads researched per scheduled run.'),
('ai.min_email_confidence',      '0.70'::jsonb,'Below this a draft goes to human review regardless of score.'),
('ai.min_classification_confidence','0.75'::jsonb,'Below this a reply is escalated to a human.'),
('ai.research_ttl_days',         '90'::jsonb,  'Cached research is reused until this many days old.'),
('ai.daily_cost_cap_usd',        '2.00'::jsonb,'Discovery/research pauses once this is exceeded in a day.'),

-- Discovery
('discovery.max_tasks_per_run',  '4'::jsonb,   'Discovery tasks processed per scheduled run.'),
('discovery.max_new_leads_per_run','60'::jsonb,'Upper bound on new leads created per run.'),
('discovery.default_provider',   '"OSM"'::jsonb,'OSM is free; switch to GOOGLE_PLACES for higher data quality.'),
('discovery.crawl_user_agent',
 '"ZenvexaBot/1.0 (+https://zenvexa.tech/bot; contact: hello@zenvexa.tech)"'::jsonb,
 'Identifies our crawler honestly. Must stay accurate and reachable.'),
('discovery.max_pages_per_site', '3'::jsonb,   'Hard cap on pages fetched from any one clinic website.'),
('discovery.crawl_delay_ms',     '2000'::jsonb,'Minimum delay between requests to the same host.'),

-- Notifications and links
('notify.telegram_chat_id',      '""'::jsonb,  'Telegram chat that receives hot-lead alerts.'),
('notify.email_to',              '""'::jsonb,  'Fallback address for alerts if Telegram fails.'),
('demo.booking_url',             '""'::jsonb,  'Cal.com/Calendly link. Left empty, the AI must never invent times.'),

-- Identity used in every email footer. Legally required in most markets.
('company.brand',                '"Zenvexa"'::jsonb, 'Brand name. Not asserted to be a registered company.'),
('company.product',              '"Clinibot"'::jsonb, NULL),
('company.website',              '"https://zenvexa.tech"'::jsonb, NULL),
('company.sender_person',        '"Umer"'::jsonb, 'Real human whose name appears on outbound mail.'),
('company.postal_address',       '""'::jsonb,
 'REQUIRED before sending. A real reachable postal address must appear in the footer.'),
('unsubscribe.base_url',         '""'::jsonb,
 'Public URL of the unsubscribe webhook, e.g. https://n8n.zenvexa.tech/webhook/unsubscribe'),

-- Content guardrails, enforced in code before any email is queued.
('guardrails.banned_phrases',
 '["revolutionary","guaranteed","10x","best ai","transform your business","game-changing",
   "act now","limited time","risk-free","100% ","cutting-edge","world-class","never miss another",
   "skyrocket","explode your","unlock the power"]'::jsonb,
 'Hype and false-urgency language. A draft containing any of these is rejected.'),
('guardrails.max_body_chars',    '1400'::jsonb, 'Long cold emails do not get read.'),
('guardrails.min_body_chars',    '350'::jsonb,  'Too short reads as a template.'),
('guardrails.required_tokens',
 '["{{UNSUBSCRIBE}}"]'::jsonb,
 'Every generated body must contain these placeholders or it is rejected.'),
('guardrails.forbid_medical_claims', 'true'::jsonb,
 'Rejects drafts that make clinical, diagnostic or patient-outcome claims.')

ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Markets. Geography is a row, never a hard-coded value.
-- consent_model drives whether cold outreach is permitted at all.
-- ---------------------------------------------------------------------
INSERT INTO acq.markets (code, name, country_code, phone_cc, timezone, currency, languages, consent_model, enabled, legal_notes) VALUES
('PK', 'Pakistan',             'PK', '92',  'Asia/Karachi', 'PKR', ARRAY['en','ur'], 'OPT_OUT_B2B', true,
 'B2B outreach to published business addresses. PECA 2016 applies; honour opt-outs immediately. Include sender identity and a working opt-out in every message.'),
('AE', 'United Arab Emirates', 'AE', '971', 'Asia/Dubai',   'AED', ARRAY['en','ar'], 'OPT_IN_REQUIRED', false,
 'UAE PDPL plus TDRA rules treat unsolicited marketing restrictively. Do NOT enable until consent basis and local counsel are confirmed.'),
('SA', 'Saudi Arabia',         'SA', '966', 'Asia/Riyadh',  'SAR', ARRAY['en','ar'], 'OPT_IN_REQUIRED', false,
 'PDPL requires a lawful basis for marketing contact. Keep disabled pending review.'),
('GB', 'United Kingdom',       'GB', '44',  'Europe/London','GBP', ARRAY['en'],      'MIXED', false,
 'PECR permits B2B email to corporate subscribers (Ltd/LLP) but treats sole traders and partnerships as individuals requiring consent. Many private clinics are sole traders — filter on entity type before enabling.')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Scoring configuration v1
-- Weights sum to ~105 for a perfect lead, so scores spread naturally across
-- the 0-100 band instead of everything clamping at the top.
-- ---------------------------------------------------------------------
INSERT INTO acq.scoring_configs (version, active, weights, thresholds) VALUES
('v1', true,
 '{
    "has_website": 8,
    "has_public_email": 12,
    "has_phone": 3,
    "has_whatsapp": 15,
    "multiple_doctors": 6,
    "active_listing": 4,
    "category_tier": { "1": 12, "2": 4, "3": 0 },

    "confirmed_multiple_doctors": 6,
    "confirmed_whatsapp": 3,
    "advertises_appointments": 12,
    "high_value_service": 12,
    "active_social": 4,
    "no_online_booking_gap": 8,

    "no_contact_channel": -40,
    "large_institution": -10
  }'::jsonb,
 '{
    "qualify": 45,
    "auto_send": 70,
    "hot": 80,
    "min_research_confidence": 0.60,
    "active_listing_reviews": 20
  }'::jsonb)
ON CONFLICT (version) DO NOTHING;

-- ---------------------------------------------------------------------
-- Sending identity
--
-- smtp_credential_name / imap_credential_name are NAMES OF n8n CREDENTIALS.
-- No password, key or token is ever stored in this database.
--
-- Recommendation (see docs/06-deliverability.md): send outreach from a
-- SEPARATE domain from the one that will run Clinibot's product mail, so a
-- reputation problem in outbound sales cannot damage transactional delivery.
-- ---------------------------------------------------------------------
INSERT INTO acq.mailboxes (key, from_email, from_name, reply_to, smtp_credential_name, imap_credential_name,
                           daily_cap, hourly_cap, warmup_stage, warmup_started_on, active) VALUES
('primary', 'umer@zenvexa.tech', 'Umer', 'umer@zenvexa.tech',
 'zenvexa-smtp', 'zenvexa-imap', 40, 6, 1, CURRENT_DATE, true)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Campaign and sequence
-- ---------------------------------------------------------------------
INSERT INTO acq.campaigns (
  key, name, market_id, mailbox_id, status,
  daily_send_limit, hourly_send_limit, per_domain_limit, max_follow_ups,
  min_score_to_send, sending_window_start, sending_window_end, sending_days, timezone
)
SELECT
  'pk-karachi-tier1', 'Karachi — high-priority clinics',
  m.id, mb.id, 'ACTIVE',
  20, 4, 1, 3,
  55, '09:30', '17:00', ARRAY[1,2,3,4,5], 'Asia/Karachi'
FROM acq.markets m, acq.mailboxes mb
WHERE m.code = 'PK' AND mb.key = 'primary'
ON CONFLICT (key) DO NOTHING;

-- Step 0 is the initial email; 1-3 are the bounded follow-up sequence.
-- Delays are ranges so the cadence is jittered and does not look automated.
INSERT INTO acq.sequence_steps (campaign_id, step_no, kind, min_delay_days, max_delay_days, prompt_key, enabled)
SELECT c.id, s.step_no, s.kind, s.min_d, s.max_d, s.prompt_key, true
FROM acq.campaigns c,
     (VALUES
        (0, 'INITIAL',   0, 0, 'email_initial'),
        (1, 'FOLLOW_UP', 4, 6, 'followup_1_value'),
        (2, 'FOLLOW_UP', 6, 9, 'followup_2_different_angle'),
        (3, 'BREAKUP',   8, 12,'followup_3_breakup')
     ) AS s(step_no, kind, min_d, max_d, prompt_key)
WHERE c.key = 'pk-karachi-tier1'
ON CONFLICT (campaign_id, step_no) DO NOTHING;

-- ---------------------------------------------------------------------
-- Discovery tasks: Karachi tier-1 areas × high-priority clinic categories
--
-- The lat/lng values are APPROXIMATE area centroids used only as search
-- centres for the Overpass/Places radius query. Tune them against a map
-- before the first production run; they do not represent any real business.
-- ---------------------------------------------------------------------
INSERT INTO acq.discovery_tasks
  (market_id, city, area, query_term, category, provider, priority_tier, bbox, cadence_days, enabled)
SELECT
  m.id, a.city, a.area, q.query_term, q.category,
  (SELECT value #>> '{}' FROM acq.settings WHERE key = 'discovery.default_provider'),
  q.tier,
  jsonb_build_object('type','around','lat',a.lat,'lng',a.lng,'radius_m',a.radius),
  30, true
FROM acq.markets m
CROSS JOIN (VALUES
    -- Tier 1: Karachi
    ('Karachi','North Nazimabad',   24.9400, 67.0400, 3500),
    ('Karachi','Nazimabad',         24.9100, 67.0300, 3000),
    ('Karachi','North Karachi',     24.9800, 67.0600, 4000),
    ('Karachi','Gulshan-e-Iqbal',   24.9200, 67.0900, 4000),
    ('Karachi','Gulistan-e-Johar',  24.9200, 67.1300, 4000),
    ('Karachi','PECHS',             24.8700, 67.0600, 2500),
    ('Karachi','Clifton',           24.8138, 67.0300, 3000),
    ('Karachi','DHA',               24.8000, 67.0500, 5000),
    ('Karachi','Bahadurabad',       24.8800, 67.0650, 2500),
    ('Karachi','Federal B Area',    24.9300, 67.0700, 3500)
  ) AS a(city, area, lat, lng, radius)
CROSS JOIN (VALUES
    ('dental clinic',        'DENTAL',          1),
    ('dermatology clinic',   'DERMATOLOGY',     1),
    ('cosmetic clinic',      'COSMETIC',        1),
    ('aesthetic clinic',     'AESTHETIC',       1),
    ('plastic surgery',      'PLASTIC_SURGERY', 1),
    ('fertility clinic',     'FERTILITY',       1),
    ('physiotherapy clinic', 'PHYSIOTHERAPY',   1),
    ('specialist clinic',    'SPECIALIST',      1)
  ) AS q(query_term, category, tier)
WHERE m.code = 'PK'
  AND NOT EXISTS (
    SELECT 1 FROM acq.discovery_tasks d
     WHERE d.city = a.city AND d.area = a.area AND d.category = q.category
  );

-- Tier 2 cities, seeded but running on a slower cadence.
INSERT INTO acq.discovery_tasks
  (market_id, city, area, query_term, category, provider, priority_tier, bbox, cadence_days, enabled)
SELECT
  m.id, a.city, NULL, q.query_term, q.category,
  (SELECT value #>> '{}' FROM acq.settings WHERE key = 'discovery.default_provider'),
  2,
  jsonb_build_object('type','around','lat',a.lat,'lng',a.lng,'radius_m',a.radius),
  45, true
FROM acq.markets m
CROSS JOIN (VALUES
    ('Lahore',      31.5204, 74.3587, 12000),
    ('Islamabad',   33.6844, 73.0479, 10000),
    ('Rawalpindi',  33.5651, 73.0169, 10000)
  ) AS a(city, lat, lng, radius)
CROSS JOIN (VALUES
    ('dental clinic',      'DENTAL',      1),
    ('dermatology clinic', 'DERMATOLOGY', 1),
    ('cosmetic clinic',    'COSMETIC',    1)
  ) AS q(query_term, category, tier)
WHERE m.code = 'PK'
  AND NOT EXISTS (
    SELECT 1 FROM acq.discovery_tasks d
     WHERE d.city = a.city AND d.area IS NULL AND d.category = q.category
  );
