# CLAUDE.md

This repo is a standalone installer that sets up automatic daily
encrypted kopia backups to Google Drive on a Linux/systemd machine.
People clone it and run `sudo ./setup-kopia-gdrive.sh`. If you are
Claude running in a user's clone, your job is usually: walking them
through the one-time Google OAuth setup, running the installer,
checking on backups, test-restores, and troubleshooting.

## What's here

- `setup-kopia-gdrive.sh` — the whole installer. Idempotent; re-running
  is always safe. It generates the systemd units itself; there are no
  unit files in the repo. Read it before answering questions about
  behavior — it is short and is the source of truth.
- `README.md` — user instructions, including the Google Cloud OAuth
  walkthrough and all override variables.
- Binaries (`kopia-gdrive-amd64`/`-arm64`) are NOT in git — users fetch
  them from the GitHub release (verify against `SHA256SUMS`) or build
  from source: branch `gdrive-native-upstream` of
  https://github.com/arsenixprime/kopia (`CGO_ENABLED=0 go build`).

## Hard rules

- **Never commit, print, cat, or copy elsewhere**: `client.json`,
  `gdrive-token.json`, `token-cache.json`, anything under
  `/etc/kopia-gdrive/` (the `env` file there holds the repository
  password). Referring to these by path is fine.
- Never suggest widening the OAuth scope beyond `drive.file` unless the
  user explicitly needs to back up into a pre-existing hand-created
  Drive folder (`--scope=drive` exists for that; explain the tradeoff:
  the token then sees their whole Drive).
- The repository password is unrecoverable. Before any step that
  touches `/etc/kopia-gdrive/` destructively, make sure the user has
  recorded it.
- Don't commit binaries to git; release assets only.

## Operational facts that save debugging time

- State on an installed machine: binary at `/usr/local/bin/kopia-gdrive`,
  everything else in `/etc/kopia-gdrive/` (config, credentials,
  password env), units `kopia-gdrive-backup.{service,timer}` and
  `kopia-gdrive-verify.{service,timer}`. All kopia commands need
  `--config-file /etc/kopia-gdrive/repository.config` and root.
- The services are `Type=oneshot`: while a backup runs the unit shows
  `activating`, not `active`. Script checks should watch
  `systemctl show -p SubState` (`start` = running), not `is-active`.
- No live progress appears in the journal mid-backup (kopia's progress
  display is TTY-only). "Is it doing anything?" → `systemctl status`
  for runtime/CPU, or run a snapshot manually in a terminal for the
  live progress line.
- Google OAuth app left in *Testing* mode → refresh tokens expire after
  7 days and backups start failing with auth errors. Fix: publish the
  OAuth app to production in the Google Cloud console, delete
  `/etc/kopia-gdrive/token-cache.json`, re-run the installer to
  re-consent.
- Drive enforces 750 GB/day/account uploads. The backend fails fast
  with a clear quota error; the next timer run resumes. This is normal
  during multi-TB seeding, not a bug.
- Errors from the backend carry the Google API `reason` string and a
  remediation hint — read them before diving into logs. Deeper logs:
  `journalctl -u kopia-gdrive-backup.service` and
  `/root/.cache/kopia/*/cli-logs/`.
- `hostname` matters: the Drive folder is `kopia-backup-<hostname -s>`.
  Two machines with the same short hostname and the same Google account
  will reuse one folder — override `FOLDER_NAME` to avoid that.

## Testing changes to the installer

There is no test suite. Minimum bar for a script change: `bash -n`,
shellcheck if available, then a real run on a scratch machine or VM
(the script needs systemd — containers usually won't do). Keep the
script idempotent: every step must tolerate already-done state.
