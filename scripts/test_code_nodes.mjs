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
    // A stubbed node counts as having run; an unstubbed one throws below,
    // which is what n8n does for a node that never executed.
    isExecuted: true,
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

// ============================================================ WEB offer

group("10 — WEB discovery tasks");

function overpass(task) {
  return runNode("10_lead_discovery", "Build Overpass Query", { input: [task] })[0].json.overpass_query;
}
const webTask = {
  id: "T-web", market_code: "PK", city: "Karachi", area: "Saddar", offer: "WEB",
  category: "PRINTING", priority_tier: 1,
  bbox: { lat: 24.85, lng: 67.03, radius_m: 2500 },
  osm_selectors: ['["shop"~"^(copyshop|printing)$"]', '["craft"="printer"]'],
};

test("a WEB task queries its own selectors, not healthcare", () => {
  const q = overpass(webTask);
  ok(q.includes('nwr["shop"~"^(copyshop|printing)$"](around:2500,24.85,67.03);'), q);
  ok(q.includes('nwr["craft"="printer"](around:2500,24.85,67.03);'), q);
  ok(!q.includes("healthcare"), "no healthcare clause");
});

test("a clinic task still gets the healthcare query", () => {
  const q = overpass({ ...webTask, offer: "CLINIBOT", osm_selectors: null });
  ok(q.includes('nwr["healthcare"]'), q);
});

test("a malformed selector fails loudly instead of reaching Overpass", () => {
  throws(() => overpass({ ...webTask, osm_selectors: ['["shop"="x"]);out;('] }),
         "unusable osm_selectors", "should refuse");
  throws(() => overpass({ ...webTask, osm_selectors: [] }), "unusable osm_selectors",
         "empty selectors should refuse");
});

test("WEB OSM results keep the task's category and carry the offer", () => {
  const out = runNode("10_lead_discovery", "Normalize OSM Results", {
    input: [{ statusCode: 200, body: { elements: [
      { type: "node", id: 9, tags: { name: "Ali Printers", shop: "copyshop", phone: "0300 1234567" } },
    ] } }],
    nodes: { "Build Overpass Query": webTask, "Check Budget + Settings": osmSettings },
  });
  eq(out[0].json.category, "PRINTING", "category");
  eq(out[0].json.priority_tier, 1, "tier");
  eq(out[0].json.offer, "WEB", "offer");
});

test("a clinic OSM result is tagged CLINIBOT by default", () => {
  const out = normalizeOsm([{ type: "node", id: 5, tags: { name: "Smile Dental", amenity: "dentist" } }]);
  eq(out[0].json.offer, "CLINIBOT", "offer");
});

test("WEB Places results keep the task's category and carry the offer", () => {
  const out = runNode("10_lead_discovery", "Normalize Place Details", {
    input: [{ statusCode: 200, body: {
      id: "P1", displayName: { text: "Trust Printing Press" }, businessStatus: "OPERATIONAL",
      nationalPhoneNumber: "0300 7654321", userRatingCount: 55, rating: 4.6,
    } }],
    nodes: { "Per Task": webTask },
  });
  // "Trust" is a clinic-pipeline exclusion; a printing press named Trust is fine.
  eq(out.length, 1, "kept");
  eq(out[0].json.category, "PRINTING", "category");
  eq(out[0].json.offer, "WEB", "offer");
  eq(out[0].json.website, null, "no website");
});

test("every Places Details response becomes a lead, not just the first", () => {
  const place = (id, name) => ({ statusCode: 200, body: {
    id, displayName: { text: name }, businessStatus: "OPERATIONAL", nationalPhoneNumber: "0300 1112223" } });
  const out = runNode("10_lead_discovery", "Normalize Place Details", {
    input: [place("A", "Alpha Prints"), place("B", "Beta Prints"),
            { statusCode: 404, body: { error: {} } }, place("C", "Gamma Prints")],
    nodes: { "Per Task": webTask },
  });
  eq(out.map((o) => o.json.source_ref), ["A", "B", "C"], "all three kept, the 404 skipped");
});

group("10 — Treg Maps discovery");

// A real anyapi.google.serp.maps answer (first live call, 2026-10-08),
// trimmed to five public business listings.
const tregFixture = JSON.parse(readFileSync(
  path.join(ROOT, "scripts", "fixtures", "treg_maps_karachi_restaurants.json"), "utf8"));
