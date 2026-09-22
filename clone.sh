#!/usr/bin/env bash
# Regenera el clon de policies.google.com/terms en site/.
# Idempotente: borra site/ y lo reconstruye desde cero.
#
# Por qué ESTA página sí se puede clonar y otras no:
#   - policies.google.com NO publica robots.txt (404) -> sin restricciones de
#     rastreo; todo el contenido público es clonable.
#   - La página es HTML estático + assets en CDN (gstatic), sin challenge
#     anti-bot (Cloudflare Turnstile devuelve 403 a clientes no-navegador).
#
# Cómo se clona (dos herramientas equivalentes):
#   httrack   -> clonador de sitios clásico (apt install httrack).
#   wget      -> ya instalado en casi cualquier sistema.
# Ambos descargan HTML + CSS + JS + imágenes y reescriben los enlaces para
# que la copia se navegue de forma local/offline.
set -euo pipefail
cd "$(dirname "$0")"

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

rm -rf site
mkdir -p site

if command -v httrack >/dev/null 2>&1; then
  echo "[clone] usando httrack"
  httrack "https://policies.google.com/terms" \
    -O site -n -r2 -c6 -A5000000 -%v --robots=0
else
  echo "[clone] httrack no disponible, usando wget"
  (
    cd site
    wget --mirror --page-requisites --convert-links --adjust-extension \
      --span-hosts --domains=policies.google.com,www.gstatic.com,ssl.gstatic.com,fonts.gstatic.com \
      --reject 'archive*,*.pdf' --level=2 \
      -e robots=off -U "$UA" \
      "https://policies.google.com/terms"
  )
fi

echo
echo "clon generado en site/  (página principal: site/policies.google.com/terms.html)"
echo "para servirlo: ./up.sh  (previa ./setup.sh)"
