#!/usr/bin/env bash
# Checks every environment variable docker-compose.yml sets on the n8n service
# against an installed n8n, because n8n ignores unknown variables silently.
#
#   npm install n8n
#   ./scripts/check_n8n_env.sh ./node_modules/n8n
#
# This exists because docker-compose.yml originally set N8N_BASIC_AUTH_ACTIVE,
# N8N_BASIC_AUTH_USER and N8N_BASIC_AUTH_PASSWORD. n8n removed basic auth; the
# variables did nothing, and the compose file described a UI as protected when
# it was not. Re-run this after every n8n upgrade.
set -uo pipefail

N8N_DIR="${1:-./node_modules/n8n}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"

[ -d "$N8N_DIR" ] || { echo "n8n package not found at '$N8N_DIR'. Install with: npm install n8n" >&2; exit 2; }

SEARCH_DIRS=""
for d in "$N8N_DIR/dist" "$N8N_DIR/../@n8n/config/dist"; do
  [ -d "$d" ] && SEARCH_DIRS="$SEARCH_DIRS $d"
done
[ -n "$SEARCH_DIRS" ] || { echo "no n8n dist directories to search under '$N8N_DIR'" >&2; exit 2; }

# Variables the n8n service sets, excluding ones consumed by Docker itself.
VARS=$(awk '/^  n8n:/{inblock=1} /^  [a-z]/{if($0 !~ /^  n8n:/) inblock=0}
            inblock && /^      [A-Z][A-Z0-9_]*:/{gsub(/:.*/,""); gsub(/ /,""); print}' "$COMPOSE" \
       | grep -vx "TZ" | sort -u)

pass=0; fail=0
printf '\033[1mChecking docker-compose.yml against %s\033[0m\n\n' "$(basename "$(cd "$N8N_DIR" && pwd)")"
for v in $VARS; do
  if grep -rql --include=*.js --include=*.json "$v" $SEARCH_DIRS 2>/dev/null; then
    printf '  \033[32m✓\033[0m %s\n' "$v"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s — not recognised by this n8n; it will be ignored silently\n' "$v"
    fail=$((fail+1))
  fi
done

printf '\n\033[1m%d recognised, %d unrecognised\033[0m\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf '\033[31mFix or remove the unrecognised variables.\033[0m\n'
  exit 1
fi
printf '\033[32mEvery variable is honoured by this n8n version.\033[0m\n'
