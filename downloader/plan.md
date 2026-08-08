# Downloader Node Plan

One document covering reliability and speed for the downloader node (Gluetun + SABnzbd),
and its handoff to the Pi (Sonarr / Radarr / Jellyfin).

These two goals are not separate. The change that makes downloads fast — moving SAB's
scratch work onto local disk — is also the change that shrinks how much of the pipeline
depends on NFS being healthy. Do them together.

---

## Background: what broke

Three failures stacked:

1. **Gluetun DNS instability.** SAB reported `server name does not resolve`; Gluetun logs
   showed lookup timeouts and TLS resets to `1.1.1.1:853`. DNS-over-TLS was flaky.
2. **Cross-node storage mismatch.** The downloader wrote to a *local* `/data/media` while
   Sonarr/Jellyfin on the Pi used the real shared `/data/media`. Same container path, different
   physical disk. SAB completed jobs that Sonarr could never import.
3. **Stale Docker bind mount.** After the host mount was fixed, SAB still saw an empty `/data`.
   A restart was not enough — the container had to be recreated.

One sentence: *the downloader came back split-brain — DNS broke downloading, and a path/mount
mismatch broke importing, with a stale bind mount hiding the fix.*

Failure 2 is the dangerous one, because it fails **silently**. Everything below is oriented
around making that specific failure impossible rather than merely detectable.

---

## Target architecture

```txt
Downloader node          ~~ WiFi ~~     Pi (192.168.1.42)      —— ethernet —— LAN
---------------                         -----------------
Gluetun (VPN)                           Sonarr / Radarr
  └─ SABnzbd (shares netns)             Jellyfin
                                        media drive attached directly
local disk:                             NFS export: /data/media
  /home/reid/sab-downloads/incomplete
  ← all scratch, unpack, PAR2 repair     ← final move lands here:
                                         /data/media/downloads/complete
NFS from Pi:
  /data/media
```

**The link between the two nodes is WiFi. It is the bottleneck for everything in this
document.** The Pi is on ethernet with the drive attached locally, so the Pi side of the path
is fast; every byte that crosses the gap is paying WiFi's bandwidth *and* its latency.

SAB does every expensive operation on local disk and touches NFS exactly once per job:
the final move of the finished release.

### Path contract

Every host that participates uses the same physical share at the same host path, and every
container sees it at the same container path.

| Host | Host path | Container | Container path |
| --- | --- | --- | --- |
| downloader | `/data/media` | sabnzbd | `/data` |
| Pi | `/data/media` | sonarr | `/data` |
| Pi | `/data/media` | radarr | `/data` |
| Pi | `/data/media` | jellyfin | `/data` |

**Never** let two machines use the same container path while pointing at different physical
disks. That was the actual killer.

> Currently `services/docker-compose.yml` mounts the share into Jellyfin at `/media`, not
> `/data`. Harmless today because Jellyfin only reads, but it breaks the contract — and the
> contract is only useful if it is uniform. Change it and re-point the Jellyfin libraries.

---

## Phase 1 — Make the wrong-disk failure impossible

### Why the obvious guard does not work

The instinctive fix is a startup check:

```bash
mountpoint -q /data/media || exit 1     # DO NOT RELY ON THIS
```

It does not do what it looks like. With `x-systemd.automount` in `fstab`, `/data/media` is an
**autofs** mountpoint before the NFS mount ever happens, and `mountpoint -q` returns success
against autofs. If the Pi is down, the check passes, SAB starts, and you are back in the exact
silent-wrong-disk state — with a guard that reported OK.

### The real fix: let Docker own the NFS mount

The root cause of both the wrong-disk write and the stale `/data` is that
`- /data/media:/data` is a host bind mount. Docker auto-creates an empty local directory when
the share is missing, and it caches its view of the host mount.

Hand the mount to Docker instead. In `downloader/docker-compose.yml`:

```yaml
volumes:
  media:
    driver: local
    driver_opts:
      type: nfs
      o: "addr=192.168.1.42,nfsvers=4,hard,timeo=600,retrans=2"
      device: ":/data/media"
```

