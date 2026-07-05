#!/bin/bash
# One-shot migration: move service state off the NFS mount (${BASE}, the old
# layout) onto the local disk at $DATA, then bootstrap the two-stage restic
# backup described in backup/README.md.
#
# Why: the NFS export uses mapall squashing and SQLite databases kept getting
# corrupted/locked over NFS (mealie was the recurring casualty). New model:
# state lives locally, the NAS receives nightly restic snapshots instead.
#
# Usage:
#   sudo scripts/migrate-to-local.sh [--dry-run] [--force]
#
# Flags:
#   --dry-run   Print every action without changing anything.
#   --force     Copy into non-empty destination directories (rsync merges).
#
# Prerequisites (checked below):
#   - run as root, on the server, from a LAN session (NOT over tailscale -
#     the stack, including tailscale, is stopped mid-migration)
#   - .env present with DATA= set
#   - /etc/restic/homelab.env present, 0600 (see backup/README.md step 2)
#   - restic, rsync, jq installed
#   - the old NFS mount still mounted (we read from it; we never delete it)
#
# Old data is NEVER deleted by this script. Archive it manually once every
# service has been verified against the new layout (see the printed next steps).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD_BASE="${OLD_BASE:-/mnt/skypaw-core}"

DRY_RUN=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

log()  { echo "[migrate] $*"; }
warn() { echo "[migrate] WARNING: $*" >&2; }
die()  { echo "[migrate] ERROR: $*" >&2; exit 1; }

# run <cmd...> - execute, or just print under --dry-run
run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------- preflight

[[ "$(id -u)" -eq 0 ]] || die "must run as root (sudo)"

for cmd in restic rsync jq docker; do
    command -v "$cmd" >/dev/null || die "$cmd is not installed"
done

[[ -f "$REPO_DIR/.env" ]] || die "$REPO_DIR/.env not found - copy .env.example and fill it in"

# Pull DATA/PUID/PGID out of .env without executing the whole file.
env_get() { grep -E "^$1=" "$REPO_DIR/.env" | tail -n1 | cut -d= -f2-; }
DATA="$(env_get DATA)"
PUID="$(env_get PUID)"
PGID="$(env_get PGID)"
[[ -n "$DATA" ]] || die ".env has no DATA= - set DATA=/var/lib/homelab"
[[ -n "$PUID" && -n "$PGID" ]] || die ".env is missing PUID/PGID"

mountpoint -q "$OLD_BASE" || die "$OLD_BASE is not mounted - the old data lives there"

RESTIC_ENV=/etc/restic/homelab.env
[[ -f "$RESTIC_ENV" ]] || die "$RESTIC_ENV not found - create it first (backup/README.md step 2)"
[[ "$(stat -c %a "$RESTIC_ENV")" == "600" ]] || die "$RESTIC_ENV must be chmod 600"

# lib.sh sources $RESTIC_ENV and gives us hl_backup/hl_copy + the repo paths.
# shellcheck source=../backup/lib.sh
. "$REPO_DIR/backup/lib.sh"
hl_load_env
[[ "$DATA" == "$(env_get DATA)" ]] || \
    die "DATA in $RESTIC_ENV ($DATA) disagrees with .env ($(env_get DATA)) - fix one of them"

# SRC:DST copy map (old NFS layout -> new local layout). Keep in sync with
# the volume mounts in services/*.yml and BACKUP_PATHS in backup/lib.sh.
PAIRS=(
    "$OLD_BASE/configs/adguard:$DATA/adguard/conf"
    "$OLD_BASE/appdata/adguard:$DATA/adguard/work"
    "$OLD_BASE/appdata/atuin:$DATA/atuin"
    "$OLD_BASE/appdata/caddy/data:$DATA/caddy/data"
    "$OLD_BASE/configs/homeassistant:$DATA/homeassistant"
    "$OLD_BASE/appdata/mealie:$DATA/mealie"
    "$OLD_BASE/appdata/mosquitto/data:$DATA/mosquitto"
    "$OLD_BASE/appdata/scarlett/data:$DATA/scarlett"
    "$OLD_BASE/appdata/tailscale:$DATA/tailscale/state"
    "$OLD_BASE/configs/tailscale:$DATA/tailscale/config"
    "$OLD_BASE/appdata/vaultwarden:$DATA/vaultwarden"
)

# Refuse to merge into non-empty destinations unless --force. Missing sources
# are only a warning (a fresh service may have no data yet).
for pair in "${PAIRS[@]}"; do
    src="${pair%%:*}" dst="${pair##*:}"
    if [[ ! -d "$src" ]]; then
        warn "source $src does not exist - will skip"
        continue
    fi
    if [[ -d "$dst" && -n "$(ls -A "$dst" 2>/dev/null)" && "$FORCE" -ne 1 ]]; then
        die "destination $dst is not empty - re-run with --force to merge into it"
    fi
done

# Free-space check: the copied data AND its first restic snapshot both land
# on the filesystem holding $DATA (the local repo may be on the same disk),
# so require 2x headroom.
src_kb=0
for pair in "${PAIRS[@]}"; do
    src="${pair%%:*}"
    [[ -d "$src" ]] && src_kb=$((src_kb + $(du -sk "$src" | cut -f1)))
done
mkdir -p "$DATA"
avail_kb=$(df -Pk "$DATA" | awk 'NR==2 {print $4}')
log "old data: $((src_kb / 1024)) MiB, free on $DATA's filesystem: $((avail_kb / 1024)) MiB"
[[ "$avail_kb" -gt $((src_kb * 2)) ]] || \
    die "need at least 2x the data size ($((src_kb * 2 / 1024)) MiB) free - grow the disk first"

log "preflight OK"

# --------------------------------------------------------------- stop stack

