"""Entrypoint so `python -m steam_mcp` and the console script both run the server."""

from steam_mcp.server import main

if __name__ == "__main__":
    main()
