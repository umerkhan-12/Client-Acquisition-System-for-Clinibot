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
\echo '=== 10. Scoring gates differ by phase ============================='

-- Regression guard. Both phases once shared the `qualify` threshold of 45,
-- which was calibrated against the blended score. A dental clinic with a
-- website, a phone and a WhatsApp number scores 38 deterministically and was
-- rejected before it could earn the 40-odd points research adds. A real
-- workflow-20 run rejected all six seeded leads.

INSERT INTO acq.leads (market_id, clinic_name, city, category, priority_tier,
                       website, phone, whatsapp, source, source_url, status)
SELECT m.id, 'Gate Test Dental', 'Karachi', 'DENTAL', 1,
       'https://gatetest.pk', '02136631122', '03001234567',
       'TEST', 'https://gatetest', 'QUALIFIED'
FROM acq.markets m WHERE m.code = 'PK';

DO $$
DECLARE lead uuid; det jsonb; bl jsonb;
BEGIN
  SELECT id INTO lead FROM acq.leads WHERE clinic_name = 'Gate Test Dental';

  det := acq.compute_score(lead, 'DETERMINISTIC');
  IF (det->>'score')::int <> 38 THEN
    RAISE EXCEPTION 'FAIL: expected a deterministic score of 38, got %', det->>'score';
  END IF;
  IF NOT (det->>'qualifies')::boolean THEN
    RAISE EXCEPTION 'FAIL: a website + phone + WhatsApp tier-1 clinic must be worth researching (score %, gate %)',
      det->>'score', det->>'gate';
  END IF;
  IF det->>'gate_key' <> 'qualify_deterministic' THEN
    RAISE EXCEPTION 'FAIL: deterministic phase used gate %', det->>'gate_key';
  END IF;
  RAISE NOTICE 'PASS: deterministic phase qualifies at % against gate %',
    det->>'score', det->>'gate';

  -- With no research attached, the blended phase must hold it back.
  bl := acq.compute_score(lead, 'BLENDED');
  IF (bl->>'qualifies')::boolean THEN
    RAISE EXCEPTION 'FAIL: blended phase should not qualify an unresearched lead at %', bl->>'score';
  END IF;
  IF bl->>'gate_key' <> 'qualify' THEN
    RAISE EXCEPTION 'FAIL: blended phase used gate %', bl->>'gate_key';
  END IF;
  RAISE NOTICE 'PASS: blended phase holds the same lead back at gate %', bl->>'gate';
END $$;

\echo ''
\echo '=== 11. WEB offer: routing, scoring, and the Clinibot claimers ===='

-- A clinic with nothing to research and no address to email cannot be a
-- Clinibot prospect. Workflow 20 used to reject it; now it becomes a website
-- prospect. A clinic WITH a website must stay exactly where it was.
INSERT INTO acq.leads (market_id, clinic_name, city, area, category, priority_tier,
                       website, phone, source, source_url, status, raw)
SELECT m.id, v.name, 'Karachi', 'Saddar', v.cat, 1, v.site, v.phone,
       'TEST', 'https://maps.example/' || v.name, 'NEW',
       '{"GOOGLE_PLACES":{"userRatingCount":40,"rating":4.4}}'::jsonb
FROM acq.markets m,
     (VALUES ('Web Test No Site',     'DENTAL',   NULL,                            '03001110001'),
             ('Web Test Facebook',    'DENTAL',   'https://facebook.com/webtest',  '02135550002'),
             ('Web Test Has Site',    'DENTAL',   'https://webtest-has-site.pk',   '03001110003')
     ) AS v(name, cat, site, phone)
WHERE m.code = 'PK';