```yaml
  sabnzbd:
    volumes:
      - ./config/sabnzbd:/config
      - media:/data                      # was: /data/media:/data
      - /home/reid/sab-downloads:/downloads
```

What this buys:

- **Fails closed.** If the Pi is unreachable, the container *fails to start*. It cannot fall
  back to a local directory, because there is no local directory to fall back to.
- **Never stale.** Docker performs the mount at container start, so every start gets a fresh
  view. The "recreate SAB after a mount change" ritual goes away.
- **No bash guard, no cron guard.** The runtime enforces the invariant instead of a script that
  can be skipped, or that can pass against autofs.

`hard` is deliberate: if the Pi disappears mid-write, I/O blocks until it returns rather than
erroring out and risking a truncated file. Combined with local scratch (Phase 2), the only
thing that can block is the final move, which is safe to stall.

Keep the `fstab` entry as well — it is useful for shell access and for Phase 2 verification —
but SAB no longer depends on it:

```fstab
192.168.1.42:/data/media  /data/media  nfs4  defaults,_netdev,nofail,x-systemd.automount  0  0
```

```bash
sudo systemctl daemon-reload
sudo mkdir -p /data/media
sudo mount -a
findmnt /data/media
```

### Migration

Recreating is required — a volume definition change is not picked up by a restart.

```bash
cd ~/hommelab/downloader
docker compose down
docker compose up -d
docker exec sabnzbd sh -c 'ls -lah /data'
```

If `/data` is empty inside the container, stop and fix the mount before letting SAB run.

---

## Phase 2 — Local scratch (the main speed win)

SAB is currently unpacking directly on the NFS share, so every expensive step crosses WiFi.

### The byte math

For a release of size N:

**Today — scratch on NFS**

| Step | Crosses WiFi |
| --- | --- |
| Download from usenet | N in |
| SAB writes RAR parts to the share | N out |
| PAR2 verify reads them back | N in |
| Unrar reads the parts | N in |
| Unrar writes extracted files | N out |
| Temp deletes, renames, cleanup | small, but many round trips |

**≈ 5N over WiFi.** Worse, most of it is small, latency-sensitive, synchronous NFS operations.
NFS over WiFi degrades on *latency*, not bandwidth — every op costs a round trip on a lossy,
half-duplex, shared medium. PAR2 repair and many-small-file extraction are the two worst
possible workloads to run this way.

**With local scratch**

| Step | Crosses WiFi |
| --- | --- |
| Download from usenet | N in |
| Write, PAR2 verify, unrar — all local disk | **zero** |
| Final move of the finished release | N out |

**≈ 2N**, and the N that remains is a single sequential large-file stream — the one workload
WiFi handles well.

### This speeds up the download itself, not just post-processing

WiFi is half-duplex and shared. While SAB unpacks over NFS, that read/write traffic contends
with the usenet download for the same radio. Your download speed is currently being throttled
by your own post-processing.

Move scratch local and downloads get the link to themselves. This is the main reason to do
Phase 2, and it is why it belongs ahead of most of the SAB tuning in Phase 3.

### Host setup

```bash
mkdir -p /home/reid/sab-downloads/incomplete
df -h /home
```

### SAB folder settings

```txt
Temporary Download Folder:  /downloads/incomplete     (local disk)
Completed Download Folder:  /data/downloads/complete  (NFS, on the Pi)
```

Never point the temporary folder at the share.

### Trade-off to know about

Local → NFS is a **cross-device move**, so it is a full second copy of every completed release
over the network, not a rename. That is the `N out` row above — it does not disappear.

It is small next to going from 5N to 2N, and the limit on it is the **downloader's WiFi**, not
the Pi's ethernet or its disk. So the ceiling on completion time is your radio: measure actual
WiFi throughput between the nodes before chasing anything else.

```bash
# on the Pi
iperf3 -s
# on the downloader
iperf3 -c 192.168.1.42
```

Whatever that number is, it is your hard ceiling for both downloading and moving.

### Measured, 2026-08-07

