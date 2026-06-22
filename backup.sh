#!/usr/bin/env bash
# backup.sh - online, zero-downtime backup of a self-hosted Ghost Agent
# Platform deployment.
#
# Runs against the LIVE stack - no stop, no write-blocking:
#   - MongoDB via `mongodump --oplog`, a consistent point-in-time online
#     logical dump (the oplog is replayed on restore)
#   - the other named volumes (TLS CA keys, runner identities, Caddy
#     certs, artifacts) via a read-only live tar
#   - the runtime config (.env, config.toml, config.proxy.toml,
#     Caddyfile, certs/) and the resolved docker-compose.yml
#
# .env holds ENCRYPTION_KEY and EXO_JWT_SECRET, which a restore needs to
# decrypt stored credentials and keep sessions valid - so the archive
# contains secrets. Store it securely and off-host.
#
# Usage:
#   ./backup.sh                 # -> /opt/exo/backups/<timestamp>
#   ./backup.sh --out=/mnt/bkp  # write under a different directory

set -euo pipefail
cd "$(dirname "$0")"

if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi

# Well-known names from the stack compose (Ghost-controlled, stable).
DB_SERVICE=database
DB_VOLUME_KEY=mongo-data

OUT_ROOT="${BACKUP_DIR:-/opt/exo/backups}"
for arg in "$@"; do
  case "$arg" in
    --out=*) OUT_ROOT="${arg#--out=}" ;;
    *) echo "${R}error:${N} unknown argument: $arg"; exit 1 ;;
  esac
done

[ "$PWD" = "/opt/exo" ] || { echo "${R}error:${N} run from /opt/exo (current: $PWD)"; exit 1; }
[ -f .env ] || { echo "${R}error:${N} .env not found - is this a configured deployment?"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "${R}error:${N} docker not found"; exit 1; }

# The online dump needs the database service running.
if ! docker compose exec -T "$DB_SERVICE" mongosh --quiet --eval 'quit(0)' >/dev/null 2>&1; then
  echo "${R}error:${N} the '${DB_SERVICE}' service must be running for an online backup. Start the stack (docker compose up -d) first."
  exit 1
fi

# Resolve the compose project (the prefix on the stack's named volumes).
PROJECT=""
cid="$(docker compose ps -q "$DB_SERVICE" 2>/dev/null | head -n1 || true)"
if [ -n "$cid" ]; then
  PROJECT="$(docker inspect "$cid" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
fi
[ -n "$PROJECT" ] || PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"

# Enumerate this stack's named volumes (adapts to the delivered topology).
VOLUMES=()
while IFS= read -r v; do [ -n "$v" ] && VOLUMES+=("$v"); done \
  < <(docker volume ls --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Name}}')

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${OUT_ROOT}/${TS}"
TMP="${DEST}.partial"
rm -rf "$TMP"; mkdir -p "$TMP"
# Only publish the backup dir if every step succeeds (atomic).
DONE=0
trap '[ "$DONE" = 1 ] || rm -rf "$TMP"' EXIT

echo "${B}Online backup of project '${PROJECT}'${N} -> ${DEST}"

# 1. MongoDB: consistent online dump (no downtime). --oplog records a
#    point-in-time window that mongorestore --oplogReplay applies.
echo "  mongodump (online, --oplog)"
docker compose exec -T "$DB_SERVICE" mongodump --archive --gzip --oplog > "${TMP}/mongo.archive.gz"

# 2. Other volumes: read-only live tar. The DB data volume is covered by
#    the dump above, so skip it.
for vol in "${VOLUMES[@]}"; do
  key="${vol#"${PROJECT}_"}"
  [ "$key" = "$DB_VOLUME_KEY" ] && continue
  echo "  volume ${key}"
  docker run --rm -v "${vol}:/data:ro" -v "${TMP}:/backup" busybox \
    tar czf "/backup/volume-${key}.tgz" -C /data .
done

# 3. Config + the resolved compose.
echo "  config (.env, config.toml, config.proxy.toml, Caddyfile, certs/, docker-compose.yml)"
for f in .env config.toml config.proxy.toml Caddyfile docker-compose.yml; do
  [ -f "$f" ] && cp -p "$f" "${TMP}/"
done
[ -d certs ] && cp -rp certs "${TMP}/"

{
  echo "created_utc=${TS}"
  echo "project=${PROJECT}"
  echo "format=online"
  echo "db_service=${DB_SERVICE}"
} > "${TMP}/manifest.txt"

mv "$TMP" "$DEST"
DONE=1
echo "${G}Backup complete:${N} ${DEST}"
echo "${Y}This archive contains secrets (.env). Store it securely and off-host.${N}"
