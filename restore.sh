#!/usr/bin/env bash
# restore.sh - restore a self-hosted deployment from a backup.sh archive.
#
# DESTRUCTIVE: replaces the current stack's volumes and runtime config
# with the backup's. For disaster recovery (roll back) or migration to a
# fresh host.
#
# Prerequisites on the target host:
#   - Docker + the compose plugin; deploy dir at /opt/exo
#   - `docker login` to the image registry first (to pull images)
#
# The backup's .env is restored verbatim, so the stack comes back with
# the ORIGINAL ENCRYPTION_KEY / EXO_JWT_SECRET - which is what makes
# stored credentials decryptable again. Do NOT run setup.sh first on a
# fresh host; the restore brings the original secrets back.
#
# Restore brings the database up on a fresh volume and replays the
# online dump into it (mongorestore --oplogReplay), so it matches how
# backup.sh captured it.
#
# Usage: ./restore.sh /opt/exo/backups/<timestamp> [--yes]

set -euo pipefail
cd "$(dirname "$0")"

if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi

DB_SERVICE=database
DB_VOLUME_KEY=mongo-data

BACKUP="${1:-}"
ASSUME_YES=0
[ "${2:-}" = "--yes" ] && ASSUME_YES=1

[ -n "$BACKUP" ] && [ "$BACKUP" != "--yes" ] || { echo "usage: ./restore.sh <backup-dir> [--yes]"; exit 1; }
[ -d "$BACKUP" ] || { echo "${R}error:${N} backup dir not found: $BACKUP"; exit 1; }
[ -f "$BACKUP/manifest.txt" ] || { echo "${R}error:${N} not a backup dir (no manifest.txt): $BACKUP"; exit 1; }
[ -f "$BACKUP/mongo.archive.gz" ] || { echo "${R}error:${N} backup has no mongo.archive.gz (not an online backup): $BACKUP"; exit 1; }
[ "$PWD" = "/opt/exo" ] || { echo "${R}error:${N} run from /opt/exo (current: $PWD)"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "${R}error:${N} docker not found"; exit 1; }

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"

echo "${Y}This REPLACES the current stack's volumes and config with the backup:${N}"
echo "  backup : $BACKUP"
echo "  project: $PROJECT"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Type 'restore' to proceed: " ans
  [ "$ans" = "restore" ] || { echo "aborted"; exit 1; }
fi

# 1. Stop the currently-running stack (if any) using the compose file
#    that's there now. Keeps volumes (we recreate them below).
if [ -f docker-compose.yml ]; then
  docker compose down --remove-orphans 2>/dev/null || true
fi

# 2. Restore config + the resolved compose into the deploy dir.
echo "${B}Restoring config${N}"
for f in .env config.toml config.proxy.toml Caddyfile docker-compose.yml; do
  [ -f "$BACKUP/$f" ] && cp -p "$BACKUP/$f" "./$f"
done
[ -d "$BACKUP/certs" ] && { rm -rf ./certs; cp -rp "$BACKUP/certs" ./certs; }
[ -f docker-compose.yml ] || { echo "${R}error:${N} backup has no docker-compose.yml; fetch it (setup.sh) before restoring"; exit 1; }

# Recreate a named volume empty, with the labels compose expects.
recreate_vol() {
  local key="$1" vol="${PROJECT}_$1"
  docker volume rm "$vol" >/dev/null 2>&1 || true
  docker volume create \
    --label com.docker.compose.project="$PROJECT" \
    --label com.docker.compose.volume="$key" \
    "$vol" >/dev/null
  printf '%s' "$vol"
}

# 3. Restore the non-DB volumes (untar into fresh volumes).
echo "${B}Restoring volumes${N}"
for tgz in "$BACKUP"/volume-*.tgz; do
  [ -e "$tgz" ] || break
  base="$(basename "$tgz")"; key="${base#volume-}"; key="${key%.tgz}"
  echo "  ${key}"
  vol="$(recreate_vol "$key")"
  docker run --rm -v "${vol}:/data" -v "${BACKUP}:/backup:ro" busybox \
    tar xzf "/backup/${base}" -C /data
done

# 4. Fresh DB volume, start ONLY the database (so nothing writes while we
#    restore), wait for it to become primary, then replay the dump.
echo "${B}Restoring database${N}"
recreate_vol "$DB_VOLUME_KEY" >/dev/null
docker compose up -d "$DB_SERVICE"

echo "  waiting for ${DB_SERVICE} to be ready..."
ready=0
for _ in $(seq 1 60); do
  if docker compose exec -T "$DB_SERVICE" mongosh --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
    ready=1; break
  fi
  sleep 2
done
[ "$ready" = 1 ] || { echo "${R}error:${N} ${DB_SERVICE} did not become ready"; exit 1; }

echo "  mongorestore (--oplogReplay)"
docker compose exec -T "$DB_SERVICE" mongorestore --archive --gzip --oplogReplay < "$BACKUP/mongo.archive.gz"

# 5. Bring up the rest of the stack.
echo "${B}Starting the stack${N}"
docker compose up -d

echo "${G}Restore complete.${N} Verify with: docker compose ps"
