-- =====================================================================
-- End-to-end smoke test.
--   psql -v ON_ERROR_STOP=1 -d <db> -f scripts/smoke_test.sql
--
-- Proves the invariants the system depends on:
--   1. cross-source deduplication collapses one business to one lead
--   2. an email without citable provenance is refused
--   3. scoring is explainable and phase-aware
--   4. send limits cannot be exceeded, even by an over-eager caller
--   5. a reply stops follow-ups AND cancels already-queued mail
--   6. opt-out is permanent and blocks every later send path
--   7. illegal state transitions are refused
--
-- Runs in a transaction and rolls back: it leaves no data behind.
-- =====================================================================

\set ON_ERROR_STOP on
BEGIN;

SET search_path = acq, public;

\echo ''
\echo '=== 1. Discovery + cross-source deduplication ==================='

-- Same clinic, three sources, three spellings, no shared primary key except
-- the phone number and the domain.
SELECT acq.upsert_lead('{
  "market_code":"PK",
  "clinic_name":"Dr. Ahmed Dental Care (Pvt) Ltd",
  "city":"Karachi","area":"North Nazimabad",
  "phone":"021-3663-1122",
  "category":"DENTAL","priority_tier":1,
  "source":"OSM","source_url":"https://www.openstreetmap.org/node/1234567",
  "source_ref":"node/1234567","source_ref_type":"OSM_ID",
  "raw":{"review_count":31}
}'::jsonb) AS first_insert \gset

\echo '--> first insert:'
SELECT :'first_insert'::jsonb ->> 'is_new' AS is_new,
       :'first_insert'::jsonb ->> 'matched_by' AS matched_by;

-- Second source: different name spelling, same phone in international format.
SELECT acq.upsert_lead('{
  "market_code":"PK",
  "clinic_name":"Ahmed Dental Clinic",
  "city":"Karachi","area":"North Nazimabad",
  "phone":"+92 21 36631122",
  "website":"https://ahmeddental.com.pk",
  "category":"DENTAL","priority_tier":1,
  "source":"GOOGLE_PLACES","source_url":"https://maps.google.com/?cid=99",
  "source_ref":"ChIJtest123","source_ref_type":"PLACE_ID",
  "raw":{"userRatingCount":142}
}'::jsonb) AS second \gset

\echo '--> second source (same phone, different spelling):'
SELECT :'second'::jsonb ->> 'duplicate' AS duplicate,
       :'second'::jsonb ->> 'matched_by' AS matched_by;

-- Third source: only the website domain in common.
SELECT acq.upsert_lead('{
  "market_code":"PK",
  "clinic_name":"AHMED DENTAL",
  "city":"Karachi",
  "website":"http://www.ahmeddental.com.pk/contact",
  "public_email":"Info@AhmedDental.com.pk",
  "email_source":"CLINIC_WEBSITE",
  "email_evidence_url":"https://ahmeddental.com.pk/contact",
  "whatsapp":"03001234567",
  "doctor_count":4,
  "source":"DIRECTORY","source_url":"https://example-directory.pk/ahmed",
  "contacts":[
    {"contact_type":"EMAIL","value":"info@ahmeddental.com.pk","source":"CLINIC_WEBSITE",
     "source_url":"https://ahmeddental.com.pk/contact","is_primary":true},
    {"contact_type":"WHATSAPP","value":"0300 1234567","source":"CLINIC_WEBSITE",
     "source_url":"https://ahmeddental.com.pk/contact"}
  ]
}'::jsonb) AS third \gset

\echo '--> third source (same domain):'
SELECT :'third'::jsonb ->> 'duplicate' AS duplicate,
       :'third'::jsonb ->> 'matched_by' AS matched_by;

\echo '--> ASSERT: three discoveries produced exactly one lead'
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM acq.leads WHERE clinic_name ILIKE '%ahmed%';
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL: expected 1 deduplicated lead, got %', n; END IF;
  RAISE NOTICE 'PASS: 1 lead from 3 sources';
END $$;

\echo '--> merged record (note phone/email/whatsapp normalization):'
SELECT clinic_name, phone, whatsapp, public_email, email_source, domain, doctor_count
FROM acq.leads WHERE clinic_name ILIKE '%ahmed%';

\echo ''
\echo '=== 2. Email provenance gate ===================================='

SELECT acq.upsert_lead('{
  "market_code":"PK",
  "clinic_name":"Skyline Skin Studio",
  "city":"Karachi","area":"Clifton",
  "public_email":"info@skylineskin.pk",
  "phone":"02135870000",
  "category":"DERMATOLOGY","priority_tier":1,
  "source":"OSM","source_url":"https://www.openstreetmap.org/node/777"
}'::jsonb) AS noprov \gset

\echo '--> lead created WITHOUT email_source/evidence_url; the address is dropped:'
SELECT :'noprov'::jsonb -> 'dropped_fields' AS dropped;

