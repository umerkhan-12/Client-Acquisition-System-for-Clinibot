#!/usr/bin/env node
/**
 * Runs the JavaScript inside the workflows' Code nodes against fixtures.
 *
 *     node scripts/test_code_nodes.mjs
 *
 * The SQL is type-checked and the workflow JSON is structurally validated, but
 * the Code nodes hold the logic most likely to be wrong: parsers, normalizers,
 * guardrails, bounce detection. Those never execute until n8n runs them against
 * a real clinic, which is a bad place to discover a mistake.
 *
 * This extracts the real `jsCode` from the committed workflow JSON — not a copy
 * — and runs it under a small shim of the n8n runtime, so a test failing here
 * means the deployed node is wrong.
 */
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const WF_DIR = path.join(ROOT, "n8n", "workflows");

// ---------------------------------------------------------------- loading

const workflows = {};
for (const f of readdirSync(WF_DIR).filter((f) => f.endsWith(".json"))) {
  workflows[f.replace(".json", "")] = JSON.parse(
    readFileSync(path.join(WF_DIR, f), "utf8"),
  );
}

function getCode(wfKey, nodeName) {
  const wf = workflows[wfKey];
  if (!wf) throw new Error(`no workflow ${wfKey}`);
  const node = wf.nodes.find((n) => n.name === nodeName);
  if (!node) throw new Error(`no node '${nodeName}' in ${wfKey}`);
  if (node.type !== "n8n-nodes-base.code")
    throw new Error(`'${nodeName}' is a ${node.type}, not a Code node`);
  return node.parameters.jsCode;
}

/**
 * Minimal n8n Code-node runtime: `$input`, `$('Other Node')`, `$execution`,
 * `$now`. Enough for runOnceForAllItems nodes, which is all of them here.
 */
function runNode(wfKey, nodeName, { input = [], nodes = {} } = {}) {
  const code = getCode(wfKey, nodeName);
  const wrap = (items) => ({
    all: () => items,
    first: () => items[0],
    last: () => items[items.length - 1],
  });
  const $input = wrap(input.map((j) => ({ json: j })));
  const $ = (name) => {
    if (!(name in nodes)) throw new Error(`test did not stub node '${name}'`);
    const v = nodes[name];
    return wrap((Array.isArray(v) ? v : [v]).map((j) => ({ json: j })));
  };
  const $execution = { id: "test-exec-1" };
  const $now = { toISO: () => "2026-08-29T00:00:00.000Z" };
  const fn = new Function("$input", "$", "$execution", "$now", code);
  return fn($input, $, $execution, $now);
}

// ----------------------------------------------------------------- runner

