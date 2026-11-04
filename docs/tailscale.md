# Tailscale

## MagicDNS notes

- Short names (`n8npi`, `dorkmini`) work on devices with MagicDNS enabled. The FQDN
  is `<host>.<tailnet>.ts.net`; use it where search domains are not applied.
- **Inside Docker containers** MagicDNS works only if the container inherits the
  host resolver. If n8n/LiteLLM report `ENOTFOUND dorkmini`, see `runbook.md`.
- Keep hostnames stable: renaming a device in the admin console changes its
  MagicDNS name and breaks every URL in `.env` and the workflows.
- Tailscale IPs (`tailscale ip -4`) are stable per device but are personal data:
  they live only in `.env`, never in the repo.

## Expose / don't expose

| Service | Port | Exposed to | Never |
|---|---|---|---|
| n8n UI + webhooks | 5678 on n8npi | your admin devices | LAN, Funnel, public DNS |
| LiteLLM | 4000 on n8npi | n8npi itself, admin devices, Hermes hosts | LAN, Funnel |
| Ollama | 11434 on dorkmini | n8npi, Hermes hosts, admin devices | LAN, Funnel, `0.0.0.0` bind |
| OpenClaw | 18789 on n8npi (recommended host) | admin devices | Funnel (OpenClaw's own `tailscale.mode: funnel` included), LAN |
| SSH | 22 | admin devices (prefer Tailscale SSH) | password auth |

- **No Tailscale Funnel** for any of these. If a webhook must be reachable from the
  internet (e.g. a SaaS callback), expose only that one path through a separate,
  deliberate setup and document it. Do not reintroduce Cloudflare Tunnel.
- `tailscale serve` (tailnet-only HTTPS) is fine if you want a real TLS cert for n8n:
  bind n8n to `127.0.0.1`, run `tailscale serve --bg 5678`, set
  `N8N_PROTOCOL=https`, `N8N_SECURE_COOKIE=true` and the `ts.net` URL in `.env`.

## ACL suggestion

Tag the servers so access is by role, not by user. Note that tagging a device
disables its key expiry and detaches it from your user; re-authenticate with
`tailscale up --advertise-tags=tag:homelab-pi` (or `tag:homelab-mac`).

```jsonc
{
  "tagOwners": {
    "tag:homelab-pi":  ["autogroup:admin"],
    "tag:homelab-mac": ["autogroup:admin"]
  },
  "acls": [
    // You (admins) can reach the service ports and SSH.
    { "action": "accept", "src": ["autogroup:admin"],
      "dst": ["tag:homelab-pi:22,5678,4000,18789", "tag:homelab-mac:22,11434"] },
    // The Pi (n8n, LiteLLM, Hermes containers) may call Ollama, nothing else.
    { "action": "accept", "src": ["tag:homelab-pi"], "dst": ["tag:homelab-mac:11434"] }
    // If OpenClaw runs on dorkmini instead, move 18789 to the tag:homelab-mac entry.
    // If Hermes on dorkmini should use LiteLLM, also allow
    //   { "action": "accept", "src": ["tag:homelab-mac"], "dst": ["tag:homelab-pi:4000"] }
  ],
  "ssh": [
    { "action": "check", "src": ["autogroup:admin"],
      "dst": ["tag:homelab-pi", "tag:homelab-mac"], "users": ["autogroup:nonroot"] }
  ],
  "tests": [
    { "src": "tag:homelab-pi", "accept": ["tag:homelab-mac:11434"], "deny": ["tag:homelab-mac:22"] }
  ]
}
```

Notes: the Mac does not get a rule to the Pi by default (it only serves). Add
`"autogroup:admin"` devices explicitly if you prefer named devices. Use the ACL
`tests` block so a later edit cannot silently open Ollama to everything.

## Other settings

- Enable **key expiry** for personal devices; tagged servers have it off, so protect
  them with Tailnet Lock if you want to stop a stolen admin login adding nodes.
- Disable **subnet routing / exit node** on both servers unless you need them.
- `tailscale up --accept-dns=true` on both, so MagicDNS works for the host itself.
