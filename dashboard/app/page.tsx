import { query, queryOne } from "@/lib/db";
import { approveDraftForm, rejectDraftForm } from "./actions";

// Always read live state; a cached pipeline view is a misleading one.
export const dynamic = "force-dynamic";

type Overview = {
  total_leads: number; qualified_leads: number; emails_sent: number;
  replies: number; interested: number; demos: number; customers: number;
  opt_outs: number; bounces: number; pending_approvals: number;
  open_dead_letters: number; reply_rate_pct: string; conversion_rate_pct: string;
};
type FunnelRow = { stage: string; leads: number; avg_score: number | null };
type Deliverability = {
  mailbox: string; from_email: string; sent_today: number;
  effective_daily_cap: number; bounce_rate_pct: string;
  complaint_rate_pct: string; reply_rate_pct: string; sent_30d: number;
};
type ApprovalRow = {
  id: string; kind: string; title: string; ai_confidence: string | null;
  requested_at: string; clinic_name: string | null; city: string | null;
  lead_score: number | null; public_email: string | null;
  payload: { subject?: string; body_text?: string; reason?: string | null;
             to_email?: string; questions?: string[]; draft?: string };
};
type LeadRow = {
  id: string; clinic_name: string; city: string | null; area: string | null;
  category: string | null; lead_score: number; status: string; stage: string;
  public_email: string | null; last_email_sent_at: string | null;
  last_reply_at: string | null; last_reply_class: string | null;
  next_follow_up_at: string | null; ai_pain_point: string | null;
};

const STAGES = ["NEW", "QUALIFIED", "CONTACTED", "REPLIED", "INTERESTED", "DEMO", "CUSTOMER"];

function fmtDate(v: string | null) {
  if (!v) return "—";
  return new Date(v).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}
function pct(v: string | null | undefined) {
  return v == null ? "0" : Number(v).toFixed(2);
}