| Path | Throughput |
| --- | --- |
| Pi local disk (`/data/media`, ntfs-3g, `dd` 2 GB) | 73 MB/s |
| WiFi downloader → Pi (`iperf3`, 10 s) | **20 MB/s** (162 Mbit/s) |

The link negotiates at 5 GHz, -56 dBm, 450/702 Mbit — which is flattering. Actual throughput
is 20 MB/s, roughly **3.6x slower than the storage behind it**. WiFi is the bottleneck, and
the storage layer does not need attention.

The run also showed **149 retransmits** and swings from 255 down to 49 Mbit/s inside ten
seconds. At -56 dBm that is interference, not range — there are 66 BSSes in scan range. The
instability matters as much as the average: a steady 162 would be easier to plan around.

What that means for a 20 GB release, counting only LAN traffic:

```txt
today (unpack over NFS, ~4N across the link)   ~80 GB   ≈ 66 min of network time
with local scratch (1N, final move only)       ~20 GB   ≈ 17 min
```

### Server-side: `async` export

The Pi's export in `/etc/exports` controls how NFS writes are acknowledged:

```txt
/data/media 192.168.1.0/24(rw,async,no_subtree_check,all_squash,anonuid=1000,anongid=1000,insecure)
```

With `sync`, the Pi must confirm every write is on physical disk before acknowledging it. The
client waits out a full disk round trip per operation. With `async` it acknowledges once the
data is in memory and flushes in the background.

Apply on the Pi:

```bash
sudo sed -i 's/,sync,/,async,/' /etc/exports
sudo exportfs -ra
sudo exportfs -v        # confirm async now appears
```

No client-side remount needed.

**The risk, stated plainly:** if the Pi loses power or hard-crashes mid-write, data acknowledged
but not yet flushed is lost — a file can end up truncated or corrupt. This is a real trade, not
a free win. It is acceptable here because the affected files are re-downloadable media, and
ext4's journal still protects filesystem *metadata*, so you risk recent file contents rather
than the library itself. It would not be an acceptable trade for the Immich photo store, which
is why that lives on a separate volume.

**How much it helps depends on where scratch lives**, and the answer is counterintuitive:

- *Today* (scratch on NFS) it helps a lot — the workload is thousands of small synchronous
  operations from PAR2 and unrar, which is the worst case for `sync`.
- *After Phase 2* it helps less — the only NFS traffic left is one large sequential stream,
  which is already WiFi-limited rather than round-trip-limited.

So this is worth doing immediately, and its benefit shrinks once local scratch lands. That is
fine — it costs one line and stays mildly useful either way.

Do not script the move. SAB already does `/downloads/incomplete → /data/downloads/complete`
correctly. Only script deletion of abandoned leftovers (below).

---

## Phase 3 — SAB settings

### Speed

| Setting | Value | Why |
| --- | --- | --- |
| Connections | your provider's max (usually 20–50) | Single largest factor in raw download speed. Check this first. |
| Direct Unpack | **ON** | Overlaps unpacking with downloading. This was a bad idea over NFS; on local scratch it is a clear win. |
| Pause Downloading During Post-Processing | **OFF** | Serializing the pipeline stops you pulling bytes while unpacking. It only earns its keep under disk pressure, which local scratch removes. Note the final move still shares the radio with active downloads — they split WiFi rather than one blocking the other, which is the outcome you want. |
| Article Cache Size | 1–2 GB | SAB defaults low; raising it cuts write amplification during assembly. |

Turn Direct Unpack on and post-processing pause off **only after** Phase 2 is in place. On NFS
scratch both of those settings are correct as-is.

If `/home` is genuinely tight, leave the pause ON and keep the queue modest — see operating
rules below.

### Correctness

```txt
Abort jobs that cannot be completed:          ON
Action when encrypted RAR is downloaded:      Abort
Identical download detection:                 Fail job (move to History)
Smart duplicate detection:                    Fail job (move to History)
```

`Fail job` beats silently discarding, because Sonarr can see the failed release and immediately
grab another one.

### Operating rules

