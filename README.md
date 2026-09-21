# Laboratorio de phishing con candado HTTPS (solo red propia)

Clon educativo de una página de login estilo PCComponentes, dockerizado, servido
con HTTPS de verdad: el navegador muestra el **candado** porque tu propia CA
local está instalada en el almacén de confianza de tu equipo. Sirve para
entender de primera mano cómo se capturan credenciales y qué significa
realmente ese candado.

> **Reglas del laboratorio**: red y dispositivos propios. Nunca lo expongas a
> internet ni lo uses con máquinas o personas que no controles. El dominio
> `pccomponentes.lab` es falso a propósito — nunca repuntes el dominio real.

## Ruta rápida

1. `./setup.sh` — **una sola vez** (pide sudo): crea la CA local, la instala en
   tu sistema y navegadores, genera el certificado y añade
   `127.0.0.1 pccomponentes.lab` a `/etc/hosts`.
2. `./up.sh` — **el comando de siempre**: levanta Docker, verifica el TLS y te
   imprime las URLs.
3. Abre `https://pccomponentes.lab` (o `https://localhost:8443`) → **candado**.
4. Escribe un email y contraseña cualquiera → página "has caído" y la credencial
   queda en `captured.log`.

```bash
tail -f captured.log      # ver capturas en vivo
docker compose down       # parar el laboratorio
```

## Piezas

| Pieza | Qué hace |
|---|---|
| `setup.sh` | Una vez: CA local (mkcert), instalación en almacén de confianza, certificado para `localhost`, tu IP de LAN y `pccomponentes.lab` |
| `up.sh` | El comando único: `docker compose up -d --build` + verificación TLS con la CA |
| `compose.yaml` | Publica 443→8443 (URL limpia) y 8443→8443; monta certificados y `captured.log` |
| `server.py` | Servidor Python stdlib (sin dependencias): sirve el clon, registra credenciales y muestra página reveal o redirige |
| `certs/` | Certificado TLS firmado por tu CA local (ignorado por git) |
| `captured.log` | Credenciales capturadas: timestamp, IP origen, email y contraseña (ignorado por git) |

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

## Qué registra el servidor vs qué ve la víctima

| Servidor (tú) | Víctima |
|---|---|
| El POST llega **descifrado para él** aunque todo sea HTTPS | Ve candado + página creíble |
| `email`, `password`, IP origen y timestamp en `captured.log` | En modo redirect: ni se entera (302 al sitio real) |

HTTPS cifra el **canal**, no la honestidad del **extremo**. El atacante ES el
destino: para él tu contraseña llega en claro. Por eso el phishing no necesita
"romper" la criptografía — solo necesita que escribas tu contraseña en el
sitio equivocado.

## Modo redirect (harvester realista)

Por defecto, tras capturar se muestra la página reveal (modo formación).
Descomenta en `compose.yaml`:

```yaml
      LAB_REDIRECT_URL: https://www.pccomponentes.com/
```

y relanza `./up.sh`: la víctima es redirigida al sitio real tras la captura —
parece que "la sesión caducó y volvió a cargar". Así operan los harvesters
reales.

## Llevarlo a otras máquinas de tu LAN

- **Con URL de IP**: `https://192.168.1.88:8443` desde cualquier dispositivo
  (el certificado incluye la IP). Para el candado, ese dispositivo necesita
  tu CA instalada — ese es el experimento.
- **Con dominio en una máquina de pruebas**: añade en SU `/etc/hosts`
  `192.168.1.88  pccomponentes.lab`.
- **Toda la LAN de pruebas**: `dnsmasq` con
  `address=/pccomponentes.lab/192.168.1.88` como resolver de la LAN.

## Pistas defensivas (qué mirar, no solo el candado)

- [ ] **Dominio exacto** en la URL: `pccomponentes.lab` ≠ `pccomponentes.com`
- [ ] **Emisor del certificado**: clic en el candado → certificado →
  "Emitido por". Aquí pone "mkcert"; en la web real, una CA pública
  (Sectigo, DigiCert...).
- [ ] **Pestaña Network** (F12): peticiones a IPs o dominios que no pegan con
  el sitio.
- [ ] **Cómo llegaste**: enlace de email/SMS/WhatsApp → sospecha siempre;
  navega al sitio a mano o desde tu marcador.
- [ ] **Passkeys / FIDO2**: una passkey se vincula al dominio real (origin
  binding de WebAuthn) — en un clon como este no funciona. Es la defensa
  estructural frente al phishing; la contraseña es el eslabón débil.

## Desmontar todo

```bash
docker compose down                     # parar el clon
sudo sed -i '/pccomponentes.lab/d' /etc/hosts
bin/mkcert -uninstall                   # retirar la CA del sistema y navegadores
# borrar el proyecto cuando termines: sin su CA, los certificados no sirven
```

## Problemas típicos

| Síntoma | Causa y solución |
|---|---|
| El candado no aparece | Falta `./setup.sh` (CA sin instalar), o navegaste por un nombre/IP que no está en el certificado — relanza `./setup.sh` |
| Firefox no confía | Importa `rootCA.pem` a mano, o instala `sudo apt-get install -y libnss3-tools` y relanza `./setup.sh` |
| `captured.log` no crece | ¿Borraste el archivo? Docker necesita que exista: `touch captured.log` antes de `./up.sh` (up.sh ya lo hace) |
| La IP capturada es `172.x.x.x` | Pruebas desde la propia máquina: Docker NAT-ifica la conexión. Desde otro dispositivo de la LAN verás su IP real |
| Cambió tu IP de LAN | Relanza `./setup.sh` (regenera el certificado con la IP nueva) |
