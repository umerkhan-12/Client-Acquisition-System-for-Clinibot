#!/usr/bin/env bash
# Pre-flight check for a sending domain: SPF, DKIM, DMARC, MX, blocklists.
#
#   ./scripts/check_deliverability.sh sending-domain.tld <dkim-selector>
#   ./scripts/check_deliverability.sh --self-test
#
# Exits non-zero when something required is missing, so it works as a gate
# before the first send.
#
# Resolution uses `dig` when present and falls back to DNS-over-HTTPS via curl,
# so it runs on a bare container as well as a droplet. The record-evaluation
# logic is separated from resolution and covered by --self-test.
set -uo pipefail

PASS=0; WARN=0; FAIL=0

emit() { # emit OK|WARN|BAD "message"
  case "$1" in
    OK)   printf '  \033[32m✓\033[0m %s\n' "$2"; PASS=$((PASS+1)) ;;
    WARN) printf '  \033[33m!\033[0m %s\n' "$2"; WARN=$((WARN+1)) ;;
    BAD)  printf '  \033[31m✗\033[0m %s\n' "$2"; FAIL=$((FAIL+1)) ;;
  esac
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------

have_dig() { command -v dig >/dev/null 2>&1; }

_doh() { # _doh <name> <type-number> ; prints one record per line
  command -v curl >/dev/null 2>&1 || return 1
  curl -sS --max-time 12 -H 'Accept: application/dns-json' \
       "https://cloudflare-dns.com/dns-query?name=$1&type=$2" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for a in d.get("Answer", []):
    if a.get("type") in (16, 15):
        print(a.get("data", "").strip())
' 2>/dev/null
}

resolve_txt() { # concatenates split strings, strips quotes
  if have_dig; then
    dig +short TXT "$1" 2>/dev/null | sed 's/" "//g; s/^"//; s/"$//'
  else
    _doh "$1" 16 | sed 's/" "//g; s/^"//; s/"$//'
  fi
}

resolve_mx() {
  if have_dig; then dig +short MX "$1" 2>/dev/null
  else _doh "$1" 15; fi
}

resolve_a() {
  if have_dig; then dig +short A "$1" 2>/dev/null
  else
    command -v curl >/dev/null 2>&1 || return 1
    curl -sS --max-time 12 -H 'Accept: application/dns-json' \
         "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null \
    | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for a in d.get("Answer", []):
    if a.get("type")==1: print(a.get("data",""))
' 2>/dev/null
  fi
}

# ---------------------------------------------------------------------
# Evaluation — pure functions over record text, exercised by --self-test
# ---------------------------------------------------------------------

eval_spf() { # eval_spf <newline-separated TXT records>
  local records="$1" spf count lookups
  mapfile -t spf < <(grep -i '^v=spf1' <<<"$records" || true)
  count=${#spf[@]}

  if   (( count == 0 )); then emit BAD "no SPF record — mail will be unauthenticated"; return
  elif (( count > 1 ));  then emit BAD "$count SPF records. More than one is a PERMERROR, not a merge."; return
  fi

  emit OK "SPF present: ${spf[0]}"
  case "${spf[0]}" in
    *-all*) emit OK   "hardfail (-all) — correct for a settled domain" ;;
    *"~all"*) emit WARN "softfail (~all) — fine while warming; move to -all once stable" ;;
    *"?all"*|*"+all"*) emit BAD "neutral or pass-all provides no protection" ;;
    *) emit WARN "no explicit 'all' mechanism" ;;
  esac

  lookups=$(grep -o -E '(^| )(include:|a:|mx:|ptr:|exists:|redirect=)' <<<"${spf[0]}" | wc -l | tr -d ' ')
  if   (( lookups > 10 )); then emit BAD  "$lookups DNS-lookup mechanisms — the limit is 10 (PERMERROR)"
  elif (( lookups > 7 ));  then emit WARN "$lookups DNS-lookup mechanisms — close to the limit of 10"
  else                          emit OK   "$lookups DNS-lookup mechanisms (limit 10)"; fi
}

