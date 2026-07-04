"""Behavioural tests for the steam-mcp tools.

The tools are registered with FastMCP without rebinding their names, so the
plain callables stay directly invokable here. The focus mirrors reddit-mcp's:
the read-only + credential-custody envelope. The key + steamid64 resolve
env-first then SSM, an unconfigured secret fails loud, the request carries the
right IPlayerService params, the normalization is scrape-faithful, and there is
no write tool.
"""

from __future__ import annotations

import base64
import importlib
from types import ModuleType

import pytest

_SECRET_ENV = ["STEAM_WEB_API_KEY", "STEAM_STEAMID64"]


def _load(monkeypatch: pytest.MonkeyPatch, env: dict[str, str] | None = None) -> ModuleType:
    """Reimport the server module with a clean secret env applied."""
    for var in _SECRET_ENV:
        monkeypatch.delenv(var, raising=False)
    for k, v in (env or {}).items():
        monkeypatch.setenv(k, v)
    import steam_mcp.server as server

    return importlib.reload(server)


def _creds() -> dict[str, str]:
    return {"STEAM_WEB_API_KEY": "test-key", "STEAM_STEAMID64": "7656119800000000"}


_OWNED_PAYLOAD = {
    "response": {
        "game_count": 1,
        "games": [
            {
                "appid": 440,
                "name": "  Team Fortress 2  ",
                "playtime_forever": 150,  # minutes -> 2.5 hours
                "playtime_2weeks": 30,
                "rtime_last_played": 1_700_000_000,
                "img_icon_url": "abc",
            }
        ],
    }
}

_RECENT_PAYLOAD = {
    "response": {
        "total_count": 1,
        "games": [
            {"appid": 570, "name": "Dota 2", "playtime_forever": 6000, "playtime_2weeks": 120},
        ],
    }
}


def test_owned_games_normalizes(monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load(monkeypatch, _creds())
    monkeypatch.setattr(server, "_fetch_json", lambda url: _OWNED_PAYLOAD)
    got = server.get_owned_games()
    assert got["source"] == "owned_games"
    assert got["count"] == 1
    game = got["items"][0]
    assert game["appid"] == 440
    assert game["name"] == "Team Fortress 2"  # stripped
    assert game["playtime_forever_minutes"] == 150
    assert game["playtime_forever_hours"] == 2.5  # minutes converted to hours
    assert game["last_played_unix"] == 1_700_000_000


def test_recently_played_normalizes(monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load(monkeypatch, _creds())
    monkeypatch.setattr(server, "_fetch_json", lambda url: _RECENT_PAYLOAD)
    got = server.get_recently_played()
    assert got["source"] == "recently_played"
    assert got["count"] == 1
    game = got["items"][0]
    assert game["appid"] == 570
    assert game["playtime_forever_hours"] == 100.0
    # No rtime_last_played in the recent payload -> None, not epoch 0.
    assert game["last_played_unix"] is None


def test_owned_games_url_carries_required_params(monkeypatch: pytest.MonkeyPatch) -> None:
    """GetOwnedGames must request app info + free games, keyed by the steamid."""
    server = _load(monkeypatch, _creds())
    seen: dict[str, str] = {}

    def _capture(url: str) -> dict:
        seen["url"] = url
        return {"response": {"games": []}}

    monkeypatch.setattr(server, "_fetch_json", _capture)
    server.get_owned_games()
    url = seen["url"]
    assert "IPlayerService/GetOwnedGames" in url
    assert "include_appinfo=1" in url
    assert "include_played_free_games=1" in url
    assert "key=test-key" in url
    assert "steamid=7656119800000000" in url


def test_private_profile_yields_empty(monkeypatch: pytest.MonkeyPatch) -> None:
    """A private profile / empty result returns `response: {}` - an empty list,
    not an error: the request itself succeeded."""
    server = _load(monkeypatch, _creds())
    monkeypatch.setattr(server, "_fetch_json", lambda url: {"response": {}})
    got = server.get_owned_games()
    assert got["count"] == 0
    assert got["items"] == []


def test_unconfigured_secret_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load(monkeypatch)  # no env
    monkeypatch.setattr(server, "_ssm", lambda name: None)  # no SSM either
    with pytest.raises(ValueError, match="not configured"):
        server.get_owned_games()


def test_env_takes_precedence_over_ssm(monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load(monkeypatch, _creds())
    # If SSM were consulted it would fail the test; env must win and be used verbatim.
    monkeypatch.setattr(server, "_ssm", lambda name: pytest.fail("SSM must not be read"))
    seen: dict[str, str] = {}

    def _capture(url: str) -> dict:
        seen["url"] = url
        return {"response": {"games": []}}

    monkeypatch.setattr(server, "_fetch_json", _capture)
    server.get_owned_games()
    assert "key=test-key" in seen["url"]
    assert "steamid=7656119800000000" in seen["url"]


def test_initialize_response_carries_steam_icon(monkeypatch: pytest.MonkeyPatch) -> None:
    """The server's `initialize` response advertises the Steam brand icon.

    Clients that render server icons (the claude.ai connector tile) read
    `serverInfo.icons` off the initialize result, which the low-level server
    builds verbatim from `create_initialization_options().icons`. Assert the
    Steam mark is there as a self-contained SVG data URI, so the tile renders the
    logo instead of a generic placeholder.
    """
    server = _load(monkeypatch)
    icons = server.mcp._mcp_server.create_initialization_options().icons
    assert icons, "expected serverInfo to advertise at least one icon"
    icon = icons[0]
    assert icon.mimeType == "image/svg+xml"
    assert icon.src.startswith("data:image/svg+xml;base64,")
    decoded = base64.b64decode(icon.src.split(",", 1)[1]).decode()
    assert "<title>Steam</title>" in decoded


def test_no_write_tools_registered(monkeypatch: pytest.MonkeyPatch) -> None:
    """The read-only invariant: every registered tool reads, none can act."""
    server = _load(monkeypatch)
    names = [t.name for t in server.mcp._tool_manager.list_tools()]
    assert names, "expected tools to be registered"
    # The action verb is the leading underscore-delimited token; every tool must
    # read (`get_`), never act. A write tool would lead with buy/trade/refund/...
    forbidden_verbs = {"buy", "trade", "refund", "post", "purchase", "delete", "send", "set"}
    for n in names:
        verb = n.split("_", 1)[0]
        assert verb == "get", f"non-read tool {n!r} registered"
        assert verb not in forbidden_verbs
