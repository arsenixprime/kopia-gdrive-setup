# kopia-gdrive-setup

Turnkey encrypted daily backups of a Linux machine to **Google Drive**,
using [kopia](https://kopia.io) with a rewritten native Google Drive
backend. One script sets up everything: repository creation in Drive,
sensible exclude policies, a daily systemd snapshot timer, and a weekly
integrity verification.

Your data is end-to-end encrypted by kopia before upload — Google only
ever sees ciphertext. The default OAuth scope (`drive.file`) means the
backup token can only access files the app itself created, never the
rest of your Drive.

## Status

This uses a **pre-release build** of kopia's Google Drive backend
(a ground-up rewrite currently being prepared for upstream submission —
structured error handling, adaptive rate limiting, persistent file-ID
caching, resumable uploads). Source:
[`arsenixprime/kopia`, branch `gdrive-native-upstream`](https://github.com/arsenixprime/kopia/tree/gdrive-native-upstream).
Binaries are published under [Releases](../../releases) with SHA-256
checksums; you can also build from source (below). The on-Drive format
is standard kopia — repositories created today remain readable by
stock kopia once the backend merges upstream.

## Requirements

- Linux with systemd, x86_64 or arm64, root access
- A Google account
- A one-time Google Cloud setup (~5 minutes, free, no billing):
  your own OAuth client

## 1. One-time Google setup

1. Go to the [Google Cloud console](https://console.cloud.google.com/),
   create a project (any name).
2. **APIs & Services → Library → Google Drive API → Enable.**
3. **APIs & Services → OAuth consent screen:** User type *External*,
   fill in the app name and your email.
4. **Publish the app** (switch from *Testing* to *In production*).
   This matters: tokens issued by apps left in *Testing* mode expire
   after 7 days, which silently kills your backups. The `drive.file`
   scope used here is non-sensitive, so production status does not
   require Google's verification review.
5. **APIs & Services → Credentials → Create credentials → OAuth client
   ID → Desktop app.** Download the JSON.

Save the downloaded file as `client.json`. One OAuth client serves all
your machines.

## 2. Install on a machine

```sh
git clone https://github.com/arsenixprime/kopia-gdrive-setup
cd kopia-gdrive-setup

# binary for your arch from the release page (or build from source):
curl -LO https://github.com/arsenixprime/kopia-gdrive-setup/releases/latest/download/kopia-gdrive-amd64
curl -LO https://github.com/arsenixprime/kopia-gdrive-setup/releases/latest/download/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS

cp /path/to/client.json .
sudo ./setup-kopia-gdrive.sh
```

A browser opens for the Google consent (on a headless machine use
`sudo DEVICE_FLOW=1 ./setup-kopia-gdrive.sh` and enter the shown code
on any other device). The script then creates the repository, runs a
~1-minute provider validation against your Drive, installs the timers,
and starts the first backup in the background.

**Record the repository password it prints at the end. There is no
reset.** It is also stored root-only in `/etc/kopia-gdrive/env`, but if
the disk dies, that password is what stands between you and your
backups — keep a copy elsewhere.

Additional machines: repeat on each machine with the same `client.json`
(each gets its own repository folder, named `kopia-backup-<hostname>`),
or copy an existing machine's token as `gdrive-token.json` instead of
`client.json` to skip the browser consent.

## What it sets up

- Repository in an app-owned Drive folder `kopia-backup-<hostname>`
- Daily snapshot of `/` at 03:00 plus a per-machine stable offset of up
  to 30 min (`FixedRandomDelay`: each host hashes its own offset from
  its machine-id, so several machines on one network naturally avoid
  backing up at the same instant, every night). Catch-up after
  downtime; runs at low CPU/IO priority. For guaranteed separation,
  give each machine its own slot with `BACKUP_ONCALENDAR` (below).
- Weekly 10% snapshot verification (Sundays)
- Retention: 3 latest / 30 daily / 8 weekly / 6 monthly; zstd compression
- Excludes: `/proc /sys /dev /run /tmp /var/tmp /var/log /var/cache`,
  coredumps, `/lost+found /media /mnt`, swapfiles, Trash, and `.cache/`
  + `.thumbnails/` directories at any depth

### Overrides

Environment variables before the `sudo` command:

```sh
SNAPSHOT_PATHS="/home /etc"              # back up these instead of /
FOLDER_NAME="kopia-backup-mybox"         # Drive folder name
BACKUP_ONCALENDAR="*-*-* 01:30:00"       # systemd OnCalendar syntax
VERIFY_ONCALENDAR="Mon *-*-* 06:00:00"
```

## Day-2 operations

```sh
alias kg='sudo kopia-gdrive --config-file /etc/kopia-gdrive/repository.config'

systemctl list-timers 'kopia-gdrive-*'        # schedules; stale LAST = trouble
journalctl -u kopia-gdrive-backup.service -p warning --since -7d
sudo systemctl start kopia-gdrive-backup.service   # run a backup right now

kg snapshot list                              # what exists
kg restore <snapshot-id> /tmp/restore-test    # restore (do a test one early!)
kg repository status                          # folder ID, repo health
```

## Build from source

```sh
git clone -b gdrive-native-upstream https://github.com/arsenixprime/kopia
cd kopia && CGO_ENABLED=0 go build -o kopia-gdrive-amd64 .
```

## Uninstall

```sh
sudo systemctl disable --now kopia-gdrive-backup.timer kopia-gdrive-verify.timer
sudo rm /etc/systemd/system/kopia-gdrive-* /usr/local/bin/kopia-gdrive
sudo rm -r /etc/kopia-gdrive    # contains the repo password — record it first!
```

The backup data in Drive is untouched: it remains a valid kopia
repository you can reconnect to later.

## Caveats

- Google Drive caps uploads at **750 GB/day per account**. A larger
  first backup stops at the cap with a clear error and resumes on the
  next daily run — multi-terabyte seeding takes a few days, by design.
- Linux + systemd only (the backend itself is cross-platform; this
  installer is not).
- Never commit `client.json` or any `*token*.json` to a fork of this
  repo — `.gitignore` guards them, but they are secrets: `client.json`
  loosely (it identifies your OAuth app), tokens absolutely.

## License

Apache-2.0, same as kopia. The binaries are unmodified builds of the
fork branch linked above.
