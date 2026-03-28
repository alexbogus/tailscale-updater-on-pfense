#!/bin/sh
# Versión 3.1 - Mejoras: Notificaciones nativas en el GUI de pfSense.

set -e
set -u

# ---------------------------------------------
# Configuración
# ---------------------------------------------
LOCK_FILE="/var/run/tailscale_update.lock"
LOG_FILE="/var/log/tailscale_update.log"
PKG_NAME="tailscale"
MAX_RETRIES=3

# ---------------------------------------------
# Funciones
# ---------------------------------------------
log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
    # Rotar log: mantener últimas 1000 líneas
    if [ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt 1500 ]; then
        tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

send_pfsense_notice() {
    local notice_msg="$*"
    # Disparar notificación nativa en el GUI de pfSense vía PHP
    /usr/local/bin/php -q <<EOF
<?php
require_once("notices.inc");
file_notice("TailscaleUpdate", "$notice_msg", "Tailscale Update System", "index.php");
?>
EOF
}

error_exit() {
    log "ERROR: $*"
    # También notificamos errores críticos en el GUI
    send_pfsense_notice "Error crítico en actualización de Tailscale: $*"
    exit 1
}

cleanup() {
    [ -d "${WORKDIR:-}" ] && rm -rf "$WORKDIR"
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# ---------------------------------------------
# Control de Concurrencia
# ---------------------------------------------
if [ -f "$LOCK_FILE" ]; then
    OLDPID=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
    if kill -0 "$OLDPID" 2>/dev/null; then
        error_exit "Script ya en ejecución (PID $OLDPID)."
    fi
fi
echo $$ > "$LOCK_FILE"
trap cleanup EXIT INT TERM

# ---------------------------------------------
# Validaciones e Identificación
# ---------------------------------------------
[ "$(id -u)" -ne 0 ] && error_exit "Se requiere root."

# Detección dinámica de versión y arquitectura
FREEBSD_VER=$(uname -r | cut -d'-' -f1 | cut -d'.' -f1)
ARCH=$(uname -m)
REPO_BASE="https://pkg.freebsd.org/FreeBSD:${FREEBSD_VER}:${ARCH}/latest"
DB_URL="${REPO_BASE}/packagesite.pkg"

log "--- Iniciando ciclo (FreeBSD $FREEBSD_VER $ARCH) ---"

# ---------------------------------------------
# Detección de Versiones
# ---------------------------------------------
if pkg-static info "$PKG_NAME" >/dev/null 2>&1; then
    CURRENT_VER=$(pkg-static info "$PKG_NAME" | awk '/Version/ {print $3}')
else
    CURRENT_VER="0"
fi

WORKDIR=$(mktemp -d -t tailscale_upd_XXXXXX)

# Descarga del índice con reintentos
log "Consultando repositorio remoto..."
success=0
for i in $(seq 1 $MAX_RETRIES); do
    if fetch -m -q -o "${WORKDIR}/packagesite.pkg" "$DB_URL"; then
        success=1 && break
    fi
    log "Reintento de conexión $i/$MAX_RETRIES..."
    sleep 3
done
[ $success -eq 0 ] && error_exit "Fallo de red persistente al conectar con FreeBSD Repo."

# Parseo de datos del paquete
RAW_DATA=$(tar -xf "${WORKDIR}/packagesite.pkg" -O 2>/dev/null | grep -m 1 "\"name\":\"${PKG_NAME}\"")
[ -z "$RAW_DATA" ] && error_exit "No se encontró el paquete $PKG_NAME en el repositorio."

LATEST_VER=$(echo "$RAW_DATA" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
LATEST_PATH=$(echo "$RAW_DATA" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')

# Comparación semántica
VER_CHECK=$(pkg-static version -t "$CURRENT_VER" "$LATEST_VER")

if [ "$VER_CHECK" = "=" ] || [ "$VER_CHECK" = ">" ]; then
    log "Sistema al día ($CURRENT_VER). Saliendo."
    exit 0
fi

log "Nueva versión detectada: $LATEST_VER (Actual instalada: $CURRENT_VER)"

# ---------------------------------------------
# Proceso de Instalación
# ---------------------------------------------
PKG_URL="${REPO_BASE}/${LATEST_PATH}"
PKG_FILE="${WORKDIR}/$(basename "$LATEST_PATH")"

log "Descargando paquete..."
fetch -q -o "$PKG_FILE" "$PKG_URL" || error_exit "Error descargando el archivo .pkg"

log "Instalando (IGNORE_OSVERSION)..."
export IGNORE_OSVERSION=yes
if ! pkg-static add -f "$PKG_FILE"; then
    error_exit "La instalación del paquete falló."
fi

# ---------------------------------------------
# Finalización y Notificación
# ---------------------------------------------
pkg-static update -f >/dev/null 2>&1 || true
sysrc tailscaled_enable="YES" >/dev/null

if service tailscaled onestatus >/dev/null 2>&1; then
    service tailscaled restart >/dev/null
else
    service tailscaled start >/dev/null
fi

# Verificación final
if tailscale version >/dev/null 2>&1; then
    NEW_VER_STR=$(tailscale version | head -n 1)
    log "Actualización completada: $NEW_VER_STR"
    # NOTIFICACIÓN GUI
    send_pfsense_notice "Tailscale se ha actualizado con éxito a la versión $LATEST_VER ($NEW_VER_STR)."
else
    error_exit "El paquete se instaló pero el binario no responde."
fi

[ -f "/root/tailscale_start.sh" ] && /bin/sh /root/tailscale_start.sh

log "Script finalizado."