DO $$
DECLARE o text; s jsonb; lead uuid; n int;
BEGIN
  SELECT offer INTO o FROM acq.route_offer((SELECT id FROM acq.leads WHERE clinic_name = 'Web Test No Site'));
  IF o <> 'WEB' THEN RAISE EXCEPTION 'FAIL: clinic with no website was not rerouted (offer %)', o; END IF;

  SELECT offer INTO o FROM acq.route_offer((SELECT id FROM acq.leads WHERE clinic_name = 'Web Test Facebook'));
  IF o <> 'WEB' THEN RAISE EXCEPTION 'FAIL: a Facebook page counted as a website (offer %)', o; END IF;

  SELECT offer INTO o FROM acq.route_offer((SELECT id FROM acq.leads WHERE clinic_name = 'Web Test Has Site'));
  IF o <> 'CLINIBOT' THEN RAISE EXCEPTION 'FAIL: clinic with a website left Clinibot (offer %)', o; END IF;
  RAISE NOTICE 'PASS: no-website clinics reroute to WEB, one with a site stays CLINIBOT';

  -- No website: the deterministic score is final, so the selective gate applies.
  s := acq.compute_score((SELECT id FROM acq.leads WHERE clinic_name = 'Web Test No Site'), 'DETERMINISTIC');
  IF s->>'gate_key' <> 'qualify' OR NOT (s->>'qualifies')::boolean OR NOT (s->'breakdown' ? 'no_website') THEN
    RAISE EXCEPTION 'FAIL: WEB no-website scoring: %', s - 'thresholds';
  END IF;
  RAISE NOTICE 'PASS: busy listing with no website scores % against the final gate %', s->>'score', s->>'gate';

  -- A WEB lead that has a website is QUALIFIED with a website: exactly what
  -- workflow 30 looks for. The offer must keep it out.
  UPDATE acq.leads SET offer = 'WEB', status = 'QUALIFIED', lead_score = 99
   WHERE clinic_name = 'Web Test Has Site';
  SELECT count(*) INTO n FROM acq.claim_leads_for_research(50, 'smoke-wf30-web')
   WHERE offer = 'WEB';
  IF n > 0 THEN RAISE EXCEPTION 'FAIL: the Clinibot research claim took % WEB lead(s)', n; END IF;
  RAISE NOTICE 'PASS: Clinibot claimers never lock a WEB lead';
END $$;

\echo ''
\echo '=== 12. Website audit decides in SQL; found email keeps provenance ='

INSERT INTO acq.leads (market_id, clinic_name, city, category, priority_tier, offer,
                       website, phone, source, source_url, status)
SELECT m.id, v.name, 'Karachi', 'PRINTING', 1, 'WEB', v.site, v.phone,
       'TEST', 'https://maps.example/' || v.name, 'QUALIFIED'
FROM acq.markets m,
     (VALUES ('Audit Weak Site', 'http://weak-printers.pk',  '03002220001'),
             ('Audit Good Site', 'https://good-printers.pk', '03002220002')) AS v(name, site, phone)
WHERE m.code = 'PK';

DO $$
DECLARE r jsonb; n int; st acq.lead_status; em text; src acq.contact_source;
BEGIN
  SELECT count(*) INTO n FROM acq.claim_leads_for_audit(10, 'smoke-wf25')
   WHERE clinic_name IN ('Audit Weak Site', 'Audit Good Site');
  IF n <> 2 THEN RAISE EXCEPTION 'FAIL: expected both sites claimed for audit, got %', n; END IF;

  r := acq.record_website_audit(jsonb_build_object(
         'lead_id', (SELECT id FROM acq.leads WHERE clinic_name = 'Audit Weak Site'),
         'url', 'http://weak-printers.pk', 'robots_allowed', true, 'reachable', true,
         'status_code', 200, 'https', false, 'has_viewport', false,
         'issues', '["no_https","not_mobile_friendly","outdated"]'::jsonb,
         'email', 'Orders@Weak-Printers.pk', 'email_url', 'http://weak-printers.pk/'));
  SELECT status, public_email, email_source INTO st, em, src
    FROM acq.leads WHERE clinic_name = 'Audit Weak Site';
  IF NOT (r->>'qualifies')::boolean OR st <> 'QUALIFIED' THEN
    RAISE EXCEPTION 'FAIL: a weak site should stay pitchable: % / %', st, r;
  END IF;
  IF em <> 'orders@weak-printers.pk' OR src <> 'CLINIC_WEBSITE' THEN
    RAISE EXCEPTION 'FAIL: email found on the site not stored with provenance (% / %)', em, src;
  END IF;

  r := acq.record_website_audit(jsonb_build_object(
         'lead_id', (SELECT id FROM acq.leads WHERE clinic_name = 'Audit Good Site'),
         'url', 'https://good-printers.pk', 'robots_allowed', true, 'reachable', true,
         'status_code', 200, 'https', true, 'has_viewport', true, 'issues', '[]'::jsonb));
  SELECT status INTO st FROM acq.leads WHERE clinic_name = 'Audit Good Site';
  IF st <> 'REJECTED' THEN RAISE EXCEPTION 'FAIL: a good site should be rejected, is %', st; END IF;
  RAISE NOTICE 'PASS: weak site stays QUALIFIED with its email; good site REJECTED';
