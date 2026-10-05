# Tailscale

Tailscale runs as a host package on every box, not as a container.
Nothing in the compose stack depends on it, and a host `tailscaled`
survives compose restarts, gives every host tailscale SSH (the channel
the replica push uses), and removes the "update tailscale last, in a
detached shell" step from the update routine.

## Install

Debian and Raspberry Pi OS both take the upstream apt repo:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --accept-dns=false <site flags>
```

`--ssh` on every host, and `--accept-dns=false` on every host that runs
AdGuard, so a DNS host never depends on the tailnet nameservers it is
one of. The site flags are what used to live in `TS_ARGS`:

| host    | site flags                                                       |
|---------|------------------------------------------------------------------|
| skypaw  | `--advertise-routes=192.168.0.0/24 --advertise-exit-node`        |
| asteria | `--advertise-routes=192.168.0.0/24` (home subnet router failover) |
| acrux   | `--advertise-exit-node`                                          |
| office  | none; it sits on a guest network and must not advertise anything |

Routes and exit nodes still need approving in the admin console under
Machines. The tailscale SSH ACL and the global nameserver list are also
admin-console settings; see the replication section of
[backup/README.md](../backup/README.md).

## Migrating skypaw off the container

The container kept its node identity under `${DATA}/tailscale/state`.
Copying that file across before the first host start keeps the same
node, and therefore the same tailscale IP, which the global nameserver
list pins. This needs root, so it goes on the runsheet:

```bash
docker compose stop tailscale
apt install tailscale            # starts tailscaled logged out, fresh key
systemctl stop tailscaled
cp /var/lib/homelab/tailscale/state/tailscaled.state /var/lib/tailscale/
chmod 600 /var/lib/tailscale/tailscaled.state
systemctl start tailscaled
tailscale up --reset --ssh --accept-dns=false --hostname=skypaw \
    --advertise-routes=192.168.0.0/24 --advertise-exit-node
tailscale status --peers=false   # same IP as before, no re-auth
```

Once it is confirmed, `${DATA}/tailscale` can go; it is no longer in
the restic path list.

## Checks

```bash
tailscale status --peers=false
tailscale netcheck                # DERP-relayed on guest wifi is expected
cat /proc/sys/net/ipv4/ip_forward # 1 on skypaw, asteria and acrux
```

IP forwarding is only needed on hosts that advertise routes or act as
an exit node:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```
