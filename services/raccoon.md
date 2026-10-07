# Raccoon

The replica installer. It lives in the `replica` profile, watches the
inbox that skypaw pushes bundles into, and installs only the trees that
changed since the bundle before. How a push works end to end is in
[replica/README.md](../replica/README.md); this is the Pi side.

Raccoon is the one replica container with the raw docker socket. It uses
it to stop and start `adguard`, `caddy` and `vaultwarden` around a tree
replacement, and for nothing else.

## Setup (root on the replica)

```bash
cd ~/homelab        # wherever the checkout lives on this host

# the inbox: a login that can only rsync into the staging directory
apt install -y rsync python3                  # rrsync is a python script
install -m755 services/raccoon/inbox-shell.sh /usr/local/sbin/inbox-shell
useradd --system --home-dir /var/lib/homelab/replica-inbox --shell /usr/local/sbin/inbox-shell inbox
mkdir -p /var/lib/homelab/replica-inbox/staging
chown inbox:inbox /var/lib/homelab/replica-inbox/staging
```

Then in `.env`:

```bash
COMPOSE_PROFILES=replica
DATA=/var/lib/homelab         # must match skypaw's DATA
REPLICA_PRIMARY=100.96.29.96  # skypaw's tailnet address
REPLICA_CALLHOME=true
INBOX_UID=<output of: id -u inbox>
```

and `docker compose up -d --build`. The image is built on the Pi from
`services/raccoon/Dockerfile` (alpine plus bash, rsync, inotify-tools,
docker-cli and ssh). Tag the node `tag:replica` in the admin console so
the two ACL rules in the replica README apply.

Do not start `adguard`, `caddy` or `vaultwarden` by hand before the first
push: with no data they would come up fresh, and raccoon would then
replace that state on the first bundle, which is harmless but noisy.
`unbound` is unaffected and can run throughout.

## Reading it

```bash
docker logs -f raccoon
ls /var/lib/homelab/replica-inbox/{staging,work,installed,rejected}
```

A normal night logs the bundle name, one `changed` or `unchanged` line
per tree, and `installed` for what moved. `rejected/` holds the last
bundle that failed validation, with the reason in the log; the live trees
are untouched when that happens. A bundle left in `work/` means a copy or
a container stop failed and raccoon will retry it on the next pass.

Raccoon's healthcheck is a heartbeat the watch loop touches at least once
a minute; `unhealthy` means the loop is wedged and `docker restart
raccoon` is the fix.

## Asking skypaw for a push

```bash
ssh pushreq@100.96.29.96
```

from the replica, as any user. It prints `push requested for <host>` and
returns when the push has finished. Raccoon does this itself on start
when `REPLICA_CALLHOME=true`.
