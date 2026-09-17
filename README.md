# ghost-agent-docker

Self-hosted deployment of the Ghost Agent Platform via `docker compose`.

The stack runs the gateway, credential proxy, worker fleet, in-stack
updater, MongoDB, and a Caddy reverse proxy as docker containers on
a single host.

## Requirements

- **Host**: Linux with a public IPv4 and SSH access. Reference sizing:
  4 GB RAM / 2 vCPUs / 120 GB disk, Ubuntu 24.04 (LTS) x64.
- **Docker**: Engine 24+ with the `docker compose` v5.x plugin. The
  major must be v5.x because in-stack upgrades run Compose v5.x and
  the host's plugin must match; `setup.sh` checks and refuses to run
  otherwise. Install step 2 below has a pinned plugin install - do
  **not** use Ubuntu's `docker-compose-v2` package, which ships a
  different major.
- **Docker Hub access token** (OAT), issued by Ghost during onboarding.
- **Outbound HTTPS** to `docker.io` (and its Cloudflare-backed CDN at
  `production.cloudflare.docker.com`) for image pulls, and to
  `github.com` / `objects.githubusercontent.com` for the compose
  plugin download.
- **TLS**, one of:
  - **Automatic Let's Encrypt** (most common): ports 80/443 reachable
    from the internet. No domain required - the install defaults to
    `<dashed-public-ip>.nip.io` (e.g. `203-0-113-45.nip.io`), which
    resolves to that IP and works fine with Let's Encrypt.
  - **Bring your own cert**: an existing TLS cert + private key plus
    DNS pointing at this host. Required when DNS is private, the host
    can't accept inbound traffic from the LE servers, or your org
    uses an internal CA.
- **Deploy directory must be `/opt/exo`.** In-stack upgrades run
  `docker compose` with the project directory fixed at `/opt/exo`, so
  the compose file's relative bind mounts (`./config.toml`,
  `./Caddyfile`, ...) must resolve there on the host; `setup.sh`
  refuses to run anywhere else.

## Install

### 1. Get this repo onto the host

Clone into `/opt/exo`:

```bash
git clone https://github.com/ghostsecurity/ghost-agent-docker.git /opt/exo
cd /opt/exo
```

Or, if you don't want to install git on the host, copy a local clone
with `rsync`:

```bash
rsync -avz -e "ssh -i ~/.ssh/<ssh-key>" \
  ~/Path/to/cloned/ghost-agent-docker/ \
  root@<instance-ip>:/opt/exo/
```

### 2. Install Docker and the Compose plugin

On a stock Ubuntu image:

