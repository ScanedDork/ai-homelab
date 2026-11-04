# Models: what runs where

All models are served by **Ollama on dorkmini** today. The "Pi-compatible" set is
small enough to run on a Raspberry Pi 4B CPU if you ever install Ollama there, but
this repo does not run inference on the Pi, which stays the isolation/automation box.

| Model | Size class | Where | Used for | Why |
|---|---|---|---|---|
| `qwen3.5:4b` | 4B | dorkmini | Hermes default; LiteLLM `local-chat` | Best tool-calling/reasoning per GB that runs fast on the Mac |
| `llama3.2:3b` | 3B | dorkmini (Pi-compatible) | LiteLLM `local-small`, quick summaries | Good general quality at low latency |
| `smollm2:1.7b` | 1.7B | dorkmini (Pi-compatible) | classification, routing, short rewrites | Usable even on a Pi CPU |
| `functiongemma:270m` | 270M | dorkmini (Pi-compatible) | function-call/intent parsing | Tiny, specialised for structured calls |
| `nomic-embed-text-v2-moe` | embedding | dorkmini (Pi-compatible) | LiteLLM `local-embed`, RAG | Multilingual embeddings; keep one embedder so vectors stay comparable |
| larger models (your choice) | 7B+ | dorkmini only | heavy reasoning | Need the Mac's unified memory; list them in `MAC_EXTRA_MODELS` |
| Gemini / Groq / Cerebras / OpenRouter free tiers | cloud | via LiteLLM | fallback only | Keep things working when the Mac is down; rate-limited and may log prompts |

## Rules of thumb

- Pi 4B (4–8 GB RAM, no GPU): ≤3B quantised models at a few tokens/s; fine for
  batch jobs, not for chat. Leave RAM for n8n and Hermes containers.
- OpenClaw uses Ollama's native API and auto-selects only tool-capable models with
  ≥16K context; pass `--custom-model-id` during onboarding to choose one explicitly.
- Change the embedding model only with a full re-index.
- Pull/refresh models: `./mac/pull-models.sh` (idempotent; `--force` refreshes tags).
- Health: `scripts/healthcheck.sh` fails if any `HEALTHCHECK_REQUIRED_MODELS` is missing.
