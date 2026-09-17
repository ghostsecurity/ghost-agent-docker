#!/usr/bin/env bash
# setup.sh - host bootstrap for the Ghost Agent Platform.
#
# Prompts for the release tag and Docker Hub OAT, generates the
# one-time claim token, fetches the stack bundle (compose file +
# static config defaults), and copies the defaults into place. All
# platform configuration - domain, TLS, admin account, connectors -
# happens afterwards in the in-product setup wizard, unlocked by the
# claim token this script prints.
#
# Refuses to overwrite existing config files. Remove them manually and
# re-run to regenerate.

set -euo pipefail

cd "$(dirname "$0")"

# ANSI color helpers - skip when not on a TTY so logs stay clean.
if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi

# --- preflight ---

# The deploy directory is locked to /opt/exo. In-stack upgrades run
# `docker compose` from inside the updater container with the project
# directory fixed at /opt/exo, so the compose file's relative bind
# mounts (./config.toml, ./Caddyfile, …) resolve to /opt/exo/... on the
# host. Deploying elsewhere works for the first `docker compose up` but
# breaks the first upgrade (recreated services would bind nonexistent
# host paths). Fail fast here rather than at upgrade time.
if [ "$PWD" != "/opt/exo" ]; then
  echo "${R}error:${N} this stack must be deployed at /opt/exo (current: ${PWD})."
  echo "  Move the repo to /opt/exo and re-run, e.g.:"
  echo "    sudo mv \"$PWD\" /opt/exo && cd /opt/exo && ./setup.sh"
  exit 1
fi

# Don't overwrite an existing config.
for f in .env config.toml config.proxy.toml Caddyfile; do
  if [ -f "$f" ]; then
    echo "${R}error:${N} $f already exists. Remove it and re-run."
    exit 1
  fi
done

for tool in openssl curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "${R}error:${N} '$tool' not found in PATH"; exit 1; }
done

# Docker (with the compose v2 plugin) is a hard requirement: the stack runs
# as `docker compose`, and the host-tuning below restarts docker.service.
# Fail fast with a clear message rather than aborting cryptically later.
if ! command -v docker >/dev/null 2>&1; then
  echo "${R}error:${N} docker not found. Install Docker Engine + the compose plugin first:"
  echo "  https://docs.docker.com/engine/install/"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "${R}error:${N} the docker daemon isn't reachable - is it running, and are you root or in the 'docker' group?"
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "${R}error:${N} 'docker compose' plugin not found. Install the pinned v5.x plugin"
  echo "  binary per the bootstrap steps in README.md (distro packages such as"
  echo "  docker-compose-v2 ship a different major and won't pass the check below)."
  exit 1
fi

# Compose MAJOR version must match the in-stack updater's compose. The
# updater reconciles the stack's networks on every upgrade and per-run
# worker recycle; compose stamps a per-network "config hash" that differs
# across major versions, so if the host compose that first creates the
# networks is a different major than the updater's, the updater's `up`
# tries to recreate networks that still have containers attached and
# fails ("network ... has active endpoints"). Keep REQUIRED_COMPOSE_MAJOR
# in lockstep with COMPOSE_VERSION in build/updater.Dockerfile.
REQUIRED_COMPOSE_MAJOR=5
HOST_COMPOSE_VER=$(docker compose version --short 2>/dev/null | sed 's/^v//')
HOST_COMPOSE_MAJOR=${HOST_COMPOSE_VER%%.*}
if [ -n "$HOST_COMPOSE_MAJOR" ] && [ "$HOST_COMPOSE_MAJOR" != "$REQUIRED_COMPOSE_MAJOR" ]; then
  echo "${R}error:${N} Docker Compose v${REQUIRED_COMPOSE_MAJOR}.x is required (found v${HOST_COMPOSE_VER:-unknown})."
  echo "  The in-stack updater runs Compose v${REQUIRED_COMPOSE_MAJOR}.x and reconciles the stack's"
  echo "  networks on upgrades; a different major makes it try to recreate networks"
  echo "  that have active endpoints, which fails. Install the pinned v${REQUIRED_COMPOSE_MAJOR}.x plugin"
  echo "  binary per the bootstrap steps in README.md."
  exit 1
fi

# --- prompts ---

echo "${B}Ghost Agent Platform - setup${N}"
echo