Local scratch is finite, and peak usage per job is about **2.5x the release size** — SAB holds
the RAR set and the extracted output simultaneously, and the local copy is not freed until the
move to NFS completes. See the disk lifecycle section below.

```txt
1080p TV / movie      usually fine
Large 4K remuxes      risky
Whole season packs    risky
Many parallel jobs    risky
```

Check headroom against your largest expected release:

```bash
df -h /home
```

---

## Phase 4 — VPN and DNS

### DNS

DNS-over-TLS caused the original `server name does not resolve` outage. It is already disabled,
but the current config has a bug:

```yaml
- DNS_ADDRESS=1.1.1.1
- DNS_ADDRESS=8.8.8.8     # duplicate key — only this one survives
```

Compose keeps the last value for a duplicate key. It reads like a redundant pair; it is a
single resolver with no fallback. Since the original outage was DNS, that matters. Use one
explicit resolver:

```yaml
    environment:
      - DOT=off
      - DNS_ADDRESS=1.1.1.1
```

### Protocol

Check what Gluetun negotiated:

```bash
docker logs vpn | grep -i -E 'wireguard|openvpn'
```

If it is on OpenVPN, switching the provider config to **WireGuard** is frequently a 2–4x
throughput improvement on a modest node, and is the second-largest speed lever after connection
count.

### Startup ordering

Already correct in compose — do not add a `sleep`-based start script:

```yaml
    depends_on:
      vpn:
        condition: service_healthy
    network_mode: service:vpn
```

Gluetun ships a real healthcheck, so `service_healthy` is strictly better than
`up -d vpn; sleep 5; up -d sabnzbd`. Plain `docker compose up -d` is safe.

---

## Phase 5 — Push notifications to Jellyfin

Jellyfin's filesystem watchers are unreliable on NFS and for files written by another
container. Do not depend on them.

In **both** Sonarr and Radarr, add a Jellyfin connection:

```txt
Host:    192.168.1.42
Port:    8096
SSL:     off
API key: <Jellyfin API key>
```

On import, Sonarr/Radarr tell Jellyfin to refresh directly. No more "Scan all libraries".

---

## Monitoring

With Phase 1 in place, SAB cannot write to the wrong disk. The remaining risk is that it sits
**stopped** after an NFS blip without anyone noticing.

`/usr/local/bin/downloader-health.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/downloader-health.log"
log() { echo "$(date -Is): $*" >> "$LOGFILE"; }

# Verify the share is genuinely reachable, not merely an autofs stub.
if ! findmnt -t nfs4 --target /data/media >/dev/null 2>&1; then
  log "NFS not mounted at /data/media"
  exit 0
fi

# Confirm we are looking at the Pi's disk, not an empty local directory.
# Create this sentinel once, on the Pi: touch /data/media/.nfs-ok
if ! timeout 10 test -f /data/media/.nfs-ok; then
  log "/data/media reachable but sentinel missing — wrong disk or export problem"
  exit 0
fi

# Share is healthy; make sure SAB is actually running.
if [ "$(docker inspect -f '{{.State.Running}}' sabnzbd 2>/dev/null)" != "true" ]; then
  log "share healthy but sabnzbd is down; starting"
  cd /home/reid/hommelab/downloader && docker compose up -d sabnzbd
fi
```

```bash
sudo chmod +x /usr/local/bin/downloader-health.sh
sudo crontab -e
```

```cron
*/5 * * * * /usr/local/bin/downloader-health.sh
```

Two things this gets right that a naive watchdog does not:

- It checks the **filesystem type and a sentinel file**, so autofs and an empty local directory
  both fail the check.
- It **starts SAB back up**. A stop-only watchdog leaves the node dead after a 30-second blip,
  because `docker stop` overrides `restart: unless-stopped`.

Optional: pipe `log()` to ntfy or a Discord webhook so a stuck mount pages you instead of
sitting in a file.

---

## Disk lifecycle and cleanup

### Does the move leave a copy behind?

**No — not on success.** SAB performs a *move*, and because local scratch and the NFS share are
different filesystems, that move is a copy followed by a delete of the source. Once the job
completes, its folder is gone from `/downloads/incomplete`. There is no permanent duplicate.

