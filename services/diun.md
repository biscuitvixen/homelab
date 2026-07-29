# Diun

Image update notifier ([github.com/crazy-max/diun](https://github.com/crazy-max/diun)):
checks registries for newer images and tells you on Discord. It never
updates anything.

That restraint is the whole reason it's here. Watchtower used to update
every `:latest` image at 05:00 nightly, and in April it walked mealie into
a build whose NumPy 2.x wheel raises SIGILL on this host's pre-SSE4.2 CPU.
The container died with exit code 132 before Python could log a line, so
there was no error to find, and it crash-looped at 100% CPU for three and
a half months. `WATCHTOWER_CLEANUP=true` had already deleted the last
working image. Notifications cost you a manual step; unattended updates
cost a service.

Diun reads Docker through `docker-socket-proxy` rather than the socket
directly, so a compromised notifier cannot start, stop or delete
containers. The proxy grants exactly one permission, `CONTAINERS=1`.

## Profile

`serv` and `pi`, the same profiles watchtower had. Both `diun` and
`docker-socket-proxy` come up together; Diun waits for the proxy to report
healthy.

## First-run setup

1. **Create a Discord webhook** for this host. In Discord: Server Settings
   -> Integrations -> Webhooks -> New Webhook, pick a channel, copy the
   URL. Use a dedicated one rather than sharing the VPS webhook, so you
   can tell the two hosts apart.
2. **Put it in `.env`.**
   ```sh
   DIUN_NOTIF_DISCORD_WEBHOOKURL=https://discord.com/api/webhooks/...
   ```
3. **Start it and confirm the notifier works.**
   ```sh
   docker compose --profile serv up -d docker-socket-proxy diun
   docker exec diun diun notif test
   ```
   A test message should appear in the channel. If it doesn't, check
   `docker logs diun` before touching anything else.

`DIUN_WATCH_FIRSTCHECKNOTIF=false` is set deliberately, so the first check
records the current state silently instead of announcing all eleven
services at once.

## The update list on lab.lan

`scripts/check-updates.sh --json` writes `web/lab.lan/updates.json`, which
the dashboard renders. Install the timer that keeps it fresh (as root):

```ini
# /etc/systemd/system/homelab-updates.service
[Unit]
Description=Refresh the homelab update list for the lab.lan dashboard
After=docker.service

[Service]
Type=oneshot
User=containersvc
ExecStart=/home/containersvc/homelab/scripts/check-updates.sh --json
```

```ini
# /etc/systemd/system/homelab-updates.timer
[Unit]
Description=Daily refresh of the homelab update list at 06:00

[Timer]
OnCalendar=*-*-* 06:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-updates.timer
sudo systemctl start homelab-updates.service   # populate it now
```

`User=containersvc` matters: it keeps the generated file owned by the repo
user, and that account is already in the `docker` group, so the job needs
no root privileges of its own.

## Notes

- **Seeing what needs doing:** `./scripts/check-updates.sh` joins Diun's
  view against what's actually running and prints a table. The same data
  is written to the lab.lan dashboard by a systemd timer
  (`homelab-updates.timer`, 06:00 daily) as `updates.json`.
- **Applying an update:** `./scripts/update.sh` pulls and recreates. That
  is now the only thing that changes a running image.
- **Mealie is the exception.** It runs a locally built image that exists
  in no registry, so its container carries `diun.enable=false` and the
  upstream image is watched through `configs/diun/watch.yml` instead. A
  notification for it means: bump the pinned `FROM` tag in
  `services/mealie/Dockerfile`, then
  `docker compose --profile serv build mealie && docker compose --profile serv up -d mealie`.
  Do not expect `update.sh` to move it.
- **Tag filtering:** `DIUN_DEFAULTS_INCLUDETAGS` only accepts three-part
  semver (`v1.2.3` or `1.2.3`), and `MAXTAGS=1` reports just the newest.
  Without that filter every nightly and release-candidate tag arrives as
  its own notification.
- Diun's own database lives at `${DATA}/diun` and is deliberately **not**
  in the restic backup set: it is a cache of registry state that rebuilds
  itself on the next check.
