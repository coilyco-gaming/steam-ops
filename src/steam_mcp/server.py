"""FastMCP server exposing Kai's Steam library over streamable-HTTP.

Read-only by construction. Each tool calls one `IPlayerService` endpoint of the
Steam Web API and returns clean, normalized JSON records - the durable
replacement for the clipboard scrape this repo used to carry
(`steam_games_to_yaml.py`, now superseded):

- get_owned_games      - the full owned library (appid, name, playtime, last-played)
- get_recently_played  - games played in the last two weeks (recent-activity signal)

A Steam Web API key over `IPlayerService` *reads* a library - it cannot post,
trade, refund, or otherwise act on the account. That is the whole point: this is
the second credential shape in the deploy#30 personal-MCP fleet (a Web API key,
vs reddit-mcp's feed URL), and like reddit-mcp there is deliberately **no write
tool** and no path that both ingests untrusted content and can act.

Credential custody: the key and the steamid64 are private and never live in the
image, the repo, or a committed config. Each is resolved at runtime,
server-side, from an env var first and then from SSM (`aws ssm get-parameter
--with-decryption`), mirroring reddit-mcp's `_ssm` resolver and node-stats'
env-based config. Env wins so the deploy can inject via an ExternalSecret
without granting the pod `ssm:GetParameter`. The secrets never leave the box and
are never logged or returned to callers - only the fetched game records are.
"""

from __future__ import annotations

import os
import subprocess
from typing import Any
from urllib.parse import urlencode

import requests
from mcp.server.fastmcp import FastMCP

API_BASE = "https://api.steampowered.com"
TIMEOUT = 20

# Each secret: (env var checked first, SSM SecureString parameter checked
# second). Env wins so the deploy can inject via an ExternalSecret without
# granting the pod ssm:GetParameter, matching node-stats' env-based config and
# reddit-mcp's resolver. These SSM params do not exist yet - they are introduced
# by this MCP (the scrape never used the API); the deploy provisions them.
SECRETS = {
    "api_key": ("STEAM_WEB_API_KEY", "/steam/web-api-key"),
    "steamid64": ("STEAM_STEAMID64", "/steam/steamid64"),
}

mcp = FastMCP(
    "steam",
    host=os.environ.get("HOST", "0.0.0.0"),
    port=int(os.environ.get("PORT", "9112")),
)


def _ssm(name: str) -> str | None:
    """Fetch a decrypted SSM parameter value. None if unavailable.

    The key and steamid64 are SecureString params read server-side at call time;
    they are never logged or returned to callers. Ported from reddit-mcp's `_ssm`.
    """
    try:
        proc = subprocess.run(
            [
                "aws",
                "ssm",
                "get-parameter",
                "--name",
                name,
                "--with-decryption",
                "--query",
                "Parameter.Value",
                "--output",
                "text",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return proc.stdout.strip() if proc.returncode == 0 else None
    except Exception:
        return None


def _secret(name: str) -> str:
    """Resolve a secret: env var first, then SSM.

    Raises ValueError (surfaced to the caller as a tool error) when neither
    source has the value, so an unconfigured deploy fails loud instead of
    silently making a keyless request that Steam answers with an empty library.
    """
    env_var, ssm_name = SECRETS[name]
    value = os.environ.get(env_var) or _ssm(ssm_name)
    if not value:
        raise ValueError(f"secret {name!r} is not configured (set {env_var} or SSM {ssm_name})")
    return value


def _api_url(endpoint: str, extra: dict[str, Any]) -> str:
    """Build a Steam Web API URL, folding in the key + steamid64 + format=json.

    The key rides in the query string (Steam takes no other auth), so this URL
    is itself sensitive - `_fetch_json` never logs it, and it never leaves the
    box. Callers pass only the read-shaping params (include_appinfo, ...).
    """
    params = {
        "key": _secret("api_key"),
        "steamid": _secret("steamid64"),
        "format": "json",
        **extra,
    }
    return f"{API_BASE}/{endpoint}?{urlencode(params)}"


def _fetch_json(url: str) -> dict | None:
    """GET a Steam Web API endpoint. Read-only: this is the only network call, a
    plain outbound GET the key cannot turn into a write. The URL carries the key,
    so it is never logged - only the parsed JSON body flows onward."""
    try:
        r = requests.get(url, timeout=TIMEOUT)
        if not r.ok:
            return None
        return r.json()
    except Exception:
        return None


def _normalize_game(game: dict) -> dict[str, Any]:
    """Flatten one IPlayerService game record into a stable, scrape-faithful shape.

    Keeps the fields the old clipboard scrape produced (name, hours, last-played)
    plus the durable identifiers the API adds (appid, raw minutes, 2-week play).
    Playtimes are minutes in the API; hours are the scrape's headline unit, so we
    surface both.
    """
    forever = game.get("playtime_forever") or 0
    two_weeks = game.get("playtime_2weeks") or 0
    last_played = game.get("rtime_last_played") or 0
    return {
        "appid": game.get("appid"),
        "name": (game.get("name") or "").strip(),
        "playtime_forever_minutes": forever,
        "playtime_forever_hours": round(forever / 60, 1),
        "playtime_2weeks_minutes": two_weeks,
        # Unix epoch seconds of last launch; 0 in the API means "never / hidden",
        # surfaced as None so callers do not read the epoch as a real timestamp.
        "last_played_unix": last_played or None,
    }


def _games(endpoint: str, source: str, extra: dict[str, Any]) -> dict[str, Any]:
    """Call an IPlayerService endpoint and return its normalized game records.

    Steam nests the list under `response.games`; a private profile or an empty
    result yields `response: {}`, which normalizes to an empty list (not an
    error - the request itself succeeded).
    """
    payload = _fetch_json(_api_url(endpoint, extra))
    response = (payload or {}).get("response") or {}
    items = [_normalize_game(g) for g in (response.get("games") or [])]
    return {"source": source, "count": len(items), "items": items}


def get_owned_games() -> dict[str, Any]:
    """Kai's full owned Steam library, with app info and free games included.

    Calls `IPlayerService/GetOwnedGames` with `include_appinfo=1` (so names come
    back, not just appids) and `include_played_free_games=1`. This is the durable
    replacement for the clipboard scrape's fields. Read-only.
    """
    return _games(
        "IPlayerService/GetOwnedGames/v1/",
        "owned_games",
        {"include_appinfo": 1, "include_played_free_games": 1},
    )


def get_recently_played() -> dict[str, Any]:
    """Games Kai has played in the last two weeks - a recent-activity signal.

    Calls `IPlayerService/GetRecentlyPlayedGames`. Cheap and useful alongside the
    full library; the same normalized record shape. Read-only.
    """
    return _games("IPlayerService/GetRecentlyPlayedGames/v1/", "recently_played", {})


# Register each tool without rebinding its name, so the plain callables stay
# directly invokable (tests call them; the mcp SDK's decorator return type has
# varied across versions, so we don't rely on it). Every registered tool is a
# read - keep it that way (no trade, no purchase, no account mutation).
for _tool in (
    get_owned_games,
    get_recently_played,
):
    mcp.tool()(_tool)


def main() -> None:
    """Run the MCP server over streamable-HTTP (endpoint served at /mcp)."""
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
