#!/usr/bin/env python3
"""
Builds the importable n8n workflow JSON in n8n/workflows/.

    python3 n8n/build_workflows.py

Why a builder rather than thirteen hand-written JSON files: every workflow needs
the same error-workflow wiring, the same credential placeholders, the same retry
policy and the same node-positioning conventions. Encoding that once means a
change to the convention is one edit, and it makes the referential integrity of
`connections` checkable instead of hopeful.

The generated JSON is committed, so nothing here is needed at runtime.
"""
import json
import pathlib
import re
import sys

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(__file__).resolve().parent / "workflows"

# --------------------------------------------------------------------------
# Credential placeholders.
#
# n8n matches credentials by id on import. These ids will not exist in your
# instance, so after importing you open each red-flagged node once and pick the
# real credential. The NAMES below are what you should call them when you create
# them, so the mapping is obvious. No secret is ever stored in this repository.
# --------------------------------------------------------------------------
CRED = {
    "pg":       {"postgres":        {"id": "REPLACE_PG",       "name": "acq-postgres"}},
    "smtp":     {"smtp":            {"id": "REPLACE_SMTP",     "name": "zenvexa-smtp"}},
    "imap":     {"imap":            {"id": "REPLACE_IMAP",     "name": "zenvexa-imap"}},
    "telegram": {"telegramApi":     {"id": "REPLACE_TELEGRAM", "name": "acq-telegram"}},
    "gemini":   {"httpHeaderAuth":  {"id": "REPLACE_GEMINI",   "name": "gemini-api-key"}},
    "places":   {"httpQueryAuth":   {"id": "REPLACE_PLACES",   "name": "google-places-key"}},
}

# Set as the error workflow on every other workflow after import.
ERROR_WORKFLOW_NAME = "ACQ 00 — Error Handler"


class Builder:
    """Accumulates nodes and connections, then emits a valid workflow document."""

    def __init__(self, name, key, tags=None, error_workflow=True):
        self.name = name
        self.key = key
        self.tags = tags or []
        self.nodes = []
        self.conns = {}
        self.error_workflow = error_workflow
        self._col = 0

    def node(self, name, ntype, params, tv=1, creds=None, pos=None,
             on_error=None, retries=0, notes=None, always_output=False,
             disabled=False, execute_once=False):
        n = {
            "parameters": params,
            "id": f"{self.key}-{len(self.nodes):02d}",
            "name": name,
            "type": ntype,
            "typeVersion": tv,
            "position": pos or [260 + self._col * 220, 300],
        }
        if pos is None:
            self._col += 1
        if creds:
            n["credentials"] = CRED[creds]
        if on_error:
            n["onError"] = on_error
        if retries:
            n["retryOnFail"] = True
            n["maxTries"] = retries
            n["waitBetweenTries"] = 2000
        if always_output:
            n["alwaysOutputData"] = True
        if execute_once:
            n["executeOnce"] = True
        if disabled:
            n["disabled"] = True
        if notes:
            n["notes"] = notes
            n["notesInFlow"] = False
        self.nodes.append(n)
        return name

    def connect(self, src, dst, src_out=0, dst_in=0):
        entry = self.conns.setdefault(src, {"main": []})
        while len(entry["main"]) <= src_out:
            entry["main"].append([])
        entry["main"][src_out].append({"node": dst, "type": "main", "index": dst_in})

    def chain(self, *names):
        for a, b in zip(names, names[1:]):
            self.connect(a, b)

    def build(self):
        names = {n["name"] for n in self.nodes}
        for src, outs in self.conns.items():
            if src not in names:
                raise ValueError(f"{self.key}: connection from unknown node {src!r}")
            for out in outs["main"]:
                for c in out:
                    if c["node"] not in names:
                        raise ValueError(f"{self.key}: connection to unknown node {c['node']!r}")
        settings = {"executionOrder": "v1", "saveManualExecutions": True,
                    "saveDataErrorExecution": "all", "saveDataSuccessExecution": "all"}
        if self.error_workflow:
            settings["errorWorkflow"] = ERROR_WORKFLOW_NAME
        return {
            "name": self.name,
            "nodes": self.nodes,
            "connections": self.conns,
            "settings": settings,
            "tags": [{"name": t} for t in (self.tags or ["acq"])],
            "active": False,
            "meta": {"acqWorkflowKey": self.key},
        }


# --------------------------------------------------------------------------
# Node shorthands
# --------------------------------------------------------------------------

def pg(b, name, query, replacement=None, **kw):
    """Postgres executeQuery. Values go through $1 placeholders, never string
    interpolation, so nothing a discovery source or a prospect writes can be
    executed as SQL."""
    params = {"operation": "executeQuery", "query": query, "options": {}}
    if replacement:
        params["options"]["queryReplacement"] = replacement
    kw.setdefault("retries", 3)
    return b.node(name, "n8n-nodes-base.postgres", params, tv=2.5, creds="pg", **kw)


def code(b, name, js, mode="runOnceForAllItems", **kw):
    return b.node(name, "n8n-nodes-base.code",
                  {"mode": mode, "jsCode": js}, tv=2, **kw)


def http(b, name, method, url, *, headers=None, qs=None, body=None,
         creds=None, timeout=30000, **kw):
    params = {"method": method, "url": url,
              "options": {"timeout": timeout,
                          "response": {"response": {"neverError": True,
                                                    "fullResponse": True}}}}
    if headers:
        params["sendHeaders"] = True
        params["headerParameters"] = {"parameters": [
            {"name": k, "value": v} for k, v in headers.items()]}
    if qs:
        params["sendQuery"] = True
        params["queryParameters"] = {"parameters": [
            {"name": k, "value": v} for k, v in qs.items()]}
    if body is not None:
        params["sendBody"] = True
        params["specifyBody"] = "json"
        params["jsonBody"] = body
    kw.setdefault("retries", 3)
    return b.node(name, "n8n-nodes-base.httpRequest", params, tv=4.2,
                  creds=creds, **kw)


def cron(b, name, expression):
    return b.node(name, "n8n-nodes-base.scheduleTrigger",
                  {"rule": {"interval": [{"field": "cronExpression",
                                          "expression": expression}]}}, tv=1.2)


def switch(b, name, value_expr, outputs, fallback="extra", **kw):
    """Switch on a string field. `outputs` is a list of literal values."""
    rules = []
    for i, val in enumerate(outputs):
        rules.append({
            "conditions": {
                "options": {"caseSensitive": True, "leftValue": "",
                            "typeValidation": "strict", "version": 2},
                "conditions": [{
                    "id": f"{name}-{i}",
                    "leftValue": value_expr,
                    "rightValue": val,
                    "operator": {"type": "string", "operation": "equals"},
                }],
                "combinator": "and",
            },
            "renameOutput": True,
            "outputKey": val,
        })
    return b.node(name, "n8n-nodes-base.switch",
                  {"rules": {"values": rules},
                   "options": {"fallbackOutput": fallback}}, tv=3, **kw)


def if_bool(b, name, expr, **kw):
    """Boolean IF. Output 0 = true, output 1 = false."""
    return b.node(name, "n8n-nodes-base.if", {
        "conditions": {
            "options": {"caseSensitive": True, "leftValue": "",
                        "typeValidation": "loose", "version": 2},
            "conditions": [{
                "id": f"{name}-c",
                "leftValue": expr,
                "rightValue": "",
                "operator": {"type": "boolean", "operation": "true",
                             "singleValue": True},
            }],
            "combinator": "and",
        },
        "looseTypeValidation": True,
    }, tv=2, **kw)


def call_workflow(b, name, target_hint, **kw):
    return b.node(name, "n8n-nodes-base.executeWorkflow", {
        "workflowId": {"__rl": True, "value": f"REPLACE_WITH_ID__{target_hint}",
                       "mode": "list", "cachedResultName": target_hint},
        "options": {"waitForSubWorkflow": True},
    }, tv=1.2, notes=f"After import, point this at the '{target_hint}' workflow.", **kw)


def dead_letter(b, name, workflow_key, node_label):
    """Terminal node for anything that cannot be retried. Section 24 of the
    brief: never silently lose a lead or an email event."""
    return pg(b, name, """
INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, lead_id, error, payload)
VALUES ($1, $2, $3, NULLIF($4,'')::uuid, $5, $6::jsonb)
""".strip(),
        replacement=("={{ [ '%s', $execution.id, '%s', ($json.lead_id || ''), "
                     "($json.error || $json.message || 'unknown error'), "
                     "JSON.stringify($json) ] }}" % (workflow_key, node_label)),
        retries=1, notes="Nothing is dropped: unrecoverable items land here for review.")


# Shared JS. Gemini's responseSchema accepts only a subset of JSON Schema, so
# keywords it rejects are stripped before the call rather than causing a 400.
SANITIZE_SCHEMA_JS = """
function sanitizeSchema(s) {
  if (Array.isArray(s)) return s.map(sanitizeSchema);
  if (s === null || typeof s !== 'object') return s;
  const drop = new Set([
    'additionalProperties', 'maxLength', 'minLength', 'pattern',
    '$schema', 'definitions', '$ref', 'default', 'examples',
    'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum',
  ]);
  const out = {};
  for (const [k, v] of Object.entries(s)) {
    if (drop.has(k)) continue;
    out[k] = (k === 'properties')
      ? Object.fromEntries(Object.entries(v).map(([pk, pv]) => [pk, sanitizeSchema(pv)]))
      : sanitizeSchema(v);
  }
  return out;
}
""".strip()

RENDER_TEMPLATE_JS = """
function render(tpl, vars) {
  return String(tpl).replace(/\\{\\{\\s*([a-zA-Z0-9_]+)\\s*\\}\\}/g, (m, k) => {
    if (!(k in vars)) return m;              // leave unknown tokens intact
    const v = vars[k];
    return typeof v === 'string' ? v : JSON.stringify(v, null, 2);
  });
}
""".strip()


# ==========================================================================
# 00 — Error Handler
# Set as the "Error Workflow" on every other workflow. Its whole job is to
# make sure a failed execution leaves a durable record and a human is told.
# ==========================================================================
def wf_error_handler():
    b = Builder("ACQ 00 — Error Handler", "wf00", error_workflow=False)

    t = b.node("On Any Workflow Error", "n8n-nodes-base.errorTrigger", {}, tv=1)

    shape = code(b, "Shape Error", r"""
// n8n hands the error trigger a single item describing the failed execution.
const e = $input.first().json;
const wf = e.workflow || {};
const ex = e.execution || {};
const err = ex.error || e.error || {};

// Some failures are noisy but self-healing (a transient 429, a dropped socket).
// They are still recorded, but they do not wake anyone up at 3am.
const message = String(err.message || 'unknown error');
const transient = /ECONNRESET|ETIMEDOUT|EAI_AGAIN|socket hang up|rate limit|429|503|502|504/i
  .test(message);

return [{
  json: {
    workflow_key: wf.name || 'unknown',
    workflow_id: wf.id || null,
    execution_id: ex.id || null,
    node_name: err.node?.name || ex.lastNodeExecuted || null,
    error: message.slice(0, 2000),
    stack: String(err.stack || '').slice(0, 4000),
    transient,
    alert: !transient,
    payload: JSON.stringify({
      mode: ex.mode || null,
      retryOf: ex.retryOf || null,
      url: ex.url || null,
    }),
  },
}];
""".strip())

    store = pg(b, "Record Dead Letter", """
INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, error, payload)
VALUES ($1, $2, $3, $4, $5::jsonb)
RETURNING id
""".strip(),
        replacement="={{ [ $json.workflow_key, $json.execution_id, $json.node_name, "
                    "$json.error, $json.payload ] }}",
        retries=2,
        notes="If this insert itself fails the execution is still visible in n8n's own log.")

    gate = if_bool(b, "Worth Waking Someone?", "={{ $('Shape Error').first().json.alert }}")

    chat = pg(b, "Get Alert Target", """
SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegram_chat_id'
""".strip(), retries=2)

    alert = b.node("Telegram Alert", "n8n-nodes-base.telegram", {
        "chatId": "={{ $json.chat_id }}",
        "text": "={{ '⚠️ *Workflow failed*\\n\\n'"
                " + '*Workflow:* ' + $('Shape Error').first().json.workflow_key + '\\n'"
                " + '*Node:* ' + ($('Shape Error').first().json.node_name || 'n/a') + '\\n'"
                " + '*Execution:* ' + ($('Shape Error').first().json.execution_id || 'n/a') + '\\n\\n'"
                " + '```\\n' + $('Shape Error').first().json.error.slice(0, 600) + '\\n```' }}",
        "additionalFields": {"parse_mode": "Markdown",
                             "appendAttribution": False},
    }, tv=1.2, creds="telegram", on_error="continueRegularOutput", retries=2,
        notes="Telegram failing must never mask the original error, so this "
              "node continues on failure — the dead letter row is already written.")

    quiet = b.node("Transient — Logged Only", "n8n-nodes-base.noOp", {}, tv=1)

    b.chain(t, shape, store, gate)
    b.connect(gate, chat, src_out=0)
    b.chain(chat, alert)
    b.connect(gate, quiet, src_out=1)
    return b.build()


