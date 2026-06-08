#!/usr/bin/env bash
# Create (or verify) a LiteLLM virtual key for Open WebUI backend access.
#
# Usage:
#   ./scripts/setup-openwebui-litellm-key.sh
#
# Writes OPENWEBUI_LITELLM_KEY to .env if not already set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing .env — copy .env.example and configure secrets first." >&2
  exit 1
fi

set -a && source "${ENV_FILE}" && set +a

LITELLM_URL="${LITELLM_URL:-http://localhost:4000}"
MASTER_KEY="${LITELLM_MASTER_KEY:-}"

if [[ -z "${MASTER_KEY}" ]]; then
  echo "LITELLM_MASTER_KEY is not set in .env" >&2
  exit 1
fi

if [[ -n "${OPENWEBUI_LITELLM_KEY:-}" ]]; then
  echo "OPENWEBUI_LITELLM_KEY already set in .env — skipping generation."
  echo "Verify with: curl -s ${LITELLM_URL}/v1/models -H \"Authorization: Bearer \$OPENWEBUI_LITELLM_KEY\""
  exit 0
fi

if ! curl -sf "${LITELLM_URL}/health/liveliness" >/dev/null; then
  echo "LiteLLM is not reachable at ${LITELLM_URL}. Start it with ./scripts/start-litellm.sh" >&2
  exit 1
fi

USE_CASE_MODELS='["auto","research","coding","chat","general","image","video"]'

RESPONSE="$(curl -sf -X POST "${LITELLM_URL}/key/generate" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"key_alias\": \"open-webui\",
    \"models\": ${USE_CASE_MODELS},
    \"metadata\": {\"service\": \"open-webui\", \"purpose\": \"employee-ui\"},
    \"rpm_limit\": 60,
    \"max_parallel_requests\": 3
  }")"

NEW_KEY="$(echo "${RESPONSE}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key',''))")"

if [[ -z "${NEW_KEY}" ]]; then
  echo "Failed to create virtual key. Response:" >&2
  echo "${RESPONSE}" >&2
  exit 1
fi

# Ensure .env ends with a newline before appending
if [[ -s "${ENV_FILE}" ]] && [[ -n "$(tail -c1 "${ENV_FILE}" | tr -d '\n')" ]]; then
  echo >> "${ENV_FILE}"
fi

if grep -q '^OPENWEBUI_LITELLM_KEY=' "${ENV_FILE}"; then
  sed -i '' "s|^OPENWEBUI_LITELLM_KEY=.*|OPENWEBUI_LITELLM_KEY=\"${NEW_KEY}\"|" "${ENV_FILE}"
else
  printf '\nOPENWEBUI_LITELLM_KEY="%s"\n' "${NEW_KEY}" >> "${ENV_FILE}"
fi

echo "Created Open WebUI virtual key and saved OPENWEBUI_LITELLM_KEY to .env"
echo "Restart Open WebUI after updating the key: docker compose up -d open-webui"