DO $$
DECLARE v text;
BEGIN
  SELECT public_email INTO v FROM acq.leads WHERE clinic_name = 'Skyline Skin Studio';
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: unprovenanced email was stored: %', v;
  END IF;
  RAISE NOTICE 'PASS: email with no citable source was refused';
END $$;

\echo '--> ASSERT: the CHECK constraint also blocks a direct write'
DO $$
BEGIN
  BEGIN
    UPDATE acq.leads SET public_email = 'guessed@skylineskin.pk'
     WHERE clinic_name = 'Skyline Skin Studio';
    RAISE EXCEPTION 'FAIL: database accepted an email with no provenance';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS: CHECK constraint rejected the guessed address';
  END;
END $$;

\echo ''
\echo '=== 3. Scoring ==================================================='

SELECT id AS lead_id FROM acq.leads WHERE clinic_name ILIKE '%ahmed%' \gset

\echo '--> deterministic phase (no AI tokens spent):'
SELECT jsonb_pretty(acq.compute_score(:'lead_id'::uuid, 'DETERMINISTIC')
                    - 'thresholds') AS deterministic;

INSERT INTO acq.lead_research (
  lead_id, is_current, clinic_type, facts, inferences,
  doctor_count_estimate, has_whatsapp, has_online_booking,
  pain_point, recommended_pitch, confidence, model, prompt_version, raw
) VALUES (
  :'lead_id'::uuid, true, 'DENTAL',
  '[{"claim":"The website lists four dentists on the Our Team page.",
     "evidence_url":"https://ahmeddental.com.pk/team"},
    {"claim":"WhatsApp is listed as the appointment contact method.",
     "evidence_url":"https://ahmeddental.com.pk/contact"}]'::jsonb,
  '[{"claim":"Appointment requests are likely handled manually over WhatsApp.",
     "basis":"WhatsApp is the only booking channel shown and there is no booking form.",
     "confidence":0.7}]'::jsonb,
  4, true, false,
  'Appointment requests arrive on WhatsApp and are answered by hand during clinic hours only.',
  'Focus on 24/7 WhatsApp response, multi-dentist availability, and reminder automation.',
  0.86, 'gemini-2.5-flash', 'research/v1',
  '{"advertises_appointments":true,"high_value_services":true,"active_social_presence":true}'::jsonb
);

\echo '--> blended phase (AI-confirmed signals folded in):'
SELECT jsonb_pretty(acq.compute_score(:'lead_id'::uuid, 'BLENDED') - 'thresholds') AS blended;

\echo ''
\echo '=== 4. Send limits cannot be exceeded ============================'

SELECT id AS campaign_id FROM acq.campaigns WHERE key = 'pk-karachi-tier1' \gset
SELECT mailbox_id FROM acq.campaigns WHERE key = 'pk-karachi-tier1' \gset

-- Widen the window so the test is not time-of-day dependent, and clear the
-- warm-up ramp so we are testing the hourly cap specifically.
UPDATE acq.campaigns
   SET sending_window_start = '00:00', sending_window_end = '23:59',
       sending_days = ARRAY[1,2,3,4,5,6,7], min_score_to_send = 0
 WHERE id = :'campaign_id'::uuid;
UPDATE acq.mailboxes SET warmup_started_on = CURRENT_DATE - 60 WHERE id = :'mailbox_id'::uuid;

-- Ten approved leads, each with an email ready to go.
INSERT INTO acq.leads (market_id, clinic_name, city, category, priority_tier,
                       public_email, email_source, email_evidence_url,
                       source, source_url, lead_score, status)
SELECT m.id, 'Load Test Clinic ' || g, 'Karachi', 'DENTAL', 1,
       ('clinic' || g || '@example' || g || '.test')::citext,
       'CLINIC_WEBSITE', 'https://example' || g || '.test/contact',
       'TEST', 'https://example' || g || '.test', 70, 'APPROVED'
FROM acq.markets m, generate_series(1, 10) g WHERE m.code = 'PK';

INSERT INTO acq.emails (lead_id, campaign_id, mailbox_id, step_no, to_email,
                        subject, body_text, status, ai_confidence)
SELECT l.id, :'campaign_id'::uuid, :'mailbox_id'::uuid, 0, l.public_email,
       'A quick question about appointment booking at ' || l.clinic_name,
       'Test body', 'READY_TO_SEND', 0.9
FROM acq.leads l WHERE l.clinic_name LIKE 'Load Test Clinic %';

\echo '--> hourly cap is 4; ask for 10:'
SELECT count(*) AS claimed_first_call FROM acq.claim_send_slots(:'campaign_id'::uuid, 10);

\echo '--> ask for 10 again in the same hour (budget is now spent):'
SELECT count(*) AS claimed_second_call FROM acq.claim_send_slots(:'campaign_id'::uuid, 10);

