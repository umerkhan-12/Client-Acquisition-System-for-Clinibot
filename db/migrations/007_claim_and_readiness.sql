-- =====================================================================
-- Migration 007: purpose-built claim functions, and a readiness check
--
-- Fixes a real defect. Workflows 30 and 40 both did this:
--
--     SELECT ... FROM acq.claim_leads(ARRAY['QUALIFIED'], 15, 'wf30') l
--      WHERE l.website IS NOT NULL AND NOT EXISTS (...)
--
-- acq.claim_leads() LOCKS every lead it picks, and only then does the outer
-- WHERE discard the unusable ones. Measured on 20 qualified leads of which 4
-- were researchable: the workflow received its 4 rows, but 15 leads were left
-- locked -- 11 of them uselessly -- and the next workflow found only 5 leads
-- available instead of 16.
--
-- Running hourly and every twenty minutes against the same status, the two
-- workflows would starve each other indefinitely.
--
-- The fix is to push the predicate INTO the claim, so a lead is only ever
-- locked by a workflow that can actually use it.
-- =====================================================================

SET search_path = acq, public;

-- ---------------------------------------------------------------------
-- Workflow 30: leads that can actually be researched
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.claim_leads_for_research(
  p_limit  int,
  p_worker text,
  p_stale_lock_minutes int DEFAULT 15
) RETURNS SETOF acq.leads LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  UPDATE acq.leads l
     SET locked_by = p_worker, locked_at = now()
   WHERE l.id IN (
     SELECT c.id FROM acq.leads c
      WHERE c.status = 'QUALIFIED'
        AND NOT c.opt_out
        AND NOT c.do_not_contact
        -- there must be something public to read, or there is nothing to
        -- personalise from and the AI call would be wasted
        AND c.website IS NOT NULL
        -- research is cached; never pay to research the same clinic twice
        AND NOT EXISTS (
          SELECT 1 FROM acq.lead_research r
           WHERE r.lead_id = c.id AND r.is_current AND r.stale_after > now()
        )
        AND (c.locked_at IS NULL
             OR c.locked_at < now() - make_interval(mins => p_stale_lock_minutes))
      ORDER BY c.lead_score DESC, c.created_at
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
   )
  RETURNING l.*;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Workflow 40: leads that are ready to have an email written
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.claim_leads_for_personalization(
  p_limit     int,
  p_worker    text,
  p_min_score int DEFAULT 0,
  p_stale_lock_minutes int DEFAULT 15
) RETURNS SETOF acq.leads LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  UPDATE acq.leads l
     SET locked_by = p_worker, locked_at = now()
   WHERE l.id IN (
     SELECT c.id FROM acq.leads c
      WHERE c.status = 'QUALIFIED'
        AND NOT c.opt_out
        AND NOT c.do_not_contact
        AND c.public_email IS NOT NULL
        AND c.lead_score >= p_min_score
        AND EXISTS (
          SELECT 1 FROM acq.lead_research r
           WHERE r.lead_id = c.id AND r.is_current
        )
        AND NOT acq.is_suppressed(c.public_email::text, c.domain, NULL, c.id)
        -- idempotent: one initial email per lead, ever
        AND NOT EXISTS (
          SELECT 1 FROM acq.emails e WHERE e.lead_id = c.id AND e.step_no = 0
        )
        AND (c.locked_at IS NULL
             OR c.locked_at < now() - make_interval(mins => p_stale_lock_minutes))
      ORDER BY c.lead_score DESC, c.created_at
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
   )
  RETURNING l.*;
END;
$fn$;

-- ---------------------------------------------------------------------
-- acq.readiness() — "can this system safely send yet?"
--
-- Turns the pre-flight checklist into a query, so the answer is never a
-- matter of remembering. BLOCKER rows are conditions the workflows
-- themselves refuse to run past.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION acq.readiness()
RETURNS TABLE (severity text, check_name text, detail text)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v text;
  n int;
