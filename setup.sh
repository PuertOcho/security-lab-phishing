#!/usr/bin/env bash
# One-time lab setup: local CA + trust stores + TLS certificate.
# Safe to re-run; every step is idempotent.
set -euo pipefail
cd "$(dirname "$0")"

MKCERT_VERSION="v1.4.4"
case "$(uname -m)" in
  x86_64)  MKCERT_ARCH="linux-amd64" ;;
  aarch64) MKCERT_ARCH="linux-arm64" ;;
  *) echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac

mkdir -p bin certs

# 1. mkcert binary: use the one on PATH, else the pinned copy in bin/
if command -v mkcert >/dev/null; then
  MKCERT=mkcert
else
  if [ ! -x bin/mkcert ]; then
    echo "downloading mkcert ${MKCERT_VERSION}..."
    curl -fsSL -o bin/mkcert \
      "https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-${MKCERT_ARCH}"
    chmod +x bin/mkcert
  fi
  MKCERT="$PWD/bin/mkcert"
fi

# 2. Browser trust: mkcert needs certutil (libnss3-tools) for Firefox/Chrome.
if ! command -v certutil >/dev/null; then
  echo "note: 'certutil' not found — for Firefox/Chrome trust install:"
  echo "      sudo apt-get install -y libnss3-tools"
fi

# 3. Install the local CA into the system and browser trust stores (sudo).
#    This is the step that makes browsers show the padlock.
"$MKCERT" -install

# 4. Mint the server certificate: localhost + LAN IP + lookalike domain +
#    the REAL domain (for the DNS-hijack scenario). mkcert signs any name
#    because it's your own CA; the padlock only shows on devices where that
#    CA is installed.
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"
"$MKCERT" -cert-file certs/server.pem -key-file certs/server.key \
  localhost 127.0.0.1 \
  policies.google.lab www.policies.google.lab \
  policies.google.com www.policies.google.com \
  ${LAN_IP:-}

# 5. Hosts entry so the URL shows a domain instead of an IP.
#    The lookalike goes to loopback; the REAL domain goes to the LAN IP so
#    that this machine (and any test machine with this /etc/hosts line) hits
#    the clone on port 443 instead of Google's real servers.
if ! grep -q "policies\\.google\\.lab" /etc/hosts 2>/dev/null; then
  echo "adding '127.0.0.1 policies.google.lab' to /etc/hosts (sudo)..."
  echo "127.0.0.1 policies.google.lab" | sudo tee -a /etc/hosts >/dev/null
fi
if ! grep -q "policies\\.google\\.com" /etc/hosts 2>/dev/null; then
  echo "adding '${LAN_IP} policies.google.com www.policies.google.com' to /etc/hosts (sudo)..."
  echo "${LAN_IP} policies.google.com www.policies.google.com" | sudo tee -a /etc/hosts >/dev/null
fi

# 6. Build the cloned site if it is not present yet.
if [ ! -f site/policies.google.com/terms.html ]; then
  echo "site/ not found — generating the clone..."
  ./clone.sh
fi

echo
echo "setup complete — start the lab with:  ./up.sh"