const tregTask = { id: "T-treg", market_code: "PK", market_name: "Pakistan", city: "Karachi",
                   area: "Saddar", offer: "WEB", category: "RESTAURANT", priority_tier: 1,
                   query_term: "restaurant", provider: "TREG_MAPS" };
function normalizeTreg(resp) {
  return runNode("10_lead_discovery", "Normalize Treg Maps", {
    input: [resp],
    nodes: { "Build Treg Maps Request": tregTask, "Check Budget + Settings": { max_new: 60 } },
  }).map((o) => o.json);
}

test("the request asks Google Maps for area, city and country as free text", () => {
  const [o] = runNode("10_lead_discovery", "Build Treg Maps Request", { input: [tregTask] });
  eq(o.json.treg_body, { query: "restaurant", location: "Saddar, Karachi, Pakistan", limit: 20 }, "body");
});

test("a real Treg answer becomes leads with phone, place id and listing stats", () => {
  const leads = normalizeTreg({ statusCode: 200, body: tregFixture });
  eq(leads.length, 5, "all five places kept");
  const kb = leads.find((l) => l.clinic_name === "Karachi Brasserie");
  ok(kb, "Karachi Brasserie present");
  eq(kb.website, null, "no website recorded as null, not guessed");
  eq(kb.source_ref_type, "PLACE_ID", "dedups with the Places branch");
  eq(kb.offer, "WEB", "offer");
  eq(kb.public_email, null, "no email invented");
  ok(kb.phone && kb.contacts[0].source === "GOOGLE_BUSINESS" && kb.contacts[0].source_url, "phone with evidence");
  eq(kb.raw.GOOGLE_PLACES.userRatingCount, 300, "review count kept for scoring");
});

test("a refused or failed call yields nothing, so the loop moves on", () => {
  eq(normalizeTreg({ statusCode: 402, body: { error: "insufficient_balance" } }).length, 0, "402");
  eq(normalizeTreg({ error: { message: "timeout" } }).length, 0, "network error");
});

test("closed and unnamed places are dropped", () => {
  const body = JSON.parse(JSON.stringify(tregFixture));
  body.output.data.items[0].permanentlyClosed = true;
  body.output.data.items[1].name = "";
  eq(normalizeTreg({ statusCode: 200, body }).length, 3, "two dropped");
});

group("01 — AI call returns the model's answer, not the log row");

const parsedOk = { valid: true, ok: true, data: { message: "Hello" }, model: "gemini-3.8-flash",
                   prompt_key: "web_pitch_message", prompt_version: "v1", input_tokens: 10,
                   output_tokens: 20, cost_usd: 0.0001, lead_id: "L1", attempt: 1 };

test("Return Result hands back the parsed data, whatever the log insert returned", () => {
  const [o] = runNode("01_ai_call", "Return Result", {
    input: [{ id: 99 }],                          // what Log AI Call actually outputs
    nodes: { "Parse & Validate": parsedOk },
  });
  eq(o.json.data, { message: "Hello" }, "data");
  eq(o.json.model, "gemini-3.8-flash", "model");
});

test("a valid retry wins over the failed first attempt", () => {
  const [o] = runNode("01_ai_call", "Return Result", {
    input: [{ id: 99 }],
    nodes: { "Parse & Validate": { valid: false, error: "invalid_json" },
             "Parse & Validate (Retry)": { ...parsedOk, data: { message: "Second" }, attempt: 2 } },
  });
  eq(o.json.data, { message: "Second" }, "retry data");
});

test("Return Failure carries the real error, not the dead-letter row", () => {
  const [o] = runNode("01_ai_call", "Return Failure", {
    input: [{ id: 7 }],
    nodes: { "Parse & Validate": { valid: false, error: "invalid_json", detail: "x" },
             "Parse & Validate (Retry)": { valid: false, error: "gemini_http_429", detail: "y",
                                           prompt_key: "k", lead_id: "L1" } },
  });
  eq(o.json.ok, false, "ok");
  eq(o.json.error, "gemini_http_429", "the last attempt's error");
});

group("20 — offer-aware triage and decision");

