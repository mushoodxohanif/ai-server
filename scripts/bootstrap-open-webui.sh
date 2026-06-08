#!/usr/bin/env bash
# Bootstrap Open WebUI: admin account, task-mode presets, and web search config.
#
# Prerequisites:
#   docker compose up -d
#   ./scripts/setup-openwebui-litellm-key.sh
#   ./scripts/start-litellm.sh
#
# Usage:
#   ./scripts/bootstrap-open-webui.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
PRESETS_FILE="${PROJECT_ROOT}/config/open-webui-presets.json"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing .env — copy .env.example and configure secrets first." >&2
  exit 1
fi

set -a && source "${ENV_FILE}" && set +a

WEBUI_URL="${OPENWEBUI_URL:-http://localhost:8080}"
ADMIN_EMAIL="${OPENWEBUI_ADMIN_EMAIL:-admin@xorora.com}"
ADMIN_PASSWORD="${OPENWEBUI_ADMIN_PASSWORD:-}"
ADMIN_NAME="${OPENWEBUI_ADMIN_NAME:-Admin}"

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  echo "Set OPENWEBUI_ADMIN_PASSWORD in .env before running bootstrap." >&2
  exit 1
fi

wait_for_webui() {
  local attempts=0
  until [[ "$(curl -s -o /dev/null -w '%{http_code}' "${WEBUI_URL}/" 2>/dev/null || echo 0)" == "200" ]]; do
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 90 ]]; then
      echo "Open WebUI not ready at ${WEBUI_URL} after 90 attempts (~3 min)." >&2
      echo "Check: docker logs open-webui" >&2
      exit 1
    fi
    sleep 2
  done
}

get_token() {
  local response
  response="$(curl -sf -X POST "${WEBUI_URL}/api/v1/auths/signin" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}" 2>/dev/null || true)"
  echo "${response}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || true
}

create_admin() {
  local response http_code body token
  response="$(curl -s -w '\n%{http_code}' -X POST "${WEBUI_URL}/api/v1/auths/signup" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"name\":\"${ADMIN_NAME}\"}")"
  http_code="$(echo "${response}" | tail -1)"
  body="$(echo "${response}" | sed '$d')"

  if [[ "${http_code}" == "200" ]]; then
    token="$(echo "${body}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")"
    echo "Created Open WebUI admin account: ${ADMIN_EMAIL}" >&2
    echo "${token}"
    return 0
  fi

  if echo "${body}" | grep -qi "already\|exists\|registered"; then
    echo "Admin account already exists — signing in." >&2
    get_token
    return 0
  fi

  echo "Signup failed (HTTP ${http_code}): ${body}" >&2
  exit 1
}

import_presets() {
  local token="$1"
  if [[ ! -f "${PRESETS_FILE}" ]]; then
    echo "Missing presets file: ${PRESETS_FILE}" >&2
    exit 1
  fi

  curl -sf -X POST "${WEBUI_URL}/api/v1/models/import" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d @"${PRESETS_FILE}" >/dev/null

  echo "Imported task-mode presets (Research, Chat, Code, Image, Auto)."
}

