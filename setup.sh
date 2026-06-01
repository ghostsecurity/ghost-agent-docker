#!/usr/bin/env bash
# setup.sh - interactive configuration for the Ghost Agent Platform.
#
# Prompts for the per-deployment inputs (release tag, public domain,
# admin email + password, Docker Hub OAT, TLS flavor), auto-generates
# the secrets that don't need operator choice (ENCRYPTION_KEY,
# jwt_secret), and stamps out the runtime config files from the
# `.example` templates:
#
#   .env, config.toml, config.proxy.toml, Caddyfile
#
# Refuses to overwrite any of those files. Remove them manually and
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

# Required template files (sources for the runtime configs).
for f in .env.example config.toml.example config.proxy.toml.example \
         Caddyfile.letsencrypt.example Caddyfile.byo.example; do
  if [ ! -f "$f" ]; then
    echo "${R}error:${N} required template $f not found - run setup.sh from a ghost-agent-docker checkout"
    exit 1
  fi
done

# Don't overwrite an existing config.
for f in .env config.toml config.proxy.toml Caddyfile; do
  if [ -f "$f" ]; then
    echo "${R}error:${N} $f already exists. Remove it and re-run."
    exit 1
  fi
done

for tool in openssl sed curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "${R}error:${N} '$tool' not found in PATH"; exit 1; }
done

# --- prompts ---

echo "${B}Ghost Agent Platform - setup${N}"
echo

# Release tag
read -r -p "Release tag to deploy (e.g. v0.0.19): " TAG
[ -z "$TAG" ] && { echo "${R}error:${N} TAG is required"; exit 1; }

# Public domain - detect IP and offer nip.io as the default
DETECTED_IP=$(curl -4 -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)

if [ -n "$DETECTED_IP" ]; then
  SUGGESTED="${DETECTED_IP//./-}.nip.io"
  echo
  echo "Detected public IP: ${B}${DETECTED_IP}${N}"
  read -r -p "Public domain [${SUGGESTED}]: " DOMAIN
  DOMAIN="${DOMAIN:-$SUGGESTED}"
else
  echo
  read -r -p "Public domain (e.g. 203-0-113-45.nip.io): " DOMAIN
  [ -z "$DOMAIN" ] && { echo "${R}error:${N} DOMAIN is required"; exit 1; }
fi

# Admin email - used for LE registration and the seed admin user
echo
read -r -p "Admin email (Let's Encrypt + initial login): " ADMIN_EMAIL
[ -z "$ADMIN_EMAIL" ] && { echo "${R}error:${N} ADMIN_EMAIL is required"; exit 1; }

# Admin password - auto-generate if blank, hex for sed-safety
echo
read -r -s -p "Admin password (blank = auto-generate): " ADMIN_PASSWORD
echo
AUTO_PW=0
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD=$(openssl rand -hex 16)
  AUTO_PW=1
fi

# Docker Hub OAT
echo
read -r -s -p "Docker Hub OAT (will be hidden): " DOCKER_OAT
echo
[ -z "$DOCKER_OAT" ] && { echo "${R}error:${N} OAT is required"; exit 1; }

# TLS flavor
echo
echo "TLS flavor:"
echo "  1) Let's Encrypt (auto - needs public DNS + ports 80/443 open)"
echo "  2) Bring-your-own cert"
read -r -p "Pick [1]: " TLS_CHOICE
TLS_CHOICE="${TLS_CHOICE:-1}"

# --- generate ---

ENCRYPTION_KEY=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -base64 64 | tr -d '\n')

# .env: substitute the three REQUIRED values into their empty
# placeholders in .env.example. Preserves comments and the optional
# Slack / REGISTRY / UPDATER_TAG lines for later manual editing.
sed \
  -e "s|^TAG=$|TAG=${TAG}|" \
  -e "s|^ENCRYPTION_KEY=$|ENCRYPTION_KEY=${ENCRYPTION_KEY}|" \
  -e "s|^EXO_UPDATER_OCI_AUTH_TOKEN=$|EXO_UPDATER_OCI_AUTH_TOKEN=${DOCKER_OAT}|" \
  .env.example > .env

# config.toml: substitute domain (URL form only), jwt_secret, seed
# admin email + password. The TODO comments in the example file are
# left intact - harmless reference for anyone editing later.
sed \
  -e "s|https://example.com|https://${DOMAIN}|g" \
  -e "s|REPLACE-WITH-LONG-RANDOM-SECRET|${JWT_SECRET}|" \
  -e "s|email = \"admin@example.com\"|email = \"${ADMIN_EMAIL}\"|" \
  -e "s|password = \"changeme\"|password = \"${ADMIN_PASSWORD}\"|" \
  config.toml.example > config.toml

# config.proxy.toml: no operator inputs - just copy.
cp config.proxy.toml.example config.proxy.toml

# Caddyfile: pick the flavor and stamp the hostname + (LE) email.
BYO_NOTICE=0
case "$TLS_CHOICE" in
  2)
    sed \
      -e "s|^example.com {|${DOMAIN} {|" \
      Caddyfile.byo.example > Caddyfile
    mkdir -p certs
    BYO_NOTICE=1
    ;;
  *)
    sed \
      -e "s|admin@example.com|${ADMIN_EMAIL}|" \
      -e "s|^example.com {|${DOMAIN} {|" \
      Caddyfile.letsencrypt.example > Caddyfile
    ;;
esac

chmod 600 .env config.toml   # contain secrets

# --- summary ---

echo
echo "${G}done${N} - configuration written to .env, config.toml, config.proxy.toml, Caddyfile"
echo
echo "Domain:   https://${DOMAIN}"
echo "Admin:    ${ADMIN_EMAIL}"
if [ "$AUTO_PW" = "1" ]; then
  echo "${Y}Admin password (auto-generated): ${ADMIN_PASSWORD}${N}"
  echo "${Y}Save this somewhere safe - it won't be shown again.${N}"
fi
if [ "$BYO_NOTICE" = "1" ]; then
  echo
  echo "${Y}BYO-cert: place fullchain.pem and privkey.pem in ./certs/ before starting.${N}"
fi
echo
echo "Next:"
echo "  docker login -u ghostsecurityhq    # if you haven't already"
echo "  docker compose pull"
echo "  docker compose up -d"
