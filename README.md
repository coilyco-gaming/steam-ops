# steam-ops / steam-mcp

A read-only MCP that exposes Kai's Steam library over streamable-HTTP, so an agent (or the claude.ai hosted connector) can read owned-games and recently-played straight from the Steam Web API - no scraping, no clipboard.

It is the second pure-read clone of the [coilyco-bridge/deploy#30](https://forgejo.coilysiren.me/coilyco-bridge/deploy) personal-MCP fleet, and its second **credential shape**: a Steam Web API key over `IPlayerService`, next to [reddit-mcp](https://forgejo.coilysiren.me/coilyco-flight-deck/reddit-mcp)'s feed URL - proving the DRY deploy substrate generalizes across shapes.

> **The repo is `steam-ops`, but the image and service are `steam-mcp`.** CI publishes `192.168.0.194:30500/steam-mcp:<sha>`.

## Superseded: the clipboard scrape

`steam_games_to_yaml.py` and `games.yaml` are the **superseded** predecessor - a manual select-all-copy scrape of the rendered games page. They are **left in place as data, not deleted.** The scrape's own docstring already named the durable path this MCP now wraps: `IPlayerService/GetOwnedGames?include_appinfo=1&include_played_free_games=1` (clean JSON from an API key + steamid64). New work goes through the MCP.

## Tools (all read-only)

- **get_owned_games** - full owned library via `IPlayerService/GetOwnedGames` (`include_appinfo=1&include_played_free_games=1`): appid, name, playtime, last-played.
- **get_recently_played** - last-two-weeks activity via `IPlayerService/GetRecentlyPlayedGames`.

Each returns `{source, count, items}` with normalized records (`appid`, `name`, `playtime_forever_minutes`, `playtime_forever_hours`, `playtime_2weeks_minutes`, `last_played_unix`).

## Read-only by construction

A Web API key over `IPlayerService` **reads** a library - it cannot post, trade, or refund (deploy#30). There is no write tool, and no path that both ingests untrusted content and can act. Like reddit-mcp, it is a **plain outbound-HTTPS reader**: no `hostPID`, `hostNetwork`, or `hostPath`. The auth overlay is added in the deploy repo, not here (deploy#28: the source stays unchanged by the overlay).

## Credential custody

The key and steamid64 are private and **never** live in the image, the repo, or a committed config. Each resolves at runtime, server-side: an env var first, then SSM SecureString via `aws ssm get-parameter --with-decryption`.

- `STEAM_WEB_API_KEY` / SSM `/steam/web-api-key` (SecureString)
- `STEAM_STEAMID64` / SSM `/steam/steam-id-64`

Env-first lets the deploy inject via an ExternalSecret without granting the pod `ssm:GetParameter`; the SSM fallback mirrors reddit-mcp's resolver. The secrets never leave the box.

> **Operator prereq:** these two SSM params **already exist** (used by steam-games-cli and the website /now) - the MCP reuses them, no new provisioning: `/steam/web-api-key` (a key from https://steamcommunity.com/dev/apikey) and `/steam/steam-id-64` (the 64-bit steamid).

## Port

Streamable-HTTP on `PORT` (default **9112**), `HOST` (default `0.0.0.0`), endpoint at `/mcp`. Fleet ports: node-stats `9110`, reddit `9111`, steam `9112`.

## Run it locally

```sh
ward sync
STEAM_WEB_API_KEY='...' STEAM_STEAMID64='7656119...' ward run
```

## Commands

Dev commands are declared in [`.ward/ward.yaml`](.ward/ward.yaml). Run them as `ward <verb>`.

## See also

- [AGENTS.md](AGENTS.md) - agent operating context for this repo.
- [docs/FEATURES.md](docs/FEATURES.md) - inventory of what ships today.
- [.ward/ward.yaml](.ward/ward.yaml) - allowlisted commands + catalog block.
- [coilyco-flight-deck/reddit-mcp](https://forgejo.coilysiren.me/coilyco-flight-deck/reddit-mcp) - the source pattern this repo mirrors.

Cross-reference convention from [coilysiren/agentic-os#59](https://github.com/coilyco-flight-deck/agentic-os/issues/59).