# ==========================================================================
# 01 — AI Call (shared sub-workflow)
#
# Every AI request in the system goes through here. Centralising it means the
# JSON contract, the single retry, the cost accounting and the "never proceed
# on invalid output" rule are implemented once instead of five times.
#
# Input:  { prompt_key, variables: {...}, lead_id?, purpose? }
# Output: { ok, data, prompt_version, model, tokens, cost_usd, error? }
# ==========================================================================
def wf_ai_call():
    b = Builder("ACQ 01 — AI Call", "wf01")

    t = b.node("When Called", "n8n-nodes-base.executeWorkflowTrigger",
               {"inputSource": "passthrough"}, tv=1.1)

    load = pg(b, "Load Prompt + Settings", """
SELECT acq.get_prompt($1) AS prompt,
       (SELECT jsonb_object_agg(key, value) FROM acq.settings
         WHERE key IN ('company.brand','company.product','company.sender_person',
                       'product.capabilities','demo.booking_url','ai.model','ai.pricing')
       ) AS settings
""".strip(), replacement="={{ $json.prompt_key }}")

    build = code(b, "Build Request", (SANITIZE_SCHEMA_JS + "\n\n" + RENDER_TEMPLATE_JS + "\n\n" + r"""
const input = $('When Called').first().json;
const row = $input.first().json;
const prompt = row.prompt;
const settings = row.settings || {};

if (!prompt) {
  throw new Error(`No active prompt registered for key '${input.prompt_key}'. ` +
                  `Run scripts/load_prompts.py against this database.`);
}

const caps = settings['product.capabilities'] || [];
const bookingUrl = settings['demo.booking_url'] || '';

// Globals every prompt may reference, merged under caller-supplied variables so
// a caller can override for a specific market or language.
const vars = Object.assign({
  brand:                 settings['company.brand'] || 'Zenvexa',
  product:               settings['company.product'] || 'Clinibot',
  sender_person:         settings['company.sender_person'] || 'Umer',
  capabilities:          Array.isArray(caps) ? caps.map(c => `- ${c}`).join('\n') : String(caps),
  booking_url_or_none:   bookingUrl || 'none — do not invent availability',
  language:              'English',
}, input.variables || {});

const model = input.model || settings['ai.model'] || 'gemini-2.5-flash';

const request = {
  systemInstruction: { parts: [{ text: render(prompt.system_prompt, vars) }] },
  contents: [{ role: 'user', parts: [{ text: render(prompt.user_template, vars) }] }],
  generationConfig: {
    temperature: Number(prompt.temperature ?? 0.2),
    responseMimeType: 'application/json',
    responseSchema: sanitizeSchema(prompt.response_schema),
  },
};

return [{
  json: {
    model,
    request,
    attempt: 1,
    prompt_key: input.prompt_key,
    prompt_version: prompt.version,
    purpose: input.purpose || prompt.purpose,
    lead_id: input.lead_id || null,
    required_fields: prompt.response_schema?.required || [],
    pricing: settings['ai.pricing'] || {},
    started_at: Date.now(),
  },
}];
""").strip())

    call = http(b, "Gemini", "POST",
                "=https://generativelanguage.googleapis.com/v1beta/models/{{ $json.model }}:generateContent",
                body="={{ JSON.stringify($json.request) }}", creds="gemini", timeout=60000,
                notes="Auth comes from the httpHeaderAuth credential (x-goog-api-key), so no "
                      "key appears in this file, in the request body, or in any log line.")

    parse_js = r"""
// Validates the model's reply against the prompt's own required-field list.
// Anything that fails here must not reach an email; the caller gets ok:false.
const ctx = $('Build Request').first().json;
const resp = $input.first().json;
const status = resp.statusCode ?? 200;
const body = resp.body ?? resp;

function fail(reason, detail) {
  return [{ json: { ...ctx, ok: false, valid: false, error: reason,
                    detail: String(detail || '').slice(0, 1500) } }];
}

if (status < 200 || status >= 300) {
  return fail(`gemini_http_${status}`, JSON.stringify(body?.error || body));
}

const cand = body?.candidates?.[0];
if (!cand) return fail('no_candidate', JSON.stringify(body).slice(0, 800));

// A truncated response is invalid even if it happens to parse.
if (cand.finishReason && !['STOP', 'MAX_TOKENS'].includes(cand.finishReason)) {
  return fail(`finish_reason_${cand.finishReason}`, JSON.stringify(cand.safetyRatings || {}));
}
if (cand.finishReason === 'MAX_TOKENS') return fail('truncated_output', '');

const text = cand?.content?.parts?.map(p => p.text).join('') || '';
let data;
try {
  data = JSON.parse(text);
} catch (e) {
  return fail('invalid_json', text.slice(0, 800));
}

const missing = (ctx.required_fields || []).filter(
  f => data[f] === undefined || data[f] === null);
if (missing.length) return fail('missing_required_fields', missing.join(', '));

const usage = body.usageMetadata || {};
const inTok = usage.promptTokenCount || 0;
const outTok = usage.candidatesTokenCount || 0;
const rate = (ctx.pricing || {})[ctx.model] || {};
const cost = (inTok / 1e6) * Number(rate.input_per_1m || 0)
           + (outTok / 1e6) * Number(rate.output_per_1m || 0);

return [{
  json: {
    ...ctx, ok: true, valid: true, data,
    input_tokens: inTok, output_tokens: outTok,
    cost_usd: Number(cost.toFixed(6)),
    latency_ms: Date.now() - Number(ctx.started_at || Date.now()),
  },
}];
""".strip()

    parse = code(b, "Parse & Validate", parse_js)
    ok1 = if_bool(b, "Valid?", "={{ $json.valid }}")

    retry_build = code(b, "Build Retry Request", r"""
// One retry, and only one. The retry does not re-ask the same way: it shows the
// model exactly what it got wrong, which fixes far more failures than a repeat.
const prev = $input.first().json;
const req = JSON.parse(JSON.stringify(prev.request));

req.generationConfig.temperature = 0;
req.contents.push({
  role: 'model',
  parts: [{ text: '(previous response was rejected)' }],
});
req.contents.push({
  role: 'user',
  parts: [{ text:
    'Your previous response was rejected: ' + prev.error +
    (prev.detail ? ('\n\nDetail: ' + prev.detail) : '') +
    '\n\nReturn ONLY a JSON object matching the schema exactly. ' +
    'Every field listed in "required" must be present and non-null. ' +
    'Do not wrap it in markdown fences and do not add commentary.' }],
});

return [{ json: { ...prev, request: req, attempt: 2, started_at: Date.now() } }];
""".strip())

    retry_call = http(b, "Gemini Retry", "POST",
                      "=https://generativelanguage.googleapis.com/v1beta/models/{{ $json.model }}:generateContent",
                      body="={{ JSON.stringify($json.request) }}", creds="gemini", timeout=60000)

    parse2 = code(b, "Parse & Validate (Retry)",
                  parse_js.replace("$('Build Request')", "$('Build Retry Request')"))
    ok2 = if_bool(b, "Valid After Retry?", "={{ $json.valid }}")

    log_ok = pg(b, "Log AI Call", """
INSERT INTO acq.ai_calls (purpose, model, lead_id, prompt_version, input_tokens,
                          output_tokens, cost_usd, latency_ms, ok, execution_id)
VALUES ($1, $2, NULLIF($3,'')::uuid, $4, $5::int, $6::int, $7::numeric, $8::int, true, $9)
""".strip(),
        replacement="={{ [ $json.purpose, $json.model, ($json.lead_id || ''), "
                    "$json.prompt_version, $json.input_tokens, $json.output_tokens, "
                    "$json.cost_usd, $json.latency_ms, $execution.id ] }}",
        on_error="continueRegularOutput",
        notes="Cost accounting must never block a successful result.")

    log_fail = pg(b, "Log Failed AI Call", """
INSERT INTO acq.ai_calls (purpose, model, lead_id, prompt_version, ok, error, execution_id)
VALUES ($1, $2, NULLIF($3,'')::uuid, $4, false, $5, $6)
""".strip(),
        replacement="={{ [ $json.purpose, $json.model, ($json.lead_id || ''), "
                    "$json.prompt_version, ($json.error + ': ' + ($json.detail || '')), "
                    "$execution.id ] }}",
        on_error="continueRegularOutput")

    dl = dead_letter(b, "Record AI Dead Letter", "01_ai_call", "Gemini Retry")

    ret_ok = code(b, "Return Result", r"""
const j = $input.first().json;
return [{ json: {
  ok: true,
  data: j.data,
  prompt_key: j.prompt_key,
  prompt_version: j.prompt_version,
  model: j.model,
  lead_id: j.lead_id,
  attempt: j.attempt,
  input_tokens: j.input_tokens,
  output_tokens: j.output_tokens,
  cost_usd: j.cost_usd,
} }];
""".strip())

    ret_fail = code(b, "Return Failure", r"""
// Deliberately returns ok:false rather than throwing. The caller decides what a
// failed AI call means — for research it means skip the lead, for personalization
// it means do not send an email. Neither should look like a workflow crash.
const j = $input.first().json;
return [{ json: {
  ok: false,
  error: j.error,
  detail: j.detail,
  prompt_key: j.prompt_key,
  lead_id: j.lead_id,
  attempts: 2,
} }];
""".strip())

    b.chain(t, load, build, call, parse, ok1)
    b.connect(ok1, log_ok, src_out=0)
    b.chain(log_ok, ret_ok)
    b.connect(ok1, retry_build, src_out=1)
    b.chain(retry_build, retry_call, parse2, ok2)
    b.connect(ok2, log_ok, src_out=0)
    b.connect(ok2, log_fail, src_out=1)
    b.chain(log_fail, dl, ret_fail)
    return b.build()


def wait_node(b, name, seconds, **kw):
    return b.node(name, "n8n-nodes-base.wait",
                  {"resume": "timeInterval", "amount": seconds, "unit": "seconds"},
                  tv=1.1, **kw)


def loop_node(b, name, size=1, **kw):
    """splitInBatches. Output 0 = 'done', output 1 = 'loop'."""
    return b.node(name, "n8n-nodes-base.splitInBatches",
                  {"batchSize": size, "options": {}}, tv=3, **kw)


# ==========================================================================
# 10 — Lead Discovery
#
# Runs each weekday morning. The one thing worth noticing in the ordering:
# already-known businesses are filtered out BEFORE the paid Place Details
# lookup, not after. Details is the expensive SKU, and after the first pass
# most search results are businesses already in the CRM — so this ordering is
# the difference between paying once per clinic and paying every month.
# ==========================================================================
def wf_discovery():
    b = Builder("ACQ 10 — Lead Discovery", "wf10")

    t = cron(b, "Every Weekday 08:00", "0 8 * * 1-5")

    budget = pg(b, "Check Budget + Settings", """
SELECT
  now()                                                             AS started_at,
  COALESCE((SELECT sum(cost_usd) FROM acq.ai_calls
             WHERE created_at::date = CURRENT_DATE), 0)             AS spent_today,
  (SELECT (value #>> '{}')::numeric FROM acq.settings WHERE key = 'ai.daily_cost_cap_usd')      AS cap,
  (SELECT (value #>> '{}')::int     FROM acq.settings WHERE key = 'discovery.max_tasks_per_run')     AS max_tasks,
  (SELECT (value #>> '{}')::int     FROM acq.settings WHERE key = 'discovery.max_new_leads_per_run') AS max_new,
  (SELECT  value #>> '{}'           FROM acq.settings WHERE key = 'discovery.crawl_user_agent')      AS user_agent
""".strip())

    within = if_bool(b, "Within Budget?", "={{ $json.spent_today < $json.cap }}")

    halted = pg(b, "Log Budget Halt", """
INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, finished_at, error, meta)
VALUES ('10_lead_discovery', $1, 'ERROR', now(), 'daily_cost_cap_reached', $2::jsonb)
""".strip(),
        replacement="={{ [ $execution.id, JSON.stringify({ spent_today: $json.spent_today, cap: $json.cap }) ] }}",
        notes="Discovery stops rather than quietly overspending. Raise ai.daily_cost_cap_usd to resume.")

    tasks = pg(b, "Claim Discovery Tasks", """
SELECT id, city, area, query_term, category, provider, priority_tier, bbox,
       (SELECT code FROM acq.markets m WHERE m.id = d.market_id) AS market_code
FROM acq.next_discovery_tasks($1::int) d
""".strip(),
        replacement="={{ [ $json.max_tasks ] }}",
        always_output=True,
        notes="next_discovery_tasks() claims and reschedules atomically, so two "
              "overlapping runs never process the same area twice.")

    loop = loop_node(b, "Per Task", 1)
    route = switch(b, "Route Provider", "={{ $json.provider }}", ["OSM", "GOOGLE_PLACES"])

    # ---------------- OSM branch (free) ----------------
    osm_q = code(b, "Build Overpass Query", r"""
const t = $input.first().json;
const bb = t.bbox || {};
const lat = bb.lat, lng = bb.lng, r = bb.radius_m || 3000;

if (lat == null || lng == null) {
  throw new Error(`Discovery task ${t.id} has no usable search centre in bbox.`);
}

// One call returns every healthcare POI around the point; the category is read
// off the tags afterwards. `nwr` covers nodes, ways and relations.
const q = `[out:json][timeout:60];
(
  nwr["amenity"~"^(clinic|doctors|dentist)$"](around:${r},${lat},${lng});
  nwr["healthcare"](around:${r},${lat},${lng});
);
out center tags 300;`;

return [{ json: { ...t, overpass_query: q } }];
""".strip())

    osm_call = http(b, "Overpass API", "GET", "https://overpass-api.de/api/interpreter",
                    qs={"data": "={{ $json.overpass_query }}"},
                    headers={"User-Agent": "={{ $('Check Budget + Settings').first().json.user_agent }}"},
                    timeout=90000, retries=2,
                    notes="Overpass is a free volunteer service. One call per area, "
                          "a pause between calls, and an honest User-Agent are the "
                          "terms of using it — do not raise the rate.")

    osm_norm = code(b, "Normalize OSM Results", r"""
const task = $('Build Overpass Query').first().json;
const maxNew = $('Check Budget + Settings').first().json.max_new || 60;
const resp = $input.first().json;
const body = resp.body ?? resp;
const elements = body.elements || [];

// Tag-driven category assignment. Falls back to name keywords because OSM in
// Pakistan reliably records amenity=clinic/doctors/dentist but rarely records
// healthcare:speciality.
function categorize(tags, name) {
  const spec = (tags['healthcare:speciality'] || '').toLowerCase();
  const hc = (tags.healthcare || '').toLowerCase();
  const am = (tags.amenity || '').toLowerCase();
  const n = (name || '').toLowerCase();
  const has = (...w) => w.some(x => spec.includes(x) || n.includes(x));

  if (am === 'dentist' || hc === 'dentist' || has('dental', 'dentist', 'orthodont'))
    return ['DENTAL', 1];
  if (has('dermatolog', 'skin')) return ['DERMATOLOGY', 1];
  if (has('plastic_surgery', 'plastic surgery', 'cosmetic surgery')) return ['PLASTIC_SURGERY', 1];
  if (has('cosmetic', 'aesthetic', 'laser', 'hair transplant')) return ['AESTHETIC', 1];
  if (has('fertility', 'ivf', 'gynaecolog', 'gynecolog')) return ['FERTILITY', 1];
  if (hc === 'physiotherapist' || has('physiotherap', 'physical therapy')) return ['PHYSIOTHERAPY', 1];
  if (has('eye', 'ophthalm', 'ent ', 'cardiolog', 'orthoped', 'urolog', 'neurolog'))
    return ['SPECIALIST', 1];
  if (hc === 'laboratory' || has('diagnostic', 'laborator', 'radiolog', 'imaging'))
    return ['DIAGNOSTIC', 2];
  if (am === 'clinic' || am === 'doctors' || hc === 'doctor') return ['GENERAL_PRACTICE', 2];
  return ['OTHER', 3];
}

const out = [];
for (const el of elements) {
  const tags = el.tags || {};
  const name = (tags.name || tags['name:en'] || '').trim();

  // No name means nothing citable to write about, and nothing to deduplicate on.
  if (!name) continue;

  // Hospitals and government facilities are out of scope by design.
  if ((tags.amenity || '') === 'hospital') continue;

  const [category, tier] = categorize(tags, name);
  const osmUrl = `https://www.openstreetmap.org/${el.type}/${el.id}`;
  const email = tags['contact:email'] || tags.email || null;
  const website = tags['contact:website'] || tags.website || null;
  const phone = tags['contact:phone'] || tags.phone || null;
  const whatsapp = tags['contact:whatsapp'] || tags.whatsapp || null;

  const contacts = [];
  if (email)    contacts.push({ contact_type: 'EMAIL',    value: email,    source: 'OSM', source_url: osmUrl, is_primary: true });
  if (phone)    contacts.push({ contact_type: 'PHONE',    value: phone,    source: 'OSM', source_url: osmUrl });
  if (whatsapp) contacts.push({ contact_type: 'WHATSAPP', value: whatsapp, source: 'OSM', source_url: osmUrl });

  out.push({ json: {
    market_code: task.market_code,
    clinic_name: name,
    website,
    city: task.city,
    area: task.area || tags['addr:suburb'] || null,
    address: [tags['addr:housenumber'], tags['addr:street'], tags['addr:suburb']]
               .filter(Boolean).join(' ') || null,
    lat: String(el.lat ?? el.center?.lat ?? ''),
    lng: String(el.lon ?? el.center?.lon ?? ''),
    phone,
    whatsapp,
    // An email tagged in OSM is publicly published data with a citable URL,
    // so it carries real provenance. Anything without both is dropped by
    // acq.upsert_lead rather than guessed at.
    public_email: email,
    email_source: email ? 'OSM' : null,
    email_evidence_url: email ? osmUrl : null,
    category,
    priority_tier: tier,
    source: 'OSM',
    source_url: osmUrl,
    source_ref: `${el.type}/${el.id}`,
    source_ref_type: 'OSM_ID',
    contacts,
    raw: { OSM: { tags, element_type: el.type, element_id: el.id } },
  }});
  if (out.length >= maxNew) break;
}
return out;
""".strip())

    # ---------------- Google Places branch (paid) ----------------
    places_search = http(b, "Places Text Search", "POST",
        "https://places.googleapis.com/v1/places:searchText",
        headers={
            # Minimal field mask keeps this on the cheapest search SKU. Website
            # and phone are deliberately NOT requested here — they come from the
            # Details call, which only runs for businesses we do not already have.
            "X-Goog-FieldMask": "places.id,places.displayName,places.formattedAddress,places.primaryType",
        },
        body="={{ JSON.stringify({"
             " textQuery: $json.query_term + ' in ' + ($json.area ? $json.area + ', ' : '') + $json.city,"
             " maxResultCount: 20,"
             " locationBias: { circle: { center: { latitude: $json.bbox.lat, longitude: $json.bbox.lng },"
             " radius: $json.bbox.radius_m } } }) }}",
        creds="places", retries=2,
        notes="Cheapest field mask on purpose. Enriching fields are fetched per "
              "business in the Details call below, only for new businesses.")

    places_cands = code(b, "Collect Place IDs", r"""
const task = $('Per Task').first().json;
const resp = $input.first().json;
const body = resp.body ?? resp;

if (resp.statusCode && resp.statusCode >= 300) {
  throw new Error(`Places search failed ${resp.statusCode}: ` +
                  JSON.stringify(body?.error || body).slice(0, 400));
}

const places = body.places || [];
return [{ json: {
  task,
  place_ids: places.map(p => p.id).filter(Boolean),
  found: places.length,
  by_id: Object.fromEntries(places.map(p => [p.id, p])),
}}];
""".strip())

    places_filter = pg(b, "Drop Already-Known Places", """
SELECT ref
FROM acq.filter_unknown_refs('PLACE_ID',
       ARRAY(SELECT jsonb_array_elements_text($1::jsonb)))
""".strip(),
        replacement="={{ JSON.stringify($json.place_ids) }}",
        always_output=True,
        notes="THE cost lever. Place Details is billed per call; this removes every "
              "business already in the CRM before a single Details request is made.")

    places_details = http(b, "Place Details (new only)", "GET",
        "=https://places.googleapis.com/v1/places/{{ $json.ref }}",
        headers={"X-Goog-FieldMask":
                 "id,displayName,formattedAddress,location,websiteUri,"
                 "internationalPhoneNumber,nationalPhoneNumber,primaryType,"
                 "userRatingCount,rating,editorialSummary,businessStatus"},
        creds="places", retries=2)

    places_norm = code(b, "Normalize Place Details", r"""
const task = $('Per Task').first().json;
const resp = $input.first().json;
const p = resp.body ?? resp;

if (!p || !p.id) return [];
if (p.businessStatus && p.businessStatus !== 'OPERATIONAL') return [];

const name = p.displayName?.text || '';
if (!name) return [];
if (/\b(hospital|medical centre complex|trust)\b/i.test(name)) return [];

const mapsUrl = `https://www.google.com/maps/place/?q=place_id:${p.id}`;
const phone = p.internationalPhoneNumber || p.nationalPhoneNumber || null;

function categorize(type, n) {
  const s = `${type || ''} ${n}`.toLowerCase();
  if (/dental|dentist|orthodont/.test(s))            return ['DENTAL', 1];
  if (/dermatolog|skin/.test(s))                     return ['DERMATOLOGY', 1];
  if (/plastic surgery|plastic_surgeon/.test(s))     return ['PLASTIC_SURGERY', 1];
  if (/cosmetic|aesthetic|laser|hair transplant/.test(s)) return ['AESTHETIC', 1];
  if (/fertility|ivf/.test(s))                       return ['FERTILITY', 1];
  if (/physiotherap|physical_therapist/.test(s))     return ['PHYSIOTHERAPY', 1];
  if (/diagnostic|laborator|radiolog/.test(s))       return ['DIAGNOSTIC', 2];
  if (/doctor|clinic|physician/.test(s))             return ['GENERAL_PRACTICE', 2];
  return ['OTHER', 3];
}
const [category, tier] = categorize(p.primaryType, name);

const contacts = [];
if (phone) contacts.push({ contact_type: 'PHONE', value: phone,
                           source: 'GOOGLE_BUSINESS', source_url: mapsUrl });

// Google Places does not expose email addresses. None is invented here; if the
// clinic publishes one on its own site, workflow 30 reads it there with the
// page URL recorded as evidence.
return [{ json: {
  market_code: task.market_code,
  clinic_name: name,
  website: p.websiteUri || null,
  city: task.city,
  area: task.area || null,
  address: p.formattedAddress || null,
  lat: String(p.location?.latitude ?? ''),
  lng: String(p.location?.longitude ?? ''),
  phone,
  public_email: null,
  category: category === 'OTHER' ? (task.category === 'ANY' ? 'OTHER' : task.category) : category,
  priority_tier: tier,
  source: 'GOOGLE_PLACES',
  source_url: mapsUrl,
  source_ref: p.id,
  source_ref_type: 'PLACE_ID',
  contacts,
  raw: { GOOGLE_PLACES: {
    userRatingCount: p.userRatingCount ?? 0,
    rating: p.rating ?? null,
    primaryType: p.primaryType ?? null,
    editorialSummary: p.editorialSummary?.text ?? null,
  }},
}}];
""".strip())

    upsert = pg(b, "Upsert Lead", "SELECT acq.upsert_lead($1::jsonb) AS result",
                replacement="={{ JSON.stringify($json) }}",
                notes="One entry point for every source. Deduplication, provenance "
                      "checking and contact recording all happen inside this call.")

    pause = wait_node(b, "Pause Between Areas", 4,
                      notes="Politeness delay for Overpass and a natural rate limit for Places.")

    record = pg(b, "Record Run", """
INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, items_out, finished_at, meta)
VALUES ('10_lead_discovery', $1, 'SUCCESS',
        (SELECT count(*) FROM acq.leads WHERE created_at >= $2::timestamptz),
        now(), jsonb_build_object('note','items_out counts leads created since run start'))
""".strip(),
        replacement="={{ [ $execution.id, $('Check Budget + Settings').first().json.started_at ] }}")

    b.chain(t, budget, within)
    b.connect(within, tasks, src_out=0)
    b.connect(within, halted, src_out=1)
    b.chain(tasks, loop)
    b.connect(loop, route, src_out=1)          # loop branch
    b.connect(loop, record, src_out=0)         # done branch

    b.connect(route, osm_q, src_out=0)
    b.chain(osm_q, osm_call, osm_norm, upsert)

    b.connect(route, places_search, src_out=1)
    b.chain(places_search, places_cands, places_filter, places_details, places_norm)
    b.connect(places_norm, upsert)

    # unmatched provider falls through the switch's extra output
    b.connect(route, pause, src_out=2)
    b.chain(upsert, pause)
    b.connect(pause, loop)                     # back around the loop
    return b.build()