function triageLeads(leads) {
  return runNode("20_lead_qualification", "Deterministic Triage", { input: leads }).map((o) => o.json);
}

test("a WEB lead with a phone and no website is not disqualified", () => {
  const [t] = triageLeads([{ id: "a", clinic_name: "Ali Printers", phone: "+923001234567", offer: "WEB" }]);
  eq(t.disqualified, false, "disqualified");
  eq(t.researchable, false, "never sent to AI research");
});

test("a clinic with nothing to research is still rejected on the Clinibot path", () => {
  const [t] = triageLeads([{ id: "b", clinic_name: "Some Clinic", phone: "+922100000000", offer: "CLINIBOT" }]);
  ok(t.disqualify_reasons.includes("nothing_to_research"), JSON.stringify(t));
});

test("a WEB lead with only an email cannot be pitched by hand", () => {
  const [t] = triageLeads([{ id: "c", clinic_name: "Mail Only Co", public_email: "a@b.pk", offer: "WEB" }]);
  ok(t.disqualify_reasons.includes("no_phone_for_manual_outreach"), JSON.stringify(t));
});

test("decision sends no-website leads to drafting and sited ones to audit", () => {
  const triaged = [
    { id: "n", clinic_name: "No Site", offer: "WEB", disqualified: false, disqualify_reasons: [] },
    { id: "s", clinic_name: "Has Site", offer: "WEB", disqualified: false, disqualify_reasons: [] },
  ];
  const out = runNode("20_lead_qualification", "Decide Next Status", {
    input: [
      { score: { score: 70, qualifies: true, breakdown: { no_website: 35 } } },
      { score: { score: 30, qualifies: true, breakdown: { has_phone: 6 } } },
    ],
    nodes: { "Deterministic Triage": triaged },
  }).map((o) => o.json);
  eq(out[0].status, "QUALIFIED", "no site status");
  ok(out[0].reason.startsWith("web:no_website"), out[0].reason);
  eq(out[1].status, "QUALIFIED", "site status");
  ok(out[1].reason.startsWith("web:website_to_audit"), out[1].reason);
});

group("25 — Website audit");

const auditLead = { id: "L9", domain: "aliprinters.pk", homepage: "http://aliprinters.pk/",
                    started_at: Date.now() - 900 };
function analyze(resp, lead = auditLead) {
  return runNode("25_website_audit", "Analyze Website", {
    input: [resp], nodes: { "Start Timer": lead },
  })[0].json;
}
const year = new Date().getFullYear();

test("an old, insecure, desktop-only site with no way to call is weak on every count", () => {
  const a = analyze({ statusCode: 200, body:
    `<html><head><title>Ali Printers</title></head><body><h1>Welcome to Ali Printers</h1>
     <p>We print visiting cards, banners and flex. Contact info@gmail.com or orders@aliprinters.pk</p>
     <footer>&copy; ${year - 6} Ali Printers</footer></body></html>` });
  eq(a.reachable, true, "reachable");
  eq(a.issues, ["no_https", "not_mobile_friendly", "outdated", "no_contact_cta"], "issues");
  eq(a.copyright_year, year - 6, "copyright year");
  eq(a.email, "orders@aliprinters.pk", "prefers the site's own domain");
  eq(a.email_url, "http://aliprinters.pk/", "email evidence is the page it was read from");
});

test("a modern site with a call button has no issues", () => {
  const a = analyze({ statusCode: 200, body:
    `<html><head><meta name="viewport" content="width=device-width">
     <link rel="canonical" href="https://aliprinters.pk/"><title>Ali</title></head>
     <body><a href="tel:+923001234567">Call</a> &copy; 2019-${year} Ali</body></html>` });
  eq(a.https, true, "https from canonical");
  eq(a.issues, [], "issues");
  eq(a.copyright_year, year, "uses the later year of a range");
});

test("a site that does not load is reported as unreachable, with no email", () => {
  const a = analyze({ error: { message: "getaddrinfo ENOTFOUND aliprinters.pk" } });
  eq(a.reachable, false, "reachable");
  eq(a.issues, ["site_unreachable"], "issues");
  eq(a.email, null, "email");
});

