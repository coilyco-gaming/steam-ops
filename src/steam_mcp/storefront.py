"""Narrow, unauthenticated readers for Steam's public storefront endpoints."""

from __future__ import annotations

from typing import Any

import requests

STORE_BASE = "https://store.steampowered.com"
TIMEOUT = 20


def _get(path: str, params: dict[str, Any]) -> dict[str, Any] | None:
    """Perform one public, read-only storefront GET without logging its URL."""
    try:
        response = requests.get(f"{STORE_BASE}{path}", params=params, timeout=TIMEOUT)
        return response.json() if response.ok else None
    except (requests.RequestException, ValueError):
        return None


def _country_code(country_code: str) -> str:
    value = country_code.strip().upper()
    if len(value) != 2 or not value.isalpha():
        raise ValueError("country_code must be a two-letter ISO country code")
    return value


def app_details(appid: int, country_code: str = "US") -> dict[str, Any]:
    """Return a stable, public subset of one application's storefront record."""
    if appid <= 0:
        raise ValueError("appid must be a positive Steam application id")
    payload = _get(
        "/api/appdetails",
        {"appids": appid, "cc": _country_code(country_code), "l": "english"},
    )
    entry = (payload or {}).get(str(appid)) or {}
    if not entry.get("success"):
        return {"source": "storefront", "provenance": {"plane": "storefront"}, "item": None}
    data = entry.get("data") or {}
    item = {
        "appid": data.get("steam_appid", appid),
        "name": data.get("name"),
        "type": data.get("type"),
        "is_free": data.get("is_free"),
        "short_description": data.get("short_description"),
        "developers": data.get("developers") or [],
        "publishers": data.get("publishers") or [],
        "genres": [genre.get("description") for genre in data.get("genres") or []],
        "categories": [category.get("description") for category in data.get("categories") or []],
        "release_date": (data.get("release_date") or {}).get("date"),
        "price_overview": data.get("price_overview"),
    }
    return {"source": "storefront", "provenance": {"plane": "storefront"}, "item": item}


def search(query: str, country_code: str = "US") -> dict[str, Any]:
    """Search the storefront using Steam's documented search-shaped endpoint."""
    term = query.strip()
    if not term:
        raise ValueError("query must not be empty")
    payload = _get(
        "/api/storesearch/",
        {"term": term, "cc": _country_code(country_code), "l": "english"},
    )
    items = [
        {
            "appid": result.get("id"),
            "name": result.get("name"),
            "type": result.get("type"),
            "price": result.get("price"),
            "tiny_image": result.get("tiny_image"),
            "metascore": result.get("metascore"),
        }
        for result in (payload or {}).get("items") or []
    ]
    return {
        "source": "storefront",
        "provenance": {"plane": "storefront"},
        "count": len(items),
        "items": items,
    }
