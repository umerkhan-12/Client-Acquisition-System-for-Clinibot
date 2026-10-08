-- =====================================================================
-- Migration 014: the lead workspace behind the dashboard's /leads pages
--
--   v_lead_list      v_lead_intel plus the contact details a person needs
--                    to act, for the filtered table and the CSV export
--   v_lead_activity  the timeline on a lead's page
--   add_lead_note()  and set_lead_stage(): the only two things the dashboard
--                    may write here, as SECURITY DEFINER entry points, like
--                    the approval functions in 010 and 011
--
-- New views rather than new columns on v_lead_intel: migration 013 re-creates
-- that view on every re-run, and Postgres cannot drop columns from a view.
--
-- Stages follow the sales path a person thinks in (contacted, replied,
-- meeting, proposal, won, lost) mapped onto the existing state machine, so
-- the opt-out and suppression rules in transition_lead() still apply: a lead
-- that opted out cannot be moved back, from the dashboard or anywhere else.
-- =====================================================================

SET search_path = acq, public;

CREATE OR REPLACE VIEW acq.v_lead_list AS
SELECT i.*,
       l.phone,
       l.whatsapp,
       l.public_email,
       l.address,
       (SELECT max(a.occurred_at) FROM acq.sales_activities a
         WHERE a.lead_id = i.id AND a.activity_type = 'PROPOSAL_SENT') AS proposal_sent_at,
       l.last_contacted_at,
       l.replied_at
FROM acq.v_lead_intel i
JOIN acq.leads l ON l.id = i.id;

CREATE OR REPLACE VIEW acq.v_lead_activity AS
SELECT a.id, a.lead_id, a.activity_type, a.actor, a.summary, a.occurred_at
FROM acq.sales_activities a
JOIN acq.leads l ON l.id = a.lead_id
WHERE NOT l.opt_out AND NOT l.do_not_contact;

CREATE OR REPLACE FUNCTION acq.add_lead_note(p_lead_id uuid, p_note text, p_by text)
RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
DECLARE
  v_note text := btrim(coalesce(p_note, ''));
BEGIN
  IF v_note = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'empty_note'); END IF;
  IF NOT EXISTS (SELECT 1 FROM acq.leads WHERE id = p_lead_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'lead_not_found');
  END IF;
  INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
  VALUES (p_lead_id, 'NOTE', 'HUMAN', left(v_note, 2000), jsonb_build_object('by', p_by));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- CONTACTED / REPLIED / MEETING / PROPOSAL / WON / LOST, onto lead_status.
-- A proposal is an event on an interested lead rather than a status of its
-- own, so it is recorded as an activity and the lead is held at INTERESTED.
CREATE OR REPLACE FUNCTION acq.set_lead_stage(p_lead_id uuid, p_stage text, p_by text)
RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = acq, public, pg_temp AS $fn$
DECLARE
  v_stage text := upper(coalesce(p_stage, ''));
  v_to    acq.lead_status;
  v_move  jsonb;
BEGIN
  v_to := CASE v_stage
            WHEN 'CONTACTED' THEN 'CONTACTED'
            WHEN 'REPLIED'   THEN 'REPLIED'
            WHEN 'MEETING'   THEN 'DEMO_BOOKED'
            WHEN 'PROPOSAL'  THEN 'INTERESTED'
            WHEN 'WON'       THEN 'CUSTOMER'
            WHEN 'LOST'      THEN 'NOT_INTERESTED'
          END::acq.lead_status;
  IF v_to IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'unknown_stage'); END IF;

  v_move := acq.transition_lead(p_lead_id, v_to, 'dashboard_stage:' || lower(v_stage), 'HUMAN');
  IF NOT coalesce((v_move ->> 'ok')::boolean, false) THEN RETURN v_move; END IF;

  IF v_stage = 'PROPOSAL' THEN
    INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload)
    VALUES (p_lead_id, 'PROPOSAL_SENT', 'HUMAN', 'Proposal sent', jsonb_build_object('by', p_by));
  END IF;
  IF v_stage = 'REPLIED' THEN
    UPDATE acq.leads SET replied_at = coalesce(replied_at, now()) WHERE id = p_lead_id;
    PERFORM acq.stop_follow_ups(p_lead_id, 'replied_recorded_in_dashboard');
  END IF;
  IF v_stage = 'CONTACTED' THEN
    UPDATE acq.leads SET last_contacted_at = coalesce(last_contacted_at, now()) WHERE id = p_lead_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'stage', v_stage, 'status', v_to);
END;
$fn$;

GRANT SELECT ON acq.v_lead_list, acq.v_lead_activity TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.add_lead_note(uuid, text, text)  TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.set_lead_stage(uuid, text, text) TO acq_dashboard;
