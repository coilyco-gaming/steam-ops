"""steam-mcp: read-only MCP exposing Kai's Steam library over streamable-HTTP.

The second pure-read clone of the coilyco-bridge/deploy#30 personal-MCP fleet,
and its second credential shape - a Steam Web API key over `IPlayerService` (vs
reddit-mcp's private feed URL) - proving the DRY deploy substrate generalizes
across shapes. It wraps the durable Steam Web API path the old clipboard scrape
(`steam_games_to_yaml.py`) named in its own docstring, replacing the scrape's
brittle rendered-text parse with clean JSON.

Read-only by construction: a Web API key reads a library, it cannot act on the
account. There is no write tool here, and no path that both ingests untrusted
content and can act. The repo is `steam-ops`, but the image and service are
`steam-mcp`.
"""

__all__ = ["__version__"]

__version__ = "0.1.0"