test("a parked domain is flagged; a JavaScript shell with little text is not", () => {
  const parked = analyze({ statusCode: 200, body:
    `<html><head><meta name="viewport" content="x"></head><body>This domain is for sale! Buy this domain.</body></html>` });
  ok(parked.issues.includes("site_parked"), JSON.stringify(parked.issues));
  const spa = analyze({ statusCode: 200, body:
    `<html><head><meta name="viewport" content="x"><title>App</title></head>
     <body><div id="root"></div><a href="https://wa.me/923001234567">WhatsApp</a></body></html>` });
  ok(!spa.issues.includes("site_parked"), JSON.stringify(spa.issues));
});

test("ordering, booking and platform are read off the homepage", () => {
  const filler = "We serve fresh coffee, pastries and brunch every day in Clifton. ".repeat(10);
  const a = analyze({ statusCode: 200, body:
    `<html><head><meta name="viewport" content="x"><link rel="stylesheet" href="/wp-content/x.css"></head>
     <body><p>${filler}</p><a href="https://www.foodpanda.pk/restaurant/x">Order on foodpanda</a>
     <a href="tel:+923001112223">Call</a></body></html>` });
  eq(a.raw.features.online_ordering, true, "foodpanda link counts as ordering");
  eq(a.raw.features.booking, false, "judged and not found");
  eq(a.raw.platform, "WordPress", "platform");
});

test("a page too thin to judge reports features as unknown, never missing", () => {
  const a = analyze({ statusCode: 200, body:
    `<html><head><meta name="viewport" content="x"></head><body><div id="root"></div></body></html>` });
  eq(a.raw.features.booking, null, "booking unknown");
  eq(a.raw.features.online_ordering, null, "ordering unknown");
});

test("robots.txt Disallow: / keeps the homepage unfetched", () => {
  const out = runNode("25_website_audit", "Apply robots.txt", {
    input: [{ statusCode: 200, body: "User-agent: *\nDisallow: /" }],
    nodes: { "Plan Audit": { ...auditLead, plan_error: null } },
  })[0].json;
  eq(out.allowed, false, "allowed");
});

group("45 — Web pitch draft check");

const pitchCfg = { portfolio_url: "https://zenvexa.tech", banned: ["guaranteed", "act now"] };
const pitchLead = { id: "W1", channel: { channel: "WHATSAPP", to_value: "+923001234567" } };
const goodPitch =
  "Assalamualaikum! I came across Ali Printers on Google Maps and noticed you don't have a " +
  "website yet. I'm Umer, a web developer. I build simple mobile-friendly sites where customers " +
  "can see your printing services and message you on WhatsApp in one tap. I'd be happy to make " +
  "a free sample for Ali Printers first. Would you like me to make one?\nhttps://zenvexa.tech";
function pcheck(data, ok_ = true) {
  return runNode("45_web_pitch", "Check Draft", {
    input: [{ ok: ok_, data, error: ok_ ? undefined : "gemini_http_500",
              model: "gemini-2.5-flash", prompt_version: "v1" }],
    nodes: { "Per Lead": pitchLead, "Load Settings": pitchCfg },
  })[0].json;
}

test("a good draft passes with the portfolio link", () => {
  const r = pcheck({ message: goodPitch, personalization_reason: "no website", confidence: 0.8 });
  eq(r.message, goodPitch, "message kept");
  eq(r.lead_id, "W1", "lead");
});

test("a price, a statistic or a stray link drops the draft to the template", () => {
  for (const bad of [
    goodPitch + " Only Rs 15,000!",
    goodPitch.replace("one tap", "one tap and get 40% more orders"),
    goodPitch + " See also https://example.com/offer",
  ]) {
    const r = pcheck({ message: bad, personalization_reason: "x", confidence: 0.9 });
    eq(r.message, null, `rejected: ${bad.slice(-40)}`);
    ok(r.notes.startsWith("ai_draft_rejected"), r.notes);
  }
});

test("banned hype and fake familiarity are rejected", () => {
  eq(pcheck({ message: goodPitch + " Results guaranteed.", confidence: 0.9 }).message, null, "banned");
  eq(pcheck({ message: "As discussed, " + goodPitch, confidence: 0.9 }).message, null, "fake contact");
});

test("a failed AI call becomes the template, never an empty queue row", () => {
  const r = pcheck({}, false);
  eq(r.message, null, "message");
  ok(r.notes.startsWith("ai_failed"), r.notes);
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
