# Laboratorio de clonado de páginas con candado HTTPS (solo red propia)

Clon educativo 1:1 de una página pública real — por defecto los **Términos de
Servicio de Google** (`https://policies.google.com/terms`) — dockerizado y
servido con HTTPS de verdad: el navegador muestra el **candado** porque tu
propia CA local está instalada en el almacén de confianza de tu equipo. Sirve
para entender de primera mano que **cualquier página pública se puede clonar
tal cual**, y qué significa realmente ese candado.

> **Reglas del laboratorio**: red y dispositivos propios. Nunca lo expongas a
> internet ni lo uses con máquinas o personas que no controles. El dominio
> `policies.google.lab` es falso a propósito — nunca repuntes el dominio real.

## Qué demuestra este laboratorio

1. **Una página se puede clonar.** Con `httrack` o `wget` se descarga el HTML,
   CSS, JS e imágenes de una página pública y se reescriben los enlaces para
   que la copia se navegue offline. El clon queda en `site/`.
2. **Qué se puede clonar lo decide el robots.txt del objetivo** (y su
   protección anti-bot). `policies.google.com` no publica `robots.txt`
   (404) → sin restricciones → clonable. Otras webs (ej. pccomponentes.com)
   están tras Cloudflare Turnstile y devuelven 403 a cualquier cliente
   no-humano, clon o navegador headless incluido.
3. **El candado no certifica que el sitio sea legítimo.** Solo que la
   conexión va cifrada hacia un servidor cuya CA confía tu dispositivo.

## Ruta rápida

1. `./setup.sh` — **una sola vez** (pide sudo): crea la CA local, la instala en
   tu sistema y navegadores, genera el certificado, añade
   `127.0.0.1 policies.google.lab` a `/etc/hosts` y genera el clon si falta.
2. `./up.sh` — **el comando de siempre**: levanta Docker, verifica el TLS y te
   imprime las URLs.
3. Abre `https://policies.google.lab:8443` (o `https://localhost:8443`) →
   verás la página de términos de Google con **candado** y un **banner rojo
   "CLON DE LABORATORIO"** arriba que la delata.
4. Para regenerar solo el clon (sin tocar certificados): `./clone.sh`.

```bash
tail -f access.log        # ver peticiones en vivo
docker compose down       # parar el laboratorio
```

## Cómo se clona una página (la técnica)

El script `clone.sh` encapsula el proceso. Dos herramientas equivalentes:

```bash
# httrack (clonador clásico; apt install httrack)
httrack "https://policies.google.com/terms" -O site -n -r2 -c6 -A5000000

# wget (ya instalado en casi cualquier sistema)
wget --mirror --page-requisites --convert-links --adjust-extension \
  --span-hosts --domains=policies.google.com,www.gstatic.com,ssl.gstatic.com,fonts.gstatic.com \
  --reject 'archive*,*.pdf' --level=2 -e robots=off \
  "https://policies.google.com/terms"
```

Detalles importantes que `clone.sh` ya tiene en cuenta:

| Detalle | Por qué |
|---|---|
| `--domains=...gstatic.com` | La página carga CSS/JS/imágenes de `www.gstatic.com`, `ssl.gstatic.com` y fuentes de `fonts.gstatic.com`. Sin `--span-hosts` el clon se ve sin estilo. |
| `--page-requisites` | Captura los recursos que la página necesita para renderizarse (no solo el HTML). |
| `--convert-links` | Reescribe los enlaces para que la copia local funcione offline. |
| `--reject 'archive*,*.pdf'` | Evita bajar el histórico de versiones y PDFs (decenas de MB). |
| `-e robots=off` | Aquí es inocuo (no hay robots.txt), pero en general respeta robots.txt salvo autorización expresa. |

**Cómo saber si una página es clonable** (comprobación previa):

```bash
curl -sI https://<dominio>/robots.txt      # 404 = sin restricciones
curl -sI https://<dominio>/                # 200 = accesible; 403 = anti-bot (Cloudflare...)
```

## Piezas

| Pieza | Qué hace |
|---|---|
| `clone.sh` | Genera el clon en `site/` (httrack o wget, según disponibilidad) |
| `dns.sh` | DNS hijack del dominio real: `dnsmasq` que resuelve `policies.google.com` → tu IP LAN (up/down/status) |
| `setup.sh` | Una vez: CA local (mkcert), instalación en almacén de confianza, certificado para `localhost`, tu IP de LAN, `policies.google.lab` y `policies.google.com` |
| `up.sh` | El comando único: `docker compose up -d --build` + verificación TLS con la CA |
| `compose.yaml` | Publica 8443→8443; monta certificados, `site/` y `access.log` |
| `server.py` | Servidor Python stdlib (sin dependencias): sirve el clon estático de `site/`, inyecta un banner rojo "CLON DE LABORATORIO" en cada HTML (desactivable con `LAB_BANNER=0`) y registra cada petición en `access.log` |
| `site/` | El clon (ignorado por git; se regenera con `clone.sh`) |
| `certs/` | Certificado TLS firmado por tu CA local (ignorado por git) |
| `access.log` | Registro de peticiones: timestamp, IP origen y ruta (ignorado por git) |

## Por qué aparece el candado (LA lección)

El candado **no** certifica que el sitio sea legítimo. Certifica dos cosas:

1. La conexión va cifrada (TLS).
2. El certificado del servidor encadena a una **CA en la que TU dispositivo
   confía**.

Quien controla el almacén de CAs de un dispositivo controla qué páginas ven el
candado. Aquí aparece porque `./setup.sh` instaló tu CA en tu máquina. Eso
mismo pasa en el mundo real:

