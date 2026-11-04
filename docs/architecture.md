# Architecture

Two devices on one Tailscale tailnet, addressed by MagicDNS short names. Nothing is
exposed to the public internet. Cloudflare Tunnel was used before and has been
replaced by Tailscale on purpose; do not reintroduce it.

| Device | Role | Runs | Listens on (Tailscale IP only) |
|---|---|---|---|
| `n8npi`, Raspberry Pi 4B, arm64, always on | Automation + routing, isolated from the Mac | n8n (Docker), LiteLLM (Docker, manual), optional Hermes containers | 5678 n8n, 4000 LiteLLM |
| `dorkmini`, Mac Mini | Inference | Ollama (launchd, native for Metal GPU), larger models | 11434 Ollama |
| Host TBD | AI gateway | OpenClaw (placeholder) | 18789 |

## Request flows

1. **Workflow → LLM**: n8n → LiteLLM `n8npi:4000` → Ollama `dorkmini:11434`.
   If Ollama errors, times out or is cooling down, LiteLLM falls back to Gemini →
   Groq → Cerebras → OpenRouter free tiers over the internet.
2. **Hermes → LLM**: Hermes → `http://dorkmini:11434/v1` directly (current config),
   or via LiteLLM to get cloud fallback.
3. **Webhook API**: a tailnet client → `POST n8npi:5678/webhook/llm-prompt` → flow 1 →
   JSON response.
4. **Monitoring**: n8n schedules → HTTP checks → Telegram Bot API (outbound only).
   `scripts/healthcheck.sh` gives the same view from a shell.
5. **Backups**: systemd timer on the Pi → `backup-n8n.sh` → `/srv/n8n-backups`
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

## Configuration sources

One `.env` at the repo root (from `.env.example`) feeds compose, the scripts and the
LiteLLM run command. Device-local files that live outside the repo:
`~/.hermes/config.yaml` (from `hermes/config.yaml.template`) and the rendered
LaunchAgent at `~/Library/LaunchAgents/com.homelab.ollama.plist`.