eval_dkim() { # eval_dkim <record> <selector>
  local rec="$1" selector="$2"
  if   [[ -z "$rec" ]];                     then emit BAD "no TXT at ${selector}._domainkey"
  elif ! grep -qi 'v=DKIM1' <<<"$rec";      then emit BAD "record at '$selector' is not a DKIM key"
  elif ! grep -q 'p=[A-Za-z0-9+/]' <<<"$rec"; then emit BAD "DKIM key is empty (p= with no value) — the key is revoked"
  else
    emit OK "DKIM key present at selector '$selector'"
    if (( ${#rec} < 250 )); then
      emit WARN "key looks short (~1024-bit); 2048-bit is the current expectation"
    else
      emit OK "key length consistent with 2048-bit"
    fi
  fi
}

eval_dmarc() { # eval_dmarc <record>
  local rec policy
  rec="$(grep -i '^v=DMARC1' <<<"$1" | head -1 || true)"
  if [[ -z "$rec" ]]; then emit BAD "no DMARC record"; return; fi

  emit OK "DMARC present: $rec"
  policy="$(grep -o 'p=[a-z]*' <<<"$rec" | head -1 | cut -d= -f2)"
  case "$policy" in
    reject)     emit OK   "p=reject — steady state" ;;
    quarantine) emit OK   "p=quarantine — good progression" ;;
    none)       emit WARN "p=none — monitoring only; move to quarantine once reports look clean" ;;
    *)          emit BAD  "no policy set" ;;
  esac
  if grep -qi 'rua=' <<<"$rec"; then
    emit OK "aggregate reports (rua) configured"
  else
    emit WARN "no rua= — you will not get the reports that tell you when to escalate"
  fi
}

eval_mx() {
  if [[ -z "${1// /}" ]]; then
    emit BAD "no MX record — you cannot receive replies or bounces, and it reads as a throwaway domain"
  else
    emit OK "MX present"
    sed 's/^/      /' <<<"$1"
  fi
}

# ---------------------------------------------------------------------
# Self-test: runs the evaluators over fixtures with known-correct verdicts
# ---------------------------------------------------------------------

self_test() {
  local failures=0
  check() { # check <label> <expected OK> <expected WARN> <expected BAD> <fn> <args...>
    local label="$1" eo="$2" ew="$3" eb="$4"; shift 4
    PASS=0; WARN=0; FAIL=0
    "$@" >/dev/null
    if [[ "$PASS:$WARN:$FAIL" == "$eo:$ew:$eb" ]]; then
      printf '  \033[32m✓\033[0m %s\n' "$label"
    else
      printf '  \033[31m✗\033[0m %s — expected %s:%s:%s got %s:%s:%s\n' \
             "$label" "$eo" "$ew" "$eb" "$PASS" "$WARN" "$FAIL"
      failures=$((failures+1))
    fi
  }

  printf '\033[1mSelf-test — record evaluation\033[0m\n\n'
  printf 'SPF\n'
  check "settled record (-all, 1 lookup)"      3 0 0 eval_spf 'v=spf1 include:zoho.com -all'
  check "warming record (~all)"                2 1 0 eval_spf 'v=spf1 include:zoho.com ~all'
  check "pass-all is useless"                  2 0 1 eval_spf 'v=spf1 include:zoho.com +all'
  check "missing record"                       0 0 1 eval_spf 'some other txt record'
  check "two records is a PERMERROR"           0 0 1 eval_spf $'v=spf1 include:a.com -all\nv=spf1 include:b.com -all'
  check "over the 10-lookup limit"             2 0 1 eval_spf 'v=spf1 include:a include:b include:c include:d include:e include:f include:g include:h include:i include:j include:k -all'
  check "no all mechanism"                     2 1 0 eval_spf 'v=spf1 include:zoho.com'

  printf '\nDKIM\n'
  local long_key="v=DKIM1; k=rsa; p=$(printf 'A%.0s' {1..300})"
  check "2048-bit key"                         2 0 0 eval_dkim "$long_key" s1
  check "short key warns"                      1 1 0 eval_dkim 'v=DKIM1; k=rsa; p=AAAA' s1
  check "revoked key (empty p=)"               0 0 1 eval_dkim 'v=DKIM1; k=rsa; p=' s1
  check "missing record"                       0 0 1 eval_dkim '' s1
  check "not a DKIM record"                    0 0 1 eval_dkim 'v=spf1 -all' s1

  printf '\nDMARC\n'
  check "p=reject with rua"                    3 0 0 eval_dmarc 'v=DMARC1; p=reject; rua=mailto:d@x.tld'
  check "p=quarantine with rua"                3 0 0 eval_dmarc 'v=DMARC1; p=quarantine; rua=mailto:d@x.tld'
  check "p=none warns, no rua warns"           1 2 0 eval_dmarc 'v=DMARC1; p=none'
  check "missing policy"                       2 0 1 eval_dmarc 'v=DMARC1; rua=mailto:d@x.tld'
  check "missing record"                       0 0 1 eval_dmarc 'v=spf1 -all'

  printf '\nMX\n'
  check "records present"                      1 0 0 eval_mx '10 mx.zoho.com.'
  check "no records"                           0 0 1 eval_mx ''

  printf '\n'
  if (( failures )); then
    printf '\033[31m%d self-test failure(s).\033[0m\n' "$failures"; return 1
  fi
  printf '\033[32mAll evaluation logic verified.\033[0m\n'; return 0
}

