# pfSense Tailscale Autoupdater 🚀

Este script automatiza la actualización de **Tailscale** en sistemas **pfSense** (basados en FreeBSD). 

Debido a que los paquetes oficiales de pfSense a veces van por detrás de las versiones estables de FreeBSD, este script permite obtener la última versión directamente desde los repositorios de FreeBSD, gestionando dependencias, servicios y notificaciones nativas en la interfaz de pfSense.

## ✨ Características

* **Detección Dinámica:** Identifica automáticamente tu versión de FreeBSD ($FREEBSD_VER) y arquitectura ($ARCH).
* **Comparación Semántica:** Solo actualiza si la versión del repositorio es superior a la instalada (evita downgrades).
* **Robustez:** Incluye reintentos de red, control de concurrencia (locking) y manejo de errores.
* **Limpieza Automática:** Gestión de directorios temporales y rotación de logs para no saturar el almacenamiento.
* **Integración con pfSense:** * Envía notificaciones nativas a la "campana" del GUI de pfSense.
    * Registra la instalación en la base de datos de paquetes local.
    * Ejecuta scripts de post-inicio personalizados (`tailscale-updater.sh`).

## 🚀 Instalación rápida

1.  **Accede a tu pfSense vía SSH** (opción 8 - Shell).
2.  **Descarga el script** (o créalo manualmente):
    ```bash
    fetch -o /root/tailscale-updater.sh [https://raw.githubusercontent.com/TU_USUARIO/TU_REPO/main/tailscale-updater.sh](https://raw.githubusercontent.com/TU_USUARIO/TU_REPO/main/tailscale-updater.sh)
    ```
3.  **Dale permisos de ejecución:**
    ```bash
    chmod +x /root/tailscale-updater.sh
    ```

## 🛠️ Uso manual

Simplemente ejecuta el script como root:
```bash
/root/tailscale-updater.sh
```

## 📅 Automatización Diaria (Cron)

Para asegurar que Tailscale esté siempre en la última versión sin intervención manual, se recomienda programar el script para que se ejecute cada 24 horas (por ejemplo, a las 04:00 AM).

### Opción A: Usando el paquete Cron (Recomendado)
Es la forma más segura y visual en pfSense. Si no lo tienes, instálalo en **System > Package Manager**.

1. Ve a **Services > Cron**.
2. Haz clic en el botón **+ Add**.
3. Configura los siguientes parámetros para una ejecución diaria:
   - **Minute:** `0`
   - **Hour:** `4`
   - **Day of Month:** `*`
   - **Month:** `*`
   - **Day of Week:** `*`
   - **User:** `root`
   - **Command:** `/root/update_tailscale.sh`
4. Haz clic en **Save**.

### Opción B: Vía Shell (Instalación rápida)
Si prefieres no usar la interfaz web, puedes añadir la tarea directamente al crontab del sistema ejecutando este comando desde el Shell (Opción 8):

```bash
echo "0 4 * * * root /bin/sh /root/update_tailscale.sh" >> /etc/crontab
```

