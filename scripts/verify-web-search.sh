#!/usr/bin/env bash
# Verify SearXNG and Open WebUI web search configuration.
#
# Prerequisites:
#   docker compose up -d
#   ./scripts/bootstrap-open-webui.sh   # configures web search in Open WebUI DB
#
# Usage:
#   ./scripts/verify-web-search.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a && source "${ENV_FILE}" && set +a
fi

WEBUI_URL="${OPENWEBUI_URL:-http://localhost:8080}"
ENGINE="${WEB_SEARCH_ENGINE:-searxng}"
PASS=0
FAIL=0

check() {
  local name="$1"
  shift
  if "$@"; then
    echo "  OK   ${name}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL ${name}"
    FAIL=$((FAIL + 1))
  fi
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

searxng_returns_json() {
  docker exec open-webui curl -sf "http://searxng:8080/search?q=openai&format=json" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('results') else 1)"
}

research_preset_has_web_search() {
  curl -sf "${WEBUI_URL}/api/v1/models" -H "Authorization: Bearer ${TOKEN}" \
    | python3 -c "
import json, sys
payload = json.load(sys.stdin)
models = payload.get('data', payload if isinstance(payload, list) else [])
research = next((m for m in models if m.get('id') == 'task-research'), None)
info = (research or {}).get('info', {})
caps = info.get('meta', {}).get('capabilities', {})
sys.exit(0 if caps.get('web_search') else 1)
"
}

echo "Web search verification (engine: ${ENGINE})"
echo ""

echo "1. SearXNG container"
check "searxng is running" container_running searxng

if [[ "${ENGINE}" == "searxng" ]]; then
  echo ""
  echo "2. SearXNG JSON API (from open-webui container)"
  check "SearXNG returns JSON results" searxng_returns_json
fi

echo ""
echo "3. Open WebUI retrieval config"
if [[ -n "${OPENWEBUI_ADMIN_EMAIL:-}" && -n "${OPENWEBUI_ADMIN_PASSWORD:-}" ]]; then
  TOKEN="$(curl -sf -X POST "${WEBUI_URL}/api/v1/auths/signin" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${OPENWEBUI_ADMIN_EMAIL}\",\"password\":\"${OPENWEBUI_ADMIN_PASSWORD}\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

  if [[ -n "${TOKEN}" ]]; then
    WEB_CONFIG="$(curl -sf "${WEBUI_URL}/api/v1/retrieval/config" \
      -H "Authorization: Bearer ${TOKEN}" \
      | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('web',{})))" 2>/dev/null || echo '{}')"

    check "ENABLE_WEB_SEARCH is true" \
      python3 -c "import json,sys; exit(0 if json.loads(sys.argv[1]).get('ENABLE_WEB_SEARCH') else 1)" \
      "${WEB_CONFIG}"

    check "WEB_SEARCH_ENGINE is ${ENGINE}" \
      python3 -c "import json,sys; exit(0 if json.loads(sys.argv[1]).get('WEB_SEARCH_ENGINE')=='${ENGINE}' else 1)" \
      "${WEB_CONFIG}"
  else
    echo "  SKIP Open WebUI config (could not sign in)"
  fi
else
  echo "  SKIP Open WebUI config (set OPENWEBUI_ADMIN_EMAIL and OPENWEBUI_ADMIN_PASSWORD in .env)"
fi

echo ""
echo "4. Research preset has web_search capability"
if [[ -n "${TOKEN:-}" ]]; then
  check "task-research model enables web_search" research_preset_has_web_search
else
  echo "  SKIP Research preset check (no auth token)"
fi

echo ""
if [[ ${FAIL} -eq 0 ]]; then
  echo "All checks passed (${PASS})."
  echo "In Open WebUI, select the Research preset and toggle web search in chat (+ icon) to test end-to-end."
  exit 0
fi

echo "${FAIL} check(s) failed, ${PASS} passed."
exit 1
