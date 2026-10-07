#!/bin/bash
# Shared definitions for the replica push on skypaw.
#
# Sourced by:
#   replicate.sh    - restores the replica trees from the latest nightly
#                     snapshot and pushes them into each replica's inbox
#
# Independent of backup/lib.sh on purpose: the two jobs share a restic
# repository and an env file and nothing else. The env file is the restic
# one because the restore needs its password and repository anyway.

ENV_FILE="${ENV_FILE:-/etc/restic/homelab.env}"

# Restore at low priority so a push never competes with the services.
RESTIC_NICE=(nice -n10 ionice -c2 -n7)

# rp_load_env: read the restic repository, DATA and the replica list.
# systemd units supply the same variables through EnvironmentFile, in
# which case the file is not read again.
rp_load_env() {
    if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
        if [[ ! -r "$ENV_FILE" ]]; then
            echo "ERROR: cannot read $ENV_FILE (run with sudo?)" >&2
            return 1
        fi
        # shellcheck disable=SC1090
        . "$ENV_FILE"
    fi
    DATA="${DATA:-/var/lib/homelab}"
    # Space-separated tailscale hostnames of the replicas. Empty means
    # replicate.sh has nothing to do.
    REPLICAS="${REPLICAS:-}"
    export RESTIC_PASSWORD DATA REPLICAS
    export RESTIC_REPOSITORY="$LOCAL_REPOSITORY"

    # The trees that travel to every replica, as tree:container pairs.
    # Trees are relative to $DATA so one list addresses the restored
    # snapshot, the bundle and the replica's data dir. The container is
    # the one the installer stops while that tree is replaced. The pairs
    # reach the replica inside each bundle's manifest, so this is the
    # only copy.
    REPLICA_TREES=(
      adguard/conf:adguard      # filters, rewrites, clients
      caddy/data:caddy          # internal CA + certs, so vault.lan verifies
      vaultwarden:vaultwarden   # vault sqlite + attachments + rsa keys
    )
    REPLICA_PATHS=("${REPLICA_TREES[@]%%:*}")
}

# rp_container <tree>: the container that owns a replica tree.
rp_container() {
    local pair
    for pair in "${REPLICA_TREES[@]}"; do
        [[ "${pair%%:*}" == "$1" ]] && { echo "${pair#*:}"; return 0; }
    done
    echo "ERROR: $1 is not a replica tree" >&2
    return 1
}

# rp_manifest <snapshot-id>: the bundle manifest on stdout. The installer
# acts only on the tree lines; the rest identifies the bundle in logs.
# Format 1 is one "tree <path> <container>" line per tree.
rp_manifest() {
    local pair
    echo "format 1"
    echo "source $(hostname)"
    echo "snapshot $1"
    echo "created $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for pair in "${REPLICA_TREES[@]}"; do
        echo "tree ${pair%%:*} ${pair#*:}"
    done
}
