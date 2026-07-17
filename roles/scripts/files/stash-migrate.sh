#!/bin/bash

DB_PATH="/mnt/docker/stash/stash/config/stash-go.sqlite"
DB_DIR=$(dirname "$DB_PATH")
LOCAL_BASE_HOST="/mnt/storage/media/premovistar"
REMOTE_BASE_HOST="/mnt/movistar_enc/media/pr"
DOCKER_LOCAL="/data"
DOCKER_REMOTE="/data_remote"

TARGET="${1%/}"
if [ -z "$TARGET" ]; then echo "Uso: stash-migrate-safe.sh <carpeta>"; exit 1; fi

STASH_PATH_OLD="$DOCKER_LOCAL/$TARGET"
STASH_PATH_NEW="$DOCKER_REMOTE/$TARGET"

FULL_LOCAL_PATH_HOST="$LOCAL_BASE_HOST/$TARGET"

echo "=== Iniciando Migración Segura para: $TARGET ==="

if [ ! -d "$FULL_LOCAL_PATH_HOST" ]; then
    echo "ERROR: La carpeta '$TARGET' no existe en el disco local."
    echo "Ruta buscada: $FULL_LOCAL_PATH_HOST"
    exit 1
fi
echo "[0/4] Validación de carpeta superada."

echo "[1/4] Deteniendo contenedor Stash..."
docker stop stash

echo "Forzando volcado de seguridad (Checkpoint Pre-Backup)..."
echo "SQL: PRAGMA wal_checkpoint(TRUNCATE);"
sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);"
echo "  -> Volcado completado."

echo "[2/4] Creando copia de seguridad de la base de datos..."
BACKUP_FILE="$DB_DIR/stash_backup_$(date +%Y%m%d_%H%M%S).tar"
tar -cf "$BACKUP_FILE" "$DB_DIR"/stash-go.sqlite*
echo "  -> Backup guardado en: $BACKUP_FILE"

echo "[3/4] Comprobando integridad de SQLite..."
echo "SQL: PRAGMA integrity_check;"
INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;")
if [ "$INTEGRITY" != "ok" ]; then
    echo "ERROR CRÍTICO: La base de datos está corrupta o bloqueada."
    echo "Integridad: $INTEGRITY"
    echo "Iniciando contenedor y abortando la migración..."
    docker start stash
    exit 1
fi
echo "  -> Integridad OK."

echo "--- ESTADO ACTUAL: Tabla 'folders' ---"
echo "SQL: SELECT id, basename, path, parent_folder_id FROM folders WHERE path LIKE '%$TARGET%';"
sqlite3 -header -column "$DB_PATH" "SELECT id, basename, path, parent_folder_id FROM folders WHERE path LIKE '%$TARGET%';"
echo "----------------------------------------"

echo "--- ESTADO ACTUAL: Tabla 'files' ---"
echo "SQL: SELECT id, basename, parent_folder_id FROM files WHERE basename LIKE '%$TARGET%';"
sqlite3 -header -column "$DB_PATH" "SELECT id, basename, parent_folder_id FROM files WHERE basename LIKE '%$TARGET%';"
echo "----------------------------------------"

RED='\033[0;31m'
BOLD_RED='\033[1;31m'
NC='\033[0m'
echo ""
echo "=== COMPROBANDO DUPLICADOS ==="
DUPLICADOS=$(sqlite3 -header -column "$DB_PATH" "
SELECT fi_local.id as id_local, fi_local.basename, fi_remote.id as id_remoto
FROM files fi_local
JOIN files fi_remote ON fi_local.basename = fi_remote.basename
WHERE fi_local.parent_folder_id = (SELECT id FROM folders WHERE path = '$STASH_PATH_OLD')
  AND fi_remote.parent_folder_id = (SELECT id FROM folders WHERE path = '$STASH_PATH_NEW')
ORDER BY fi_local.basename;
")
if [ -z "$DUPLICADOS" ]; then
    echo "  -> Sin duplicados. Migración segura."
else
    echo -e "${BOLD_RED}⚠️  ATENCIÓN: Estos archivos ya existen en la carpeta remota y serán SALTADOS:${NC}"
    echo ""
    echo -e "${RED}${DUPLICADOS}${NC}"
    echo ""
    echo -e "${BOLD_RED}Si quieres reemplazar alguno, cancela con Ctrl+C y gestiona el duplicado manualmente.${NC}"
fi
echo "=============================="

echo "[4/4] Ejecutando Fusión Inteligente en Base de Datos..."
SQL_MASTER="
UPDATE files
SET parent_folder_id = (SELECT id FROM folders WHERE path = '$STASH_PATH_NEW')
WHERE parent_folder_id = (SELECT id FROM folders WHERE path = '$STASH_PATH_OLD')
  AND EXISTS (SELECT 1 FROM folders WHERE path = '$STASH_PATH_NEW');

DELETE FROM folders
WHERE path = '$STASH_PATH_OLD'
  AND EXISTS (SELECT 1 FROM folders WHERE path = '$STASH_PATH_NEW');

UPDATE folders SET path = '$STASH_PATH_NEW' WHERE path = '$STASH_PATH_OLD';

UPDATE folders
SET parent_folder_id = (SELECT id FROM folders WHERE path = '$DOCKER_REMOTE')
WHERE path = '$STASH_PATH_NEW';
"

echo ""
echo "=== SQL A EJECUTAR (Fusión Inteligente) ==="
echo "$SQL_MASTER"
echo "========================================"

read -p "Presiona cualquier tecla para ejecutar la migración en BBDD... " -n1 -s
echo ""

sqlite3 "$DB_PATH" "$SQL_MASTER"
echo "  -> Base de datos actualizada correctamente."

echo "--- NUEVO ESTADO: Tabla 'folders' ---"
echo "SQL: SELECT id, basename, path, parent_folder_id FROM folders WHERE path LIKE '%$TARGET%';"
sqlite3 -header -column "$DB_PATH" "SELECT id, basename, path, parent_folder_id FROM folders WHERE path LIKE '%$TARGET%';"
echo "----------------------------------------"

echo "--- NUEVO ESTADO: Tabla 'files' ---"
echo "SQL: SELECT id, basename, parent_folder_id FROM files WHERE basename LIKE '%$TARGET%';"
sqlite3 -header -column "$DB_PATH" "SELECT id, basename, parent_folder_id FROM files WHERE basename LIKE '%$TARGET%';"
echo "----------------------------------------"

echo "Total de archivos encontrados:"
sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files WHERE basename LIKE '%$TARGET%';"
echo "----------------------------------------"

echo ""
read -p "Presiona cualquier tecla para forzar el volcado a disco (Checkpoint)... " -n1 -s
echo ""

echo "SQL: PRAGMA wal_checkpoint(TRUNCATE);"
sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);"
echo "  -> Volcado completado."

echo "Restaurando permisos para Docker (Usuario 1000)..."
chown -R 1000:1000 "$DB_DIR"

echo ""
echo "Reiniciando contenedor Stash..."
docker start stash

echo "=== MIGRACIÓN COMPLETADA CON ÉXITO ==="
