#!/bin/bash
# Shared helpers for homelab restic backups.
#
# Sourced by:
#   backup.sh       - nightly systemd job (env comes from EnvironmentFile)
#   backup-cli.sh   - interactive ops tool (env sourced from $ENV_FILE here)
#   scripts/migrate-to-local.sh - one-shot migration off the NFS mount
#
# Defines: paths, container set, RESTIC_NICE, and the restic invocations
# (hl_backup / hl_forget / hl_copy) so the entrypoints can't drift.
# Callers must run hl_load_env before anything else - it resolves $DATA and
# builds BACKUP_PATHS.

ENV_FILE="${ENV_FILE:-/etc/restic/homelab.env}"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source env file if RESTIC_PASSWORD wasn't already provided. systemd sets it
# via EnvironmentFile for the nightly job; the CLI invocation needs to load it
# here. RESTIC_PASSWORD, LOCAL_REPOSITORY, REMOTE_MOUNT, REMOTE_REPOSITORY,
# and DATA all come from that file. Restic itself reads RESTIC_REPOSITORY, so
# we mirror LOCAL_REPOSITORY into it for the bare `restic backup` /
# `restic forget` calls below; the remote repo is passed explicitly via -r at
# copy time.
hl_load_env() {
    if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
        if [[ ! -r "$ENV_FILE" ]]; then
            echo "ERROR: cannot read $ENV_FILE (run with sudo?)" >&2
            return 1
        fi
        # shellcheck disable=SC1090
        . "$ENV_FILE"
    fi
    DATA="${DATA:-/var/lib/homelab}"
    export RESTIC_PASSWORD LOCAL_REPOSITORY REMOTE_MOUNT REMOTE_REPOSITORY DATA
    export RESTIC_REPOSITORY="$LOCAL_REPOSITORY"

    BACKUP_PATHS=(
      "$DATA/adguard/conf"      # AdGuardHome.yaml - filters, rewrites, clients
      "$DATA/atuin"             # shell history sqlite
      "$DATA/caddy/data"        # internal CA + issued certs (trusted by LAN devices)
      "$DATA/homeassistant"     # config + .storage + recorder sqlite
      "$DATA/mealie"            # recipes sqlite + images
      "$DATA/mosquitto"         # retained-message store
      "$DATA/scarlett"          # bot sqlite (user timezones etc)
      "$DATA/tailscale"         # node identity/state + /etc/tailscale
      "$DATA/vaultwarden"       # vault sqlite + attachments + rsa keys
      # .env carries the Vaultwarden admin token, Discord token, etc. Without
      # it the stack won't start. Same security boundary as the restic
      # password file at /etc/restic/homelab.env (both plaintext on the same
      # host), so including it here doesn't widen exposure.
      "$COMPOSE_DIR/.env"
    )
    # NOT backed up: $DATA/adguard/work (query log + stats, rebuilt from
    # conf), $DATA/caddy/config (admin API autosave, rebuilt from the
    # Caddyfile), and the scarlett_lavalink_plugins volume (plugin jars
    # re-download on start).
}

# Containers to pause during backup: the SQLite/state writers, so their DBs
# are snapshotted with no writer attached.
#
# Deliberately NOT paused:
#   caddy, adguard, unbound - pausing adguard kills DNS for the whole LAN;
#     adguard/conf only changes on settings edits, safe to snapshot live
#   tailscale - would drop remote access mid-backup; state writes are rare
#   watchtower, scarlett-lavalink - no state worth quiescing
#
# pause/unpause (SIGSTOP/SIGCONT) is used instead of stop/start so Docker
# doesn't treat the exit as a crash and auto-restart containers mid-backup.
PAUSE_CONTAINERS=(
  mealie
  vaultwarden
  atuin
  homeassistant
  mosquitto
  scarlett-bot
)

