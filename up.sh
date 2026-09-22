#!/usr/bin/env bash
# One-command lab launcher: build, start, verify.
set -euo pipefail
cd "$(dirname "$0")"

[ -f certs/server.pem ] || { echo "certs/ missing — run ./setup.sh first"; exit 1; }
[ -f site/policies.google.com/terms.html ] || { echo "site/ missing — run ./clone.sh (or ./setup.sh)"; exit 1; }
touch access.log

# LAB_IP is used by compose.yaml to bind port 443 on the LAN interface
# (needed for the DNS-hijack of the real domain policies.google.com).
export LAB_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"

docker compose up -d --build

if [ -x bin/mkcert ]; then MKCERT="$PWD/bin/mkcert"; else MKCERT=mkcert; fi
CAROOT="$("$MKCERT" -CAROOT)"

for _ in $(seq 1 30); do
  curl -fs --cacert "$CAROOT/rootCA.pem" https://localhost:8443/ >/dev/null 2>&1 && break
  sleep 0.5
done

echo "lab is up:"
echo "  https://policies.google.lab:8443  (same machine, lookalike domain)"
echo "  https://localhost:8443"
[ -n "$LAB_IP" ] && echo "  https://${LAB_IP}:8443          (from another device on your LAN)"
[ -n "$LAB_IP" ] && echo "  https://policies.google.com      (SOLO con ./dns.sh up + DNS del cliente apuntando a ${LAB_IP})"
echo
echo "DNS hijack (dominio real):  ./dns.sh up"
echo "watch requests:  tail -f access.log"
echo "container logs:  docker compose logs -f"
echo "stop the lab:    docker compose down"
