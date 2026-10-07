#!/bin/bash
# Login shell for the pushreq user on skypaw. A replica runs
# `ssh pushreq@<skypaw>` over Tailscale SSH to ask for a push of the
# replica trees to itself; nothing it sends is executed. The caller is
# identified by its tailscale node, not by anything it says, and the only
# action is starting the instanced replicate unit for that node, through
# a sudoers entry scoped to exactly that unit pattern. The start blocks
# until the push finishes, so the caller's exit status is the push's.
#
# Installed by hand to /usr/local/sbin/pushreq-shell; see
# replica/README.md.

ip="${SSH_CLIENT%% *}"
if [[ -z "$ip" ]]; then
    echo "pushreq: not an ssh session" >&2
    exit 1
fi

name="$(tailscale whois --json "$ip" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["Node"]["ComputedName"])' 2>/dev/null)"
if ! [[ "$name" =~ ^[a-z0-9-]+$ ]]; then
    echo "pushreq: cannot identify $ip as a tailscale node" >&2
    exit 1
fi

echo "pushreq: push requested for $name"
exec sudo -n systemctl start "replicate-homelab@$name.service"
