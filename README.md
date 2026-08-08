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

## Network

| Node | Address | How |
| --- | --- | --- |
| Pi (`hommelab`) | `192.168.1.42` | static, **plus** a DHCP lease |
| downloader (`downloader`) | `192.168.1.127` | DHCP over WiFi |
| router (Spectrum SAX1V1K) | `192.168.1.1` | — |

The Pi holds a static address *and* a normal DHCP lease at the same time:

```bash
sudo nmcli connection modify netplan-eth0 +ipv4.addresses 192.168.1.42/24
```

The `+` appends rather than replaces, so `ipv4.method` stays `auto`. This is deliberate — a
pure static address would leave the Pi unreachable on any network using a different subnet,
recoverable only with a monitor and keyboard. With both, the DHCP lease always gets you in and
`.42` stays stable for every hardcoded reference in this repo.

Config is written by NetworkManager into `/etc/netplan/90-NM-<uuid>.yaml`. Despite the netplan
filenames, **`nmcli` is the right tool here** — NM owns those files and edits persist.

### Router

The Spectrum SAX1V1K exposes **no DHCP reservation UI**. `http://192.168.1.1` is a status page
only; everything else is in the My Spectrum app, which does not offer reservations. Hence the
host-side static address above.

### WiFi

The downloader has no ethernet port (it is an Intel Mac running Ubuntu Server), so it joins over
WiFi. The SSID is **`DebugDepature`** — misspelled, missing an `r`. Its netplan config is
`/etc/netplan/50-cloud-init.yaml`; wpa_supplicant silently matches nothing if the SSID is off by
a character, with no error in any log.

## Measured performance

Baseline as of 2026-08-07:

| Path | Throughput |
| --- | --- |
| Pi local disk (`/data/media`, ntfs-3g) | 73 MB/s |
| WiFi downloader → Pi (`iperf3`) | 20 MB/s (162 Mbit/s) |

WiFi is the bottleneck at ~3.6x slower than the storage behind it, despite negotiating 5 GHz at
-56 dBm and 450/702 Mbit. A **USB-ethernet adapter for the downloader is the single largest
available speed improvement.** See [downloader/plan.md](downloader/plan.md).

`/data/media` is NTFS via ntfs-3g (FUSE). Slower than ext4 in principle, but not the constraint
here, and hardlinks are confirmed working — which is what lets Sonarr/Radarr import for free.

## Nice URLs

Nginx Proxy Manager serves `*.hommelab.local`, with Pi-hole providing the DNS records:

```
sonarr · radarr · prowlarr · jellyfin · jellyseerr · immich · pihole · sab
```

`sab.hommelab.local` proxies across to the downloader at `192.168.1.127:8888`; the rest are on
the Pi.

**These only resolve for clients using Pi-hole as their DNS server.** The router currently hands
out itself (`192.168.1.1`), so each device needs Pi-hole set manually until that changes:

```bash
sudo networksetup -setdnsservers Wi-Fi 192.168.1.42     # macOS; "Empty" to undo
```

Where the config lives — neither is in git, both are on the Pi:

| What | Path |
| --- | --- |
| Pi-hole DNS records | `services/etc-pihole/pihole.toml`, `dns.hosts` array |
| NPM proxy hosts | `services/npm/data/nginx/proxy_host/*.conf` (generated from `database.sqlite`) |

Pi-hole is v6, so records live in `pihole.toml` rather than the older `custom.list`. Editing the
toml requires `docker restart pihole` to take effect.

> Known gap: NPM points at `192.168.1.40` (the Pi's DHCP lease) for its backends rather than
> `.42` or, better, Docker container names — NPM shares a network with those containers, as the
> `pihole` entry already demonstrates.

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
