# Security envelope

**Read-only by construction.** A Steam Web API key over `IPlayerService` reads
a library. It cannot post, trade, refund, or act on the account (deploy#30). No
write tool exists, and no tool both ingests untrusted content and can act.

**Credentials never in the image.** Web API credentials resolve env-first then
from SSM, and client PICS has its own env-first refresh token. Tokens,
passwords, Guard material, and request URLs never enter logs, exceptions, tool
results, or tracked files.

**Network-gated reach.** The endpoint sits behind the deploy's auth and network
overlay rather than anything in this source.

## Configuration

- `PORT` (default 9112), `HOST` (default 0.0.0.0)
- `STEAM_WEB_API_KEY` or SSM `/steam/web-api-key` (SecureString)
- `STEAM_STEAMID64` or SSM `/steam/steam-id-64`
- `STEAM_CLIENT_REFRESH_TOKEN` or SSM `/steam/client-refresh-token`

Env is checked first and SSM is the fallback. The refresh token is the normal
client credential, and the deployed ExternalSecret injects only that token.

`just bootstrap-client` reads the existing `/steam/username` and
`/steam/password` SecureStrings through AOSGuard and stores only the issued
token, writing a rotated token back to SSM without it entering command
arguments. If Steam Guard needs a manual code, it is entered during that
one-time operator login rather than during a live MCP request.

## See also

- [FEATURES.md](FEATURES.md) - the capability inventory.