# Docker Hub OAT (collected first so the newest release tag can be
# resolved from the registry before the tag prompt).
read -r -s -p "Docker Hub OAT (will be hidden): " DOCKER_OAT
echo
[ -z "$DOCKER_OAT" ] && { echo "${R}error:${N} OAT is required"; exit 1; }

# Resolve the newest published release tag from the registry - the same
# semantics as the in-stack updater's poller and the AWS bootstrap.
# exo-stack is published LAST in the release pipeline (after every
# image), so its newest clean-semver tag is a fully published release.
# Best-effort: a lookup failure just leaves the prompt without a default.
REGISTRY_VALUE="${REGISTRY:-docker.io/ghostsecurityhq}"
DH_ORG="${REGISTRY_VALUE##*/}"
ORAS_IMAGE="ghcr.io/oras-project/oras:v1.2.0"

echo
echo "Resolving newest release..."
LATEST_TAG=$(docker run --rm "$ORAS_IMAGE" \
  repo tags --username "$DH_ORG" --password "$DOCKER_OAT" \
  "${REGISTRY_VALUE}/exo-stack" 2>/dev/null \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V | tail -1 || true)

# Release tag - defaults to the resolved latest; the operator can pin a
# specific version by typing it.
if [ -n "$LATEST_TAG" ]; then
  read -r -p "Release tag to deploy [${LATEST_TAG}]: " TAG
  TAG="${TAG:-$LATEST_TAG}"
else
  echo "${Y}note:${N} could not resolve the latest tag automatically."
  read -r -p "Release tag to deploy (e.g. v0.0.45): " TAG
fi
[ -z "$TAG" ] && { echo "${R}error:${N} TAG is required"; exit 1; }

# --- generate ---

# The one secret this script delivers: the claim token that unlocks the
# in-product setup wizard. The platform stores only its hash; the raw
# value is printed once below.
CLAIM_TOKEN=$(openssl rand -hex 32)

