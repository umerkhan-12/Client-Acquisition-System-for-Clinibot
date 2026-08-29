-- =====================================================================
-- Zenvexa / Clinibot — Client Acquisition System
-- Migration 001: core schema
--
-- SAFETY: everything lives in the dedicated `acq` schema. This migration
-- never touches, reads, or alters Clinibot's own tables. It is designed to
-- run either in a separate database (recommended) or as a separate schema
-- inside the Clinibot database.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email/domain
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- fuzzy clinic-name deduplication

CREATE SCHEMA IF NOT EXISTS acq;

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------

-- Pipeline state machine. Legal transitions are data, not code — see
-- acq.status_transitions and acq.transition_lead().
DO $mig$ BEGIN
  CREATE TYPE acq.lead_status AS ENUM (
    'NEW',
    'RESEARCHING',
    'QUALIFIED',
    'READY_FOR_REVIEW',
    'APPROVED',
    'CONTACTED',
    'FOLLOW_UP_1',
    'FOLLOW_UP_2',
    'FOLLOW_UP_3',
    'REPLIED',
    'INTERESTED',
    'DEMO_REQUESTED',
    'DEMO_BOOKED',
    'CUSTOMER',
    -- terminal / negative
    'NOT_INTERESTED',
    'LATER',
    'OPTED_OUT',
    'BOUNCED',
    'INVALID',
    'DO_NOT_CONTACT',
    'REJECTED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.contact_type AS ENUM (
    'EMAIL', 'PHONE', 'WHATSAPP', 'WEBSITE_FORM', 'SOCIAL'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

-- How a contact value came to exist. GUESSED is deliberately absent: the
-- system must never invent an address. See the CHECK on acq.leads.
DO $mig$ BEGIN
  CREATE TYPE acq.contact_source AS ENUM (
    'CLINIC_WEBSITE',      -- read from the clinic's own public site
    'GOOGLE_BUSINESS',     -- Google Business Profile / Places API
    'OSM',                 -- OpenStreetMap public tags
    'PUBLIC_DIRECTORY',    -- public business directory listing
    'MANUAL',              -- entered by a human operator
    'INBOUND_REPLY'        -- learned from a reply the prospect sent us
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.verification_status AS ENUM (
    'UNVERIFIED',
    'PUBLICLY_LISTED',   -- observed verbatim on a public page we can cite
    'SYNTAX_OK',
    'MX_OK',             -- domain has MX records (DNS-over-HTTPS check)
    'VERIFIED',          -- third-party verifier said deliverable
    'INVALID',
    'ROLE_ACCOUNT'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.email_status AS ENUM (
    'DRAFT',
    'PENDING_APPROVAL',
    'READY_TO_SEND',
    'QUEUED',
    'SENDING',
    'SENT',
    'FAILED',
    'CANCELLED',
    'BOUNCED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.email_event_type AS ENUM (
    'QUEUED','SENT','DELIVERED','SOFT_BOUNCE','HARD_BOUNCE','COMPLAINT',
    'OPENED','CLICKED','REPLIED','FAILED','UNSUBSCRIBED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.reply_class AS ENUM (
    'INTERESTED','VERY_INTERESTED','ASKING_PRICE','ASKING_DEMO','NEEDS_MORE_INFO',
    'NOT_INTERESTED','OPT_OUT','LATER','WRONG_PERSON','AUTOMATIC_REPLY','UNCLEAR'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.approval_kind AS ENUM (
    'EMAIL_DRAFT',
    'REPLY_DRAFT',
    'LOW_CONFIDENCE_CLASSIFICATION',
    'DATA_CONFLICT',
    'UNCERTAIN_EMAIL_ADDRESS',
    'PRICING_QUESTION',
    'LEGAL_QUESTION',
    'COMPLAINT',
    'DELETION_REQUEST',
    'MEDICAL_QUESTION',
    'CUSTOM_INTEGRATION',
    'GUARDRAIL_FAILURE',
    'OTHER'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.approval_status AS ENUM (
    'PENDING','APPROVED','REJECTED','EDITED','EXPIRED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.suppression_scope AS ENUM ('EMAIL','DOMAIN','PHONE','LEAD');
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.suppression_reason AS ENUM (
    'OPT_OUT_REQUEST','HARD_BOUNCE','COMPLAINT','MANUAL','ROLE_ACCOUNT',
    'INVALID_SYNTAX','NO_MX','COMPETITOR','LEGAL','DELETION_REQUEST'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

-- Keys used to recognise "we already know this business".
DO $mig$ BEGIN
  CREATE TYPE acq.identity_key_type AS ENUM (
    'PLACE_ID','OSM_ID','DOMAIN','EMAIL','PHONE','WHATSAPP','NAME_CITY'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.actor AS ENUM ('SYSTEM','AI','HUMAN','PROSPECT');
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.consent_model AS ENUM (
    'OPT_OUT_B2B',      -- B2B cold contact permitted with clear opt-out
    'OPT_IN_REQUIRED',  -- prior consent required for marketing email
    'MIXED'             -- corporate subscribers opt-out, sole traders opt-in
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

DO $mig$ BEGIN
  CREATE TYPE acq.followup_status AS ENUM (
    'SCHEDULED','CANCELLED','SENT','SKIPPED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $mig$;

-- ---------------------------------------------------------------------
-- Configuration tables
-- ---------------------------------------------------------------------

-- Free-form runtime configuration. n8n reads limits/thresholds from here so
-- they can change without editing workflows or restarting containers.
CREATE TABLE IF NOT EXISTS acq.settings (
  key          text PRIMARY KEY,
  value        jsonb NOT NULL,
  description  text,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   text
);

-- Geography is configuration, never hard-coded. Adding UAE/KSA/UK is a row.
CREATE TABLE IF NOT EXISTS acq.markets (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code           text NOT NULL UNIQUE,               -- 'PK', 'AE', 'UK'
  name           text NOT NULL,
  country_code   text NOT NULL,                      -- ISO-3166 alpha-2
  phone_cc       text NOT NULL,                      -- '92', '971', '44'
  timezone       text NOT NULL,                      -- 'Asia/Karachi'
  currency       text NOT NULL DEFAULT 'USD',
  languages      text[] NOT NULL DEFAULT ARRAY['en'],
  consent_model  acq.consent_model NOT NULL DEFAULT 'OPT_OUT_B2B',
  legal_notes    text,
  enabled        boolean NOT NULL DEFAULT false,
  config         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Versioned scoring weights so a score can always be explained after the fact.
CREATE TABLE IF NOT EXISTS acq.scoring_configs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version     text NOT NULL UNIQUE,
  weights     jsonb NOT NULL,
  thresholds  jsonb NOT NULL,
  active      boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Only one active scoring config at a time.
CREATE UNIQUE INDEX IF NOT EXISTS scoring_configs_one_active
  ON acq.scoring_configs (active) WHERE active;

-- Sending identities. Credentials are NEVER stored here — only the *name* of
-- the n8n credential to use, so secrets stay inside n8n's encrypted store.
CREATE TABLE IF NOT EXISTS acq.mailboxes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                   text NOT NULL UNIQUE,
  from_email            citext NOT NULL,
  from_name             text NOT NULL,
  reply_to              citext,
  smtp_credential_name  text NOT NULL,   -- reference into n8n credentials
  imap_credential_name  text,            -- reference into n8n credentials
  daily_cap             int NOT NULL DEFAULT 20,
  hourly_cap            int NOT NULL DEFAULT 6,
  warmup_stage          int NOT NULL DEFAULT 1,
  warmup_started_on     date,
  active                boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT mailboxes_caps_sane CHECK (daily_cap > 0 AND hourly_cap > 0)
);

-- ---------------------------------------------------------------------
-- Lead discovery
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.discovery_tasks (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  market_id       uuid NOT NULL REFERENCES acq.markets(id) ON DELETE CASCADE,
  city            text NOT NULL,
  area            text,
  query_term      text NOT NULL,            -- 'dental clinic'
  category        text NOT NULL,            -- 'DENTAL'
  provider        text NOT NULL DEFAULT 'OSM',  -- 'OSM' | 'GOOGLE_PLACES'
  priority_tier   smallint NOT NULL DEFAULT 2,
  bbox            jsonb,                    -- {south,west,north,east} for OSM
  cadence_days    int NOT NULL DEFAULT 30,
  last_run_at     timestamptz,
  next_run_at     timestamptz NOT NULL DEFAULT now(),
  last_result_count int,
  enabled         boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS discovery_tasks_due_idx
  ON acq.discovery_tasks (next_run_at) WHERE enabled;

-- ---------------------------------------------------------------------
-- Leads
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.leads (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  market_id         uuid NOT NULL REFERENCES acq.markets(id),

  clinic_name       text NOT NULL,
  normalized_name   text NOT NULL,          -- maintained by trigger
  website           text,
  domain            text,                   -- normalized, maintained by trigger
  city              text,
  area              text,
  address           text,
  lat               numeric(10,7),
  lng               numeric(10,7),

  -- Primary contact channels, denormalized from acq.lead_contacts for fast
  -- querying by n8n and the dashboard. acq.lead_contacts remains the full record.
  phone             text,                   -- E.164
  whatsapp          text,                   -- E.164
  public_email      citext,
  email_source      acq.contact_source,
  email_evidence_url text,

  specialties       text[] NOT NULL DEFAULT '{}',
  doctor_count      int,
  services          text[] NOT NULL DEFAULT '{}',
  booking_method    text,
  category          text,                   -- DENTAL | DERMATOLOGY | ...
  priority_tier     smallint NOT NULL DEFAULT 2,

  source            text NOT NULL,
  source_url        text,
  source_ref        text,                   -- place_id / OSM id

  lead_score        int NOT NULL DEFAULT 0,
  ai_score          int,
  score_breakdown   jsonb NOT NULL DEFAULT '{}'::jsonb,
  scoring_version   text,

  status            acq.lead_status NOT NULL DEFAULT 'NEW',
  status_reason     text,

  last_contacted_at timestamptz,
  next_follow_up_at timestamptz,
  follow_up_count   int NOT NULL DEFAULT 0,
  replied_at        timestamptz,

  opt_out           boolean NOT NULL DEFAULT false,
  do_not_contact    boolean NOT NULL DEFAULT false,

  notes             text,
  raw               jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Cooperative locking for concurrent n8n executions.
  locked_by         text,
  locked_at         timestamptz,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  -- HARD RULE (section 6 of the brief): an email address may only exist if it
  -- was actually observed on a public source. There is no code path that can
  -- persist a guessed address, because the database refuses it.
  CONSTRAINT leads_email_must_have_provenance CHECK (
    public_email IS NULL
    OR (email_source IS NOT NULL AND email_evidence_url IS NOT NULL)
  ),
  CONSTRAINT leads_email_syntax CHECK (
    public_email IS NULL OR public_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  ),
  CONSTRAINT leads_score_range CHECK (lead_score BETWEEN 0 AND 100),
  CONSTRAINT leads_ai_score_range CHECK (ai_score IS NULL OR ai_score BETWEEN 0 AND 100)
);

CREATE INDEX IF NOT EXISTS leads_status_score_idx   ON acq.leads (status, lead_score DESC, created_at);
CREATE INDEX IF NOT EXISTS leads_market_city_idx    ON acq.leads (market_id, city, area);
CREATE INDEX IF NOT EXISTS leads_next_follow_up_idx ON acq.leads (next_follow_up_at) WHERE next_follow_up_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS leads_domain_idx         ON acq.leads (domain) WHERE domain IS NOT NULL;
CREATE INDEX IF NOT EXISTS leads_email_idx          ON acq.leads (public_email) WHERE public_email IS NOT NULL;
CREATE INDEX IF NOT EXISTS leads_name_trgm_idx      ON acq.leads USING gin (normalized_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS leads_locked_idx         ON acq.leads (locked_at) WHERE locked_by IS NOT NULL;

-- Deduplication index. One row per (key_type, key_value) across the whole
-- system, so a business discovered from OSM and again from Google Places
-- collapses onto a single lead instead of being contacted twice.
CREATE TABLE IF NOT EXISTS acq.lead_identity_keys (
  id         bigserial PRIMARY KEY,
  lead_id    uuid NOT NULL REFERENCES acq.leads(id) ON DELETE CASCADE,
  key_type   acq.identity_key_type NOT NULL,
  key_value  text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lead_identity_keys_unique UNIQUE (key_type, key_value)
);

CREATE INDEX IF NOT EXISTS lead_identity_keys_lead_idx ON acq.lead_identity_keys (lead_id);

CREATE TABLE IF NOT EXISTS acq.lead_contacts (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id             uuid NOT NULL REFERENCES acq.leads(id) ON DELETE CASCADE,
  contact_type        acq.contact_type NOT NULL,
  value               text NOT NULL,
  normalized_value    text NOT NULL,
  label               text,                       -- 'reception', 'appointments'
  is_primary          boolean NOT NULL DEFAULT false,
  verification_status acq.verification_status NOT NULL DEFAULT 'UNVERIFIED',
  source              acq.contact_source NOT NULL,
  source_url          text NOT NULL,              -- citable evidence, always
  verified_at         timestamptz,
  discovered_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lead_contacts_unique UNIQUE (lead_id, contact_type, normalized_value)
);

CREATE INDEX IF NOT EXISTS lead_contacts_lead_idx  ON acq.lead_contacts (lead_id);
CREATE INDEX IF NOT EXISTS lead_contacts_value_idx ON acq.lead_contacts (contact_type, normalized_value);

-- Cached AI research. `stale_after` prevents re-spending tokens on a clinic
-- that was already researched (section 19 of the brief).
CREATE TABLE IF NOT EXISTS acq.lead_research (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id               uuid NOT NULL REFERENCES acq.leads(id) ON DELETE CASCADE,
  is_current            boolean NOT NULL DEFAULT true,
  clinic_type           text,
  facts                 jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{claim, evidence_url}]
  inferences            jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{claim, basis, confidence}]
  services              jsonb NOT NULL DEFAULT '[]'::jsonb,
  doctor_count_estimate int,
  has_whatsapp          boolean,
  has_online_booking    boolean,
  has_visible_reception boolean,
  pain_point            text,
  recommended_pitch     text,
  relevance_reason      text,
  confidence            numeric(4,3),
  model                 text,
  prompt_version        text,
  fetched_urls          text[] NOT NULL DEFAULT '{}',
  robots_allowed        boolean,
  raw                   jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  stale_after           timestamptz NOT NULL DEFAULT (now() + interval '90 days'),
  CONSTRAINT lead_research_confidence CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1)
);

CREATE UNIQUE INDEX IF NOT EXISTS lead_research_one_current
  ON acq.lead_research (lead_id) WHERE is_current;
CREATE INDEX IF NOT EXISTS lead_research_stale_idx ON acq.lead_research (stale_after) WHERE is_current;

CREATE TABLE IF NOT EXISTS acq.lead_scores (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id         uuid NOT NULL REFERENCES acq.leads(id) ON DELETE CASCADE,
  score           int NOT NULL,
  breakdown       jsonb NOT NULL DEFAULT '{}'::jsonb,
  scorer          text NOT NULL,          -- DETERMINISTIC | AI | BLENDED
  scoring_version text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS lead_scores_lead_idx ON acq.lead_scores (lead_id, created_at DESC);

-- ---------------------------------------------------------------------
-- Campaigns and sequences
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.campaigns (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                 text NOT NULL UNIQUE,
  name                text NOT NULL,
  market_id           uuid NOT NULL REFERENCES acq.markets(id),
  mailbox_id          uuid NOT NULL REFERENCES acq.mailboxes(id),
  status              text NOT NULL DEFAULT 'ACTIVE',   -- ACTIVE | PAUSED | ARCHIVED
  daily_send_limit    int NOT NULL DEFAULT 20,
  hourly_send_limit   int NOT NULL DEFAULT 6,
  per_domain_limit    int NOT NULL DEFAULT 1,   -- max emails to one domain at once
  per_campaign_limit  int,                      -- lifetime cap, NULL = unlimited
  max_follow_ups      int NOT NULL DEFAULT 3,
  min_score_to_send   int NOT NULL DEFAULT 55,
  sending_window_start time NOT NULL DEFAULT '09:30',
  sending_window_end   time NOT NULL DEFAULT '17:00',
  sending_days        int[] NOT NULL DEFAULT ARRAY[1,2,3,4,5],  -- ISO dow, 1=Mon
  timezone            text NOT NULL DEFAULT 'Asia/Karachi',
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaigns_followups_bounded CHECK (max_follow_ups BETWEEN 0 AND 5)
);

CREATE TABLE IF NOT EXISTS acq.sequence_steps (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id     uuid NOT NULL REFERENCES acq.campaigns(id) ON DELETE CASCADE,
  step_no         int NOT NULL,             -- 0 = initial email
  kind            text NOT NULL,            -- INITIAL | FOLLOW_UP | BREAKUP
  min_delay_days  int NOT NULL DEFAULT 4,
  max_delay_days  int NOT NULL DEFAULT 6,
  prompt_key      text NOT NULL,
  enabled         boolean NOT NULL DEFAULT true,
  CONSTRAINT sequence_steps_unique UNIQUE (campaign_id, step_no),
  CONSTRAINT sequence_steps_delay_sane CHECK (max_delay_days >= min_delay_days)
);

-- ---------------------------------------------------------------------
-- Outbound email
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.emails (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id                uuid NOT NULL REFERENCES acq.leads(id) ON DELETE CASCADE,
  campaign_id            uuid NOT NULL REFERENCES acq.campaigns(id),
  mailbox_id             uuid NOT NULL REFERENCES acq.mailboxes(id),
  step_no                int NOT NULL DEFAULT 0,

  to_email               citext NOT NULL,
  subject                text NOT NULL,
  body_text              text NOT NULL,
  body_html              text,

  personalization_reason text,
  suggested_feature      text,
  ai_confidence          numeric(4,3),
  model                  text,
  prompt_version         text,

  status                 acq.email_status NOT NULL DEFAULT 'DRAFT',

  message_id             text,      -- RFC 5322 Message-ID we generated
  in_reply_to            text,
  thread_key             text,
  unsubscribe_token      text NOT NULL DEFAULT encode(gen_random_bytes(18), 'hex'),

  guardrail_report       jsonb NOT NULL DEFAULT '{}'::jsonb,
  approved_by            text,
  approved_at            timestamptz,

  scheduled_for          timestamptz,
  queued_at              timestamptz,
  sent_at                timestamptz,
  failed_at              timestamptz,
  attempts               int NOT NULL DEFAULT 0,
  error                  text,

  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),

  -- Idempotency: one email per lead per campaign per sequence step. A retried
  -- or duplicated workflow execution cannot produce a second send.
  CONSTRAINT emails_idempotent UNIQUE (lead_id, campaign_id, step_no),
  CONSTRAINT emails_confidence CHECK (ai_confidence IS NULL OR ai_confidence BETWEEN 0 AND 1)
);

CREATE UNIQUE INDEX IF NOT EXISTS emails_message_id_idx ON acq.emails (message_id) WHERE message_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS emails_unsub_token_idx ON acq.emails (unsubscribe_token);
CREATE INDEX IF NOT EXISTS emails_sendable_idx  ON acq.emails (status, scheduled_for)
  WHERE status IN ('READY_TO_SEND','QUEUED');
CREATE INDEX IF NOT EXISTS emails_lead_idx      ON acq.emails (lead_id, created_at DESC);
CREATE INDEX IF NOT EXISTS emails_thread_idx    ON acq.emails (thread_key) WHERE thread_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS acq.email_events (
  id                bigserial PRIMARY KEY,
  email_id          uuid REFERENCES acq.emails(id) ON DELETE CASCADE,
  lead_id           uuid REFERENCES acq.leads(id) ON DELETE CASCADE,
  event             acq.email_event_type NOT NULL,
  occurred_at       timestamptz NOT NULL DEFAULT now(),
  provider          text,
  provider_event_id text,          -- dedupe key for provider webhooks
  detail            text,
  payload           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS email_events_provider_dedupe
  ON acq.email_events (provider, provider_event_id)
  WHERE provider_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS email_events_email_idx ON acq.email_events (email_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS email_events_type_idx  ON acq.email_events (event, occurred_at DESC);

-- Atomic send-rate accounting. Limits are enforced here rather than inside
-- n8n, because overlapping or retried executions would otherwise each believe
-- they are within budget.
CREATE TABLE IF NOT EXISTS acq.send_counters (
  mailbox_id  uuid NOT NULL REFERENCES acq.mailboxes(id) ON DELETE CASCADE,
  bucket_date date NOT NULL,
  bucket_hour smallint NOT NULL,     -- 0-23, or -1 for the daily rollup
  sent_count  int NOT NULL DEFAULT 0,
  PRIMARY KEY (mailbox_id, bucket_date, bucket_hour),
  CONSTRAINT send_counters_hour_range CHECK (bucket_hour BETWEEN -1 AND 23)
);

-- ---------------------------------------------------------------------
-- Inbound: replies and classification
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.replies (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id       uuid REFERENCES acq.leads(id) ON DELETE SET NULL,
  email_id      uuid REFERENCES acq.emails(id) ON DELETE SET NULL,
  message_id    text NOT NULL,
  in_reply_to   text,
  references_hdr text,
  from_email    citext NOT NULL,
  from_name     text,
  subject       text,
  body_text     text,
  body_html     text,
  headers       jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_auto_reply boolean NOT NULL DEFAULT false,
  is_bounce     boolean NOT NULL DEFAULT false,
  matched_by    text,       -- IN_REPLY_TO | REFERENCES | FROM_EMAIL | UNMATCHED
  received_at   timestamptz NOT NULL DEFAULT now(),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT replies_message_id_unique UNIQUE (message_id)
);

CREATE INDEX IF NOT EXISTS replies_lead_idx ON acq.replies (lead_id, received_at DESC);

CREATE TABLE IF NOT EXISTS acq.reply_classifications (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reply_id            uuid NOT NULL REFERENCES acq.replies(id) ON DELETE CASCADE,
  class               acq.reply_class NOT NULL,
  confidence          numeric(4,3) NOT NULL,
  reasoning           text,
  extracted_questions jsonb NOT NULL DEFAULT '[]'::jsonb,
  suggested_reply     text,
  requires_human      boolean NOT NULL DEFAULT true,
  escalation_reason   text,
  model               text,
  prompt_version      text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reply_classifications_unique UNIQUE (reply_id),
  CONSTRAINT reply_classifications_conf CHECK (confidence BETWEEN 0 AND 1)
);

-- ---------------------------------------------------------------------
-- Follow-ups
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.follow_ups (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id          uuid NOT NULL REFERENCES acq.leads(id) ON DELETE CASCADE,
  campaign_id      uuid NOT NULL REFERENCES acq.campaigns(id) ON DELETE CASCADE,
  step_no          int NOT NULL,
  due_at           timestamptz NOT NULL,
  status           acq.followup_status NOT NULL DEFAULT 'SCHEDULED',
  cancelled_reason text,
  email_id         uuid REFERENCES acq.emails(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT follow_ups_unique UNIQUE (lead_id, campaign_id, step_no)
);

CREATE INDEX IF NOT EXISTS follow_ups_due_idx ON acq.follow_ups (due_at) WHERE status = 'SCHEDULED';

-- ---------------------------------------------------------------------
-- Suppression (opt-outs, bounces, complaints) — one table, one lookup
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.opt_outs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope            acq.suppression_scope NOT NULL,
  value            text NOT NULL,
  normalized_value text NOT NULL,
  reason           acq.suppression_reason NOT NULL,
  source           text NOT NULL,      -- REPLY | WEBHOOK | MANUAL | BOUNCE | LIST_UNSUB
  lead_id          uuid REFERENCES acq.leads(id) ON DELETE SET NULL,
  evidence         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT opt_outs_unique UNIQUE (scope, normalized_value)
);

CREATE INDEX IF NOT EXISTS opt_outs_lookup_idx ON acq.opt_outs (normalized_value);

-- ---------------------------------------------------------------------
-- Human-in-the-loop and activity trail
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.approvals (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind           acq.approval_kind NOT NULL,
  status         acq.approval_status NOT NULL DEFAULT 'PENDING',
  lead_id        uuid REFERENCES acq.leads(id) ON DELETE CASCADE,
  email_id       uuid REFERENCES acq.emails(id) ON DELETE CASCADE,
  reply_id       uuid REFERENCES acq.replies(id) ON DELETE CASCADE,
  title          text NOT NULL,
  payload        jsonb NOT NULL DEFAULT '{}'::jsonb,
  ai_confidence  numeric(4,3),
  requested_at   timestamptz NOT NULL DEFAULT now(),
  decided_at     timestamptz,
  decided_by     text,
  decision_note  text,
  edited_payload jsonb,
  expires_at     timestamptz NOT NULL DEFAULT (now() + interval '14 days')
);

CREATE INDEX IF NOT EXISTS approvals_pending_idx ON acq.approvals (status, requested_at)
  WHERE status = 'PENDING';

CREATE TABLE IF NOT EXISTS acq.sales_activities (
  id            bigserial PRIMARY KEY,
  lead_id       uuid REFERENCES acq.leads(id) ON DELETE CASCADE,
  activity_type text NOT NULL,
  actor         acq.actor NOT NULL DEFAULT 'SYSTEM',
  summary       text NOT NULL,
  payload       jsonb NOT NULL DEFAULT '{}'::jsonb,
  execution_id  text,
  occurred_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sales_activities_lead_idx ON acq.sales_activities (lead_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS sales_activities_type_idx ON acq.sales_activities (activity_type, occurred_at DESC);

CREATE TABLE IF NOT EXISTS acq.notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel     text NOT NULL,      -- TELEGRAM | EMAIL | WEBHOOK
  target      text NOT NULL,
  subject     text,
  body        text NOT NULL,
  lead_id     uuid REFERENCES acq.leads(id) ON DELETE SET NULL,
  dedupe_key  text NOT NULL,
  status      text NOT NULL DEFAULT 'PENDING',
  error       text,
  sent_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notifications_dedupe UNIQUE (dedupe_key)
);

-- ---------------------------------------------------------------------
-- Demo booking
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.demo_bookings (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id           uuid REFERENCES acq.leads(id) ON DELETE SET NULL,
  provider          text NOT NULL,          -- CAL_COM | CALENDLY | GOOGLE
  provider_event_id text NOT NULL,
  invitee_email     citext,
  invitee_name      text,
  scheduled_at      timestamptz,
  duration_min      int,
  join_url          text,
  status            text NOT NULL DEFAULT 'BOOKED',  -- BOOKED|RESCHEDULED|CANCELLED|COMPLETED|NO_SHOW
  payload           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT demo_bookings_provider_unique UNIQUE (provider, provider_event_id)
);

-- ---------------------------------------------------------------------
-- Observability: AI spend, workflow runs, dead letters
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.ai_calls (
  id             bigserial PRIMARY KEY,
  purpose        text NOT NULL,    -- RESEARCH | PERSONALIZE | CLASSIFY | FOLLOWUP
  model          text NOT NULL,
  lead_id        uuid REFERENCES acq.leads(id) ON DELETE SET NULL,
  prompt_version text,
  input_tokens   int,
  output_tokens  int,
  cost_usd       numeric(10,6),
  latency_ms     int,
  ok             boolean NOT NULL DEFAULT true,
  error          text,
  execution_id   text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ai_calls_created_idx ON acq.ai_calls (created_at DESC);
CREATE INDEX IF NOT EXISTS ai_calls_purpose_idx ON acq.ai_calls (purpose, created_at DESC);

CREATE TABLE IF NOT EXISTS acq.workflow_runs (
  id           bigserial PRIMARY KEY,
  workflow_key text NOT NULL,
  execution_id text,
  status       text NOT NULL DEFAULT 'RUNNING',   -- RUNNING|SUCCESS|ERROR
  items_in     int,
  items_out    int,
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  error        text,
  meta         jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS workflow_runs_key_idx ON acq.workflow_runs (workflow_key, started_at DESC);

-- Nothing is ever silently lost: any failure that cannot be retried lands here.
CREATE TABLE IF NOT EXISTS acq.dead_letters (
  id           bigserial PRIMARY KEY,
  workflow_key text NOT NULL,
  execution_id text,
  node_name    text,
  lead_id      uuid REFERENCES acq.leads(id) ON DELETE SET NULL,
  email_id     uuid REFERENCES acq.emails(id) ON DELETE SET NULL,
  error        text NOT NULL,
  payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
  retry_count  int NOT NULL DEFAULT 0,
  resolved_at  timestamptz,
  resolved_by  text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS dead_letters_open_idx ON acq.dead_letters (created_at DESC)
  WHERE resolved_at IS NULL;

-- ---------------------------------------------------------------------
-- State machine definition (data, not code)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acq.status_transitions (
  from_status acq.lead_status NOT NULL,
  to_status   acq.lead_status NOT NULL,
  PRIMARY KEY (from_status, to_status)
);

COMMENT ON TABLE acq.status_transitions IS
  'Allowed lead status transitions. acq.transition_lead() rejects anything not listed here.';
