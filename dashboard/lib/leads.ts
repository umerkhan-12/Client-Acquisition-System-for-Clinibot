/**
 * Filters for the lead list, shared by /leads and its CSV export so the file
 * always contains exactly the rows on screen. Every value reaches SQL as a
 * $n parameter; only the whitelisted sort keys are ever spliced in.
 */

export type LeadRow = {
  id: string; business_name: string; offer: string; category: string | null;
  area: string | null; city: string | null; lead_score: number; status: string;
  website: string | null; listing_url: string | null; created_at: string;
  rating: string | null; review_count: number | null; website_status: string | null;
  platform: string | null; opportunities: { code: string; detail: string; evidence: string | null }[] | null;
  recommended_service: string | null; service_label: string | null; complexity: string | null;
  why: string | null; priority: string; best_channel: string;
  phone: string | null; whatsapp: string | null; public_email: string | null; address: string | null;
  proposal_sent_at: string | null; last_contacted_at: string | null; replied_at: string | null;
};

/** The sales stages a person thinks in, mapped to the system's statuses. */
export const STAGES: Record<string, string[]> = {
  NEW:       ["NEW", "RESEARCHING"],
  QUALIFIED: ["QUALIFIED", "READY_FOR_REVIEW", "APPROVED"],
  CONTACTED: ["CONTACTED", "FOLLOW_UP_1", "FOLLOW_UP_2", "FOLLOW_UP_3"],
  REPLIED:   ["REPLIED", "LATER"],
  INTERESTED:["INTERESTED", "DEMO_REQUESTED"],
  MEETING:   ["DEMO_BOOKED"],
  WON:       ["CUSTOMER"],
  LOST:      ["NOT_INTERESTED", "REJECTED", "INVALID", "BOUNCED", "OPTED_OUT", "DO_NOT_CONTACT"],
};

export function stageOf(status: string): string {
  for (const [stage, statuses] of Object.entries(STAGES)) if (statuses.includes(status)) return stage;
  return status;
}

const SORTS: Record<string, string> = {
  score:   "lead_score DESC, review_count DESC NULLS LAST",
  newest:  "created_at DESC",
  reviews: "review_count DESC NULLS LAST, lead_score DESC",
};

export type Filters = Record<string, string | undefined>;

export function buildLeadQuery(f: Filters, limit: number | null) {
  const where: string[] = [];
  const params: unknown[] = [];
  const add = (sql: string, v: unknown) => { params.push(v); where.push(sql.replace("?", `$${params.length}`)); };

  if (f.q)        add("business_name ILIKE ?", `%${f.q}%`);
  if (f.offer)    add("offer = ?", f.offer);
  if (f.category) add("category = ?", f.category);
  if (f.city)     add("city = ?", f.city);
  if (f.area)     add("area = ?", f.area);
  if (f.priority) add("priority = ?", f.priority);
  if (f.site)     add("website_status = ?", f.site);
  if (f.service)  add("recommended_service = ?", f.service);
  if (f.min && Number.isFinite(Number(f.min))) add("lead_score >= ?", Number(f.min));
  if (f.since && /^\d{4}-\d{2}-\d{2}$/.test(f.since)) add("created_at >= ?::date", f.since);
  if (f.stage && STAGES[f.stage]) add("status = ANY(?::acq.lead_status[])", STAGES[f.stage]);
  else where.push("status NOT IN ('REJECTED','INVALID','OPTED_OUT','DO_NOT_CONTACT')");

  const order = SORTS[f.sort ?? "score"] ?? SORTS.score;
  const sql = `SELECT * FROM acq.v_lead_list
    ${where.length ? "WHERE " + where.join(" AND ") : ""}
    ORDER BY ${order}${limit ? ` LIMIT ${Math.trunc(limit)}` : ""}`;
  return { sql, params };
}

/** Labels for codes shown to a person. */
export const SITE_LABEL: Record<string, string> = {
  NO_WEBSITE: "No website", SOCIAL_ONLY: "Social page only", NOT_CHECKED: "Not checked yet",
  BROKEN: "Does not load", WEAK: "Weak website", OK: "Website OK",
};
export const SERVICE_OPTIONS = [
  ["WEBSITE", "Website"], ["WEBSITE_ORDERING", "Website + ordering"], ["WEBSITE_BOOKING", "Website + booking"],
  ["WEBSITE_SHOP", "Website + shop"], ["REDESIGN", "Redesign"], ["ONLINE_ORDERING", "Ordering system"],
  ["BOOKING", "Booking system"], ["ECOMMERCE", "E-commerce"], ["WHATSAPP_INTEGRATION", "WhatsApp button"],
] as const;
