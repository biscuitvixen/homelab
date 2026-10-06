# Backup

All stateful service data lives on the local disk under `$DATA`
(default `/var/lib/homelab`) — never on the NFS mount, because SQLite and
NFS locking do not mix (that's what kept killing mealie). The NAS instead
receives nightly restic snapshots.

The SQLite-writer containers (mealie, vaultwarden, atuin, homeassistant,
mosquitto, scarlet, uptime-kuma) are paused briefly each night for a clean snapshot,
then unpaused unconditionally via a shell trap. AdGuard, unbound, caddy and
tailscale stay up throughout — pausing adguard would kill DNS for the whole
LAN, and pausing tailscale would drop remote access.

Two-stage design:
1. **restic → local repo** on the host disk (`$LOCAL_REPOSITORY`) — always runs, fast, works when the NAS is down
2. **restic copy → NFS mount** on the NAS (`$REMOTE_REPOSITORY` under `$REMOTE_MOUNT`) — best-effort copy, skipped cleanly if the mount is unavailable. Uses `restic copy` (not rsync) so the NAS holds an independent restic repo with shared chunker params, preserving dedup across both repos.

All paths are configured via the env file in step 2 below, loaded by the
scripts and the systemd unit.

## Schedule

04:00 daily (host local time). This originally had to beat watchtower's
05:00 image-update sweep, since an auto-update recreating a paused
container would break the unpause safety net. Watchtower has been replaced
by Diun, which only notifies, so nothing recreates containers behind this
job. The time is kept because 04:00 is quiet, not because it has to be.

## What is backed up

| Path | Contents | Why |
|------|----------|-----|
| `$DATA/adguard/conf` | AdGuardHome.yaml | Filters, DNS rewrites, clients, admin login |
| `$DATA/atuin` | SQLite DB | Synced shell history |
| `$DATA/caddy/data` | Internal CA + issued certs | LAN devices trust this CA — losing it means re-installing the root cert everywhere |
| `$DATA/homeassistant` | Config, `.storage`, recorder SQLite | Automations, integrations, entity registry, history |
| `$DATA/mealie` | SQLite DB + images | Recipes |
| `$DATA/mosquitto` | Persistence store | Retained MQTT messages |
| `$DATA/scarlet` | SQLite DB | Bot state (user timezones etc) |
| `$DATA/uptime-kuma` | SQLite DB | Monitors, notifications, heartbeat history |
| `$DATA/dozzle` | `users.yml` | Log viewer logins (bcrypt hashes) |
| `$DATA/vaultwarden` | SQLite DB, attachments, RSA keys | The password vault. The single most important path in this table |
| `<repo>/.env` | Deployed secrets | Required to start the stack. Same security boundary as the restic password file (both plaintext on this host), so no extra exposure |

Not backed up: `$DATA/adguard/work` (query log + stats, rebuilt from conf),
`$DATA/caddy/config` (admin API autosave, rebuilt from the Caddyfile),
`$DATA/vaultwarden/icon_cache`, `$DATA/homeassistant/{deps,tts}`, `*.log`,
the `scarlet_lavalink_plugins` volume (plugin jars re-download on start),
and tailscale state (host package under `/var/lib/tailscale`; a rebuilt
host re-auths, which is one command).

## Setup

`scripts/migrate-to-local.sh` performs steps 3–4 (repo init + first snapshot)
as part of the migration off the NFS mount. The steps are listed here for
manual/DR setup.

### 1. Install restic (and jq, used by the CLI's copy dry-run)

```bash
apt install restic jq
```

### 2. Create the env file

Holds the encryption password and the repo paths. Loaded by systemd as an
`EnvironmentFile`, so it must be in `KEY=VAL` format.

```bash
sudo mkdir -p /etc/restic
sudo tee /etc/restic/homelab.env > /dev/null <<EOF
RESTIC_PASSWORD=your-strong-password-here
LOCAL_REPOSITORY=/var/backups/homelab-restic
REMOTE_MOUNT=/mnt/skypaw-core
REMOTE_REPOSITORY=/mnt/skypaw-core/backups/homelab-restic
DATA=/var/lib/homelab
REPLICAS="asteria acrux"
EOF
sudo chmod 600 /etc/restic/homelab.env
```

**Keep a copy of `RESTIC_PASSWORD` somewhere off this host** (e.g. in the
vault on another device). An encrypted repo with a lost password is a paperweight.

The scripts export `RESTIC_REPOSITORY="$LOCAL_REPOSITORY"` so restic itself
sees the local repo by default; the NAS repo is passed explicitly via
`-r "$REMOTE_REPOSITORY"` only at copy/restore time.

### 3. Initialise the local repository

```bash
. /etc/restic/homelab.env
sudo mkdir -p "$LOCAL_REPOSITORY"
sudo -E restic -r "$LOCAL_REPOSITORY" init
```

### 4. Initialise the NAS-side restic repo

The NFS mount at `/mnt/skypaw-core` already exists on this host (it's the
old `${BASE}` mount). Check `/etc/fstab` has `nofail,soft,timeo=30` on it so
an offline NAS times out cleanly instead of hanging the backup job or boot:

```
truenas.lan:/mnt/<pool>/<dataset>  /mnt/skypaw-core  nfs  _netdev,nofail,soft,timeo=30,vers=4  0 0
```

The export's mapall squashing is fine here — restic doesn't care who owns
its pack files; ownership is recorded *inside* the snapshots.

The two restic repos must share chunker params for dedup to carry across.
Initialise the destination with `--copy-chunker-params` pointing at the
existing local repo:

```bash
. /etc/restic/homelab.env
export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"
sudo -E restic -r "$REMOTE_REPOSITORY" init \
  --copy-chunker-params --from-repo "$LOCAL_REPOSITORY"
```

After this, the nightly `restic copy` step only ships new pack files each run.

### 5. Install the systemd units

Create `/etc/systemd/system/backup-homelab.service`:
```ini
[Unit]
Description=Homelab restic backup
After=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/homelab.env
ExecStart=/home/containersvc/homelab/backup/backup.sh
User=root
```

(Adjust `ExecStart` to wherever this repo is checked out on the server.)

Create `/etc/systemd/system/backup-homelab.timer`:
```ini
[Unit]
Description=Daily homelab backup at 04:00

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:
```bash
chmod +x backup/backup.sh backup/backup-cli.sh backup/replicate.sh
sudo systemctl daemon-reload
sudo systemctl enable --now backup-homelab.timer
```

The replica push has its own pair, `replicate-homelab.service` and
`.timer`, identical in shape with `ExecStart=/home/containersvc/homelab/backup/replicate.sh`
and `OnCalendar=*-*-* 04:30:00`, so it always runs against the snapshot
the 04:00 job just wrote.

## Verify

Check the timer is scheduled:
```bash
systemctl list-timers backup-homelab
```

Check last run status and logs:
```bash
sudo systemctl status backup-homelab
sudo journalctl -u backup-homelab -n 50
```

List snapshots (via the CLI wrapper — it sources the env file for you):
```bash
sudo backup/backup-cli.sh snapshots            # local repo
sudo backup/backup-cli.sh snapshots --remote   # NAS repo
```

## Manual operations

`backup-cli.sh` is a thin wrapper around the same `lib.sh` that the nightly
job uses, so manual runs use identical paths, container set, retention
policy, and nice/ionice tuning. Run with `sudo` (needs to read
`/etc/restic/homelab.env` and root-owned service data).

Interactive menu:
```bash
sudo backup/backup-cli.sh menu
```

Single commands:
```bash
sudo backup/backup-cli.sh backup           # pause containers, backup, unpause
sudo backup/backup-cli.sh forget           # apply retention policy + prune
sudo backup/backup-cli.sh copy             # mirror local repo to the NAS
sudo backup/backup-cli.sh snapshots        # list snapshots (add --remote for the NAS)
sudo backup/backup-cli.sh check            # verify repo integrity
sudo backup/backup-cli.sh stats            # repo size / dedup stats
sudo backup/backup-cli.sh unlock           # remove stale repo locks
sudo backup/backup-cli.sh pause            # pause containers only
sudo backup/backup-cli.sh unpause          # unpause containers only
```

Dry-run flags:
```bash
sudo backup/backup-cli.sh backup --dry-run   # backup with no writes (also skips pause/unpause)
sudo backup/backup-cli.sh forget --dry-run   # show what forget+prune would remove
sudo backup/backup-cli.sh copy --dry-run     # show what copy would ship
sudo backup/backup-cli.sh dry-run            # full pipeline dry-run (backup+forget+copy)
```

### Tags and retention

Every snapshot carries `homelab`. On top of that:

- **Nightly** snapshots (from the systemd job) are tagged `nightly`.
- **Manual** snapshots (from `backup-cli.sh backup`) are tagged `manual`.

The retention policy in `hl_forget` (7 daily / 4 weekly / 3 monthly /
1 yearly) is scoped to `--tag nightly`, so manual snapshots are **never
selected for forget and are kept indefinitely**. That's deliberate: a manual
snapshot is taken at a specific moment for a reason (before an upgrade,
before a destructive maintenance op — or the `initial-migration` snapshot),
and the point is to preserve that exact state until you decide otherwise.

To clean up a manual snapshot when you no longer need it:
```bash
sudo backup/backup-cli.sh snapshots        # find the ID
sudo backup/backup-cli.sh delete <id>
```

Retention also uses `--group-by host,tags` so all nightly snapshots pool into
a single bucket regardless of which paths they covered. Without this, any
change to the path list (adding/removing a service, moving the data dir)
would start a new restic group that retention treats independently, producing
orphan single-snapshot groups that never age out.

## Restore

Source the env file; restic then targets the local repo by default:
```bash
. /etc/restic/homelab.env
export RESTIC_REPOSITORY="$LOCAL_REPOSITORY"
```

Restore something to a temp location for inspection (snapshots store
absolute paths, so `--include` takes the full path):
```bash
sudo -E restic restore latest \
  --target /tmp/homelab-restore \
  --include "/var/lib/homelab/mealie"
# Files land at: /tmp/homelab-restore/var/lib/homelab/mealie/
```

Restore one service in place (stop it first):
```bash
docker compose stop vaultwarden
sudo -E restic restore latest --target / --include "/var/lib/homelab/vaultwarden"
docker compose start vaultwarden
```

Restore from a specific snapshot instead of `latest`:
```bash
sudo -E restic snapshots   # find the snapshot ID
sudo -E restic restore abc12345 --target / --include "/var/lib/homelab/vaultwarden"
```

Full disaster recovery after a host rebuild (local repo gone — pull from the
NAS copy; you need the restic password from your off-host copy):
```bash
. /etc/restic/homelab.env
sudo -E restic -r "$REMOTE_REPOSITORY" restore latest --target /
```
Then fix ownership for the non-root writer (`chown -R 1883:1883
/var/lib/homelab/mosquitto`), reinstall the systemd units, and
`docker compose up -d`.

## Replication

Every Pi in the `replica` profile carries a copy of three trees from the
latest nightly snapshot: `adguard/conf`, `caddy/data` and `vaultwarden`.
`backup/replicate.sh` restores them here and pushes them out; the replicas
hold no restic password and never see the repo, only plain files over
tailscale SSH.

Per host it takes a dry rsync to learn which trees changed, stops only the
containers that own them, copies, and brings them back with `compose up`.
Most nights only the vault moves, so replica DNS is untouched. A replica
that is off (the office Pi at the weekend) is a warning and the rest still
run; a failed copy is an error and the timer shows it.

Because skypaw is the source of truth, a setting changed on a replica's
AdGuard is reverted on the next push. Change it on skypaw.

```bash
sudo backup/replicate.sh --dry-run            # what each host would receive
sudo backup/replicate.sh --only asteria       # one host, e.g. after a rebuild
```

What the replicas need:
- `REPLICAS` in `/etc/restic/homelab.env`: tailscale hostnames, space
  separated. The script resolves them with `tailscale ip`, not DNS.
- A tailscale SSH ACL letting this host reach `root` on each. The push
  runs as root on the replica so it can replace files the containers
  rewrote as root and keep skypaw's ownership.
- The repo checked out with `COMPOSE_PROFILES=replica` in its `.env` and
  the same `DATA` path as here. `REPLICA_COMPOSE_DIR` in
  `/etc/restic/homelab.env` names the checkout when it is not
  `/home/containersvc/homelab`.
- `VAULTWARDEN_SIGNUPS_ALLOWED=false`, which is now the compose default.

Not yet built: a call-home on boot so a replica with `DATA` on tmpfs
refills itself, and an encrypted export of writes made while a replica is
promoted. Until then, a promoted replica's changes live only in its RAM
or on its disk.