# ==========================================================================
# 20 — Lead Qualification (deterministic, zero AI cost)
#
# Section 19 of the brief: cheap checks first. Every lead passes through here,
# and most are rejected here, so the AI in workflow 30 only ever sees leads
# that are already worth spending tokens on.
# ==========================================================================
def wf_qualification():
    b = Builder("ACQ 20 — Lead Qualification", "wf20")

    t = cron(b, "Every 30 Minutes", "*/30 * * * *")

    claim = pg(b, "Claim New Leads", """
SELECT id, clinic_name, website, city, area, phone, whatsapp, public_email,
       category, priority_tier, source, domain
FROM acq.claim_leads(ARRAY['NEW']::acq.lead_status[], 50, $1)
""".strip(),
        replacement="={{ [ 'wf20:' + $execution.id ] }}",
        always_output=True,
        notes="FOR UPDATE SKIP LOCKED inside claim_leads means overlapping runs "
              "take disjoint work instead of colliding.")

    triage = code(b, "Deterministic Triage", r"""
// Rejections that need no model call and no network request. Anything decided
// here costs nothing, which is the whole point of running it before workflow 30.
const out = [];
for (const item of $input.all()) {
  const l = item.json;
  const reasons = [];

  const hasEmail = !!l.public_email;
  const hasPhone = !!l.phone;
  const hasWhatsapp = !!l.whatsapp;
  const hasWebsite = !!l.website;

  if (!hasEmail && !hasPhone && !hasWhatsapp) reasons.push('no_contact_channel');
  if (!hasWebsite && !hasEmail) reasons.push('nothing_to_research');
  if (/\b(hospital|trust|foundation|government|govt|welfare|charitable|medical college)\b/i
        .test(l.clinic_name || '')) reasons.push('large_institution');
  if ((l.clinic_name || '').trim().length < 3) reasons.push('unusable_name');
  if (/\b(pharmacy|medical store|chemist|drug store)\b/i.test(l.clinic_name || ''))
    reasons.push('not_appointment_based');

  out.push({ json: {
    ...l,
    disqualified: reasons.length > 0,
    disqualify_reasons: reasons,
    // Only leads with a research surface are worth an AI call.
    researchable: hasWebsite,
  }});
}
return out;
""".strip())

    score = pg(b, "Score (Deterministic)",
               "SELECT acq.compute_score($1::uuid, 'DETERMINISTIC') AS score",
               replacement="={{ [ $json.id ] }}")

    decide = code(b, "Decide Next Status", r"""
// Pairs each scoring result back with its triage item. The Postgres node emits
// one output row per input item in the same order, so index alignment holds.
const triaged = $('Deterministic Triage').all();
const out = [];

$input.all().forEach((item, i) => {
  const lead = triaged[i].json;
  const s = item.json.score || {};
  const score = s.score ?? 0;
  const qualifies = s.qualifies === true;

  let status, reason;
  if (lead.disqualified) {
    status = lead.disqualify_reasons.includes('no_contact_channel') ? 'INVALID' : 'REJECTED';
    reason = lead.disqualify_reasons.join(',');
  } else if (!qualifies) {
    status = 'REJECTED';
    reason = `score_below_threshold:${score}`;
  } else if (!lead.researchable) {
    // Qualifies on paper but there is nothing public to write a personal email
    // from. A human can decide; the system will not send something generic.
    status = 'READY_FOR_REVIEW';
    reason = 'qualified_but_no_website_to_research';
  } else {
    status = 'QUALIFIED';
    reason = `score:${score}`;
  }

  out.push({ json: { lead_id: lead.id, clinic_name: lead.clinic_name,
                     score, status, reason } });
});
return out;
""".strip())

    move = pg(b, "Apply Status", """
SELECT acq.transition_lead($1::uuid, $2::acq.lead_status, $3, 'SYSTEM', $4) AS result
""".strip(),
        replacement="={{ [ $json.lead_id, $json.status, $json.reason, $execution.id ] }}")

    record = pg(b, "Record Run", """
INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, items_out, finished_at)
VALUES ('20_lead_qualification', $1, 'SUCCESS', $2::int, now())
""".strip(),
        replacement="={{ [ $execution.id, $input.all().length ] }}",
        execute_once=True)

    b.chain(t, claim, triage, score, decide, move, record)
    return b.build()


