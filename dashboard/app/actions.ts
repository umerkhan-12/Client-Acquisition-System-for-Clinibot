"use server";

import { revalidatePath } from "next/cache";
import { pool } from "@/lib/db";
import { requireUserForAction } from "@/lib/auth";

/**
 * Approve a drafted email.
 *
 * Deliberately does NOT set the email straight to SENT — it moves it to
 * READY_TO_SEND and lets workflow 50 pick it up, so the approved email still
 * passes through acq.claim_send_slots(): daily caps, sending window, warm-up
 * ramp and suppression all still apply. Approving is permission to send, not
 * an instruction to bypass the limits.
 */
export async function approveDraft(approvalId: string) {
  // Every action re-checks. A Server Action is its own POST endpoint, so
  // middleware having run for the page is not evidence that it ran for this.
  const { email: decidedBy } = await requireUserForAction();

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const { rows } = await client.query<{ email_id: string | null; lead_id: string | null }>(
      `UPDATE acq.approvals
          SET status = 'APPROVED', decided_at = now(), decided_by = $2
        WHERE id = $1::uuid AND status = 'PENDING'
        RETURNING email_id, lead_id`,
      [approvalId, decidedBy],
    );
    if (rows.length === 0) {
      await client.query("ROLLBACK");
      return { ok: false as const, error: "already decided" };
    }

    const { email_id: emailId, lead_id: leadId } = rows[0];

    if (emailId) {
      await client.query(
        `UPDATE acq.emails
            SET status = 'READY_TO_SEND', approved_by = $2, approved_at = now()
          WHERE id = $1::uuid AND status = 'PENDING_APPROVAL'`,
        [emailId, decidedBy],
      );
    }
    if (leadId) {
      // transition_lead() refuses this if the lead opted out in the meantime,
      // which is exactly the behaviour we want between drafting and approval.
      await client.query(
        `SELECT acq.transition_lead($1::uuid, 'APPROVED', 'approved_in_dashboard', 'HUMAN')`,
        [leadId],
      );
    }

    await client.query("COMMIT");
    revalidatePath("/");
    return { ok: true as const };
  } catch (err) {
    await client.query("ROLLBACK");
    return { ok: false as const, error: (err as Error).message };
  } finally {
    client.release();
  }
}

/** Reject a draft. The email is cancelled; the lead stays for a later attempt. */
export async function rejectDraft(approvalId: string) {
  const { email: decidedBy } = await requireUserForAction();

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const { rows } = await client.query<{ email_id: string | null }>(
      `UPDATE acq.approvals
          SET status = 'REJECTED', decided_at = now(), decided_by = $2
        WHERE id = $1::uuid AND status = 'PENDING'
        RETURNING email_id`,
      [approvalId, decidedBy],
    );
    if (rows.length === 0) {
      await client.query("ROLLBACK");
      return { ok: false as const, error: "already decided" };
    }

    if (rows[0].email_id) {
      await client.query(
        `UPDATE acq.emails
            SET status = 'CANCELLED', error = 'rejected in dashboard'
          WHERE id = $1::uuid AND status IN ('PENDING_APPROVAL','DRAFT')`,
        [rows[0].email_id],
      );
    }

    await client.query("COMMIT");
    revalidatePath("/");
    return { ok: true as const };
  } catch (err) {
    await client.query("ROLLBACK");
    return { ok: false as const, error: (err as Error).message };
  } finally {
    client.release();
  }
}

/** Never contact this clinic again. transition_lead() then blocks every path back. */
export async function markDoNotContact(leadId: string) {
  const { email } = await requireUserForAction();

  await pool.query(`UPDATE acq.leads SET do_not_contact = true WHERE id = $1::uuid`, [leadId]);
  await pool.query(`SELECT acq.stop_follow_ups($1::uuid, $2)`,
    [leadId, `marked do_not_contact in dashboard by ${email}`],
  );
  revalidatePath("/");
  return { ok: true as const };
}

// ---------------------------------------------------------------------
// Website outreach (the WEB offer, migration 011).
//
// These messages are sent by a person from their own phone, not by the
// system. The dashboard records what happened through three SECURITY DEFINER
// functions; acq_dashboard has no write access to the queue table itself, so
// it cannot, for instance, change the number a message goes to.
// ---------------------------------------------------------------------

type SqlResult = { ok: boolean; error?: string };

async function callJsonFn(sql: string, params: unknown[]): Promise<SqlResult> {
  const { rows } = await pool.query<{ r: SqlResult }>(sql, params);
  return rows[0]?.r ?? { ok: false, error: "no result" };
}

/** "I sent it." Stores the text actually sent and schedules the follow-up. */
export async function markManualSent(outreachId: string, finalMessage: string) {
  const { email } = await requireUserForAction();
  const r = await callJsonFn(
    `SELECT acq.mark_manual_sent($1::uuid, $2, $3) AS r`,
    [outreachId, finalMessage, email],
  );
  revalidatePath("/outreach");
  return r;
}

export async function skipManual(outreachId: string, reason: string) {
  const { email } = await requireUserForAction();
  const r = await callJsonFn(
    `SELECT acq.skip_manual($1::uuid, $2, $3) AS r`,
    [outreachId, reason, email],
  );
  revalidatePath("/outreach");
  return r;
}

