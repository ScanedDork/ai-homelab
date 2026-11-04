# LiteLLM routing proxy

An OpenAI-compatible endpoint on **n8npi:4000** that prefers local Ollama on
dorkmini and falls back to free tiers (Gemini, Groq, Cerebras, OpenRouter).
It runs on the Pi because the Pi is always on: if the Mac is asleep, requests
still succeed via the cloud fallbacks.

| Model group   | Primary (dorkmini)        | Fallback order                          |
|---------------|---------------------------|-----------------------------------------|
| `local-chat`  | `qwen3.5:4b`              | gemini-flash → groq → cerebras → openrouter |
| `local-small` | `llama3.2:3b`             | groq → cerebras → gemini-flash → openrouter |
| `local-embed` | `nomic-embed-text-v2-moe` | none (embeddings must stay consistent)  |

Cloud groups (`gemini-flash`, `groq-llama`, …) can also be requested directly.

## Run (on n8npi)

LiteLLM is not part of `pi/docker-compose.yml`; start it by hand. Only the
variables it needs are passed, not the whole `.env`:

```bash
set -a; . ./.env; set +a
docker run -d --name litellm --restart unless-stopped \
  -p "${PI_TAILSCALE_IP}:4000:4000" \
  -v "$PWD/litellm/config.yaml:/app/config.yaml:ro" \
  -e LITELLM_MASTER_KEY -e OLLAMA_API_BASE \
  -e GEMINI_API_KEY -e GROQ_API_KEY -e CEREBRAS_API_KEY -e OPENROUTER_API_KEY \
  "${LITELLM_IMAGE:-ghcr.io/berriai/litellm:main-stable}" --config /app/config.yaml --port 4000
```

The image is multi-arch (linux/amd64 + linux/arm64). Pin a version tag in
`LITELLM_IMAGE` rather than tracking `main-stable` if you want reproducible updates.

Check: `curl http://n8npi:4000/health/liveliness`. Restart after editing the
config: `docker restart litellm`. Leave a provider key empty and that fallback
simply fails over to the next one.

## Pointing clients at it

- **n8n**: HTTP Request node → `POST http://n8npi:4000/v1/chat/completions` with a
  Header Auth credential `Authorization: Bearer <LITELLM_MASTER_KEY>`; see
  `n8n-workflows/02-webhook-llm-prompt.json`. n8n's OpenAI Chat Model node also works
  with Base URL `http://n8npi:4000/v1`.
- **Hermes**: in `~/.hermes/config.yaml` set `base_url: http://n8npi:4000/v1` and
  `default: local-chat` (see `hermes/README.md`). Use the master key (or a LiteLLM
  virtual key) as the API key.

## What has been tested

This config was run on LiteLLM 1.108.0 against local stubs:
- It loads with no config warnings, and all 7 model groups are listed.
- `/health/liveliness` answers without auth; `/v1/*` rejects requests without a key.
- `local-chat` is served by Ollama when Ollama is up (0 fallbacks).
- When Ollama is unreachable, `local-chat` falls back to the next group
  (`x-litellm-attempted-fallbacks: 1`).
- `local-embed` returns embeddings and, by design, never falls back.

## Verify before relying on it

- The cloud model IDs and free-tier limits (rpm/tpm) could not be checked against the
  providers from the build environment, and these catalogues change. Run one request
  per group (`"model": "groq-llama"` etc.) after adding keys, and adjust `rpm`/`tpm`
  to your tier.
- Free tiers may use your prompts for training (notably Gemini free tier). Keep
  sensitive prompts on `local-*` groups, which never leave the tailnet unless they fail over.
  For strictly local requests, call the Ollama model group without fallbacks or call
  Ollama directly.
