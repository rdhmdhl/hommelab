# Downloader Node Hardening Plan

This is the plan to harden the downloader node so it does not silently drift into a half-broken state again.

## What broke

Two different failures stacked on top of each other:

1. **Gluetun DNS instability**
   - SAB reported `server name does not resolve`
   - Gluetun logs showed DNS lookup timeouts and TLS resets to `1.1.1.1:853`
   - Root cause: DNS-over-TLS in Gluetun was flaky

2. **Cross-node storage mismatch**
   - Downloader wrote to local `/data/media`
   - Sonarr/Jellyfin on the Pi used the real shared `/data/media`
   - Same path name inside containers, different physical storage
   - SAB completed downloads, but Sonarr could not import them

3. **Stale Docker bind mount**
   - After fixing the host mount, SAB still saw an empty `/data`
   - Recreating the container fixed it
   - Restart was not enough

---

## Hardening goals

The downloader should:

- always mount the shared media path at `/data/media`
- never start SAB unless `/data/media` is a real mounted share
- stop SAB if the mount disappears
- use stable DNS in Gluetun
- notify Jellyfin through Sonarr/Radarr instead of relying on filesystem watching
- make troubleshooting fast and obvious

---

## 1. Keep the shared mount path fixed

### Correct `fstab`

The downloader must mount the Pi export at `/data/media`, not `/media`.

Use this on the downloader:

```fstab
192.168.1.42:/data/media  /data/media  nfs4  defaults,_netdev,nofail,x-systemd.automount  0  0
```

### Why

- Docker Compose maps `/data/media` into SAB as `/data`
- Sonarr and Jellyfin also use `/data/media`
- if downloader mounts the share anywhere else, the whole handoff breaks

### Apply changes

```bash
sudo systemctl daemon-reload
sudo mkdir -p /data/media
sudo mount -a
findmnt /data/media
```

Expected result:

```bash
/data/media  192.168.1.42:/data/media  nfs4 ...
```

---

## 2. Never start SAB unless the mount is real

This is the single best guardrail.

If `/data/media` is missing, SAB should not be allowed to download to a fake local directory.

### Start script

Create:

`~/hommelab/downloader/start-downloader.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

MOUNTPOINT="/data/media"
COMPOSE_DIR="$HOME/hommelab/downloader"

if ! mountpoint -q "$MOUNTPOINT"; then
  echo "ERROR: $MOUNTPOINT is not mounted"
  exit 1
fi

echo "OK: $MOUNTPOINT is mounted"

cd "$COMPOSE_DIR"
docker compose up -d vpn
sleep 5
docker compose up -d sabnzbd
```

Make executable:

```bash
chmod +x ~/hommelab/downloader/start-downloader.sh
```

Use this instead of raw `docker compose up -d`.

---

## 3. Stop SAB if the NFS mount disappears

Better to fail loudly than silently write to the wrong disk.

### Watchdog script

Create:

`/usr/local/bin/downloader-mount-watchdog.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

MOUNTPOINT="/data/media"
LOGFILE="/var/log/downloader-mount-watchdog.log"

if ! mountpoint -q "$MOUNTPOINT"; then
  echo "$(date): $MOUNTPOINT is not mounted; stopping sabnzbd" >> "$LOGFILE"
  docker stop sabnzbd >/dev/null 2>&1 || true
fi
```

Make executable:

```bash
sudo chmod +x /usr/local/bin/downloader-mount-watchdog.sh
```

### Cron version

Add to root crontab:

```bash
sudo crontab -e
```

Add:

```cron
*/2 * * * * /usr/local/bin/downloader-mount-watchdog.sh
```

That checks every 2 minutes.

---

## 4. Recreate SAB after mount changes

If the host mount changes, **restart is not enough**. Recreate the container.

This was proven during debugging: SAB kept an empty stale `/data` until the container was recreated.

### Rule

Whenever `/data/media` changes, or after NFS comes back:

```bash
cd ~/hommelab/downloader
docker compose stop sabnzbd
docker rm sabnzbd
docker compose up -d sabnzbd
```

### Why

Docker bind mounts can hold a stale view after the host mount changes underneath them.

---

## 5. Keep Gluetun DNS simple

The DNS-over-TLS setup caused the original `server name does not resolve` problem.

### Use this in `docker-compose.yml`

```yaml
services:
  vpn:
    image: qmcgaw/gluetun
    container_name: vpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    ports:
      - 8888:8080
    env_file:
      - .env
    environment:
      - DOT=off
      - DNS_ADDRESS=1.1.1.1
      - DNS_ADDRESS=8.8.8.8
    volumes:
      - ./config/gluetun:/gluetun
    restart: unless-stopped
```

### Why

This removes the flaky DNS-over-TLS layer and uses simple plaintext resolvers.

---

## 6. Start services in the right order