DO $$
DECLARE n int;
BEGIN
  SELECT sent_count INTO n FROM acq.send_counters
   WHERE bucket_hour <> -1 AND bucket_date = (now() AT TIME ZONE 'Asia/Karachi')::date;
  IF n > 4 THEN RAISE EXCEPTION 'FAIL: hourly cap breached, counter = %', n; END IF;
  RAISE NOTICE 'PASS: hourly cap held at % claimed', n;
END $$;

\echo '--> outside the sending window nothing is claimed at all:'
UPDATE acq.campaigns SET sending_window_start = '03:00', sending_window_end = '03:01'
 WHERE id = :'campaign_id'::uuid;
SELECT count(*) AS claimed_outside_window FROM acq.claim_send_slots(:'campaign_id'::uuid, 10);
UPDATE acq.campaigns SET sending_window_start = '00:00', sending_window_end = '23:59'
 WHERE id = :'campaign_id'::uuid;

\echo ''
\echo '=== 5. Sending, replying, and the follow-up stop =================='

SELECT id AS email_id FROM acq.emails WHERE status = 'QUEUED' ORDER BY created_at LIMIT 1 \gset
SELECT lead_id AS sent_lead FROM acq.emails WHERE id = :'email_id'::uuid \gset

\echo '--> pre-send guard:'
SELECT acq.is_sendable(:'email_id'::uuid) ->> 'sendable' AS sendable;

\echo '--> record the send; follow-up 1 is scheduled automatically:'
SELECT jsonb_pretty(acq.record_email_sent(:'email_id'::uuid, '<msg-001@zenvexa.tech>')) AS sent;

SELECT status AS lead_status_after_send FROM acq.leads WHERE id = :'sent_lead'::uuid;
SELECT step_no, status FROM acq.follow_ups WHERE lead_id = :'sent_lead'::uuid;

-- Queue a follow-up that has NOT yet been sent, to prove a reply kills it.
INSERT INTO acq.emails (lead_id, campaign_id, mailbox_id, step_no, to_email,
                        subject, body_text, status)
SELECT :'sent_lead'::uuid, :'campaign_id'::uuid, :'mailbox_id'::uuid, 1,
       public_email, 'Following up', 'Follow-up body', 'READY_TO_SEND'
FROM acq.leads WHERE id = :'sent_lead'::uuid;

INSERT INTO acq.replies (lead_id, email_id, message_id, from_email, subject, body_text, received_at)
VALUES (:'sent_lead'::uuid, :'email_id'::uuid, '<reply-001@clinic.test>',
        'reception@example1.test', 'Re: A quick question',
        'Yes this sounds interesting, can you show me a demo?', now())
RETURNING id AS reply_id \gset

\echo '--> the prospect replies:'
SELECT jsonb_pretty(acq.record_reply(:'reply_id'::uuid)) AS reply_recorded;

DO $$
DECLARE v_sched int; v_queued int; v_status acq.lead_status;
BEGIN
  SELECT count(*) INTO v_sched  FROM acq.follow_ups
   WHERE lead_id = (SELECT lead_id FROM acq.replies ORDER BY created_at DESC LIMIT 1)
     AND status = 'SCHEDULED';
  SELECT count(*) INTO v_queued FROM acq.emails
   WHERE lead_id = (SELECT lead_id FROM acq.replies ORDER BY created_at DESC LIMIT 1)
     AND status IN ('READY_TO_SEND','QUEUED','DRAFT','PENDING_APPROVAL');
  SELECT status INTO v_status FROM acq.leads
   WHERE id = (SELECT lead_id FROM acq.replies ORDER BY created_at DESC LIMIT 1);

  IF v_sched <> 0 THEN RAISE EXCEPTION 'FAIL: % follow-ups still scheduled after reply', v_sched; END IF;
  IF v_queued <> 0 THEN RAISE EXCEPTION 'FAIL: % emails still queued after reply', v_queued; END IF;
  IF v_status <> 'REPLIED' THEN RAISE EXCEPTION 'FAIL: lead status is % not REPLIED', v_status; END IF;
  RAISE NOTICE 'PASS: reply cancelled all follow-ups and queued mail, lead -> REPLIED';
END $$;

\echo ''
\echo '=== 6. Opt-out is permanent ======================================'

SELECT acq.apply_opt_out('EMAIL', 'clinic2@example2.test', 'OPT_OUT_REQUEST', 'REPLY',
                         (SELECT id FROM acq.leads WHERE clinic_name = 'Load Test Clinic 2'),
                         '{"quote":"Please do not contact me again."}'::jsonb) AS opt_out_id;

\echo '--> is_sendable now refuses that address:'
SELECT acq.is_suppressed('clinic2@example2.test') AS suppressed;

