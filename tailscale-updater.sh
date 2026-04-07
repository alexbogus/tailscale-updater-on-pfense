#!/bin/sh
# Versión 3.2 - Mejoras: Corrección de encodado, lógica de notificaciones y eficiencia.

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
    # Rotar log: mantener últimas 1000 líneas si supera las 1500
    if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt 1500 ]; then
        tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

send_pfsense_notice() {
    local notice_msg="$*"
    # Eliminamos acentos conflictivos para asegurar compatibilidad con el GUI de pfSense
    clean_msg=$(echo "$notice_msg" | tr 'áéíóúÁÉÍÓÚ' 'aeiouAEIOU')
    
    /usr/local/bin/php -q <<EOF
<?php
require_once("notices.inc");
// Usamos add_notice si queremos que persista o file_notice para el log general
file_notice("TailscaleUpdate", "$clean_msg", "Tailscale Update System", "index.php");
?>
EOF
}

error_exit() {
    log "ERROR: $*"
    send_pfsense_notice "Error critico en actualizacion de Tailscale: $*"
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
    if [ "$OLDPID" -ne 0 ] && kill -0 "$OLDPID" 2>/dev/null; then
        # Salida silenciosa si ya corre para no saturar logs
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap cleanup EXIT INT TERM

# ---------------------------------------------
# Validaciones e Identificación
# ---------------------------------------------
[ "$(id -u)" -ne 0 ] && error_exit "Se requiere root."

FREEBSD_VER=$(uname -r | cut -d'-' -f1 | cut -d'.' -f1)
ARCH=$(uname -m)
REPO_BASE="https://pkg.freebsd.org/FreeBSD:${FREEBSD_VER}:${ARCH}/latest"
DB_URL="${REPO_BASE}/packagesite.pkg"

# ---------------------------------------------
# Detección de Versiones
# ---------------------------------------------
if pkg-static info "$PKG_NAME" >/dev/null 2>&1; then
    CURRENT_VER=$(pkg-static info "$PKG_NAME" | awk '/Version/ {print $3}')
else
    CURRENT_VER="0"
fi

WORKDIR=$(mktemp -d -t tailscale_upd_XXXXXX)

# Descarga del índice
success=0
for i in $(seq 1 $MAX_RETRIES); do
    if fetch -m -q -o "${WORKDIR}/packagesite.pkg" "$DB_URL"; then
        success=1 && break
    fi
    sleep 3
done

[ $success -eq 0 ] && error_exit "Fallo de red al conectar con FreeBSD Repo."

# Extraer info del paquete
RAW_DATA=$(tar -xf "${WORKDIR}/packagesite.pkg" -O 2>/dev/null | grep -m 1 "\"name\":\"${PKG_NAME}\"")
[ -z "$RAW_DATA" ] && error_exit "No se encontro el paquete $PKG_NAME."

LATEST_VER=$(echo "$RAW_DATA" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
LATEST_PATH=$(echo "$RAW_DATA" | sed -n 's/.*"version":"'${LATEST_VER}'","path":"\([^"]*\)".*/\1/p')

# COMPARACIÓN CRÍTICA
VER_CHECK=$(pkg-static version -t "$CURRENT_VER" "$LATEST_VER")

if [ "$VER_CHECK" != "<" ]; then
    # Si la versión es igual (=) o la instalada es mayor (>), no hacemos nada.
    # No enviamos notificación al GUI para evitar el spam que ves en tu captura.
    cleanup
    exit 0
fi

log "Nueva version detectada: $LATEST_VER (Actual: $CURRENT_VER). Iniciando descarga..."

# ---------------------------------------------
# Proceso de Instalación
# ---------------------------------------------
PKG_URL="${REPO_BASE}/${LATEST_PATH}"
PKG_FILE="${WORKDIR}/$(basename "$LATEST_PATH")"

fetch -q -o "$PKG_FILE" "$PKG_URL" || error_exit "Error descargando el archivo .pkg"

export IGNORE_OSVERSION=yes
if ! pkg-static add -f "$PKG_FILE"; then
    error_exit "La instalacion del paquete fallo."
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

# Verificación final y ÚNICA notificación de éxito
if tailscale version >/dev/null 2>&1; then
    NEW_VER_STR=$(tailscale version | head -n 1)
    log "Actualizacion completada: $NEW_VER_STR"
    # Ahora sí notificamos al GUI porque hubo un cambio real
    send_pfsense_notice "Tailscale actualizado con exito a la version $LATEST_VER ($NEW_VER_STR)."
else
    error_exit "El binario no responde tras la instalacion."
fi

[ -f "/root/tailscale_start.sh" ] && /bin/sh /root/tailscale_start.sh
