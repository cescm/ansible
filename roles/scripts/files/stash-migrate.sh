#!/bin/bash

DB_PATH="/mnt/docker/stash/stash/config/stash-go.sqlite"
DB_DIR=$(dirname "$DB_PATH")
LOCAL_BASE_HOST="/mnt/storage/media/premovistar"
REMOTE_BASE_HOST="/mnt/movistar_enc/media/pr"
DOCKER_LOCAL="/data"
DOCKER_REMOTE="/data_remote"

TARGET="${1%/}"
if [ -z "$TARGET" ]; then echo "Usage: stash-migrate-safe.sh <folder>"; exit 1; fi

STASH_PATH_OLD="$DOCKER_LOCAL/$TARGET"
STASH_PATH_NEW="$DOCKER_REMOTE/$TARGET"

FULL_LOCAL_PATH_HOST="$LOCAL_BASE_HOST/$TARGET"

echo "=== Starting Safe Migration for: $TARGET ==="

if [ ! -d "$FULL_LOCAL_PATH_HOST" ]; then
    echo "ERROR: Folder '$TARGET' does not exist on the local disk."
    echo "Searched path: $FULL_LOCAL_PATH_HOST"
    exit 1
fi
echo "[0/4] Folder validation passed."

echo "[1/4] Stopping Stash container..."
docker stop stash

echo "Forcing safety checkpoint flush (Pre-Backup Checkpoint)..."
echo "SQL: PRAGMA wal_checkpoint(TRUNCATE);"
sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);"
echo "  -> Flush completed."

echo "[2/4] Creating database backup..."
BACKUP_FILE="$DB_DIR/stash_backup_$(date +%Y%m%d_%H%M%S).tar"
tar -cf "$BACKUP_FILE" "$DB_DIR"/stash-go.sqlite*
echo "  -> Backup saved to: $BACKUP_FILE"

echo "[3/4] Checking SQLite integrity..."
echo "SQL: PRAGMA integrity_check;"
INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;")
if [ "$INTEGRITY" != "ok" ]; then
    echo "CRITICAL ERROR: The database is corrupt or locked."
    echo "Integrity: $INTEGRITY"
    echo "Starting container and aborting the migration..."
    docker start stash
    exit 1
fi
echo "  -> Integrity OK."

echo "--- CURRENT STATE: 'folders' table ---"
echo "SQL: SELECT id, basename, path, parent_folder_id FROM folders WHERE path LIKE '%$TARGET%';"
sqlite3 -header -column "$DB_PATH" "SELECT id, basename, path, parent_folder_id FROM folders WHERE path LIKE '%$TARGET%';"
echo "----------------------------------------"

echo "--- CURRENT STATE: 'files' table ---"
echo "SQL: SELECT id, basename, parent_folder_id FROM files WHERE basename LIKE '%$TARGET%';"
sqlite3 -header -column "$DB_PATH" "SELECT id, basename, parent_folder_id FROM files WHERE basename LIKE '%$TARGET%';"
echo "----------------------------------------"

RED='\033[0;31m'
BOLD_RED='\033[1;31m'
NC='\033[0m'
echo ""
echo "=== CHECKING FOR DUPLICATES ==="
DUPLICADOS=$(sqlite3 -header -column "$DB_PATH" "
SELECT fi_local.id as id_local, fi_local.basename, fi_remote.id as id_remoto
FROM files fi_local
JOIN files fi_remote ON fi_local.basename = fi_remote.basename
WHERE fi_local.parent_folder_id = (SELECT id FROM folders WHERE path = '$STASH_PATH_OLD')
  AND fi_remote.parent_folder_id = (SELECT id FROM folders WHERE path = '$STASH_PATH_NEW')
ORDER BY fi_local.basename;
")
if [ -z "$DUPLICADOS" ]; then
    echo "  -> No duplicates. Migration is safe."
else
    echo -e "${BOLD_RED}⚠️  ATTENTION: These files already exist in the remote folder and will be SKIPPED:${NC}"
    echo ""
    echo -e "${RED}${DUPLICADOS}${NC}"
    echo ""
    echo -e "${BOLD_RED}If you want to replace any of them, cancel with Ctrl+C and handle the duplicate manually.${NC}"
fi
echo "=============================="

echo "[4/4] Running Smart Merge on database..."
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
echo "=== SQL TO EXECUTE (Smart Merge) ==="
echo "$SQL_MASTER"
echo "======================================="

read -p "Press any key to run the DB migration... " -n1 -s
echo ""

sqlite3 "$DB_PATH" "$SQL_MASTER"
echo "  -> Database updated successfully."

echo "--- NEW STATE: 'folders' table ---"
echo "SQL: SELECT id, basename, path, parent_folder_id FROM folders WHERE path LIKE '%$TARGET%';"
sqlite3 -header -column "$DB_PATH" "SELECT id, basename, path, parent_folder_id FROM folders WHERE path LIKE '%$TARGET%';"
echo "----------------------------------------"

echo "--- NEW STATE: 'files' table ---"
echo "SQL: SELECT id, basename, parent_folder_id FROM files WHERE basename LIKE '%$TARGET%';"
sqlite3 -header -column "$DB_PATH" "SELECT id, basename, parent_folder_id FROM files WHERE basename LIKE '%$TARGET%';"
echo "----------------------------------------"

echo "Total files found:"
sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files WHERE basename LIKE '%$TARGET%';"
echo "----------------------------------------"

echo ""
read -p "Press any key to force the disk dump (Checkpoint)... " -n1 -s
echo ""

echo "SQL: PRAGMA wal_checkpoint(TRUNCATE);"
sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);"
echo "  -> Dump completed."

echo "Restoring permissions for Docker (user 1000)..."
chown -R 1000:1000 "$DB_DIR"

echo ""
echo "Reiniciando contenedor Stash..."
docker start stash

echo "=== MIGRATION COMPLETED SUCCESSFULLY ==="
