#!/usr/bin/env bash
# Genera el clon de una página pública en site/.
#
#   ./clone.sh                  -> página por defecto: https://policies.google.com/terms
#   ./clone.sh <url>            -> clona esa URL y la deja como página de entrada
#   ./clone.sh <url> <hosts>    -> idem + hosts de assets extra separados por comas
#                                  (si el clon sale sin estilo, pásalos aquí)
#
# Cada invocación refresca SOLO el clon de la página indicada y la deja como
# página de entrada "/" (lo registra en site/.landing). Los clones de otras
# páginas conviven en site/ y se sirven también en su ruta
# (p. ej. /example.com/index.html). Para un borrado total: rm -rf site/.
#
# Tres garantías de seguridad:
#   1) Descarga en staging: el clon nuevo se baja a un directorio temporal y
#      solo sustituye al antiguo si está completo y correcto. Un fallo de red
#      o una descarga errónea nunca borran lo que ya funciona.
#   2) Guarda anti-bucle: si el dominio objetivo está redirigido a esta
#      máquina (línea de /etc/hosts del DNS hijack, caché de
#      systemd-resolved...), wget clonaría el PROPIO clon. Durante la
#      descarga se fija la IP REAL del original en /etc/hosts (IP obtenida
#      vía DNS externo, imposible de desviar por el lab) y se restaura todo
#      al salir, pase lo que pase.
#   3) Comprobación de fidelidad: el <title> del clon debe coincidir con el
#      del original real (descargado vía IP fijada). Si no coincide, el clon
#      NO se instala.
#
# Qué se captura:
#   - Página por defecto: página + subpáginas cercanas (depth 2) — su clon
#     completo, con httrack si está instalado o wget si no.
#   - Otras URLs: esa página + sus recursos (CSS/JS/imágenes) SIN seguir sus
#     enlaces internos: exactamente lo que un clon de phishing necesita.
#
# Por qué la página por defecto SÍ se clona y otras no:
#   - policies.google.com NO publica robots.txt (404) -> sin restricciones de
#     rastreo; todo el contenido público es clonable.
#   - La página es HTML estático + assets en CDN (gstatic), sin challenge
#     anti-bot (Cloudflare Turnstile devuelve 403 a clientes no-navegador).
# Comprueba siempre antes:
#   curl -sI <url>/robots.txt    # 404 = sin restricciones
#   curl -sI <url>               # 200 = accesible; 403 = anti-bot
#
# Cómo se clona (dos herramientas equivalentes):
#   httrack   -> clonador de sitios clásico (apt install httrack).
#   wget      -> ya instalado en casi cualquier sistema.
# Ambos descargan HTML + CSS + JS + imágenes y reescriben los enlaces para
# que la copia se navegue de forma local/offline.
set -euo pipefail
cd "$(dirname "$0")"

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
DEFAULT_URL="https://policies.google.com/terms"
DEFAULT_DOMAINS="policies.google.com,www.gstatic.com,ssl.gstatic.com,fonts.gstatic.com"

URL="${1:-$DEFAULT_URL}"
EXTRA_DOMAINS="${2:-}"
SELF_HOST="$(printf '%s' "$URL" | sed -E 's#^https?://([^/]+).*#\1#')"
SELF_HOST="${SELF_HOST%%:*}"   # quita el puerto si lo trae
case "$URL" in
  https://*) RPORT=443 ;;
  *)         RPORT=80 ;;
esac

# Ruta de la página dentro de su host (sin scheme, sin query, sin fragmento).
REST="$(printf '%s' "$URL" | sed -E 's#^https?://##')"
case "$REST" in
  */*) PAGE_PATH="${REST#*/}" ;;
  *)   PAGE_PATH="" ;;
esac
PAGE_PATH="${PAGE_PATH%%\?*}"
PAGE_PATH="${PAGE_PATH%%#*}"

STAGING="$(mktemp -d)"
HOSTS_BAK=""
cleanup() {
  # Se ejecuta SIEMPRE al salir (éxito o error): restaura /etc/hosts y limpia.
  set +e
  if [ -n "$HOSTS_BAK" ] && [ -f "$HOSTS_BAK" ]; then
    if sudo -n tee /etc/hosts < "$HOSTS_BAK" >/dev/null 2>&1; then
      rm -f "$HOSTS_BAK"
    else
      echo "[clone] AVISO: no se pudo restaurar /etc/hosts automáticamente."
      echo "[clone] cópialo a mano desde: $HOSTS_BAK"
    fi
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT

# --- IP REAL de un host vía DNS EXTERNO (dig consulta al servidor indicado
# directamente — ignora /etc/hosts y la caché local). Fallback: DoH de Google.
ext_resolve() {
  local h="$1" ip=""
  ip="$(dig +short @"${LAB_DNS:-1.1.1.1}" "$h" 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
  if [ -z "$ip" ]; then
    ip="$(curl -fsS --max-time 10 \
      "https://dns.google/resolve?name=$h&type=A" 2>/dev/null \
      | grep -oE '"data":"[0-9]+(\.[0-9]+){3}"' | head -1 \
      | grep -oE '[0-9]+(\.[0-9]+){3}')"
  fi
  printf '%s' "$ip"
}

