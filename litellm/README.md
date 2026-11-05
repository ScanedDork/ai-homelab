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

LiteLLM is the `litellm` service in `pi/docker-compose.yml`, so `make up-pi` starts
it, `make update` updates it (with rollback), and Docker health-checks
`/health/liveliness`. It gets only the variables it needs: `LITELLM_MASTER_KEY`,
`OLLAMA_API_BASE` and the four provider keys. `dorkmini` resolves inside the
container through the fixed host entry built from `MAC_TAILSCALE_IP`.

- Image: `LITELLM_IMAGE` (default `docker.io/litellm/litellm:main-stable`, multi-arch,
  the same build as `ghcr.io/berriai/litellm`). Pin a version tag for reproducible
  updates. `LITELLM_LOCAL_MODEL_COST_MAP=True` stops it fetching the price map from
  GitHub at every start.
- After editing `config.yaml`: `docker restart litellm`.
- Check: `curl http://n8npi:4000/health/liveliness`, or the dashboard's Overview.
- A provider whose key is empty is still tried during fallback and fails fast. Add at
  least one key so the Pi still answers while dorkmini sleeps.

## Pointing clients at it

- **n8n** (same compose network): HTTP Request node → `POST http://litellm:4000/v1/chat/completions`
  with the "LiteLLM master key" credential that `make provision` creates; see
  `n8n-workflows/02-webhook-llm-prompt.json`. n8n's OpenAI Chat Model node also works
  with Base URL `http://litellm:4000/v1`.
- **Dashboard**: uses `http://litellm:4000` server-side (Playground tab).
- **Hermes**: in `~/.hermes/config.yaml` set `base_url: http://n8npi:4000/v1` and
  `default: local-chat` (see `hermes/README.md`). Use the master key (or a LiteLLM
  virtual key) as the API key.

## What has been tested

This config was run on LiteLLM 1.108.0, both from pip and as the `litellm` compose
service (real image), against local stubs:
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