# ==========================================================================
# 30 — AI Research and Enrichment
#
# The only workflow that reads clinic websites. It obeys robots.txt, identifies
# itself, caps pages per site and paces requests, because the alternative is
# exactly the aggressive scraping the brief rules out. Results are cached until
# ai.research_ttl_days so no clinic is ever researched twice for free.
# ==========================================================================
def wf_research():
    b = Builder("ACQ 30 — AI Research", "wf30")

    t = cron(b, "Hourly (Business Hours)", "0 6-14 * * 1-5")

    claim = pg(b, "Claim Leads Needing Research", """
-- The predicate lives INSIDE the claim. Filtering after acq.claim_leads() would
-- lock every lead it picked and then discard most of them, leaving them locked
-- and unusable for 15 minutes and starving workflow 40 of the same status.
SELECT id, clinic_name, website, domain, city, area, category,
       phone, whatsapp, public_email, doctor_count, source_url, lead_score, raw
FROM acq.claim_leads_for_research(
       (SELECT (value #>> '{}')::int FROM acq.settings WHERE key = 'ai.max_research_per_run'),
       $1)
""".strip(),
        replacement="={{ [ 'wf30:' + $execution.id ] }}", always_output=True)

    loop = loop_node(b, "Per Lead", 1)

    plan = code(b, "Plan Fetch", r"""
const l = $input.first().json;
let origin;
try {
  origin = new URL(l.website.startsWith('http') ? l.website : `https://${l.website}`).origin;
} catch (e) {
  return [{ json: { ...l, fetch_error: 'unparseable_website_url', pages: [] } }];
}
return [{ json: { ...l, origin, robots_url: `${origin}/robots.txt` } }];
""".strip())

    robots = http(b, "Fetch robots.txt", "GET", "={{ $json.robots_url }}",
                  headers={"User-Agent": "={{ $('Load Crawl Settings').first().json.user_agent }}"},
                  timeout=10000, retries=1, on_error="continueRegularOutput",
                  notes="A missing or unreachable robots.txt is treated as 'allowed', "
                        "which is the standard interpretation.")

    crawl_settings = pg(b, "Load Crawl Settings", """
SELECT (SELECT  value #>> '{}'       FROM acq.settings WHERE key = 'discovery.crawl_user_agent') AS user_agent,
       (SELECT (value #>> '{}')::int FROM acq.settings WHERE key = 'discovery.max_pages_per_site') AS max_pages
""".strip(), execute_once=True)

    check_robots = code(b, "Apply robots.txt", r"""
// A deliberately conservative robots.txt reader: it honours Disallow rules for
// our own User-agent and for *, and on any doubt it fetches nothing. Being
// wrong in the permissive direction means crawling somewhere we were asked not
// to, which is exactly what section 3 of the brief forbids.
const lead = $('Plan Fetch').first().json;
const cfg = $('Load Crawl Settings').first().json;
const resp = $input.first().json;
const maxPages = cfg.max_pages || 3;

if (lead.fetch_error) return [{ json: { ...lead, allowed_urls: [], robots_allowed: false } }];

const status = resp.statusCode ?? 0;
const text = (status >= 200 && status < 300) ? String(resp.body ?? '') : '';

const disallow = [];
let applies = false;
for (const raw of text.split(/\r?\n/)) {
  const line = raw.split('#')[0].trim();
  if (!line) continue;
  const [rawKey, ...rest] = line.split(':');
  const key = rawKey.trim().toLowerCase();
  const val = rest.join(':').trim();
  if (key === 'user-agent') {
    applies = (val === '*' || /zenvexa/i.test(val));
  } else if (key === 'disallow' && applies && val) {
    disallow.push(val);
  }
}

const blocked = (path) => disallow.some(d => d === '/' || path.startsWith(d));

// Only pages that plausibly describe the practice. No search pages, no
// pagination, no crawling the whole site.
const candidates = ['/', '/contact', '/contact-us', '/about', '/services', '/team', '/doctors'];
const allowed = [];
for (const path of candidates) {
  if (blocked(path)) continue;
  allowed.push(`${lead.origin}${path === '/' ? '' : path}`);
  if (allowed.length >= maxPages) break;
}

return [{ json: {
  ...lead,
  allowed_urls: allowed,
  robots_allowed: allowed.length > 0,
  robots_disallow_rules: disallow,
}}];
""".strip())

    any_pages = if_bool(b, "Any Pages Allowed?", "={{ $json.robots_allowed }}")

    expand = code(b, "Expand Page URLs", r"""
const j = $input.first().json;
return j.allowed_urls.map(u => ({ json: { url: u, lead_id: j.id } }));
""".strip())

    fetch_page = http(b, "Fetch Page", "GET", "={{ $json.url }}",
                      headers={"User-Agent": "={{ $('Load Crawl Settings').first().json.user_agent }}",
                               "Accept": "text/html"},
                      timeout=15000, retries=1, on_error="continueRegularOutput",
                      notes="Continues on error so one dead URL does not abandon the lead.")

    no_fetch = b.node("Nothing Fetchable", "n8n-nodes-base.noOp", {}, tv=1)

    extract = code(b, "Extract Text + Emails", r"""
const lead = $('Apply robots.txt').first().json;

function toText(html) {
  return String(html)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
}

const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const NOT_AN_ADDRESS = /\.(png|jpe?g|gif|svg|webp|css|js|woff2?)$/i;

const pages = [];
const found = [];   // every candidate address, with the page it was read from

for (const item of $input.all()) {
  const r = item.json;
  const url = r.url || r.request?.uri || '';
  const status = r.statusCode ?? 0;
  if (status < 200 || status >= 300) continue;
  const body = typeof r.body === 'string' ? r.body : '';
  if (!body) continue;

  const text = toText(body);
  if (text.length < 40) continue;
  pages.push({ url, text: text.slice(0, 6000) });

  for (const m of (body.match(EMAIL_RE) || [])) {
    const addr = m.toLowerCase();
    if (NOT_AN_ADDRESS.test(addr)) continue;
    if (/(example|sentry|wixpress|godaddy|wordpress|@2x)/.test(addr)) continue;
    if (!found.some(f => f.email === addr)) found.push({ email: addr, url });
  }
}

// Prefer an address on the clinic's own domain: a generic address found on a
// clinic site is far more likely to be the web designer's than the clinic's.
const site = (lead.domain || '').replace(/^www\./, '');
found.sort((a, b) => {
  const aOwn = site && a.email.endsWith(`@${site}`) ? 0 : 1;
  const bOwn = site && b.email.endsWith(`@${site}`) ? 0 : 1;
  return aOwn - bOwn;
});
const best = found[0] || null;

const combined = pages
  .map(p => `--- ${p.url} ---\n${p.text}`)
  .join('\n\n')
  .slice(0, 14000);

return [{ json: {
  ...lead,
  page_content: combined,
  fetched_urls: pages.map(p => p.url),
  pages_fetched: pages.length,
  // Recorded with the exact page it was read from, which is what makes it a
  // fact rather than a guess. acq.upsert_lead rejects it without that URL.
  discovered_email: best?.email || null,
  discovered_email_url: best?.url || null,
  all_emails_found: found,
}}];
""".strip())

    ai_in = code(b, "Build AI Input", r"""
const j = $input.first().json;
return [{ json: {
  prompt_key: 'research_clinic',
  purpose: 'RESEARCH',
  lead_id: j.id,
  variables: {
    lead_json: {
      clinic_name: j.clinic_name, website: j.website, city: j.city, area: j.area,
      category: j.category, phone: j.phone, whatsapp: j.whatsapp,
      public_email: j.public_email || j.discovered_email,
      doctor_count: j.doctor_count, source_url: j.source_url,
    },
    page_content: j.page_content || '(no page content could be retrieved)',
    fetched_urls: j.fetched_urls || [],
  },
}}];
""".strip())

    ai = call_workflow(b, "AI: Research Clinic", "ACQ 01 — AI Call")

    handle = code(b, "Handle Research Result", r"""
const src = $('Extract Text + Emails').first().json;
const res = $input.first().json;

if (!res.ok) {
  return [{ json: { lead_id: src.id, ok: false, error: res.error,
                    next_status: 'READY_FOR_REVIEW',
                    reason: `research_failed:${res.error}` } }];
}

const d = res.data;
const disq = Array.isArray(d.disqualifiers) ? d.disqualifiers : [];

// The model's own confidence gates whether its output is trusted at all. Thin
// pages produce confident-sounding but empty briefs; below 0.4 the lead goes to
// a human rather than into an email.
let next_status = 'QUALIFIED', reason = `researched:${d.confidence}`;
if (disq.length) {
  next_status = 'REJECTED';
  reason = `disqualified:${disq.join(',')}`;
} else if (Number(d.confidence) < 0.4) {
  next_status = 'READY_FOR_REVIEW';
  reason = `low_research_confidence:${d.confidence}`;
}

return [{ json: {
  lead_id: src.id,
  ok: true,
  next_status,
  reason,
  prompt_version: res.prompt_version,
  model: res.model,
  research: {
    clinic_type: d.clinic_type,
    facts: d.facts || [],
    inferences: d.inferences || [],
    services: d.services || [],
    doctor_count_estimate: d.doctor_count_estimate ?? null,
    has_whatsapp: !!d.has_whatsapp,
    has_online_booking: !!d.has_online_booking,
    has_visible_reception: !!d.has_visible_reception,
    pain_point: d.pain_point || '',
    recommended_pitch: d.recommended_pitch || '',
    relevance_reason: d.relevance_reason || '',
    confidence: d.confidence,
    raw: {
      advertises_appointments: !!d.advertises_appointments,
      high_value_services: !!d.high_value_services,
      active_social_presence: !!d.active_social_presence,
      doctor_count_basis: d.doctor_count_basis || '',
      disqualifiers: disq,
    },
  },
  fetched_urls: src.fetched_urls || [],
  robots_allowed: src.robots_allowed,
  discovered_email: src.discovered_email,
  discovered_email_url: src.discovered_email_url,
}}];
""".strip())

    save_email = pg(b, "Record Discovered Email", """
-- Only fills an address the lead does not already have, and only with the page
-- URL it was read from. The CHECK constraint on acq.leads refuses it otherwise.
UPDATE acq.leads
   SET public_email       = $2::citext,
       email_source       = 'CLINIC_WEBSITE',
       email_evidence_url = $3
 WHERE id = $1::uuid
   AND public_email IS NULL
   AND $2 <> ''
   AND $3 <> ''
""".strip(),
        replacement="={{ [ $json.lead_id, ($json.discovered_email || ''), "
                    "($json.discovered_email_url || '') ] }}",
        on_error="continueRegularOutput")

    save = pg(b, "Save Research", """
WITH archived AS (
  UPDATE acq.lead_research SET is_current = false
   WHERE lead_id = $1::uuid AND is_current
)
INSERT INTO acq.lead_research (
  lead_id, is_current, clinic_type, facts, inferences, services,
  doctor_count_estimate, has_whatsapp, has_online_booking, has_visible_reception,
  pain_point, recommended_pitch, relevance_reason, confidence,
  model, prompt_version, fetched_urls, robots_allowed, raw, stale_after)
SELECT $1::uuid, true,
       r->>'clinic_type', r->'facts', r->'inferences', r->'services',
       NULLIF(r->>'doctor_count_estimate','')::int,
       (r->>'has_whatsapp')::boolean, (r->>'has_online_booking')::boolean,
       (r->>'has_visible_reception')::boolean,
       r->>'pain_point', r->>'recommended_pitch', r->>'relevance_reason',
       NULLIF(r->>'confidence','')::numeric,
       $3, $4, ARRAY(SELECT jsonb_array_elements_text($5::jsonb)),
       $6::boolean, r->'raw',
       now() + make_interval(days =>
         (SELECT (value #>> '{}')::int FROM acq.settings WHERE key = 'ai.research_ttl_days'))
FROM (SELECT $2::jsonb AS r) s
RETURNING id
""".strip(),
        replacement="={{ [ $json.lead_id, JSON.stringify($json.research), $json.model, "
                    "$json.prompt_version, JSON.stringify($json.fetched_urls), "
                    "$json.robots_allowed ] }}")

    # ---- qualification pass -------------------------------------------
    # research_clinic extracts facts; score_lead judges what they mean. Keeping
    # those separate means the extraction prompt is never also asked to decide
    # whether to contact someone, which is where "helpful" models start
    # promoting inferences to facts.
    qual_in = code(b, "Build Qualification Input", r"""
const src = $('Handle Research Result').first().json;
const lead = $('Extract Text + Emails').first().json;
return [{ json: {
  prompt_key: 'score_lead',
  purpose: 'SCORE',
  lead_id: src.lead_id,
  variables: {
    lead_json: {
      clinic_name: lead.clinic_name, city: lead.city, area: lead.area,
      category: lead.category, website: lead.website,
      public_email: lead.public_email || lead.discovered_email,
      phone: lead.phone, whatsapp: lead.whatsapp, lead_score: lead.lead_score,
    },
    research_json: src.research,
  },
}}];
""".strip())

    qual_ai = call_workflow(b, "AI: Qualify Lead", "ACQ 01 — AI Call")

    qual_merge = code(b, "Merge Qualification", r"""
// Decides the lead's final status from BOTH passes. A failed qualification call
// is not treated as approval: the research verdict stands and nothing is
// patched, so the lead simply proceeds on the weaker evidence.
const research = $('Handle Research Result').first().json;
const res = $input.first().json;

if (!res.ok) {
  return [{ json: {
    lead_id: research.lead_id,
    qualification: null,
    next_status: research.next_status,
    reason: research.reason + `;qualification_failed:${res.error}`,
  }}];
}

const q = res.data;
const disq = Array.isArray(q.disqualifiers) ? q.disqualifiers : [];

// The qualification pass can only ever be MORE restrictive than the research
// pass. It can reject a lead research let through; it cannot rescue one
// research already rejected.
let next_status = research.next_status;
let reason = research.reason;

if (research.next_status !== 'REJECTED') {
  if (q.recommend_contact === false || disq.length) {
    next_status = 'REJECTED';
    reason = `not_recommended:${disq.join(',') || q.fit_tier}`;
  } else if (q.fit_tier === 'WEAK') {
    next_status = 'READY_FOR_REVIEW';
    reason = `weak_fit:${q.reasoning || ''}`.slice(0, 200);
  }
}

return [{ json: {
  lead_id: research.lead_id,
  qualification: q,
  fit_tier: q.fit_tier,
  next_status,
  reason,
}}];
""".strip())

    qual_write = pg(b, "Apply Qualification Signals", """
-- Overlays the qualification pass's signals onto the cached research, using the
-- same keys acq.compute_score() already reads. The full verdict is kept under
-- raw.qualification so a score can be explained months later. The `? 'signals'`
-- guard makes this a no-op when the qualification call failed.
UPDATE acq.lead_research
   SET raw = raw || jsonb_build_object(
         'advertises_appointments', ($2::jsonb -> 'signals' ->> 'appointment_driven')::boolean,
         'high_value_services',     ($2::jsonb -> 'signals' ->> 'high_value_services')::boolean,
         'active_social_presence',  ($2::jsonb -> 'signals' ->> 'active_online_presence')::boolean,
         'qualification',           $2::jsonb),
       has_whatsapp = COALESCE(($2::jsonb -> 'signals' ->> 'whatsapp_is_a_contact_channel')::boolean,
                               has_whatsapp),
       has_online_booking = COALESCE(($2::jsonb -> 'signals' ->> 'has_online_booking')::boolean,
                                     has_online_booking)
 WHERE lead_id = $1::uuid
   AND is_current
   AND $2::jsonb ? 'signals'
""".strip(),
        replacement="={{ [ $json.lead_id, JSON.stringify($json.qualification) ] }}",
        on_error="continueRegularOutput")

    rescore = pg(b, "Score (Blended)",
                 "SELECT acq.compute_score($1::uuid, 'BLENDED') AS score",
                 replacement="={{ [ $('Merge Qualification').first().json.lead_id ] }}")

    apply = pg(b, "Apply Status", """
SELECT acq.transition_lead($1::uuid, $2::acq.lead_status, $3, 'AI', $4) AS result
""".strip(),
        replacement="={{ [ $('Merge Qualification').first().json.lead_id, "
                    "$('Merge Qualification').first().json.next_status, "
                    "$('Merge Qualification').first().json.reason, $execution.id ] }}")

    pause = wait_node(b, "Pace Requests", 3)

    b.chain(t, crawl_settings, claim, loop)
    b.connect(loop, plan, src_out=1)
    b.chain(plan, robots, check_robots, any_pages)
    b.connect(any_pages, expand, src_out=0)
    b.chain(expand, fetch_page, extract)
    b.connect(any_pages, no_fetch, src_out=1)
    b.connect(no_fetch, extract)
    b.chain(extract, ai_in, ai, handle, save_email, save,
            qual_in, qual_ai, qual_merge, qual_write, rescore, apply, pause)
    b.connect(pause, loop)
    b.connect(loop, b.node("Research Sweep Complete", "n8n-nodes-base.noOp", {}, tv=1), src_out=0)
    return b.build()


# ==========================================================================
# 40 — Personalization
#
# Turns a researched lead into a drafted email. Two things stand between the
# model and a real clinic's inbox: a free MX check (a domain with no mail
# exchanger will hard-bounce, and bounces are what destroy a young sending
# domain), and a deterministic guardrail pass over the generated text.
# ==========================================================================
def wf_personalization():
    b = Builder("ACQ 40 — Personalization", "wf40")

    t = cron(b, "Every 20 Minutes", "*/20 * * * *")

    settings = pg(b, "Load Settings", """
SELECT
  (SELECT (value)::boolean            FROM acq.settings WHERE key = 'outreach.auto_send_enabled')       AS auto_send,
  (SELECT (value #>> '{}')::numeric   FROM acq.settings WHERE key = 'ai.min_email_confidence')          AS min_conf,
  (SELECT  value                      FROM acq.settings WHERE key = 'guardrails.banned_phrases')        AS banned,
  (SELECT (value #>> '{}')::int       FROM acq.settings WHERE key = 'guardrails.max_body_chars')        AS max_chars,
  (SELECT (value #>> '{}')::int       FROM acq.settings WHERE key = 'guardrails.min_body_chars')        AS min_chars,
  (SELECT  value                      FROM acq.settings WHERE key = 'guardrails.required_tokens')       AS required_tokens,
  (SELECT  value                      FROM acq.settings WHERE key = 'product.capabilities')             AS capabilities,
  (SELECT (value #>> '{}')            FROM acq.settings WHERE key = 'company.postal_address')           AS postal_address,
  c.id AS campaign_id, c.mailbox_id, c.min_score_to_send
FROM acq.campaigns c
WHERE c.key = 'pk-karachi-tier1'
""".strip(), execute_once=True,
        notes="Campaign key is the one thing to change when you add a second market.")

    claim = pg(b, "Claim Researched Leads", """
-- Every condition — has an email, has research, is not suppressed, has no
-- step-0 email already — is applied inside the claim, so this workflow never
-- locks a lead it cannot use. The join is guaranteed to match.
SELECT l.id, l.clinic_name, l.website, l.city, l.area, l.category, l.phone,
       l.whatsapp, l.public_email, l.domain, l.lead_score, l.doctor_count,
       to_jsonb(r) - 'raw' AS research, r.confidence AS research_confidence
FROM acq.claim_leads_for_personalization(10, $1, $2::int) l
JOIN acq.lead_research r ON r.lead_id = l.id AND r.is_current
""".strip(),
        replacement="={{ [ 'wf40:' + $execution.id, $json.min_score_to_send ] }}",
        always_output=True,
        notes="Leads with no public email are never reached here — nothing invents one.")

    loop = loop_node(b, "Per Lead", 1)

    # Free deliverability pre-check over DNS-over-HTTPS. No account, no key.
    mx = http(b, "Check MX Records", "GET",
              "=https://cloudflare-dns.com/dns-query?name={{ $json.public_email.split('@')[1] }}&type=MX",
              headers={"Accept": "application/dns-json"},
              timeout=8000, retries=2, on_error="continueRegularOutput",
              notes="Free MX lookup. A domain with no mail exchanger will hard-bounce, "
                    "and hard bounces are the fastest way to wreck a new sending domain.")

    mx_check = code(b, "Evaluate MX", r"""
const lead = $('Per Lead').first().json;
const r = $input.first().json;
const body = r.body ?? r;

// DNS status 0 = NOERROR. Answer records of type 15 are MX records.
const answers = body?.Answer || [];
const hasMx = body?.Status === 0 && answers.some(a => a.type === 15);

// A lookup that itself failed is not evidence of a bad domain, so it is treated
// as inconclusive and allowed through rather than silently dropping the lead.
const inconclusive = r.statusCode && (r.statusCode < 200 || r.statusCode >= 300);

return [{ json: {
  ...lead,
  mx_ok: hasMx || inconclusive,
  mx_checked: !inconclusive,
  mx_records: answers.filter(a => a.type === 15).map(a => a.data),
}}];
""".strip())

    mx_gate = if_bool(b, "Deliverable Domain?", "={{ $json.mx_ok }}")

    no_mx = pg(b, "Suppress Undeliverable Domain", """
SELECT acq.apply_opt_out('DOMAIN', $1, 'NO_MX', 'MANUAL', $2::uuid, $3::jsonb) AS suppressed,
       acq.transition_lead($2::uuid, 'INVALID', 'no_mx_records', 'SYSTEM') AS moved
""".strip(),
        replacement="={{ [ $json.public_email.split('@')[1], $json.id, "
                    "JSON.stringify({ checked_at: $now.toISO() }) ] }}")

    ai_in = code(b, "Build AI Input", r"""
const j = $input.first().json;
return [{ json: {
  prompt_key: 'email_initial',
  purpose: 'PERSONALIZE',
  lead_id: j.id,
  variables: {
    lead_json: {
      clinic_name: j.clinic_name, city: j.city, area: j.area,
      category: j.category, website: j.website,
      doctor_count: j.doctor_count, lead_score: j.lead_score,
    },
    research_json: j.research,
  },
}}];
""".strip())

    ai = call_workflow(b, "AI: Write Email", "ACQ 01 — AI Call")

    guard = code(b, "Guardrails", r"""
// The second of two defences. The prompt asks for restraint; this enforces it.
// Anything failing here is never queued — it goes to a human instead.
const lead = $('Evaluate MX').first().json;
const cfg = $('Load Settings').first().json;
const res = $input.first().json;

function reject(reasons, extra = {}) {
  return [{ json: { lead_id: lead.id, clinic_name: lead.clinic_name,
                    passed: false, reasons, ...extra } }];
}

if (!res.ok) return reject([`ai_failed:${res.error}`]);

const d = res.data;
const subject = String(d.subject || '').trim();
const body = String(d.body_text || '').trim();
const reasons = [];

const banned = Array.isArray(cfg.banned) ? cfg.banned : [];
const hay = `${subject}\n${body}`.toLowerCase();
for (const phrase of banned) {
  if (hay.includes(String(phrase).toLowerCase().trim())) reasons.push(`banned_phrase:${phrase}`);
}

const required = Array.isArray(cfg.required_tokens) ? cfg.required_tokens : [];
for (const tok of required) {
  if (!body.includes(tok)) reasons.push(`missing_token:${tok}`);
}

if (body.length > (cfg.max_chars || 1400)) reasons.push(`too_long:${body.length}`);
if (body.length < (cfg.min_chars || 350))  reasons.push(`too_short:${body.length}`);
if (!subject) reasons.push('empty_subject');
if (subject.length > 78) reasons.push(`subject_too_long:${subject.length}`);
if (/^re:|^fwd:/i.test(subject)) reasons.push('fake_reply_subject');

// Claims the product cannot back, and claims nobody should make in a cold email.
if (/\b(?:PKR|Rs\.?|USD|\$|€|£)\s?\d/i.test(body)) reasons.push('contains_price');
if (/\b(cure|treat|diagnos|patient outcome|clinically proven|medically)\b/i.test(body))
  reasons.push('medical_claim');
if (/\b(\d+%|\d+x)\s*(more|increase|growth|revenue|bookings)\b/i.test(body))
  reasons.push('unsupported_statistic');
if (/\b(I called|I visited|I spoke|we spoke|as discussed|per our conversation)\b/i.test(body))
  reasons.push('fabricated_prior_contact');

// More than one link reads as bulk mail and hurts deliverability.
const links = body.match(/https?:\/\/\S+/g) || [];
if (links.length > 1) reasons.push(`too_many_links:${links.length}`);

// Every email must carry a real postal address, so refuse to build one until
// company.postal_address is set.
if (!String(cfg.postal_address || '').trim()) reasons.push('no_postal_address_configured');

const conf = Number(d.confidence ?? 0);
const minConf = Number(cfg.min_conf ?? 0.7);

if (reasons.length) return reject(reasons, { subject, body_text: body, confidence: conf });

// Passed the hard checks. Low confidence is not a rejection, it is a review.
const needsReview = !cfg.auto_send || conf < minConf;

return [{ json: {
  lead_id: lead.id,
  clinic_name: lead.clinic_name,
  to_email: lead.public_email,
  campaign_id: cfg.campaign_id,
  mailbox_id: cfg.mailbox_id,
  passed: true,
  subject,
  body_text: body,
  personalization_reason: d.personalization_reason || '',
  suggested_feature: d.suggested_feature || '',
  confidence: conf,
  model: res.model,
  prompt_version: res.prompt_version,
  status: needsReview ? 'PENDING_APPROVAL' : 'READY_TO_SEND',
  review_reason: !cfg.auto_send ? 'auto_send_disabled'
                : (conf < minConf ? `low_confidence:${conf}` : null),
  guardrail_report: { checks_passed: true, links: links.length, body_chars: body.length },
}}];
""".strip())

    passed = if_bool(b, "Guardrails Passed?", "={{ $json.passed }}")

    insert = pg(b, "Queue Email", """
INSERT INTO acq.emails (
  lead_id, campaign_id, mailbox_id, step_no, to_email, subject, body_text,
  personalization_reason, suggested_feature, ai_confidence, model,
  prompt_version, status, guardrail_report)
VALUES ($1::uuid, $2::uuid, $3::uuid, 0, $4::citext, $5, $6,
        $7, $8, $9::numeric, $10, $11, $12::acq.email_status, $13::jsonb)
ON CONFLICT (lead_id, campaign_id, step_no) DO NOTHING
RETURNING id, status, unsubscribe_token
""".strip(),
        replacement="={{ [ $json.lead_id, $json.campaign_id, $json.mailbox_id, $json.to_email, "
                    "$json.subject, $json.body_text, $json.personalization_reason, "
                    "$json.suggested_feature, $json.confidence, $json.model, "
                    "$json.prompt_version, $json.status, JSON.stringify($json.guardrail_report) ] }}",
        always_output=True,
        notes="ON CONFLICT DO NOTHING makes a re-run harmless: one email per lead per step.")

    move_ready = pg(b, "Mark Lead Approved", """
SELECT acq.transition_lead($1::uuid,
         CASE WHEN $2 = 'PENDING_APPROVAL' THEN 'READY_FOR_REVIEW'::acq.lead_status
              ELSE 'APPROVED'::acq.lead_status END,
         $3, 'AI', $4) AS result
""".strip(),
        replacement="={{ [ $('Guardrails').first().json.lead_id, "
                    "$('Guardrails').first().json.status, "
                    "('draft_ready:' + ($('Guardrails').first().json.review_reason || 'auto')), "
                    "$execution.id ] }}")

    needs_review = if_bool(b, "Needs Human Approval?",
                           "={{ $('Guardrails').first().json.status === 'PENDING_APPROVAL' }}")

    approval = pg(b, "Create Approval Request", """
INSERT INTO acq.approvals (kind, lead_id, email_id, title, payload, ai_confidence)
VALUES ('EMAIL_DRAFT', $1::uuid, NULLIF($2,'')::uuid, $3, $4::jsonb, $5::numeric)
RETURNING id
""".strip(),
        replacement="={{ [ $('Guardrails').first().json.lead_id, "
                    "($('Queue Email').first().json.id || ''), "
                    "('Approve outreach to ' + $('Guardrails').first().json.clinic_name), "
                    "JSON.stringify({ subject: $('Guardrails').first().json.subject, "
                    "body_text: $('Guardrails').first().json.body_text, "
                    "to_email: $('Guardrails').first().json.to_email, "
                    "reason: $('Guardrails').first().json.review_reason }), "
                    "$('Guardrails').first().json.confidence ] }}")

    rejected = pg(b, "Record Guardrail Failure", """
WITH a AS (
  INSERT INTO acq.approvals (kind, lead_id, title, payload, ai_confidence)
  VALUES ('GUARDRAIL_FAILURE', $1::uuid, $2, $3::jsonb, $4::numeric)
  RETURNING id
)
INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, lead_id, error, payload)
SELECT '40_personalization', $5, 'Guardrails', $1::uuid, $6, $3::jsonb FROM a
""".strip(),
        replacement="={{ [ $json.lead_id, ('Draft rejected for ' + $json.clinic_name), "
                    "JSON.stringify({ reasons: $json.reasons, subject: $json.subject, "
                    "body_text: $json.body_text }), ($json.confidence || 0), "
                    "$execution.id, ('guardrails: ' + ($json.reasons || []).join(', ')) ] }}",
        notes="A rejected draft is never silently discarded — it becomes a review item.")

    hold = pg(b, "Return Lead to Review", """
SELECT acq.transition_lead($1::uuid, 'READY_FOR_REVIEW', $2, 'SYSTEM', $3) AS result
""".strip(),
        replacement="={{ [ $json.lead_id, ('guardrail_failed:' + ($json.reasons || []).join(',')), "
                    "$execution.id ] }}")

    done_review = b.node("Awaiting Approval", "n8n-nodes-base.noOp", {}, tv=1)
    done_auto = b.node("Queued For Sending", "n8n-nodes-base.noOp", {}, tv=1)
    done = b.node("Batch Complete", "n8n-nodes-base.noOp", {}, tv=1)

    b.chain(t, settings, claim, loop)
    b.connect(loop, mx, src_out=1)
    b.chain(mx, mx_check, mx_gate)
    b.connect(mx_gate, ai_in, src_out=0)
    b.connect(mx_gate, no_mx, src_out=1)
    b.connect(no_mx, loop)
    b.chain(ai_in, ai, guard, passed)
    b.connect(passed, insert, src_out=0)
    b.chain(insert, move_ready, needs_review)
    b.connect(needs_review, approval, src_out=0)
    b.chain(approval, done_review)
    b.connect(done_review, loop)
    b.connect(needs_review, done_auto, src_out=1)
    b.connect(done_auto, loop)
    b.connect(passed, rejected, src_out=1)
    b.chain(rejected, hold)
    b.connect(hold, loop)
    b.connect(loop, done, src_out=0)
    return b.build()


