#!/bin/sh
# Versión 3.4 - Corrección definitiva de detección de versión vs binario.

set -e
set -u

# ---------------------------------------------
# Configuración
# ---------------------------------------------
LOCK_FILE="/var/run/tailscale_update.lock"
LOG_FILE="/var/log/tailscale_update.log"
PKG_NAME="tailscale"

# ---------------------------------------------
# Funciones
# ---------------------------------------------
log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

send_pfsense_notice() {
    local notice_msg="$*"
    clean_msg=$(echo "$notice_msg" | tr 'áéíóúÁÉÍÓÚñÑ' 'aeiouAEIOUnN')
    /usr/local/bin/php -q <<EOF
<?php
require_once("notices.inc");
file_notice("TailscaleUpdate", "$clean_msg", "Tailscale Update System", "index.php");
?>
EOF
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
    if [ "$OLDPID" -ne 0 ] && kill -0 "$OLDPID" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCK_FILE"
trap cleanup EXIT INT TERM

# ---------------------------------------------
# Detección de Versiones
# ---------------------------------------------
FREEBSD_VER=$(uname -r | cut -d'-' -f1 | cut -d'.' -f1)
ARCH=$(uname -m)
REPO_BASE="https://pkg.freebsd.org/FreeBSD:${FREEBSD_VER}:${ARCH}/latest"
DB_URL="${REPO_BASE}/packagesite.pkg"

if pkg-static info "$PKG_NAME" >/dev/null 2>&1; then
    CURRENT_VER=$(pkg-static info "$PKG_NAME" | awk '/Version/ {print $3}')
else
    CURRENT_VER="0"
fi

WORKDIR=$(mktemp -d -t tailscale_upd_XXXXXX)
fetch -q -o "${WORKDIR}/packagesite.pkg" "$DB_URL" || exit 1

RAW_DATA=$(tar -xf "${WORKDIR}/packagesite.pkg" -O 2>/dev/null | grep -m 1 "\"name\":\"${PKG_NAME}\"")
LATEST_PATH=$(echo "$RAW_DATA" | sed -e 's/.*"path":"\([^"]*\)".*/\1/' -e 's/".*//')

# --- MEJORA CRÍTICA AQUÍ ---
# Extraemos la versión real del nombre del archivo (ej: tailscale-1.96.4~hash.pkg -> 1.96.4)
# Buscamos el patrón entre el guion '-' y el símbolo '~' o '.pkg'
REAL_LATEST_VER=$(echo "$LATEST_PATH" | sed -n 's/.*tailscale-\([^~]*\).*/\1/p' | cut -d'.' -f1-3)

log "Versión instalada: $CURRENT_VER | Versión en repo: $REAL_LATEST_VER"

# Comparación basada en la versión real del binario
VER_CHECK=$(pkg-static version -t "$CURRENT_VER" "$REAL_LATEST_VER")

if [ "$VER_CHECK" != "<" ]; then
    log "Sistema al día. No se requiere acción."
    exit 0
fi

log "¡Nueva versión real detectada! Actualizando a $REAL_LATEST_VER..."

# ---------------------------------------------
# Proceso de Instalación
# ---------------------------------------------
PKG_URL="${REPO_BASE}/${LATEST_PATH}"
PKG_FILE="${WORKDIR}/update.pkg"

fetch -q -o "$PKG_FILE" "$PKG_URL"

export IGNORE_OSVERSION=yes
if pkg-static add -f "$PKG_FILE"; then
    service tailscaled restart >/dev/null 2>&1 || service tailscaled start >/dev/null 2>&1
    NEW_VER_STR=$(tailscale version | head -n 1)
    log "Actualización completada con éxito: $NEW_VER_STR"
    send_pfsense_notice "Tailscale actualizado a la version $REAL_LATEST_VER."
else
    log "Error en la instalación."
fi

[ -f "/root/tailscale_start.sh" ] && /bin/sh /root/tailscale_start.sh
