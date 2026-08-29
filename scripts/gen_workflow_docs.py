#!/usr/bin/env python3
"""
Generates docs/02-workflows.md from the workflow JSON itself.

The node tables are read out of n8n/workflows/*.json rather than typed by hand,
so the reference cannot drift from what actually runs. The narrative for each
workflow lives in NARRATIVE below.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
WF = ROOT / "n8n" / "workflows"
OUT = ROOT / "docs" / "02-workflows.md"

TYPE_LABEL = {
    "n8n-nodes-base.scheduleTrigger": "Schedule trigger",
    "n8n-nodes-base.executeWorkflowTrigger": "Sub-workflow trigger",
    "n8n-nodes-base.errorTrigger": "Error trigger",
    "n8n-nodes-base.emailReadImap": "IMAP trigger",
    "n8n-nodes-base.webhook": "Webhook",
    "n8n-nodes-base.postgres": "Postgres",
    "n8n-nodes-base.httpRequest": "HTTP",
    "n8n-nodes-base.code": "Code",
    "n8n-nodes-base.if": "IF",
    "n8n-nodes-base.switch": "Switch",
    "n8n-nodes-base.splitInBatches": "Loop",
    "n8n-nodes-base.emailSend": "SMTP send",
    "n8n-nodes-base.telegram": "Telegram",
    "n8n-nodes-base.executeWorkflow": "Call workflow",
    "n8n-nodes-base.wait": "Wait",
    "n8n-nodes-base.noOp": "No-op",
    "n8n-nodes-base.respondToWebhook": "Webhook response",
}

CRED_LABEL = {
    "postgres": "`acq-postgres`",
    "smtp": "`zenvexa-smtp`",
    "imap": "`zenvexa-imap`",
    "telegramApi": "`acq-telegram`",
    "httpHeaderAuth": "`gemini-api-key`",
    "httpQueryAuth": "`google-places-key`",
}

NARRATIVE = {
    "00_error_handler": (
        "Set this as the **Error Workflow** on every other workflow (Workflow "
        "settings → Error workflow). It is the reason section 24's \"never "
        "silently lose a lead or an email event\" holds: any execution that dies "
        "anywhere lands here.\n\n"
        "It distinguishes transient failures (a dropped socket, a 429, a 503) "
        "from real ones. Both are recorded; only real ones send a Telegram alert, "
        "because an alert channel that cries wolf gets muted, and then it protects "
        "nothing."),
    "01_ai_call": (
        "Every AI request in the system goes through here, which is what makes "
        "section 25's JSON contract enforceable in one place rather than five.\n\n"
        "Gemini is called with `responseMimeType: application/json` and the "
        "prompt's own `responseSchema`, so malformed output is rare to begin "
        "with. When it happens anyway, the retry is *corrective*: it shows the "
        "model the exact rejection reason and drops temperature to 0, which fixes "
        "far more failures than asking the same question twice. After two "
        "attempts it returns `ok: false` — deliberately not an exception, because "
        "a failed research call and a failed email call mean different things to "
        "their callers.\n\n"
        "Gemini's `responseSchema` only accepts a subset of JSON Schema, so "
        "unsupported keywords (`additionalProperties`, `maxLength`, `pattern`) are "
        "stripped from the schema before the call."),
    "10_lead_discovery": (
        "The ordering is the whole point. Text Search returns place IDs cheaply; "
        "**Place Details is the billed call**, and it runs only for businesses "
        "that survived `acq.filter_unknown_refs`. After the first pass most "
        "search results are already in the CRM, so this ordering is the "
        "difference between paying once per clinic and paying every month.\n\n"
        "OSM needs no such split — one Overpass call returns full tags — so the "
        "OSM branch goes straight to `upsert_lead`. Overpass is a free volunteer "
        "service: one call per area, a four-second pause between areas, and an "
        "honest User-Agent are the terms of using it."),
    "20_lead_qualification": (
        "Zero AI calls, by design. This is section 19's \"deterministic logic "
        "first\": most leads are rejected here for reasons that need no model and "
        "no network request — no contact channel, a hospital, a pharmacy, a score "
        "below threshold.\n\n"
        "A lead that qualifies but has no website goes to `READY_FOR_REVIEW` "
        "rather than forward. There is nothing public to write a specific email "
        "from, and the system will not send a generic one."),
    "30_ai_research": (
        "The only workflow that reads clinic websites, and the only place a "
        "hallucination can enter the pipeline.\n\n"
        "It fetches `robots.txt` first and honours `Disallow` for both `*` and "
        "its own agent; on any doubt it fetches nothing. It requests at most "
        "three specific pages (home, contact, about/services/team) — never a "
        "crawl — identifies itself honestly, and paces requests.\n\n"
        "Email addresses found verbatim on a clinic's own page are recorded with "
        "**that page's URL as evidence**, which is what makes them facts rather "
        "than guesses. An address on the clinic's own domain is preferred, since "
        "a stray address on a clinic site is more often the web designer's.\n\n"
        "Results cache for `ai.research_ttl_days` (90 by default), so no clinic "
        "is researched twice for free."),
    "40_personalization": (
        "Two things stand between the model and a real clinic's inbox.\n\n"
        "First a **free MX check** over Cloudflare DNS-over-HTTPS. A domain with "
        "no mail exchanger will hard-bounce, and hard bounces are the fastest way "
        "to wreck a young sending domain. A domain that fails is suppressed and "
        "the lead marked `INVALID`; a lookup that itself failed is treated as "
        "inconclusive rather than as evidence.\n\n"
        "Then the **guardrails** — a deterministic pass the prompt cannot talk "
        "its way past: banned hype phrases, length bounds, the unsubscribe token, "
        "no price, no medical claim, no invented statistic, no fabricated prior "
        "contact, at most one link, and a configured postal address. A failing "
        "draft becomes a review item, never a discarded one."),
    "50_outreach_send": (
        "The only workflow permitted to talk to SMTP. Initial emails and "
        "follow-ups both arrive as rows in `acq.emails`, so the daily cap applies "
        "to the operation as a whole rather than separately to each.\n\n"
        "`acq.claim_send_slots()` applies every limit in one transaction — daily "
        "and hourly caps, the sending window, sending days, per-domain limits, "
        "the warm-up ramp and suppression. `acq.is_sendable()` runs again "
        "immediately before the SMTP call, catching a reply or opt-out that "
        "arrived in the seconds between.\n\n"
        "Sends are spaced 40-160 seconds apart at random. A perfectly regular "
        "cadence looks like exactly what it is."),
    "60_inbox_monitor": (
        "Watches the outreach mailbox over IMAP — cheaper and more reliable at "
        "this volume than provider webhooks, and it sees replies *and* bounces on "
        "one connection.\n\n"
        "Its most important property: **`acq.record_reply()` runs before "
        "classification is attempted.** Follow-ups stop the moment a human reply "
        "is recognised, whatever it says and whether or not Gemini is reachable. "
        "An AI outage can never cause someone who replied to keep receiving mail.\n\n"
        "Bounces are separated into permanent (`5.x.x`, suppresses the address) "
        "and temporary (`4.x.x`, recorded only). Auto-replies are logged and the "
        "sequence continues — an out-of-office is not a reply. Mail that matches "
        "no lead still gets a durable record."),
    "70_reply_classification": (
        "Routes an inbound reply into one of five outcomes. Two safety rules "
        "override the model's own choice:\n\n"
        "- If the classifier reports *any* opt-out signal, the class becomes "
        "`OPT_OUT` regardless of what it actually chose. A message that asks a "
        "question *and* asks to be removed has asked to be removed.\n"
        "- Confidence below `ai.min_classification_confidence` forces human "
        "escalation.\n\n"
        "An interested prospect who also asks something a human must answer is "
        "still routed as hot — the notification carries the open question rather "
        "than burying it in an approval queue."),
    "80_followup_engine": (
        "Generates follow-ups; never sends them. It writes rows into "
        "`acq.emails` and workflow 50 does the sending, which is what keeps one "
        "choke point for all outbound mail.\n\n"
        "`acq.due_follow_ups()` already excludes replied, opted-out, bounced and "
        "over-cap leads, so nothing here re-checks them. The guardrails are tuned "
        "for the specific ways follow-ups go wrong: filler openers (\"just "
        "following up\"), guilt (\"I haven't heard back\"), false urgency, and "
        "repeating the previous email. A draft that fails is **skipped**, not "
        "retried — the sequence simply ends a step early."),
    "90_hot_lead_notification": (
        "Produces the notification you actually read on a phone. If the briefing "
        "model fails, it still notifies with the raw reply: a hot lead going "
        "unannounced because a summariser timed out is the worst failure "
        "available here.\n\n"
        "A unique `dedupe_key` per (lead, reply) means a retried execution cannot "
        "notify twice.\n\n"
        "Auto-reply requires four things at once: `outreach.auto_reply_enabled` "
        "on, the briefing judging the draft safe, a draft existing, and no open "
        "questions. It bypasses the send caps deliberately — replying to someone "
        "who wrote to you is not cold outreach."),
    "100_demo_crm_pipeline": (
        "Three independent paths in one workflow.\n\n"
        "**Booking webhook** — accepts Cal.com and Calendly shapes, matches the "
        "invitee address to a lead, records the booking, moves the lead to "
        "`DEMO_BOOKED` and cancels remaining follow-ups. A booking from an "
        "address you never emailed is still recorded, with a null `lead_id`.\n\n"
        "**Daily digest** at 18:00 — pipeline counts, spend, and deliverability, "
        "with explicit warnings when bounce rate exceeds 2% or complaint rate "
        "exceeds 0.1%.\n\n"
        "**Nightly sweep** at 02:00 — releases locks held by executions that "
        "died, un-sticks leads stranded in `RESEARCHING`, and expires stale "
        "approvals."),
    "110_unsubscribe": (
        "Small, and the most important workflow for staying legitimate.\n\n"
        "One click, no confirmation step, no login. Unsubscribing must be easier "
        "than replying or it is not a real opt-out. The token is a random 36-hex "
        "string on the email row, so the URL carries no personal data and cannot "
        "be guessed.\n\n"
        "**Workflow 50 refuses to send anything while `unsubscribe.base_url` is "
        "unset.** An opt-out link that does not work is worse than none at all."),
}


def describe(node):
    p = node.get("parameters", {})
    t = node["type"]
    if t == "n8n-nodes-base.postgres":
        q = p.get("query", "").strip()
        first = next((l.strip() for l in q.split("\n")
                      if l.strip() and not l.strip().startswith("--")), "")
        return f"`{first[:78]}`"
    if t == "n8n-nodes-base.httpRequest":
        url = re.sub(r"\{\{.*?\}\}", "…", str(p.get("url", "")))
        return f"`{p.get('method','GET')} {url[:70]}`"
    if t == "n8n-nodes-base.scheduleTrigger":
        expr = p["rule"]["interval"][0].get("expression", "")
        return f"cron `{expr}`"
    if t == "n8n-nodes-base.webhook":
        return f"`{p.get('httpMethod')} /{p.get('path')}`"
    if t == "n8n-nodes-base.switch":
        keys = [r.get("outputKey") for r in p.get("rules", {}).get("values", [])]
        return "routes: " + ", ".join(f"`{k}`" for k in keys) + ", `fallback`"
    if t == "n8n-nodes-base.splitInBatches":
        return f"batch size {p.get('batchSize')}"
    if t == "n8n-nodes-base.executeWorkflow":
        return f"→ {p['workflowId'].get('cachedResultName','')}"
    if t == "n8n-nodes-base.wait":
        return f"{p.get('amount')} {p.get('unit')}"
    return ""


def main():
    lines = [
        "# Workflow reference",
        "",
        "*Generated from `n8n/workflows/*.json` by `scripts/gen_workflow_docs.py`.*",
        "*Edit `n8n/build_workflows.py` and regenerate rather than editing this file.*",
        "",
        "Thirteen workflows: the ten stages the brief specifies, plus three pieces of",
        "infrastructure they all depend on — the error handler (00), the shared AI-call",
        "sub-workflow (01), and the unsubscribe webhook (110).",
        "",
        "**Credential names** referenced below are what to call them when you create",
        "them in n8n. No secret is stored in this repository; the ids in the JSON are",
        "placeholders you replace once on import.",
        "",
        "---",
        "",
        "## Contents",
        "",
    ]
    files = sorted(WF.glob("*.json"), key=lambda p: int(p.stem.split("_")[0]))
    for f in files:
        doc = json.loads(f.read_text())
        lines.append(f"- [{doc['name']}](#{doc['name'].lower().replace(' ', '-').replace('—','').replace('--','-')}) "
                     f"— `{f.name}`")
    lines += ["", "---", ""]

    for f in files:
        doc = json.loads(f.read_text())
        key = f.stem
        nodes = doc["nodes"]

        triggers = [n for n in nodes if "Trigger" in n["type"] or "webhook" in n["type"]
                    or "scheduleTrigger" in n["type"] or "emailReadImap" in n["type"]]
        creds = sorted({CRED_LABEL.get(c, c) for n in nodes
                        for c in n.get("credentials", {})})
        db_ops = [n for n in nodes if n["type"] == "n8n-nodes-base.postgres"]
        error_paths = [n["name"] for n in nodes
                       if n.get("onError") in ("continueErrorOutput", "continueRegularOutput")]
        retried = [n["name"] for n in nodes if n.get("retryOnFail")]

        lines += [
            f"## {doc['name']}",
            "",
            f"**File** `n8n/workflows/{f.name}` · **{len(nodes)} nodes**",
            "",
            NARRATIVE.get(key, ""),
            "",
            "**Trigger** — " + (", ".join(
                f"{TYPE_LABEL.get(t['type'], t['type'])} ({describe(t)})" for t in triggers)
                or "called by another workflow"),
            "",
            "**Credentials** — " + (", ".join(creds) or "none"),
            "",
            "| # | Node | Type | Detail |",
            "|---|---|---|---|",
        ]
        for i, n in enumerate(nodes, 1):
            lines.append(f"| {i} | {n['name']} | {TYPE_LABEL.get(n['type'], n['type'])} "
                         f"| {describe(n)} |")

        lines += ["", "**Database operations**", ""]
        if db_ops:
            for n in db_ops:
                note = n.get("notes", "")
                lines.append(f"- **{n['name']}** — {describe(n)}"
                             + (f"<br>{note}" if note else ""))
        else:
            lines.append("- none")

        lines += [
            "",
            "**Error handling** — "
            + (f"retries on: {', '.join(f'`{x}`' for x in retried)}. " if retried else "")
            + (f"continues past failure at: {', '.join(f'`{x}`' for x in error_paths)}. "
               if error_paths else "")
            + "Unhandled failures go to *ACQ 00 — Error Handler*, which writes an "
              "`acq.dead_letters` row and alerts.",
            "",
            "---",
            "",
        ]

    OUT.write_text("\n".join(lines))
    print(f"wrote {OUT.relative_to(ROOT)} ({len(lines)} lines) from {len(files)} workflows")


if __name__ == "__main__":
    main()
