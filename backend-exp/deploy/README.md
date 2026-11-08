# Dev deployment (0.1.0-dev-nonsigned)

The dev backend runs on the `ttt-server` VM (GCP project `ttt-ultimate-b7097a`, us-east1-b) as a container,
at **`https://api.everyai.dev`**, served through a Cloudflare Tunnel (named tunnel `everyai-api`; no open port or
certificate on the VM). `deploy.sh` deploys that way by default. The older direct setup below (Anole's own TLS on
`:8443` at `everyai.136-108-68-64.sslip.io`, the certificate from ttt's Caddy) is the fallback
(`EVERYAI_INGRESS=tls EVERYAI_HOSTNAME=…`); it is not running now.

- **Optional accounts, no server keys.** Production config (`ANOLE_ENV=production`, `DEV_AUTH=false`,
  `BILLING_ENABLED=false`): a request without a token is anonymous; signing in is by magic link (Resend). No
  `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY`: users add their own keys in the app (BYOK), or use local models
  and the local harness. The image holds only the binary (`deploy.sh` sends only the binary), so no `.env`
  reaches it. Secrets live in `/opt/everyai/secrets.env` on the VM (root, 0600): `JWT_SECRET` (made once,
  kept across redeploys) and `RESEND_API_KEY` (from the repo-root `.env`), written by `set-secrets.sh`.
- **Rate limit:** `RATE_LIMIT_PER_MINUTE` (600) per client address across the API, plus the tighter `/v1/auth`
  and pairing limits.
- **TLS:** Anole serves HTTPS on 8443 itself. Caddy (the ttt stack, which owns 80/443) obtains and renews the
  certificate for the hostname through a site block that serves nothing else; the container mounts Caddy's
  certificate folder read-only, and `everyai-cert-reload.timer` sends SIGHUP daily.
- **Data:** SQLite in the `everyai_data` volume.

## Deploy or update

```sh
backend-exp/deploy/set-secrets.sh   # once (and after a key change): secrets.env on the VM
backend-exp/deploy/deploy.sh        # cross-compiles here, builds the image on the VM, restarts it
```

Before the first deploy with accounts: `api.everyai.dev` should point at the VM (the sign-in mails link to
`PUBLIC_URL`), and `EVERYAI_HOSTNAME=api.everyai.dev` passed to `deploy.sh`; see `TODO-accounts.md` §3.

`deploy.sh` also installs the compose file (`/opt/everyai`) and the reload timer. Done once by hand: the Caddy block
below in `/opt/ttt/Caddyfile` (backup `Caddyfile.bak-everyai`), and TCP 8443 open (firewall rule `everyai-api`,
network tag `everyai-api` on the VM).

```caddy
# EveryAI dev backend: Caddy only obtains and renews this certificate; Anole serves the API on :8443.
everyai.136-108-68-64.sslip.io {
	respond "EveryAI API: https://everyai.136-108-68-64.sslip.io:8443" 404
}
```

## Runbook (owner actions; the scripts here never run them by themselves)

### Memory: a swapfile
The e2-micro has 1 GB shared with ttt. `swap.sh` adds a 2 GB swapfile with swappiness 10 (idempotent):

```sh
gcloud compute ssh ttt-server --zone us-east1-b --command 'sudo bash -s' < backend-exp/deploy/swap.sh
```

### Egress: limits and a budget alert
The relay meters itself (`src/egress.zig`): `EGRESS_RATE_MBPS` (40) paces sends, `EGRESS_MONTHLY_MB` (768) stops the
relay for the month (sockets get `budget {resets_at}`), and a warning is logged at `EGRESS_WARN_MB` (default 80% of
the month). 768 MB is sized to GCP's Always Free egress: 1 GB a month from North America, **Premium tier only**,
about $0.12/GB past it (secondary sources, 2026-11-08; Google's own page wasn't checked). A Cloudflare Tunnel
doesn't change this: the VM's traffic to Cloudflare is still GCP egress. Per host and per account limits: `RELAY_HOST_*_MB`, `RELAY_ACCOUNT_*_MB`. Byte totals are in the
`egress_usage` table (`d<day>` / `m<month>` rows). Set the month below what the network tier lets you send for
free, then add a billing alert so a mistake costs at most a dollar:

```sh
gcloud billing budgets create --billing-account=<ACCOUNT_ID> --display-name="everyai egress" \
  --budget-amount=1USD --threshold-rule=percent=0.5 --threshold-rule=percent=1.0
```

**Network tier.** The free egress allowance depends on the tier. Moving the VM's external address to the Standard
tier **changes its IP** (the sslip hostname and any DNS record must follow):

```sh
gcloud compute instances delete-access-config ttt-server --zone us-east1-b --access-config-name="external-nat"
gcloud compute instances add-access-config ttt-server --zone us-east1-b --network-tier=STANDARD
```

Read Google's current free-tier and network-tier pages before choosing; record what they say in `TODO-accounts.md`.

### TLS: Cloudflare Tunnel (optional) or Anole's own
- **Tunnel:** create a named tunnel on the Cloudflare account (Zero Trust → Networks → Tunnels), add the public
  hostname `api.everyai.dev → http://backend:8080` (`cloudflared.example.yml` records it), put
  `TUNNEL_TOKEN=…` in the root `.env` and run `set-secrets.sh` (it goes to `/opt/everyai/tunnel.env`, so the
  cloudflared container never sees the backend's secrets), then
  `docker compose -f docker-compose.yml -f docker-compose.tunnel.yml up -d`. No open port or certificate on the VM;
  the 8443 firewall rule can go. Check the relay through it:
  `cd frontend && dart run tool/relay_check.dart https://api.everyai.dev` (pairs an anonymous host and device and
  sends a frame each way; no model calls).
- **Fallback, as today:** Anole serves HTTPS on 8443 with the certificate Caddy renews (or certbot's), reloaded on
  SIGHUP by `everyai-cert-reload.timer`.

### Moving off the ttt VM (checklist, never run by an agent)
1. A VM of its own (e2-micro, same region), the swapfile, Docker, `set-secrets.sh` against it.
2. Copy the `everyai_data` volume (stop the container first; SQLite with WAL needs the `-wal` file too).
3. Point `api.everyai.dev` (or the tunnel) at it; run `relay_check.dart`.
4. Only then, on the ttt VM: `docker compose -p everyai down`, remove `/opt/everyai`, the `everyai-cert-reload`
   timer, the Caddy block (restore from `/opt/ttt/Caddyfile.bak-everyai` by hand, then reload Caddy), and the
   `everyai-api` firewall rule and network tag. Leave every ttt container and file alone.
