# OpenClaw (placeholder)

Known: OpenClaw is the AI gateway, reachable on **port 18789 on a Tailscale IP**.
Everything else is unknown to this repo and marked TODO rather than guessed.

`docker-compose.yml` is a structurally valid placeholder behind the `openclaw`
profile, so `make up-pi` never starts it.

## Parameters to fill in

| Parameter | Where | Status |
|---|---|---|
| Host running OpenClaw (n8npi or dorkmini) | decides `OPENCLAW_BIND_IP` | **TODO** |
| Install method (Docker image vs native/npm service) | compose or delete compose | **TODO** |
| `OPENCLAW_IMAGE` (name, tag, arm64 support) | `.env` | **TODO** |
| `OPENCLAW_BIND_IP` = `tailscale ip -4` of that host | `.env` | **TODO** |
| `OPENCLAW_PORT` (host side) | `.env` | 18789 (known) |
| Container listen port | `docker-compose.yml` | **TODO** confirm 18789 |
| `OPENCLAW_STATE_PATH` (config/state dir in container) | `.env` | **TODO** |
| Gateway auth token variable + value | compose env + `.env` | **TODO** |
| Upstream LLM: Ollama (`http://dorkmini:11434`) or LiteLLM (`http://n8npi:4000/v1`) | OpenClaw config | **TODO** |
| Channels/integrations enabled | OpenClaw config | **TODO** |

## Once filled in

1. Set the values in `.env`, add env vars to the compose `environment:` block.
2. `make validate`.
3. Add an OpenClaw row to `scripts/healthcheck.sh` and the Tailscale ACL
   (`docs/tailscale.md`) for the chosen host.

If OpenClaw runs natively (not Docker), delete `docker-compose.yml` and document the
service unit here instead. Keep the bind on the Tailscale IP, not `0.0.0.0`.