END $$;

\echo ''
\echo '=== 13. Web pitch: daily cap, channel, fallback, follow-up ========'

INSERT INTO acq.leads (market_id, clinic_name, city, area, category, priority_tier, offer,
                       phone, source, source_url, status, lead_score)
SELECT m.id, 'Pitch Test ' || g, 'Karachi', 'Saddar', 'SALON', 1, 'WEB',
       CASE WHEN g = 4 THEN '02133330004' ELSE '0300333000' || g END,
       'TEST', 'https://maps.example/pitch' || g, 'QUALIFIED', 90 - g
FROM acq.markets m, generate_series(1, 4) g WHERE m.code = 'PK';

UPDATE acq.settings SET value = '2'::jsonb WHERE key = 'web.max_drafts_per_day';
-- Earlier sections left other WEB leads QUALIFIED; park them so the cap test
-- counts only these four.
UPDATE acq.leads SET status = 'REJECTED' WHERE offer = 'WEB' AND clinic_name NOT LIKE 'Pitch Test %';

DO $$
DECLARE n int; r jsonb; m acq.manual_outreach%ROWTYPE; st acq.lead_status;
        l4 uuid; l1 uuid;
BEGIN
  SELECT count(*) INTO n FROM acq.claim_leads_for_web_pitch(10, 'wf45:smoke-a');
  IF n <> 2 THEN RAISE EXCEPTION 'FAIL: daily cap 2 but first claim took %', n; END IF;
  -- claimed-but-undrafted leads count against the cap, so an overlapping run gets nothing
  SELECT count(*) INTO n FROM acq.claim_leads_for_web_pitch(10, 'wf45:smoke-b');
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL: overlapping run exceeded the cap by %', n; END IF;
  RAISE NOTICE 'PASS: daily draft cap holds across overlapping runs';

  SELECT id INTO l1 FROM acq.leads WHERE clinic_name = 'Pitch Test 1';
  SELECT id INTO l4 FROM acq.leads WHERE clinic_name = 'Pitch Test 4';

  -- No AI message: the template is used, so a model outage delays nothing.
  r := acq.record_web_pitch(jsonb_build_object('lead_id', l1));
  SELECT * INTO m FROM acq.manual_outreach WHERE lead_id = l1 AND step_no = 0;
  IF m.draft_source <> 'TEMPLATE' OR m.channel <> 'WHATSAPP' OR m.message NOT LIKE '%Pitch Test 1 in Saddar%' THEN
    RAISE EXCEPTION 'FAIL: template fallback / channel wrong: % % %', m.draft_source, m.channel, m.message;
  END IF;
  -- a landline gets a call script, not a WhatsApp link
  r := acq.record_web_pitch(jsonb_build_object('lead_id', l4, 'message', 'Hello from a test'));
  IF r->>'channel' <> 'PHONE_CALL' THEN RAISE EXCEPTION 'FAIL: landline channel was %', r->>'channel'; END IF;
  -- a retried run cannot queue a second pitch
  r := acq.record_web_pitch(jsonb_build_object('lead_id', l1, 'message', 'second attempt'));
  SELECT count(*) INTO n FROM acq.manual_outreach WHERE lead_id = l1 AND step_no = 0;
  IF n <> 1 OR NOT (r->>'duplicate')::boolean THEN RAISE EXCEPTION 'FAIL: duplicate pitch queued'; END IF;
  SELECT status INTO st FROM acq.leads WHERE id = l1;
  IF st <> 'READY_FOR_REVIEW' THEN RAISE EXCEPTION 'FAIL: drafted lead is % not READY_FOR_REVIEW', st; END IF;
  RAISE NOTICE 'PASS: template fallback, WhatsApp vs call, idempotent drafts';

  -- Sent by hand: lead CONTACTED, follow-up scheduled, not resendable.
  r := acq.mark_manual_sent(m.id, 'Edited before sending', 'smoke@test');
  SELECT status INTO st FROM acq.leads WHERE id = l1;
  IF NOT (r->>'ok')::boolean OR st <> 'CONTACTED' THEN RAISE EXCEPTION 'FAIL: mark sent: % / %', r, st; END IF;
  IF (SELECT message FROM acq.manual_outreach WHERE id = m.id) <> 'Edited before sending' THEN
    RAISE EXCEPTION 'FAIL: the edited text was not the one recorded';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM acq.manual_outreach WHERE lead_id = l1 AND step_no = 1 AND status = 'SCHEDULED') THEN
    RAISE EXCEPTION 'FAIL: no follow-up scheduled';
  END IF;
  r := acq.mark_manual_sent(m.id, NULL, 'smoke@test');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL: a sent message was marked sent twice'; END IF;

  -- Any answer cancels the follow-up: the manual twin of record_reply().
  r := acq.record_manual_outcome(l1, 'REPLIED', 'smoke@test');
  IF EXISTS (SELECT 1 FROM acq.manual_outreach WHERE lead_id = l1 AND status = 'SCHEDULED') THEN
    RAISE EXCEPTION 'FAIL: follow-up still scheduled after a reply';
  END IF;
  SELECT status INTO st FROM acq.leads WHERE id = l1;
  IF st <> 'REPLIED' THEN RAISE EXCEPTION 'FAIL: lead is % after reply', st; END IF;
  RAISE NOTICE 'PASS: sent by hand -> CONTACTED + follow-up; a reply cancels it';

  -- "Stop messaging me" suppresses the number for good.
  r := acq.record_manual_outcome(l1, 'OPT_OUT', 'smoke@test');
  SELECT status INTO st FROM acq.leads WHERE id = l1;
  IF st <> 'OPTED_OUT' OR NOT acq.is_suppressed(NULL, NULL, '+923003330001', NULL) THEN
    RAISE EXCEPTION 'FAIL: opt-out not applied (status %)', st;
  END IF;
  r := acq.transition_lead(l1, 'QUALIFIED', 'try to revive', 'HUMAN');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL: opted-out WEB lead revived'; END IF;
  RAISE NOTICE 'PASS: opt-out suppresses the phone number and is permanent';