configure_web_search() {
  local token="$1"
  local engine="${WEB_SEARCH_ENGINE:-searxng}"

  if [[ "${engine}" == "tavily" && -z "${TAVILY_API_KEY:-}" ]]; then
    echo "WEB_SEARCH_ENGINE=tavily requires TAVILY_API_KEY in .env" >&2
    exit 1
  fi

  WEBUI_URL="${WEBUI_URL}" TOKEN="${token}" WEB_SEARCH_ENGINE="${engine}" \
    TAVILY_API_KEY="${TAVILY_API_KEY:-}" \
    SEARXNG_QUERY_URL="${SEARXNG_QUERY_URL:-http://searxng:8080/search?q=<query>}" \
    SEARXNG_LANGUAGE="${SEARXNG_LANGUAGE:-en}" \
    WEB_SEARCH_RESULT_COUNT="${WEB_SEARCH_RESULT_COUNT:-5}" \
    WEB_SEARCH_CONCURRENT_REQUESTS="${WEB_SEARCH_CONCURRENT_REQUESTS:-10}" \
    WEB_LOADER_CONCURRENT_REQUESTS="${WEB_LOADER_CONCURRENT_REQUESTS:-10}" \
    python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

webui_url = os.environ["WEBUI_URL"]
token = os.environ["TOKEN"]
engine = os.environ.get("WEB_SEARCH_ENGINE", "searxng")

headers = {"Authorization": f"Bearer {token}"}

try:
    with urllib.request.urlopen(
        urllib.request.Request(f"{webui_url}/api/v1/retrieval/config", headers=headers)
    ) as resp:
        config = json.load(resp)
except urllib.error.HTTPError as exc:
    print(f"Failed to read retrieval config (HTTP {exc.code})", file=sys.stderr)
    sys.exit(1)

web = config.get("web") or {}
web["ENABLE_WEB_SEARCH"] = True
web["WEB_SEARCH_ENGINE"] = engine
web["WEB_SEARCH_RESULT_COUNT"] = int(os.environ.get("WEB_SEARCH_RESULT_COUNT", "5"))
web["WEB_SEARCH_CONCURRENT_REQUESTS"] = int(
    os.environ.get("WEB_SEARCH_CONCURRENT_REQUESTS", "10")
)
web["WEB_LOADER_CONCURRENT_REQUESTS"] = int(
    os.environ.get("WEB_LOADER_CONCURRENT_REQUESTS", "10")
)
web["BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL"] = True

if engine == "searxng":
    web["SEARXNG_QUERY_URL"] = os.environ.get(
        "SEARXNG_QUERY_URL", "http://searxng:8080/search?q=<query>"
    )
    web["SEARXNG_LANGUAGE"] = os.environ.get("SEARXNG_LANGUAGE", "en")
elif engine == "tavily":
    web["TAVILY_API_KEY"] = os.environ["TAVILY_API_KEY"]

payload = json.dumps({"web": web}).encode()
update_req = urllib.request.Request(
    f"{webui_url}/api/v1/retrieval/config/update",
    data=payload,
    headers={**headers, "Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(update_req) as resp:
        json.load(resp)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(f"Failed to update web search config (HTTP {exc.code}): {body}", file=sys.stderr)
    sys.exit(1)

print(f"Configured web search: engine={engine}, enabled=True (Research preset uses this).")
PY
}

configure_image_generation() {
  local token="$1"

  WEBUI_URL="${WEBUI_URL}" TOKEN="${token}" \
    IMAGE_GENERATION_MODEL="${IMAGE_GENERATION_MODEL:-x/flux2-klein:9b}" \
    IMAGES_OPENAI_API_BASE_URL="${IMAGES_OPENAI_API_BASE_URL:-http://host.docker.internal:11434/v1}" \
    python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

webui_url = os.environ["WEBUI_URL"]
token = os.environ["TOKEN"]
headers = {"Authorization": f"Bearer {token}"}

try:
    with urllib.request.urlopen(
        urllib.request.Request(f"{webui_url}/api/v1/images/config", headers=headers)
    ) as resp:
        config = json.load(resp)
except urllib.error.HTTPError as exc:
    print(f"Failed to read image config (HTTP {exc.code})", file=sys.stderr)
    sys.exit(1)

config["ENABLE_IMAGE_GENERATION"] = True
config["ENABLE_IMAGE_PROMPT_GENERATION"] = False
config["IMAGE_GENERATION_ENGINE"] = "openai"
config["IMAGE_GENERATION_MODEL"] = os.environ.get("IMAGE_GENERATION_MODEL", "x/flux2-klein:9b")
config["IMAGES_OPENAI_API_BASE_URL"] = os.environ.get(
    "IMAGES_OPENAI_API_BASE_URL", "http://host.docker.internal:11434/v1"
)
config["IMAGES_OPENAI_API_KEY"] = "ollama"
config["IMAGE_SIZE"] = "1024x1024"
config["IMAGE_STEPS"] = 4

payload = json.dumps(config).encode()
update_req = urllib.request.Request(
    f"{webui_url}/api/v1/images/config/update",
    data=payload,
    headers={**headers, "Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(update_req) as resp:
        json.load(resp)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(f"Failed to update image config (HTTP {exc.code}): {body}", file=sys.stderr)
    sys.exit(1)

print("Configured image generation: Ollama flux2-klein via /v1/images/generations.")
PY
}

echo "Waiting for Open WebUI at ${WEBUI_URL}..."
wait_for_webui

TOKEN="$(get_token)"
if [[ -z "${TOKEN}" ]]; then
  TOKEN="$(create_admin)"
fi

if [[ -z "${TOKEN}" ]]; then
  echo "Could not obtain Open WebUI auth token." >&2
  exit 1
fi

import_presets "${TOKEN}"
configure_web_search "${TOKEN}"
configure_image_generation "${TOKEN}"

echo ""
echo "Bootstrap complete."
echo "  Employee UI: ${PROXY_BASE_URL:-${WEBUI_URL}}"
echo "  Admin login: ${ADMIN_EMAIL}"
echo "  Task modes:  Workspace → Models → filter by tag \"Task Mode\""
echo "  Web search:  Research preset + SearXNG (or Tavily if configured)"
echo "  Image gen:   Image preset → type a prompt (e.g. \"juicy strawberry\")"
