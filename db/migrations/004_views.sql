-- =====================================================================
-- Migration 004: reporting views and the lead-profile assembler
-- These back the Next.js dashboard and the Telegram hot-lead card, so the
-- presentation layers never need to know the schema.
-- =====================================================================

SET search_path = acq, public;

-- Maps the 21 detailed statuses onto the 6 funnel stages the dashboard shows.
CREATE OR REPLACE FUNCTION acq.funnel_stage(p_status acq.lead_status)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN p_status IN ('NEW','RESEARCHING')                                   THEN 'NEW'
    WHEN p_status IN ('QUALIFIED','READY_FOR_REVIEW','APPROVED')             THEN 'QUALIFIED'
    WHEN p_status IN ('CONTACTED','FOLLOW_UP_1','FOLLOW_UP_2','FOLLOW_UP_3') THEN 'CONTACTED'
    WHEN p_status IN ('REPLIED','LATER')                                     THEN 'REPLIED'
    WHEN p_status IN ('INTERESTED','DEMO_REQUESTED')                         THEN 'INTERESTED'
    WHEN p_status = 'DEMO_BOOKED'                                            THEN 'DEMO'
    WHEN p_status = 'CUSTOMER'                                               THEN 'CUSTOMER'
    ELSE 'CLOSED'
  END;
$fn$;

CREATE OR REPLACE VIEW acq.v_funnel AS
SELECT
  acq.funnel_stage(status) AS stage,
  count(*)                 AS leads,
  round(avg(lead_score))   AS avg_score
FROM acq.leads
WHERE status NOT IN ('REJECTED','INVALID')
GROUP BY 1;

-- The headline numbers requested in section 22 of the brief.
CREATE OR REPLACE VIEW acq.v_overview AS
SELECT
  (SELECT count(*) FROM acq.leads)                                              AS total_leads,
  (SELECT count(*) FROM acq.leads WHERE status NOT IN ('NEW','RESEARCHING','REJECTED','INVALID'))
                                                                                AS qualified_leads,
  (SELECT count(*) FROM acq.emails WHERE status = 'SENT')                       AS emails_sent,
  (SELECT count(*) FROM acq.replies WHERE NOT is_auto_reply AND NOT is_bounce)  AS replies,
  (SELECT count(*) FROM acq.leads WHERE status IN ('INTERESTED','DEMO_REQUESTED','DEMO_BOOKED','CUSTOMER'))
                                                                                AS interested,
  (SELECT count(*) FROM acq.demo_bookings WHERE status <> 'CANCELLED')          AS demos,
  (SELECT count(*) FROM acq.leads WHERE status = 'CUSTOMER')                    AS customers,
  (SELECT count(*) FROM acq.opt_outs WHERE reason IN ('OPT_OUT_REQUEST','COMPLAINT','DELETION_REQUEST'))
                                                                                AS opt_outs,
  (SELECT count(*) FROM acq.email_events WHERE event = 'HARD_BOUNCE')           AS bounces,
  (SELECT count(*) FROM acq.approvals WHERE status = 'PENDING')                 AS pending_approvals,
  (SELECT count(*) FROM acq.dead_letters WHERE resolved_at IS NULL)             AS open_dead_letters,
  CASE WHEN (SELECT count(*) FROM acq.emails WHERE status = 'SENT') = 0 THEN 0
       ELSE round(100.0
            * (SELECT count(*) FROM acq.replies WHERE NOT is_auto_reply AND NOT is_bounce)
            / (SELECT count(*) FROM acq.emails WHERE status = 'SENT'), 2)
  END                                                                           AS reply_rate_pct,
  CASE WHEN (SELECT count(*) FROM acq.leads WHERE status <> 'NEW') = 0 THEN 0
       ELSE round(100.0
            * (SELECT count(*) FROM acq.leads WHERE status = 'CUSTOMER')
            / NULLIF((SELECT count(*) FROM acq.emails WHERE status = 'SENT'), 0), 2)
  END                                                                           AS conversion_rate_pct;

