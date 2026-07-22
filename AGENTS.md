---
ward:
  workflow: merge-remote-main
---
# Agent instructions

Workspace conventions load globally via `~/.claude/CLAUDE.md`. This file covers only what is specific to this repo.

## Scope

A single tiny Python service: a FastMCP server (`src/steam_mcp/server.py`) that exposes Kai's Steam library - owned games and recently-played - as read-only MCP tools over streamable-HTTP, backed by the Steam Web API's `IPlayerService`.

## Project shape

No frontend, no database. `src/steam_mcp/` holds the server and its entrypoint; `tests/` covers the tool logic, the credential-resolution order, and the read-only envelope. One image, one process. The repo is `steam-ops`; the image and service are `steam-mcp`.

`steam_games_to_yaml.py` and `games.yaml` are the **superseded** clipboard scrape and its output, left in place as data. Do not delete them, and do not extend them - new work goes through the MCP.

`scripts/` holds client-side host ops (e.g. `sunshine-sync-steam.ps1`, which syncs a Sunshine streaming host's app list from its installed Steam games, and `display-mode/`, which flips the host's virtual display on and off around a stream). These target an operator's own machine, are **not** shipped in the image, and are not MCP tools - so the read-only-tool and credential rules below are about the service, not these scripts. Keep them out of `src/`.

`scripts/display-mode/` is deployed, not run in place: `Install-DisplayMode.ps1` copies it to `C:\ProgramData\DisplayMode`, which is the path Sunshine's `global_prep_cmd` and the desktop shortcut are wired to. Edit the repo copy and re-run the installer; never patch the deployed copy.

## Repo boundaries

The deploy surface (namespace, Ingress, Authelia client, values.env) lives in [coilyco-bridge/deploy](https://forgejo.coilysiren.me/coilyco-bridge/deploy), not here (source -> deploy layer invariant). This repo builds and publishes the image; the deploy repo rolls it. The server shape is patterned on [coilyco-flight-deck/reddit-mcp](https://forgejo.coilysiren.me/coilyco-flight-deck/reddit-mcp) - keep the two in step where the pattern is shared (credential resolver, port convention, CI).

## Commands

Route every command through just, never bare `uv` / `pytest`. Verbs are declared in the [`justfile`](justfile). Run them as `just <verb>`.

## Validation

`just lint` (ruff + ruff-format + mypy) and `just test` (pytest). `just precommit` runs the full pre-commit suite, including the agentic-os catalog hooks. Validate before pushing.

## Safety

- **Every tool is read-only.** Never add a tool that buys, trades, refunds, sets, or otherwise mutates the Steam account. A Web API key over `IPlayerService` cannot write; keep it that way at the tool layer too. Mutation is out of scope for this MCP by design (deploy#30).
- **No ingest-and-act path.** A tool must never both fetch untrusted content and take an action on it. This service only reads and returns.
- **The key and steamid64 are secrets.** They resolve from env then SSM at runtime, server-side, and must never be baked into the image, the repo, or a committed config. The key rides in the request query string, so never log a request URL or return it to a caller. `trufflehog` runs at commit time as the backstop, but the discipline is upstream of the hook.

## Cross-repo contracts

The private single-architecture image is published as
`forgejo.coilysiren.me/coilyco-gaming/steam-mcp:<full-source-sha>` by
[`.forgejo/workflows/build-publish.yml`](.forgejo/workflows/build-publish.yml)
on every push to main. The trusted deploy runner owns the write credential and
verifies the remote manifest. The deploy repo consumes that exact reference
through a separate read-only credential. Keep the dependency surface tiny
(mcp + requests). A new dependency needs a reason.

## Release

Push to main. CI tests, publishes one source-SHA image to Forgejo OCI, and
verifies the remote manifest. There is no version bump or tag ceremony.
Deferred cleanup gets a Forgejo issue, never a silent skip.

## Agent rules

Name the actor in action sentences.

## Checkout residency

This repo is not in Agent Compose's `repository-plan.yaml`, so it has no
resident checkout under `~/projects/<owner>/`. That is intentional. Work it
from a task-scoped temporary clone, and remove that clone once the work lands.

A temporary root can be purged at any time, so commit and push before pausing,
switching tasks, or ending a session. The remote is the only durable artifact.

## See also

- [README.md](README.md) - human-facing intro.
- [docs/FEATURES.md](docs/FEATURES.md) - inventory of what ships today.
- [.ward/ward.yaml](.ward/ward.yaml) - allowlisted commands + catalog block.

Cross-reference convention from [coilysiren/agentic-os#59](https://github.com/coilyco-flight-deck/agentic-os/issues/59).