log "stopping the stack (paths are changing - stop, not pause)"
run docker compose --project-directory "$REPO_DIR" \
    --profile serv --profile dns --profile iot --profile ai stop

# --------------------------------------------------------------------- copy

for pair in "${PAIRS[@]}"; do
    src="${pair%%:*}" dst="${pair##*:}"
    [[ -d "$src" ]] || continue
    log "copy $src -> $dst"
    run mkdir -p "$dst"
    if [[ "$dst" == "$DATA/tailscale/state" ]]; then
        # the old layout nested portainer's data inside tailscale's state dir
        # (a since-fixed mistake in portainer.yml) - don't carry it across
        run rsync -a --info=progress2 --exclude=portainer "$src"/ "$dst"/
    else
        run rsync -a --info=progress2 "$src"/ "$dst"/
    fi
done

# caddy's /config moves out of the caddy_config named volume
if docker volume inspect homelab_caddy_config >/dev/null 2>&1; then
    log "copy named volume homelab_caddy_config -> $DATA/caddy/config"
    run mkdir -p "$DATA/caddy/config"
    run docker run --rm -v homelab_caddy_config:/from -v "$DATA/caddy/config":/to \
        alpine sh -c 'cp -a /from/. /to/'
else
    warn "named volume homelab_caddy_config not found - skipping"
fi

# ---------------------------------------------------------------- ownership

# Under NFS mapall the in-container uid never mattered (the server squashed
# every write to one identity); on local disk it does. PUID:PGID preserves
# today's effective ownership for everything except mosquitto, which runs
# as uid 1883 inside its container.
log "fixing ownership ($PUID:$PGID, mosquitto 1883:1883)"
for pair in "${PAIRS[@]}"; do
    dst="${pair##*:}"
    [[ -d "$dst" || "$DRY_RUN" -eq 1 ]] || continue
    if [[ "$dst" == "$DATA/mosquitto" ]]; then
        run chown -R 1883:1883 "$dst"
    else
        run chown -R "$PUID:$PGID" "$dst"
    fi
done
if [[ -d "$DATA/caddy/config" || "$DRY_RUN" -eq 1 ]]; then
    run chown -R "$PUID:$PGID" "$DATA/caddy/config"
fi

# ----------------------------------------------------------- restic bootstrap

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would init restic repos and take the initial-migration snapshot"
else
    if restic -r "$LOCAL_REPOSITORY" cat config >/dev/null 2>&1; then
        log "local restic repo already initialised at $LOCAL_REPOSITORY"
    else
        log "initialising local restic repo at $LOCAL_REPOSITORY"
        mkdir -p "$LOCAL_REPOSITORY"
        restic -r "$LOCAL_REPOSITORY" init
    fi

    if mountpoint -q "$REMOTE_MOUNT"; then
        if RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" restic -r "$REMOTE_REPOSITORY" cat config >/dev/null 2>&1; then
            log "NAS restic repo already initialised at $REMOTE_REPOSITORY"
        else
            log "initialising NAS restic repo at $REMOTE_REPOSITORY (shared chunker params)"
            mkdir -p "$REMOTE_REPOSITORY"
            RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" restic -r "$REMOTE_REPOSITORY" init \
                --copy-chunker-params --from-repo "$LOCAL_REPOSITORY"
        fi
    else
        warn "$REMOTE_MOUNT not mounted - skipping NAS repo init and copy"
    fi

    # Stack is stopped, so no pause needed for a consistent first snapshot.
    log "taking the initial snapshot (tagged manual + initial-migration, never auto-pruned)"
    hl_backup --tag manual --tag initial-migration

    rc=0
    hl_copy || rc=$?
    case "$rc" in
        0) log "initial snapshot copied to the NAS" ;;
        2) warn "$REMOTE_MOUNT not mounted - NAS copy skipped, run 'backup/backup-cli.sh copy' later" ;;
        *) warn "restic copy to the NAS failed (rc=$rc) - local snapshot is intact" ;;
    esac
fi

# --------------------------------------------------------------- next steps

cat <<EOF

[migrate] Done. Old data at $OLD_BASE is untouched. Next steps:

 1. Install the systemd units and enable the timer (backup/README.md step 5):
      sudo systemctl enable --now backup-homelab.timer

 2. Bring the stack back up on the new paths:
      docker compose --profile serv up -d

 3. Verify every service before touching the old data:
      - DNS resolves through adguard:      dig @192.168.0.10 lab.lan
      - Caddy serves with the SAME certs:  open https://lab.lan (no cert warning)
      - Vaultwarden: log in, open an item
      - Mealie: open a recipe with an image
      - Atuin: 'atuin sync' from a client
      - Home Assistant: history graphs show pre-migration data
      - Mosquitto: mosquitto_sub -h 192.168.0.10 -t '\$SYS/broker/version' -C 1
      - Tailscale: 'tailscale status' shows the node online (no re-auth)
      - Scarlett: bot online in Discord; if her logs show permission errors
        on /app/data, chown $DATA/scarlett to the uid in her image
      - watch for permission errors: docker compose logs -f

 4. ONLY after everything checks out, archive the old data on the NAS
    (keep it until a few nightly backups have run cleanly):
      mv $OLD_BASE/appdata $OLD_BASE/appdata.pre-migration
      mv $OLD_BASE/configs/adguard        $OLD_BASE/configs/adguard.pre-migration
      mv $OLD_BASE/configs/homeassistant  $OLD_BASE/configs/homeassistant.pre-migration
      mv $OLD_BASE/configs/tailscale      $OLD_BASE/configs/tailscale.pre-migration
    and remove the retired volumes:
      docker volume rm homelab_caddy_config homelab_mealie_data
EOF
