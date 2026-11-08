# Dev deployment (0.1.0-dev-nonsigned)

The dev backend runs on the `ttt-server` VM (GCP project `ttt-ultimate-b7097a`, us-east1-b) as a container,
at `https://everyai.136-108-68-64.sslip.io:8443`.

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
