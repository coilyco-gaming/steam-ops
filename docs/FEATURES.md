# steam-mcp features

Living inventory of what ships from this repo. One image, one process: a FastMCP server on port 9112, streamable-HTTP endpoint at `/mcp`. The repo is `steam-ops`; the image/service is `steam-mcp`.

## Tools (all read-only)

- **get_owned_games** - Kai's full owned Steam library via `IPlayerService/GetOwnedGames` (`include_appinfo=1&include_played_free_games=1`). The durable replacement for the superseded clipboard scrape's fields.
- **get_recently_played** - games played in the last two weeks via `IPlayerService/GetRecentlyPlayedGames`, a recent-activity signal.

Each returns `{source, count, items}`; `items` are normalized game records: `appid`, `name`, `playtime_forever_minutes`, `playtime_forever_hours`, `playtime_2weeks_minutes`, `last_played_unix` (None when Steam reports no last-play or the profile is private).

## Server metadata

- **Steam brand icon** - the server's `initialize` response advertises `serverInfo.icons` carrying Valve's official Steam mark (an SVG data URI, committed at [`../src/steam_mcp/assets/steam-icon.svg`](../src/steam_mcp/assets/steam-icon.svg)), so clients that render server icons - the claude.ai connector tile - show the Steam logo instead of a generic placeholder.

## Security envelope

- **Read-only by construction** - a Steam Web API key over `IPlayerService` reads a library; it cannot post, trade, refund, or act on the account (deploy#30). No write tool exists, and no tool both ingests untrusted content and can act.
- **Credentials never in the image** - the key and steamid64 resolve at runtime, server-side: env var first, then SSM SecureString via `aws ssm get-parameter --with-decryption`. Never baked into the image, repo, or committed config; the key rides in the request query string, so request URLs are never logged or returned to callers. An unconfigured secret fails loud (`ValueError`) rather than making a keyless request.
- **Network-gated reach** - the endpoint sits behind the deploy's auth/network overlay (Authelia/Traefik, added in the deploy repo), not in this source.

## Configuration (env)

- `PORT` (default 9112), `HOST` (default 0.0.0.0).
- `STEAM_WEB_API_KEY` / SSM `/steam/web-api-key` (SecureString).
- `STEAM_STEAMID64` / SSM `/steam/steam-id-64`.

Env is checked first; SSM is the fallback. The secrets never leave the box. Both SSM params **already exist** (used by steam-games-cli and the website /now) - this MCP reuses them, it does not introduce them.

## Ops helpers (client-side)

`scripts/` holds host-side helpers, **not** part of the shipped image or the MCP - they run on an operator's own [Sunshine](https://github.com/LizardByte/Sunshine) streaming host, never in the service.

- **`sunshine-sync-steam.ps1`** - rebuilds Sunshine's app list from the host's locally-installed Steam games (`appmanifest_*.acf`), so a Moonlight client shows one launchable tile per game (with PNG box art) instead of only "Desktop". It talks to the local Sunshine web API - which, running as LocalSystem, writes the admin-owned config - so no Steam Web API key and no elevation. The Sunshine password resolves from `SUNSHINE_WEB_PASSWORD` then a prompt; it never enters the repo. Idempotent (`-DryRun` previews).
- **`steam-airgap.ps1`** - toggles a Windows Firewall block on Steam's networking executables (`-On` / `-Off` / `-Status`), forcing the Steam client offline while Tailscale / Sunshine / Moonlight and the game's own traffic stay up. Lets an airgapped streaming host keep running a game (e.g. X4) while the same account plays online elsewhere - Steam can't be kicked if it can't reach its servers. Self-elevates for the firewall writes.

## Superseded predecessor

`steam_games_to_yaml.py` + `games.yaml` are the old clipboard scrape and its output, kept in place as historical data. They are not wired into the MCP and get no new work.

## Deploy

Plain outbound-HTTPS reader (no host namespaces, no hostPath). The build-publish workflow runs both jobs in the pinned aos dev-base image, then publishes the image to the in-cluster registry (`192.168.0.194:30500/steam-mcp:<sha>`) by [`.forgejo/workflows/build-publish.yml`](../.forgejo/workflows/build-publish.yml). Rollout lives in [coilyco-bridge/deploy](https://forgejo.coilysiren.me/coilyco-bridge/deploy) and is out of scope for this repo.

## See also

- [../README.md](../README.md) - human-facing intro.
- [../AGENTS.md](../AGENTS.md) - agent operating context.
- [../.ward/ward.yaml](../.ward/ward.yaml) - allowlisted commands + catalog block.

Cross-reference convention from [coilysiren/agentic-os#59](https://github.com/coilyco-flight-deck/agentic-os/issues/59).
