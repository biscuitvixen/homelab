#!/bin/bash
# Login shell for the inbox user on a replica. The only thing it will run
# is an rsync server confined to the inbox staging directory, write-only,
# so the pushing host can deliver bundles and do nothing else: no
# interactive login, no other command, no reading back, no path outside
# the directory.
#
# Tailscale SSH invokes the login shell as `shell -c <command>` and sets
# no SSH_ORIGINAL_COMMAND; rrsync refuses to start without that variable,
# so it is reconstructed from the -c argument. rrsync (shipped with rsync
# 3.2.3 and later) validates the rsync server options itself.
#
# Installed by hand to /usr/local/sbin/inbox-shell and set as the inbox
# user's shell; see ../replica-installer.md.

STAGING=/var/lib/homelab/replica-inbox/staging

refuse() {
    echo "inbox: $1" >&2
    exit 1
}

[[ $# -eq 2 && "$1" == "-c" ]] || refuse "interactive login refused"
[[ "$2" == "rsync --server "* ]] || refuse "only rsync is accepted"
[[ -d "$STAGING" ]] || refuse "staging directory missing; is the installer running?"

export SSH_ORIGINAL_COMMAND="$2"
exec /usr/bin/rrsync -wo -no-lock "$STAGING"
