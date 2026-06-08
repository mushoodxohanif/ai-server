#!/usr/bin/env bash
# Start LiteLLM with .env loaded (PROXY_BASE_URL + master key for admin UI).
set -euo pipefail
cd "$(dirname "$0")/.."
source venv/bin/activate
set -a && source .env && set +a
exec litellm --config litellm_config.yaml --port 4000 --host 0.0.0.0
