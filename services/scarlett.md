# Scarlett

A Discord bot ([github.com/biscuitvixen/scarlett_ai](https://github.com/biscuitvixen/scarlett_ai)): personality chat, timestamp coordination, and music in voice channels.

Only the CPU parts run in the homelab, `scarlett-bot` and `scarlett-lavalink` (its audio server). The LLM stays on the GPU host (the Spark) and is reached over the network, so the two boxes stay decoupled: point `SCARLETT_LLM_BASE_URL` at the Spark's OpenAI-compatible endpoint. No ports are published (the bot is outbound-only, Lavalink is internal to `homelab_network`), so there's no reverse-proxy or dashboard entry.

## Profile

Runs under the `serv` profile, and has its own `ai` profile to bring it up alone:

```sh
docker compose --profile ai up -d
```

## First-run setup

1. **Make the bot image reachable.** It's published to GHCR by the app's CI, but GHCR packages are private by default. Either make `ghcr.io/biscuitvixen/scarlett_ai` public, or authenticate on this host once:
   ```sh
   docker login ghcr.io    # username = your GitHub user, password = a PAT with read:packages
   ```
2. **Fill in `.env`** — at minimum `SCARLETT_DISCORD_TOKEN`, `SCARLETT_LLM_BASE_URL` (the Spark), and `SCARLETT_LLM_MODEL`.
3. **Fix the Lavalink plugins volume.** Lavalink runs as uid 322 but Docker creates the volume as root, so the first plugin download fails until:
   ```sh
   docker run --rm -v homelab_scarlett_lavalink_plugins:/p alpine chown -R 322:322 /p
   ```
   (Confirm the exact volume name with `docker volume ls | grep scarlett`.)
4. **YouTube OAuth.** Start with `SCARLETT_YOUTUBE_OAUTH_REFRESH_TOKEN` blank, watch `docker compose logs -f scarlett-lavalink` for a device-link URL and code, authorise with a **burner** Google account (never your main one), then paste the refresh token it logs into `.env` and restart.

## Notes

- `watchtower` (already in this stack) will auto-pull new bot images as the app's CI publishes them.
- Personality lives in `configs/scarlett/personality.md`; edit it and the next reply uses it, no restart needed.
- Lavalink config is `configs/scarlett/application.yml`; the OAuth token is injected from `.env`, not stored there.
