#!/bin/bash
# Nightly restic backup for the homelab.
#
# Pauses the SQLite-writer containers briefly for a clean snapshot, then
# unpauses them via a trap so they always come back up even if restic fails.
# DNS/TLS (adguard, unbound, caddy) and tailscale stay up throughout.
#
# Two-stage backup:
#   1. restic → local repo on the host disk (always runs, fast)
#   2. restic copy → NFS mount on the NAS (best-effort, skipped if not mounted)
#
# Scheduled at 04:00 daily via systemd timer - deliberately before
# watchtower's 05:00 image-update sweep, which must never recreate a
# container we have paused.
#
# Shared paths, container set, and restic invocations live in backup/lib.sh
# so this file and backup-cli.sh stay in lockstep.
#
# Prerequisites:
#   1. restic installed on the host
#   2. /etc/restic/homelab.env created (see backup/README.md)
#   3. Repos initialised (scripts/migrate-to-local.sh does this, or see README)
#   4. systemd timer enabled: systemctl enable --now backup-homelab.timer

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
hl_load_env

hl_pause

hl_backup --tag nightly

# Source data is captured - bring containers back up before the slower
# repo-maintenance steps (forget/prune/copy) which only touch restic repos.
hl_unpause

# Forget+prune is best-effort: a flaky prune shouldn't skip the offsite copy
# below. Without this, set -e would abort the script and we'd lose a night
# of NAS sync over a transient prune failure (e.g. a stale lock).
rc=0
hl_forget || rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "WARNING: restic forget/prune failed (rc=$rc) - continuing to remote copy"
fi

# Best-effort copy to the NAS. mount-missing (rc=2) is a warning, not a failure.
rc=0
hl_copy || rc=$?
case "$rc" in
    0) ;;
    2) echo "WARNING: $REMOTE_MOUNT not mounted - skipping remote copy" ;;
    *) echo "WARNING: remote restic copy failed (rc=$rc) - local backup still intact" ;;
esac
