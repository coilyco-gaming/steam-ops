"""Authenticated, read-only Steam client-protocol/PICS adapter.

The ``steamio`` package (steam.py) owns the client protocol.  This adapter owns
only credential precedence, the refresh-token lifecycle, and normalization.
"""

from __future__ import annotations

import asyncio
import json
import subprocess
from collections.abc import Callable
from typing import Any


class ClientProtocolAdapter:
    """Use a Steam account session only for PICS/account reads.

    A refresh token is the normal credential.  Username/password (and an
    optional Steam Guard shared secret) are read only when no refresh token is
    configured, then the newly issued token is persisted to SSM.  Nothing from
    either credential path is returned or included in exception text.
    """

    def __init__(
        self,
        secret: Callable[[str], str],
        optional_secret: Callable[[str], str | None],
        persist_refresh_token: Callable[[str], None],
    ) -> None:
        self._secret = secret
        self._optional_secret = optional_secret
        self._persist_refresh_token = persist_refresh_token

    async def _login(self, client: Any) -> None:
        refresh_token = self._optional_secret("client_refresh_token")
        if refresh_token:
            try:
                await client.login(refresh_token=refresh_token)
                original_token = refresh_token
            except Exception:
                # An expired/revoked refresh token is not steady state. Fall
                # back to bootstrap without exposing the client-library error.
                await self._bootstrap(client)
                original_token = None
        else:
            await self._bootstrap(client)
            original_token = None
        rotated_token = getattr(client, "refresh_token", None)
        if rotated_token and rotated_token != original_token:
            self._persist_refresh_token(rotated_token)

    async def _bootstrap(self, client: Any) -> None:
        """Use account credentials only after the refresh-token path fails."""
        await client.login(
            self._secret("client_account_name"),
            self._secret("client_account_password"),
            shared_secret=self._optional_secret("client_guard_shared_secret"),
        )

    async def _with_client(self, operation: Callable[[Any], Any]) -> Any:
        try:
            import steam

            async with steam.Client() as client:
                await self._login(client)
                return await operation(client)
        except (ImportError, OSError, RuntimeError, ValueError):
            raise RuntimeError(
                "Steam client authentication or PICS request failed; verify the persisted "
                "refresh token or perform the documented manual bootstrap."
            ) from None

    def product_info(self, appid: int) -> dict[str, Any]:
        """Read PICS product metadata for a single positive application id."""
        if appid <= 0:
            raise ValueError("appid must be a positive Steam application id")

        async def operation(client: Any) -> dict[str, Any]:
            infos = await client.fetch_product_info(apps=[appid])
            info = infos[0] if infos else None
            return {
                "source": "steam_client_pics",
                "provenance": {"plane": "client_pics"},
                "item": _product_item(appid, info),
            }

        return asyncio.run(self._with_client(operation))

    def licenses(self) -> dict[str, Any]:
        """Read account package-license metadata without exposing access tokens."""

        async def operation(client: Any) -> dict[str, Any]:
            items = [
                {
                    "packageid": getattr(account_license, "id", None),
                    "created_at": _safe_value(getattr(account_license, "created_at", None)),
                    "payment_method": _safe_value(getattr(account_license, "payment_method", None)),
                }
                for account_license in client.licenses
            ]
            return {
                "source": "steam_client",
                "provenance": {"plane": "client_pics"},
                "count": len(items),
                "items": items,
            }

        return asyncio.run(self._with_client(operation))


def _safe_value(value: Any) -> Any:
    """Serialize enum/date-like public metadata without serializing secrets."""
    return getattr(value, "value", value.isoformat() if hasattr(value, "isoformat") else value)


def _product_item(appid: int, info: Any) -> dict[str, Any] | None:
    if info is None:
        return None
    common = getattr(info, "common", None)
    if not common and isinstance(info, dict):
        common = info.get("common")
    common = common or {}
    return {
        "appid": appid,
        "name": common.get("name"),
        "type": common.get("type"),
        "oslist": common.get("oslist"),
        "release_state": common.get("releasestate"),
    }


def persist_refresh_token(ssm_name: str, refresh_token: str) -> None:
    """Write a rotated token to SSM without placing its value in process argv."""
    payload = json.dumps(
        {"Name": ssm_name, "Value": refresh_token, "Type": "SecureString", "Overwrite": True}
    )
    try:
        subprocess.run(
            ["aws", "ssm", "put-parameter", "--cli-input-json", "file:///dev/stdin"],
            input=payload,
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("Steam client refresh token could not be persisted") from None
