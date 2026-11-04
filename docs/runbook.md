# Runbook

Start with `make health` (or `./scripts/healthcheck.sh`) and read the FAIL rows.

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

**Workflows fail with `ENOTFOUND dorkmini` / `n8npi`.** The container cannot use
MagicDNS. Check `/etc/resolv.conf` on the Pi: if it points to a local stub
(127.0.0.53), Docker falls back to public DNS. Fix one of:
add `dns: [100.100.100.100]` to the n8n service, use the full `*.ts.net` names, or
run `tailscale up --accept-dns=true` so the host resolver is Tailscale's.

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

**Every request goes to the cloud.** LiteLLM cannot reach Ollama: check the
`ENOTFOUND` item above and `OLLAMA_API_BASE`; a failing deployment is skipped for
`cooldown_time` (120 s) after `allowed_fails`.

**429s / `No deployments available`.** Every deployment in the chain is cooling
down or over its rpm. Lower request volume, add a provider key, or raise `rpm` if
your tier allows. Check model IDs still exist (free catalogues change).

**401 from LiteLLM.** The client is not sending `Authorization: Bearer $LITELLM_MASTER_KEY`.

## Tailscale

**`tailscale FAIL BackendState=NeedsLogin`.** Key expired or logged out:
`sudo tailscale up` (tagged devices do not expire). Service URLs fail until it is back.
