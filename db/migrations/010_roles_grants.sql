-- =====================================================================
-- Migration 010: least-privilege roles for n8n and the dashboard
--
-- WHY THIS EXISTS
--
-- Migrations 001-009 contain no GRANT and no CREATE ROLE. Everything ran as
-- the owner, which was fine while the database was a container on the same
-- box as everything else. It stops being fine the moment the database is
-- Supabase and the dashboard is a Vercel function on the public internet:
-- the alternative to this file is both of them connecting as `postgres`.
--
-- Two roles, sized to what each actually does:
--
--   acq_n8n        runs the thirteen workflows. Full DML, EXECUTE on the
--                  functions, no DDL.
--   acq_dashboard  renders five views and decides on the approval queue.
--                  Cannot read acq.leads. Cannot read acq.opt_outs. Cannot
--                  read raw research. Cannot send.
--
-- NO PASSWORDS HERE. Both roles are created without one, so neither can
-- connect until somebody assigns credentials out of band:
--
--   ALTER ROLE acq_n8n       WITH PASSWORD '…';
--   ALTER ROLE acq_dashboard WITH PASSWORD '…';
--
-- Idempotent, like every migration here: re-run it after adding a table.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Roles. CREATE ROLE has no IF NOT EXISTS, so guard it.
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'acq_n8n') THEN
    CREATE ROLE acq_n8n LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'acq_dashboard') THEN
    CREATE ROLE acq_dashboard LOGIN;
  END IF;
END $$;

-- =====================================================================
-- The two functions the dashboard calls must be SECURITY DEFINER.
--
-- All 32 functions ship SECURITY INVOKER, which means the function body's
-- table access is checked against the *caller*. So granting acq_dashboard
-- EXECUTE on transition_lead() would achieve nothing unless it also had write
-- access to leads, status_transitions and follow_ups — which is exactly the
-- privilege this migration exists to withhold.
--
-- Making these two SECURITY DEFINER turns them into narrow, audited privileged
-- entry points: the dashboard can move a lead's state only in the ways the
-- function permits, and transition_lead() is precisely where the "a suppressed
-- lead may only move further from contact" invariant is enforced. That
-- invariant now applies to a caller that cannot bypass it by writing to the
-- table directly.
--
-- search_path is pinned on both. A SECURITY DEFINER function with a mutable
-- search_path is a privilege-escalation vector: a caller can put their own
-- schema first and have the body resolve to their table instead of ours.
-- =====================================================================
ALTER FUNCTION acq.transition_lead(uuid, acq.lead_status, text, acq.actor, text)
  SECURITY DEFINER
  SET search_path = acq, public, pg_temp;

ALTER FUNCTION acq.stop_follow_ups(uuid, text)
  SECURITY DEFINER
  SET search_path = acq, public, pg_temp;

-- warmup_daily_cap() is a third case, and a non-obvious one.
--
-- A view without security_invoker resolves its own *table* references as the
-- view's owner — but a function called inside that view still executes with
-- the caller's privileges. acq.v_deliverability calls warmup_daily_cap(), which
-- reads acq.mailboxes, so granting SELECT on the view was not enough:
--
--   ERROR:  permission denied for table mailboxes
--   CONTEXT: PL/pgSQL function acq.warmup_daily_cap(uuid)
--
-- It is a read-only computation over one row, so promoting it is safe. Worth
-- remembering when adding a view: a grant that looks sufficient is not, if the
-- view calls a function that touches a table.
ALTER FUNCTION acq.warmup_daily_cap(uuid)
  SECURITY DEFINER
  SET search_path = acq, public, pg_temp;

-- =====================================================================
-- acq_n8n — the workflow runner
-- =====================================================================
GRANT USAGE ON SCHEMA acq TO acq_n8n;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA acq TO acq_n8n;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA acq TO acq_n8n;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA acq TO acq_n8n;

-- Tables added by a later migration should not silently be unreadable.
ALTER DEFAULT PRIVILEGES IN SCHEMA acq
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO acq_n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA acq
  GRANT USAGE, SELECT ON SEQUENCES TO acq_n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA acq
  GRANT EXECUTE ON FUNCTIONS TO acq_n8n;

-- =====================================================================
-- acq_dashboard — read five views, decide on the queue, nothing else
-- =====================================================================
GRANT USAGE ON SCHEMA acq TO acq_dashboard;

-- Reading happens through views, never base tables. The views are plain
-- (no security_invoker), so they execute with their owner's rights: SELECT on
-- the view is sufficient and does NOT imply SELECT on acq.leads underneath.
-- That is the whole mechanism by which this role sees clinics but cannot dump
-- the leads table, the suppression list, or cached research.
GRANT SELECT ON
  acq.v_overview,
  acq.v_funnel,
  acq.v_lead_dashboard,
  acq.v_approval_queue,
  acq.v_deliverability
TO acq_dashboard;

-- Deciding on the queue. Column-level UPDATE, not table-level.
--
-- This is not fussiness. Table-level UPDATE on acq.emails would let a stolen
-- Vercel connection string rewrite `to_email` on an approved draft and
-- redirect real outbound mail. Naming the four columns the dashboard actually
-- writes removes that entirely.
GRANT SELECT                                            ON acq.approvals TO acq_dashboard;
GRANT UPDATE (status, decided_at, decided_by)           ON acq.approvals TO acq_dashboard;

GRANT SELECT                                            ON acq.emails    TO acq_dashboard;
GRANT UPDATE (status, approved_by, approved_at, error)  ON acq.emails    TO acq_dashboard;

-- markDoNotContact() sets exactly one column. `SELECT (id)` is required only
-- so the WHERE clause can resolve; it conveys nothing else about the row.
GRANT SELECT (id)             ON acq.leads TO acq_dashboard;
GRANT UPDATE (do_not_contact) ON acq.leads TO acq_dashboard;

GRANT EXECUTE ON FUNCTION acq.transition_lead(uuid, acq.lead_status, text, acq.actor, text)
  TO acq_dashboard;
GRANT EXECUTE ON FUNCTION acq.stop_follow_ups(uuid, text) TO acq_dashboard;

-- =====================================================================
-- Supabase hardening.
--
-- Supabase serves only the schemas listed in its API settings, and `acq` must
-- never be one of them — PostgREST over a table of scraped clinic contacts,
-- gated by RLS policies somebody has to get right every time, is the most
-- common way a Supabase project leaks.
--
-- Keeping it off that list is the real control. This is the second line:
-- should `acq` ever be exposed by accident, the anon and authenticated roles
-- still hold no privilege on anything inside it.
--
-- Guarded because these roles do not exist on a plain Postgres, which is what
-- the test suite runs against.
-- =====================================================================
DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA acq FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA acq FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA acq FROM %I', r);
      EXECUTE format('REVOKE ALL ON SCHEMA acq FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA acq REVOKE ALL ON TABLES FROM %I', r);
      RAISE NOTICE 'revoked all privileges on schema acq from %', r;
    END IF;
  END LOOP;
END $$;

COMMENT ON SCHEMA acq IS
  'Client acquisition system. NEVER add this schema to Supabase''s exposed-schema list — it holds scraped contact data and is reached only by acq_n8n and acq_dashboard over a pooled Postgres connection.';
