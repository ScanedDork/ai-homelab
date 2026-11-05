# Runbook

Start with `make preflight` (configuration and host problems) and `make health`
(running services), or open the dashboard. Read the FAIL rows; each says what to do.

## Setup

**`make up-pi` stops at preflight.** Fix the FAIL rows it prints. Use
`SKIP_PREFLIGHT=1 make up-pi` only if you know a row is wrong for your setup.

**Telegram chat ID.** Create a bot with @BotFather and put its token in
`TELEGRAM_BOT_TOKEN`. Send your bot any message, then open
`https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser; `"chat":{"id":...}` is
the value for `TELEGRAM_CHAT_ID`. For a group, add the bot and use the negative
group ID. Then `make provision`.

**`make provision` fails at the webhook check.**
- 404: the workflow did not activate; check `docker logs n8n` and re-run.
- 403: `N8N_WEBHOOK_TOKEN` changed after provisioning; re-run `make provision`.
- 502: n8n works but LiteLLM/Ollama did not answer; see the LiteLLM section.

**Rotating a secret.** Edit it in `.env`, then `make up-pi` (containers pick up the
new value) and `make provision` (n8n credentials). Never rotate `N8N_ENCRYPTION_KEY`
in place: existing credentials would become unreadable.

## n8n

**Container not running after a reboot; logs say `cannot assign requested address`.**
Docker started before Tailscale had an IP. Install the drop-in:
`sudo cp scripts/systemd/docker-wait-for-tailscale.conf /etc/systemd/system/docker.service.d/ && sudo systemctl daemon-reload`, then `make up-pi`.
(Alternative: `sysctl net.ipv4.ip_nonlocal_bind=1`.)

**n8n crash-loops with `n8n's address '::' is not available`.** IPv6 is disabled on
the host. The compose file already sets `N8N_LISTEN_ADDRESS=0.0.0.0` inside the
container; make sure you are on the current compose file.

**`Mismatching encryption keys` / credentials cannot be decrypted.**
`N8N_ENCRYPTION_KEY` in `.env` differs from the key the volume was created with.
Restore the original key (from your password manager, or `config` in the old
volume) and `make up-pi`. Never generate a new key for an existing volume.

**UI login loops or "secure cookie" warning.** Plain HTTP needs
`N8N_SECURE_COOKIE=false`. With `tailscale serve` (HTTPS), set it `true`.

**Webhook URLs in the UI show `localhost`.** Set `N8N_WEBHOOK_URL` in `.env` and recreate.

**Workflows fail with `ENOTFOUND dorkmini` / `n8npi`, or connect to the wrong host.**
Containers do not use MagicDNS for these two names: compose adds fixed entries from
`MAC_TAILSCALE_IP` and `PI_TAILSCALE_IP`. Check them with `tailscale ip -4 dorkmini`
and `tailscale ip -4`, fix `.env`, then `make up-pi`. Other `*.ts.net` names still
need MagicDNS inside Docker; if those fail, run `tailscale up --accept-dns=true` or
add `dns: [100.100.100.100]` to the service.

**Weekly backup report says it cannot read the status file.** The timer has not run
yet, or `BACKUP_DIR/status` was created by Docker as root. Run `make backup`; if it
reports "not writable", `sudo chown -R $USER: /srv/n8n-backups`.

**Disk full on the Pi.** `docker system df`; `docker image prune` (keeps
`homelab/n8n:rollback`); lower `BACKUP_RETENTION`; executions are pruned after 14 days.

## Updates and restores

**`update.sh` exited 2 (rolled back).** The new image did not become healthy; the
previous image is running again. Check `docker logs n8n` for the cause; retry later.
Pin a known-good tag via `N8N_IMAGE=docker.io/n8nio/n8n:<version>` if needed.

**`update.sh` exited 3 (rolled back + restored).** The new version probably migrated
the database, so the old image could not start on it; the pre-update backup was
restored. Data created between backup and failure (minutes) is lost.

**Manual restore.** `./scripts/restore-n8n.sh --latest` (or a specific archive). It
verifies the checksum and takes a `pre-restore` safety backup first.

## Ollama (dorkmini)