const OUTCOMES = ["REPLIED", "INTERESTED", "NOT_INTERESTED", "OPT_OUT", "CUSTOMER", "WRONG_NUMBER"] as const;

/** Any outcome cancels the pending follow-up before anything else happens. */
export async function recordManualOutcome(leadId: string, outcome: string) {
  const { email } = await requireUserForAction();
  if (!(OUTCOMES as readonly string[]).includes(outcome)) {
    return { ok: false, error: "unknown outcome" };
  }
  const r = await callJsonFn(
    `SELECT acq.record_manual_outcome($1::uuid, $2, $3) AS r`,
    [leadId, outcome, email],
  );
  revalidatePath("/outreach");
  return r;
}

export async function markManualSentForm(formData: FormData): Promise<void> {
  const id = String(formData.get("outreachId") ?? "");
  if (id) await markManualSent(id, String(formData.get("message") ?? ""));
}

export async function skipManualForm(formData: FormData): Promise<void> {
  const id = String(formData.get("outreachId") ?? "");
  if (id) await skipManual(id, String(formData.get("reason") ?? "skipped in dashboard"));
}

export async function recordManualOutcomeForm(formData: FormData): Promise<void> {
  const id = String(formData.get("leadId") ?? "");
  const outcome = String(formData.get("outcome") ?? "");
  if (id && outcome) await recordManualOutcome(id, outcome);
}

// ---------------------------------------------------------------------
// Form adapters.
//
// `<form action={...}>` requires a handler returning void, while the functions
// above return a result so they can also be called programmatically. These thin
// wrappers bridge the two rather than making the real actions lose their return
// type.
// ---------------------------------------------------------------------

export async function approveDraftForm(formData: FormData): Promise<void> {
  const id = String(formData.get("approvalId") ?? "");
  if (id) await approveDraft(id);
}

export async function rejectDraftForm(formData: FormData): Promise<void> {
  const id = String(formData.get("approvalId") ?? "");
  if (id) await rejectDraft(id);
}

export async function markDoNotContactForm(formData: FormData): Promise<void> {
  const id = String(formData.get("leadId") ?? "");
  if (id) await markDoNotContact(id);
}

// ---------------------------------------------------------------------
// The lead workspace (/leads/[id], migration 014). Notes and stage moves go
// through SECURITY DEFINER functions; a stage move still passes through
// transition_lead(), so an opted-out lead cannot be moved back from here.
// ---------------------------------------------------------------------

const LEAD_STAGES = ["CONTACTED", "REPLIED", "MEETING", "PROPOSAL", "WON", "LOST"] as const;

export async function addLeadNoteForm(formData: FormData): Promise<void> {
  const { email } = await requireUserForAction();
  const id = String(formData.get("leadId") ?? "");
  const note = String(formData.get("note") ?? "");
  if (!id || !note.trim()) return;
  await callJsonFn(`SELECT acq.add_lead_note($1::uuid, $2, $3) AS r`, [id, note, email]);
  revalidatePath(`/leads/${id}`);
}

export async function setLeadStageForm(formData: FormData): Promise<void> {
  const { email } = await requireUserForAction();
  const id = String(formData.get("leadId") ?? "");
  const stage = String(formData.get("stage") ?? "");
  if (!id || !(LEAD_STAGES as readonly string[]).includes(stage)) return;
  await callJsonFn(`SELECT acq.set_lead_stage($1::uuid, $2, $3) AS r`, [id, stage, email]);
  revalidatePath(`/leads/${id}`);
  revalidatePath("/leads");
}

// ---------------------------------------------------------------------
// One-click WhatsApp (migration 015). The button only queues; workflow 47
// sends at a safe pace through the database's claimer. Every entry point
// re-checks the signed-in user, like the actions above.
// ---------------------------------------------------------------------

export async function queueWhatsAppForm(formData: FormData): Promise<void> {
  const { email } = await requireUserForAction();
  const id = String(formData.get("outreachId") ?? "");
  if (!id) return;
  await callJsonFn(`SELECT acq.queue_whatsapp_send($1::uuid, $2, $3) AS r`,
    [id, String(formData.get("message") ?? ""), email]);
  revalidatePath("/outreach");
}

export async function unqueueWhatsAppForm(formData: FormData): Promise<void> {
  const { email } = await requireUserForAction();
  const id = String(formData.get("outreachId") ?? "");
  if (!id) return;
  await callJsonFn(`SELECT acq.unqueue_whatsapp_send($1::uuid, $2) AS r`, [id, email]);
  revalidatePath("/outreach");
}

const FAILURE_ACTIONS = ["RETRY", "SENT_BY_HAND", "BACK_TO_MANUAL"] as const;

export async function resolveWhatsAppFailureForm(formData: FormData): Promise<void> {
  const { email } = await requireUserForAction();
  const id = String(formData.get("outreachId") ?? "");
  const action = String(formData.get("action") ?? "");
  if (!id || !(FAILURE_ACTIONS as readonly string[]).includes(action)) return;
  await callJsonFn(`SELECT acq.resolve_whatsapp_failure($1::uuid, $2, $3) AS r`, [id, action, email]);
  revalidatePath("/outreach");
}
