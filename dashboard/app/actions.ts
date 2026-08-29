"use server";

import { revalidatePath } from "next/cache";
import { pool } from "@/lib/db";

/**
 * Approve a drafted email.
 *
 * Deliberately does NOT set the email straight to SENT — it moves it to
 * READY_TO_SEND and lets workflow 50 pick it up, so the approved email still
 * passes through acq.claim_send_slots(): daily caps, sending window, warm-up
 * ramp and suppression all still apply. Approving is permission to send, not
 * an instruction to bypass the limits.
 */
export async function approveDraft(approvalId: string, decidedBy = "dashboard") {
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
export async function rejectDraft(approvalId: string, decidedBy = "dashboard") {
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
  await pool.query(`UPDATE acq.leads SET do_not_contact = true WHERE id = $1::uuid`, [leadId]);
  await pool.query(`SELECT acq.stop_follow_ups($1::uuid, 'marked do_not_contact in dashboard')`, [
    leadId,
  ]);
  revalidatePath("/");
  return { ok: true as const };
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