CREATE OR REPLACE VIEW acq.v_daily_metrics AS
WITH days AS (
  SELECT generate_series(CURRENT_DATE - interval '29 days', CURRENT_DATE, interval '1 day')::date AS d
)
SELECT
  days.d AS day,
  (SELECT count(*) FROM acq.leads      WHERE created_at::date = days.d)                  AS leads_discovered,
  (SELECT count(*) FROM acq.emails     WHERE sent_at::date = days.d)                     AS emails_sent,
  (SELECT count(*) FROM acq.replies    WHERE received_at::date = days.d
                                         AND NOT is_auto_reply AND NOT is_bounce)        AS replies,
  (SELECT count(*) FROM acq.email_events WHERE occurred_at::date = days.d
                                           AND event = 'HARD_BOUNCE')                    AS hard_bounces,
  (SELECT count(*) FROM acq.opt_outs   WHERE created_at::date = days.d)                  AS opt_outs,
  (SELECT coalesce(sum(cost_usd), 0) FROM acq.ai_calls WHERE created_at::date = days.d)  AS ai_cost_usd
FROM days
ORDER BY days.d DESC;

-- Deliverability health per mailbox. Watch bounce_rate_pct and complaint_rate_pct:
-- sustained values above ~2% and ~0.1% respectively are the point at which a
-- sending domain starts getting filtered.
CREATE OR REPLACE VIEW acq.v_deliverability AS
SELECT
  m.key                                       AS mailbox,
  m.from_email,
  m.warmup_stage,
  acq.warmup_daily_cap(m.id)                  AS effective_daily_cap,
  coalesce(sc.sent_today, 0)                  AS sent_today,
  s.sent_30d,
  s.hard_bounces_30d,
  s.complaints_30d,
  s.replies_30d,
  CASE WHEN s.sent_30d = 0 THEN 0
       ELSE round(100.0 * s.hard_bounces_30d / s.sent_30d, 2) END AS bounce_rate_pct,
  CASE WHEN s.sent_30d = 0 THEN 0
       ELSE round(100.0 * s.complaints_30d / s.sent_30d, 2) END   AS complaint_rate_pct,
  CASE WHEN s.sent_30d = 0 THEN 0
       ELSE round(100.0 * s.replies_30d / s.sent_30d, 2) END      AS reply_rate_pct
FROM acq.mailboxes m
LEFT JOIN LATERAL (
  SELECT
    count(*) FILTER (WHERE e.status = 'SENT' AND e.sent_at > now() - interval '30 days') AS sent_30d,
    count(*) FILTER (WHERE ev.event = 'HARD_BOUNCE')                                     AS hard_bounces_30d,
    count(*) FILTER (WHERE ev.event = 'COMPLAINT')                                       AS complaints_30d,
    count(*) FILTER (WHERE ev.event = 'REPLIED')                                         AS replies_30d
  FROM acq.emails e
  LEFT JOIN acq.email_events ev
         ON ev.email_id = e.id AND ev.occurred_at > now() - interval '30 days'
  WHERE e.mailbox_id = m.id
) s ON true
LEFT JOIN LATERAL (
  SELECT sent_count AS sent_today FROM acq.send_counters
   WHERE mailbox_id = m.id AND bucket_date = CURRENT_DATE AND bucket_hour = -1
) sc ON true;

-- The main dashboard table.
CREATE OR REPLACE VIEW acq.v_lead_dashboard AS
SELECT
  l.id,
  l.clinic_name,
  l.city,
  l.area,
  l.category,
  l.lead_score,
  l.status,
  acq.funnel_stage(l.status)    AS stage,
  l.public_email,
  l.whatsapp,
  l.website,
  l.last_contacted_at,
  l.next_follow_up_at,
  l.follow_up_count,
  r.pain_point                  AS ai_pain_point,
  r.recommended_pitch           AS ai_recommended_pitch,
  r.confidence                  AS ai_confidence,
  le.subject                    AS last_email_subject,
  le.sent_at                    AS last_email_sent_at,
  lr.body_text                  AS last_reply_text,
  lr.received_at                AS last_reply_at,
  rc.class                      AS last_reply_class,
  l.score_breakdown,
  l.created_at
