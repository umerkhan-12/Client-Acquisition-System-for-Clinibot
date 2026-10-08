"use client";

import { useState } from "react";
import { markManualSentForm, skipManualForm } from "../actions";

export type OutreachRow = {
  id: string; lead_id: string; step_no: number; channel: "WHATSAPP" | "PHONE_CALL";
  to_value: string; message: string; draft_source: string;
  personalization_reason: string | null; business_name: string;
  category: string | null; area: string | null; city: string | null;
  lead_score: number; website: string | null; listing_url: string | null;
  rating: string | null; review_count: number | null;
  website_issues: string[] | null; due_at: string;
  // From acq.lead_intel() (migration 013); absent on older rows.
  service_label?: string | null; complexity?: string | null;
  why?: string | null; priority?: string | null;
};

const ISSUE_LABELS: Record<string, string> = {
  site_unreachable: "site does not load",
  site_parked: "parked / under construction",
  no_https: "not secure (no https)",
  not_mobile_friendly: "not mobile-friendly",
  slow_or_heavy: "slow or heavy",
  outdated: "looks outdated",
  no_contact_cta: "no call / WhatsApp / form",
};

/**
 * One message to send by hand. The text is editable: whatever is in the box
 * when "Mark as sent" is pressed is what gets recorded, so the log matches
 * what the business actually received.
 */
export function SendCard({ row }: { row: OutreachRow }) {
  const [text, setText] = useState(row.message);
  const [copied, setCopied] = useState(false);

  const digits = row.to_value.replace(/[^0-9]/g, "");
  const waHref = `https://wa.me/${digits}?text=${encodeURIComponent(text)}`;

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* clipboard refused: the text is still selectable in the box */
    }
  }

  const where = [row.area, row.city].filter(Boolean).join(", ");
  const rating = row.rating != null
    ? `★ ${Number(row.rating).toFixed(1)}${row.review_count ? ` (${row.review_count})` : ""}`
    : null;
  const site = row.website
    ? (row.website_issues?.length
        ? row.website_issues.map((i) => ISSUE_LABELS[i] ?? i).join(", ")
        : "has a website")
    : "no website";

  return (
    <div className="approval">
      <div className="who">
        {row.business_name}{" "}
        <span className="badge">{row.step_no === 0 ? "FIRST MESSAGE" : "FOLLOW-UP"}</span>{" "}
        <span className="score">{row.lead_score}/100</span>
      </div>
      <div className="meta">
        {[row.category?.toLowerCase().replace(/_/g, " "), where, rating, site,
          row.draft_source === "TEMPLATE" ? "template draft" : null]
          .filter(Boolean).join(" · ")}
        {row.listing_url && (
          <> · <a href={row.listing_url} target="_blank" rel="noreferrer">listing</a></>
        )}
      </div>

      {(row.service_label || row.why) && (
        <div className="intel">
          {row.service_label && (
            <div>
              <b>Pitch:</b> {row.service_label}
              {row.complexity && <span className="badge">{row.complexity} effort</span>}
              {row.priority && <span className={`badge prio-${row.priority.toLowerCase()}`}>{row.priority}</span>}
            </div>
          )}
          {row.why && <div className="why">Why: {row.why}</div>}
        </div>
      )}

      <textarea
        className="msg"
        value={text}
        onChange={(e) => setText(e.target.value)}
        rows={Math.min(10, Math.max(4, Math.ceil(text.length / 80)))}
        aria-label={`Message to ${row.business_name}`}
      />

      <div className="actions wrap">
        {row.channel === "WHATSAPP" ? (
          <a className="btn primary" href={waHref} target="_blank" rel="noreferrer">
            Open in WhatsApp
          </a>
        ) : (
          <a className="btn primary" href={`tel:${row.to_value}`}>Call {row.to_value}</a>
        )}
        <button type="button" onClick={copy}>{copied ? "Copied" : "Copy text"}</button>
        <span className="num-label">{row.to_value}</span>

        <span className="spacer" />

        <form action={markManualSentForm}>
          <input type="hidden" name="outreachId" value={row.id} />
          <input type="hidden" name="message" value={text} />
          <button type="submit">Mark as sent</button>
        </form>
        <form action={skipManualForm}>
          <input type="hidden" name="outreachId" value={row.id} />
          <input type="hidden" name="reason" value="skipped in dashboard" />
          <button type="submit">Skip</button>
        </form>
      </div>
    </div>
  );
}