# Detect the public IP: its nip.io name becomes the bring-up hostname
# the pre-setup Caddyfile serves with a real Let's Encrypt cert, so the
# wizard loads without a certificate warning. Detection failure is
# non-fatal - the catch-all self-signed fallback still serves the
# wizard on the bare IP (one browser warning to accept).
DETECTED_IP=$(curl -4 -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
BRINGUP_DOMAIN=""
if [ -n "$DETECTED_IP" ]; then
  BRINGUP_DOMAIN="${DETECTED_IP//./-}.nip.io"
fi

# Minimal .env: image selection, registry auth, the claim token, and
# the bring-up hostname. Everything else (domain, TLS, connectors,
# worker count) is configured through the setup wizard and rendered
# into this file by the platform.
cat > .env <<EOF
# Ghost Agent Platform - runtime environment.
#
# Written by setup.sh; the platform rewrites managed lines in this file
# when instance settings change. Lines you add for the optional
# overrides documented in .env.example are preserved.
TAG=${TAG}
EXO_UPDATER_OCI_AUTH_TOKEN=${DOCKER_OAT}
EXO_CLAIM_TOKEN=${CLAIM_TOKEN}
EOF
if [ -n "$BRINGUP_DOMAIN" ]; then
  printf 'EXO_BRINGUP_DOMAIN=%s\n' "$BRINGUP_DOMAIN" >> .env
fi
chmod 600 .env   # holds secrets: the OAT and the claim token

# --- fetch the stack bundle ---

# The docker-compose.yml is NOT shipped in this repo. It's published per
# release as the OCI "stack bundle" `${REGISTRY}/exo-stack:${TAG}`,
# together with the static config defaults (defaults/), the Caddyfile
# templates the platform renders settings into (templates/), and host
# helper scripts (scripts/). The in-stack updater fetches subsequent
# versions on each topology-aware upgrade (same source of truth). We
# pull with a throwaway `oras` container (no host oras install needed),
# authenticating with the OAT already collected above.
REGISTRY_VALUE="${REGISTRY:-docker.io/ghostsecurityhq}"
DH_ORG="${REGISTRY_VALUE##*/}"
STACK_REF="${REGISTRY_VALUE}/exo-stack:${TAG}"
ORAS_IMAGE="ghcr.io/oras-project/oras:v1.2.0"

echo
echo "${B}Fetching stack bundle${N} ${STACK_REF}"
if docker run --rm -v "$PWD:/work" -w /work "$ORAS_IMAGE" \
  pull --username "$DH_ORG" --password "$DOCKER_OAT" "$STACK_REF" -o . ; then
  echo "  wrote docker-compose.yml + defaults/ + templates/ + scripts/"
else
  echo "${R}error:${N} failed to fetch the stack bundle ${STACK_REF}."
  echo "  Confirm the tag exists in Docker Hub and the OAT has read access, then re-run."
  exit 1
fi

for f in defaults/config.toml defaults/config.proxy.toml defaults/Caddyfile.bootstrap; do
  if [ ! -f "$f" ]; then
    echo "${R}error:${N} bundle is missing $f - the release predates the setup wizard."
    echo "  Deploy a newer release tag."
    exit 1
  fi
done

# --- place the config defaults ---

# Copy-if-absent only: neither this script nor an upgrade ever
# overwrites the live copies. The platform (updater) rewrites the
# Caddyfile and managed .env lines when instance settings change.
cp -n defaults/config.toml config.toml
cp -n defaults/config.proxy.toml config.proxy.toml
cp -n defaults/Caddyfile.bootstrap Caddyfile
# BYO-cert drop point; bind-mounted into the edge proxy. The platform
# writes operator-uploaded certs here when custom TLS is selected.
mkdir -p certs

# config.toml and config.proxy.toml carry no secrets and are
# bind-mounted read-only into the non-root gateway / credential-proxy
# (UID 65532); keep them world-readable so the containers can read them
# regardless of the operator's umask.
chmod 644 config.toml config.proxy.toml Caddyfile

# --- claim-token reissue helper ---

# Installs the on-host helper that rotates the claim token for an
# unclaimed instance (lost/exposed token before the wizard ran).
if [ -f scripts/reissue-claim-token.sh ]; then
  if [ "$(id -u)" -eq 0 ]; then
    install -m 755 scripts/reissue-claim-token.sh /usr/local/bin/exo-reissue-claim-token
    echo "  installed /usr/local/bin/exo-reissue-claim-token"
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 755 scripts/reissue-claim-token.sh /usr/local/bin/exo-reissue-claim-token
    echo "  installed /usr/local/bin/exo-reissue-claim-token"
  else
    echo "${Y}note:${N} could not install the reissue helper (no root/sudo);"
    echo "  run scripts/reissue-claim-token.sh directly if the claim token is lost."
  fi
fi

# --- summary ---

if [ -n "$BRINGUP_DOMAIN" ]; then
  WIZARD_URL="https://${BRINGUP_DOMAIN}"
else
  WIZARD_URL="https://<this-host's-public-IP>"
fi

echo
echo "${G}done${N} - configuration written to .env, config.toml, config.proxy.toml, Caddyfile"
echo
echo "${Y}Claim token (needed once, in the setup wizard):${N}"
echo
echo "  ${B}${CLAIM_TOKEN}${N}"
echo
echo "${Y}Save it until setup completes - it won't be shown again.${N}"
echo "(Lost it before claiming? Run exo-reissue-claim-token to rotate.)"

# --- host tuning (optional) ---

echo
echo "${B}Host tuning${N} (optional, modifies system files - needs root/sudo):"
echo "  - Cap container log size at 10MB x 3 files (json-file driver)"
echo "  - Daily prune of unused images older than 7 days"
echo "  - Block worker pool image builds from the cloud metadata service"
echo
read -r -p "Apply? [Y/n]: " TUNE_CHOICE

case "${TUNE_CHOICE:-Y}" in
  [nN]|[nN][oO])
    echo "Skipping host tuning."
    ;;
  *)
    # Pick the privilege escalator. Skip with a notice if we're not
    # root AND sudo isn't installed.
    if [ "$(id -u)" -eq 0 ]; then
      SUDO=""
    elif command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      echo "${Y}note:${N} need root or sudo to apply host tuning - skipping"
      TUNE_SKIPPED=1
    fi

    DOCKER_BIN=$(command -v docker || echo /usr/bin/docker)

    if [ -z "${TUNE_SKIPPED:-}" ]; then
      # Docker daemon log rotation. Refuse to overwrite an existing
      # daemon.json - operators may have other config there. The
      # warning tells them what to add manually.
      if [ -f /etc/docker/daemon.json ]; then
        echo "${Y}note:${N} /etc/docker/daemon.json already exists - skipping log rotation."
        echo "  To enable manually, add:"
        echo '    "log-driver": "json-file",'
        echo '    "log-opts": { "max-size": "10m", "max-file": "3" }'
      else
        $SUDO mkdir -p /etc/docker
        $SUDO tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
        # Restart docker so the new log driver picks up. Safe here
        # because the stack hasn't been brought up yet (setup.sh
        # runs before `docker compose up`).
        $SUDO systemctl restart docker
        echo "  wrote /etc/docker/daemon.json and restarted docker"
      fi

      # Systemd timer for daily image prune. Idempotent - re-writing
      # the same content on a re-run is fine.
      $SUDO tee /etc/systemd/system/exo-docker-prune.service > /dev/null <<EOF
