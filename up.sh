#!/usr/bin/env bash
# One-command lab launcher: build, start, verify.
set -euo pipefail
cd "$(dirname "$0")"

[ -f certs/server.pem ] || { echo "certs/ missing — run ./setup.sh first"; exit 1; }
touch captured.log

docker compose up -d --build

if [ -x bin/mkcert ]; then MKCERT="$PWD/bin/mkcert"; else MKCERT=mkcert; fi
CAROOT="$("$MKCERT" -CAROOT)"

for _ in $(seq 1 30); do
  curl -fs --cacert "$CAROOT/rootCA.pem" https://localhost:8443/ >/dev/null 2>&1 && break
  sleep 0.5
done

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"
echo "lab is up:"
echo "  https://pccomponentes.lab        (same machine, clean URL via port 443)"
echo "  https://localhost:8443"
[ -n "$LAN_IP" ] && echo "  https://${LAN_IP}:8443         (from another device on your LAN)"
echo
echo "watch captures:  tail -f captured.log"
echo "container logs:  docker compose logs -f"
echo "stop the lab:    docker compose down"
