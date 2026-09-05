#!/usr/bin/env sh
set -eu
STAMP=$(date +%Y%m%d-%H%M%S)
DEST=${BACKUP_DIR:-./backups/$STAMP}
mkdir -p "$DEST"
docker compose --env-file .env -f core/docker-compose.yml exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$DEST/postgres.dump"
docker compose --env-file .env -f core/docker-compose.yml exec -T qdrant sh -c 'tar czf - /qdrant/storage' > "$DEST/qdrant.tgz"
docker compose --env-file .env -f core/docker-compose.yml exec -T n8n sh -c 'tar czf - /home/node/.n8n' > "$DEST/n8n.tgz"
echo "$DEST"
