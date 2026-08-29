-- =====================================================================
-- Migration 006: prompt registry
--
-- Prompts live in the database, not inside n8n nodes. Editing a prompt then
-- means one UPDATE (or one re-run of scripts/load_prompts.py) instead of
-- exporting, editing and re-importing a workflow. Every generated artefact
-- already records the prompt_version that produced it, so a regression can be
-- traced to the exact prompt text that caused it.
--
-- Source of truth is prompts/*.md in this repository. This table is a
-- deployment target, not a place to hand-edit.
-- =====================================================================

SET search_path = acq, public;

CREATE TABLE IF NOT EXISTS acq.prompts (
  key             text NOT NULL,
  version         text NOT NULL,
  purpose         text NOT NULL,
  system_prompt   text NOT NULL,
  user_template   text NOT NULL,
  response_schema jsonb NOT NULL,
  temperature     numeric(3,2) NOT NULL DEFAULT 0.20,
  active          boolean NOT NULL DEFAULT false,
  notes           text,
  source_file     text,
  loaded_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (key, version),
  CONSTRAINT prompts_temperature_range CHECK (temperature BETWEEN 0 AND 2)
);

-- Exactly one active version per prompt key.
CREATE UNIQUE INDEX IF NOT EXISTS prompts_one_active_per_key
  ON acq.prompts (key) WHERE active;

-- Returns everything an AI request needs, in one round trip.
CREATE OR REPLACE FUNCTION acq.get_prompt(p_key text)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'key',             p.key,
    'version',         p.version,
    'purpose',         p.purpose,
    'system_prompt',   p.system_prompt,
    'user_template',   p.user_template,
    'response_schema', p.response_schema,
    'temperature',     p.temperature
  )
  FROM acq.prompts p
  WHERE p.key = p_key AND p.active;
$fn$;

-- ---------------------------------------------------------------------
-- The claim whitelist.
--
-- This is the ONLY set of statements any prompt may make about the product.
-- It is injected into every generation prompt as {{capabilities}}. Anything
-- not on this list cannot be said in an email, which is what stops the model
-- inventing integrations, certifications or results.
--
-- PRUNE THIS BEFORE SENDING ANYTHING. Remove every line that is not shipped
-- and working today. A capability listed here WILL be claimed to real clinics.
-- ---------------------------------------------------------------------
INSERT INTO acq.settings (key, value, description) VALUES
('product.capabilities',
 '[
   "Answers patient messages on WhatsApp 24/7",
   "Understands natural-language patient messages",
   "Books appointments",
   "Checks doctor and service availability",
   "Handles cancellations",
   "Handles rescheduling",
   "Sends appointment confirmations",
   "Sends appointment reminders",
   "Answers common clinic questions",
   "Supports multiple doctors and services",
   "Reads prescription images",
   "Can collect an appointment fee before confirming a booking",
   "Connects to clinic scheduling and calendar systems",
   "Provides a clinic dashboard",
   "Reduces routine receptionist workload"
 ]'::jsonb,
 'CLAIM WHITELIST. The only statements the AI may make about Clinibot. Remove any line not shipped and working today — everything here will be asserted to real clinics.'),

('product.capabilities_unverified',
 '["Connects to clinic scheduling and calendar systems",
   "Can collect an appointment fee before confirming a booking",
   "Reads prescription images"]'::jsonb,
 'Capabilities flagged as "potentially" available in the original brief. Confirm each is live, or delete it from product.capabilities before the first send.')
ON CONFLICT (key) DO NOTHING;

-- Token rates used by workflow 01 to cost every AI call. Verify against
-- ai.google.dev/pricing before relying on the numbers: model pricing changes,
-- and a stale rate here produces a confidently wrong cost report.
INSERT INTO acq.settings (key, value, description) VALUES
('ai.pricing',
 '{
    "gemini-2.5-flash":      { "input_per_1m": 0.30, "output_per_1m": 2.50 },
    "gemini-2.5-flash-lite": { "input_per_1m": 0.10, "output_per_1m": 0.40 },
    "gemini-2.0-flash":      { "input_per_1m": 0.10, "output_per_1m": 0.40 },
    "gemini-2.5-pro":        { "input_per_1m": 1.25, "output_per_1m": 10.00 }
  }'::jsonb,
 'USD per million tokens, per model. VERIFY against current published pricing — these are indicative only.')
ON CONFLICT (key) DO NOTHING;
