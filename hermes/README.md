# Hermes Agent

`config.yaml.template` matches the current setup: base URL
`http://dorkmini:11434/v1`, default model `qwen3.5:4b`, provider `custom`. Key names
follow upstream `cli-config.yaml.example`. The real file lives at
`~/.hermes/config.yaml` and is never committed here.

## Switching models

1. Make sure the model exists on dorkmini: `OLLAMA_HOST=http://dorkmini:11434 ollama list`
   (pull with `./mac/pull-models.sh` or `ollama pull <model>`).
2. Change `model.default` in `~/.hermes/config.yaml`, or run
   `hermes config set model.default <model>`, or use the interactive `hermes model`.
   Inside a chat, `/model custom:<model>` switches for that session only.
3. Restart Hermes (or the container). Small models (e.g. `llama3.2:3b`) are faster but
   weaker at tool calling; `qwen3.5:4b` is the default for that reason (see `docs/models.md`).

To get cloud fallback when dorkmini is down, point `base_url` at LiteLLM
(`http://n8npi:4000/v1`, model `local-chat`, `api_key` set); see the commented block
in the template.

## Multiple Hermes containers on the Pi

`pi/docker-compose.yml` has a commented `x-hermes` anchor plus `hermes-1`/`hermes-2`
services, using the official multi-arch image `nousresearch/hermes-agent`. Each
instance's `HERMES_HOME` (`/opt/data` in the container) is its own host directory.

```bash
for n in 1 2; do
  sudo install -d -o 1000 -g 1000 /srv/hermes/hermes-$n
  cp hermes/config.yaml.template /srv/hermes/hermes-$n/config.yaml   # then edit per instance
done
# uncomment the anchor + services in pi/docker-compose.yml, then:
make validate && make up-pi
docker exec hermes-1 hermes doctor      # sanity check inside the container
```

Notes:

- Instances run `hermes gateway run` (messaging gateway). Configure platforms with
  `docker exec -it hermes-1 hermes gateway setup`; their tokens go in that instance's
  `/srv/hermes/hermes-N/.env`.
- Pi-hosted instances should use small models or LiteLLM; the Pi's RAM is shared with
  n8n (each instance is capped at 768 MB in compose).
- The containers resolve `dorkmini`/`n8npi` via the Pi's DNS; see the MagicDNS item
  in `docs/runbook.md` if they cannot.
- Upstream's own compose uses `network_mode: host` to serve a dashboard on
  127.0.0.1:9119. This repo uses the default bridge network and no dashboard, so
  nothing is exposed.
- Back up `/srv/hermes` alongside the n8n backups if the agents keep memory you care about.