- Las empresas descifran el tráfico TLS de sus empleados con su propia CA
  corporativa (proxies Zscaler, Fortinet...): los usuarios ven el candado.
- El malware puede instalar una CA raíz en tu sistema.

**El experimento clave**: abre `https://192.168.1.88:8443` desde el móvil.
Verás un error de certificado: la CA no está instalada ahí. Ese aviso **es TLS
funcionando** — verifica identidad, no solo cifra. Si instalas la CA en el
móvil (`rootCA.pem`, de `mkcert -CAROOT`), el candado aparece. El candado
obedece al almacén de CAs del dispositivo, no a la honestidad del sitio.

## Modo redirect (harvester realista)

Por defecto se sirve el clon (modo formación: ves la página clonada). Para el
modo realista — la víctima es redirigida al sitio real sin ver el clon —
descomenta en `compose.yaml`:

```yaml
      LAB_REDIRECT_URL: https://policies.google.com/terms
```

y relanza `./up.sh`. Toda petición a `/` recibe un 302 al sitio real.

## Redirigir el dominio REAL con DNS (hijack dentro de tu LAN)

El mecanismo anterior sirve el clon en un dominio falso (`policies.google.lab`).
Para el escenario más realista — la víctima escribe `https://policies.google.com/terms`
y aun así ve el clon — manipulas el DNS de tu propia red:

1. El clon escucha en el puerto **443** de la IP LAN (bind en `compose.yaml`), con
   un certificado que incluye el dominio real `policies.google.com` (mkcert firma
   cualquier dominio porque es TU CA).
2. `./dns.sh up` levanta un `dnsmasq` en esta máquina que resuelve
   `policies.google.com` → tu IP LAN.
3. El dispositivo de prueba debe usar esta máquina como su DNS (o el DHCP de tu
   router debe repartir tu IP como resolver).

```bash
./dns.sh up          # dnsmasq: policies.google.com -> tu IP LAN (pide sudo)
./dns.sh status      # ver si está activo
./dns.sh down        # pararlo
```

En el dispositivo de prueba: abre `https://policies.google.com/terms` → verás el
clon (y el candado, si le instalaste tu CA). Fuera de tu red el dominio sigue
resolviendo a Google; el hijack solo existe donde tu dnsmasq es el resolver.

> Regla de oro: esto es solo para una red y dispositivos que controles. Manipular
> el DNS de `policies.google.com` en una red ajena es un ataque real.

## Llevarlo a otras máquinas de tu LAN

- **Con URL de IP**: `https://192.168.1.250:8443` desde cualquier dispositivo
  (el certificado incluye la IP). Para el candado, ese dispositivo necesita
  tu CA instalada — ese es el experimento.
- **Con dominio en una máquina de pruebas**: añade en SU `/etc/hosts`
  `192.168.1.250  policies.google.lab`.
- **Toda la LAN de pruebas (dominio falso)**: `dnsmasq` con
  `address=/policies.google.lab/192.168.1.250` como resolver de la LAN.
- **Dominio REAL en toda la LAN (hijack)**: `./dns.sh up` — ver sección anterior.

## Pistas defensivas (qué mirar, no solo el candado)

- [ ] **Dominio exacto** en la URL: `policies.google.lab` ≠ `policies.google.com`
- [ ] **Emisor del certificado**: clic en el candado → certificado →
  "Emitido por". Aquí pone "mkcert"; en la web real, una CA pública.
- [ ] **Pestaña Network** (F12): peticiones a IPs o dominios que no pegan con
  el sitio.
- [ ] **Cómo llegaste**: enlace de email/SMS/WhatsApp → sospecha siempre;
  navega al sitio a mano o desde tu marcador.

## Desmontar todo

```bash
docker compose down                     # parar el clon
sudo sed -i '/policies.google.lab/d' /etc/hosts
bin/mkcert -uninstall                   # retirar la CA del sistema y navegadores
# borrar el proyecto cuando termines: sin su CA, los certificados no sirven
```

## Problemas típicos

| Síntoma | Causa y solución |
|---|---|
| El candado no aparece | Falta `./setup.sh` (CA sin instalar), o navegaste por un nombre/IP que no está en el certificado — relanza `./setup.sh` |
| La página se ve sin estilo | El clon no capturó los assets de `gstatic.com` — relanza `./clone.sh` |
| Firefox no confía | Importa `rootCA.pem` a mano, o instala `sudo apt-get install -y libnss3-tools` y relanza `./setup.sh` |
| Chromium (snap) no confía | El snap tiene su propio almacén NSS (no lee `~/.pki/nssdb`): `certutil -A -n mkcert-hermes -t "C,," -d sql:$HOME/snap/chromium/current/.pki/nssdb -i "$(bin/mkcert -CAROOT)/rootCA.pem"`. Repite tras cada `snap refresh chromium` |
| `access.log` no crece | ¿Borraste el archivo? Docker necesita que exista: `touch access.log` antes de `./up.sh` (up.sh ya lo hace) |
| La IP registrada es `172.x.x.x` | Pruebas desde la propia máquina: Docker NAT-ifica la conexión. Desde otro dispositivo de la LAN verás su IP real |
| Cambió tu IP de LAN | Relanza `./setup.sh` (regenera el certificado con la IP nueva) |
| 403 Forbidden al clonar | El objetivo tiene anti-bot (Cloudflare). Elige una página cuyo `robots.txt` permita rastreo o que no esté tras WAF |
