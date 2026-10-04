#!/bin/bash
# Generic full-host daily kopia-gdrive backup setup (any Linux + systemd).
# Run as root from the directory containing this bundle:
#   sudo ./setup-kopia-gdrive.sh
#
# Expects in the same directory:
#   kopia-gdrive-amd64 / kopia-gdrive-arm64   (binary for this arch)
# and ONE of:
#   client.json        (your OAuth Desktop client from the Google Cloud
#                       console — a browser consent runs during setup;
#                       see README for the one-time Google setup)
#   gdrive-token.json  (an already-authorized user token, e.g. copied
#                       from another of your machines)
#
# Optional environment overrides (export before running, or prefix the command):
#   SNAPSHOT_PATHS="/"                          space-separated paths to back up
#   FOLDER_NAME="kopia-backup-<hostname>"       Drive folder for this repo
#   BACKUP_ONCALENDAR="*-*-* 03:00:00"          daily snapshot schedule
#   VERIFY_ONCALENDAR="Sun *-*-* 05:00:00"      weekly verify schedule
#   DEVICE_FLOW=1                               headless machine: show a code
#                                               to enter on another device
#                                               instead of opening a browser
#
# Idempotent: safe to re-run; it reuses an existing repo/password/config.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
cd "$(dirname "$0")"

SNAPSHOT_PATHS="${SNAPSHOT_PATHS:-/}"
FOLDER_NAME="${FOLDER_NAME:-kopia-backup-$(hostname -s)}"
BACKUP_ONCALENDAR="${BACKUP_ONCALENDAR:-*-*-* 03:00:00}"
VERIFY_ONCALENDAR="${VERIFY_ONCALENDAR:-Sun *-*-* 05:00:00}"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  BIN=kopia-gdrive-amd64 ;;
  aarch64) BIN=kopia-gdrive-arm64 ;;
  *) echo "unsupported arch $ARCH"; exit 1 ;;
esac
[ -f "$BIN" ] || { echo "missing $BIN — download it from the GitHub release (see README) or build from source"; exit 1; }
if [ ! -f gdrive-token.json ] && [ ! -f client.json ]; then
  echo "missing credentials: put client.json (OAuth Desktop client, see README)"
  echo "or gdrive-token.json (existing authorized token) next to this script"
  exit 1
fi

ETC=/etc/kopia-gdrive
CONFIG=$ETC/repository.config
export KOPIA_CHECK_FOR_UPDATES=false

echo "== installing binary =="
install -m 0755 "$BIN" /usr/local/bin/kopia-gdrive
kg() { /usr/local/bin/kopia-gdrive --config-file "$CONFIG" "$@"; }

echo "== installing credentials and generating repository password =="
install -d -m 0700 "$ETC"
if [ -f gdrive-token.json ]; then
  install -m 0600 gdrive-token.json "$ETC/gdrive-token.json"
  AUTH_ARGS=(--credentials-file "$ETC/gdrive-token.json")
else
  install -m 0600 client.json "$ETC/client.json"
  AUTH_ARGS=(--client-credentials-file "$ETC/client.json" --token-cache-file "$ETC/token-cache.json")
  if [ "${DEVICE_FLOW:-0}" = "1" ]; then
    AUTH_ARGS+=(--device-flow)
  fi
fi
if [ ! -f "$ETC/env" ]; then
  PW=$(openssl rand -base64 32)
  umask 077
  printf 'KOPIA_PASSWORD=%s\n' "$PW" > "$ETC/env"
else
  echo "   (reusing existing $ETC/env)"
fi
# shellcheck disable=SC1091
. "$ETC/env"; export KOPIA_PASSWORD

echo "== creating repository (Drive folder: $FOLDER_NAME) =="
if [ ! -f "$CONFIG" ]; then
  kg repository create gdrive \
      --create-folder-name "$FOLDER_NAME" \
      "${AUTH_ARGS[@]}"
else
  echo "   (config already exists, skipping create)"
fi

echo "== policies: retention, compression, cache/temp excludes =="
# Universal: caches and thumbnails excluded wherever they appear
# (unanchored patterns match at any depth under every snapshot path).
kg policy set --global \
    --compression=zstd \
    --keep-latest 3 --keep-daily 30 --keep-weekly 8 --keep-monthly 6 --keep-annual 0 \
    --add-ignore '.cache/' \
    --add-ignore '.thumbnails/'

for p in $SNAPSHOT_PATHS; do
  kg policy set "$p" --ignore-file-errors=true
done

# Full-host sources additionally skip pseudo-filesystems, temp, logs,
# mounts of other things, swap, coredumps and per-user Trash.
case " $SNAPSHOT_PATHS " in *" / "*)
  kg policy set / \
      --add-ignore /proc/ \
      --add-ignore /sys/ \
      --add-ignore /dev/ \
      --add-ignore /run/ \
      --add-ignore /tmp/ \
      --add-ignore /var/tmp/ \
      --add-ignore /var/log/ \
      --add-ignore /var/cache/ \
      --add-ignore /var/lib/systemd/coredump/ \
      --add-ignore /lost+found/ \
      --add-ignore /media/ \
      --add-ignore /mnt/ \
      --add-ignore /swapfile \
      --add-ignore /swap.img \
      --add-ignore '/home/*/.local/share/Trash/' \
      --add-ignore /root/.local/share/Trash/
  ;;
esac

echo "== provider sanity check (~1 min) =="
kg repository validate-provider

echo "== installing systemd units =="
cat > /etc/systemd/system/kopia-gdrive-backup.service <<EOF
[Unit]
Description=kopia-gdrive snapshot of ${SNAPSHOT_PATHS}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ETC}/env
Environment=KOPIA_CHECK_FOR_UPDATES=false
ExecStart=/usr/local/bin/kopia-gdrive --config-file ${CONFIG} snapshot create ${SNAPSHOT_PATHS}
Nice=10
IOSchedulingClass=idle
EOF

cat > /etc/systemd/system/kopia-gdrive-backup.timer <<EOF
[Unit]
Description=daily kopia-gdrive snapshot

[Timer]
OnCalendar=${BACKUP_ONCALENDAR}
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/kopia-gdrive-verify.service <<EOF
[Unit]
Description=kopia-gdrive weekly snapshot verification
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ETC}/env
Environment=KOPIA_CHECK_FOR_UPDATES=false
ExecStart=/usr/local/bin/kopia-gdrive --config-file ${CONFIG} snapshot verify --verify-files-percent=10
Nice=10
IOSchedulingClass=idle
EOF

cat > /etc/systemd/system/kopia-gdrive-verify.timer <<EOF
[Unit]
Description=weekly kopia-gdrive snapshot verification

[Timer]
OnCalendar=${VERIFY_ONCALENDAR}
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now kopia-gdrive-backup.timer kopia-gdrive-verify.timer

echo "== starting first snapshot in the background =="
systemctl start --no-block kopia-gdrive-backup.service
echo "   follow it with: journalctl -fu kopia-gdrive-backup.service"

echo
echo "=================================================================="
echo " DONE. RECORD THIS PASSWORD SOMEWHERE SAFE — THERE IS NO RESET:"
grep '^KOPIA_PASSWORD=' "$ETC/env" | sed 's/^KOPIA_PASSWORD=/   /'
echo " (also stored root-only in $ETC/env)"
echo " Folder ID / status:  kopia-gdrive --config-file $CONFIG repository status"
echo "=================================================================="