**`ollama FAIL HTTP 000`.** In order: Mac asleep (`pmset -g`; set `sleep 0`);
Tailscale down on the Mac; LaunchAgent not running
(`launchctl print gui/$(id -u)/com.homelab.ollama`); Ollama.app holding the port
(`lsof -nP -iTCP:11434`); logs in `~/Library/Logs/ollama/`.

**Works on the Mac via localhost but not from the Pi.** It is bound to 127.0.0.1:
the LaunchAgent is not the instance running. Quit Ollama.app, then
`./mac/install-ollama-launchd.sh`.

**`ollama-models FAIL missing`.** `./mac/pull-models.sh`.

**Slow responses / swapping.** Too many models loaded. Lower `OLLAMA_KEEP_ALIVE`,
or set `OLLAMA_MAX_LOADED_MODELS=1` in the plist template and re-run the installer.

## LiteLLM

**Every request goes to the cloud.** LiteLLM cannot reach Ollama: check
`MAC_TAILSCALE_IP` (item above), `OLLAMA_API_BASE` and that the Mac is awake. A
failing deployment is skipped for `cooldown_time` (120 s) after `allowed_fails`.

**Chat fails with `Missing ... API key` after a local error.** dorkmini is down and
no cloud key is set, so the whole fallback chain failed. Add a key to `.env` and run
`make up-pi`.

**LiteLLM unhealthy right after start.** First start on a Pi takes up to two minutes
(`start_period: 120s`). Check `docker logs litellm`; a YAML error in
`litellm/config.yaml` shows there.

**429s / `No deployments available`.** Every deployment in the chain is cooling
down or over its rpm. Lower request volume, add a provider key, or raise `rpm` if
your tier allows. Check model IDs still exist (free catalogues change).

**401 from LiteLLM.** The client is not sending `Authorization: Bearer $LITELLM_MASTER_KEY`.

## Dashboard

**Container exits with `config error: DASHBOARD_TOKEN ...`.** Set a real token in `.env`
(`openssl rand -hex 32`), then `make up-pi`.

**Page keeps asking for the token.** The token in the browser differs from `.env`
(e.g. after rotating it). Enter the new one; "Forget token" clears the old one.

**Dashboard shows FAIL but `make health` on the Pi is OK.** The container resolves
`dorkmini` from `MAC_TAILSCALE_IP`; see the `ENOTFOUND` item above.

**Tailscale rows show SKIP "tailscaled socket not mounted".** `/var/run/tailscale`
must exist on the Pi when the container starts. Start Tailscale, then `make up-pi`.

**"No tailnet device named dorkmini".** The Mac's machine name in the admin console
differs. Rename it to `dorkmini`, or set `MAC_HOSTNAME` for the dashboard service.

**Backups show WARN "no status file yet".** Run `make backup` once; the dashboard reads
`BACKUP_DIR/status/status.json` read-only.

**Changes to `dashboard/` not visible.** `make up-pi` rebuilds the image; a plain
`docker compose up -d` does not.

## OpenClaw

**Container unhealthy right after first start.** Onboarding has not run; follow
`openclaw/README.md` "First run". `docker logs openclaw-gateway` shows the reason.

**`EACCES` on `/home/node/.openclaw`.** The host directories are not owned by uid 1000:
`sudo chown -R 1000:1000 /srv/openclaw`.

**Control UI rejects the origin.** Add the URL you browse from (e.g. `http://n8npi:18789`)
to `gateway.controlUi.allowedOrigins` (see the README's `config set` command).

**Model answers contain raw tool-call JSON.** The provider points at `.../v1`; change it
to the native `http://dorkmini:11434`.

## Hermes containers

**`hermes-N` restarts in a loop.** `docker logs hermes-N`; usually a missing or invalid
`/srv/hermes/hermes-N/config.yaml`. Check with `docker exec hermes-N hermes doctor`.

**Permission denied under `/opt/data`.** The instance dir owner must match
`HERMES_UID`/`HERMES_GID` in `.env`.

## Tailscale

**`tailscale FAIL BackendState=NeedsLogin`.** Key expired or logged out:
`sudo tailscale up` (tagged devices do not expire). Service URLs fail until it is back.