END $$;

UPDATE acq.settings SET value = '20'::jsonb WHERE key = 'web.max_drafts_per_day';

\echo ''
\echo '=== 14. Dashboard role: the queue, and nothing underneath ========='

DO $$
DECLARE n int; denied boolean := false; r jsonb;
BEGIN
  SET LOCAL ROLE acq_dashboard;
  SELECT count(*) INTO n FROM acq.v_manual_outreach;
  BEGIN
    PERFORM 1 FROM acq.manual_outreach LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN denied := true;
  END;
  -- the three narrow entry points are callable
  r := acq.skip_manual((SELECT id FROM acq.v_manual_outreach WHERE business_name = 'Pitch Test 4'),
                       'smoke', 'smoke@test');
  RESET ROLE;

  IF NOT denied THEN RAISE EXCEPTION 'FAIL: acq_dashboard can read acq.manual_outreach directly'; END IF;
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL: dashboard could not skip a draft: %', r; END IF;
  RAISE NOTICE 'PASS: dashboard reads % queue row(s) via the view, not the table, and can act on them', n;
END $$;

\echo ''
\echo '=== 15. Listing stats score, in the shape discovery stores them ===='

-- Regression guard. upsert_lead nests each source's payload under its source
-- name, so real leads look like raw.GOOGLE_PLACES.GOOGLE_PLACES.rating. The
-- scorer read the flat path, and the review-count and rating points never
-- fired for a single discovered lead. Built through upsert_lead here, exactly
-- as workflow 10 does, rather than inserting raw by hand.
DO $$
DECLARE r jsonb; s jsonb;
BEGIN
  r := acq.upsert_lead_for_offer(jsonb_build_object(
         'market_code', 'PK', 'offer', 'WEB', 'clinic_name', 'Stats Test Rooftop Cafe',
         'city', 'Karachi', 'area', 'Clifton', 'phone', '03009990001',
         'category', 'CAFE', 'priority_tier', 1,
         'source', 'TREG_MAPS', 'source_url', 'https://maps.example/stats',
         'source_ref', 'ChIJstatstest', 'source_ref_type', 'PLACE_ID',
         'raw', jsonb_build_object('GOOGLE_PLACES',
                  jsonb_build_object('userRatingCount', 1200, 'rating', 4.6))));
  s := acq.compute_score((r->>'lead_id')::uuid, 'DETERMINISTIC');
  IF NOT (s->'breakdown' ? 'active_listing' AND s->'breakdown' ? 'well_rated'
          AND s->'breakdown' ? 'popular_venue') THEN
    RAISE EXCEPTION 'FAIL: nested listing stats not scored: %', s->'breakdown';
  END IF;
  RAISE NOTICE 'PASS: a busy 4.6-star venue earns active_listing, well_rated and popular_venue (score %)', s->>'score';