export default async function Page() {
  const [overview, funnel, deliverability, approvals, leads] = await Promise.all([
    queryOne<Overview>("SELECT * FROM acq.v_overview"),
    query<FunnelRow>("SELECT * FROM acq.v_funnel ORDER BY stage"),
    query<Deliverability>("SELECT * FROM acq.v_deliverability"),
    query<ApprovalRow>("SELECT * FROM acq.v_approval_queue LIMIT 25"),
    query<LeadRow>(
      `SELECT * FROM acq.v_lead_dashboard
        WHERE status NOT IN ('REJECTED','INVALID')
        ORDER BY lead_score DESC, created_at DESC LIMIT 60`,
    ),
  ]);

  const byStage = Object.fromEntries(funnel.map((f) => [f.stage, f.leads]));
  const mb = deliverability[0];

  // Surface the two numbers that decide whether to keep sending at all.
  const warnings: string[] = [];
  if (mb && Number(mb.bounce_rate_pct) > 2)
    warnings.push(`Bounce rate ${pct(mb.bounce_rate_pct)}% — pause and clean the list.`);
  if (mb && Number(mb.complaint_rate_pct) > 0.1)
    warnings.push(`Complaint rate ${pct(mb.complaint_rate_pct)}% — stop sending now.`);
  if (overview && Number(overview.open_dead_letters) > 0)
    warnings.push(`${overview.open_dead_letters} unresolved dead letters.`);

  return (
    <main>
      <header className="top">
        <h1>Acquisition pipeline</h1>
        <span className="sub">Clinibot · Zenvexa</span>
      </header>

      {warnings.map((w) => (
        <div className="warnbar" key={w}>{w}</div>
      ))}

      <h2>Overview</h2>
      <div className="tiles">
        <Tile label="Total leads"   value={overview?.total_leads} />
        <Tile label="Qualified"     value={overview?.qualified_leads} />
        <Tile label="Emails sent"   value={overview?.emails_sent} />
        <Tile label="Replies"       value={overview?.replies} />
        <Tile label="Interested"    value={overview?.interested} tone="good" />
        <Tile label="Demos"         value={overview?.demos} tone="good" />
        <Tile label="Customers"     value={overview?.customers} tone="good" />
        <Tile label="Reply rate"    value={`${pct(overview?.reply_rate_pct)}%`} />
        <Tile label="Opt-outs"      value={overview?.opt_outs} tone="warn" />
        <Tile label="Bounces"       value={overview?.bounces} tone="warn" />
      </div>

      <h2>Pipeline</h2>
      <div className="funnel">
        {STAGES.map((s) => (
          <div className="stage" key={s}>
            <div className="n">{byStage[s] ?? 0}</div>
            <div className="s">{s}</div>
          </div>
        ))}
      </div>

      <h2>Deliverability</h2>
      <div className="panel scroll">
        <table>
          <thead>
            <tr>
              <th>Mailbox</th><th>From</th><th>Today</th><th>Sent 30d</th>
              <th>Bounce</th><th>Complaint</th><th>Reply</th>
            </tr>
          </thead>
          <tbody>
            {deliverability.length === 0 && (
              <tr><td colSpan={7} className="empty">No mailbox configured.</td></tr>
            )}
            {deliverability.map((d) => (
              <tr key={d.mailbox}>
                <td>{d.mailbox}</td>
                <td>{d.from_email}</td>
                <td className="num">{d.sent_today} / {d.effective_daily_cap}</td>
                <td className="num">{d.sent_30d}</td>
                <td className="num" style={{ color: Number(d.bounce_rate_pct) > 2 ? "var(--bad)" : undefined }}>
                  {pct(d.bounce_rate_pct)}%
                </td>
                <td className="num" style={{ color: Number(d.complaint_rate_pct) > 0.1 ? "var(--bad)" : undefined }}>
                  {pct(d.complaint_rate_pct)}%
                </td>
                <td className="num">{pct(d.reply_rate_pct)}%</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2>Waiting for you ({approvals.length})</h2>
      <div className="panel">
        {approvals.length === 0 && (
          <div className="empty">Nothing to approve.</div>
        )}
        {approvals.map((a) => (
          <div className="approval" key={a.id}>
            <div className="who">
              {a.clinic_name ?? "—"}{" "}
              <span className="badge">{a.kind}</span>{" "}
              {a.lead_score != null && <span className="score">{a.lead_score}/100</span>}
            </div>
            <div className="meta">
              {[a.city, a.public_email,
                a.ai_confidence != null ? `confidence ${Number(a.ai_confidence).toFixed(2)}` : null,
                a.payload?.reason ?? null,
                fmtDate(a.requested_at)]
                .filter(Boolean).join(" · ")}
            </div>

            {a.payload?.subject && (
              <pre>{`Subject: ${a.payload.subject}\n\n${a.payload.body_text ?? ""}`}</pre>
            )}
            {!a.payload?.subject && a.payload?.draft && <pre>{a.payload.draft}</pre>}
            {!!a.payload?.questions?.length && (
              <pre>{a.payload.questions.map((q) => `• ${q}`).join("\n")}</pre>
            )}

            <div className="actions">
              {/* Approving queues the email for workflow 50 — it still passes
                  through every send limit rather than going out immediately. */}
              <form action={approveDraftForm}>
                <input type="hidden" name="approvalId" value={a.id} />
                <button className="primary" type="submit">Approve</button>
              </form>
              <form action={rejectDraftForm}>
                <input type="hidden" name="approvalId" value={a.id} />
                <button type="submit">Reject</button>
              </form>
            </div>
          </div>
        ))}
      </div>

      <h2>Leads</h2>
      <div className="panel scroll">
        <table>
          <thead>
            <tr>
              <th>Clinic</th><th>Location</th><th>Type</th><th>Score</th>
              <th>Status</th><th>Contact</th><th>Last email</th>
              <th>Last reply</th><th>Next</th><th>AI read</th>
            </tr>
          </thead>
          <tbody>
            {leads.length === 0 && (
              <tr><td colSpan={10} className="empty">No leads yet. Run workflow 10.</td></tr>
            )}
            {leads.map((l) => (
              <tr key={l.id}>
                <td>{l.clinic_name}</td>
                <td>{[l.area, l.city].filter(Boolean).join(", ") || "—"}</td>
                <td>{l.category ?? "—"}</td>
                <td className="num score">{l.lead_score}</td>
                <td><span className="badge">{l.status}</span></td>
                <td>{l.public_email ?? "—"}</td>
                <td>{fmtDate(l.last_email_sent_at)}</td>
                <td>
                  {fmtDate(l.last_reply_at)}
                  {l.last_reply_class && <> <span className="badge">{l.last_reply_class}</span></>}
                </td>
                <td>{fmtDate(l.next_follow_up_at)}</td>
                <td style={{ maxWidth: "22rem", color: "var(--muted)", fontSize: ".82rem" }}>
                  {l.ai_pain_point ?? "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </main>
  );
}

function Tile({ label, value, tone }: {
  label: string; value: number | string | undefined; tone?: "good" | "warn" | "bad";
}) {
  return (
    <div className="tile">
      <div className="label">{label}</div>
      <div className={`value${tone ? ` ${tone}` : ""}`}>{value ?? 0}</div>
    </div>
  );
}