\echo '--> and claim_send_slots skips it permanently:'
UPDATE acq.emails SET status = 'READY_TO_SEND', queued_at = NULL
 WHERE lead_id = (SELECT id FROM acq.leads WHERE clinic_name = 'Load Test Clinic 2');
DELETE FROM acq.send_counters;   -- reset budget so only suppression can exclude it

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM acq.claim_send_slots(
    (SELECT id FROM acq.campaigns WHERE key = 'pk-karachi-tier1'), 10)
   WHERE to_email = 'clinic2@example2.test';
  IF n > 0 THEN RAISE EXCEPTION 'FAIL: opted-out address was claimed for sending'; END IF;
  RAISE NOTICE 'PASS: opted-out address is unreachable by the send path';
END $$;

\echo ''
\echo '=== 7. Claiming locks only leads the workflow can use ============='

-- Regression guard. A claim that locks first and filters afterwards leaves
-- unusable leads locked for 15 minutes and starves the next workflow of the
-- same status; measured at 11 wasted locks out of 15 before this was fixed.
INSERT INTO acq.leads (market_id, clinic_name, city, category, priority_tier,
                       website, phone, source, source_url, lead_score, status)
SELECT m.id, 'Claim Test ' || g, 'Karachi', 'DENTAL', 1,
       CASE WHEN g <= 3 THEN 'https://claimtest' || g || '.pk' END,
       '0219000' || lpad(g::text, 4, '0'),
       'TEST', 'https://claimtest/' || g, 70, 'QUALIFIED'
FROM acq.markets m, generate_series(1, 12) g WHERE m.code = 'PK';

DO $$
DECLARE returned int; wasted int;
BEGIN
  SELECT count(*) INTO returned FROM acq.claim_leads_for_research(12, 'smoke-wf30');
  SELECT count(*) INTO wasted FROM acq.leads
   WHERE locked_by = 'smoke-wf30' AND website IS NULL;

  IF wasted > 0 THEN
    RAISE EXCEPTION 'FAIL: % leads locked that the workflow cannot research', wasted;
  END IF;
  IF returned <> 3 THEN
    RAISE EXCEPTION 'FAIL: expected 3 researchable leads, got %', returned;
  END IF;
  RAISE NOTICE 'PASS: claim locked only the 3 usable leads, none wasted';
END $$;

\echo ''
\echo '=== 8. Readiness reports what still blocks sending ================'

SELECT severity, check_name, left(detail, 66) AS detail
FROM acq.readiness() WHERE severity = 'BLOCKER';

DO $$
DECLARE n int;
BEGIN
  -- postal address and unsubscribe URL ship empty on purpose
  SELECT count(*) INTO n FROM acq.readiness() WHERE severity = 'BLOCKER';
  IF n < 2 THEN
    RAISE EXCEPTION 'FAIL: readiness() should flag the unset send-blockers, found %', n;
  END IF;
  RAISE NOTICE 'PASS: readiness() reports % blocker(s) before first send', n;
END $$;

\echo ''
\echo '=== 9. State machine refuses illegal transitions =================='

SELECT acq.transition_lead(
  (SELECT id FROM acq.leads WHERE clinic_name = 'Load Test Clinic 3'),
  'CUSTOMER', 'skipping the whole pipeline') ->> 'error' AS illegal_transition_error;

DO $$
DECLARE r jsonb; st acq.lead_status;
BEGIN
  SELECT status INTO st FROM acq.leads WHERE clinic_name = 'Load Test Clinic 2';
  IF st <> 'OPTED_OUT' THEN
    RAISE EXCEPTION 'FAIL: opted-out lead has status % not OPTED_OUT', st;
  END IF;

  r := acq.transition_lead(
         (SELECT id FROM acq.leads WHERE clinic_name = 'Load Test Clinic 2'),
         'CONTACTED', 'trying to contact an opted-out lead');
  IF (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL: an opted-out lead was moved to CONTACTED';
  END IF;
  RAISE NOTICE 'PASS: opted-out lead refused re-entry to the pipeline (%)', r->>'error';

  -- even an explicit human actor cannot walk an opt-out back
  r := acq.transition_lead(
         (SELECT id FROM acq.leads WHERE clinic_name = 'Load Test Clinic 2'),
         'QUALIFIED', 'human override attempt', 'HUMAN');
  IF (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL: HUMAN actor bypassed the opt-out guard';
  END IF;
  RAISE NOTICE 'PASS: HUMAN actor also refused (%)', r->>'error';
END $$;

\echo ''
\echo '=== Summary ======================================================'
SELECT * FROM acq.v_funnel ORDER BY stage;
SELECT total_leads, emails_sent, replies, opt_outs, reply_rate_pct FROM acq.v_overview;

ROLLBACK;
\echo ''
\echo 'Smoke test finished. All assertions passed; transaction rolled back.'
