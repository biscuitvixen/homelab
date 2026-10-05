# Scarlet

A Discord bot ([github.com/biscuitvixen/scarlet](https://github.com/biscuitvixen/scarlet)): personality chat, timestamp coordination, and music in voice channels.

Only the CPU parts run in the homelab, `scarlet` and `lavalink` (its audio server). The LLM stays on the GPU host (the Spark) and is reached over the network, so the two boxes stay decoupled: point `SCARLET_LLM_BASE_URL` at the Spark's OpenAI-compatible endpoint. No ports are published (the bot is outbound-only, Lavalink is internal to `homelab_network`), so there's no reverse-proxy or dashboard entry.

## Profile

Runs under the `serv` profile. To bring up just the pair:

```sh
docker compose up -d scarlet lavalink
```

## First-run setup

1. **Make the bot image reachable.** It's published to GHCR by the app's CI, but GHCR packages are private by default. Either make `ghcr.io/biscuitvixen/scarlet` public, or authenticate on this host once:
   ```sh
   docker login ghcr.io    # username = your GitHub user, password = a PAT with read:packages
   ```
2. **Fill in `.env`** — at minimum `SCARLET_DISCORD_TOKEN`, `SCARLET_LLM_BASE_URL` (the Spark), and `SCARLET_LLM_MODEL`.
3. **Fix the Lavalink plugins volume.** Lavalink runs as uid 322 but Docker creates the volume as root, so the first plugin download fails until:
   ```sh
   docker run --rm -v homelab_scarlet_lavalink_plugins:/p alpine chown -R 322:322 /p
   ```
   (Confirm the exact volume name with `docker volume ls | grep scarlet`.)
4. **Pre-create the bot's data dir.** The bot runs as uid 1000, but Docker creates the `${DATA}/scarlet` bind mount as root on first `up`, so its SQLite DB fails with `unable to open database file` until:
   ```sh
   sudo mkdir -p /var/lib/homelab/scarlet && sudo chown 1000:1000 /var/lib/homelab/scarlet
   ```
   Then `docker compose up -d scarlet`.
5. **YouTube OAuth.** Start with `SCARLET_YOUTUBE_OAUTH_REFRESH_TOKEN` blank, watch `docker compose logs -f lavalink` for a device-link URL and code, authorise with a **burner** Google account (never your main one), then paste the refresh token it logs into `.env` and restart.

## Notes

- The bot's SQLite DB lives at `${DATA}/scarlet` on the local disk and is included in the nightly restic backup (see [backup/README.md](../backup/README.md)).
- `diun` (already in this stack) notifies you on Discord when the app's CI publishes a new bot image. Nothing updates on its own; apply it with `./scripts/update.sh` when you're ready.
- Personality lives in `configs/scarlet/personality.md`; edit it and the next reply uses it, no restart needed.
- Lavalink config is `configs/scarlet/application.yml`; the OAuth token is injected from `.env`, not stored there.
- `SCARLET_MUSIC_ENABLED=false` drops the music cog and stops the bot contacting Lavalink, but it does **not** stop `lavalink` itself: the two share the `ai` compose profile, and the bot's `depends_on` still waits for it to report healthy. Reclaiming its ~295 MB means giving Lavalink a profile of its own and dropping that `depends_on` as well. Worth doing only if nobody uses `/play`.
