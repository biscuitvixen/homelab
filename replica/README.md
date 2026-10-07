# Replicas

A raccoon on every Pi and a pigeon on skypaw. The pigeon can drop parcels
through one letterbox; the raccoon decides what to do with them.

Every Pi in the `replica` profile carries a copy of three trees from the
latest nightly snapshot: `adguard/conf`, `caddy/data` and `vaultwarden`.
skypaw restores them from restic and pushes them into an inbox on each
replica; the replica installs them itself. The replicas hold no restic
password and never see the repo, and skypaw never runs a command on a
replica or holds a login there that can write outside the inbox.

## How a push works

```
skypaw (root, 04:30 timer or on request)        replica
  restic restore -> scratch                       $DATA/replica-inbox/
  rsync trees    -> inbox@pi:./<bundle>/   --->     staging/<bundle>/   written by the inbox user
  rsync manifest -> inbox@pi:./<bundle>/manifest   work/<bundle>/      claimed by raccoon
                                                   installed/          last installed copy of each tree
  pushreq-shell  <--- ssh pushreq@skypaw <---      rejected/           the last bad bundle
                                                 raccoon container
```

1. `replica/replicate.sh` restores the trees from the newest `nightly`
   snapshot into a scratch dir and writes a manifest naming the snapshot,
   the time, and which container owns each tree.
2. For each host in `REPLICAS` it resolves the tailnet address with
   `tailscale ip`, then rsyncs the trees into a fresh bundle directory
   under the replica's inbox as the `inbox` user. That user's login shell
   (`services/raccoon/inbox-shell.sh`) accepts nothing but an rsync server
   confined to the staging directory, write-only.
3. The manifest is sent last and only if every tree succeeded. Its
   arrival is the signal that the bundle is complete.
4. Raccoon (`services/raccoon/install.sh`) moves the bundle to `work/`,
   compares each tree's content with the copy of the previous bundle it
   keeps under `installed/`, stops the containers whose trees changed,
   replaces those trees, starts the containers, and keeps the new copy as
   the reference. Unchanged trees are discarded. Most nights only the
   vault moves and replica DNS is never interrupted.

The comparison is against the last bundle, not the live tree, because the
owning containers rewrite their own files on every start (AdGuard
normalises its YAML, Caddy re-saves certificate metadata, Vaultwarden
rolls its WAL). A live comparison would restart everything every night.

Because skypaw is the source of truth, a setting changed on a replica's
AdGuard is reverted on the next push that carries a changed config.
Change it on skypaw.

A replica that is off is a warning and the others still run; a failed
copy is an error, the manifest is withheld so the replica ignores the
partial bundle, and the job exits non-zero.

## Asking for a push

A replica can request its own push: `ssh pushreq@<skypaw tailnet ip>`
over Tailscale SSH. The `pushreq` login shell
(`replica/pushreq-shell.sh`) identifies the caller from its tailscale
node, not from anything it sends, and starts
`replicate-homelab@<node>.service` through a sudoers entry scoped to that
unit pattern. Raccoon does this on start when `REPLICA_CALLHOME=true`,
which is how a replica with `DATA` on tmpfs refills itself after a boot.
`replicate.sh` refuses any node that is not in `REPLICAS`, and a per-host
lock skips a request that overlaps the nightly run.

```bash
sudo replica/replicate.sh --dry-run             # connectivity and permissions, no manifest
sudo replica/replicate.sh --only asteria        # one host now
systemctl start replicate-homelab@asteria       # the same, as the unit
```

## skypaw setup (root)

```bash
cd /home/containersvc/homelab

# the push itself
grep -q '^REPLICAS=' /etc/restic/homelab.env || echo 'REPLICAS="asteria"' >> /etc/restic/homelab.env
cp replica/replicate-homelab.service replica/replicate-homelab.timer replica/replicate-homelab@.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now replicate-homelab.timer

# the request path
install -m755 replica/pushreq-shell.sh /usr/local/sbin/pushreq-shell
useradd --system --home-dir /var/lib/pushreq --shell /usr/local/sbin/pushreq-shell pushreq
install -m440 replica/sudoers-pushreq /etc/sudoers.d/pushreq && visudo -cf /etc/sudoers.d/pushreq
```

`REPLICA_USER` in `/etc/restic/homelab.env` overrides the `inbox` login
name if a replica uses a different one.

## Tailscale

Both directions are Tailscale SSH rules, so no keys are involved. skypaw
carries `tag:primary` (alongside `tag:server`), replicas carry
`tag:replica`:

```json
{"action": "accept", "src": ["tag:primary"], "dst": ["tag:replica"], "users": ["inbox"]},
{"action": "accept", "src": ["tag:replica"], "dst": ["tag:primary"], "users": ["pushreq"]},
```

`accept`, not `check`: a timer cannot answer a browser prompt. Nothing
grants root or any other user in either direction.

The replica-side setup is in [services/raccoon.md](../services/raccoon.md).

## Verify

From skypaw as root, after a replica is set up:

```bash
replica/replicate.sh --dry-run --only asteria   # lists the three trees
replica/replicate.sh --only asteria             # "asteria: pushed bundle ..."
replica/replicate.sh --only asteria             # again: raccoon logs "unchanged" x3
```

On the replica, `docker logs raccoon` shows the bundle, which trees
changed, and what was stopped and started. `docker inspect -f
'{{.State.StartedAt}}' adguard caddy vaultwarden` before and after the
second push proves nothing restarted.

## Promotion

Making a replica primary is a DNS change: point `vault.lan` at the
replica in the AdGuard that answers. Writes made on a promoted replica
exist only there; copy its `vaultwarden` tree back to skypaw before the
next push, or they are overwritten. Automatic failover and a read-only
standby are planned on top of this; see the session notes.