Two caveats matter for disk planning:

**1. Both copies exist during the transfer.** The local copy is not released until the copy to
NFS finishes. On a WiFi link that window is not short — a 20 GB release at 200 Mbit is roughly
15 minutes with the local copy still on disk.

**2. Peak local usage is roughly 2N, not N.** Inside the job folder SAB holds the downloaded
RAR set *and* the extracted output at the same time, deleting the RARs only after a successful
unpack. So a 20 GB release transiently needs ~40 GB of scratch.

Budget local scratch at **2.5x your largest expected release**, plus headroom for anything else
running concurrently. This is the real constraint behind the operating rules in Phase 3.

### What actually accumulates

Failure paths, not the happy path:

| Leftover | Cause |
| --- | --- |
| `<job>/` | container killed, power loss, or SAB restart mid-job |
| `_UNPACK_<job>/` | unrar interrupted partway |
| `_FAILED_<job>/` | unpack or PAR2 repair failed |
| stale job folders | job deleted from the queue without "delete files" |
| `admin/` growth | SAB's job database and `.nzb` backups — small, leave it alone |

These never clear themselves, which is why the cleanup job exists.

### Cleanup script

The naive version — delete anything older than N days — can eat an active download, because a
directory's mtime does not change while files inside it are being written. This version asks
SAB what it is actually working on and refuses to touch those jobs.

`~/hommelab/downloader/cleanup-sab-scratch.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRATCH="/home/reid/sab-downloads/incomplete"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-3}"
SAB_URL="${SAB_URL:-http://127.0.0.1:8888}"
SAB_APIKEY="${SAB_APIKEY:-}"
DRY_RUN="${DRY_RUN:-0}"

[[ -n "$SCRATCH" && "$SCRATCH" != "/" ]] || { echo "Bad SCRATCH path"; exit 1; }
[[ -d "$SCRATCH" ]] || { echo "Scratch folder does not exist: $SCRATCH"; exit 0; }

# Ask SAB which jobs are live. Anything it names is off-limits regardless of age.
active=""
if [[ -n "$SAB_APIKEY" ]]; then
  if ! active=$(curl -fsS --max-time 10 \
        "$SAB_URL/api?mode=queue&output=json&apikey=$SAB_APIKEY" \
        | grep -o '"filename":"[^"]*"' | cut -d'"' -f4); then
    echo "ERROR: could not reach SAB API; refusing to delete anything" >&2
    exit 1
  fi
else
  echo "WARNING: SAB_APIKEY unset; falling back to age-only checks" >&2
fi

is_active() {
  local name="${1#_UNPACK_}"; name="${name#_FAILED_}"
  [[ -n "$active" ]] && grep -Fxq "$name" <<<"$active"
}

cutoff=$(( $(date +%s) - MAX_AGE_DAYS * 86400 ))
freed=0

while IFS= read -r -d '' item; do
  base=$(basename "$item")

  if is_active "$base"; then
    echo "SKIP (active in queue): $base"
    continue
  fi

  # Age is judged by the newest file *inside* the folder, since the folder's own
  # mtime does not update as files within it grow.
  newest=$(find "$item" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
  newest=${newest:-0}
  (( ${newest%.*} < cutoff )) || { echo "SKIP (recent): $base"; continue; }

  size=$(du -sm "$item" 2>/dev/null | cut -f1 || echo 0)
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "WOULD REMOVE: $base (${size} MB)"
  else
    echo "REMOVING: $base (${size} MB)"
    rm -rf -- "$item"
  fi
  freed=$(( freed + size ))
done < <(find "$SCRATCH" -mindepth 1 -maxdepth 1 -print0)

echo "Total: ${freed} MB $([[ "$DRY_RUN" == "1" ]] && echo 'would be freed' || echo 'freed')"
df -h "$SCRATCH" | tail -1
```

```bash
chmod +x ~/hommelab/downloader/cleanup-sab-scratch.sh
```

