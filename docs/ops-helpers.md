# Ops helpers

`scripts/` holds host-side helpers. They are **not** part of the shipped image
or the MCP: they run on an operator's own
[Sunshine](https://github.com/LizardByte/Sunshine) streaming host.

**`sunshine-sync-steam.ps1`** rebuilds Sunshine's app list from the host's
locally installed Steam games (`appmanifest_*.acf`), so a Moonlight client shows
one launchable tile per game with box art rather than only "Desktop". It talks
to the local Sunshine web API, which runs as LocalSystem and writes the
admin-owned config, so it needs no Steam Web API key and no elevation. The
Sunshine password resolves from `SUNSHINE_WEB_PASSWORD` then a prompt and never
enters the repo. It is idempotent, and `-DryRun` previews.

**`steam-airgap.ps1`** toggles a Windows Firewall block on Steam's networking
executables with `-On`, `-Off`, and `-Status`, forcing the client offline while
Tailscale, Sunshine, Moonlight, and the game's own traffic stay up. That lets an
airgapped streaming host keep running a game while the same account plays online
elsewhere, because Steam cannot be kicked if it cannot reach its servers. It
self-elevates for the firewall writes.

## See also

- [FEATURES.md](FEATURES.md) - the capability inventory.