# ---------------------------------------------------------------------

if [[ "${1:-}" == "--self-test" ]]; then self_test; exit $?; fi

DOMAIN="${1:-}"
SELECTOR="${2:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "usage: $0 <domain> [dkim-selector]" >&2
  echo "       $0 --self-test" >&2
  exit 2
fi
if ! have_dig && ! command -v curl >/dev/null 2>&1; then
  echo "need either dig or curl to resolve DNS" >&2; exit 2
fi
have_dig || printf '\033[33mnote: dig not found, resolving over DNS-over-HTTPS\033[0m\n'

printf '\033[1mDeliverability check — %s\033[0m\n' "$DOMAIN"

section "SPF";   eval_spf "$(resolve_txt "$DOMAIN")"

section "DKIM"
if [[ -z "$SELECTOR" ]]; then
  emit WARN "no selector given — trying common ones"
  for s in default google zoho zmail s1 s2 selector1 selector2 mail k1; do
    if grep -qi 'v=DKIM1' <<<"$(resolve_txt "${s}._domainkey.${DOMAIN}")"; then SELECTOR="$s"; break; fi
  done
fi
if [[ -z "$SELECTOR" ]]; then
  emit BAD "no DKIM key at any common selector — pass yours as the second argument"
else
  eval_dkim "$(resolve_txt "${SELECTOR}._domainkey.${DOMAIN}")" "$SELECTOR"
fi

section "DMARC"; eval_dmarc "$(resolve_txt "_dmarc.${DOMAIN}")"
section "MX";    eval_mx "$(resolve_mx "$DOMAIN")"

section "Blocklists"
for BL in zen.spamhaus.org dbl.spamhaus.org b.barracudacentral.org; do
  RES="$(resolve_a "${DOMAIN}.${BL}")"
  if [[ -n "$RES" ]]; then emit BAD "LISTED on $BL ($RES)"; else emit OK "not listed on $BL"; fi
done

printf '\n\033[1mSummary\033[0m  %d passed, %d warnings, %d failures\n' "$PASS" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
  printf '\033[31mNot ready to send.\033[0m Fix the failures above first.\n'; exit 1
fi
if (( WARN > 0 )); then
  printf '\033[33mReady to send, with caveats.\033[0m Review the warnings above.\n'; exit 0
fi
printf '\033[32mReady to send.\033[0m\n'