# Every service pins container_name:, so plain `docker pause <name>` works.
# Both helpers filter PAUSE_CONTAINERS to what's actually in the relevant
# state - a profile that doesn't run e.g. scarlett-bot must not abort the
# whole nightly job under set -e.
hl_pausable_containers() {
    comm -12 \
        <(printf '%s\n' "${PAUSE_CONTAINERS[@]}" | sort) \
        <(docker ps --filter status=running --format '{{.Names}}' | sort)
}

hl_paused_containers() {
    comm -12 \
        <(printf '%s\n' "${PAUSE_CONTAINERS[@]}" | sort) \
        <(docker ps --filter status=paused --format '{{.Names}}' | sort)
}

# Run restic under nice + ionice so its disk I/O doesn't starve containers
# on the shared LXC disk.
#   nice -n10        : lower CPU priority (default 0, range -20..19)
#   ionice -c2 -n7   : best-effort I/O class, lowest priority within it
RESTIC_NICE=(nice -n10 ionice -c2 -n7)

# Pause containers and install a safety-net trap: unpause on exit even if the
# caller dies mid-backup. Caller must clear the trap (via hl_unpause) once it's
# done so the unpause doesn't fire a second time.
hl_pause() {
    local running
    running=$(hl_pausable_containers)
    if [[ -n "$running" ]]; then
        # shellcheck disable=SC2086
        docker pause $running
    fi
    # shellcheck disable=SC2154  # $p is assigned when the trap fires
    trap 'p=$(hl_paused_containers); [[ -n "$p" ]] && docker unpause $p' EXIT
}

hl_unpause() {
    local paused
    paused=$(hl_paused_containers)
    if [[ -n "$paused" ]]; then
        # shellcheck disable=SC2086
        docker unpause $paused
    fi
    trap - EXIT
}

# hl_backup [extra restic args...]
# Runs restic backup against BACKUP_PATHS with the standard excludes/tag.
# Caller is responsible for pause/unpause ordering.
hl_backup() {
    "${RESTIC_NICE[@]}" restic backup \
        "${BACKUP_PATHS[@]}" \
        --exclude "$DATA/vaultwarden/icon_cache" \
        --exclude "$DATA/homeassistant/deps" \
        --exclude "$DATA/homeassistant/tts" \
        --exclude "*.log" \
        --exclude "*.log.*" \
        --tag homelab \
        "$@"
}

# hl_forget [extra restic args...]
# Applies the retention policy + prune against the local repo.
#
# Scoped to --tag nightly so manual snapshots (tagged 'manual') are never
# selected for forget and are kept indefinitely. To prune a manual snapshot
# you have to forget it explicitly by ID.
#
# --group-by host,tags pools all nightly snapshots into one bucket regardless
# of which paths they covered. Without this, restic groups by (host,paths,tags)
# and any change to the path list (adding/removing a service, moving the data
# dir) starts a new group that retention then treats independently - producing
# orphan groups of one snapshot each that never age out. Pooling by host+tags
# keeps the policy applied across the whole repo so old paths get pruned
# naturally as new snapshots accumulate.
hl_forget() {
    "${RESTIC_NICE[@]}" restic forget \
        --group-by host,tags \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 3 \
        --keep-yearly 1 \
        --prune \
        --tag nightly \
        "$@"
}

# hl_copy [extra restic args...]
# Mirror local repo to the repo on the NAS (NFS mount) via restic copy. Both
# repos share chunker params (set at remote repo init via
# --copy-chunker-params) so dedup carries across; only new pack files are
# sent each run. RESTIC_FROM_PASSWORD covers the source (--from-repo) - the
# destination uses the regular RESTIC_PASSWORD.
# Returns 2 if the remote mount is missing so callers can decide whether
# that's fatal (CLI) or a warning (nightly best-effort).
hl_copy() {
    if ! mountpoint -q "$REMOTE_MOUNT"; then
        return 2
    fi
    RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" \
        "${RESTIC_NICE[@]}" restic -r "$REMOTE_REPOSITORY" copy \
            --from-repo "$LOCAL_REPOSITORY" \
            "$@"
}