# ==========================================================================
# 50 — Outreach Send
#
# The only workflow permitted to talk to SMTP. Initial emails and follow-ups
# both arrive here as rows in acq.emails, so every limit is enforced in one
# place and there is no second path that could bypass them.
# ==========================================================================
def wf_send():
    b = Builder("ACQ 50 — Outreach Send", "wf50")

    t = cron(b, "Every 15 Minutes", "*/15 * * * *")

    camps = pg(b, "Active Campaigns", """
SELECT c.id AS campaign_id, c.key, c.timezone,
       m.from_email, m.from_name, m.reply_to,
       (SELECT (value)::boolean FROM acq.settings WHERE key = 'outreach.dry_run')      AS dry_run,
       (SELECT  value #>> '{}'  FROM acq.settings WHERE key = 'unsubscribe.base_url')  AS unsub_base,
       (SELECT  value #>> '{}'  FROM acq.settings WHERE key = 'company.brand')         AS brand,
       (SELECT  value #>> '{}'  FROM acq.settings WHERE key = 'company.website')       AS company_url,
       (SELECT  value #>> '{}'  FROM acq.settings WHERE key = 'company.postal_address') AS postal_address
FROM acq.campaigns c
JOIN acq.mailboxes m ON m.id = c.mailbox_id
WHERE c.status = 'ACTIVE' AND m.active
""".strip(), always_output=True)

    claim = pg(b, "Claim Send Slots", """
SELECT e.id AS email_id, e.lead_id, e.to_email, e.subject, e.body_text,
       e.step_no, e.unsubscribe_token,
       (SELECT clinic_name FROM acq.leads WHERE id = e.lead_id) AS clinic_name
FROM acq.claim_send_slots($1::uuid, 5) e
""".strip(),
        replacement="={{ [ $json.campaign_id ] }}",
        always_output=True,
        notes="Daily and hourly caps, the sending window, per-domain limits, the "
              "warm-up ramp and suppression are all applied inside this one "
              "transaction. Two overlapping runs cannot both think they have budget.")

    loop = loop_node(b, "Per Email", 1)

    recheck = pg(b, "Final Pre-Send Check",
                 "SELECT acq.is_sendable($1::uuid) AS check",
                 replacement="={{ [ $json.email_id ] }}",
                 notes="Catches a reply or opt-out that landed in the seconds between "
                       "claiming the slot and reaching the SMTP call.")

    sendable = if_bool(b, "Still Sendable?", "={{ $json.check.sendable }}")

    render = code(b, "Render Final Email", r"""
const e = $('Per Email').first().json;
const c = $('Active Campaigns').first().json;

if (!String(c.postal_address || '').trim()) {
  throw new Error('company.postal_address is empty. A real postal address is ' +
                  'required in the footer before any outreach can be sent.');
}
if (!String(c.unsub_base || '').trim()) {
  throw new Error('unsubscribe.base_url is empty. Deploy workflow 110 and set it ' +
                  'before sending — an opt-out link that does not work is worse ' +
                  'than none at all.');
}

const unsubUrl = `${c.unsub_base}?t=${e.unsubscribe_token}`;

// The token is a placeholder the model was told to leave in place. If it is
// missing the guardrails already rejected the draft, so this is belt and braces.
let body = String(e.body_text);
const line = `If you'd rather not hear from me again, unsubscribe here: ${unsubUrl}`;
body = body.includes('{{UNSUBSCRIBE}}')
  ? body.replace('{{UNSUBSCRIBE}}', line)
  : `${body}\n\n${line}`;

const footer = [
  '',
  '--',
  `${c.brand} · ${c.company_url}`,
  c.postal_address,
].join('\n');

return [{ json: {
  ...e,
  from_email: c.from_email,
  from_name: c.from_name,
  reply_to: c.reply_to || c.from_email,
  dry_run: !!c.dry_run,
  final_body: body + footer,
  // Our own correlation id. Note this is NOT the RFC 5322 Message-ID the MTA
  // will assign — n8n's SMTP node cannot set custom headers. Inbound matching
  // is by sender address first; see workflow 60.
  correlation_id: `<acq-${e.email_id}@zenvexa.tech>`,
}}];
""".strip())

    dry = if_bool(b, "Dry Run?", "={{ $json.dry_run }}")

    send = b.node("Send Email (SMTP)", "n8n-nodes-base.emailSend", {
        "fromEmail": "={{ $json.from_name + ' <' + $json.from_email + '>' }}",
        "toEmail": "={{ $json.to_email }}",
        "subject": "={{ $json.subject }}",
        "emailFormat": "text",
        "text": "={{ $json.final_body }}",
        "options": {"replyTo": "={{ $json.reply_to }}", "appendAttribution": False},
    }, tv=2.1, creds="smtp", retries=2, on_error="continueErrorOutput",
        notes="appendAttribution is off: n8n's default footer would misrepresent "
              "who sent the message.")

    dry_note = code(b, "Dry Run — Not Sent", r"""
const j = $input.first().json;
return [{ json: { ...j, dry_run_preview: j.final_body.slice(0, 400) } }];
""".strip())

    recorded = pg(b, "Record Sent", """
SELECT acq.record_email_sent($1::uuid, $2, $3) AS result
""".strip(),
        replacement="={{ [ $('Render Final Email').first().json.email_id, "
                    "$('Render Final Email').first().json.correlation_id, $execution.id ] }}",
        notes="Also schedules the next follow-up and advances the lead's status.")

    failed = pg(b, "Record Failure", """
SELECT acq.record_email_failed($1::uuid, $2, $3) AS result
""".strip(),
        replacement="={{ [ $('Render Final Email').first().json.email_id, "
                    "('smtp: ' + ($json.error?.message || $json.message || 'send failed')), "
                    "$execution.id ] }}",
        notes="Returns the email to READY_TO_SEND for two more attempts, then "
              "marks it FAILED and writes a dead letter.")

    cancel = pg(b, "Cancel Unsendable", """
UPDATE acq.emails SET status = 'CANCELLED', error = $2
 WHERE id = $1::uuid AND status = 'QUEUED'
""".strip(),
        replacement="={{ [ $('Per Email').first().json.email_id, "
                    "('pre_send_check: ' + $json.check.reason) ] }}")

    jitter = code(b, "Human Pacing Delay", r"""
// Emails leaving on an exact cadence look like what they are. A random gap of
// 40-160 seconds between sends is both more natural and gentler on the mailbox.
return [{ json: { wait_seconds: 40 + Math.floor(Math.random() * 120) } }];
""".strip())

    wait = b.node("Wait (Jittered)", "n8n-nodes-base.wait",
                  {"resume": "timeInterval", "amount": "={{ $json.wait_seconds }}",
                   "unit": "seconds"}, tv=1.1)

    done = b.node("Send Batch Complete", "n8n-nodes-base.noOp", {}, tv=1)

    b.chain(t, camps, claim, loop)
    b.connect(loop, recheck, src_out=1)
    b.chain(recheck, sendable)
    b.connect(sendable, render, src_out=0)
    b.connect(sendable, cancel, src_out=1)
    b.connect(cancel, loop)
    b.chain(render, dry)
    b.connect(dry, dry_note, src_out=0)
    b.connect(dry_note, jitter)
    b.connect(dry, send, src_out=1)
    b.connect(send, recorded, src_out=0)
    b.connect(send, failed, src_out=1)          # error output
    b.connect(recorded, jitter)
    b.connect(failed, jitter)
    b.chain(jitter, wait)
    b.connect(wait, loop)
    b.connect(loop, done, src_out=0)
    return b.build()


