import { NextResponse, type NextRequest } from "next/server";
import { query } from "@/lib/db";
import { requireUserForAction } from "@/lib/auth";
import { buildLeadQuery, stageOf, SITE_LABEL, type LeadRow } from "@/lib/leads";

export const dynamic = "force-dynamic";

/**
 * CSV of the leads matching the same filters as /leads, every row, for a CRM
 * or a spreadsheet. Checked here as well as in middleware: a route handler is
 * its own endpoint, and this one hands out contact details.
 */
export async function GET(request: NextRequest) {
  try {
    await requireUserForAction();
  } catch {
    return new NextResponse("Sign in to export leads.", { status: 401 });
  }

  const f = Object.fromEntries(request.nextUrl.searchParams.entries());
  const { sql, params } = buildLeadQuery(f, null);
  const rows = await query<LeadRow>(sql, params);

  const cols: [string, (l: LeadRow) => unknown][] = [
    ["business_name", (l) => l.business_name],
    ["industry", (l) => l.category],
    ["area", (l) => l.area],
    ["city", (l) => l.city],
    ["address", (l) => l.address],
    ["phone", (l) => l.phone],
    ["whatsapp", (l) => l.whatsapp],
    ["email", (l) => l.public_email],
    ["website", (l) => l.website],
    ["maps_url", (l) => l.listing_url],
    ["google_rating", (l) => l.rating],
    ["google_reviews", (l) => l.review_count],
    ["website_status", (l) => SITE_LABEL[l.website_status ?? ""] ?? l.website_status],
    ["platform", (l) => l.platform],
    ["problems", (l) => (l.opportunities ?? []).map((o) => o.detail).join("; ")],
    ["recommended_service", (l) => l.service_label],
    ["complexity", (l) => l.complexity],
    ["why_good_prospect", (l) => l.why],
    ["lead_score", (l) => l.lead_score],
    ["priority", (l) => l.priority],
    ["best_channel", (l) => l.best_channel],
    ["stage", (l) => stageOf(l.status)],
    ["found_at", (l) => l.created_at],
  ];

  // Quote every field; double embedded quotes. A leading = + - @ is prefixed
  // with ' so a spreadsheet does not run a business name as a formula.
  const cell = (v: unknown) => {
    let s = v == null ? "" : String(v);
    if (/^[=+\-@]/.test(s)) s = "'" + s;
    return `"${s.replace(/"/g, '""')}"`;
  };
  const lines = [cols.map(([h]) => h).join(","), ...rows.map((l) => cols.map(([, get]) => cell(get(l))).join(","))];
  const stamp = new Date().toISOString().slice(0, 10);

  return new NextResponse("﻿" + lines.join("\r\n") + "\r\n", {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="zenvexa-leads-${stamp}.csv"`,
      "Cache-Control": "no-store",
    },
  });
}
