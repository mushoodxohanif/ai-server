#!/usr/bin/env bash
# Write detected LAN IP and PROXY_BASE_URL into .env.
#
# Usage:
#   ./scripts/sync-lan-env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

IP="$("${SCRIPT_DIR}/show-lan-url.sh" 2>/dev/null | awk '/^Mac LAN IP:/ {print $4}')"
if [[ -z "$IP" ]]; then
  echo "Could not detect LAN IP." >&2
  exit 1
fi

BASE="https://${IP}"
touch "$ENV_FILE"

python3 - "$ENV_FILE" "$IP" "$BASE" <<'PY'
import re, sys
path, lan_ip, base = sys.argv[1:4]
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
for key, val in {"LAN_IP": lan_ip, "PROXY_BASE_URL": base}.items():
    line = f'{key}="{val}"'
    if re.search(rf"^{re.escape(key)}=", text, re.M):
        text = re.sub(rf"^{re.escape(key)}=.*$", line, text, flags=re.M)
    else:
        text = text.rstrip("\n") + ("\n" if text else "") + line + "\n"
open(path, "w").write(text)
PY

echo "Updated .env: LAN_IP=${IP}, PROXY_BASE_URL=${BASE}"
echo "Restart LiteLLM if it is running."
