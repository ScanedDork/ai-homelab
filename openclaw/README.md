# OpenClaw gateway

`docker-compose.yml` follows the upstream compose file
([openclaw/openclaw](https://github.com/openclaw/openclaw)), restricted to the
gateway service and published only on a Tailscale IP. The official image
`ghcr.io/openclaw/openclaw` (mirror: `openclaw/openclaw` on Docker Hub) is multi-arch
(amd64 + arm64), so it can run on **n8npi** or **dorkmini**.

## Parameters

| Parameter | Where | Value |
|---|---|---|
| Host running OpenClaw | decides `OPENCLAW_BIND_IP` | **Your choice** (see below) |
| `OPENCLAW_IMAGE` | `.env` | `ghcr.io/openclaw/openclaw:latest`; pin a release such as `2026.9.3` for stability |
| `OPENCLAW_BIND_IP` | `.env` | `tailscale ip -4` of the chosen host |
| `OPENCLAW_PORT` | `.env` | `18789` (the container always listens on 18789) |
| `OPENCLAW_GATEWAY_TOKEN` | `.env` | `openssl rand -hex 32`; token auth is OpenClaw's default |
| `OPENCLAW_HOST_CONFIG_DIR` / `_WORKSPACE_DIR` / `_SECRETS_DIR` | `.env` | host dirs, owned by uid/gid 1000 (`node` in the image) |
| `OPENCLAW_URL` | `.env` | e.g. `http://n8npi:18789`; enables the healthcheck row |
| Upstream LLM | `openclaw.json`, via onboarding | Ollama **native** URL `http://dorkmini:11434` (no `/v1`) |

**Which host?** n8npi keeps the always-on, isolated role (OpenClaw holds channel
tokens such as a Telegram bot, like n8n). dorkmini is only worth it if OpenClaw needs
local browsers or heavy tools. The recommended default is **n8npi**.

**Use Ollama's native URL.** OpenClaw's docs say the OpenAI-compatible
`http://host:11434/v1` breaks tool calling, so point it at `http://dorkmini:11434`,
not at the `/v1` URL that Hermes uses. Onboarding only auto-selects models with tool
support and at least 16K context; check that `qwen3.5:4b` qualifies, or pass
`--custom-model-id`.

## First run

```bash
sudo install -d -o 1000 -g 1000 /srv/openclaw/config /srv/openclaw/workspace /srv/openclaw/auth-secrets
C="docker compose --env-file .env -f openclaw/docker-compose.yml"

# 1. Onboard headlessly: local gateway, token auth from .env, Ollama on dorkmini.
$C run -T --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js onboard --non-interactive --accept-risk --skip-health \
  --mode local --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
  --auth-choice ollama --custom-base-url "http://dorkmini:11434" --custom-model-id "qwen3.5:4b" \
  --skip-channels --no-install-daemon

# 2. Allow the Control UI origin you will browse from (MagicDNS name of the host).
$C run -T --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js config set --batch-json \
  '[{"path":"gateway.controlUi.allowedOrigins","value":["http://n8npi:18789"]}]'

# 3. Start and check.
$C up -d
curl -fsS http://n8npi:18789/healthz
```

Open `http://n8npi:18789/` and paste `OPENCLAW_GATEWAY_TOKEN` into Settings. Add
channels later with `dist/index.js channels add --channel telegram --use-env`
(`TELEGRAM_BOT_TOKEN` must then be in the container environment).

## Native install alternative

If OpenClaw runs natively instead of in Docker, skip this compose file and set
`gateway.bind: "tailnet"` with `gateway.auth.mode: "token"` in `openclaw.json`. The
gateway then listens directly on the Tailscale IP. Do **not** enable OpenClaw's
`tailscale.mode: "funnel"`: that is public exposure.

## Still to verify on your device

- The model list after onboarding: `dist/index.js models list --provider ollama`.
- Whether you already have state in `~/.openclaw` from an earlier install. If so,
  point `OPENCLAW_HOST_CONFIG_DIR` at it instead of `/srv/openclaw/config`.
