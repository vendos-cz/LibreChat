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
| `ms365-mcp` | built from `ms365-mcp.Dockerfile` | Outlook / Microsoft 365 MCP server (mail, calendar, contacts) |

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

An unset `PROXY_NETWORK` keeps whatever mode `.env` already records, so a
redeploy that does not pass it cannot tear a proxy-mode server off its proxy.
Moving back to LibreChat's own Caddy is therefore deliberate: clear
`PROXY_NETWORK` in `.env` on the server first, then redeploy.

## Non-secret `.env` defaults

`bootstrap.sh` writes a block of non-secret settings into `.env` on every run,
so they cannot drift back to the `.env.example` values: `SEARCH=true` (config
1.3.14 flipped the default to `false`, which silently disabled MeiliSearch),
the `EMBEDDINGS_*` / `CHUNK_*` / `RAG_USE_FULL_CONTEXT` group, keep-alive and
request timeouts above Caddy's idle timeout, a one-hour session with a 30-day
refresh token, and the IP/concurrency rate limits. Anything that could lock the
operator out — `ALLOW_EMAIL_LOGIN`, `ALLOW_UNVERIFIED_EMAIL_LOGIN`,
`ALLOW_PASSWORD_RESET` — is deliberately left alone, and secrets stay in GitHub
Secrets.

It also mirrors `OPENAI_API_KEY` into `IMAGE_GEN_OAI_API_KEY` — see below.

## Outlook / Microsoft 365 MCP

