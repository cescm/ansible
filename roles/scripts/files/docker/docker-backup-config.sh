#!/bin/bash
# docker-backup-config.sh — Whiptail TUI for Docker backup configuration
#
# Provides an interactive menu (whiptail) to:
#   1. Select which Docker services to back up
#   2. Configure backup path, retention, and compression settings
#   3. Run the backup immediately
#   4. View the last backup log
#
# Usage: ./docker-backup-config.sh [config-path]
#   Default config: /etc/docker-backup/docker-backup.conf
#
# Dependencies: whiptail, docker-backup.sh
# Language: Spanish UI (config values in English)

CONFIG="${1:-/etc/docker-backup/docker-backup.conf}"
BACKUP_SCRIPT="/usr/local/bin/docker-backup.sh"
SERVICES_DIR="/mnt/docker"
LOG_FILE="/var/log/docker-backup.log"
CONFIG_DIR=$(dirname "$CONFIG")

# Asegurar directorio de configuración
[[ -d "$CONFIG_DIR" ]] || mkdir -p "$CONFIG_DIR"

# Cargar configuración si existe
load_config() {
    [[ -f "$CONFIG" ]] && source "$CONFIG"
    BACKUP_DIR="${BACKUP_DIR:-/mnt/storage/backup/docker}"
    RETENTION_COUNT="${RETENTION_COUNT:-7}"
    RETENTION_DAYS="${RETENTION_DAYS:-30}"
    COMPRESSION="${COMPRESSION:-zstd}"
    SERVICE_FILTER="${SERVICE_FILTER:-}"
}
load_config

# Detectar servicios disponibles
detect_services() {
    SERVICES=()
    for d in "$SERVICES_DIR"/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        [[ -f "$d/.backup-skip" ]] && continue
        SERVICES+=("$name")
    done
    IFS=$'\n' SERVICES=($(sort <<<"${SERVICES[*]}")); unset IFS
}

# Comprobar si un servicio está seleccionado
is_selected() {
    local name="$1"
    if [[ -z "$SERVICE_FILTER" ]]; then return 0; fi
    for s in $SERVICE_FILTER; do
        [[ "$s" == "$name" ]] && return 0
    done
    return 1
}

# Menú principal
main_menu() {
    while true; do
        choice=$(whiptail --title "Docker Backup Configurator" \
            --menu "¿Qué quieres hacer?" 14 50 4 \
            "1" "Configurar servicios y opciones" \
            "2" "Ejecutar backup ahora" \
            "3" "Ver último log" \
            "4" "Salir" 3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && exit 0
        case "$choice" in
            1) config_menu ;;
            2) run_backup ;;
            3) view_log ;;
            4) exit 0 ;;
        esac
    done
}

# Menú de configuración
config_menu() {
    while true; do
        choice=$(whiptail --title "Configuración" \
            --menu "Elige qué configurar" 14 50 3 \
            "1" "Seleccionar servicios a respaldar" \
            "2" "Opciones de backup (ruta, retención, compresión)" \
            "3" "Volver al menú principal" 3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && return
        case "$choice" in
            1) select_services ;;
            2) edit_settings ;;
            3) return ;;
        esac
    done
}

# Selección de servicios (checklist)
select_services() {
    detect_services
    declare -a args=()
    args+=("--title" "Servicios disponibles" "--checklist")
    args+=("Selecciona los servicios a respaldar (ESPACIO para marcar/desmarcar)" 20 60 12)

    local all_selected=true
    for svc in "${SERVICES[@]}"; do
        is_selected "$svc" && state="ON" || { state="OFF"; all_selected=false; }
        args+=("$svc" "$svc" "$state")
    done

    selected=$(whiptail "${args[@]}" 3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && return

    SERVICE_FILTER=$(echo "$selected" | tr -d '"' | tr '\n' ' ' | sed 's/ $//')
    save_config
    whiptail --title "Guardado" --msgbox "Configuración guardada." 8 40
}

# Editar opciones de backup
edit_settings() {
    local bd rc rd comp
    bd=$(whiptail --title "Directorio de backup" --inputbox "Ruta donde guardar los backups" 10 60 "$BACKUP_DIR" 3>&1 1>&2 2>&3) || return
    rc=$(whiptail --title "Retención (cantidad)" --inputbox "Nº mínimo de snapshots a conservar" 10 60 "$RETENTION_COUNT" 3>&1 1>&2 2>&3) || return
    rd=$(whiptail --title "Retención (días)" --inputbox "Eliminar backups más antiguos de N días" 10 60 "$RETENTION_DAYS" 3>&1 1>&2 2>&3) || return
    comp=$(whiptail --title "Compresión" \
        --menu "Algoritmo de compresión" 12 50 3 \
        "zstd" "Zstandard (rápido, buena compresión)" \
        "gzip" "GZip (estándar)" \
        "none" "Sin compresión" 3>&1 1>&2 2>&3) || return

    BACKUP_DIR="$bd"
    RETENTION_COUNT="$rc"
    RETENTION_DAYS="$rd"
    COMPRESSION="$comp"
    save_config
    whiptail --title "Guardado" --msgbox "Configuración guardada." 8 40
}

# Guardar configuración
save_config() {
    cat > "$CONFIG" <<- EOF
# Docker Backup config — generado por docker-backup-config.sh
BACKUP_DIR=${BACKUP_DIR}
SERVICES_DIR=${SERVICES_DIR}
SERVICE_FILTER="${SERVICE_FILTER}"
RETENTION_COUNT=${RETENTION_COUNT}
RETENTION_DAYS=${RETENTION_DAYS}
COMPRESSION=${COMPRESSION}
EOF
}

# Ejecutar backup
run_backup() {
    if [[ ! -f "$BACKUP_SCRIPT" ]]; then
        whiptail --title "Error" --msgbox "Script de backup no encontrado:\n$BACKUP_SCRIPT" 10 50
        return
    fi
    whiptail --title "Backup" --infobox "Ejecutando backup...\nEsto puede tardar unos minutos." 8 50
    $BACKUP_SCRIPT "$CONFIG" > /dev/null 2>&1
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        whiptail --title "Completado" --msgbox "Backup finalizado correctamente." 8 40
    else
        whiptail --title "Completado (con errores)" --msgbox "Backup finalizado con $rc errores.\nRevisa el log para más detalles." 10 50
    fi
}

# Ver log
view_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        whiptail --title "Log" --msgbox "No hay log disponible todavía." 8 40
        return
    fi
    local tail_log
    tail_log=$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo "Error leyendo el log")
    whiptail --title "Últimas líneas del log" --scrolltext --msgbox "$tail_log" 20 70
}

# Arranque
main_menu
