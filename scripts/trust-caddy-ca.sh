#!/usr/bin/env bash
# Trust Caddy's internal CA so browsers accept https://<lan-ip> on the LAN.
#
# Run after Caddy has started at least once (docker compose up -d caddy).
#
# Usage:
#   ./scripts/trust-caddy-ca.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER="${CADDY_CONTAINER:-ai-caddy}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Caddy container '$CONTAINER' is not running." >&2
  echo "Start it first: docker compose -f ${PROJECT_ROOT}/docker-compose.yml up -d caddy" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

docker cp "${CONTAINER}:/data/caddy/pki/authorities/local/root.crt" "$TMP"

echo "Installing Caddy internal CA into macOS System keychain (requires sudo)..."
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$TMP"

echo "Done. Restart your browser, then open https://<lan-ip>/ui  (run ./scripts/show-lan-url.sh)"