let passed = 0;
let failed = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    console.log(`  \x1b[32m✓\x1b[0m ${name}`);
    passed++;
  } catch (e) {
    console.log(`  \x1b[31m✗\x1b[0m ${name}\n      ${e.message}`);
    failed++;
    failures.push(name);
  }
}
function group(name) {
  console.log(`\n\x1b[1m${name}\x1b[0m`);
}
function eq(actual, expected, what = "value") {
  const a = JSON.stringify(actual), b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${what}: expected ${b}, got ${a}`);
}
function ok(cond, msg) {
  if (!cond) throw new Error(msg);
}
function throws(fn, match, msg) {
  try {
    fn();
  } catch (e) {
    if (match && !String(e.message).includes(match))
      throw new Error(`${msg}: threw "${e.message}", expected to mention "${match}"`);
    return;
  }
  throw new Error(msg || "expected a throw, got none");
}

// ============================================================ workflow 10

group("10 — Normalize OSM Results");

const osmTask = {
  market_code: "PK", city: "Karachi", area: "North Nazimabad",
  bbox: { lat: 24.94, lng: 67.04, radius_m: 3000 },
};
const osmSettings = { max_new: 60, user_agent: "ZenvexaBot/1.0" };

function normalizeOsm(elements) {
  return runNode("10_lead_discovery", "Normalize OSM Results", {
    input: [{ statusCode: 200, body: { elements } }],
    nodes: { "Build Overpass Query": osmTask, "Check Budget + Settings": osmSettings },
  });
}

test("maps a dentist node to a DENTAL tier-1 lead", () => {
  const out = normalizeOsm([{
    type: "node", id: 111, lat: 24.94, lon: 67.04,
    tags: { name: "Smile Dental", amenity: "dentist", phone: "021-3663-1122" },
  }]);
  eq(out.length, 1, "lead count");
  eq(out[0].json.category, "DENTAL", "category");
  eq(out[0].json.priority_tier, 1, "tier");
  eq(out[0].json.source_ref_type, "OSM_ID", "ref type");
  eq(out[0].json.source_ref, "node/111", "ref");
  eq(out[0].json.market_code, "PK", "market");
});

test("an OSM email carries provenance; a lead with none carries no email fields", () => {
  const out = normalizeOsm([
    { type: "node", id: 1, tags: { name: "A Dental", amenity: "dentist",
                                   "contact:email": "hi@a.pk" } },
    { type: "node", id: 2, tags: { name: "B Dental", amenity: "dentist" } },
  ]);
  const [a, b] = out.map((o) => o.json);
  eq(a.public_email, "hi@a.pk", "email");
  eq(a.email_source, "OSM", "email source");
  ok(a.email_evidence_url.includes("openstreetmap.org/node/1"), "evidence url must cite OSM");
  eq(b.public_email, null, "no email");
  eq(b.email_source, null, "no source when no email");
  eq(b.email_evidence_url, null, "no evidence when no email");
});

test("skips unnamed elements and hospitals", () => {
  const out = normalizeOsm([
    { type: "node", id: 1, tags: { amenity: "dentist" } },                       // no name
    { type: "node", id: 2, tags: { name: "City Hospital", amenity: "hospital" } },
    { type: "node", id: 3, tags: { name: "Real Clinic", amenity: "clinic" } },
  ]);
  eq(out.length, 1, "only the named non-hospital survives");
  eq(out[0].json.clinic_name, "Real Clinic", "name");
});

test("classifies by speciality tag and by name keyword", () => {
  const out = normalizeOsm([
    { type: "node", id: 1, tags: { name: "X", amenity: "clinic",
                                   "healthcare:speciality": "dermatology" } },
    { type: "node", id: 2, tags: { name: "Glow Aesthetic Laser Studio", amenity: "clinic" } },
    { type: "node", id: 3, tags: { name: "Y", healthcare: "physiotherapist" } },
    { type: "way",  id: 4, tags: { name: "Z Diagnostic Lab", healthcare: "laboratory" } },
  ]);
  eq(out.map((o) => o.json.category),
     ["DERMATOLOGY", "AESTHETIC", "PHYSIOTHERAPY", "DIAGNOSTIC"], "categories");
});

test("honours the per-run lead cap", () => {
  const many = Array.from({ length: 30 }, (_, i) => ({
    type: "node", id: i, tags: { name: `Clinic ${i}`, amenity: "dentist" },
  }));
  const out = runNode("10_lead_discovery", "Normalize OSM Results", {
    input: [{ statusCode: 200, body: { elements: many } }],
    nodes: { "Build Overpass Query": osmTask,
             "Check Budget + Settings": { ...osmSettings, max_new: 7 } },
  });
  eq(out.length, 7, "capped");
});

test("uses way/relation centre coordinates", () => {
  const out = normalizeOsm([{
    type: "way", id: 9, center: { lat: 24.8, lon: 67.05 },
    tags: { name: "Way Clinic", amenity: "clinic" },
  }]);
  eq(out[0].json.lat, "24.8", "lat from center");
  eq(out[0].json.lng, "67.05", "lng from center");
});

// ============================================================ workflow 30

group("30 — Apply robots.txt");

function robots(body, statusCode = 200) {
  return runNode("30_ai_research", "Apply robots.txt", {
    input: [{ statusCode, body }],
    nodes: {
      "Plan Fetch": { id: "L1", origin: "https://clinic.pk", domain: "clinic.pk" },
      "Load Crawl Settings": { max_pages: 3, user_agent: "ZenvexaBot/1.0" },
    },
  })[0].json;
}

test("a missing robots.txt means allowed", () => {
  const r = robots("", 404);
  eq(r.robots_allowed, true, "allowed");
  ok(r.allowed_urls.length > 0, "should propose pages");
});

test("Disallow: / for * blocks everything", () => {
  const r = robots("User-agent: *\nDisallow: /");
  eq(r.robots_allowed, false, "blocked");
  eq(r.allowed_urls, [], "no urls");
});

test("a targeted Disallow removes only that path", () => {
  const r = robots("User-agent: *\nDisallow: /contact");
  ok(!r.allowed_urls.some((u) => u.includes("/contact")), "contact must be excluded");
  ok(r.allowed_urls.length > 0, "other pages still allowed");
});

test("a rule naming our own agent is honoured", () => {
  const r = robots("User-agent: ZenvexaBot\nDisallow: /\n\nUser-agent: Googlebot\nDisallow:");
  eq(r.robots_allowed, false, "our agent is blocked");
});

test("a rule for a different agent does not apply to us", () => {
  const r = robots("User-agent: Googlebot\nDisallow: /");
  eq(r.robots_allowed, true, "not our rule");
});

test("comments and blank lines are ignored", () => {
  const r = robots("# a comment\n\nUser-agent: *\nDisallow: /admin  # inline\n");
  ok(!r.allowed_urls.some((u) => u.includes("/admin")), "admin excluded");
  ok(r.allowed_urls.length > 0, "rest allowed");
});

test("never proposes more pages than the configured cap", () => {
  const r = runNode("30_ai_research", "Apply robots.txt", {
    input: [{ statusCode: 200, body: "" }],
    nodes: {
      "Plan Fetch": { id: "L1", origin: "https://clinic.pk", domain: "clinic.pk" },
      "Load Crawl Settings": { max_pages: 2, user_agent: "ZenvexaBot/1.0" },
    },
  })[0].json;
  eq(r.allowed_urls.length, 2, "capped at max_pages");
});

group("30 — Extract Text + Emails");

function extract(pages, lead = { id: "L1", domain: "clinic.pk", clinic_name: "C" }) {
  return runNode("30_ai_research", "Extract Text + Emails", {
    input: pages,
    nodes: { "Apply robots.txt": lead },
  })[0].json;
}

test("strips markup and collapses whitespace", () => {
  const r = extract([{
    url: "https://clinic.pk/", statusCode: 200,
    body: "<html><head><style>b{color:red}</style><script>x=1</script></head>" +
          "<body><h1>Dr Ahmed  Dental</h1><p>Three   dentists see patients " +
          "six days a week, and appointments are booked over WhatsApp.</p>" +
          "</body></html>",
  }]);
  ok(r.page_content.includes("Dr Ahmed Dental"), "heading text kept, whitespace collapsed");
  ok(!r.page_content.includes("color:red"), "css dropped");
  ok(!r.page_content.includes("x=1"), "script dropped");
});

test("skips a page with too little text to be worth reading", () => {
  // Nav-only stubs and near-empty pages are filtered rather than sent to the
  // model, where they would produce a confident brief about nothing.
  const r = extract([{
    url: "https://clinic.pk/", statusCode: 200,
    body: "<html><body><nav>Home</nav></body></html>",
  }]);
  eq(r.pages_fetched, 0, "stub page skipped");
});

test("decodes the entities that survive tag stripping", () => {
  const r = extract([{
    url: "https://clinic.pk/", statusCode: 200,
    body: "<p>Braces&nbsp;&amp;&nbsp;implants are offered here, and our clinic " +
          "books every appointment through WhatsApp during opening hours.</p>",
  }]);
  ok(r.page_content.includes("Braces & implants"), "entities decoded");
});

test("prefers an address on the clinic's own domain", () => {
  const r = extract([{
    url: "https://clinic.pk/contact", statusCode: 200,
    body: "<p>Built by studio@webagency.com — reach us at info@clinic.pk</p>" +
          "<p>Lorem ipsum dolor sit amet consectetur adipiscing elit sed do.</p>",
  }]);
  eq(r.discovered_email, "info@clinic.pk", "own-domain address wins");
  eq(r.discovered_email_url, "https://clinic.pk/contact", "evidence url recorded");
});

test("rejects image filenames and platform noise", () => {
  const r = extract([{
    url: "https://clinic.pk/", statusCode: 200,
    body: "<img src='logo@2x.png'> sprite@2x.jpeg noreply@sentry.wixpress.com " +
          "<p>Some genuine page text here to pass the length filter, at least.</p>",
  }]);
  eq(r.discovered_email, null, "nothing that looks like an address is really one");
});

test("ignores failed fetches but keeps the successful ones", () => {
  const r = extract([
    { url: "https://clinic.pk/", statusCode: 200,
      body: "<p>Our clinic has four dentists and opens six days a week here.</p>" },
    { url: "https://clinic.pk/contact", statusCode: 500, body: "" },
    { url: "https://clinic.pk/about", statusCode: 404, body: "Not found" },
  ]);
  eq(r.pages_fetched, 1, "only the 200 counted");
  eq(r.fetched_urls, ["https://clinic.pk/"], "urls");
});

test("survives every page failing", () => {
  const r = extract([{ url: "https://clinic.pk/", statusCode: 503, body: "" }]);
  eq(r.pages_fetched, 0, "no pages");
  eq(r.page_content, "", "empty content, not a crash");
  eq(r.discovered_email, null, "no email");
});

// ============================================================ workflow 40

group("40 — Guardrails");

const gcfg = {
  banned: ["revolutionary", "guaranteed", "10x", "transform your business"],
  required_tokens: ["{{UNSUBSCRIBE}}"],
  max_chars: 1400, min_chars: 350, min_conf: 0.7,
  auto_send: true, postal_address: "12 Example Rd, Karachi",
  campaign_id: "c1", mailbox_id: "m1",
};
const glead = { id: "L1", clinic_name: "Meridian Dental", public_email: "hi@meridian.pk" };

function guard(data, cfgOverride = {}) {
  return runNode("40_personalization", "Guardrails", {
    input: [{ ok: true, data, model: "gemini-2.5-flash", prompt_version: "v1" }],
    nodes: { "Evaluate MX": glead, "Load Settings": { ...gcfg, ...cfgOverride } },
  })[0].json;
}

const goodBody =
  "Hi Meridian Dental,\n\nI noticed your contact page lists WhatsApp as the way " +
  "to book an appointment, and that four dentists share the practice.\n\n" +
  "We built Clinibot, an AI receptionist that answers patients on WhatsApp, " +
  "books appointments and sends reminders. It handles availability across " +
  "several dentists, which seems relevant to how you already work.\n\n" +
  "Would you be open to a five minute demo?\n\nBest,\nUmer\n\n{{UNSUBSCRIBE}}";

test("a clean draft passes and is queued to send", () => {
  const r = guard({ subject: "A question about your WhatsApp bookings",
                    body_text: goodBody, confidence: 0.86,
                    personalization_reason: "contact page lists WhatsApp",
                    suggested_feature: "Books appointments" });
  eq(r.passed, true, "passed");
  eq(r.status, "READY_TO_SEND", "status");
});

test("low confidence routes to review rather than rejecting", () => {
  const r = guard({ subject: "A question", body_text: goodBody, confidence: 0.4 });
  eq(r.passed, true, "still passes the hard checks");
  eq(r.status, "PENDING_APPROVAL", "but needs a human");
  ok(r.review_reason.startsWith("low_confidence"), "reason recorded");
});

test("auto_send off sends even a confident draft to review", () => {
  const r = guard({ subject: "A question", body_text: goodBody, confidence: 0.99 },
                  { auto_send: false });
  eq(r.status, "PENDING_APPROVAL", "held");
  eq(r.review_reason, "auto_send_disabled", "reason");
});

test("rejects banned hype vocabulary", () => {
  const r = guard({ subject: "A revolutionary idea", body_text: goodBody, confidence: 0.9 });
  eq(r.passed, false, "rejected");
  ok(r.reasons.some((x) => x.includes("revolutionary")), "names the phrase");
});

test("rejects a missing unsubscribe token", () => {
  const r = guard({ subject: "Hello", body_text: goodBody.replace("{{UNSUBSCRIBE}}", ""),
                    confidence: 0.9 });
  eq(r.passed, false, "rejected");
  ok(r.reasons.some((x) => x.includes("missing_token")), "names the token");
});

test("rejects a price, a medical claim, and an invented statistic", () => {
  for (const [body, reason] of [
    [goodBody.replace("Best,", "It costs PKR 5000 a month.\n\nBest,"), "contains_price"],
    [goodBody.replace("Best,", "It is clinically proven to help.\n\nBest,"), "medical_claim"],
    [goodBody.replace("Best,", "Clinics see 40% more bookings.\n\nBest,"), "unsupported_statistic"],
  ]) {
    const r = guard({ subject: "Hello", body_text: body, confidence: 0.9 });
    eq(r.passed, false, `rejected for ${reason}`);
    ok(r.reasons.includes(reason), `reason ${reason}, got ${r.reasons}`);
  }
});

test("rejects a fabricated prior conversation", () => {
  const r = guard({ subject: "Hello",
                    body_text: goodBody.replace("I noticed", "As discussed when I called, I noticed"),
                    confidence: 0.9 });
  eq(r.passed, false, "rejected");
  ok(r.reasons.includes("fabricated_prior_contact"), "reason");
});

test("rejects a fake Re: subject and more than one link", () => {
  let r = guard({ subject: "Re: our conversation", body_text: goodBody, confidence: 0.9 });
  ok(r.reasons.includes("fake_reply_subject"), "fake reply subject");

  r = guard({ subject: "Hello",
              body_text: goodBody.replace("Best,", "See https://a.pk and https://b.pk\n\nBest,"),
              confidence: 0.9 });
  ok(r.reasons.some((x) => x.startsWith("too_many_links")), "too many links");
});

test("refuses to build any email while the postal address is unset", () => {
  const r = guard({ subject: "Hello", body_text: goodBody, confidence: 0.9 },
                  { postal_address: "  " });
  eq(r.passed, false, "rejected");
  ok(r.reasons.includes("no_postal_address_configured"), "reason");
});

test("a failed AI call is a rejection, never a send", () => {
  const r = runNode("40_personalization", "Guardrails", {
    input: [{ ok: false, error: "invalid_json" }],
    nodes: { "Evaluate MX": glead, "Load Settings": gcfg },
  })[0].json;
  eq(r.passed, false, "rejected");
  ok(r.reasons[0].includes("ai_failed"), "reason");
});

// ============================================================ workflow 50

group("50 — Render Final Email");

const rfCampaign = {
  postal_address: "12 Example Rd, Karachi",
  unsub_base: "https://n8n.zenvexa.tech/webhook/unsubscribe",
  brand: "Zenvexa", company_url: "https://zenvexa.tech",
  from_email: "umer@zenvexa.tech", from_name: "Umer",
  reply_to: "umer@zenvexa.tech", dry_run: false,
};
const rfEmail = {
  email_id: "e1", to_email: "hi@clinic.pk", subject: "Hi",
  body_text: "Hello there.\n\n{{UNSUBSCRIBE}}\n\nBest,\nUmer",
  unsubscribe_token: "abc123", step_no: 0,
};
function render(email = rfEmail, campaign = rfCampaign) {
  return runNode("50_outreach_send", "Render Final Email", {
    input: [{}],
    nodes: { "Per Email": email, "Active Campaigns": campaign },
  })[0].json;
}

test("substitutes the unsubscribe token with a working link", () => {
  const r = render();
  ok(!r.final_body.includes("{{UNSUBSCRIBE}}"), "token replaced");
  ok(r.final_body.includes("webhook/unsubscribe?t=abc123"), "real per-email URL");
});

test("appends the brand and postal address footer", () => {
  const r = render();
  ok(r.final_body.includes("12 Example Rd, Karachi"), "postal address present");
  ok(r.final_body.includes("Zenvexa"), "brand present");
});

test("adds an unsubscribe line even if the token was missing", () => {
  const r = render({ ...rfEmail, body_text: "No token here at all." });
  ok(r.final_body.includes("unsubscribe here:"), "line appended anyway");
});

test("refuses to send with no postal address configured", () => {
  throws(() => render(rfEmail, { ...rfCampaign, postal_address: "" }),
         "postal_address", "must refuse without a postal address");
});

test("refuses to send with no unsubscribe URL configured", () => {
  throws(() => render(rfEmail, { ...rfCampaign, unsub_base: "" }),
         "unsubscribe.base_url", "must refuse without a working opt-out");
});

// ============================================================ workflow 60

group("60 — Triage Message");

function triage(msg) {
  return runNode("60_inbox_monitor", "Triage Message", { input: [msg] })[0].json;
}

test("a normal reply is a human reply", () => {
  const r = triage({ from: { value: [{ address: "Reception@Clinic.PK", name: "Reception" }] },
                     subject: "Re: your email", textPlain: "Yes, interested.",
                     messageId: "<m1@clinic.pk>", headers: {} });
  eq(r.kind, "HUMAN_REPLY", "kind");
  eq(r.from_email, "reception@clinic.pk", "address lowercased");
  eq(r.lookup_email, "reception@clinic.pk", "lookup");
});

test("detects an out-of-office as an auto-reply", () => {
  eq(triage({ from: { text: "x@clinic.pk" }, subject: "Out of office",
              textPlain: "Away", headers: {} }).kind, "AUTO_REPLY", "by subject");
  eq(triage({ from: { text: "x@clinic.pk" }, subject: "Re: hello", textPlain: "",
              headers: { "Auto-Submitted": "auto-replied" } }).kind, "AUTO_REPLY", "by header");
  eq(triage({ from: { text: "x@clinic.pk" }, subject: "Re: hello", textPlain: "",
              headers: { Precedence: "bulk" } }).kind, "AUTO_REPLY", "by precedence");
});

test("Auto-Submitted: no is NOT an auto-reply", () => {
  eq(triage({ from: { text: "x@clinic.pk" }, subject: "Re: hi", textPlain: "Sure",
              headers: { "Auto-Submitted": "no" } }).kind, "HUMAN_REPLY", "kind");
});

test("separates a permanent bounce from a temporary one", () => {
  const hard = triage({
    from: { text: "MAILER-DAEMON@zenvexa.tech" }, subject: "Undelivered Mail Returned to Sender",
    textPlain: "550 5.1.1 <gone@clinic.pk>: Recipient address rejected", headers: {},
  });
  eq(hard.kind, "BOUNCE", "kind");
  eq(hard.hard_bounce, true, "5.x.x is permanent");
  eq(hard.lookup_email, "gone@clinic.pk", "recovers the failed address from the report");

  const soft = triage({
    from: { text: "MAILER-DAEMON@zenvexa.tech" }, subject: "Delivery Status Notification (Delay)",
    textPlain: "4.2.2 <full@clinic.pk>: mailbox full", headers: {},
  });
  eq(soft.kind, "BOUNCE", "kind");
  eq(soft.hard_bounce, false, "4.x.x must not suppress an address");
});

test("finds the failed address in a multipart/report bounce", () => {
  const r = triage({
    from: { text: "postmaster@zenvexa.tech" }, subject: "Delivery Status Notification",
    textPlain: "Final-Recipient: rfc822; dead@clinic.pk\nStatus: 5.1.1",
    headers: { "Content-Type": "multipart/report; report-type=delivery-status" },
  });
  eq(r.kind, "BOUNCE", "kind");
  eq(r.lookup_email, "dead@clinic.pk", "address");
});

test("always produces a message id, even when the server omits one", () => {
  const r = triage({ from: { text: "x@clinic.pk" }, subject: "Hi", textPlain: "y", headers: {} });
  ok(r.message_id && r.message_id.length > 5, "synthesised id");
});

// ============================================================ workflow 70

group("70 — Interpret Classification");

const ictx = { reply_id: "r1", lead_id: "L1", min_conf: 0.75 };
function interpret(data, ok_ = true, error) {
  return runNode("70_reply_classification", "Interpret Classification", {
    input: [ok_ ? { ok: true, data, model: "m", prompt_version: "v1" }
                : { ok: false, error }],
    nodes: { "Load Reply Context": ictx },
  })[0].json;
}

test("routes an enthusiastic reply to hot", () => {
  const r = interpret({ class: "VERY_INTERESTED", confidence: 0.95,
                        opt_out_signal_detected: false, requires_human: false,
                        extracted_questions: [], sentiment: "POSITIVE" });
  eq(r.route, "HOT", "route");
  eq(r.next_status, "INTERESTED", "status");
});

test("a demo request becomes DEMO_REQUESTED", () => {
  const r = interpret({ class: "ASKING_DEMO", confidence: 0.92,
                        opt_out_signal_detected: false, requires_human: false,
                        extracted_questions: [], sentiment: "POSITIVE" });
  eq(r.next_status, "DEMO_REQUESTED", "status");
});

test("an opt-out signal overrides whatever class the model chose", () => {
  const r = interpret({ class: "NEEDS_MORE_INFO", confidence: 0.9,
                        opt_out_signal_detected: true,
                        opt_out_quote: "please remove me from your list",
                        requires_human: false, extracted_questions: ["what does it cost?"],
                        sentiment: "NEUTRAL" });
  eq(r.class, "OPT_OUT", "class forced");
  eq(r.route, "OPT_OUT", "route");
  eq(r.next_status, "OPTED_OUT", "status");
});

test("low confidence escalates to a human", () => {
  const r = interpret({ class: "INTERESTED", confidence: 0.4,
                        opt_out_signal_detected: false, requires_human: false,
                        extracted_questions: [], sentiment: "POSITIVE" });
  eq(r.requires_human, true, "escalated");
});

test("an interested prospect with a hard question is still hot", () => {
  const r = interpret({ class: "ASKING_PRICE", confidence: 0.9,
                        opt_out_signal_detected: false, requires_human: true,
                        escalation_reason: "pricing", extracted_questions: ["how much?"],
                        sentiment: "POSITIVE" });
  eq(r.route, "HOT", "stays hot so the question is surfaced, not queued");
  eq(r.requires_human, true, "still flagged");
});

test("a failed classification becomes a human review, never an approval", () => {
  const r = interpret(null, false, "gemini_http_429");
  eq(r.route, "HUMAN", "route");
  eq(r.class, "UNCLEAR", "class");
  eq(r.requires_human, true, "human");
  ok(r.escalation_reason.includes("classification_failed"), "reason");
});

// ============================================================ workflow 01

group("01 — Parse & Validate");

const pvCtx = {
  model: "gemini-2.5-flash", prompt_key: "email_initial", prompt_version: "v1",
  purpose: "PERSONALIZE", lead_id: "L1", required_fields: ["subject", "body_text"],
  pricing: { "gemini-2.5-flash": { input_per_1m: 0.3, output_per_1m: 2.5 } },
  started_at: Date.now(), request: {},
};
function parse(resp) {
  return runNode("01_ai_call", "Parse & Validate", {
    input: [resp], nodes: { "Build Request": pvCtx },
  })[0].json;
}
const geminiOk = (obj) => ({
  statusCode: 200,
  body: { candidates: [{ finishReason: "STOP",
                         content: { parts: [{ text: JSON.stringify(obj) }] } }],
          usageMetadata: { promptTokenCount: 2000, candidatesTokenCount: 500 } },
});

test("accepts a well-formed response and costs it", () => {
  const r = parse(geminiOk({ subject: "s", body_text: "b" }));
  eq(r.valid, true, "valid");
  eq(r.data.subject, "s", "payload");
  eq(r.input_tokens, 2000, "input tokens");
  ok(Math.abs(r.cost_usd - (2000 / 1e6 * 0.3 + 500 / 1e6 * 2.5)) < 1e-9, "cost");
});

test("rejects malformed JSON", () => {
  const r = parse({ statusCode: 200, body: { candidates: [{ finishReason: "STOP",
    content: { parts: [{ text: "here you go: {oops" }] } }] } });
  eq(r.valid, false, "invalid");
  eq(r.error, "invalid_json", "error");
});

test("rejects a response missing a required field", () => {
  const r = parse(geminiOk({ subject: "s" }));
  eq(r.valid, false, "invalid");
  eq(r.error, "missing_required_fields", "error");
  ok(r.detail.includes("body_text"), "names the field");
});

test("rejects truncated output even though it might parse", () => {
  const r = parse({ statusCode: 200, body: { candidates: [{ finishReason: "MAX_TOKENS",
    content: { parts: [{ text: '{"subject":"s","body_text":"b"}' }] } }] } });
  eq(r.valid, false, "invalid");
  eq(r.error, "truncated_output", "error");
});

test("rejects an HTTP error and a safety refusal", () => {
  eq(parse({ statusCode: 429, body: { error: { message: "rate limit" } } }).error,
     "gemini_http_429", "http error");
  eq(parse({ statusCode: 200, body: { candidates: [{ finishReason: "SAFETY", content: {} }] } }).error,
     "finish_reason_SAFETY", "safety");
});

test("a null required field counts as missing", () => {
  const r = parse(geminiOk({ subject: "s", body_text: null }));
  eq(r.valid, false, "invalid");
  eq(r.error, "missing_required_fields", "error");
});

// ============================================================ workflow 80

group("80 — Follow-up Guardrails");

const fctx = {
  lead_id: "L1", follow_up_id: "f1", campaign_id: "c1", mailbox_id: "m1",
  step_no: 1, public_email: "hi@clinic.pk", clinic_name: "Meridian Dental",
  banned: ["revolutionary", "guaranteed"], auto_send: true, min_conf: 0.7,
  previous_emails: [{ step_no: 0, subject: "A question about your WhatsApp bookings",
                      body_text: "I noticed your contact page lists WhatsApp as the way to book." }],
};
function fguard(data, ctxOverride = {}) {
  return runNode("80_followup_engine", "Guardrails", {
    input: [{ ok: true, data, model: "m", prompt_version: "v1" }],
    nodes: { "Per Follow-Up": { ...fctx, ...ctxOverride } },
  })[0].json;
}
const fgood = "One thing I left out: setup is a WhatsApp number and your doctor list, " +
              "and it runs the same day. Happy to show you.\n\n{{UNSUBSCRIBE}}";

test("a good follow-up passes", () => {
  const r = fguard({ subject: "A question about your WhatsApp bookings",
                     body_text: fgood, angle: "setup effort",
                     suggested_feature: "Books appointments", is_final: false, confidence: 0.85 });
  eq(r.ok, true, `passed, got ${JSON.stringify(r.reasons)}`);
  eq(r.status, "READY_TO_SEND", "status");
});

test("rejects filler openers and guilt", () => {
  for (const [text, reason] of [
    ["Just following up on my last email.\n\n{{UNSUBSCRIBE}}" + " padding.".repeat(12), "filler_opener"],
    ["I haven't heard back from you.\n\n{{UNSUBSCRIBE}}" + " padding.".repeat(12), "guilt_trip"],
    ["Last chance to see this.\n\n{{UNSUBSCRIBE}}" + " padding.".repeat(12), "false_urgency"],
  ]) {
    const r = fguard({ subject: "s", body_text: text, angle: "a",
                       suggested_feature: "f", is_final: false, confidence: 0.9 });
    eq(r.ok, false, `rejected for ${reason}`);
    ok(r.reasons.includes(reason), `reason ${reason}, got ${r.reasons}`);
  }
});

test("rejects a follow-up that repeats the previous email", () => {
  const r = fguard({ subject: "s",
    body_text: "I noticed your contact page lists WhatsApp as the way to book. " +
               "Thought I would mention it again.\n\n{{UNSUBSCRIBE}}",
    angle: "a", suggested_feature: "f", is_final: false, confidence: 0.9 });
  eq(r.ok, false, "rejected");
  ok(r.reasons.includes("repeats_previous_email"), "reason");
});

test("rejects an overlong follow-up", () => {
  const r = fguard({ subject: "s", body_text: "word ".repeat(300) + "{{UNSUBSCRIBE}}",
                     angle: "a", suggested_feature: "f", is_final: false, confidence: 0.9 });
  eq(r.ok, false, "rejected");
  ok(r.reasons.some((x) => x.startsWith("too_long_for_followup")), "reason");
});

// ============================================================ summary

console.log(
  `\n\x1b[1mSummary\x1b[0m  ${passed} passed, ${failed} failed ` +
  `(${Object.keys(workflows).length} workflows loaded)`,
);
if (failed) {
  console.log(`\x1b[31mFailures:\x1b[0m ${failures.join(", ")}`);
  process.exit(1);
}
console.log("\x1b[32mAll Code-node logic verified against the committed workflow JSON.\x1b[0m");
