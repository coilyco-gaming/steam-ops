"""Interactive, operator-side bootstrap for the Steam client refresh token."""

from __future__ import annotations

import asyncio
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from steam_mcp.client import run_authenticated_session

ACCOUNT_NAME_PARAMETER = "/steam/username"
ACCOUNT_PASSWORD_PARAMETER = "/steam/password"
GUARD_SHARED_SECRET_PARAMETER = "/steam/client-guard-shared-secret"
REFRESH_TOKEN_PARAMETER = "/steam/client-refresh-token"


def _read_parameter(name: str, *, required: bool = True) -> str | None:
    try:
        proc = subprocess.run(
            [
                "aosguard",
                "ops",
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
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        proc = None
    value = proc.stdout.strip() if proc and proc.returncode == 0 else ""
    if value:
        return value
    if required:
        raise RuntimeError(f"Required SSM parameter {name} is unavailable")
    return None


def _write_refresh_token(refresh_token: str) -> None:
    token_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix="steam-client-refresh-token.",
            delete=False,
        ) as token_file:
            token_file.write(refresh_token)
            token_path = Path(token_file.name)
        token_path.chmod(0o600)
        subprocess.run(
            [
                "aosguard",
                "ops",
                "aws",
                "ssm",
                "put-parameter",
                "--name",
                REFRESH_TOKEN_PARAMETER,
                "--type",
                "SecureString",
                "--overwrite",
                "--value",
                f"file://{token_path}",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("Steam client refresh token could not be persisted") from None
    finally:
        if token_path is not None:
            token_path.unlink(missing_ok=True)


async def _bootstrap() -> None:
    import steam

    account_name = _read_parameter(ACCOUNT_NAME_PARAMETER)
    account_password = _read_parameter(ACCOUNT_PASSWORD_PARAMETER)
    shared_secret = _read_parameter(GUARD_SHARED_SECRET_PARAMETER, required=False)

    async def capture_refresh_token(client: Any) -> str:
        refresh_token = getattr(client, "refresh_token", None)
        if not refresh_token:
            raise RuntimeError("Steam did not issue a refresh token")
        return refresh_token

    async with steam.Client() as client:
        refresh_token = await run_authenticated_session(
            client,
            capture_refresh_token,
            ready_timeout=None,
            username=account_name,
            password=account_password,
            shared_secret=shared_secret,
        )
    _write_refresh_token(refresh_token)


def main() -> None:
    """Perform one controlled login and persist only the issued refresh token."""
    try:
        asyncio.run(_bootstrap())
    except (ImportError, OSError, RuntimeError, ValueError):
        raise SystemExit(
            "Steam client bootstrap failed. No credential value was printed or persisted."
        ) from None
    print(f"Steam client refresh token stored in {REFRESH_TOKEN_PARAMETER}.")


if __name__ == "__main__":
    main()
