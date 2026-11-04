# Security hardening checklist

Tick these off on each device. Items marked (repo) are already done by files here.

## Both devices

- [ ] Tailscale ACLs from `tailscale.md` applied; ACL `tests` pass.
- [ ] No Funnel, no Cloudflare Tunnel, no router port forwards.
- [ ] `.env` is `chmod 600`, owned by the deploy user, and backed up to a password
      manager (it holds `N8N_ENCRYPTION_KEY`; backups are useless without it).
- [ ] `make validate` before every push (secret scan included). (repo: CI runs it)
- [ ] Free-tier LLM keys are scoped/rate-limited in each provider console; rotate if leaked.

## n8npi (Raspberry Pi)

- [ ] SSH: keys only (`PasswordAuthentication no`, `PermitRootLogin no`), or Tailscale SSH.
- [ ] `unattended-upgrades` enabled for security updates; reboot window chosen.
- [ ] Firewall: `ufw default deny incoming`, `ufw allow in on tailscale0`. (Docker
      bypasses ufw; that is why ports bind to the Tailscale IP.) (repo: compose binds)
- [ ] Docker drop-in `scripts/systemd/docker-wait-for-tailscale.conf` installed.
- [ ] Only the deploy user is in the `docker` group (docker group = root).
- [ ] n8n owner account with a strong password and 2FA enabled in the UI.
- [ ] n8n hardening env (repo): Execute Command node excluded, env access blocked in
      expressions, file nodes restricted to the backup-status dir, telemetry off.
- [ ] Webhooks use header auth (repo: workflow 2) and are tailnet-only.
- [ ] Backups: timer enabled; copy `/srv/n8n-backups` off the Pi weekly (encrypted,
      e.g. `restic`/`age`), since SD cards fail. Test a restore quarterly.
- [ ] Boot from SSD/USB rather than SD if possible; enable the hardware watchdog.

## dorkmini (Mac Mini)

- [ ] Ollama bound to the Tailscale IP only (repo: launchd plist; refuses 0.0.0.0).
      Verify: `lsof -nP -iTCP:11434 -sTCP:LISTEN` shows the 100.x address only.
- [ ] Ollama menu-bar app not auto-starting (it would bind localhost separately).
- [ ] macOS firewall on, stealth mode on; automatic security updates on.
- [ ] FileVault: on is safer, but blocks unattended boot (auto-login). Pick one:
      FileVault on + manual unlock after power loss, or off + physical security.
- [ ] Separate standard (non-admin) user for running Ollama, if practical.
- [ ] Only pull models from sources you trust; models are code-adjacent artifacts.
- [ ] Sleep disabled, auto-restart after power failure on (`docs/runbook.md`).
