#!/usr/bin/env python3
"""
Local site-cloning awareness lab server (Docker-friendly).

Serves a real 1:1 clone of a public page (by default Google's Terms of
Service, cloned from https://policies.google.com/terms) from the ./site
directory, over HTTPS with a certificate signed by YOUR local CA. The
browser shows a valid padlock because that CA is installed in the trust
store of your own machine — which is the whole lesson: the padlock proves
the connection is encrypted to a server your device trusts, NOT that the
site is the real one.

Authorized use only:
  - Run it only inside a network you own, against test machines you control.
  - This is a training clone: never repoint traffic from machines or users
    you do not control, and never expose this server to the public internet.

Usage:
  python3 server.py [port]        # 8443 when certs exist, 8080 otherwise
Environment:
  LAB_HOST           bind address (default 127.0.0.1)
  LAB_CERT, LAB_KEY  TLS cert/key files (HTTPS when both exist)
  LAB_SITE_DIR       directory holding the cloned site (default ./site)
  LAB_REDIRECT_URL   if set, GET / issues a 302 here instead of serving the
                     clone (realistic "harvester" mode: the visitor is sent
                     to the real page and never sees the clone)
"""
import datetime
import http.server
import mimetypes
import os
import socketserver
import ssl
import sys
import urllib.parse

# Bind to loopback by default so the lab never leaves this machine.
# Override with LAB_HOST=0.0.0.0 only for a deliberate LAN test.
HOST = os.environ.get("LAB_HOST", "127.0.0.1")
DEFAULT_PORT = 8080

SITE_DIR = os.environ.get("LAB_SITE_DIR", "site")
# Path (inside SITE_DIR) of the cloned page to serve as the root.
LANDING_PAGE = "policies.google.com/terms.html"

# If both files exist, the server serves over HTTPS. Generate them with mkcert
# so the local CA is trusted and the browser shows a valid padlock.
CERT_FILE = os.environ.get("LAB_CERT", "cert.pem")
KEY_FILE = os.environ.get("LAB_KEY", "key.pem")

# When set, GET / returns a 302 to this URL instead of the clone (harvester
# mode). When empty, the lab serves the clone itself.
REDIRECT_URL = os.environ.get("LAB_REDIRECT_URL", "")

# Injected into every served HTML page so the lab operator (and any test
# "victim") can tell at a glance this is the clone, not the real page.
# Set LAB_BANNER=0 to disable (e.g. for a blind harvester test).
BANNER_ENABLED = os.environ.get("LAB_BANNER", "1") != "0"

BANNER_HTML = (
    "<div style=\"position:fixed;top:0;left:0;right:0;z-index:2147483647;"
    "background:#b91c1c;color:#fff;font:600 14px/1.4 system-ui,Arial,sans-serif;"
    "text-align:center;padding:8px 16px;\">"
    "&#9888; CLON DE LABORATORIO &mdash; p&aacute;gina clonada con fines educativos, "
    "NO es policies.google.com real</div>"
)

# Request log (one line per GET) — keeps a local record of what was fetched.
ACCESS_LOG = "access.log"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if REDIRECT_URL and self.path in ("/", "/index.html"):
            self.send_response(302)
            self.send_header("Location", REDIRECT_URL)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self._log(f"302 -> {REDIRECT_URL}")
            return

        target = self._resolve_path(self.path)
        if target is None:
            self.send_error(404, "Not Found")
            self._log("404")
            return

        ctype = mimetypes.guess_type(target)[0] or "application/octet-stream"
        is_html = ctype == "text/html"
        # The cloned files are UTF-8. Declaring the charset is what keeps
        # UTF-8 punctuation (e.g. the right single quote ’ in "What’s")
        # from being misdecoded as Windows-1252 into mojibake like "â€™".
        if ctype.startswith("text/") or ctype in ("application/javascript",
                                                  "application/json",
                                                  "application/xml"):
            ctype += "; charset=utf-8"
        try:
            with open(target, "rb") as fh:
                data = fh.read()
        except OSError:
            self.send_error(404, "Not Found")
            self._log("404")
            return

        # Inject the lab banner into HTML pages so the clone is unmistakable.
        if BANNER_ENABLED and is_html:
            data = self._inject_banner(data)

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self._log(f"200 {ctype}")

    def _inject_banner(self, data):
        """Insert the clone banner right after <body ...> (or prepend)."""
        banner = BANNER_HTML.encode("utf-8")
        lower = data.lower()
        idx = lower.find(b"<body")
        if idx != -1:
            close = lower.find(b">", idx)
            if close != -1:
                return data[: close + 1] + banner + data[close + 1 :]
        return banner + data

    def _resolve_path(self, raw_path):
        """Map a request path to a file under SITE_DIR, or None.

        The clone is laid out by domain (wget --mirror): the landing page
        lives at SITE_DIR/policies.google.com/terms.html and its assets are
        referenced with paths like /www.gstatic.com/... so we serve SITE_DIR
        as the document root and alias the root URL to the landing page.
        """
        path, _, query = raw_path.partition("?")
        path = urllib.parse.unquote(path)

        if path in ("/", "/index.html", "/terms", "/terms.html"):
            candidate = os.path.join(SITE_DIR, LANDING_PAGE)
            return candidate if os.path.isfile(candidate) else None

        # Strip a leading slash and resolve relative to SITE_DIR.
        rel = path.lstrip("/") or LANDING_PAGE
        candidate = os.path.join(SITE_DIR, rel)

        # wget --adjust-extension names query-variant files literally with a
        # '?' in the filename (e.g. "index.html?lfhs=2.html"). Fall back to
        # that literal form when the plain path is missing.
        if os.path.isfile(candidate):
            return candidate
        if query and os.path.isfile(candidate + "?" + query):
            return candidate + "?" + query
        # Directory -> index.html
        if os.path.isdir(candidate):
            idx = os.path.join(candidate, "index.html")
            if os.path.isfile(idx):
                return idx
        return None

    def _log(self, what):
        stamp = datetime.datetime.now().isoformat(timespec="seconds")
        line = f"{stamp}\t{self.client_address[0]}\t{self.path}\t{what}\n"
        with open(ACCESS_LOG, "a", encoding="utf-8") as fh:
            fh.write(line)
        print(f"[GET] {self.path} -> {what}", flush=True)

    def log_message(self, *args):
        pass  # Silence default request logging; our own _log is explicit.


def main():
    tls = os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE)
    default_port = 8443 if tls else DEFAULT_PORT
    port = int(sys.argv[1]) if len(sys.argv) > 1 else default_port

    if not os.path.isdir(SITE_DIR):
        print(f"error: {SITE_DIR}/ not found — run ./clone.sh first", file=sys.stderr)
        sys.exit(1)

    socketserver.ThreadingTCPServer.allow_reuse_address = True
    httpd = socketserver.ThreadingTCPServer((HOST, port), Handler)
    scheme = "http"
    if tls:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    with httpd:
        print(f"Lab clone serving on {scheme}://{HOST}:{port}  (Ctrl+C to stop)")
        print(f"Cloned site root: ./{SITE_DIR}")
        print(f"Requests are appended to ./{ACCESS_LOG}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