END $$;

\echo ''
\echo '=== 16. Lead intelligence: opportunities from evidence only ======='

DO $$
DECLARE r jsonb; i jsonb; salon uuid; shell uuid;
BEGIN
  -- A busy cafe with no website: build ordering into the first pitch.
  r := acq.upsert_lead_for_offer(jsonb_build_object(
         'market_code', 'PK', 'offer', 'WEB', 'clinic_name', 'Intel Test Espresso Bar',
         'city', 'Karachi', 'area', 'DHA', 'phone', '03009990002', 'category', 'CAFE',
         'priority_tier', 1, 'source', 'TREG_MAPS', 'source_url', 'https://maps.example/intel1',
         'raw', jsonb_build_object('GOOGLE_PLACES', jsonb_build_object('userRatingCount', 6166, 'rating', 4.4))));
  PERFORM acq.compute_score((r->>'lead_id')::uuid, 'DETERMINISTIC');
  i := acq.lead_intel((r->>'lead_id')::uuid);
  IF i->>'recommended_service' <> 'WEBSITE_ORDERING' OR i->>'complexity' <> 'MEDIUM'
     OR i->>'website_status' <> 'NO_WEBSITE' OR i->>'best_channel' <> 'WHATSAPP'
     OR position('6,166 Google reviews' in i->>'why') = 0
     OR NOT (i->'opportunities' @> '[{"code":"NO_ONLINE_ORDERING"}]') THEN
    RAISE EXCEPTION 'FAIL: cafe intel wrong: %', i;
  END IF;
  RAISE NOTICE 'PASS: busy cafe without a site -> % (%), priority %', i->>'service_label', i->>'complexity', i->>'priority';

  -- A salon whose site was audited as weak and as having no booking.
  r := acq.upsert_lead_for_offer(jsonb_build_object(
         'market_code', 'PK', 'offer', 'WEB', 'clinic_name', 'Intel Test Glow Salon',
         'city', 'Karachi', 'website', 'http://glow-salon-intel.pk', 'phone', '03009990003',
         'category', 'SALON', 'priority_tier', 1, 'source', 'TREG_MAPS', 'source_url', 'https://maps.example/intel2'));
  salon := (r->>'lead_id')::uuid;
  PERFORM acq.record_website_audit(jsonb_build_object(
    'lead_id', salon, 'url', 'http://glow-salon-intel.pk/', 'robots_allowed', true, 'reachable', true,
    'issues', '["not_mobile_friendly","no_https"]'::jsonb, 'has_tel_link', true,
    'raw', jsonb_build_object('features', jsonb_build_object('booking', false), 'platform', 'Wix')));
  i := acq.lead_intel(salon);
  IF i->>'recommended_service' <> 'REDESIGN' OR i->>'website_status' <> 'WEAK' OR i->>'platform' <> 'Wix'
     OR NOT (i->'opportunities' @> '[{"code":"NO_ONLINE_BOOKING"}]')
     OR position('not set up for phones' in i->>'why') = 0 THEN
    RAISE EXCEPTION 'FAIL: salon intel wrong: %', i;
  END IF;
  RAISE NOTICE 'PASS: weak salon site -> redesign, booking flagged, platform recorded';

  -- A homepage too thin to judge (features null) claims nothing about booking.
  r := acq.upsert_lead_for_offer(jsonb_build_object(
         'market_code', 'PK', 'offer', 'WEB', 'clinic_name', 'Intel Test Shell Studio',
         'city', 'Karachi', 'website', 'https://shell-studio-intel.pk', 'phone', '03009990004',
         'category', 'SALON', 'priority_tier', 1, 'source', 'TREG_MAPS', 'source_url', 'https://maps.example/intel3'));
  shell := (r->>'lead_id')::uuid;
  PERFORM acq.record_website_audit(jsonb_build_object(
    'lead_id', shell, 'url', 'https://shell-studio-intel.pk/', 'robots_allowed', true, 'reachable', true,
    'issues', '[]'::jsonb, 'has_tel_link', true,
    'raw', jsonb_build_object('features', jsonb_build_object('booking', null))));
  i := acq.lead_intel(shell);
  IF i->'opportunities' @> '[{"code":"NO_ONLINE_BOOKING"}]' OR i->>'recommended_service' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: an unjudgeable page produced a claim: %', i;
  END IF;
  RAISE NOTICE 'PASS: a page too thin to judge claims nothing';
