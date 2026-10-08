import Link from "next/link";
import { query, queryOne } from "@/lib/db";
import { buildLeadQuery, stageOf, STAGES, SITE_LABEL, SERVICE_OPTIONS, type LeadRow } from "@/lib/leads";

export const dynamic = "force-dynamic";

type Totals = {
  total: number; new_week: number; hot: number; contacted: number; replies: number;
  meetings: number; proposals: number; won: number;
};

export default async function LeadsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const f = await searchParams;
  const { sql, params } = buildLeadQuery(f, 300);

  const [rows, totals, categories, areas] = await Promise.all([
    query<LeadRow>(sql, params),
    queryOne<Totals>(`
      SELECT count(*)::int                                                       AS total,
             count(*) FILTER (WHERE created_at > now() - interval '7 days')::int AS new_week,
             count(*) FILTER (WHERE priority = 'HOT')::int                       AS hot,
             count(*) FILTER (WHERE last_contacted_at IS NOT NULL)::int          AS contacted,
             count(*) FILTER (WHERE replied_at IS NOT NULL)::int                 AS replies,
             count(*) FILTER (WHERE status = 'DEMO_BOOKED')::int                 AS meetings,
             count(*) FILTER (WHERE proposal_sent_at IS NOT NULL)::int           AS proposals,
             count(*) FILTER (WHERE status = 'CUSTOMER')::int                    AS won
        FROM acq.v_lead_list`),
    query<{ v: string }>(`SELECT DISTINCT category AS v FROM acq.v_lead_list WHERE category IS NOT NULL ORDER BY 1`),
    query<{ v: string }>(`SELECT DISTINCT area AS v FROM acq.v_lead_list WHERE area IS NOT NULL ORDER BY 1`),
  ]);

  const t = totals ?? { total: 0, new_week: 0, hot: 0, contacted: 0, replies: 0, meetings: 0, proposals: 0, won: 0 };
  const conversion = t.contacted ? ((100 * t.won) / t.contacted).toFixed(1) : "0";
  const exportHref = "/leads/export?" + new URLSearchParams(
    Object.entries(f).filter(([, v]) => v) as [string, string][]).toString();

  return (
    <main>
      <header className="top">
        <h1>Leads</h1>
        <span className="sub">
          <Link href="/">Pipeline</Link> · <Link href="/outreach">Website outreach</Link>
        </span>
      </header>

      <div className="tiles">
        <Tile label="Total leads" value={t.total} />
        <Tile label="New this week" value={t.new_week} />
        <Tile label="Hot" value={t.hot} tone="bad" />
        <Tile label="Contacted" value={t.contacted} />
        <Tile label="Replies" value={t.replies} />
        <Tile label="Meetings" value={t.meetings} tone="good" />
        <Tile label="Proposals" value={t.proposals} tone="good" />
        <Tile label="Won" value={t.won} tone="good" />
        <Tile label="Conversion" value={`${conversion}%`} />
      </div>

      <form className="filters" method="get">
        <input name="q" placeholder="Business name" defaultValue={f.q ?? ""} aria-label="Business name" />
        <select name="category" defaultValue={f.category ?? ""} aria-label="Industry">
          <option value="">All industries</option>
          {categories.map((c) => <option key={c.v} value={c.v}>{c.v.toLowerCase().replace(/_/g, " ")}</option>)}
        </select>
        <select name="area" defaultValue={f.area ?? ""} aria-label="Area">
          <option value="">All areas</option>
          {areas.map((a) => <option key={a.v} value={a.v}>{a.v}</option>)}
        </select>
        <select name="priority" defaultValue={f.priority ?? ""} aria-label="Priority">
          <option value="">Any priority</option>
          {["HOT", "HIGH", "MEDIUM", "LOW"].map((p) => <option key={p} value={p}>{p}</option>)}
        </select>
        <select name="site" defaultValue={f.site ?? ""} aria-label="Website status">
          <option value="">Any website</option>
          {Object.entries(SITE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <select name="service" defaultValue={f.service ?? ""} aria-label="Service opportunity">
          <option value="">Any opportunity</option>
          {SERVICE_OPTIONS.map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <select name="stage" defaultValue={f.stage ?? ""} aria-label="Lead status">
          <option value="">Active leads</option>
          {Object.keys(STAGES).map((s) => <option key={s} value={s}>{s.toLowerCase()}</option>)}
        </select>
        <input name="min" type="number" min={0} max={100} placeholder="Min score" defaultValue={f.min ?? ""} aria-label="Minimum score" />
        <input name="since" type="date" defaultValue={f.since ?? ""} aria-label="Found since" />
        <select name="sort" defaultValue={f.sort ?? "score"} aria-label="Sort">
          <option value="score">Sort: score</option>
          <option value="reviews">Sort: reviews</option>
          <option value="newest">Sort: newest</option>
        </select>
        <button className="primary" type="submit">Apply</button>
        <Link className="btn-link" href="/leads">Clear</Link>
        <a className="btn-link" href={exportHref}>Export CSV</a>
      </form>

      <div className="panel scroll">
        <table>
          <thead>
            <tr><th>Business</th><th>Type</th><th>Area</th><th>Score</th><th>Website</th>
                <th>Pitch</th><th>Google</th><th>Stage</th><th>Channel</th></tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr><td colSpan={9} className="empty">No leads match these filters. Clear them to see everything.</td></tr>
            )}
            {rows.map((l) => (
              <tr key={l.id}>
                <td><Link href={`/leads/${l.id}`}>{l.business_name}</Link></td>
                <td>{l.category?.toLowerCase().replace(/_/g, " ") ?? "—"}</td>
                <td>{[l.area, l.city].filter(Boolean).join(", ") || "—"}</td>
                <td className="num"><span className="score">{l.lead_score}</span>{" "}
                  <span className={`badge prio-${l.priority.toLowerCase()}`}>{l.priority}</span></td>
                <td>{SITE_LABEL[l.website_status ?? ""] ?? "—"}</td>
                <td>{l.service_label ?? "—"}{l.complexity && <span className="muted"> · {l.complexity}</span>}</td>
                <td className="num">{l.rating ? `${Number(l.rating).toFixed(1)}★ (${l.review_count ?? 0})` : "—"}</td>
                <td><span className="badge">{stageOf(l.status).toLowerCase()}</span></td>
                <td>{l.best_channel.toLowerCase().replace("_", " ")}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="hint" style={{ marginTop: ".6rem" }}>Showing up to 300. Export includes every match.</p>
    </main>
  );
}

function Tile({ label, value, tone }: { label: string; value: number | string; tone?: "good" | "bad" }) {
  return (
    <div className="tile">
      <div className="label">{label}</div>
      <div className={`value${tone ? ` ${tone}` : ""}`}>{value}</div>
    </div>
  );
}