# ==========================================================================
# 60 — Inbox Monitoring
#
# Watches the outreach mailbox over IMAP. Its most important property: a human
# reply stops all follow-ups BEFORE classification is attempted, so an AI
# outage can never cause someone who replied to keep receiving mail.
# ==========================================================================
def wf_inbox():
    b = Builder("ACQ 60 — Inbox Monitor", "wf60")

    t = b.node("New Mail (IMAP)", "n8n-nodes-base.emailReadImap", {
        "format": "resolved",
        "options": {"customEmailConfig": '["UNSEEN"]', "forceReconnect": 60},
    }, tv=2, creds="imap",
        notes="IMAP idle on the outreach mailbox. Cheaper and more reliable at this "
              "volume than provider webhooks, and it sees replies AND bounces.")

    triage = code(b, "Triage Message", r"""
const m = $input.first().json;

// n8n's resolved IMAP format varies a little by server, so read defensively.
const headers = m.headers || m.headerLines || {};
const hdr = (name) => {
  const k = Object.keys(headers).find(x => x.toLowerCase() === name.toLowerCase());
  const v = k ? headers[k] : undefined;
  return Array.isArray(v) ? v.join(' ') : String(v ?? '');
};

const fromRaw = m.from?.value?.[0]?.address || m.from?.text || m.from || '';
const fromEmail = String(fromRaw).match(/[^<\s]+@[^>\s]+/)?.[0]?.toLowerCase() || '';
const fromName = m.from?.value?.[0]?.name || '';
const subject = String(m.subject || '');
const text = String(m.textPlain || m.text || '');
const html = String(m.textHtml || '');

const isBounce =
  /(mailer-daemon|postmaster|no-?reply@.*(mail|smtp))/i.test(fromEmail) ||
  /^(undelivered|undeliverable|delivery status|returned mail|failure notice|mail delivery)/i.test(subject) ||
  /multipart\/report/i.test(hdr('content-type')) ||
  /delivery-status-notification/i.test(hdr('content-type'));

const isAuto =
  (hdr('auto-submitted') && !/^no$/i.test(hdr('auto-submitted'))) ||
  !!hdr('x-autoreply') || !!hdr('x-autorespond') ||
  /(bulk|auto_reply|auto-reply|list)/i.test(hdr('precedence')) ||
  /^(out of office|automatic reply|auto:|autoreply)/i.test(subject);

// For a bounce, the address that failed is inside the report body, not in From.
let bouncedAddress = null;
if (isBounce) {
  const body = `${text}\n${html}`;
  const candidates = body.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g) || [];
  bouncedAddress = candidates.find(a =>
    !/(mailer-daemon|postmaster|zenvexa\.tech)/i.test(a))?.toLowerCase() || null;
}

// 5.x.x is permanent; 4.x.x is temporary and must not suppress an address.
const hardBounce = isBounce && /\b5\.\d\.\d\b/.test(`${text} ${subject}`);

let kind = 'HUMAN_REPLY';
if (isBounce) kind = 'BOUNCE';
else if (isAuto) kind = 'AUTO_REPLY';

return [{ json: {
  kind,
  hard_bounce: hardBounce,
  message_id: m.messageId || hdr('message-id') || `imap-${Date.now()}-${Math.random()}`,
  in_reply_to: hdr('in-reply-to') || null,
  references: hdr('references') || null,
  from_email: fromEmail,
  from_name: fromName,
  subject,
  body_text: text.slice(0, 20000),
  body_html: html.slice(0, 20000),
  lookup_email: isBounce ? (bouncedAddress || fromEmail) : fromEmail,
  received_at: m.date || new Date().toISOString(),
}}];
""".strip())

    match = pg(b, "Match To Lead", """
-- Matching is by recipient address first: at this volume every prospect has a
-- unique address, and it survives clients that rewrite In-Reply-To. The
-- correlation id is a secondary path.
SELECT e.id AS email_id, e.lead_id, e.subject AS sent_subject,
       e.body_text AS sent_body, e.step_no,
       l.clinic_name, l.city, l.area, l.lead_score, l.category,
       CASE WHEN e.message_id = $2 THEN 'CORRELATION_ID' ELSE 'FROM_EMAIL' END AS matched_by
FROM acq.emails e
JOIN acq.leads l ON l.id = e.lead_id
WHERE (e.to_email = $1::citext OR ($2 <> '' AND e.message_id = $2))
  AND e.status IN ('SENT','BOUNCED')
ORDER BY e.sent_at DESC NULLS LAST
LIMIT 1
""".strip(),
        replacement="={{ [ $json.lookup_email, ($json.in_reply_to || '') ] }}",
        always_output=True)

    merge = code(b, "Merge Match", r"""
const msg = $('Triage Message').first().json;
const row = $input.first().json;
const matched = !!row?.lead_id;
return [{ json: {
  ...msg,
  ...(matched ? row : {}),
  matched,
  route: matched ? msg.kind : 'UNMATCHED',
}}];
""".strip())

    route = switch(b, "Route Message", "={{ $json.route }}",
                   ["HUMAN_REPLY", "BOUNCE", "AUTO_REPLY"])

    store_reply = pg(b, "Store Reply", """
INSERT INTO acq.replies (lead_id, email_id, message_id, in_reply_to, references_hdr,
                         from_email, from_name, subject, body_text, body_html,
                         is_auto_reply, is_bounce, matched_by, received_at)
VALUES ($1::uuid, NULLIF($2,'')::uuid, $3, NULLIF($4,''), NULLIF($5,''),
        $6::citext, $7, $8, $9, $10, false, false, $11, $12::timestamptz)
ON CONFLICT (message_id) DO NOTHING
RETURNING id
""".strip(),
        replacement="={{ [ $json.lead_id, ($json.email_id || ''), $json.message_id, "
                    "($json.in_reply_to || ''), ($json.references || ''), $json.from_email, "
                    "($json.from_name || ''), $json.subject, $json.body_text, "
                    "($json.body_html || ''), $json.matched_by, $json.received_at ] }}",
        always_output=True,
        notes="ON CONFLICT on message_id makes redelivery from IMAP harmless.")

    stop = pg(b, "Stop Follow-Ups Immediately",
              "SELECT acq.record_reply($1::uuid) AS result",
              replacement="={{ [ $json.id ] }}",
              notes="Runs BEFORE classification on purpose. Whatever the reply says, "
                    "and whether or not the AI is reachable, the sequence stops here.")

    classify = call_workflow(b, "Classify Reply", "ACQ 70 — Reply Classification")

    prep_classify = code(b, "Prepare Classification Input", r"""
const reply = $('Store Reply').first().json;
const ctx = $('Merge Match').first().json;
return [{ json: { reply_id: reply.id, lead_id: ctx.lead_id } }];
""".strip())

    bounce = pg(b, "Record Bounce", """
SELECT acq.record_bounce(NULLIF($1,'')::uuid, $2::boolean, $3, $4) AS result
""".strip(),
        replacement="={{ [ ($json.email_id || ''), $json.hard_bounce, "
                    "($json.subject + ' :: ' + $json.body_text.slice(0, 400)), "
                    "$json.lookup_email ] }}",
        notes="Only 5.x.x permanent failures suppress the address. A 4.x.x temporary "
              "failure is recorded and retried.")

    auto = pg(b, "Log Auto-Reply", """
INSERT INTO acq.replies (lead_id, email_id, message_id, from_email, from_name,
                         subject, body_text, is_auto_reply, matched_by, received_at)
VALUES ($1::uuid, NULLIF($2,'')::uuid, $3, $4::citext, $5, $6, $7, true, $8, $9::timestamptz)
ON CONFLICT (message_id) DO NOTHING
""".strip(),
        replacement="={{ [ $json.lead_id, ($json.email_id || ''), $json.message_id, "
                    "$json.from_email, ($json.from_name || ''), $json.subject, "
                    "$json.body_text.slice(0, 2000), $json.matched_by, $json.received_at ] }}",
        notes="An out-of-office is not a reply: it is logged, and the sequence continues.")

    unmatched = pg(b, "Record Unmatched Mail", """
INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, error, payload)
VALUES ('60_inbox_monitor', $1, 'Match To Lead',
        'inbound message could not be matched to any lead', $2::jsonb)
""".strip(),
        replacement="={{ [ $execution.id, JSON.stringify({ from: $json.from_email, "
                    "subject: $json.subject, kind: $json.kind, "
                    "excerpt: $json.body_text.slice(0, 500) }) ] }}",
        notes="Mail from a stranger still gets a durable record — never dropped.")

    b.chain(t, triage, match, merge, route)
    b.connect(route, store_reply, src_out=0)
    b.chain(store_reply, stop, prep_classify, classify)
    b.connect(route, bounce, src_out=1)
    b.connect(route, auto, src_out=2)
    b.connect(route, unmatched, src_out=3)   # switch fallback output
    return b.build()


# ==========================================================================
# 70 — Reply Classification
# ==========================================================================
def wf_classification():
    b = Builder("ACQ 70 — Reply Classification", "wf70")

    t = b.node("When Called", "n8n-nodes-base.executeWorkflowTrigger",
               {"inputSource": "passthrough"}, tv=1.1)

    load = pg(b, "Load Reply Context", """
SELECT r.id AS reply_id, r.body_text, r.subject AS reply_subject, r.from_email,
       r.lead_id,
       e.subject AS sent_subject, e.body_text AS sent_body,
       acq.lead_profile(r.lead_id) AS lead_profile,
       (SELECT (value #>> '{}')::numeric FROM acq.settings WHERE key = 'ai.min_classification_confidence') AS min_conf
FROM acq.replies r
LEFT JOIN acq.emails e ON e.id = r.email_id
WHERE r.id = $1::uuid
""".strip(), replacement="={{ [ $json.reply_id ] }}")

    ai_in = code(b, "Build AI Input", r"""
const j = $input.first().json;
return [{ json: {
  prompt_key: 'classify_reply',
  purpose: 'CLASSIFY',
  lead_id: j.lead_id,
  variables: {
    sent_subject: j.sent_subject || '(unknown)',
    sent_body: (j.sent_body || '').slice(0, 3000),
    reply_subject: j.reply_subject || '',
    reply_body: (j.body_text || '').slice(0, 6000),
    from_email: j.from_email,
    lead_context: j.lead_profile,
  },
}}];
""".strip())

    ai = call_workflow(b, "AI: Classify", "ACQ 01 — AI Call")

    interpret = code(b, "Interpret Classification", r"""
const ctx = $('Load Reply Context').first().json;
const res = $input.first().json;
const minConf = Number(ctx.min_conf ?? 0.75);

// A failed classification is never treated as "probably fine". It becomes a
// human review item, and follow-ups are already stopped by workflow 60.
if (!res.ok) {
  return [{ json: {
    reply_id: ctx.reply_id, lead_id: ctx.lead_id, route: 'HUMAN',
    class: 'UNCLEAR', confidence: 0, requires_human: true,
    escalation_reason: `classification_failed:${res.error}`,
    reasoning: 'AI classification failed', extracted_questions: [],
    suggested_reply: '', model: null, prompt_version: null,
  }}];
}

const d = res.data;
let cls = d.class;

// Belt and braces over the prompt's own instruction: if the model spotted any
// removal request at all, the class is OPT_OUT regardless of what it chose.
if (d.opt_out_signal_detected === true) cls = 'OPT_OUT';

const lowConf = Number(d.confidence ?? 0) < minConf;
const requiresHuman = !!d.requires_human || lowConf;

let route;
switch (cls) {
  case 'OPT_OUT':          route = 'OPT_OUT'; break;
  case 'NOT_INTERESTED':   route = 'NEGATIVE'; break;
  case 'LATER':            route = 'LATER'; break;
  case 'AUTOMATIC_REPLY':  route = 'AUTO'; break;
  case 'VERY_INTERESTED':
  case 'INTERESTED':
  case 'ASKING_DEMO':
  case 'ASKING_PRICE':     route = 'HOT'; break;
  default:                 route = 'HUMAN';
}
// An interested prospect asking something a human must answer still counts as
// hot — the notification carries the open question rather than burying it.
if (requiresHuman && route !== 'HOT' && route !== 'OPT_OUT') route = 'HUMAN';

const nextStatus = {
  OPT_OUT: 'OPTED_OUT', NEGATIVE: 'NOT_INTERESTED', LATER: 'LATER',
  HOT: (cls === 'ASKING_DEMO' ? 'DEMO_REQUESTED' : 'INTERESTED'),
  HUMAN: 'REPLIED', AUTO: 'REPLIED',
}[route];

return [{ json: {
  reply_id: ctx.reply_id, lead_id: ctx.lead_id,
  route, next_status: nextStatus,
  class: cls, confidence: d.confidence ?? 0,
  reasoning: d.reasoning || '', extracted_questions: d.extracted_questions || [],
  suggested_reply: d.suggested_reply || '',
  requires_human: requiresHuman,
  escalation_reason: d.escalation_reason || (lowConf ? `low_confidence:${d.confidence}` : null),
  opt_out_quote: d.opt_out_quote || '',
  sentiment: d.sentiment || 'NEUTRAL',
  revisit_after_days: d.revisit_after_days || 0,
  model: res.model, prompt_version: res.prompt_version,
}}];
""".strip())

    save = pg(b, "Save Classification", """
INSERT INTO acq.reply_classifications (
  reply_id, class, confidence, reasoning, extracted_questions, suggested_reply,
  requires_human, escalation_reason, model, prompt_version)
VALUES ($1::uuid, $2::acq.reply_class, $3::numeric, $4, $5::jsonb, $6,
        $7::boolean, $8, $9, $10)
ON CONFLICT (reply_id) DO UPDATE
  SET class = EXCLUDED.class, confidence = EXCLUDED.confidence,
      reasoning = EXCLUDED.reasoning, requires_human = EXCLUDED.requires_human
RETURNING id
""".strip(),
        replacement="={{ [ $json.reply_id, $json.class, $json.confidence, $json.reasoning, "
                    "JSON.stringify($json.extracted_questions), $json.suggested_reply, "
                    "$json.requires_human, ($json.escalation_reason || ''), "
                    "$json.model, $json.prompt_version ] }}")

    route = switch(b, "Route Outcome",
                   "={{ $('Interpret Classification').first().json.route }}",
                   ["OPT_OUT", "HOT", "LATER", "NEGATIVE", "HUMAN"])

    opt_out = pg(b, "Apply Opt-Out", """
SELECT acq.apply_opt_out('EMAIL',
         (SELECT from_email::text FROM acq.replies WHERE id = $1::uuid),
         'OPT_OUT_REQUEST', 'REPLY', $2::uuid, $3::jsonb) AS suppressed
""".strip(),
        replacement="={{ [ $json.reply_id, $json.lead_id, "
                    "JSON.stringify({ quote: $json.opt_out_quote, class: $json.class }) ] }}",
        notes="apply_opt_out also moves the lead to OPTED_OUT and cancels everything "
              "queued. There is no path back into the pipeline afterwards.")

    hot = call_workflow(b, "Notify Hot Lead", "ACQ 90 — Hot Lead Notification")

    later = pg(b, "Snooze Lead", """
WITH moved AS (
  SELECT acq.transition_lead($1::uuid, 'LATER', $2, 'AI', $3) AS r
)
UPDATE acq.leads
   SET next_follow_up_at = now() + make_interval(days => GREATEST($4::int, 30))
 WHERE id = $1::uuid
""".strip(),
        replacement="={{ [ $json.lead_id, ('later:' + $json.class), $execution.id, "
                    "($json.revisit_after_days || 90) ] }}",
        notes="One bounded revisit, at least 30 days out. Not a fourth follow-up.")

    negative = pg(b, "Close Lead", """
SELECT acq.transition_lead($1::uuid, 'NOT_INTERESTED', $2, 'AI', $3) AS result
""".strip(),
        replacement="={{ [ $json.lead_id, ('declined:' + $json.class), $execution.id ] }}")

    human = pg(b, "Escalate To Human", """
INSERT INTO acq.approvals (kind, lead_id, reply_id, title, payload, ai_confidence)
VALUES (
  CASE
    WHEN $5 = 'ASKING_PRICE'   THEN 'PRICING_QUESTION'::acq.approval_kind
    WHEN $5 = 'WRONG_PERSON'   THEN 'DATA_CONFLICT'::acq.approval_kind
    WHEN $5 = 'NEEDS_MORE_INFO' THEN 'REPLY_DRAFT'::acq.approval_kind
    ELSE 'LOW_CONFIDENCE_CLASSIFICATION'::acq.approval_kind
  END,
  $1::uuid, $2::uuid, $3, $4::jsonb, $6::numeric)
RETURNING id
""".strip(),
        replacement="={{ [ $json.lead_id, $json.reply_id, "
                    "('Reply needs a human: ' + $json.class), "
                    "JSON.stringify({ class: $json.class, reason: $json.escalation_reason, "
                    "questions: $json.extracted_questions, draft: $json.suggested_reply }), "
                    "$json.class, $json.confidence ] }}")

    notify_human = call_workflow(b, "Notify (Needs Human)", "ACQ 90 — Hot Lead Notification")

    auto_done = b.node("Auto-Reply — No Action", "n8n-nodes-base.noOp", {}, tv=1)

    prep_notify = code(b, "Prepare Notification Input", r"""
const j = $('Interpret Classification').first().json;
return [{ json: { lead_id: j.lead_id, reply_id: j.reply_id, class: j.class,
                  route: j.route, requires_human: j.requires_human } }];
""".strip())

    prep_notify2 = code(b, "Prepare Notification Input (Human)", r"""
const j = $('Interpret Classification').first().json;
return [{ json: { lead_id: j.lead_id, reply_id: j.reply_id, class: j.class,
                  route: 'HUMAN', requires_human: true } }];
""".strip())

    notify_optout = call_workflow(b, "Notify Opt-Out", "ACQ 90 — Hot Lead Notification")
    prep_optout = code(b, "Prepare Opt-Out Notice", r"""
const j = $('Interpret Classification').first().json;
return [{ json: { lead_id: j.lead_id, reply_id: j.reply_id, class: 'OPT_OUT',
                  route: 'OPT_OUT', requires_human: false } }];
""".strip())

    b.chain(t, load, ai_in, ai, interpret, save, route)
    b.connect(route, opt_out, src_out=0)
    b.chain(opt_out, prep_optout, notify_optout)
    b.connect(route, prep_notify, src_out=1)
    b.chain(prep_notify, hot)
    b.connect(route, later, src_out=2)
    b.connect(route, negative, src_out=3)
    b.connect(route, human, src_out=4)
    b.chain(human, prep_notify2, notify_human)
    b.connect(route, auto_done, src_out=5)
    return b.build()