It **fails closed**: if the SAB API is unreachable it deletes nothing rather than guessing. Get
the API key from SAB under Config → General.

Dry run first:

```bash
DRY_RUN=1 SAB_APIKEY=<key> ~/hommelab/downloader/cleanup-sab-scratch.sh
```

Cron — keep the key out of the crontab line by sourcing it from a root-only file:

```cron
30 4 * * * . /home/reid/.sab-cleanup.env && /home/reid/hommelab/downloader/cleanup-sab-scratch.sh >> /home/reid/hommelab/downloader/cleanup-sab-scratch.log 2>&1
```

```bash
echo 'export SAB_APIKEY=<key>' > ~/.sab-cleanup.env && chmod 600 ~/.sab-cleanup.env
```

Simplest possible alternative, if you would rather not reason about active jobs at all:

```bash
docker stop sabnzbd && ~/hommelab/downloader/cleanup-sab-scratch.sh && docker start sabnzbd
```

### The other side: the completed folder on the Pi

Local scratch is the small disk, but `/data/media/downloads/complete` is where real space goes
if nothing prunes it — and **no script in this repo should do that job.**

Let Sonarr and Radarr handle it:

```txt
Settings → Download Clients → Completed Download Handling → Remove: Yes
```

This works cleanly here because `/data/downloads/complete` and `/data/tv` are on the *same*
filesystem, so Sonarr **hardlinks** the import rather than copying it. The library file and the
download are one set of blocks with two names; "removing" the download just drops one name and
frees nothing until both are gone. That gives you instant imports, no doubled space, and
automatic cleanup.

Verify hardlinking is actually happening — a link count of 2 means it worked:

```bash
docker exec sonarr sh -c 'stat -c "%h %n" /data/tv/SomeShow/Season\ 01/*.mkv | head'
```

If that reports `1`, Sonarr is copying instead of linking. Check that both paths are inside the
same mount and that permissions allow it, or imports will silently double your storage use.

---

## Verification

The host can look perfectly healthy while the container is wrong. Always check both.

### Host

```bash
findmnt -t nfs4 /data/media
test -f /data/media/.nfs-ok && echo "sentinel OK"
df -h /home                                   # local scratch headroom
```

### Inside SAB

```bash
docker exec sabnzbd sh -c 'ls -lah /data && find /data -maxdepth 2 -type d | sort'
docker exec sabnzbd sh -c 'ls -lah /downloads/incomplete'
```

Expect under `/data`: `downloads/complete`, `downloads/incomplete`, `tv`, `movies`.
Expect `/downloads/incomplete` to be on local disk and to have scratch in it while a job runs.

### VPN

```bash
docker logs --tail=100 vpn
docker exec sabnzbd sh -c 'nslookup news.example.com'      # DNS actually resolving
```

### Pi

```bash
findmnt /data/media
docker exec sonarr find /data/downloads/complete -maxdepth 2 -iname "*SomeTitle*" 2>/dev/null
docker exec jellyfin ls -lah /data/tv
```

---

## Checklist

**Reliability**

- [x] NFS mounted at `/data/media` on both nodes
- [x] `x-systemd.automount` + `nofail` in `fstab`
- [x] Gluetun DoT disabled
- [x] Sonarr → Jellyfin notification
- [x] Radarr → Jellyfin notification
- [x] SAB uses a Docker NFS volume, not a host bind mount *(fails closed; kills the stale-mount problem)*
- [x] Duplicate `DNS_ADDRESS` key removed from compose
- [ ] `.nfs-ok` sentinel created on the Pi
- [ ] Health script installed, checking `findmnt -t nfs4` + sentinel, and restarting SAB
- [ ] Jellyfin re-pointed from `/media` to `/data` for path-contract consistency

**Speed**

