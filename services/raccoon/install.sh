#!/bin/bash
# Raccoon, the replica installer: watches the inbox for bundles pushed from skypaw and
# installs the trees that changed since the last installed bundle.
#
# A bundle is a directory under staging/ holding one or more trees and a
# manifest; the manifest arrives last, so its presence means the bundle
# is complete. Each tree in the manifest names the container that owns
# it. A tree is installed only if its content differs from the copy of
# the previously installed bundle kept under installed/, which no
# container ever touches; comparing against the live tree instead would
# flag every night, because the owning containers rewrite their own files
# on start. Install means: stop the owning container if it is running,
# replace the live tree, start it again.
#
# Runs as root inside the container with the docker socket mounted. The
# socket is what lets it stop and start the three named containers; it
# never creates or removes anything, and a container that does not exist
# is left for compose.
#
# Layout under $INBOX (which lives under $DATA, so a tmpfs replica loses
# it with everything else and refills from scratch):
#   staging/<bundle>/   written by the inbox user over rsync
#   work/<bundle>/      claimed by this script, being installed
#   installed/<tree>    pristine copy of the last installed tree
#   installed/manifest  manifest of the last installed bundle
#   rejected/<bundle>   the last bundle that failed validation
#
# Environment:
#   DATA             live data root inside the container (default /data)
#   INBOX            inbox root (default $DATA/replica-inbox)
#   INBOX_UID        uid of the inbox user, owner of staging/
#   REPLICA_PRIMARY  skypaw's tailnet address, for the boot-time call-home
#   REPLICA_CALLHOME true to ask skypaw for a push on start
#   INSTALLER_ONCE   set to process what is already present and exit

set -uo pipefail

DATA="${DATA:-/data}"
INBOX="${INBOX:-$DATA/replica-inbox}"
STAGING="$INBOX/staging"
WORK="$INBOX/work"
INSTALLED="$INBOX/installed"
REJECTED="$INBOX/rejected"
HEARTBEAT=/run/heartbeat