[Unit]
Description=Prune unused Docker images older than 7 days
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${DOCKER_BIN} image prune -a --filter "until=168h" -f
EOF

      $SUDO tee /etc/systemd/system/exo-docker-prune.timer > /dev/null <<'EOF'
[Unit]
Description=Daily Docker image prune

[Timer]
OnCalendar=daily
# Persistent=true catches up missed runs (host was off, etc.) on
# next boot instead of waiting another 24h.
Persistent=true

[Install]
WantedBy=timers.target
EOF

      $SUDO systemctl daemon-reload
      $SUDO systemctl enable --now exo-docker-prune.timer >/dev/null 2>&1
      echo "  installed exo-docker-prune.timer (daily image prune)"

      # Worker pool image builds run on this host's Docker daemon, so
      # each install step runs in a container on the default bridge
      # (docker0) with the host's outbound network. On a cloud VM that
      # path reaches the instance metadata service, and with it the
      # VM's cloud identity. Drop it for the default bridge only; the
      # stack's own containers sit on compose networks and are not
      # affected. Harmless on a host with no metadata service.
      # Idempotent, and re-applied after every docker restart.
      $SUDO tee /usr/local/sbin/exo-block-build-metadata > /dev/null <<'EOF'
#!/bin/sh
set -eu

guard() { # <iptables binary> <metadata address> <required: yes|no>
  bin=$1; addr=$2; required=$3
  if ! command -v "$bin" >/dev/null 2>&1 || ! "$bin" -S DOCKER-USER >/dev/null 2>&1; then
    [ "$required" = no ] && return 0
    echo "exo-block-build-metadata: $bin has no DOCKER-USER chain; is docker running?" >&2
    exit 1
  fi
  "$bin" -C DOCKER-USER -i docker0 -d "$addr" -j DROP 2>/dev/null \
    || "$bin" -I DOCKER-USER 1 -i docker0 -d "$addr" -j DROP
}

guard iptables  169.254.169.254 yes
guard ip6tables fd00:ec2::254   no
EOF
      $SUDO chmod 0755 /usr/local/sbin/exo-block-build-metadata

      $SUDO tee /etc/systemd/system/exo-block-build-metadata.service > /dev/null <<'EOF'
[Unit]
Description=Block Docker's default bridge from the instance metadata service
After=docker.service
Requires=docker.service
# Re-run whenever docker restarts, so the rule is never lost with the chain.
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/exo-block-build-metadata

[Install]
WantedBy=multi-user.target
EOF

      $SUDO systemctl daemon-reload
      if $SUDO systemctl enable --now exo-block-build-metadata.service >/dev/null 2>&1; then
        echo "  installed exo-block-build-metadata.service (metadata guard for pool image builds)"
      else
        echo "${Y}note:${N} could not install exo-block-build-metadata.service (is docker running with its"
        echo "  iptables management on?); see 'Worker pools and add-ons' in the README for the rule."
      fi
    fi
    ;;
esac

echo
echo "Next:"
echo "  docker login -u ghostsecurityhq    # if you haven't already"
echo "  docker compose pull"
echo "  docker compose up -d"
echo
echo "Then open ${B}${WIZARD_URL}${N} to run the setup wizard and enter the"
echo "claim token above. The wizard creates the admin account and"
echo "configures the domain and TLS."
if [ -z "$BRINGUP_DOMAIN" ]; then
  echo "(Browsing by bare IP serves a temporary self-signed certificate -"
  echo "accept the one-time warning.)"
fi
