# steam-mcp features

Living inventory of what ships from this repo. One image, one process: a FastMCP server on port 9112, streamable-HTTP endpoint at `/mcp`. The repo is `steam-ops`; the image/service is `steam-mcp`.

## Tools (all read-only)

- **get_owned_games** - Kai's full owned Steam library via `IPlayerService/GetOwnedGames` (`include_appinfo=1&include_played_free_games=1`). The durable replacement for the superseded clipboard scrape's fields.
- **get_recently_played** - games played in the last two weeks via `IPlayerService/GetRecentlyPlayedGames`, a recent-activity signal.
- **get_store_app_details** and **get_store_search_results** - fixed, normalized public
  storefront app metadata and search. These calls are intentionally
  unauthenticated; no Web API key or account cookie travels to the storefront.
- **get_pics_product_info** and **get_account_licenses** - authenticated,
  read-only Steam client-protocol/PICS metadata and account license surfaces.
  Package access tokens are not included in tool results.

Existing Web API responses retain `{source, count, items}`; every plane adds
explicit `provenance.plane` (`web_api`, `storefront`, or `client_pics`). Web API
items remain normalized game records: `appid`, `name`,
`playtime_forever_minutes`, `playtime_forever_hours`,
`playtime_2weeks_minutes`, `last_played_unix` (None when Steam reports no
last-play or the profile is private).

## Server metadata

- **Steam brand icon** - the server's `initialize` response advertises `serverInfo.icons` carrying Valve's official Steam mark (an SVG data URI, committed at [`../src/steam_mcp/assets/steam-icon.svg`](../src/steam_mcp/assets/steam-icon.svg)), so clients that render server icons - the claude.ai connector tile - show the Steam logo instead of a generic placeholder.

## Security envelope

- **Read-only by construction** - a Steam Web API key over `IPlayerService` reads a library; it cannot post, trade, refund, or act on the account (deploy#30). No write tool exists, and no tool both ingests untrusted content and can act.
- **Credentials never in the image** - Web API credentials resolve env-first,
  then from SSM. Client/PICS has its own env-first refresh token. An interactive
  operator bootstrap reads the existing account name and password from SSM and
  accepts Steam Guard input outside the workload. A rotated refresh token is
  written back to its SSM SecureString without entering command arguments.
  Tokens, passwords, Guard material, and request URLs never enter logs,
  exceptions, tool results, or tracked files.
- **Network-gated reach** - the endpoint sits behind the deploy's auth/network overlay (Authelia/Traefik, added in the deploy repo), not in this source.

## Configuration (env)

- `PORT` (default 9112), `HOST` (default 0.0.0.0).
- `STEAM_WEB_API_KEY` / SSM `/steam/web-api-key` (SecureString).
- `STEAM_STEAMID64` / SSM `/steam/steam-id-64`.
- `STEAM_CLIENT_REFRESH_TOKEN` / SSM `/steam/client-refresh-token`.

Env is checked first; SSM is the fallback. The refresh token is the normal
client credential. The deployed ExternalSecret injects only that token.
`ward exec bootstrap-client` reads the existing `/steam/username` and
`/steam/password` SecureStrings through AOSGuard and stores only the issued
token. If Steam Guard needs a manual code, Kai enters it during that one-time
operator login rather than during a live MCP request.

## Ops helpers (client-side)

`scripts/` holds host-side helpers, **not** part of the shipped image or the MCP - they run on an operator's own [Sunshine](https://github.com/LizardByte/Sunshine) streaming host, never in the service.

- **`sunshine-sync-steam.ps1`** - rebuilds Sunshine's app list from the host's locally-installed Steam games (`appmanifest_*.acf`), so a Moonlight client shows one launchable tile per game (with PNG box art) instead of only "Desktop". It talks to the local Sunshine web API - which, running as LocalSystem, writes the admin-owned config - so no Steam Web API key and no elevation. The Sunshine password resolves from `SUNSHINE_WEB_PASSWORD` then a prompt; it never enters the repo. Idempotent (`-DryRun` previews).
- **`steam-airgap.ps1`** - toggles a Windows Firewall block on Steam's networking executables (`-On` / `-Off` / `-Status`), forcing the Steam client offline while Tailscale / Sunshine / Moonlight and the game's own traffic stay up. Lets an airgapped streaming host keep running a game (e.g. X4) while the same account plays online elsewhere - Steam can't be kicked if it can't reach its servers. Self-elevates for the firewall writes.

## Superseded predecessor

`steam_games_to_yaml.py` + `games.yaml` are the old clipboard scrape and its output, kept in place as historical data. They are not wired into the MCP and get no new work.

## Deploy

Plain outbound-HTTPS reader (no host namespaces, no hostPath). Every push to
canonical `main` publishes and verifies the private single-architecture image
as `forgejo.coilysiren.me/coilyco-gaming/steam-mcp:<full-source-sha>`.
[The source workflow](../.forgejo/workflows/build-publish.yml) owns publishing.
Rollout lives in
[coilyco-bridge/deploy](https://forgejo.coilysiren.me/coilyco-bridge/deploy),
which consumes the exact immutable reference with a read-only package
credential.

## See also

- [../README.md](../README.md) - human-facing intro.
- [../AGENTS.md](../AGENTS.md) - agent operating context.
- [../.ward/ward.yaml](../.ward/ward.yaml) - allowlisted commands + catalog block.

Cross-reference convention from [coilysiren/agentic-os#59](https://github.com/coilyco-flight-deck/agentic-os/issues/59).