REAL_IP="$(ext_resolve "$SELF_HOST")"
if [ -z "$REAL_IP" ]; then
  echo "ERROR: no se pudo resolver la IP real de $SELF_HOST vía DNS externo."
  echo "Sin ella no puedo garantizar que no clono este mismo lab (auto-bucle)."
  exit 1
fi

# --- Título del ORIGINAL real y hosts de assets (misma descarga, 2 usos) ----
REF_HTML="$STAGING/__ref.html"
REF_TITLE=""
if curl -fsSL --max-time 30 -A "$UA" \
    --resolve "$SELF_HOST:$RPORT:$REAL_IP" "$URL" -o "$REF_HTML" 2>/dev/null; then
  REF_TITLE="$(grep -o '<title>[^<]*' "$REF_HTML" | head -1)"
fi

if [ "$URL" = "$DEFAULT_URL" ] && [ -z "$EXTRA_DOMAINS" ]; then
  MODE=full
  DOMAINS="$DEFAULT_DOMAINS"
else
  MODE=single
  # Hosts de assets auto-detectados desde el HTML (CSS/JS/imágenes externos):
  # sin --span-hosts hacia esos dominios el clon se ve sin estilo.
  DETECTED="$(grep -oE '(src|href)="(https?:)?//[^/"]+' "$REF_HTML" 2>/dev/null \
    | sed -E 's#^.*//([^/]+).*#\1#' | sort -u | paste -sd, - || true)"
  DOMAINS="$SELF_HOST${DETECTED:+,$DETECTED}${EXTRA_DOMAINS:+,$EXTRA_DOMAINS}"
fi

echo "[clone] $URL"
echo "[clone] dominios: $DOMAINS"
echo "[clone] IP real de $SELF_HOST: $REAL_IP"
[ -n "$REF_TITLE" ] && echo "[clone] original real: $REF_TITLE"

# --- Garantía 2: durante la descarga, TODOS los hosts necesarios resuelven a
# sus IPs reales (líneas del lab en /etc/hosts -> IPs externas). files va
# primero en nsswitch, así que esta fijación es determinista. Al salir,
# cleanup() restaura el fichero original.
PIN_HOSTS="$SELF_HOST www.$SELF_HOST $(printf '%s' "$DOMAINS" | tr ',' ' ')"
NEED_PIN=""
for h in $PIN_HOSTS; do
  case " $NEED_PIN " in *" $h "*) continue ;; esac
  NEED_PIN="$NEED_PIN $h"
done
HOSTS_NEW="$STAGING/hosts.new"
# Quitar las líneas de /etc/hosts de todos los hosts implicados (una por una)
# y añadir después sus IPs reales:
cp /etc/hosts "$HOSTS_NEW"
for h in $NEED_PIN; do
  P="(^|[[:space:]])([a-z0-9-]+\.)*$(printf '%s' "$h" | sed 's/\./\\./g')([[:space:]]|$)"
  grep -vE "$P" "$HOSTS_NEW" > "$HOSTS_NEW.tmp" || true
  mv "$HOSTS_NEW.tmp" "$HOSTS_NEW"
done
PINNED=""
for h in $NEED_PIN; do
  IP=""
  if [ "$h" = "$SELF_HOST" ] || [ "$h" = "www.$SELF_HOST" ]; then
    [ "$h" = "$SELF_HOST" ] && IP="$REAL_IP"
  fi
  [ -z "$IP" ] && IP="$(ext_resolve "$h")"
  [ -z "$IP" ] && continue
  printf '%s %s\n' "$IP" "$h" >> "$HOSTS_NEW"
  PINNED="$PINNED $h=$IP"
done
echo "[clone] fijando IPs reales durante la descarga (anti-bucle):$PINNED"
HOSTS_BAK="$(mktemp)"
cp /etc/hosts "$HOSTS_BAK"
sudo -n tee /etc/hosts < "$HOSTS_NEW" >/dev/null
resolvectl flush-caches >/dev/null 2>&1 || true

