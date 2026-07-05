# Migration runbook: NFS → local storage + restic

Deploy-day checklist for cutting the server over from the old `${BASE}`
(NFS) layout to local `$DATA` storage with nightly restic backups. Full
background in [backup/README.md](../backup/README.md); the heavy lifting is
automated by [`migrate-to-local.sh`](migrate-to-local.sh).

> **Run this from LAN SSH or the Proxmox console, NOT over Tailscale** —
> the whole stack, including tailscale, is stopped mid-migration.

## 0. Before starting

- [ ] Pull this branch on the server and `cp .env.example .env` diff-check:
      your existing `.env` needs `DATA=/var/lib/homelab` added (and `BASE=`
      can be deleted).
- [ ] `sudo apt install restic jq` (rsync is usually present).
- [ ] Check disk headroom: the LXC disk now holds all service data **plus**
      the local restic repo. `du -sh /mnt/skypaw-core/appdata` for a rough
      size; the script enforces 2× free.

## 1. Create the restic env file

```bash
sudo mkdir -p /etc/restic
sudo tee /etc/restic/homelab.env > /dev/null <<EOF
RESTIC_PASSWORD=$(openssl rand -base64 32)
LOCAL_REPOSITORY=/var/backups/homelab-restic
REMOTE_MOUNT=/mnt/skypaw-core
REMOTE_REPOSITORY=/mnt/skypaw-core/backups/homelab-restic
DATA=/var/lib/homelab
EOF
sudo chmod 600 /etc/restic/homelab.env
sudo cat /etc/restic/homelab.env   # copy RESTIC_PASSWORD into the vault on ANOTHER device
```

Storing the password off-host is not optional: the vault it would normally
live in (vaultwarden) is *inside* the backup.

## 2. Migrate

```bash
sudo scripts/migrate-to-local.sh --dry-run   # read the plan
sudo scripts/migrate-to-local.sh             # do it
```

Stops the stack, copies everything to `$DATA`, fixes ownership, initialises
both restic repos, and takes an `initial-migration` snapshot. Old NAS data is
left untouched. Expected warnings:

- `source /mnt/skypaw-core/appdata/scarlett/data does not exist - will skip`
  — fine, Scarlett has never run on this box; her data dir is created fresh
  on first start.

## 3. Install the systemd timer

Unit texts are in [backup/README.md](../backup/README.md) step 5 (service +
timer, 04:00 daily — before watchtower's 05:00 sweep). Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now backup-homelab.timer
systemctl list-timers backup-homelab
```

## 4. Bring the stack up and verify

```bash
docker compose --profile serv up -d
docker compose ps            # wait for healthy
docker compose logs -f       # watch for permission errors
```

- [ ] DNS resolves: `dig @192.168.0.10 lab.lan`
- [ ] https://lab.lan loads with **no new cert warning** (CA survived the move)
- [ ] Vaultwarden: log in, open an item
- [ ] Mealie: open a recipe with an image
- [ ] Atuin: `atuin sync` from a client
- [ ] Home Assistant: history graphs show pre-migration data
- [ ] Mosquitto: `mosquitto_sub -h 192.168.0.10 -t '$SYS/broker/version' -C 1`
- [ ] Tailscale: `docker exec tailscale tailscale status` — online, no re-auth
- [ ] Scarlett: online in Discord (first run — do the plugins-volume chown
      and YouTube OAuth from [services/scarlett.md](../services/scarlett.md))

## 5. Prove the backup path

```bash
sudo backup/backup-cli.sh snapshots            # initial-migration snapshot present
sudo backup/backup-cli.sh snapshots --remote   # ...and on the NAS
sudo systemctl start backup-homelab.service    # one manual nightly run
sudo journalctl -u backup-homelab -n 30
```

Restore test (mandatory — a backup you've never restored is a hope, not a backup):

```bash
. /etc/restic/homelab.env
sudo -E restic restore latest --target /tmp/restore-test --include "$DATA/mealie"
sudo sqlite3 /tmp/restore-test/var/lib/homelab/mealie/mealie.db 'PRAGMA integrity_check;'
sudo rm -rf /tmp/restore-test
```

## 6. Only after a few clean nightlies

Archive the old NAS data and drop the retired volumes:

```bash
mv /mnt/skypaw-core/appdata /mnt/skypaw-core/appdata.pre-migration
mv /mnt/skypaw-core/configs/adguard        /mnt/skypaw-core/configs/adguard.pre-migration
mv /mnt/skypaw-core/configs/homeassistant  /mnt/skypaw-core/configs/homeassistant.pre-migration
mv /mnt/skypaw-core/configs/tailscale      /mnt/skypaw-core/configs/tailscale.pre-migration
docker volume rm homelab_caddy_config homelab_mealie_data
```
