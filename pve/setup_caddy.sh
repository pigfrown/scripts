#!/usr/bin/env bash

set -euo pipefail

HOSTNAME="${1:-}"
PORT="${2:-}"

CADDYFILE="/etc/caddy/Caddyfile"
CERT_DIR="/opt/certs"
CRT="${CERT_DIR}/${HOSTNAME}_crt.pem"
KEY="${CERT_DIR}/${HOSTNAME}_prv.pem"

if [[ -z "$HOSTNAME" || -z "$PORT" ]]; then
  echo "Usage: $0 <hostname> <port>"
  echo "Example: $0 sonarr 8989"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (to write ${CADDYFILE})"
  exit 1
fi

mkdir -p /etc/caddy

cat > "$CADDYFILE" <<EOF
${HOSTNAME}.home.arpa {
  tls ${CRT} ${KEY}
  reverse_proxy 127.0.0.1:${PORT}
}
EOF

echo "✔ Caddyfile written to ${CADDYFILE}"
echo

if [[ ! -f "$CRT" || ! -f "$KEY" ]]; then
  echo "⚠ TLS certificate files not found:"
  [[ ! -f "$CRT" ]] && echo "  - Missing: ${CRT}"
  [[ ! -f "$KEY" ]] && echo "  - Missing: ${KEY}"
  echo
  echo "Copy your certificate files into place, for example:"
  echo "  cp your-cert.pem ${CRT}"
  echo "  cp your-key.pem  ${KEY}"
else
  echo "✔ TLS certificate files found"
fi

echo
echo "When ready, reload Caddy with:"
echo "  systemctl reload caddy"
