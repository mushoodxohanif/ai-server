#!/usr/bin/env bash
# Print this Mac's LAN IP and the HTTPS URLs employees should use.
#
# Usage:
#   ./scripts/show-lan-url.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

detect_lan_ip() {
  if [[ -n "${LAN_IP:-}" ]]; then
    echo "$LAN_IP"
    return 0
  fi
  if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    local from_env
    from_env="$(grep -E '^LAN_IP=' "${PROJECT_ROOT}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'" || true)"
    if [[ -n "$from_env" ]]; then
      echo "$from_env"
      return 0
    fi
  fi
  local ip=""
  for iface in en0 en1 bridge0; do
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    if [[ -n "$ip" && "$ip" != "127.0.0.1" ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

IP="$(detect_lan_ip || true)"
if [[ -z "$IP" ]]; then
  echo "Could not detect LAN IP. Set LAN_IP in .env and re-run." >&2
  exit 1
fi

BASE="https://${IP}"

cat <<EOF
LAN access URLs
===============

Mac LAN IP:  ${IP}

Employee UI (Open WebUI):  ${BASE}/
LiteLLM admin UI:          ${BASE}/ui/login/
API base (LiteLLM):        ${BASE}/v1
Health check:              ${BASE}/health/liveliness

Task modes: Open WebUI → model selector → Research, Chat, Code, Image, Auto

Trust TLS cert on each Mac (one-time — required for Chrome):
  ./scripts/trust-caddy-ca.sh
EOF
