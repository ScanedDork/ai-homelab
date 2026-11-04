# Plan: moving ranjeetskanda.com off Hostinger shared hosting

**Status: plan only, nothing here is automated.** Assumption to verify first: the site
is static or can become static (HTML/CSS/JS, or a static-site generator). If it is
WordPress/PHP with a database, see "If the site is dynamic" below.

## Inventory first (on Hostinger)

1. Export the site files and any database; note PHP version and cron jobs.
2. Record **all DNS records**, especially **MX, SPF, DKIM, DMARC** if Hostinger hosts
   email. Email is the most common casualty of a hosting move.
3. Note where the domain is registered (Hostinger or elsewhere) and its renewal date.
4. Lower DNS TTLs to 300 s at least 48 h before cutover.

## Options

| | Cloudflare Pages | Cloudflare R2 | Supabase | Caddy on dorkmini |
|---|---|---|---|---|
| What it is | Static hosting + CDN, git deploys | S3-compatible object storage | Postgres + auth + storage + edge functions | Self-hosted web server |
| Good for | The website itself | Large files, media, downloads, backups | Dynamic data (forms, auth, comments) | Experiments, tailnet-only sites |
| Cost | Free tier is generous | Free tier 10 GB, no egress fees | Free tier, projects pause when idle | Free, but your power/uptime |
| Uptime | Global CDN | Global | Managed (free tier pauses) | Home internet + one Mac |
| Ops effort | Very low | Low | Medium | High (TLS, updates, monitoring) |
| Security impact | None on homelab | None on homelab | None on homelab | **Exposes dorkmini to the internet** |
| Lock-in | Low (static files) | Low (S3 API) | Medium (Postgres is portable, auth less so) | None |
| Custom domain | Apex needs the zone on Cloudflare DNS; subdomain works via CNAME | Via custom domain on Cloudflare zone | Custom domains on paid plans | Your DNS + public IP or tunnel |

Notes:
- Caddy on dorkmini needs inbound public access: router port forwarding or Tailscale
  Funnel. Both put the inference box on the internet, against this homelab's
  isolation goal. Cloudflare Tunnel was already tried and replaced; not an option.
- Cloudflare Pages/R2 are unrelated to Cloudflare Tunnel; using them does not touch
  the homelab network.

## Recommendation

**Cloudflare Pages for the site**, **R2 only if** there are large assets that do not
belong in git, **Supabase only if** a dynamic feature is actually needed (e.g. a
contact form). Keep Caddy on dorkmini for tailnet-only previews, not public hosting.

## Steps

1. Put the site in a git repo (separate from this one); build it locally.
2. Create a Pages project from that repo; check the `*.pages.dev` preview.
3. Move DNS to Cloudflare (add the zone, copy **every** record from the inventory,
   including email records), or keep DNS where it is and use a `www` CNAME.
4. Add the custom domain in Pages; wait for the certificate.
5. Cut over by switching nameservers (or the A/CNAME records); keep TTL low.
6. Verify: site, HTTPS, redirects (`_redirects` file), email send/receive, SPF/DKIM.
7. Keep the Hostinger plan running for at least two weeks before cancelling.

## Rollback

- DNS-level: point nameservers (or A/CNAME) back to Hostinger's values from the
  inventory. With TTL 300 the switch-back is minutes; nameserver changes can take
  hours, so prefer record-level cutover if DNS already lives at Cloudflare.
- Nothing is deleted on Hostinger until the two-week window passes, so rollback
  never needs a re-upload.

## If the site is dynamic (WordPress/PHP)

Pages cannot run PHP. Options: export to static (e.g. a static-export plugin) and
follow the plan above; or move to a managed WordPress host. Do not self-host a public
WordPress on dorkmini.
