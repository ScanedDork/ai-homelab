# Hermes Agent

`config.yaml.template` matches the current setup: base URL
`http://dorkmini:11434/v1`, default model `qwen3.5:4b`. The real file lives at
`~/.hermes/config.yaml` and is git-ignored here.

## Switching models

1. Make sure the model exists on dorkmini: `OLLAMA_HOST=http://dorkmini:11434 ollama list`
   (pull with `./mac/pull-models.sh` or `ollama pull <model>`).
2. Change `model.default` in `~/.hermes/config.yaml` (or use the interactive
   `hermes model` command if your version has it).
3. Restart Hermes. Small models (e.g. `llama3.2:3b`) are faster but weaker at tool
   calling; `qwen3.5:4b` is the default for that reason (see `docs/models.md`).

To get cloud fallback when dorkmini is down, point `base_url` at LiteLLM
(`http://n8npi:4000/v1`, model `local-chat`); see the commented block in the template.

## Multiple Hermes containers on the Pi

`pi/docker-compose.yml` has a commented `x-hermes` anchor plus `hermes-1`/`hermes-2`
services. To enable:

1. Resolve the TODOs (image, in-container config path, command) for your Hermes version.
2. Create `hermes/instances/hermes-N/config.yaml` per instance (git-ignored data you
   may want to keep elsewhere) from the template. Pi-hosted instances should use the
   LiteLLM URL or small models; the Pi has 4–8 GB RAM shared with n8n.
3. Uncomment the anchor, the services and their volumes; set `HERMES_IMAGE` in `.env`.
4. `make validate && make up-pi`.
