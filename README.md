# hommelab

Docker Compose configuration for a two-node home lab: media automation, photo backup, DNS, and
reverse proxying.

## Topology

```txt
Downloader node          ~~ WiFi ~~     Pi (192.168.1.42)      —— ethernet —— LAN
---------------                         -----------------
Gluetun (VPN)                           Sonarr, Radarr, Prowlarr
  └─ SABnzbd                            Jellyfin, Jellyseerr
                                        Immich (+ Postgres, Redis, ML)
                                        Pi-hole, Nginx Proxy Manager, Glance
                                        media drive attached directly
                                        NFS export: /data/media
```

The downloader node exists to keep usenet traffic behind the VPN. Everything else runs on the
Pi, which has the media drive attached and is on ethernet.

**The WiFi link between the two nodes is the performance bottleneck for the media pipeline.**
See [downloader/plan.md](downloader/plan.md).

## Layout

| Path | What it is | Runs on |
| --- | --- | --- |
| `downloader/` | Gluetun + SABnzbd | downloader node |
| `services/` | Sonarr, Radarr, Prowlarr, Jellyfin, Jellyseerr, Immich, Pi-hole, NPM, Glance | Pi |
| `immich/` | standalone Immich compose | Pi |

Each directory is its own Compose project — deploy from within it:

```bash
cd services && docker compose up -d
```

## Path contract

Every host uses the same physical share at the same host path, and every container sees it at
the same container path:

```txt
host (both nodes):  /data/media
containers:         /data
```

**Never** let two machines use the same container path while pointing at different physical
disks. Doing so produced a silent outage where SAB completed downloads that Sonarr could not
see — it is the single most important rule in this repo.

> Known deviation: `services/docker-compose.yml` mounts the share into Jellyfin at `/media`.
> Tracked in [downloader/plan.md](downloader/plan.md).

## Ports

| Service | Port | Node |
| --- | --- | --- |
| Nginx Proxy Manager | 80 / 443, 81 admin | Pi |
| Glance | 8080 | Pi |
| Jellyfin | 8096 | Pi |
| Sonarr | 8989 | Pi |
| Radarr | 7878 | Pi |
| Prowlarr | 9696 | Pi |
| Jellyseerr | 5055 | Pi |
| Immich | 2283 | Pi |
| Pi-hole | 8888 (UI), 53 | Pi |
| SABnzbd | 8888 → 8080 via Gluetun | downloader |

SABnzbd is published through Gluetun's port mapping because it shares the VPN network
namespace. The 8888 collision with Pi-hole is fine only because they are on different hosts.

## Secrets

`.env` files are gitignored, as are all runtime volumes and container state — see
`.gitignore`. Nothing in this repo should contain credentials, API keys, or VPN config.

## Documentation

- [downloader/plan.md](downloader/plan.md) — reliability and speed plan for the download
  pipeline: NFS mount strategy, local scratch, SAB tuning, VPN/DNS, health monitoring, and the
  incident that motivated it.

## Health check

```bash
# both nodes
findmnt -t nfs4 /data/media
docker compose ps

# downloader
docker exec sabnzbd sh -c 'ls -lah /data'
docker logs --tail=50 vpn
```

If `/data` is empty inside SABnzbd, the share is not mounted correctly — stop and fix it before
letting downloads run. See `downloader/plan.md`.
