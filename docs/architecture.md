# Architecture

Two devices on one Tailscale tailnet, addressed by MagicDNS short names. Nothing is
exposed to the public internet. Cloudflare Tunnel was used before and has been
replaced by Tailscale on purpose; do not reintroduce it.

| Device | Role | Runs | Listens on (Tailscale IP only) |
|---|---|---|---|
| `n8npi`, Raspberry Pi 4B, arm64, always on | Automation + routing, isolated from the Mac | n8n, LiteLLM, dashboard (one compose stack), optional Hermes containers | 5678 n8n, 4000 LiteLLM, 8080 dashboard |
| `dorkmini`, Mac Mini | Inference | Ollama (launchd, native for Metal GPU), larger models | 11434 Ollama |
| `n8npi` (recommended) | AI gateway | OpenClaw (Docker, optional) | 18789 |

## Request flows

1. **Workflow → LLM**: n8n → LiteLLM `n8npi:4000` → Ollama `dorkmini:11434`.
   If Ollama errors, times out or is cooling down, LiteLLM falls back to Gemini →
   Groq → Cerebras → OpenRouter free tiers over the internet.
2. **OpenClaw → LLM**: gateway → Ollama native API `http://dorkmini:11434` (no `/v1`;
   OpenClaw's docs say the OpenAI-compatible path breaks tool calling).
3. **Hermes → LLM**: Hermes → `http://dorkmini:11434/v1` directly (current config),
   or via LiteLLM to get cloud fallback.
4. **Webhook API**: a tailnet client → `POST n8npi:5678/webhook/llm-prompt` → flow 1 →
   JSON response.
5. **Monitoring**: n8n schedules → HTTP checks → Telegram Bot API (outbound only).
   `scripts/healthcheck.sh` gives the same view from a shell.
6. **Dashboard**: browser → `n8npi:8080` (Bearer token) → the dashboard server makes
   the same checks server-side and proxies chat to LiteLLM, so neither Ollama nor the
   LiteLLM key is ever exposed to the browser. See `dashboard/README.md`.
7. **Backups**: systemd timer on the Pi → `backup-n8n.sh` → `/srv/n8n-backups`
   (+ `status/status.json`, mounted read-only into n8n for the weekly report).

## Why this split

- **Pi as the isolation box**: it holds credentials for automations (Telegram, API
  keys) and runs no inference, so a compromised model runtime on the Mac does not
  sit next to those secrets. It is also the always-on device, so LiteLLM lives here
  and keeps cloud fallback working while the Mac sleeps.
- **Mac for inference**: Apple Silicon unified memory runs 4B+ models at useful
  speed; the Pi can only run the tiny ones (see `models.md`).
- **Bind to Tailscale IPs, not 0.0.0.0**: LAN devices and anything that bypasses the
  host firewall (Docker publishes ports around ufw) cannot reach the services.

## Name resolution inside containers

Containers on the Pi do not rely on MagicDNS. `pi/docker-compose.yml` adds
`dorkmini` and `n8npi` as fixed host entries built from `MAC_TAILSCALE_IP` and
`PI_TAILSCALE_IP`, which are stable per device. Services on the same stack talk over
the compose network (`http://n8n:5678`, `http://litellm:4000`). Host-side scripts
use MagicDNS as usual.

## Lifecycle

`make install` bootstraps `.env`, secrets, directories and systemd units.
`make up-pi` runs preflight, then starts the stack. `make provision` creates n8n
credentials and workflows from `.env`. `make update` updates images with rollback.
All of them are idempotent.

## Configuration sources

One `.env` at the repo root (from `.env.example`) feeds compose, the scripts and the
LiteLLM run command. Device-local files that live outside the repo:
`~/.hermes/config.yaml` (from `hermes/config.yaml.template`) and the rendered
LaunchAgent at `~/Library/LaunchAgents/com.homelab.ollama.plist`.
