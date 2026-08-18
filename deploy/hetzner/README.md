# LibreChat on Hetzner Cloud

Production deployment for this fork: builds the app image from the checked-out
source (so fork changes are actually deployed), fronted by Caddy with automatic
Let's Encrypt certificates.

## Stack

| Service | Image | Purpose |
|---|---|---|
| `caddy` | `caddy:2.10-alpine` | TLS termination, reverse proxy, ports 80/443 |
| `api` | built from `Dockerfile.multi` (`api-build`) | LibreChat server + client bundle |
| `mongodb` | `mongo:8.0.20` | Primary datastore |
| `meilisearch` | `getmeili/meilisearch:v1.35.1` | Conversation search |
| `vectordb` | `pgvector/pgvector:0.8.0-pg15` | Embeddings for RAG |
| `rag_api` | `librechat-rag-api-dev-lite` | File ingestion / retrieval |

Only Caddy publishes ports. Everything else stays on the internal Docker
network.

## Server sizing

The client bundle is built on the server. **CX32 (4 vCPU / 8 GB) or larger** is
the comfortable choice; on CX22 (2 vCPU / 4 GB) the build works only because
`bootstrap.sh` adds a 4 GB swap file, and it is slow. Disk: 40 GB+.

## First deploy

Point an A record at the server's IPv4 (and AAAA at its IPv6) before starting,
otherwise Let's Encrypt cannot validate the domain.

```bash
ssh root@YOUR_SERVER_IP

curl -fsSL https://raw.githubusercontent.com/vendos-cz/LibreChat/main/deploy/hetzner/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh

DOMAIN=chat.example.com ACME_EMAIL=you@example.com BRANCH=main ./bootstrap.sh
```

The first run installs Docker, adds firewall rules for 22/80/443, clones the
repo to `/opt/librechat`, generates `.env` with fresh secrets, then builds and
starts the stack. Expect **10–15 minutes** for the initial build.

Two safeguards apply when the server is not dedicated to LibreChat:

- **`ufw` is not switched on** unless you pass `SETUP_FIREWALL=1`. The allow
  rules are always added, but enabling a firewall on a server already running
  other services can cut them off. If `ufw` is already active, rules are simply
  applied.
- **Ports 80 and 443 are checked before the stack starts.** Caddy needs both; if
  anything else holds them, the script aborts and names the process instead of
  fighting over the port. Redeploys skip this check once Caddy owns the ports.

Without `DOMAIN` the stack serves plain HTTP on port 80 using the server's
public IP — fine for a smoke test, not for real use.

### Immediately after the first deploy

1. Open the URL and register the first account.
2. Close registration:
   ```bash
   cd /opt/librechat/deploy/hetzner
   sed -i 's/^ALLOW_REGISTRATION=.*/ALLOW_REGISTRATION=false/' .env
   docker compose up -d api
   ```
3. Add the provider API keys you need (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, …)
   to `.env` and re-run `docker compose up -d api`.

## Google sign-in for one company domain

Instead of handing out passwords, let everyone with a company address sign in
with Google and get their account on first use. Two pieces do the work: the
Google OAuth client in `.env`, and the email-domain allowlist in
`librechat.yaml`.

**1. Create the OAuth client** in Google Cloud Console, under **APIs &
Services**:

- **OAuth consent screen** — user type **Internal** if the company domain is a
  Google Workspace domain. Only accounts in that Workspace can then reach the
  client at all, and no app verification is needed.
- **Credentials → Create credentials → OAuth client ID → Web application** —
  authorized redirect URI `https://<your-domain>/oauth/google/callback`, matched
  exactly, scheme included. See the Actions section below for how that URI is
  derived and when a second one is needed.

Google refuses redirect URIs on domains whose ownership cannot be verified, so a
placeholder hostname such as `sslip.io` will not do here — use a host under a
domain you own.

**2. Deploy the settings**, either through the workflow below or on the server:

```bash
cd /opt/librechat/deploy/hetzner
ALLOWED_EMAIL_DOMAINS=example.com \
  ALLOW_SOCIAL_LOGIN=true ALLOW_SOCIAL_REGISTRATION=true \
  GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… \
  DOMAIN=chat.example.com ./bootstrap.sh
```

| Setting | Where it lands | Effect |
|---|---|---|
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | `.env` | Enables the Google strategy |
| `ALLOW_SOCIAL_LOGIN` | `.env` | Shows the "Continue with Google" button |
| `ALLOW_SOCIAL_REGISTRATION` | `.env` | Lets a first Google sign-in create the account |
| `ALLOWED_EMAIL_DOMAINS` | `librechat.yaml` (`registration.allowedDomains`) | Rejects every other email domain |

`ALLOW_REGISTRATION` stays independent: leave it `false` and the email/password
signup form remains closed while Google sign-in works.

The allowlist is what enforces the restriction — it is checked before the
account is created, and again on every later sign-in. With exactly one domain
allowed, LibreChat also sends Google's `hd` parameter, so the account chooser
offers only accounts on that domain instead of failing after the fact.

