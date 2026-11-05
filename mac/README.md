# dorkmini (Mac Mini): Ollama

Ollama runs natively (Metal GPU acceleration does not work inside Docker on macOS)
and listens **only on the Mac's Tailscale IP**, port 11434.

## Install

```bash
brew install ollama            # or install the app; the CLI is what launchd runs
./mac/install-ollama-launchd.sh --dry-run   # inspect the rendered plist
./mac/install-ollama-launchd.sh             # install + load the LaunchAgent
./mac/pull-models.sh                        # pull the expected models
./scripts/preflight.sh                      # verify: binding, LaunchAgent, sleep, models
```

`install-ollama-launchd.sh` takes the bind IP from `--ip`, else `MAC_TAILSCALE_IP`
in `.env`, else `tailscale ip -4`. It refuses `0.0.0.0`.

## Notes

- **One Ollama only.** Quit the Ollama menu-bar app and remove it from Login Items;
  otherwise it binds `127.0.0.1:11434` first and the LaunchAgent crash-loops.
- **Local CLI use.** Because Ollama no longer listens on localhost, use
  `OLLAMA_HOST=http://dorkmini:11434 ollama list` on the Mac itself.
- **Boot order.** It is a LaunchAgent, so it starts at user login. The Tailscale
  macOS app also needs a logged-in user, so enable automatic login for the service
  account (FileVault blocks auto-login; see `docs/security.md` for the trade-off).
  `KeepAlive` restarts Ollama until the Tailscale IP exists.
- **Sleep.** `sudo pmset -a sleep 0 disksleep 0` and enable "Start up automatically
  after a power failure"; a sleeping Mac looks like an Ollama outage.
- **Larger models.** Add them to `MAC_EXTRA_MODELS` in `.env` and re-run
  `pull-models.sh` (already-present models are skipped).
- **Logs.** `~/Library/Logs/ollama/`.
- **Uninstall.** `./mac/install-ollama-launchd.sh --uninstall`.