# ==========================================================================
# 80 — Follow-up Engine
#
# Generates follow-ups but never sends them: it writes rows into acq.emails and
# workflow 50 does the sending. Keeping one send path means the daily cap
# applies to the whole operation, not separately to initial mail and follow-ups.
# ==========================================================================
def wf_followups():
    b = Builder("ACQ 80 — Follow-up Engine", "wf80")

    t = cron(b, "Hourly", "5 * * * *")

    due = pg(b, "Due Follow-Ups", """
SELECT f.follow_up_id, f.lead_id, f.campaign_id, f.step_no, f.clinic_name, f.prompt_key,
       l.city, l.area, l.category, l.public_email, l.lead_score, l.doctor_count,
       (to_jsonb(r) - 'raw') AS research,
       (SELECT jsonb_agg(jsonb_build_object('step_no', e.step_no, 'subject', e.subject,
                                            'body_text', e.body_text, 'sent_at', e.sent_at)
                         ORDER BY e.step_no)
          FROM acq.emails e
         WHERE e.lead_id = f.lead_id AND e.status = 'SENT') AS previous_emails,
       EXTRACT(DAY FROM now() - l.last_contacted_at)::int AS days_since_last,
       (SELECT (value)::boolean          FROM acq.settings WHERE key = 'outreach.auto_send_enabled') AS auto_send,
       (SELECT (value #>> '{}')::numeric FROM acq.settings WHERE key = 'ai.min_email_confidence')    AS min_conf,
       (SELECT  value                    FROM acq.settings WHERE key = 'guardrails.banned_phrases')  AS banned,
       c.mailbox_id
FROM acq.due_follow_ups(20) f
JOIN acq.leads l     ON l.id = f.lead_id
JOIN acq.campaigns c ON c.id = f.campaign_id
LEFT JOIN acq.lead_research r ON r.lead_id = f.lead_id AND r.is_current
""".strip(), always_output=True,
        notes="due_follow_ups() already excludes replied, opted-out, bounced and "
              "over-cap leads, so nothing here needs to re-check them.")

    loop = loop_node(b, "Per Follow-Up", 1)

    ai_in = code(b, "Build AI Input", r"""
const j = $input.first().json;
return [{ json: {
  prompt_key: j.prompt_key,          // followup_1_value | _2_different_angle | _3_breakup
  purpose: 'FOLLOWUP',
  lead_id: j.lead_id,
  variables: {
    step_no: String(j.step_no),
    days_since_last: String(j.days_since_last ?? 0),
    lead_json: {
      clinic_name: j.clinic_name, city: j.city, area: j.area,
      category: j.category, doctor_count: j.doctor_count, lead_score: j.lead_score,
    },
    research_json: j.research || {},
    previous_emails: j.previous_emails || [],
  },
}}];
""".strip())

    ai = call_workflow(b, "AI: Write Follow-Up", "ACQ 01 — AI Call")

    guard = code(b, "Guardrails", r"""
const ctx = $('Per Follow-Up').first().json;
const res = $input.first().json;

if (!res.ok) {
  return [{ json: { ok: false, lead_id: ctx.lead_id, follow_up_id: ctx.follow_up_id,
                    reasons: [`ai_failed:${res.error}`] } }];
}

const d = res.data;
const subject = String(d.subject || '').trim();
const body = String(d.body_text || '').trim();
const reasons = [];

const banned = Array.isArray(ctx.banned) ? ctx.banned : [];
const hay = `${subject}\n${body}`.toLowerCase();
for (const p of banned) if (hay.includes(String(p).toLowerCase().trim())) reasons.push(`banned_phrase:${p}`);

// The specific failure modes of follow-up writing.
if (/\b(just following up|bumping this|circling back|in case you missed|did you see my)\b/i.test(body))
  reasons.push('filler_opener');
if (/\b(haven't heard|no response|you didn't reply|I'll assume)\b/i.test(body))
  reasons.push('guilt_trip');
if (/\b(last chance|final notice|expires|act now|limited)\b/i.test(body))
  reasons.push('false_urgency');
if (!body.includes('{{UNSUBSCRIBE}}')) reasons.push('missing_unsubscribe_token');
if (body.length > 900) reasons.push(`too_long_for_followup:${body.length}`);
if (body.length < 120) reasons.push(`too_short:${body.length}`);
if (/\b(?:PKR|Rs\.?|USD|\$)\s?\d/i.test(body)) reasons.push('contains_price');

// A follow-up that repeats the previous email is worse than no follow-up.
const prev = (ctx.previous_emails || []).map(e => String(e.body_text || ''));
const firstSentence = body.split(/[.!?]/)[0].trim().toLowerCase();
if (firstSentence.length > 20 && prev.some(p => p.toLowerCase().includes(firstSentence)))
  reasons.push('repeats_previous_email');

const conf = Number(d.confidence ?? 0);
const needsReview = !ctx.auto_send || conf < Number(ctx.min_conf ?? 0.7);

return [{ json: {
  ok: reasons.length === 0,
  reasons,
  lead_id: ctx.lead_id,
  follow_up_id: ctx.follow_up_id,
  campaign_id: ctx.campaign_id,
  mailbox_id: ctx.mailbox_id,
  step_no: ctx.step_no,
  to_email: ctx.public_email,
  clinic_name: ctx.clinic_name,
  subject, body_text: body,
  suggested_feature: d.suggested_feature || '',
  confidence: conf,
  model: res.model, prompt_version: res.prompt_version,
  status: needsReview ? 'PENDING_APPROVAL' : 'READY_TO_SEND',
}}];
""".strip())

    ok = if_bool(b, "Follow-Up Usable?", "={{ $json.ok }}")

    queue = pg(b, "Queue Follow-Up Email", """
INSERT INTO acq.emails (lead_id, campaign_id, mailbox_id, step_no, to_email,
                        subject, body_text, suggested_feature, ai_confidence,
                        model, prompt_version, status)
VALUES ($1::uuid, $2::uuid, $3::uuid, $4::int, $5::citext, $6, $7, $8,
        $9::numeric, $10, $11, $12::acq.email_status)
ON CONFLICT (lead_id, campaign_id, step_no) DO NOTHING
RETURNING id
""".strip(),
        replacement="={{ [ $json.lead_id, $json.campaign_id, $json.mailbox_id, $json.step_no, "
                    "$json.to_email, $json.subject, $json.body_text, $json.suggested_feature, "
                    "$json.confidence, $json.model, $json.prompt_version, $json.status ] }}",
        always_output=True)

    skip = pg(b, "Skip This Follow-Up", """
WITH s AS (
  UPDATE acq.follow_ups SET status = 'SKIPPED', cancelled_reason = $2
   WHERE id = $1::uuid AND status = 'SCHEDULED'
)
INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, lead_id, error, payload)
VALUES ('80_followup_engine', $3, 'Guardrails', $4::uuid, $2, $5::jsonb)
""".strip(),
        replacement="={{ [ $json.follow_up_id, ('guardrails: ' + ($json.reasons || []).join(', ')), "
                    "$execution.id, $json.lead_id, JSON.stringify({ reasons: $json.reasons, "
                    "subject: $json.subject, body_text: $json.body_text }) ] }}",
        notes="A bad follow-up is skipped, not retried into the prospect's inbox. The "
              "lead keeps its status and the sequence simply ends one step early.")

    done = b.node("Follow-Up Sweep Complete", "n8n-nodes-base.noOp", {}, tv=1)

    b.chain(t, due, loop)
    b.connect(loop, ai_in, src_out=1)
    b.chain(ai_in, ai, guard, ok)
    b.connect(ok, queue, src_out=0)
    b.connect(queue, loop)
    b.connect(ok, skip, src_out=1)
    b.connect(skip, loop)
    b.connect(loop, done, src_out=0)
    return b.build()


# ==========================================================================
# 90 — Hot Lead Notification
# ==========================================================================
def wf_hot_lead():
    b = Builder("ACQ 90 — Hot Lead Notification", "wf90")

    t = b.node("When Called", "n8n-nodes-base.executeWorkflowTrigger",
               {"inputSource": "passthrough"}, tv=1.1)

    load = pg(b, "Load Lead Profile", """
SELECT acq.lead_profile($1::uuid) AS profile,
       (SELECT body_text FROM acq.replies WHERE id = NULLIF($2,'')::uuid) AS reply_body,
       (SELECT to_jsonb(rc) FROM acq.reply_classifications rc
         WHERE rc.reply_id = NULLIF($2,'')::uuid) AS classification,
       (SELECT  value #>> '{}'  FROM acq.settings WHERE key = 'notify.telegram_chat_id') AS chat_id,
       (SELECT  value #>> '{}'  FROM acq.settings WHERE key = 'demo.booking_url')        AS booking_url,
       (SELECT (value)::boolean FROM acq.settings WHERE key = 'outreach.auto_reply_enabled') AS auto_reply,
       (SELECT from_email::text FROM acq.replies WHERE id = NULLIF($2,'')::uuid) AS reply_to_address,
       (SELECT subject FROM acq.replies WHERE id = NULLIF($2,'')::uuid) AS reply_subject,
       m.from_email, m.from_name
FROM acq.mailboxes m WHERE m.key = 'primary'
""".strip(), replacement="={{ [ $json.lead_id, ($json.reply_id || '') ] }}")

    ai_in = code(b, "Build AI Input", r"""
const j = $input.first().json;
return [{ json: {
  prompt_key: 'hot_lead_brief',
  purpose: 'HOT_LEAD',
  lead_id: j.profile?.lead_id,
  variables: {
    lead_profile: j.profile,
    reply_body: (j.reply_body || '').slice(0, 4000),
    classification: j.classification || {},
  },
}}];
""".strip())

    ai = call_workflow(b, "AI: Brief Me", "ACQ 01 — AI Call")

    fmt = code(b, "Format Notification", r"""
const ctx = $('Load Lead Profile').first().json;
const res = $input.first().json;
const p = ctx.profile || {};

// If the briefing model failed, still send a notification. A hot lead going
// unannounced because a summariser timed out is the worst possible failure here.
const d = res.ok ? res.data : {
  priority: 'HIGH',
  headline: `Reply from ${p.clinic_name || 'a prospect'}`,
  key_quote: (ctx.reply_body || '').slice(0, 300),
  why_qualified: [], recommended_action: 'REVIEW_AND_DECIDE',
  action_rationale: 'AI briefing unavailable — read the reply directly.',
  open_questions: [], draft_reply: '', draft_reply_safe_to_send: false,
};

const icon = { URGENT: '🔥', HIGH: '🔥', NORMAL: '📬', LOW: '📮' }[d.priority] || '📬';
const bullets = (d.why_qualified || []).map(x => `• ${x}`).join('\n') || '• (no verified facts recorded)';
const questions = (d.open_questions || []).map(x => `• ${x}`).join('\n');

const text = [
  `${icon} *${d.priority} — ${d.headline}*`,
  '',
  `*Clinic:* ${p.clinic_name || '?'}`,
  `*Location:* ${p.location || '?'}`,
  `*Lead score:* ${p.lead_score ?? '?'}/100`,
  `*Contact:* ${p.public_email || p.whatsapp || p.phone || '?'}`,
  `*Emails sent:* ${p.emails_sent ?? 0}`,
  '',
  '*Why it qualified:*',
  bullets,
  '',
  '*They said:*',
  `_${String(d.key_quote || '').slice(0, 500)}_`,
  '',
  `*Action:* ${d.recommended_action}`,
  d.action_rationale ? `_${d.action_rationale}_` : '',
  questions ? `\n*Needs your answer:*\n${questions}` : '',
  d.draft_reply ? `\n*Draft reply:*\n\`\`\`\n${d.draft_reply}\n\`\`\`` : '',
  ctx.booking_url ? `\n*Booking link:* ${ctx.booking_url}` : '',
].filter(Boolean).join('\n');

// Auto-reply only when explicitly enabled AND the briefing judged the draft safe
// AND there is a draft AND nothing was escalated. All four, or a human replies.
const canAutoReply = !!ctx.auto_reply
  && d.draft_reply_safe_to_send === true
  && !!d.draft_reply
  && (d.open_questions || []).length === 0;

return [{ json: {
  chat_id: ctx.chat_id, text,
  lead_id: p.lead_id, priority: d.priority,
  dedupe_key: `hotlead:${p.lead_id}:${$('When Called').first().json.reply_id || 'none'}`,
  can_auto_reply: canAutoReply,
  draft_reply: d.draft_reply || '',
  reply_to_address: ctx.reply_to_address,
  reply_subject: ctx.reply_subject ? `Re: ${String(ctx.reply_subject).replace(/^re:\s*/i, '')}` : 'Re: your reply',
  from_email: ctx.from_email, from_name: ctx.from_name,
  booking_url: ctx.booking_url || '',
}}];
""".strip())

    dedupe = pg(b, "Record Notification", """
INSERT INTO acq.notifications (channel, target, body, lead_id, dedupe_key, status)
VALUES ('TELEGRAM', $1, $2, $3::uuid, $4, 'PENDING')
ON CONFLICT (dedupe_key) DO NOTHING
RETURNING id
""".strip(),
        replacement="={{ [ ($json.chat_id || 'unset'), $json.text, $json.lead_id, $json.dedupe_key ] }}",
        always_output=True,
        notes="The unique dedupe_key means a retried execution cannot notify twice "
              "for the same reply.")

    fresh = if_bool(b, "First Time For This Reply?",
                    "={{ $json.id !== undefined && $json.id !== null }}")

    tg = b.node("Send Telegram", "n8n-nodes-base.telegram", {
        "chatId": "={{ $('Format Notification').first().json.chat_id }}",
        "text": "={{ $('Format Notification').first().json.text }}",
        "additionalFields": {"parse_mode": "Markdown", "appendAttribution": False},
    }, tv=1.2, creds="telegram", retries=3, on_error="continueErrorOutput")

    mark = pg(b, "Mark Notified", """
UPDATE acq.notifications SET status = 'SENT', sent_at = now()
 WHERE dedupe_key = $1
""".strip(), replacement="={{ [ $('Format Notification').first().json.dedupe_key ] }}")

    tg_failed = pg(b, "Notification Failed", """
-- One statement, not two: a parameterised query cannot carry multiple
-- statements, and the data-modifying CTE still runs even though nothing
-- selects from it.
WITH marked AS (
  UPDATE acq.notifications SET status = 'FAILED', error = $2
   WHERE dedupe_key = $1
  RETURNING 1
)
INSERT INTO acq.dead_letters (workflow_key, execution_id, node_name, lead_id, error, payload)
SELECT '90_hot_lead_notification', $3, 'Send Telegram',
       NULLIF($4,'')::uuid, 'telegram delivery failed', $5::jsonb
""".strip(),
        replacement="={{ [ $('Format Notification').first().json.dedupe_key, "
                    "($json.error?.message || 'unknown'), $execution.id, "
                    "($('Format Notification').first().json.lead_id || ''), "
                    "JSON.stringify({ text: $('Format Notification').first().json.text }) ] }}",
        notes="A hot lead that could not be announced is a dead letter, not a shrug.")

    auto_gate = if_bool(b, "Auto-Reply Allowed?",
                        "={{ $('Format Notification').first().json.can_auto_reply }}")

    auto_reply = b.node("Send Auto-Reply", "n8n-nodes-base.emailSend", {
        "fromEmail": "={{ $('Format Notification').first().json.from_name + ' <' "
                     "+ $('Format Notification').first().json.from_email + '>' }}",
        "toEmail": "={{ $('Format Notification').first().json.reply_to_address }}",
        "subject": "={{ $('Format Notification').first().json.reply_subject }}",
        "emailFormat": "text",
        "text": "={{ $('Format Notification').first().json.draft_reply "
                "+ ($('Format Notification').first().json.booking_url "
                "? '\\n\\nYou can pick a time here: ' "
                "+ $('Format Notification').first().json.booking_url : '') }}",
        "options": {"appendAttribution": False},
    }, tv=2.1, creds="smtp", retries=2, on_error="continueRegularOutput",
        notes="Replying to someone who wrote to us is not cold outreach, so this "
              "deliberately bypasses the send caps in workflow 50. It is still gated "
              "on outreach.auto_reply_enabled, which ships off.")

    log_reply = pg(b, "Log Auto-Reply", """
INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload, execution_id)
VALUES ($1::uuid, 'AUTO_REPLY_SENT', 'AI', 'Automatic reply sent to interested prospect',
        $2::jsonb, $3)
""".strip(),
        replacement="={{ [ $('Format Notification').first().json.lead_id, "
                    "JSON.stringify({ to: $('Format Notification').first().json.reply_to_address, "
                    "body: $('Format Notification').first().json.draft_reply }), $execution.id ] }}")

    skip = b.node("Already Notified", "n8n-nodes-base.noOp", {}, tv=1)
    human_reply = b.node("Human Will Reply", "n8n-nodes-base.noOp", {}, tv=1)

    b.chain(t, load, ai_in, ai, fmt, dedupe, fresh)
    b.connect(fresh, tg, src_out=0)
    b.connect(fresh, skip, src_out=1)
    b.connect(tg, mark, src_out=0)
    b.connect(tg, tg_failed, src_out=1)
    b.chain(mark, auto_gate)
    b.connect(auto_gate, auto_reply, src_out=0)
    b.chain(auto_reply, log_reply)
    b.connect(auto_gate, human_reply, src_out=1)
    return b.build()