BEGIN
  -- ---- blockers: the send path refuses while these are unset -----------
  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'company.postal_address';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'BLOCKER', 'company.postal_address',
      'Empty. Workflow 50 throws rather than send mail with no postal address.';
  ELSE
    RETURN QUERY SELECT 'OK', 'company.postal_address', v;
  END IF;

  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'unsubscribe.base_url';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'BLOCKER', 'unsubscribe.base_url',
      'Empty. Deploy workflow 110 and set its public URL; an opt-out link that does not work is worse than none.';
  ELSE
    RETURN QUERY SELECT 'OK', 'unsubscribe.base_url', v;
  END IF;

  SELECT count(*) INTO n FROM acq.prompts WHERE active;
  IF n < 8 THEN
    RETURN QUERY SELECT 'BLOCKER', 'prompts',
      format('%s of 8 active. Run: python3 scripts/load_prompts.py | psql', n);
  ELSE
    RETURN QUERY SELECT 'OK', 'prompts', format('%s active', n);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.scoring_configs WHERE active) THEN
    RETURN QUERY SELECT 'BLOCKER', 'scoring_config', 'No active scoring config; compute_score() will fail.';
  ELSE
    RETURN QUERY SELECT 'OK', 'scoring_config',
      (SELECT version FROM acq.scoring_configs WHERE active);
  END IF;

  -- ---- warnings: it will run, but not as intended ----------------------
  SELECT count(*) INTO n
    FROM acq.settings s,
         LATERAL jsonb_array_elements_text(s.value) c
   WHERE s.key = 'product.capabilities_unverified';
  IF n > 0 THEN
    RETURN QUERY SELECT 'WARN', 'product.capabilities',
      format('%s capabilities are flagged unverified and will still be claimed to real clinics. Prune product.capabilities.', n);
  END IF;

  SELECT value #>> '{}' INTO v FROM acq.settings WHERE key = 'notify.telegram_chat_id';
  IF coalesce(btrim(v), '') = '' THEN
    RETURN QUERY SELECT 'WARN', 'notify.telegram_chat_id',
      'Empty. Hot-lead notifications and error alerts have nowhere to go.';
  ELSE
    RETURN QUERY SELECT 'OK', 'notify.telegram_chat_id', 'set';
  END IF;

  IF EXISTS (SELECT 1 FROM acq.mailboxes WHERE active AND warmup_started_on IS NULL) THEN
    RETURN QUERY SELECT 'WARN', 'mailbox.warmup',
      'warmup_started_on is unset, so the ramp caps sending at 5/day.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.markets WHERE enabled) THEN
    RETURN QUERY SELECT 'WARN', 'markets', 'No market is enabled; discovery will find nothing.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.discovery_tasks WHERE enabled) THEN
    RETURN QUERY SELECT 'WARN', 'discovery_tasks', 'No discovery task is enabled.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM acq.campaigns WHERE status = 'ACTIVE') THEN
    RETURN QUERY SELECT 'WARN', 'campaigns', 'No active campaign; nothing will be sent.';
  END IF;

  SELECT count(*) INTO n FROM acq.dead_letters WHERE resolved_at IS NULL;
  IF n > 0 THEN
    RETURN QUERY SELECT 'WARN', 'dead_letters', format('%s unresolved.', n);
  END IF;

  -- ---- informational ---------------------------------------------------
  RETURN QUERY
  SELECT 'INFO', 'outreach.auto_send_enabled',
         CASE WHEN (SELECT (value)::boolean FROM acq.settings WHERE key='outreach.auto_send_enabled')
              THEN 'ON — drafts send without review'
              ELSE 'OFF — every draft waits for approval (the intended starting state)' END;

  RETURN QUERY
  SELECT 'INFO', 'outreach.dry_run',
         CASE WHEN (SELECT (value)::boolean FROM acq.settings WHERE key='outreach.dry_run')
              THEN 'ON — nothing is actually sent'
              ELSE 'OFF — real mail will leave the building' END;

  RETURN QUERY SELECT 'INFO', 'leads',
    format('%s total, %s qualified, %s contacted',
      (SELECT count(*) FROM acq.leads),
      (SELECT count(*) FROM acq.leads WHERE status = 'QUALIFIED'),
      (SELECT count(*) FROM acq.leads WHERE last_contacted_at IS NOT NULL));
END;
$fn$;

COMMENT ON FUNCTION acq.readiness() IS
  'Pre-flight check. Any BLOCKER row means the send path will refuse to run.';
