import Link from "next/link";
import { notFound } from "next/navigation";
import { query, queryOne } from "@/lib/db";
import { addLeadNoteForm, setLeadStageForm } from "../../actions";
import { stageOf, SITE_LABEL, type LeadRow } from "@/lib/leads";

export const dynamic = "force-dynamic";

type Draft = {
  id: string; step_no: number; channel: string; to_value: string; message: string;
  status: string; due_at: string | null; sent_at: string | null; queue: string;
};
type Activity = { id: string; activity_type: string; actor: string; summary: string | null; occurred_at: string };

const STAGE_BUTTONS: [string, string][] = [
  ["CONTACTED", "Contacted"], ["REPLIED", "Replied"], ["MEETING", "Meeting booked"],
  ["PROPOSAL", "Proposal sent"], ["WON", "Won"], ["LOST", "Lost"],
];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function when(v: string | null) {
  return v ? new Date(v).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" }) : "—";
}

export default async function LeadPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const [lead, drafts, activity] = await Promise.all([
    queryOne<LeadRow>(`SELECT * FROM acq.v_lead_list WHERE id = $1::uuid`, [id]),
    query<Draft>(
      `SELECT id, step_no, channel, to_value, message, status, due_at, sent_at, queue
         FROM acq.v_manual_outreach WHERE lead_id = $1::uuid ORDER BY step_no`, [id]),
    query<Activity>(
      `SELECT id, activity_type, actor, summary, occurred_at
         FROM acq.v_lead_activity WHERE lead_id = $1::uuid
        ORDER BY occurred_at DESC LIMIT 50`, [id]),
  ]);
  if (!lead) notFound();

  const wa = lead.whatsapp ?? lead.phone;
  const waLink = wa ? `https://wa.me/${wa.replace(/\D/g, "")}` : null;

  return (
    <main>
      <header className="top">
        <h1>{lead.business_name}</h1>
        <span className="sub"><Link href="/leads">← All leads</Link></span>
      </header>
      <p className="hint">
        {[lead.category?.toLowerCase().replace(/_/g, " "), lead.area, lead.city].filter(Boolean).join(" · ")}
        {" · "}found {when(lead.created_at)}
      </p>

      <div className="tiles">
        <div className="tile"><div className="label">Lead score</div>
          <div className="value">{lead.lead_score}</div></div>
        <div className="tile"><div className="label">Priority</div>
          <div className={`value${lead.priority === "HOT" ? " bad" : lead.priority === "HIGH" ? " warn" : ""}`}>{lead.priority}</div></div>
        <div className="tile"><div className="label">Stage</div>
          <div className="value">{stageOf(lead.status).toLowerCase()}</div></div>
        <div className="tile"><div className="label">Google</div>
          <div className="value">{lead.rating ? `${Number(lead.rating).toFixed(1)}★` : "—"}</div>
          <div className="muted">{lead.review_count ?? 0} reviews</div></div>
      </div>

      <div className="detail-grid">
        <section className="panel pad">
          <h2>Why this lead</h2>
          <p>{lead.why ?? "No analysis yet."}</p>
          <dl className="kv">
            <dt>Recommended</dt><dd>{lead.service_label ?? "—"}{lead.complexity && <span className="muted"> · {lead.complexity.toLowerCase()} effort</span>}</dd>
            <dt>Best channel</dt><dd>{lead.best_channel.toLowerCase().replace("_", " ")}</dd>
            <dt>Website</dt><dd>{SITE_LABEL[lead.website_status ?? ""] ?? "—"}{lead.platform && <span className="muted"> · {lead.platform}</span>}</dd>
          </dl>
          {lead.opportunities && lead.opportunities.length > 0 && (
            <>
              <h2>What&apos;s missing</h2>
              <ul className="opps">
                {lead.opportunities.map((o) => (
                  <li key={o.code}>{o.detail}{o.evidence && <span className="muted"> — {o.evidence}</span>}</li>
                ))}
              </ul>
            </>
          )}
        </section>

        <section className="panel pad">
          <h2>Contact</h2>
          <dl className="kv">
            <dt>Phone</dt><dd>{lead.phone ?? "—"}</dd>
            <dt>WhatsApp</dt><dd>{waLink ? <a href={waLink} target="_blank" rel="noreferrer">{wa}</a> : "—"}</dd>
            <dt>Email</dt><dd>{lead.public_email ? <a href={`mailto:${lead.public_email}`}>{lead.public_email}</a> : "—"}</dd>
            <dt>Website</dt><dd>{lead.website ? <a href={lead.website} target="_blank" rel="noreferrer">{lead.website}</a> : "—"}</dd>
            <dt>Maps</dt><dd>{lead.listing_url ? <a href={lead.listing_url} target="_blank" rel="noreferrer">Open listing</a> : "—"}</dd>
            <dt>Address</dt><dd>{lead.address ?? "—"}</dd>
          </dl>
        </section>
      </div>

      <h2>Move this lead</h2>
      <div className="actions wrap">
        {STAGE_BUTTONS.map(([stage, label]) => (
          <form key={stage} action={setLeadStageForm}>
            <input type="hidden" name="leadId" value={lead.id} />
            <input type="hidden" name="stage" value={stage} />
            <button type="submit" className={stage === "WON" ? "primary" : undefined}>{label}</button>
          </form>
        ))}
      </div>
      <p className="hint" style={{ marginTop: ".5rem" }}>
        A lead that asked not to be contacted can&apos;t be moved back; the button does nothing for it.
      </p>

      <h2>Drafted messages</h2>
      <div className="panel">
        {drafts.length === 0 && <div className="empty">No message drafted for this lead yet.</div>}
        {drafts.map((d) => (
          <div className="approval" key={d.id}>
            <div className="meta">
              {d.step_no === 0 ? "First message" : `Follow-up ${d.step_no}`} · {d.channel.toLowerCase()} to {d.to_value}
              {" · "}{d.sent_at ? `sent ${when(d.sent_at)}` : d.queue === "TO_SEND" ? "ready to send" : d.status.toLowerCase()}
            </div>
            <pre>{d.message}</pre>
          </div>
        ))}
      </div>
      {drafts.some((d) => d.queue === "TO_SEND") && (
        <p className="hint" style={{ marginTop: ".5rem" }}>Send it from <Link href="/outreach">Website outreach</Link>, which records it.</p>
      )}

      <h2>Notes and history</h2>
      <form action={addLeadNoteForm} className="note-form">
        <input type="hidden" name="leadId" value={lead.id} />
        <textarea className="msg" name="note" rows={3} maxLength={2000} placeholder="What happened, what they said, what to do next" required />
        <button className="primary" type="submit">Add note</button>
      </form>
      <div className="panel">
        {activity.length === 0 && <div className="empty">Nothing recorded yet.</div>}
        <ul className="timeline">
          {activity.map((a) => (
            <li key={a.id}>
              <span className="muted">{when(a.occurred_at)}</span>{" "}
              <span className="badge">{a.activity_type.toLowerCase().replace(/_/g, " ")}</span>{" "}
              {a.summary}
            </li>
          ))}
        </ul>
      </div>
    </main>
  );
}