# ==========================================================================
# 100 — Demo Booking + CRM Pipeline
#
# Three independent paths in one workflow: the booking webhook, the daily
# digest, and a nightly sweeper that catches leads stuck in a state.
# ==========================================================================
def wf_demo_crm():
    b = Builder("ACQ 100 — Demo & CRM Pipeline", "wf100")

    # ---- path 1: booking webhook ----
    hook = b.node("Booking Webhook", "n8n-nodes-base.webhook", {
        "httpMethod": "POST",
        "path": "demo-booked",
        "responseMode": "lastNode",
        "options": {},
    }, tv=2, pos=[260, 120],
        notes="Point Cal.com or Calendly at this URL. Both post a JSON body on "
              "booking.created / invitee.created.")

    parse = code(b, "Parse Booking", r"""
// Handles both Cal.com and Calendly shapes without assuming which one is wired up.
const body = $input.first().json.body ?? $input.first().json;
const type = body.triggerEvent || body.event || 'unknown';
const p = body.payload || body;

const invitee = p.invitee || p.attendees?.[0] || p.responses || {};
const email = String(
  invitee.email || p.email || p.attendees?.[0]?.email || ''
).toLowerCase();

const startTime = p.startTime || p.start_time || p.scheduled_event?.start_time || null;
const eventId = String(
  p.uid || p.id || p.uri || p.bookingId || `${email}:${startTime}`
);

const cancelled = /cancel/i.test(type);
const rescheduled = /reschedul/i.test(type);

return [{ json: {
  provider: body.triggerEvent ? 'CAL_COM' : 'CALENDLY',
  provider_event_id: eventId,
  invitee_email: email,
  invitee_name: invitee.name || p.name || '',
  scheduled_at: startTime,
  duration_min: p.length || p.duration || null,
  join_url: p.meetingUrl || p.location || p.scheduled_event?.location?.join_url || null,
  status: cancelled ? 'CANCELLED' : (rescheduled ? 'RESCHEDULED' : 'BOOKED'),
  raw: body,
}}];
""".strip())

    record_demo = pg(b, "Record Booking", """
WITH matched AS (
  SELECT l.id AS lead_id
  FROM acq.leads l
  WHERE l.public_email = $3::citext
  UNION
  SELECT r.lead_id FROM acq.replies r WHERE r.from_email = $3::citext AND r.lead_id IS NOT NULL
  LIMIT 1
),
booked AS (
  INSERT INTO acq.demo_bookings (lead_id, provider, provider_event_id, invitee_email,
                                 invitee_name, scheduled_at, duration_min, join_url,
                                 status, payload)
  SELECT (SELECT lead_id FROM matched), $1, $2, $3::citext, $4,
         NULLIF($5,'')::timestamptz, NULLIF($6,'')::int, NULLIF($7,''), $8, $9::jsonb
  ON CONFLICT (provider, provider_event_id) DO UPDATE
    SET status = EXCLUDED.status, scheduled_at = EXCLUDED.scheduled_at, updated_at = now()
  RETURNING id, lead_id, status
)
SELECT b.id, b.lead_id, b.status,
       CASE WHEN b.lead_id IS NOT NULL AND b.status <> 'CANCELLED'
            THEN acq.transition_lead(b.lead_id, 'DEMO_BOOKED', 'demo_booked', 'SYSTEM')
       END AS moved,
       CASE WHEN b.lead_id IS NOT NULL
            THEN acq.stop_follow_ups(b.lead_id, 'demo_booked')
       END AS cancelled_followups,
       (SELECT clinic_name FROM acq.leads WHERE id = b.lead_id) AS clinic_name
FROM booked b
""".strip(),
        replacement="={{ [ $json.provider, $json.provider_event_id, $json.invitee_email, "
                    "$json.invitee_name, ($json.scheduled_at || ''), "
                    "String($json.duration_min || ''), ($json.join_url || ''), "
                    "$json.status, JSON.stringify($json.raw) ] }}",
        always_output=True,
        notes="Booking with an address we never emailed still gets recorded, with a "
              "null lead_id, rather than being discarded.")

    notify_demo = b.node("Announce Booking", "n8n-nodes-base.telegram", {
        "chatId": "={{ $('Load Notify Target').first().json.chat_id }}",
        "text": "={{ '📅 *Demo ' + $json.status.toLowerCase() + '*\\n\\n'"
                " + '*Clinic:* ' + ($json.clinic_name || $('Parse Booking').first().json.invitee_email) + '\\n'"
                " + '*When:* ' + ($('Parse Booking').first().json.scheduled_at || 'unspecified') + '\\n'"
                " + ($json.lead_id ? '' : '\\n_Not matched to a known lead._') }}",
        "additionalFields": {"parse_mode": "Markdown", "appendAttribution": False},
    }, tv=1.2, creds="telegram", on_error="continueRegularOutput")

    notify_target = pg(b, "Load Notify Target", """
SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegram_chat_id'
""".strip(), execute_once=True, pos=[480, 120])

    # ---- path 2: daily digest ----
    digest_t = cron(b, "Daily Digest 18:00", "0 18 * * 1-5")
    digest_t_node = b.nodes[-1]
    digest_t_node["position"] = [260, 420]

    metrics = pg(b, "Collect Metrics", """
SELECT
  (SELECT row_to_json(o) FROM acq.v_overview o)                            AS overview,
  (SELECT json_agg(f ORDER BY f.stage) FROM acq.v_funnel f)                AS funnel,
  (SELECT row_to_json(d) FROM acq.v_daily_metrics d LIMIT 1)               AS today,
  (SELECT json_agg(row_to_json(x)) FROM acq.v_deliverability x)            AS deliverability,
  (SELECT count(*) FROM acq.approvals WHERE status = 'PENDING')            AS pending_approvals,
  (SELECT count(*) FROM acq.dead_letters WHERE resolved_at IS NULL)        AS open_dead_letters
""".strip(), pos=[480, 420])

    digest = code(b, "Format Digest", r"""
const m = $input.first().json;
const o = m.overview || {};
const t = m.today || {};
const d = (m.deliverability || [])[0] || {};

// Deliverability thresholds worth waking up to. Above ~2% bounce or ~0.1%
// complaint, a young sending domain starts getting filtered, and the fix is to
// stop sending, not to send more carefully.
const warnings = [];
if (Number(d.bounce_rate_pct) > 2)     warnings.push(`⚠️ Bounce rate ${d.bounce_rate_pct}% — pause and clean the list.`);
if (Number(d.complaint_rate_pct) > 0.1) warnings.push(`🚨 Complaint rate ${d.complaint_rate_pct}% — stop sending now.`);
if (Number(m.open_dead_letters) > 0)   warnings.push(`${m.open_dead_letters} unresolved dead letters.`);
if (Number(m.pending_approvals) > 0)   warnings.push(`${m.pending_approvals} drafts waiting for your approval.`);

const text = [
  '📊 *Daily pipeline*',
  '',
  `Sent today: *${t.emails_sent ?? 0}*   Replies: *${t.replies ?? 0}*   Bounces: *${t.hard_bounces ?? 0}*`,
  `AI spend today: *$${Number(t.ai_cost_usd ?? 0).toFixed(3)}*`,
  '',
  `Leads: ${o.total_leads ?? 0} · Qualified: ${o.qualified_leads ?? 0} · Contacted: ${o.emails_sent ?? 0}`,
  `Replies: ${o.replies ?? 0} · Interested: ${o.interested ?? 0} · Demos: ${o.demos ?? 0} · Customers: ${o.customers ?? 0}`,
  `Reply rate: ${o.reply_rate_pct ?? 0}%  ·  Opt-outs: ${o.opt_outs ?? 0}`,
  '',
  `Deliverability — bounce ${d.bounce_rate_pct ?? 0}% · complaint ${d.complaint_rate_pct ?? 0}% · sent today ${d.sent_today ?? 0}/${d.effective_daily_cap ?? 0}`,
  warnings.length ? `\n${warnings.join('\n')}` : '\n✅ Nothing needs your attention.',
].join('\n');

return [{ json: { text } }];
""".strip())

    send_digest = b.node("Send Digest", "n8n-nodes-base.telegram", {
        "chatId": "={{ $('Load Notify Target 2').first().json.chat_id }}",
        "text": "={{ $json.text }}",
        "additionalFields": {"parse_mode": "Markdown", "appendAttribution": False},
    }, tv=1.2, creds="telegram", on_error="continueRegularOutput")

    notify_target2 = pg(b, "Load Notify Target 2", """
SELECT value #>> '{}' AS chat_id FROM acq.settings WHERE key = 'notify.telegram_chat_id'
""".strip(), execute_once=True, pos=[700, 420])

    # ---- path 3: nightly hygiene ----
    sweep_t = cron(b, "Nightly Sweep 02:00", "0 2 * * *")
    b.nodes[-1]["position"] = [260, 700]

    sweep = pg(b, "Release Stale Locks & Leads", """
-- Three kinds of stuck state, all self-healing:
WITH unlocked AS (
  -- 1. leads left locked by an execution that died mid-run
  UPDATE acq.leads SET locked_by = NULL, locked_at = NULL
   WHERE locked_at < now() - interval '2 hours'
  RETURNING 1
),
stuck AS (
  -- 2. leads that entered RESEARCHING and never came out
  UPDATE acq.leads SET status = 'QUALIFIED', status_reason = 'sweeper:stuck_in_researching'
   WHERE status = 'RESEARCHING' AND updated_at < now() - interval '1 day'
  RETURNING 1
),
expired AS (
  -- 3. approvals nobody acted on
  UPDATE acq.approvals SET status = 'EXPIRED'
   WHERE status = 'PENDING' AND expires_at < now()
  RETURNING 1
)
SELECT (SELECT count(*) FROM unlocked) AS locks_released,
       (SELECT count(*) FROM stuck)    AS leads_unstuck,
       (SELECT count(*) FROM expired)  AS approvals_expired
""".strip(), pos=[480, 700])

    log_sweep = pg(b, "Log Sweep", """
INSERT INTO acq.workflow_runs (workflow_key, execution_id, status, finished_at, meta)
VALUES ('100_nightly_sweep', $1, 'SUCCESS', now(), $2::jsonb)
""".strip(),
        replacement="={{ [ $execution.id, JSON.stringify($json) ] }}", pos=[700, 700])

    b.chain(hook, notify_target, parse, record_demo, notify_demo)
    b.chain(digest_t, notify_target2, metrics, digest, send_digest)
    b.chain(sweep_t, sweep, log_sweep)
    return b.build()


# ==========================================================================
# 110 — Unsubscribe Webhook
#
# Small, and the single most important workflow for staying legitimate: the
# opt-out link in every email has to actually work, first time, with no login
# and no confirmation step.
# ==========================================================================
def wf_unsubscribe():
    b = Builder("ACQ 110 — Unsubscribe", "wf110")

    hook = b.node("Unsubscribe Request", "n8n-nodes-base.webhook", {
        "httpMethod": "GET",
        "path": "unsubscribe",
        "responseMode": "responseNode",
        "options": {},
    }, tv=2,
        notes="Set unsubscribe.base_url in acq.settings to this webhook's production "
              "URL. Until it is set, workflow 50 refuses to send anything.")

    apply = pg(b, "Apply Opt-Out", """
-- One click, no confirmation, no login. Unsubscribing must be easier than
-- replying, or it is not a real opt-out.
WITH found AS (
  SELECT id, lead_id, to_email
    FROM acq.emails
   WHERE unsubscribe_token = $1 AND $1 <> ''
   LIMIT 1
)
SELECT
  COALESCE((SELECT true FROM found), false) AS found,
  (SELECT to_email FROM found)              AS address,
  (SELECT clinic_name FROM acq.leads
    WHERE id = (SELECT lead_id FROM found)) AS clinic_name,
  (SELECT acq.apply_opt_out('EMAIL', to_email::text, 'OPT_OUT_REQUEST', 'LIST_UNSUB',
                            lead_id, jsonb_build_object('via', 'unsubscribe_link'))
     FROM found)                            AS opt_out_id
""".strip(),
        replacement="={{ [ ($json.query?.t || '') ] }}",
        always_output=True, retries=2)

    page = code(b, "Build Confirmation Page", r"""
const j = $input.first().json;
const ok = j.found === true;

const body = ok
  ? `<h1>You're unsubscribed</h1>
     <p>We've removed <strong>${j.address}</strong> from our list. You won't hear from us again.</p>
     <p>Sorry for the interruption.</p>`
  : `<h1>Link not recognised</h1>
     <p>This unsubscribe link is not valid, or has already been used.</p>
     <p>If you're still receiving email from us, reply to any message with
        "unsubscribe" and we'll remove you by hand.</p>`;

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Unsubscribe</title>
<style>
  body { font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
         max-width: 34rem; margin: 4rem auto; padding: 0 1.5rem; color: #1a1a1a; }
  h1 { font-size: 1.4rem; margin-bottom: .75rem; }
  p { color: #444; }
  footer { margin-top: 2.5rem; font-size: .85rem; color: #777;
           border-top: 1px solid #e5e5e5; padding-top: 1rem; }
  @media (prefers-color-scheme: dark) {
    body { background: #141414; color: #ededed; }
    p { color: #b4b4b4; }
    footer { color: #8a8a8a; border-top-color: #2c2c2c; }
  }
</style></head>
<body>${body}<footer>Zenvexa · Clinibot</footer></body></html>`;

return [{ json: { html, status: ok ? 200 : 404 } }];
""".strip())

    respond = b.node("Respond", "n8n-nodes-base.respondToWebhook", {
        "respondWith": "text",
        "responseBody": "={{ $json.html }}",
        "options": {
            "responseCode": "={{ $json.status }}",
            "responseHeaders": {"entries": [
                {"name": "Content-Type", "value": "text/html; charset=utf-8"},
                {"name": "Cache-Control", "value": "no-store"},
            ]},
        },
    }, tv=1.1)

    log = pg(b, "Log Opt-Out", """
INSERT INTO acq.sales_activities (lead_id, activity_type, actor, summary, payload, execution_id)
SELECT l.id, 'UNSUBSCRIBED', 'PROSPECT', 'Unsubscribed via the link in an email',
       jsonb_build_object('address', $1::text), $2
FROM acq.leads l WHERE l.public_email = $1::citext
""".strip(),
        replacement="={{ [ ($('Apply Opt-Out').first().json.address || ''), $execution.id ] }}",
        on_error="continueRegularOutput")

    b.chain(hook, apply, page, respond, log)
    return b.build()


# ==========================================================================
WORKFLOWS = [
    ("00_error_handler",        wf_error_handler),
    ("01_ai_call",              wf_ai_call),
    ("10_lead_discovery",       wf_discovery),
    ("20_lead_qualification",   wf_qualification),
    ("30_ai_research",          wf_research),
    ("40_personalization",      wf_personalization),
    ("50_outreach_send",        wf_send),
    ("60_inbox_monitor",        wf_inbox),
    ("70_reply_classification", wf_classification),
    ("80_followup_engine",      wf_followups),
    ("90_hot_lead_notification", wf_hot_lead),
    ("100_demo_crm_pipeline",   wf_demo_crm),
    ("110_unsubscribe",         wf_unsubscribe),
]


def check_prompt_coverage(problems):
    """Every prompt loaded into acq.prompts must be reachable from something.

    A registered-but-uncalled prompt is worse than a missing one: it reads as
    part of the pipeline in the docs and in the database, and silently is not.
    Keys are reached either directly (a prompt_key in this file) or indirectly
    via acq.sequence_steps.prompt_key, which workflow 80 resolves at runtime.
    """
    prompt_dir = ROOT_DIR / "prompts"
    seed = (ROOT_DIR / "db" / "migrations" / "005_seed_config.sql").read_text()
    src = pathlib.Path(__file__).read_text()

    registered = set()
    for f in prompt_dir.glob("*.md"):
        head = f.read_text().split("---")[1]
        for line in head.splitlines():
            if line.startswith("key:"):
                registered.add(line.split(":", 1)[1].strip())
            elif line.startswith("also_keys:"):
                registered.update(k.strip() for k in line.split(":", 1)[1].split(","))

    reached = set(re.findall(r"prompt_key: '([a-z0-9_]+)'", src))
    reached |= set(re.findall(r"'(followup_[a-z0-9_]+)'", seed))

    for orphan in sorted(registered - reached):
        problems.append(
            f"prompt {orphan!r} is registered in prompts/ but no workflow calls it")
    return len(registered), len(registered & reached)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    total_nodes = 0
    problems = []
    n_prompts, n_reached = check_prompt_coverage(problems)

    for filename, fn in WORKFLOWS:
        doc = fn()

        names = [n["name"] for n in doc["nodes"]]
        if len(names) != len(set(names)):
            dupes = {n for n in names if names.count(n) > 1}
            problems.append(f"{filename}: duplicate node names {sorted(dupes)}")

        # Every node except a trigger should be reachable from something.
        targets = {c["node"] for outs in doc["connections"].values()
                   for out in outs["main"] for c in out}
        for n in doc["nodes"]:
            is_trigger = ("Trigger" in n["type"] or "webhook" in n["type"]
                          or "scheduleTrigger" in n["type"] or "emailReadImap" in n["type"])
            if not is_trigger and n["name"] not in targets:
                problems.append(f"{filename}: node {n['name']!r} is unreachable")

        text = json.dumps(doc, indent=2)
        json.loads(text)                       # must round-trip
        (OUT / f"{filename}.json").write_text(text + "\n")
        total_nodes += len(doc["nodes"])
        print(f"  {filename+'.json':<34} {len(doc['nodes']):>3} nodes")

    if problems:
        print("\nPROBLEMS:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print(f"\n{len(WORKFLOWS)} workflows, {total_nodes} nodes, all structurally valid.")
    print(f"{n_reached}/{n_prompts} registered prompts reachable from a workflow.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