log()   { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
error() { log "ERROR: $*" >&2; }

# Ownership is only settable as root; the test harness runs unprivileged.
OWN=()
[[ $EUID -eq 0 ]] && OWN=(--chown=root:root)

setup() {
    [[ -d "$DATA" ]] || { error "$DATA is not mounted"; exit 1; }
    if [[ -z "${INSTALLER_ONCE:-}" && ! -S /var/run/docker.sock ]]; then
        error "docker socket is not mounted"; exit 1
    fi
    mkdir -p "$STAGING" "$WORK" "$INSTALLED" "$REJECTED"
    if [[ -n "${INBOX_UID:-}" ]]; then
        chown "$INBOX_UID" "$STAGING" 2>/dev/null \
            || log "WARNING: cannot chown staging to uid $INBOX_UID"
    fi
}

# Parsed manifest of the bundle being processed: "rel container" lines.
TREES=()

# validate <bundle-dir>: fills TREES or explains why the bundle is bad.
validate() {
    local bundle="$1" line kind rel container
    TREES=()
    [[ -f "$bundle/manifest" ]] || { error "no manifest"; return 1; }
    [[ "$(head -n1 "$bundle/manifest")" == "format 1" ]] \
        || { error "unknown manifest format: $(head -n1 "$bundle/manifest")"; return 1; }
    while read -r kind rel container; do
        [[ "$kind" == "tree" ]] || continue
        if ! [[ "$rel" =~ ^[a-z0-9_-]+(/[a-z0-9_-]+)?$ && "$container" =~ ^[a-z0-9_-]+$ ]]; then
            error "bad tree line: $kind $rel $container"; return 1
        fi
        [[ -d "$bundle/$rel" ]] || { error "tree $rel missing from bundle"; return 1; }
        TREES+=("$rel $container")
    done < "$bundle/manifest"
    [[ ${#TREES[@]} -gt 0 ]] || { error "manifest lists no trees"; return 1; }
}

# changed <bundle-dir> <rel>: true if the tree differs in content from the
# last installed copy. Itemised lines starting with "." are attribute-only
# differences (mtime, permissions) and do not count; -c compares content
# rather than size and time.
changed() {
    local bundle="$1" rel="$2"
    [[ -d "$INSTALLED/$rel" ]] || return 0
    rsync -rlc -n --delete --out-format='%i %n' "$bundle/$rel/" "$INSTALLED/$rel/" \
        | grep -qv '^\.'
}

reject() {
    local bundle="$1"
    rm -rf "${REJECTED:?}"/*
    mv "$bundle" "$REJECTED/"
    error "bundle $(basename "$bundle") rejected"
}

# process_bundle <bundle-dir>
process_bundle() {
    local bundle="$1" name rel container state
    local -a todo=() stopped=()
    local -A was_running=()
    name="$(basename "$bundle")"
    log "bundle $name: $(grep -E '^(snapshot|created) ' "$bundle/manifest" 2>/dev/null | tr '\n' ' ')"

    validate "$bundle" || { reject "$bundle"; return 1; }

    for line in "${TREES[@]}"; do
        read -r rel container <<< "$line"
        if changed "$bundle" "$rel"; then
            log "  $rel: changed (restart $container)"
            todo+=("$line")
        else
            log "  $rel: unchanged"
        fi
    done

    if [[ ${#todo[@]} -eq 0 ]]; then
        cp "$bundle/manifest" "$INSTALLED/manifest"
        rm -rf "$bundle"
        log "bundle $name: nothing to install"
        return 0
    fi

    # Stop every affected container first so a tree is never replaced
    # under a running process. A container that is absent or already
    # stopped is left in that state afterwards.
    for line in "${todo[@]}"; do
        read -r rel container <<< "$line"
        [[ -n "${was_running[$container]:-}" ]] && continue
        state="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo missing)"
        was_running[$container]="$state"
        if [[ "$state" == "true" ]]; then
            if docker stop "$container" >/dev/null; then
                stopped+=("$container")
            else
                error "cannot stop $container; bundle $name left in work/ for the next pass"
                for container in "${stopped[@]}"; do docker start "$container" >/dev/null; done
                return 1
            fi
        fi
    done

    # -c on the live copy as well, so the decision above and the copy
    # agree on what differs; size-and-mtime alone can miss a same-sized
    # file rewritten within the same second.
    local rc=0
    for line in "${todo[@]}"; do
        read -r rel container <<< "$line"
        mkdir -p "$DATA/$rel"
        if rsync -rlptDc --delete "${OWN[@]}" --exclude icon_cache "$bundle/$rel/" "$DATA/$rel/"; then
            rm -rf "${INSTALLED:?}/$rel"
            mkdir -p "$(dirname "$INSTALLED/$rel")"
            mv "$bundle/$rel" "$INSTALLED/$rel"
            log "  $rel: installed"
        else
            error "  $rel: copy failed; live tree may be partial"
            rc=1
        fi
    done

    # Bring back what was running even after a failed copy: yesterday's
    # files beat no service at all.
    for container in "${stopped[@]}"; do
        docker start "$container" >/dev/null || { error "cannot start $container"; rc=1; }
    done

    if [[ "$rc" -eq 0 ]]; then
        cp "$bundle/manifest" "$INSTALLED/manifest"
        rm -rf "$bundle"
        log "bundle $name: installed"
    else
        log "bundle $name: finished with errors, left in work/"
    fi
    return "$rc"
}

# Bundles whose manifest has arrived move from staging to work, oldest
# first; a bundle still being written stays where it is.
take_staging() {
    local d
    for d in "$STAGING"/*/; do
        [[ -d "$d" && -f "$d/manifest" ]] || continue
        mv "$d" "$WORK/"
    done
}

process_work() {
    local d
    for d in "$WORK"/*/; do
        [[ -d "$d" ]] || continue
        process_bundle "${d%/}" || true
    done
}

# Ask skypaw for a push. tailscaled on the host may still be coming up at
# boot, so retry for a while and never treat failure as fatal.
callhome() {
    local i
    for i in $(seq 1 20); do
        if ssh -o BatchMode=yes -o ConnectTimeout=10 \
               -o StrictHostKeyChecking=accept-new \
               -o UserKnownHostsFile="$INBOX/known_hosts" \
               "pushreq@$REPLICA_PRIMARY" 2>&1 | sed 's/^/  pushreq: /'; then
            log "call-home: push requested from $REPLICA_PRIMARY"
            return 0
        fi
        sleep 30
    done
    log "WARNING: call-home to $REPLICA_PRIMARY failed after 10 minutes"
}

setup
process_work
take_staging
process_work
[[ -n "${INSTALLER_ONCE:-}" ]] && exit 0

if [[ "${REPLICA_CALLHOME:-false}" == "true" && -n "${REPLICA_PRIMARY:-}" ]]; then
    callhome &
fi

log "watching $STAGING"
while true; do
    # Timeout keeps the heartbeat fresh and catches anything inotify
    # missed; 2 is inotifywait's timeout exit status.
    inotifywait -q -t 60 -r -e moved_to,close_write,create "$STAGING" >/dev/null 2>&1
    touch "$HEARTBEAT"
    take_staging
    process_work
done
