# SABnzbd Local Scratch + Cleanup Plan

## Goal

Use the downloader machine's local disk for SABnzbd's active download/unpack work, then move completed downloads to the Pi/NFS media share.

This should make unpacking faster while keeping the downloader from filling up over time.

## Why This Helps

Right now, SAB appears to be unpacking directly from the NFS-mounted media share.

That means heavy post-processing work happens over the network:

```txt
read RAR parts from Pi over NFS
write extracted files back to Pi over NFS
delete temp files over NFS
repair/check PAR2 files over NFS
```

That is slow, especially for large releases, PAR2 repair, and folders with lots of small files.

The better setup is:

```txt
Downloader local disk:
  /downloads/incomplete     temporary download/unpack scratch

Pi / NFS media disk:
  /data/downloads/complete  final completed downloads
  /data/media/...           Sonarr/Radarr/Jellyfin library
```

SAB does the hard work locally, then moves the completed result to the NFS share.

## SAB Folder Settings

In SABnzbd, set:

```txt
Temporary Download Folder: /downloads/incomplete
Completed Download Folder: /data/downloads/complete
```

Do **not** use the NFS share for the temporary/incomplete folder.

## Docker Compose Volume Setup

Example SABnzbd Docker volumes:

```yaml
volumes:
  - ./config/sabnzbd:/config
  - /data/media:/data
  - /home/reid/sab-downloads:/downloads
```

Host paths:

```txt
/home/reid/sab-downloads/incomplete   # local downloader scratch
/data/media/downloads/complete        # Pi/NFS final destination
```

Inside the SAB container:

```txt
/downloads/incomplete                 # local scratch
/data/downloads/complete              # NFS completed downloads
```

## Recommended SAB Settings

In SABnzbd:

```txt
Abort jobs that cannot be completed: ON
Action when encrypted RAR is downloaded: Abort
Direct Unpack: OFF
Pause Downloading During Post-Processing: ON
```

For duplicate detection:

```txt
Identical download detection: Fail job (move to History)
Smart duplicate detection: Fail job (move to History)
```

Why:

- `Abort encrypted RAR` prevents passworded junk from getting stuck.
- `Abort jobs that cannot be completed` prevents wasting time on missing articles.
- `Pause Downloading During Post-Processing` reduces disk pressure on the downloader.
- `Direct Unpack OFF` keeps things simpler with this setup.
- `Fail job` is better than silently discarding because Sonarr can see the failed release and try another one.

## Create the Local Scratch Folder

On the downloader machine:

```bash
mkdir -p /home/reid/sab-downloads/incomplete
```

Check available local space:

```bash
df -h /
df -h /home
```

If `/home` has limited space, avoid queuing large 4K releases or full season packs.

## Cleanup Script

This script deletes old abandoned items from the local SAB incomplete folder.

Create the script:

```bash
nano ~/hommelab/downloader/cleanup-sab-scratch.sh
```

Paste:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRATCH="/home/reid/sab-downloads/incomplete"
MAX_AGE_DAYS=3

# Safety checks
if [[ -z "$SCRATCH" || "$SCRATCH" == "/" ]]; then
  echo "Bad SCRATCH path"
  exit 1
fi

if [[ ! -d "$SCRATCH" ]]; then
  echo "Scratch folder does not exist: $SCRATCH"
  exit 0
fi

echo "Cleaning SAB scratch older than $MAX_AGE_DAYS days:"
echo "$SCRATCH"

find "$SCRATCH" \
  -mindepth 1 \
  -maxdepth 1 \
  -mtime +"$MAX_AGE_DAYS" \
  -print \
  -exec rm -rf {} +

echo "Done."
```

Make it executable:

```bash
chmod +x ~/hommelab/downloader/cleanup-sab-scratch.sh
```

## Dry Run Before Deleting

Before running the cleanup script, check what would be deleted:

```bash
find /home/reid/sab-downloads/incomplete -mindepth 1 -maxdepth 1 -mtime +3 -print
```

If the output looks safe, run:

```bash
~/hommelab/downloader/cleanup-sab-scratch.sh
```

## Cron Job

Open cron:

```bash
crontab -e
```

Run cleanup every morning at 4:30 AM:

```cron
30 4 * * * /home/reid/hommelab/downloader/cleanup-sab-scratch.sh >> /home/reid/hommelab/downloader/cleanup-sab-scratch.log 2>&1
```

## Safer Cleanup Option

If you want to be extra safe, only clean when SAB is stopped:

```bash
docker stop sabnzbd
~/hommelab/downloader/cleanup-sab-scratch.sh
docker start sabnzbd
```

This avoids deleting anything SAB is actively using.

## Important Notes

Do **not** write a custom script to move completed downloads if SAB can already do it.

Let SAB handle this:

```txt
/downloads/incomplete  ->  /data/downloads/complete
```

Only script deletion of abandoned leftovers from:

```txt
/home/reid/sab-downloads/incomplete
```

## Recommended Operating Rules

Because the downloader has limited local disk space:

```txt
1080p TV/movie: usually fine
Large 4K remuxes: risky
Whole season packs: risky
Multiple active downloads: risky
```

Keep the queue modest so local scratch does not fill up.

## Final Setup Summary

```txt
SAB temporary/incomplete folder:
  /downloads/incomplete
  -> host: /home/reid/sab-downloads/incomplete
  -> local downloader disk

SAB completed folder:
  /data/downloads/complete
  -> host: /data/media/downloads/complete
  -> Pi/NFS media share

Cleanup script:
  Deletes local incomplete leftovers older than 3 days
```

This gives SAB local unpack speed while keeping completed media on the Pi.

