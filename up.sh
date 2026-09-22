#!/usr/bin/env bash
# Arranque único del laboratorio: build, start, verify.
set -euo pipefail
cd "$(dirname "$0")"

[ -f certs/server.pem ] || { echo "faltan certificados — ejecuta ./setup.sh"; exit 1; }
[ -f site/.landing ] || [ -f site/policies.google.com/terms.html ] \
  || { echo "site/ sin clon — ejecuta ./clone.sh (o ./setup.sh)"; exit 1; }
touch access.log

# LAB_IP lo usa compose.yaml para bindear el 443 en la interfaz de LAN
# (necesario para el hijack del dominio REAL policies.google.com).
export LAB_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"

docker compose up -d --build

if [ -x bin/mkcert ]; then MKCERT="$PWD/bin/mkcert"; else MKCERT=mkcert; fi
CAROOT="$("$MKCERT" -CAROOT)"

for _ in $(seq 1 30); do
  curl -fs --cacert "$CAROOT/rootCA.pem" https://localhost:8443/ >/dev/null 2>&1 && break
  sleep 0.5
done

echo "laboratorio en marcha:"
echo "  https://policies.google.lab:8443   (esta máquina, dominio falso)"
echo "  https://localhost:8443"
[ -n "$LAB_IP" ] && echo "  https://${LAB_IP}:8443             (otro dispositivo de la LAN)"
[ -n "$LAB_IP" ] && echo "  https://policies.google.com/terms  (SOLO con ./dns.sh up y el DNS del cliente apuntando a ${LAB_IP})"
echo
echo "DNS hijack (dominio real, toda la LAN):  ./dns.sh up"
echo "peticiones en vivo:     tail -f access.log"
echo "logs del contenedor:    docker compose logs -f"
echo "parar el laboratorio:   docker compose down"
