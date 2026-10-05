#!/bin/bash
# Push the replica subset of the latest nightly snapshot to each replica Pi.
#
# Runs on skypaw after backup.sh. Restores REPLICA_PATHS from the newest
# nightly snapshot into a scratch dir, then for every host in REPLICAS:
#   1. dry rsync to learn which of the three trees actually change
#   2. stop the containers that own the changing trees
#   3. real rsync into $DATA over tailscale SSH
#   4. `docker compose up -d` to bring the stopped containers back
# vaultwarden is stopped rather than paused because its SQLite file is
# replaced underneath it. AdGuard and caddy are only restarted on a night
# their data moved, so replica DNS is normally untouched.
#
# The replicas hold no restic password and never see the repo: the restore
# happens here and only plain files travel. Hosts are resolved with
# `tailscale ip` rather than DNS, because the DNS hosts run tailscale with
# --accept-dns=false. An unreachable replica (office Pi powered off) is a
# warning and the others still run; an rsync or compose failure is an
# error and the job exits non-zero at the end.
#
# Usage:
#   sudo backup/replicate.sh [--dry-run] [--only <host>]
#
# Flags:
#   --dry-run       Show what each host would receive; no stop/start, no writes
#   --only <host>   Push to one replica, e.g. from its own call-home on boot
#
# Prerequisites:
#   1. REPLICAS="asteria acrux ..." in /etc/restic/homelab.env
#   2. tailscale SSH ACL allowing this host to reach REPLICA_USER on each
#   3. The replica checked out at ~REPLICA_USER/homelab with COMPOSE_PROFILES
#      set in its .env, and the same $DATA path as here

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
hl_load_env

REPLICA_USER="${REPLICA_USER:-containersvc}"
REPLICA_COMPOSE_DIR="${REPLICA_COMPOSE_DIR:-homelab}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

DRY_RUN=0
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --only)    ONLY="${2:?--only needs a host}"; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ -z "$REPLICAS" ]]; then
    echo "No REPLICAS configured in $ENV_FILE - nothing to do"
    exit 0
fi

# The container that owns each replica tree; the tree's first path element.
container_for() {
    case "$1" in
        adguard/*) echo adguard ;;
        caddy/*)   echo caddy ;;
        *)         echo "${1%%/*}" ;;
    esac
}

SCRATCH="$(mktemp -d /var/tmp/homelab-replicate.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

# restic recreates the absolute path under --target, so the restored tree
# sits at $SCRATCH$DATA. --include on a directory pulls everything under it.
restore_args=()
for rel in "${REPLICA_PATHS[@]}"; do
    restore_args+=(--include "$DATA/$rel")
done
"${RESTIC_NICE[@]}" restic restore latest --tag nightly \
    --target "$SCRATCH" "${restore_args[@]}" >/dev/null
SRC="$SCRATCH$DATA"

for rel in "${REPLICA_PATHS[@]}"; do
    if [[ ! -d "$SRC/$rel" ]]; then
        echo "ERROR: $rel missing from the restored snapshot" >&2
        exit 1
    fi
done

# rsync flags: archive minus owner/group, because the receiving user is not
# root and the containers run as root inside their namespaces, so
# containersvc-owned files are fine. --delete keeps the replica an exact
# copy; the icon cache is excluded from backups and would otherwise be
# wiped nightly. -i itemises so the dry pass can be parsed.
RSYNC=(rsync -rlptDi --delete --exclude icon_cache -e "ssh ${SSH_OPTS[*]}")

# The dry pass sends all three trees in one call with --relative, anchored
# at $SRC by the /./ marker, so each lands at its own path under $DATA and
# the itemised paths come back relative to $DATA. --delete under --relative
# only reaches inside the transferred trees, so adguard/work is safe.
DRY_SOURCES=("${REPLICA_PATHS[@]/#/$SRC/./}")

# changed_trees <user@ip>: prints the REPLICA_PATHS entries whose contents
# would change, one per line, by parsing a dry run. Itemised lines begin
# with a change flag string, then a space, then the path.
changed_trees() {
    local target="$1" path
    "${RSYNC[@]}" -nR "${DRY_SOURCES[@]}" "$target:$DATA/" 2>/dev/null \
    | while read -r _ path; do
        for rel in "${REPLICA_PATHS[@]}"; do
            [[ "$path" == "$rel" || "$path" == "$rel/"* ]] && echo "$rel"
        done
    done | sort -u
}

failed=0
for host in $REPLICAS; do
    if [[ -n "$ONLY" && "$host" != "$ONLY" ]]; then
        continue
    fi
    if ! ip="$(tailscale ip -4 "$host" 2>/dev/null)"; then
        echo "WARNING: $host is not a known tailscale peer - skipping"
        continue
    fi
    target="$REPLICA_USER@$ip"
    if ! ssh "${SSH_OPTS[@]}" "$target" true 2>/dev/null; then
        echo "WARNING: $host ($ip) unreachable - skipping"
        continue
    fi

    mapfile -t trees < <(changed_trees "$target")
    if [[ ${#trees[@]} -eq 0 ]]; then
        echo "$host: up to date"
        continue
    fi
    containers=()
    for rel in "${trees[@]}"; do
        containers+=("$(container_for "$rel")")
    done
    echo "$host: updating ${trees[*]} (restarting ${containers[*]})"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        "${RSYNC[@]}" -nR "${DRY_SOURCES[@]}" "$target:$DATA/" | sed "s/^/  /"
        continue
    fi

    # Pushing per tree, not all three at once, so a tree whose container is
    # still running is never touched. Bring the containers back even if the
    # copy failed: a replica with yesterday's vault beats one with none.
    rc=0
    ssh "${SSH_OPTS[@]}" "$target" \
        "cd $REPLICA_COMPOSE_DIR && docker compose stop ${containers[*]}" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        for rel in "${trees[@]}"; do
            "${RSYNC[@]}" "$SRC/$rel/" "$target:$DATA/$rel/" >/dev/null || rc=$?
        done
    fi
    ssh "${SSH_OPTS[@]}" "$target" \
        "cd $REPLICA_COMPOSE_DIR && docker compose up -d ${containers[*]}" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "ERROR: $host push failed (rc=$rc)" >&2
        failed=1
    fi
done

exit "$failed"
