#!/bin/bash
# Push the replica trees from the latest nightly snapshot into each
# replica's inbox.
#
# Runs on skypaw after backup.sh, or on demand for one host when that
# host asks (see pushreq-shell.sh). Restores REPLICA_TREES from the newest
# nightly snapshot into a scratch dir, then for every host in REPLICAS
# rsyncs the trees into a fresh bundle directory under the host's inbox
# and sends the manifest last. The manifest's arrival is the replica's
# signal that the bundle is complete; what to install and which
# containers to restart is decided there, by the installer, against the
# bundle it installed previously.
#
# This host never runs a command on a replica. The login is the inbox
# user, whose shell only accepts rsync into the inbox (see
# services/raccoon/inbox-shell.sh), so a compromised skypaw can
# write files there and nothing else. Hosts are resolved with
# `tailscale ip` rather than DNS, because the DNS hosts run tailscale
# with --accept-dns=false. An unreachable replica is a warning and the
# others still run; a failed copy is an error and the job exits non-zero
# at the end.
#
# Usage:
#   sudo replica/replicate.sh [--dry-run] [--only <host>]
#
# Flags:
#   --dry-run       Itemise what each host would receive; no manifest is sent
#   --only <host>   Push to one replica, which must be listed in REPLICAS
#
# Prerequisites:
#   1. REPLICAS="asteria acrux ..." in /etc/restic/homelab.env
#   2. tailscale SSH ACL allowing this host to reach the inbox user on each
#   3. The replica running the replica profile, with the inbox set up as
#      described in services/raccoon.md

set -euo pipefail

DRY_RUN=0
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --only)    ONLY="${2:?--only needs a host}"; shift ;;
        -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
rp_load_env

REPLICA_USER="${REPLICA_USER:-inbox}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

if [[ -z "$REPLICAS" ]]; then
    echo "No REPLICAS configured in $ENV_FILE - nothing to do"
    exit 0
fi
# A request for an unlisted host is refused before any restore happens,
# so the on-demand trigger cannot push to an arbitrary name.
if [[ -n "$ONLY" ]] && ! grep -qw -- "$ONLY" <<< "$REPLICAS"; then
    echo "ERROR: $ONLY is not in REPLICAS ($REPLICAS)" >&2
    exit 2
fi

SCRATCH="$(mktemp -d /var/tmp/homelab-replicate.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

# restic recreates the absolute path under --target, so the restored tree
# sits at $SCRATCH$DATA. --include on a directory pulls everything under it.
restore_args=()
for rel in "${REPLICA_PATHS[@]}"; do
    restore_args+=(--include "$DATA/$rel")
done
snapshot="$(restic snapshots --json --latest 1 --tag nightly \
    | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[0]["short_id"] if s else "")')"
if [[ -z "$snapshot" ]]; then
    echo "ERROR: no nightly snapshot in $RESTIC_REPOSITORY" >&2
    exit 1
fi
"${RESTIC_NICE[@]}" restic restore "$snapshot" \
    --target "$SCRATCH" "${restore_args[@]}" >/dev/null
SRC="$SCRATCH$DATA"

for rel in "${REPLICA_PATHS[@]}"; do
    if [[ ! -d "$SRC/$rel" ]]; then
        echo "ERROR: $rel missing from snapshot $snapshot" >&2
        exit 1
    fi
done

# One bundle name per run, shared by every host, so a replica's installed
# manifest names the same snapshot and time skypaw logged.
created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
bundle="${created//[-:]/}"
rp_manifest "$snapshot" "$created" > "$SCRATCH/manifest"

# rsync flags: no owner/group, since the receiver is an unprivileged user
# and the installer sets root ownership on install. --delete keeps a
# re-pushed bundle an exact copy; the icon cache is excluded from backups
# and is not in the snapshot anyway. -i itemises the dry run.
RSYNC=(rsync -rlpt --delete --exclude icon_cache --timeout=120 -e "ssh ${SSH_OPTS[*]}")

# All trees go in one call with --relative, anchored at $SRC by the /./
# marker, so each lands at its own path under the bundle directory and
# the intermediate directories are created on the way. --delete under
# --relative only reaches inside the transferred trees.
SOURCES=("${REPLICA_PATHS[@]/#/$SRC/./}")

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

    # The nightly all-hosts run and a boot-time request for one host can
    # overlap; the second push to the same host is skipped, not queued.
    exec {lock}>"/run/lock/replicate-homelab-$host.lock"
    if ! flock -n "$lock"; then
        echo "WARNING: $host push already running - skipping"
        continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "$host: would push bundle $bundle (snapshot $snapshot)"
        "${RSYNC[@]}" -niR "${SOURCES[@]}" "$target:./$bundle/" | sed 's/^/  /' || true
        continue
    fi

    # The manifest goes last and only after every tree succeeded, so the
    # installer never sees a bundle that is missing part of a tree.
    rc=0
    "${RSYNC[@]}" -R "${SOURCES[@]}" "$target:./$bundle/" >/dev/null || rc=$?
    if [[ "$rc" -eq 255 ]]; then
        echo "WARNING: $host ($ip) unreachable - skipping"
        continue
    fi
    if [[ "$rc" -eq 0 ]]; then
        "${RSYNC[@]}" "$SCRATCH/manifest" "$target:./$bundle/manifest" >/dev/null || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        echo "ERROR: $host push failed (rsync rc=$rc), manifest not sent" >&2
        failed=1
        continue
    fi
    echo "$host: pushed bundle $bundle (snapshot $snapshot)"
done

exit "$failed"