SAB depends on Gluetun’s network namespace.

If both come up too quickly together, SAB can fail with namespace errors.

### Compose

Keep this in SAB:

```yaml
depends_on:
  vpn:
    condition: service_healthy
network_mode: service:vpn
```

### If manual startup is needed

```bash
docker compose up -d vpn
docker compose up -d sabnzbd
```

---

## 7. Verify the real container view, not just the host

The host can look healthy while the container is stale.

### Quick checks

#### Host
```bash
findmnt /data/media
ls -lah /data/media/downloads
```

#### SAB container
```bash
docker exec -it sabnzbd sh -c 'ls -lah /data && find /data -maxdepth 2 -type d | sort'
```

Expected directories inside SAB:

- `/data/downloads`
- `/data/downloads/complete`
- `/data/downloads/incomplete`
- `/data/tv`
- `/data/movies`

If `/data` is empty inside SAB, recreate the container.

---

## 8. Make Sonarr/Radarr notify Jellyfin directly

Jellyfin should not rely on filesystem watchers alone, especially with network/shared storage.

### Why

Real-time monitoring is unreliable on:
- NFS
- SMB/FUSE-ish storage
- files imported by another service/container

### Set up in Sonarr and Radarr

Add a Jellyfin connection using:

- Host: `192.168.1.42`
- Port: `8096`
- SSL: off
- API key: Jellyfin API key

### Result

When Sonarr/Radarr import media, they tell Jellyfin directly to refresh.

This avoids the “Scan all libraries” annoyance.

---

## 9. Keep one path contract across all nodes

This is the key rule.

Every box that participates in the pipeline should treat the same shared storage as:

```bash
/data/media
```

And inside the containers:

```bash
/data
```

That means:

- downloader host: `/data/media`
- Pi host: `/data/media`
- SAB container: `/data`
- Sonarr container: `/data`
- Radarr container: `/data`
- Jellyfin container: `/data`

### Never allow this again

Do **not** let two machines use the same container path name while pointing to different physical disks.

That was the real killer.

---

## 10. Add a quick health checklist

When something feels off, run these first.

### Downloader host
```bash
findmnt /data/media
docker logs --tail=50 vpn
docker exec -it sabnzbd sh -c 'find /data -maxdepth 2 -type d | sort'
```

### Pi / media host
```bash
findmnt /data/media
docker exec -it sonarr find /data/downloads/complete -maxdepth 2 -iname "*SomeTitle*" 2>/dev/null
docker exec -it jellyfin ls -lah /data/tv
```

---

## 11. Optional improvements

### A. Use a dedicated mountpoint like `/mnt/media-nfs`
This can reduce ambiguity versus `/data/media`.

But if everything is already standardized on `/data/media`, it may not be worth changing.

### B. Send notifications when the mount is missing
Examples:
- ntfy
- Discord webhook
- email
- simple log file + grep

### C. Add a systemd service for downloader startup
This would be cleaner than manually running Docker commands.

### D. Consider moving SAB onto the Pi
Simpler architecture:
- fewer moving parts
- no cross-node handoff
- no NFS dependency for completed downloads

Only do this if you do not care about keeping the VPN isolated on the downloader node.

---

## 12. Summary of actual root cause

If I had to diagnose the incident in one sentence:

> The downloader node came back in a split-brain state: Gluetun DNS was unstable, and the downloader was no longer writing to the same shared `/data/media` storage used by Sonarr and Jellyfin.

More practically:

- DNS issue broke downloading
- mount/path mismatch broke import
- stale SAB bind mount hid the fix until the container was recreated

---

## 13. Minimum hardening checklist

If nothing else gets done, do these:

- [x] mount NFS at `/data/media`
- [x] keep `x-systemd.automount` in `fstab`
- [x] disable Gluetun DoT and use stable DNS
- [ ] only start SAB after `mountpoint -q /data/media` passes
- [ ] stop SAB automatically if the mount disappears
- [ ] recreate SAB after any mount change
- [x] configure Sonarr → Jellyfin
- [x] configure Radarr → Jellyfin

That gets most of the value.

---

## 14. Commands worth keeping handy

### Validate NFS mount
```bash
findmnt /data/media
```

### Validate SAB sees the real share
```bash
docker exec -it sabnzbd sh -c 'ls -lah /data && find /data -maxdepth 2 -type d | sort'
```

### Recreate SAB after mount changes
```bash
cd ~/hommelab/downloader
docker compose stop sabnzbd
docker rm sabnzbd
docker compose up -d sabnzbd
```

### Check Gluetun health
```bash
docker logs --tail=100 vpn
```

### Check Sonarr sees completed downloads
```bash
docker exec -it sonarr find /data/downloads/complete -maxdepth 2 -iname "*Title*" 2>/dev/null
```

---

This plan is designed to make the downloader fail safely instead of silently doing the wrong thing.

