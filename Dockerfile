# Single-stage: this is a tiny requests + FastMCP service, no frontend, no build
# step. uv installs the pinned deps into the system env, then the console script
# runs the streamable-HTTP server. Mirrors reddit-mcp's registry flow (in-
# cluster registry, plain build), a plain outbound-HTTPS reader.
#
# The image ships zero credentials: the Steam Web API key and steamid64 are
# resolved at runtime from env/SSM (see src/steam_mcp/server.py), never baked in
# here. The repo is steam-ops, but the image/service is steam-mcp.
FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# The aws CLI is the SSM fallback path when the deploy injects no key/steamid env.
RUN pip install --no-cache-dir awscli

WORKDIR /app
COPY pyproject.toml README.md /app/
COPY src /app/src

# Install the project (and its deps) into the system environment. No lockfile:
# the dependency surface is two libraries, so a resolved install is enough.
RUN uv pip install --system --no-cache .

ENV PORT=9112
EXPOSE 9112

CMD ["steam-mcp"]