# wget/httrack devuelven != 0 ante errores PARCIALES (típico: un asset
# volátil da 404) aunque el clon principal sirva perfectamente: se captura el
# código y se decide al final en vez de abortar por set -e.
CLONE_STATUS=0
if [ "$MODE" = full ] && command -v httrack >/dev/null 2>&1; then
  echo "[clone] usando httrack (depth 2)"
  ( cd "$STAGING" && httrack "$URL" -O . -n -r2 -c6 -A5000000 -%v --robots=0 ) || CLONE_STATUS=$?
elif [ "$MODE" = full ]; then
  echo "[clone] httrack no disponible, usando wget (depth 2)"
  (
    cd "$STAGING"
    wget --mirror --page-requisites --convert-links --adjust-extension \
      --span-hosts --domains="$DOMAINS" \
      --reject 'archive*,*.pdf' --level=2 \
      -e robots=off -U "$UA" \
      "$URL"
  ) || CLONE_STATUS=$?
else
  # Una página + sus recursos, sin seguir enlaces internos (clon de landing).
  echo "[clone] usando wget (una página + recursos)"
  (
    cd "$STAGING"
    wget --page-requisites --convert-links --adjust-extension \
      --span-hosts --domains="$DOMAINS" \
      --reject 'archive*,*.pdf' \
      -e robots=off -U "$UA" \
      "$URL"
  ) || CLONE_STATUS=$?
fi
# wget: 0 = ok; 8 = "Server issued an error response" (algún fichero dio
# 404/5xx, el resto del clon está descargado). Cualquier otro código es real.
if [ "$CLONE_STATUS" -ne 0 ] && [ "$CLONE_STATUS" -ne 8 ]; then
  echo "ERROR: la descarga falló (código $CLONE_STATUS) — el clon anterior NO se ha tocado"
  exit "$CLONE_STATUS"
fi

# Página principal esperada: wget --adjust-extension guarda "ruta.html" cuando
# la URL no lleva extensión.
case "$PAGE_PATH" in
  "")  LANDING="$SELF_HOST/index.html" ;;
  */)  LANDING="$SELF_HOST/${PAGE_PATH}index.html" ;;
  *)   LAST="${PAGE_PATH##*/}"
       case "$LAST" in
         *.*) LANDING="$SELF_HOST/$PAGE_PATH" ;;
         *)   LANDING="$SELF_HOST/$PAGE_PATH.html" ;;
       esac ;;
esac

echo
if [ ! -f "$STAGING/$LANDING" ]; then
  echo "AVISO: no se encontró $LANDING en la descarga — el clon anterior NO se ha tocado."
  echo "Revisa la salida de la descarga y pasa los hosts de assets extra como"
  echo "2º argumento si el clon sale sin estilo."
  exit 1
fi

# --- Garantía 3: el clon debe coincidir con el original real ---------------
CLONE_TITLE="$(grep -o '<title>[^<]*' "$STAGING/$LANDING" | head -1 || true)"
if [ -n "$REF_TITLE" ]; then
  if [ "$CLONE_TITLE" != "$REF_TITLE" ]; then
    echo "ERROR: la comprobación de fidelidad ha fallado:"
    echo "  original real:  $REF_TITLE"
    echo "  clon obtenido:  ${CLONE_TITLE:-<sin título>}"
    echo "El clon anterior NO se ha tocado. (¿la URL está redirigida a otro sitio?)"
    exit 1
  fi
  echo "[fidelidad] OK — el clon coincide con el original real"
elif [ -z "$CLONE_TITLE" ]; then
  echo "ERROR: el clon no tiene <title> y no hay original para comparar."
  echo "El clon anterior NO se ha tocado."
  exit 1
else
  echo "AVISO: sin acceso al original real para comparar (¿red caída?)."
  echo "Instalo el clon basándome solo en su estructura: $CLONE_TITLE"
fi

# --- Garantía 1: sustituir en site/ SOLO los dominios ya descargados -------
mkdir -p site
for d in ${DOMAINS//,/ }; do
  if [ -d "$STAGING/$d" ]; then
    rm -rf "site/$d"
    mv "$STAGING/$d" site/
  fi
done
printf '%s\n' "$LANDING" > site/.landing
echo "clon generado en site/  (página principal: site/$LANDING)"
echo "comprobación manual:  grep -o '<title>[^<]*' site/$LANDING"
echo "para servirlo: ./up.sh  (previa ./setup.sh)"