`ms365-mcp` runs [`@softeria/ms-365-mcp-server`](https://github.com/softeria/ms-365-mcp-server)
in HTTP mode on the internal network only, and `librechat.yaml` declares it as
the `outlook` MCP server pointing at `http://ms365-mcp:3000/mcp`.

Authentication is On-Behalf-Of, not a second login. LibreChat takes the
signed-in user's Entra access token, exchanges it for a Microsoft Graph token
(`jwt-bearer` grant, `OboTokenService`) and sends that as the request's
`Authorization: Bearer` header; the MCP server uses it directly against Graph.
Nobody clicks an OAuth link and no token is stored in the container.

Two prerequisites live outside this repo:

- **`OPENID_REUSE_TOKENS=true` in `.env`.** Without it the user's federated
  access token is never kept, so there is nothing to exchange and the API log
  says `No valid OpenID token available for Graph token exchange`.
- **Delegated Graph permissions on the Entra app registration.** The OBO scope
  is `https://graph.microsoft.com/.default`, which grants exactly what that app
  already has admin consent for — widen it there, not in `librechat.yaml`.

Tool availability follows from those permissions: `--org-mode` exposes the full
tool set (mail, calendar, contacts, Teams, SharePoint, OneDrive), and a call
whose scope was never consented is rejected by Graph, not by the MCP server.

`--allow-unauthenticated-discovery` is deliberate: it lets `initialize` and
`tools/list` through without a bearer so LibreChat's startup inspection can
cache the tool list. Without it startup gets a 401 and LibreChat flags the
server as needing its own OAuth flow. Do **not** add `--trust-proxy-auth` —
it returns from the auth middleware before the bearer is read, so every call
would fall back to the server's own (nonexistent) token instead of the user's.

Bumping the server: change `MS365_MCP_VERSION` in `docker-compose.yml` (or set
it in `.env`) and redeploy.

## Image generation

Nothing about this lives in `librechat.yaml`. Image tools are plugins driven by
`.env`, added per agent in the UI.

**The key.** `OpenAIImageTools.js` resolves `IMAGE_GEN_OAI_API_KEY` and nothing
else — there is no fallback to `OPENAI_API_KEY`, and the manifest authField
carries no `||` alternates the way `dalle`'s `DALLE3_API_KEY||DALLE_API_KEY`
does. It is the same OpenAI credential either way, so `bootstrap.sh` mirrors the
key already in `.env` rather than asking for a second secret holding a copy of
it. A value set deliberately is never clobbered, and the literal
`user_provided` counts as unset, because `loadAuthValues` skips it and falls
through to each user's own key.

**It is agents-only.** Both `OpenAIImageTools.js` and `GeminiImageGen.js` throw
`This tool is only available for agents`, and `TEphemeralAgent` — the mechanism
behind the prompt-bar tool row — does not list image tools at all. So there is
no point putting them in `interface.defaultPinnedTools`. The path is: Agents
endpoint → Agent Builder → Tools → add "OpenAI Image Tools" → **save the
agent** → chat with that agent.

**Diagnosing "the tool does nothing".** In that order:

1. `docker logs LibreChat-API | grep 'Error loading tool image_gen_oai'` — a
   missing or rejected key is caught by `loadTools` and logged, not surfaced.
   The model simply never sees the tool.
2. `endpoints.agents.capabilities` must contain `tools`. Without it
   `ToolService` drops the whole plugin list and Agent Builder shows nothing.
3. If `includedTools` is ever set in `librechat.yaml` it is a **strict
   allowlist** and must then name `image_gen_oai` (which covers `image_edit_oai`
   too, via `toolkitExpansion`). It is deliberately absent here.
4. The tool row appears in Agent Builder **even with no key**, flagged
   `needs_setup` — presence in the UI proves nothing about the key.
5. `gpt-image-1` requires a **verified** OpenAI organisation. If the org behind
   the key is unverified, the mirror is correct and the call still fails
   provider-side.

**Two config settings that exist only because of image tools.**
`imageOutputType` is `png`, not `webp`: `image_edit_oai` appends no
`output_format` to its multipart body but wraps the result as
`data:image/${imageOutputType}`, so webp produces a `.webp` file with MIME
`image/webp` carrying PNG bytes, and `resizeImageBuffer` never calls
`toFormat()` to correct it. And `fileConfig.imageGeneration.percentage: 100`
overrides the `'high'` default, which caps the short side at 768 — a 1024×1024
generation was being stored as 768×768 with nothing saying so. Only
`percentage` is set: it is checked first and ignores `px`.

**Storage.** `fileStrategy` is the default `local`, which writes to
`client/public/images` — mounted as the named volume `librechat-images`, so
generated images survive a container replacement. Losing that mount means
broken image links for every past generation.

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

`.github/workflows/deploy-hetzner.yml` deploys on **push to the `deploy`
branch**, and also still offers **Actions → Deploy to Hetzner → Run workflow**.
Nothing else deploys: a commit to `main` never reaches the server. To release,
fast-forward `deploy` to the commit you want live.

**Push one commit per deploy.** The workflow pipes `bootstrap.sh` from the
*runner's* checkout while the server runs its own `git fetch`, so the script and
the tree it operates on come from whatever each side saw at its own moment. Two
pushes seconds apart therefore let an older script run against a newer tree —
observed live: the tracked config was installed but a mirror step added in the
newer `bootstrap.sh` was not, because the run that reached the server was still
carrying the previous commit's script. Batch related changes into one commit.

Required repository secrets:

| Secret | Required | Notes |
|---|---|---|
| `HETZNER_HOST` | yes | Server IPv4 or hostname |
| `HETZNER_SSH_KEY` | yes | Private key whose public half is in the server's `authorized_keys` |
| `HETZNER_USER` | no | Defaults to `root` |
| `HETZNER_SSH_PORT` | no | Defaults to `22` |
| `HETZNER_DOMAIN` | first deploy only | Omit to serve plain HTTP; afterwards the hostname in `.env` is reused |
| `ACME_EMAIL` | required with `HETZNER_DOMAIN` | Let's Encrypt contact; reused from `.env` once set |

Neither has to be re-supplied on a redeploy. `DOMAIN_SERVER` is what OAuth
callback URLs are built from, so a deploy that arrived without a hostname used
to move the deployment onto its bare IP and break every social login; an unset
value now keeps what `.env` records and only falls back to the IP on a
deployment that never had a hostname.

Settings the deploy can push into the server's `.env`, so they need no
hand-editing over SSH. Each is applied only when set; an unset one leaves the
current value alone. To take a value back *out*, set it to the literal
`none` — deleting a secret is indistinguishable from never having set one, so
that alone will not clear anything.

| Secret | Notes |
|---|---|
| `ANTHROPIC_API_KEY` | Provider key. Also what the memory agent and conversation titles run on |
| `OPENAI_API_KEY` | Provider key. Also mirrored into `IMAGE_GEN_OAI_API_KEY` |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret |
| `GOOGLE_KEY` | Gemini key shared by everyone. `.env.example` ships `GOOGLE_KEY=user_provided`, so without this secret the Google endpoint is still offered and asks every user for their own key |
| `KIMI_API_KEY` | Moonshot/Kimi key. Setting it also adds the Kimi endpoint to `librechat.yaml`; clearing it removes the endpoint again |
| `OPENROUTER_KEY` | Shared OpenRouter credit, spent by the `OpenRouter` endpoint in `librechat.reference.yaml`. Also what server-side calls can reach; the per-user `OpenRouter (own key)` entry cannot be used for those |
| `SERPER_API_KEY` | Web search provider, and required for web search at all. Read by the `webSearch` block in `librechat.reference.yaml` |
| `FIRECRAWL_API_KEY` | Optional scraper for web search. Without it bootstrap strips the `firecrawl` lines from `librechat.yaml`, so scraping falls back to Serper instead of LibreChat demanding a key from every user |
| `BACKUP_PASSPHRASE` | Encrypts each backup archive before it leaves the server. Only meaningful with `BACKUP_SSH_TARGET` set. Keep a copy in a password manager — GitHub cannot show a secret back to you, and the encrypted archives are worthless without it |

| Variable | Notes |
|---|---|
| `ALLOW_SOCIAL_LOGIN` | `true` to show the Google button — credentials alone do not |
| `ALLOW_SOCIAL_REGISTRATION` | `true` to let a new account be created via Google |
| `ALLOWED_REGISTRATION_DOMAINS` | Comma-separated email domains allowed to sign in; defaults to `nasdum.cz` in the workflow |
| `OPENROUTER_USER_KEYS` | `true` also offers an "OpenRouter (own key)" entry each user keys themselves. Unset (the default) does not offer it |
| `BACKUP_SSH_TARGET` | scp destination for the nightly backup, e.g. `u12345@u12345.your-storagebox.de:`. Unset keeps archives on the server, which does not survive losing the server |
| `BACKUP_SSH_PORT` | Port for `BACKUP_SSH_TARGET` when it is not 22. Managed storage often is not |
| `GOOGLE_CLIENT_ID` | Overrides the client id defaulted in the workflow. Not a secret — it is in the redirect every signing-in browser sees, and keeping it in the workflow makes a truncated value reviewable instead of invisible |

### Confirming what is actually deployed

`https://<domain>/api/config` is public and includes `buildInfo`:

```bash
curl -s https://chat.example.com/api/config | jq .buildInfo
# { "commit": "da972a9", "branch": "deploy", "buildDate": "2026-08-21T14:09:34Z" }
```

That is a better signal than an Actions log, which reports what was attempted
rather than what is running. `BUILD_COMMIT` / `BUILD_BRANCH` / `BUILD_DATE` are
written by `bootstrap.sh` **after** the config-install block, so a `buildInfo`
naming the expected commit also proves the run got past installing
`librechat.reference.yaml`. `buildDate` changes on every run, which is how to
tell a fresh deploy from a stale one at an unchanged commit.

**Who can sign in.** Social login applies no domain restriction of its own: with
`registration.allowedDomains` unset in `librechat.yaml`, anyone whose Google
account the consent screen admits can sign in, and `ALLOW_SOCIAL_REGISTRATION`
then creates the account. Closing email registration does not cover this — it is
a separate path. The deploy therefore writes `registration.allowedDomains` from
`ALLOWED_REGISTRATION_DOMAINS`, rewriting just that key in `librechat.yaml` and
leaving the rest of the file (including the unrelated `allowedDomains` keys under
`actions` and `mcpServers`) untouched. Clearing the value leaves the file alone
rather than removing the restriction.

**Where `librechat.yaml` comes from.** Upstream gitignores `librechat.yaml`, so
the version-controlled copy lives here as `librechat.reference.yaml` and
`bootstrap.sh` installs it over the live file on **every** deploy, keeping the
previous one as `librechat.yaml.bak-<timestamp>`. Editing the file on the server
therefore buys you a restart-fast change that the next deploy discards — put the
change in `librechat.reference.yaml` too. Delete the reference file and the old
behaviour returns: seed once from `librechat.example.yaml`, never replace.

This replaced seed-once because the drift was real. The live config had stayed
the upstream example for months: `librechat.ai` terms-of-service links, five
demo endpoints with no keys behind them, and a Kimi entry duplicated by an
older marker format.

Two ordering facts matter if you change any of this. The install happens
*before* `set_allowed_domains` and `set_managed_endpoints` run, so those two
patch the freshly installed file — which is why the reference file must keep a
bare `registration:` line and a two-space `  custom:` line, and must **not**
carry the `# >>> deploy-managed endpoints` markers itself. And because the
workflow pipes `bootstrap.sh` from the *runner's* checkout while the server
checks out `$BRANCH` separately, deploying a branch whose `bootstrap.sh` differs
from `main` means dispatching the workflow on that same branch.

**Adding a model provider.** A secret on its own does nothing: the key has to
reach the server's `.env` *and* an endpoint has to reference it in
`librechat.reference.yaml`. Kimi shows how both halves are wired — everything the deploy
adds lives inside one `# >>> deploy-managed endpoints` marker pair, so the
endpoints upstream ships in the same list are never touched, and an entry is
written only while its credential is configured, so a menu item cannot outlive
the key behind it.

**Shared key or the user's own.** A custom endpoint takes its key from the
environment *or* from each user, never both: `initialize.ts` reads
`userValues.apiKey` and ignores the configured value as soon as it is
`user_provided`. Offering both therefore means offering two entries, which is
what OpenRouter does here — the upstream entry spends `OPENROUTER_KEY`, and the
deploy-managed "OpenRouter (own key)" entry prompts each user for their own via
**Set API Key** in the UI and stores it encrypted.

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

Switching `SEARCH` from `false` to `true` does not backfill the index. If older
conversations do not turn up in search, reset the sync flags and restart:

```bash
docker exec LibreChat-API npm run reset-meili-sync
docker restart LibreChat-API
```

### Backup

`backup.sh` runs nightly from the `librechat-backup.timer` systemd unit that
`bootstrap.sh` installs, and writes a single verified archive to
`/var/backups/librechat/`, keeping the newest 14. Take one on demand — before a
risky change, or to check the plumbing — with the **Back up Hetzner now**
workflow, which starts the same unit the timer does.

Each archive holds four things:

| Member | Why it has to be there |
|---|---|
| `env` | `CREDS_KEY`/`CREDS_IV`. Every user-provided API key in Mongo is encrypted with them, so **restoring Mongo without this file gets you a database of ciphertext.** Also the JWT secrets and every provider key |
| `mongo.archive.gz` | `mongodump` of the `LibreChat` database — conversations, users, agents, memories, shared links |
| `librechat-uploads.tar.gz` | attached files, and the source documents the RAG index was built from |
| `librechat-images.tar.gz` | generated images, referenced from messages |

Left out on purpose: `meili-data` and `pgdata` are indexes derived from the
above and are cheaper to rebuild (`npm run reset-meili-sync`, and re-uploading
to the RAG API) than to store.

The script refuses to report success it cannot prove: it reads the finished
archive back, requires `env` and `mongo.archive.gz` to be present and larger
than a floor, and checks the copied `.env` still contains a `CREDS_KEY`. It
also refuses to run at all if `mongodump` is missing from the Mongo container,
rather than falling back to tarring a live data directory — that produces an
archive which may not replay, and finding that out during a restore is the
worst possible time.

#### Off-site

Unset, backups stay on the server, which covers a bad migration or a dropped
collection but not the loss of the machine. Setting it up is four steps, and
only the first cannot be done from the repository:

1. Get storage reachable over ssh. A Hetzner Storage Box is the cheapest fit —
   same datacentre, and `scp` needs no extra tooling. **Check which port it
   listens on**; managed storage often does not use 22, and if yours does not,
   set the `BACKUP_SSH_PORT` variable to it.
2. Set the `BACKUP_SSH_TARGET` repository variable to the scp destination, e.g.
   `u12345@u12345.your-storagebox.de:`, and deploy. The deploy generates an
   outbound ed25519 key at `/root/.ssh/librechat-backup` if it does not exist
   and **prints its public half in the log** — the GitHub deploy key opens
   GitHub → server, which is the other direction and no use here.
3. Authorise that public key on the storage side. This is the one manual step.
4. Set the `BACKUP_PASSPHRASE` secret, so only an encrypted copy leaves the
   server — the archive contains `.env` in the clear. **Keep that passphrase in
   a password manager: GitHub cannot show a secret back to you, and the
   encrypted archives are worthless without it.**

Between steps 2 and 3 the nightly backup still runs and still keeps a local
archive; only the upload fails, loudly. Note also that a failed upload does not
stop rotation — otherwise a destination left broken would let the archives grow
until they filled the disk, and a backup that causes the outage is worse than
no backup.

Do not use a git repository as the destination, private or not. The archive
carries `.env` — every provider key, plus `CREDS_KEY`/`CREDS_IV` — and a commit
is a one-way door: the history keeps it, every clone keeps it, and GitHub's push
protection may well reject the push anyway. Beyond that, git keeps every version
of an 8 MB binary forever with no rotation, and the account that runs the backup
would also be the account that stores it.

#### Restore

Untested restores are not backups, so run through this on a scratch server
before you need it.

```bash
cd /opt/librechat/deploy/hetzner
mkdir -p /tmp/restore && tar xzf /var/backups/librechat/librechat-<stamp>.tar.gz -C /tmp/restore
```

If the archive is encrypted, decrypt it first:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -in librechat-<stamp>.tar.gz.enc \
  -out librechat-<stamp>.tar.gz
```

Put `.env` back **first** — the credentials in Mongo are unreadable without it,
and a partial restore that skips it looks like data loss:

```bash
cp /tmp/restore/env .env && chmod 600 .env
docker compose up -d mongodb
docker exec -i chat-mongodb mongorestore --archive --gzip --drop \
  < /tmp/restore/mongo.archive.gz
```

`--drop` replaces each collection being restored, so restoring into a live
database discards whatever is there now. That is what you want for a real
restore and not what you want for a look around; on a scratch server, or with
`--nsFrom`/`--nsTo` into another database name, for the latter.

Then the file volumes, and the search index which is rebuilt rather than
restored:

```bash
docker run --rm -v librechat_librechat-uploads:/data -v /tmp/restore:/in alpine \
  sh -c 'rm -rf /data/* && tar xzf /in/librechat-uploads.tar.gz -C /data'
docker run --rm -v librechat_librechat-images:/data -v /tmp/restore:/in alpine \
  sh -c 'rm -rf /data/* && tar xzf /in/librechat-images.tar.gz -C /data'

docker compose up -d
docker exec LibreChat-API npm run reset-meili-sync
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

**Image generation aborts partway** — high-quality `gpt-image-1` calls routinely
run past 60 s. The bundled Caddyfile does not impose a read timeout, but any
proxy or CDN in front of it may; `HTTP_REQUEST_TIMEOUT_MS` is set to 300000 on
the app side.

**A `librechat.yaml` change did nothing** — the file is installed from
`librechat.reference.yaml` on every deploy, so a server-side edit may have been
overwritten. Check `librechat.yaml.bak-*` for what was replaced. Note also that
most `interface:` toggles are written into the Mongo role documents at every
start, so an Admin Panel change to one of those keys reverts on restart unless
the key is removed from the reference file.