- [x] Baseline WiFi throughput measured with `iperf3` (20 MB/s — this is the ceiling)
- [x] NFS export switched from `sync` to `async` on the Pi
- [x] Local scratch at `/home/reid/sab-downloads/incomplete` *(5N → 2N over WiFi)*
- [x] SAB temp folder → `/downloads/incomplete`, complete folder → `/data/downloads/complete`
- [x] SAB connections set to 20 *(plenty for a 160 Mbit link)*
- [x] Article cache raised to 1 GB
- [x] Direct Unpack ON, post-processing pause OFF
- [x] Local disk sized at ≥2.5x largest expected release *(LVM extended 100G → 226G)*
- [x] Confirmed on 5 GHz, -56 dBm
- [ ] Gluetun on WireGuard (verify; switch if on OpenVPN)
- [ ] Queue-aware cleanup script + cron installed (dry-run verified first)
- [ ] Sonarr/Radarr "Remove Completed Downloads" ON, hardlinking confirmed via link count
- [ ] Downloader moved to ethernet via USB adapter *(highest leverage remaining: 20 → 73 MB/s)*

---

## Suggested order

0. `iperf3` between the nodes — establishes the ceiling everything else is measured against.
1. Duplicate `DNS_ADDRESS` fix and Gluetun protocol check — cheap, no downtime.
2. SAB connection count — one setting, large effect.
3. Local scratch (Phase 2) — the structural speed fix; takes WiFi traffic from ~5N to ~2N.
4. Docker NFS volume (Phase 1) — the structural reliability fix; needs a `compose down`.
5. Direct Unpack ON / pause OFF, article cache — safe once 3 is verified.
6. Sentinel, health script, cleanup cron.
7. Ethernet for the downloader, if it can be arranged — outranks everything above it, but is a
   physical job rather than a config change, so it runs on its own timeline.

Steps 1–3 are reversible and independently testable. Step 4 is the one that needs a window.
Re-run the step 0 measurement after step 3 to confirm the contention theory held.

---

## Bigger structural options

Everything above optimizes the current topology. These two change it, and both beat any
software tuning in this document.

### A. Get the downloader onto ethernet

This is the single highest-leverage change available. It removes the bottleneck rather than
working around it, and it improves both the download and the move simultaneously.

In rough order of preference: a real cable, then MoCA if there is coax, then powerline. The node
is already on 5 GHz at -56 dBm, so signal strength is not the problem — the 20 MB/s measured
above is interference and contention, which a cable removes entirely and a better channel only
partially mitigates.

The downloader is an Intel Mac with no ethernet port, so this means a **USB or Thunderbolt
ethernet adapter** (~$15, no drivers needed on Ubuntu). Cheapest meaningful upgrade available:
it would move the ceiling from 20 MB/s to the Pi's 73 MB/s disk limit, a ~3.6x improvement on
every byte crossing between nodes.

Failing a cable, changing the 5 GHz channel in the My Spectrum app is worth a try — 66 BSSes
in range and 149 retransmits per 10 s point at a congested channel.

If this happens, most of Phase 2's urgency evaporates. Local scratch is still worth keeping
(it is still 2N versus 5N, and NFS latency still hurts under PAR2 repair), but it stops being
the difference between usable and painful.

### B. Move SAB onto the Pi

The drive is attached to the Pi and the Pi is on ethernet, so running SAB there takes the
storage path to **~1N over ethernet with no network move at all**. On pure byte-movement
grounds it wins outright.

The counterargument is CPU and disk:

- PAR2 repair and unrar are CPU-heavy, and a Pi is weak at both. You would be moving the
  expensive step onto the slower processor.
- A USB-attached drive doing read + write simultaneously during unpack contends with itself,
  at exactly the step you are trying to speed up.
- It also collapses the VPN isolation the downloader node currently provides, unless you run
  Gluetun on the Pi too.

So it is a genuine trade — strong CPU behind WiFi, versus weak CPU on ethernet — not an obvious
win. Worth benchmarking `par2 repair` on a large release on both boxes before deciding.

**Recommendation:** do Phase 2 first. It is cheap, reversible, and helps under either topology.
Pursue A if it is physically possible. Only evaluate B if A is impossible and the Pi
benchmarks well.

### C. Minor

A dedicated mountpoint (`/mnt/media-nfs`) would reduce ambiguity versus `/data/media`. Probably
not worth the churn now that the path contract is written down.
