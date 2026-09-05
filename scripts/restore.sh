#!/usr/bin/env sh
set -eu
SRC=${1:?usage: restore.sh <backup-dir>}
cat "$SRC/postgres.dump" | docker compose --env-file .env -f core/docker-compose.yml exec -T postgres pg_restore --clean --if-exists -U "$POSTGRES_USER" -d "$POSTGRES_DB"
echo "PostgreSQL restored. Restore Qdrant/n8n volumes only during a maintenance window; see docs/operations/BACKUP-RESTORE.md."