FROM acq.leads l
LEFT JOIN acq.lead_research r ON r.lead_id = l.id AND r.is_current
LEFT JOIN LATERAL (
  SELECT subject, sent_at FROM acq.emails
   WHERE lead_id = l.id AND status = 'SENT'
   ORDER BY sent_at DESC LIMIT 1
) le ON true
LEFT JOIN LATERAL (
  SELECT id, body_text, received_at FROM acq.replies
   WHERE lead_id = l.id AND NOT is_auto_reply AND NOT is_bounce
   ORDER BY received_at DESC LIMIT 1
) lr ON true
LEFT JOIN acq.reply_classifications rc ON rc.reply_id = lr.id;

CREATE OR REPLACE VIEW acq.v_hot_leads AS
SELECT * FROM acq.v_lead_dashboard
WHERE status IN ('REPLIED','INTERESTED','DEMO_REQUESTED','DEMO_BOOKED')
   OR last_reply_class IN ('VERY_INTERESTED','INTERESTED','ASKING_DEMO','ASKING_PRICE')
ORDER BY lead_score DESC, last_reply_at DESC NULLS LAST;

CREATE OR REPLACE VIEW acq.v_approval_queue AS
SELECT
  a.id, a.kind, a.title, a.ai_confidence, a.requested_at, a.expires_at,
  l.clinic_name, l.city, l.lead_score, l.public_email,
  a.payload, a.lead_id, a.email_id, a.reply_id
FROM acq.approvals a
LEFT JOIN acq.leads l ON l.id = a.lead_id
WHERE a.status = 'PENDING' AND a.expires_at > now()
ORDER BY l.lead_score DESC NULLS LAST, a.requested_at;

-- Assembles the complete lead profile for the hot-lead notification, so the
-- notification workflow is a formatting step with no schema knowledge.
CREATE OR REPLACE FUNCTION acq.lead_profile(p_lead_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'lead_id',        l.id,
    'clinic_name',    l.clinic_name,
    'location',       concat_ws(', ', nullif(l.area,''), nullif(l.city,'')),
    'category',       l.category,
    'lead_score',     l.lead_score,
    'status',         l.status,
    'website',        l.website,
    'public_email',   l.public_email,
    'phone',          l.phone,
    'whatsapp',       l.whatsapp,
    'doctor_count',   l.doctor_count,
    'score_breakdown', l.score_breakdown,
    'why_qualified',  coalesce(
        (SELECT jsonb_agg(f->>'claim') FROM acq.lead_research r2,
                jsonb_array_elements(r2.facts) f
          WHERE r2.lead_id = l.id AND r2.is_current), '[]'::jsonb),
    'pain_point',     r.pain_point,
    'recommended_pitch', r.recommended_pitch,
    'ai_confidence',  r.confidence,
    'emails_sent',    (SELECT count(*) FROM acq.emails WHERE lead_id = l.id AND status = 'SENT'),
    'last_email', (
      SELECT jsonb_build_object('subject', subject, 'sent_at', sent_at, 'step_no', step_no)
        FROM acq.emails WHERE lead_id = l.id AND status = 'SENT'
       ORDER BY sent_at DESC LIMIT 1),
    'last_reply', (
      SELECT jsonb_build_object(
               'from', rp.from_email, 'received_at', rp.received_at,
               'text', left(coalesce(rp.body_text,''), 800),
               'class', rc.class, 'confidence', rc.confidence,
               'suggested_reply', rc.suggested_reply)
        FROM acq.replies rp
        LEFT JOIN acq.reply_classifications rc ON rc.reply_id = rp.id
       WHERE rp.lead_id = l.id AND NOT rp.is_auto_reply AND NOT rp.is_bounce
       ORDER BY rp.received_at DESC LIMIT 1),
    'source',        l.source,
    'source_url',    l.source_url,
    'created_at',    l.created_at
  )
  FROM acq.leads l
  LEFT JOIN acq.lead_research r ON r.lead_id = l.id AND r.is_current
  WHERE l.id = p_lead_id;
$fn$;
