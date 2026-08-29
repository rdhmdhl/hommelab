#!/usr/bin/env bash
# Bring SABnzbd back after the node loses power, or after the Pi goes away.
#
# Why this exists
# ---------------
# SAB's /data is a Docker NFS volume (see docker-compose.yml), so Docker performs
# the mount at container start. On a cold boot dockerd starts seconds before WiFi
# has a DHCP lease, so that mount fails:
#
#   error while mounting volume '.../downloader_media/_data': network is unreachable
#
# That failure happens *before* the container process exists, so RestartCount stays
# 0 and `restart: unless-stopped` never engages -- Docker does not try again.
# Gluetun has no volume dependency and retries its tunnel internally, which is why
# the VPN comes back on its own and SAB stays dead until someone notices.
#
# Fixing the boot race alone would not be enough: on a whole-house outage the Pi is
# still booting too, so no amount of local ordering helps. This converges instead of
# racing -- it retries until the share is genuinely there.

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/home/reid/hommelab/downloader}"
NFS_HOST="${NFS_HOST:-192.168.1.42}"
NFS_PORT="${NFS_PORT:-2049}"

# Run under a systemd timer, so stdout is the journal.
log() { echo "$*"; }

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

if running sabnzbd; then
  exit 0
fi

# Probe the Pi before touching Docker. A genuinely-down Pi should cost one refused
# connection per tick, not a recreated container and a mount failure in the journal.
if ! timeout 5 bash -c "exec 3<>/dev/tcp/${NFS_HOST}/${NFS_PORT}" 2>/dev/null; then
  log "sabnzbd down; NFS ${NFS_HOST}:${NFS_PORT} unreachable -- waiting"
  exit 0
fi

log "sabnzbd down and NFS reachable -- starting"
cd "$COMPOSE_DIR"

# `up -d`, not `docker start`. Only `up` remounts the NFS volume fresh and honours
# `depends_on: vpn: service_healthy`. A bare `start` reuses the stale volume state
# and can also race the VPN -- SAB shares gluetun's netns, so starting it while the
# VPN container is down fails with "cannot join network namespace", which is the
# same unrecoverable class of failure as the mount error above.
docker compose up -d sabnzbd