END $$;

\echo ''
\echo '=== 17. Lead workspace: notes and stages through narrow functions ='

DO $$
DECLARE r jsonb; lead uuid; st acq.lead_status; n int; denied boolean := false;
BEGIN
  r := acq.upsert_lead_for_offer(jsonb_build_object(
         'market_code', 'PK', 'offer', 'WEB', 'clinic_name', 'Stage Test Bistro', 'city', 'Karachi',
         'phone', '03009990005', 'category', 'RESTAURANT', 'source', 'TREG_MAPS',
         'source_url', 'https://maps.example/stage'));
  lead := (r->>'lead_id')::uuid;
  UPDATE acq.leads SET status = 'CONTACTED' WHERE id = lead;

  SET LOCAL ROLE acq_dashboard;
  r := acq.add_lead_note(lead, 'Owner asked for a call on Monday', 'smoke@test');
  r := acq.set_lead_stage(lead, 'MEETING', 'smoke@test');
  r := acq.set_lead_stage(lead, 'PROPOSAL', 'smoke@test');
  SELECT count(*) INTO n FROM acq.v_lead_activity WHERE lead_id = lead AND activity_type IN ('NOTE','PROPOSAL_SENT');
  BEGIN
    PERFORM 1 FROM acq.sales_activities LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN denied := true;
  END;
  RESET ROLE;

  SELECT status INTO st FROM acq.leads WHERE id = lead;
  IF st <> 'INTERESTED' OR n <> 2 OR NOT denied THEN
    RAISE EXCEPTION 'FAIL: workspace: status %, timeline rows %, table denied %', st, n, denied;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM acq.v_lead_list WHERE id = lead AND proposal_sent_at IS NOT NULL AND phone IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL: v_lead_list missing proposal or phone';
  END IF;

  -- An opted-out lead cannot be walked back from the dashboard either.
  UPDATE acq.leads SET opt_out = true WHERE id = lead;
  r := acq.set_lead_stage(lead, 'WON', 'smoke@test');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL: dashboard moved an opted-out lead to WON'; END IF;
  RAISE NOTICE 'PASS: notes and stages via the dashboard role; opt-out still wins (%)', r->>'error';
END $$;

\echo ''
\echo '=== Summary ======================================================'
SELECT * FROM acq.v_funnel ORDER BY stage;
SELECT total_leads, emails_sent, replies, opt_outs, reply_rate_pct FROM acq.v_overview;

ROLLBACK;
\echo ''
\echo 'Smoke test finished. All assertions passed; transaction rolled back.'