## Behind an existing reverse proxy

If the server already runs a proxy on 80/443, set `PROXY_NETWORK` to one of that
proxy's docker networks. LibreChat then starts without its own Caddy and joins
that network, keeping its default network for outbound access:

```bash
PROXY_NETWORK=mystack_internal DOMAIN=chat.example.com ./bootstrap.sh
```

`ACME_EMAIL` is not needed — the existing proxy owns certificates. Nothing
routes to LibreChat until that proxy is told to; for Caddy, add:

```
chat.example.com {
    reverse_proxy LibreChat-API:3080 {
        flush_interval -1
    }
}
```

then `docker exec <proxy> caddy reload --config /etc/caddy/Caddyfile`. The
`flush_interval -1` matters as much here as in the bundled Caddyfile: without
it the proxy buffers responses and streamed replies arrive in one lump.

`bootstrap.sh` records the chosen mode in `.env` as `COMPOSE_FILE` and
`COMPOSE_PROFILES`, so the plain `docker compose` commands below pick up the
overlay by themselves — no `-f` juggling, and no risk of a manual `up -d`
quietly detaching the api container from the proxy network.

## Redeploying

Re-running `bootstrap.sh` is the redeploy path — it preserves `.env` and the
data volumes, updates the checkout, and rebuilds:

```bash
cd /opt/librechat/deploy/hetzner
DOMAIN=chat.example.com ACME_EMAIL=you@example.com ./bootstrap.sh
```

(The script re-execs itself from `/tmp` first, so updating the checkout cannot
pull the file out from under the running shell.)

### From GitHub Actions

`.github/workflows/deploy-hetzner.yml` does the same thing over SSH via
**Actions → Deploy to Hetzner → Run workflow**. Required repository secrets:

| Secret | Required | Notes |
|---|---|---|
| `HETZNER_HOST` | yes | Server IPv4 or hostname |
| `HETZNER_SSH_KEY` | yes | Private key whose public half is in the server's `authorized_keys` |
| `HETZNER_USER` | no | Defaults to `root` |
| `HETZNER_SSH_PORT` | no | Defaults to `22` |
| `HETZNER_DOMAIN` | no | Omit to serve plain HTTP |
| `ACME_EMAIL` | required with `HETZNER_DOMAIN` | Let's Encrypt contact |

What changes per run — `branch`, `domain`, `proxy_network`,
`allow_registration`, `allow_social_login`, `allow_social_registration`,
`allowed_email_domains` — are workflow inputs, each applied only when given, so
an empty one keeps what the server already has. `allowed_email_domains` also
falls back to the `ALLOWED_EMAIL_DOMAINS` repository variable, which is where to
keep it so every deploy reasserts the same allowlist.

Settings the deploy can push into the server's `.env`, so they need no
hand-editing over SSH. Each is applied only when set; an unset one leaves the
current value alone.

| Secret | Notes |
|---|---|
| `ANTHROPIC_API_KEY` | Provider key |
| `OPENAI_API_KEY` | Provider key |
| `GOOGLE_CLIENT_ID` | Google OAuth client for social sign-in |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret |

| Variable | Notes |
|---|---|
| `ALLOW_SOCIAL_LOGIN` | `true` to show the Google button — credentials alone do not |
| `ALLOW_SOCIAL_REGISTRATION` | `true` to let a new account be created via Google |

Google's redirect URI is `${DOMAIN_SERVER}${GOOGLE_CALLBACK_URL}`, i.e.
`https://chat.example.com/oauth/google/callback` with the default
`GOOGLE_CALLBACK_URL`. Register exactly that in the Google client; no JavaScript
origins are needed. The admin panel signs in through a separately hard-coded
`/api/admin/oauth/google/callback`, so using that flow means adding a second
redirect URI.

## Operations

```bash
cd /opt/librechat/deploy/hetzner

docker compose ps
docker compose logs -f api
docker compose logs -f caddy      # TLS / certificate issues
docker compose restart api
docker compose down               # stop (volumes survive)
```

### Backup

The state worth backing up lives in the `librechat_mongo-data` (conversations,
users) and `librechat_librechat-uploads` (uploaded files) volumes, plus
`.env`, which holds `CREDS_KEY`/`CREDS_IV` — **without those two, stored
credentials cannot be decrypted.**

```bash
docker run --rm -v librechat_mongo-data:/data -v "$PWD:/backup" alpine \
  tar czf /backup/mongo-$(date +%F).tar.gz -C /data .
```

## Troubleshooting

**Certificate not issued** — check DNS actually resolves to this server
(`dig +short chat.example.com`) and that ports 80/443 are reachable;
`docker compose logs caddy` shows the ACME error.

**Build killed / OOM** — confirm swap is active (`swapon --show`) and lower
`NODE_MAX_OLD_SPACE_SIZE` in `.env`, or build on a larger server type.

**Streaming responses arrive all at once** — the Caddy config disables response
buffering (`flush_interval -1`); a proxy or CDN in front of Caddy is the usual
culprit.
