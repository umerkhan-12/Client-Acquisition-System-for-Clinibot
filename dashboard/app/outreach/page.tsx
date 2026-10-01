import Link from "next/link";
import { query, queryOne } from "@/lib/db";
import { recordManualOutcomeForm } from "../actions";
import { SendCard, type OutreachRow } from "./SendCard";

export const dynamic = "force-dynamic";

type WebOverview = {
  web_leads: number; web_qualified: number; to_send: number; sent_today: number;
  pitched_total: number; replied: number; interested: number; customers: number;
};
type SentRow = {
  id: string; lead_id: string; step_no: number; channel: string; to_value: string;
  business_name: string; area: string | null; sent_at: string; lead_status: string;
};

const OUTCOME_BUTTONS: [string, string][] = [
  ["INTERESTED", "Interested"],
  ["REPLIED", "Replied"],
  ["NOT_INTERESTED", "Not interested"],
  ["CUSTOMER", "Became a client"],
  ["OPT_OUT", "Asked to stop"],
  ["WRONG_NUMBER", "Wrong number"],
];

function ago(v: string) {
  const days = Math.floor((Date.now() - new Date(v).getTime()) / 86_400_000);
  return days <= 0 ? "today" : days === 1 ? "yesterday" : `${days} days ago`;
}

export default async function OutreachPage() {
  const [ov, toSend, awaiting] = await Promise.all([
    queryOne<WebOverview>("SELECT * FROM acq.v_web_overview"),
    query<OutreachRow>(
      `SELECT * FROM acq.v_manual_outreach
        WHERE queue = 'TO_SEND'
        ORDER BY step_no DESC, lead_score DESC, due_at
        LIMIT 40`,
    ),
    query<SentRow>(
      `SELECT DISTINCT ON (lead_id) id, lead_id, step_no, channel, to_value,
              business_name, area, sent_at, lead_status
         FROM acq.v_manual_outreach
        WHERE queue = 'AWAITING_REPLY'
        ORDER BY lead_id, sent_at DESC`,
    ),
  ]);
  awaiting.sort((a, b) => new Date(b.sent_at).getTime() - new Date(a.sent_at).getTime());

  return (
    <main>
      <header className="top">
        <h1>Website outreach</h1>
        <span className="sub">Messages you send by hand · <Link href="/">Clinibot pipeline</Link></span>
      </header>

      <div className="tiles">
        <Tile label="To send now" value={ov?.to_send} />
        <Tile label="Sent today" value={ov?.sent_today} />
        <Tile label="Pitched" value={ov?.pitched_total} />
        <Tile label="Replied" value={ov?.replied} />
        <Tile label="Interested" value={ov?.interested} tone="good" />
        <Tile label="Clients" value={ov?.customers} tone="good" />
        <Tile label="Website leads" value={ov?.web_leads} />
      </div>

      <h2>Send these ({toSend.length})</h2>
      <p className="hint">
        Read each message, change anything that doesn&apos;t sound like you, send it from your phone,
        then press <b>Mark as sent</b>. Send them a few minutes apart, not all at once.
      </p>
      <div className="panel">
        {toSend.length === 0 && (
          <div className="empty">
            Nothing to send. New drafts appear here when workflow 45 runs, up to the daily limit.
          </div>
        )}
        {toSend.map((r) => <SendCard key={r.id} row={r} />)}
      </div>

      <h2>Waiting for a reply ({awaiting.length})</h2>
      <p className="hint">
        When someone answers, record it here. Any answer cancels their follow-up.
      </p>
      <div className="panel scroll">
        <table>
          <thead>
            <tr><th>Business</th><th>Number</th><th>Last message</th><th>Record what happened</th></tr>
          </thead>
          <tbody>
            {awaiting.length === 0 && (
              <tr><td colSpan={4} className="empty">No messages waiting for a reply.</td></tr>
            )}
            {awaiting.map((r) => (
              <tr key={r.lead_id}>
                <td>{r.business_name}{r.area ? <span className="muted"> · {r.area}</span> : null}</td>
                <td className="num-label">{r.to_value}</td>
                <td>{r.step_no === 0 ? "First message" : "Follow-up"}, {ago(r.sent_at)}</td>
                <td>
                  <div className="actions wrap">
                    {OUTCOME_BUTTONS.map(([value, label]) => (
                      <form action={recordManualOutcomeForm} key={value}>
                        <input type="hidden" name="leadId" value={r.lead_id} />
                        <input type="hidden" name="outcome" value={value} />
                        <button type="submit" className={value === "INTERESTED" || value === "CUSTOMER" ? "primary" : undefined}>
                          {label}
                        </button>
                      </form>
                    ))}
                  </div>
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
  label: string; value: number | string | undefined; tone?: "good" | "warn";
}) {
  return (
    <div className="tile">
      <div className="label">{label}</div>
      <div className={`value${tone ? ` ${tone}` : ""}`}>{value ?? 0}</div>
    </div>
  );
}