```bash
apt-get update
apt-get install -y docker.io curl

COMPOSE_VERSION=v5.1.3
COMPOSE_SHA256=a0298760c9772d2c06888fc8703a487c94c3c3b0134adeef830742a2fc7647b4
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
echo "${COMPOSE_SHA256}  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c -
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

### 3. Authenticate to Docker Hub

Run as the same user that will run `docker compose`:

```bash
docker login -u ghostsecurityhq
# paste the OAT when prompted
```

The host login is needed for the initial `docker compose pull` (step 5)
and any manual pulls you run from the shell later. The in-stack updater
authenticates itself separately at container start using the OAT in
`.env`.

### 4. Bootstrap the host

Run the interactive script:

```bash
cd /opt/exo
./setup.sh
```

It prompts for the Docker Hub OAT, then resolves the newest published
release and offers it as the default tag (type a specific `vX.Y.Z` to
pin instead). It generates the one-time **claim token** (printed at the
end - save it), fetches the release's stack bundle (`docker-compose.yml`
plus the static config defaults), and copies the defaults into place.
It refuses to overwrite existing config files - delete them and re-run
to regenerate.

Everything else - the admin account, public domain, TLS - is
configured afterwards in the in-product setup wizard. There are no
secrets to generate or config files to edit by hand: the platform
self-generates its internal secrets on first boot and rewrites the
managed parts of `.env` and the `Caddyfile` when settings change.

![setup.sh prompts](docs/setup-screenshot.png)

### 5. Pull and start

```bash
docker compose pull
docker compose up -d
```

The first `up` takes a minute or two: MongoDB initializes its replica
set, the credential proxy generates its CA and encryption key, and the
UI bundle is copied into the shared volume. The edge proxy serves the
`nip.io` bring-up hostname with a real Let's Encrypt certificate;
bare-IP access falls back to a temporary self-signed certificate.

### 6. Run the setup wizard

Open the `nip.io` URL setup.sh printed in a browser (no certificate
warning; browsing by bare IP instead shows a one-time self-signed
warning). Enter the claim token, create the admin account, and set the domain
and TLS mode (Let's Encrypt or a custom certificate upload). The stack
applies the configuration - the affected services restart briefly -
and the instance comes up at the configured domain with a real
certificate.

Lost the claim token before claiming? Rotate it from the host:

```bash
exo-reissue-claim-token
```

The token is single-use: once setup completes it is inert, and the
claim endpoints are permanently disabled.

Domain, TLS, worker count, and connector tokens can all be changed
later under System → Settings.

## Upgrade

The in-stack updater polls Docker Hub every 10 minutes for new release
tags. When a newer `vX.Y.Z` is available, the "Upgrade" button in the
UI's System view lights up; click it to upgrade the running stack in
place - including the updater's own image, which is recreated by a
detached helper at the tail of the upgrade and rolled back
automatically if the new container doesn't come healthy. A release can
add, remove, or reconfigure containers - not just bump image tags -
and each upgrade overwrites the local `docker-compose.yml` with the
release's, so don't edit it in place.

To upgrade out of band:

```bash
sed -i 's/^TAG=.*/TAG=vX.Y.Z/' .env
docker compose pull
docker compose up -d
```

## Logs

```bash
docker compose logs -f --tail=100 gateway
docker compose logs -f --tail=100 credential-proxy
docker compose logs -f --tail=100 exo-updater
docker compose logs -f --tail=100 worker
```

## Backup and restore

`backup.sh` takes an **online, zero-downtime** backup of everything
needed to rebuild the deployment - no stop, no write-blocking:

- MongoDB via `mongodump --oplog` (a consistent point-in-time online dump)
- the other named volumes (TLS CA private keys, runner identities, Caddy
  certs, artifacts) via a read-only live tar
- the runtime config (`.env`, `config.toml`, `config.proxy.toml`,
  `Caddyfile`, `certs/`) and the resolved `docker-compose.yml`

```bash
cd /opt/exo
./backup.sh                 # -> ./backups/<timestamp>
./backup.sh --out=/mnt/bkp  # write under a different directory
```

The stack keeps serving throughout. The archive includes `.env` and
the `tls` volume, which together carry the credential-wrapping key and
session-signing secret (`encryption.key` / `jwt.secret` on the volume
for platform-generated secrets, or `.env` values where the operator
supplied them). Those are what make a restore usable - stored
credentials and sessions are unrecoverable without them. Because it
contains secrets, **store the backup securely and off the host**.

`restore.sh` rebuilds from a backup - for rolling an instance back, or
for moving to a fresh host. It is destructive: it replaces the current
volumes and config with the backup's, brings the database up on a fresh
volume, and replays the dump into it.

```bash
docker login -u ghostsecurityhq   # so images for the backed-up tag can be pulled
cd /opt/exo
./restore.sh ./backups/<timestamp>
```

On a fresh host, clone this repo to `/opt/exo` and run `restore.sh`
directly - do **not** run `setup.sh` first (it would mint new secrets;
the restore brings back the original `.env`). Verify with
`docker compose ps` afterward.

## Common adjustments

| Goal | Where |
| --- | --- |
| Change domain / TLS / worker count / Slack tokens | System → Settings in the UI |
| Run a second worker pool on its own image (a slimmer base, extra tools) | System → Instance settings → Workers in the UI (see below) |
| Install a tool the shipped worker image lacks | System → Worker add-ons in the UI, then add it to a pool (see below) |
| Bump the updater image only | `UPDATER_TAG` in `.env`, then `docker compose up -d exo-updater` |
| Run behind an existing reverse proxy | Switch the Caddyfile to plain HTTP on another host port (see below) |
| Use named volumes on a specific disk | Configure Docker volume storage out of band (see below) |
| Switch the registry | `REGISTRY` in `.env` (must mirror the `ghostsecurityhq/exo-*` layout) |
| Cap container log size, auto-prune old images, block pool image builds from cloud metadata | Optional final step in `setup.sh` (see below) |

**Worker pools and add-ons**: besides the default worker fleet, up to
three more pools can run on images the updater builds on this host:
a published base (the full image or the slim one) plus add-ons from
the release catalog and any custom add-ons you define. Nothing is
pushed to a registry; the build runs on the host's Docker daemon, so it
needs outbound access to Ubuntu's package archives and to wherever the
add-ons download from (GitHub releases, npm). Builds keep one previous
image per pool and cap their build cache, and refuse to start with less
than 15 GB free on Docker's data root. The updater keeps its build
files in `/opt/exo`: `worker-addons/` (the release catalog, replaced on
every upgrade), `worker-images/pool-<n>/` (each pool's rendered
Dockerfile and build log), `.worker-images.json`, and `.buildx/`. Leave
them alone; `worker-images/pool-<n>/build.log` is the place to look
when a build fails. Pool settings and add-on recipes live in the
database and are covered by `backup.sh`.

Because the build runs on the host daemon, each install step runs in a
container on Docker's default bridge with the host's outbound network,
not through the credential proxy. On a cloud VM that path also reaches
the instance metadata service at `169.254.169.254`, and with it the
VM's cloud identity. The host tuning step in `setup.sh` installs
`exo-block-build-metadata.service`, which drops that traffic for the
default bridge only (the stack's containers use compose networks and
are unaffected) and re-applies the rule after every Docker restart. If
you skipped host tuning, re-run `setup.sh` or add the rule to your own
firewall management:

```
iptables -I DOCKER-USER -i docker0 -d 169.254.169.254 -j DROP
ip6tables -I DOCKER-USER -i docker0 -d fd00:ec2::254 -j DROP
```

The second line matters only on an EC2 instance with IMDS over IPv6
enabled and IPv6 turned on in Docker; other clouds serve metadata on
the IPv4 address alone. On a server with no metadata service both rules
are harmless.

**Existing reverse proxy**: keep Caddy in the stack - it serves the
static UI bundle as well as proxying the API. Switch its Caddyfile to
plain HTTP on a different host port, then point your external proxy at
that port.

**Volume placement**: the `docker-compose.yml` is fetched from the
release bundle and overwritten on every upgrade, so don't edit it in
place. Configure the Docker volume's storage out of band instead (e.g.
a `local` volume `driver_opts` device, or relocating `/var/lib/docker`).

**Log caps and image pruning**: the optional `setup.sh` step caps each
container's logs at 10MB x 3 rotation (`json-file` driver) and installs
a daily systemd timer running `docker image prune -a --filter until=168h`.
Answer 'n' at the prompt to skip.

## Tearing down

```bash
docker compose down            # stop containers, keep volumes
docker compose down -v         # also delete volumes (DESTRUCTIVE)
```

`down -v` removes the MongoDB data volume, Caddy's cert state, the
credential proxy's CA material, and all runner identities. Treat it
like dropping a database - everything has to be reseeded/recreated after.
