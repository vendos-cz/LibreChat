#!/usr/bin/env bash
#
# One-shot bootstrap for LibreChat on a fresh Hetzner Cloud server (Ubuntu 24.04).
#
#   DOMAIN=chat.example.com ACME_EMAIL=you@example.com ./bootstrap.sh
#
# Re-running is safe: existing secrets in .env are preserved, images are
# rebuilt from the current checkout, and the stack is restarted in place.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/vendos-cz/LibreChat.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/librechat}"
DEPLOY_DIR="$APP_DIR/deploy/hetzner"
DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
# Enabling a firewall on a server that already runs other services can cut
# them off, so ufw is only switched on for a server dedicated to LibreChat.
# Rules are always added; SETUP_FIREWALL=1 is what actually enables ufw.
SETUP_FIREWALL="${SETUP_FIREWALL:-0}"
# Set to an existing docker network to run behind a reverse proxy that already
# owns ports 80/443. LibreChat then starts without its own Caddy and joins that
# network, and the proxy is expected to route a hostname to LibreChat-API:3080.
PROXY_NETWORK="${PROXY_NETWORK:-}"
# Comma-separated email domains allowed to sign in. Social login has no domain
# restriction of its own, so leaving this empty lets anyone with a Google
# account register once the OAuth consent screen is published.
ALLOWED_REGISTRATION_DOMAINS="${ALLOWED_REGISTRATION_DOMAINS:-}"
# Moonshot/Kimi key. Set it and the endpoint appears in librechat.yaml; clear it
# and the endpoint is removed again, so a menu entry never outlives its key.
KIMI_API_KEY="${KIMI_API_KEY:-}"
# The OpenRouter entry upstream ships reads ${OPENROUTER_KEY}, so delivering
# that secret is all a shared key needs. Set this to "true" to *also* offer a
# second entry each user keys themselves.
OPENROUTER_USER_KEYS="${OPENROUTER_USER_KEYS:-}"
# Firecrawl scrapes pages for web search. Naming it in librechat.yaml without a
# key does not fall back to Serper — it makes LibreChat demand the key from each
# user — so the config is stripped back when this is empty. Declared here
# because the stripping reads it directly and the script runs under `set -u`.
FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"
# scp destination for the nightly backup, e.g. u12345@u12345.your-storagebox.de:
# Unset keeps backups on this server only, which covers a bad migration or a
# dropped collection but not the loss of the server itself. The archive holds
# .env in the clear, so set BACKUP_PASSPHRASE too and only an encrypted copy
# leaves the machine.
BACKUP_SSH_TARGET="${BACKUP_SSH_TARGET:-}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
# Managed storage frequently listens somewhere other than 22.
BACKUP_SSH_PORT="${BACKUP_SSH_PORT:-}"

compose() {
  if [ -n "$PROXY_NETWORK" ]; then
    PROXY_NETWORK="$PROXY_NETWORK" docker compose \
      -f docker-compose.yml -f docker-compose.proxy.yml "$@"
  else
    docker compose --profile edge -f docker-compose.yml "$@"
  fi
}

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (or via sudo)."

# On redeploy this script lives inside the checkout it is about to git-update.
# Bash reads scripts incrementally, so rewriting the file mid-run can corrupt
# execution — re-exec from a copy outside the repo first.
SELF="$(readlink -f "$0" 2>/dev/null || true)"
case "${BOOTSTRAP_REEXEC:-}:$SELF" in
  1:*) ;;
  *:"$APP_DIR"/*)
    TMP_SELF="$(mktemp /tmp/librechat-bootstrap.XXXXXX)"
    cp "$SELF" "$TMP_SELF"
    export BOOTSTRAP_REEXEC=1
    exec bash "$TMP_SELF" "$@"
    ;;
esac

# Only our own Caddy needs an ACME contact; behind an external proxy that
# proxy already owns certificate issuance.
if [ -n "$DOMAIN" ] && [ -z "$ACME_EMAIL" ] && [ -z "${PROXY_NETWORK:-}" ]; then
  die "ACME_EMAIL is required when DOMAIN is set (Let's Encrypt needs it)."
fi

log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git gnupg ufw ipset iproute2 jq

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$(. /etc/os-release && echo "$VERSION_CODENAME")" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

# The client bundle is built with esbuild/vite in-container; small Hetzner
# plans (CX22/CX32) OOM during that step without swap.
if ! swapon --show=NAME --noheadings | grep -q .; then
  log "Creating ${SWAP_SIZE} swap file"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Adding firewall rules (22, 80, 443)"
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null

if ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "ufw already active — rules applied"
elif [ "$SETUP_FIREWALL" = "1" ]; then
  log "Enabling ufw"
  ufw --force enable >/dev/null
else
  log "ufw left inactive (pass SETUP_FIREWALL=1 to enable it)"
fi

if [ -d "$APP_DIR/.git" ]; then
  log "Updating checkout in $APP_DIR ($BRANCH)"
  # The clone is shallow and single-branch, so its fetch refspec only covers
  # the branch first deployed. Name the refspec explicitly, otherwise deploying
  # any other branch fails with "origin/<branch> is not a commit".
  # reset --hard leaves untracked and ignored files alone, so .env survives.
  git -C "$APP_DIR" fetch --depth 1 origin \
    "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  git -C "$APP_DIR" reset -q --hard
  git -C "$APP_DIR" checkout -q -B "$BRANCH" "refs/remotes/origin/$BRANCH"
else
  log "Cloning $REPO_URL ($BRANCH) into $APP_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi

# The Actions workflow pipes this script from the *runner's* checkout, while the
# block above updates the server's checkout on its own. Those are two separate
# reads of the branch, so they can land on different commits: push twice in
# quick succession and an older script runs against a newer tree. Observed live
# — the tracked config was installed from the new tree while a step added in the
# same push was missing, because the script came from the previous commit.
#
# Fix it where it can be fixed: hand off, exactly once, to the copy in the tree
# that is about to be deployed. Whatever arrived on stdin, the script that does
# the work is then always the one that ships with the config it installs.
#
# The copy runs from /tmp, so the re-exec guard above does not fire again, and
# BOOTSTRAP_HANDOFF stops this from looping. The cost is one repeated pass over
# the prerequisites, which are all idempotent.
if [ "${BOOTSTRAP_HANDOFF:-}" != "1" ] && [ -f "$DEPLOY_DIR/bootstrap.sh" ]; then
  HANDOFF_SELF="$(mktemp /tmp/librechat-bootstrap-tree.XXXXXX)"
  cp "$DEPLOY_DIR/bootstrap.sh" "$HANDOFF_SELF"
  export BOOTSTRAP_HANDOFF=1
  log "Handing off to the checked-out bootstrap.sh ($(git -C "$APP_DIR" rev-parse --short HEAD))"
  exec bash "$HANDOFF_SELF" "$@"
fi

cd "$DEPLOY_DIR"

# librechat.yaml is gitignored upstream, so the version-controlled copy lives
# beside this script as librechat.reference.yaml and is installed over the live
# file on every deploy. That trades "manual edits on the server survive" for
# "the config is in git and cannot drift" — the drift is what bit us: the live
# file was still the upstream example, complete with librechat.ai ToS links,
# five keyless demo endpoints and a duplicated Kimi entry.
#
# A timestamped backup is kept, and the copy is skipped when the file is already
# identical so a redeploy does not litter the directory.
if [ -f librechat.reference.yaml ]; then
  if [ -f librechat.yaml ] && cmp -s librechat.reference.yaml librechat.yaml; then
    log "librechat.yaml already matches librechat.reference.yaml"
  else
    if [ -f librechat.yaml ]; then
      backup="librechat.yaml.bak-$(date +%Y%m%d-%H%M%S)"
      cp librechat.yaml "$backup"
      log "Installing librechat.reference.yaml (previous kept as $backup)"
    else
      log "Installing librechat.reference.yaml"
    fi
    cp librechat.reference.yaml librechat.yaml
  fi
elif [ ! -f librechat.yaml ]; then
  log "No librechat.reference.yaml — seeding from librechat.example.yaml"
  cp "$APP_DIR/librechat.example.yaml" librechat.yaml
fi

# The reference config names Firecrawl as the scraper, which is right when its
# key is delivered and wrong when it is not: loadWebSearchAuth fails the
# SCRAPERS category and LibreChat starts asking every user for a Firecrawl key.
# The documented fallback to the search provider's own scraping only happens
# when `scraperProvider` is absent, so absent is what it has to be.
if [ -z "$FIRECRAWL_API_KEY" ] && [ -f librechat.yaml ]; then
  if grep -qE "^  (scraperProvider|firecrawlApiKey):" librechat.yaml; then
    grep -vE "^  (scraperProvider|firecrawlApiKey):" librechat.yaml > librechat.yaml.new
    mv librechat.yaml.new librechat.yaml
    log "FIRECRAWL_API_KEY unset — dropped the firecrawl scraper (Serper will scrape)"
  fi
elif [ -n "$FIRECRAWL_API_KEY" ]; then
  log "Firecrawl scraper configured"
fi

# registration.allowedDomains lives only in librechat.yaml — there is no env
# equivalent — so rewrite that one key in place rather than templating a
# 1000-line example file that would then drift from upstream. Rewriting the
# whole key each time keeps this idempotent.
set_allowed_domains() {
  grep -qE '^registration:[[:space:]]*$' librechat.yaml || die \
    "librechat.yaml has no top-level 'registration:' key, so ALLOWED_REGISTRATION_DOMAINS
  cannot be applied. Add the key, or clear the setting to leave the file alone."

  awk -v domains="$1" '
    $0 ~ /^registration:[[:space:]]*$/ {
      print
      print "  allowedDomains:"
      count = split(domains, list, ",")
      for (i = 1; i <= count; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", list[i])
        if (list[i] != "") print "    - \"" list[i] "\""
      }
      inside = 1
      next
    }
    inside && /^[^[:space:]]/ { inside = 0; dropping = 0 }
    inside && /^[[:space:]]*#?[[:space:]]*allowedDomains:/ { dropping = 1; next }
    inside && dropping && /^[[:space:]]*#?[[:space:]]*-[[:space:]]/ { next }
    inside && dropping { dropping = 0 }
    { print }
  ' librechat.yaml > librechat.yaml.new

  mv librechat.yaml.new librechat.yaml
}

if [ -n "$ALLOWED_REGISTRATION_DOMAINS" ]; then
  set_allowed_domains "$ALLOWED_REGISTRATION_DOMAINS"
  log "Sign-in restricted to: $ALLOWED_REGISTRATION_DOMAINS"
else
  log "ALLOWED_REGISTRATION_DOMAINS unset — librechat.yaml left alone (any domain may sign in)"
fi

# A GitHub secret on its own does nothing for a provider: the key has to reach
# the server's .env *and* an endpoint has to reference it in librechat.yaml.
# Everything this deploy adds lives inside one marker pair, so the endpoints
# upstream ships in the same list are never disturbed, and an entry withdrawn
# here disappears instead of lingering.
ENDPOINTS_MARKER_OPEN='    # >>> deploy-managed endpoints'
ENDPOINTS_MARKER_CLOSE='    # <<< deploy-managed endpoints'

# A custom endpoint takes its key either from the environment or from each user,
# never both: initialize.ts reads `userValues.apiKey` and ignores the configured
# value as soon as it is `user_provided`. Offering both therefore means offering
# two entries — one on the deployment's key, one on the user's own.
set_managed_endpoints() {
  grep -qE '^  custom:[[:space:]]*$' librechat.yaml || die \
    "librechat.yaml has no 'endpoints.custom:' list, so deploy-managed endpoints
  cannot be added. Restore the key, or clear the provider keys to leave it alone."

  # `close` is an awk keyword, so the marker variables cannot be named after it.
  awk -v kimi="$1" -v byok="$2" \
      -v mark_open="$ENDPOINTS_MARKER_OPEN" -v mark_close="$ENDPOINTS_MARKER_CLOSE" '
    $0 == mark_open { dropping = 1; next }
    $0 == mark_close { dropping = 0; next }
    dropping { next }
    /^  custom:[[:space:]]*$/ {
      print
      if (kimi != "yes" && byok != "yes") { next }
      print mark_open
      if (kimi == "yes") {
        # Model ids and baseURL are from platform.kimi.ai. `fetch: true` means
        # the live /v1/models list is what the picker shows, so a retired id in
        # `default` — which the schema requires — cannot hide a live model.
        print "    - name: \"Kimi\""
        print "      apiKey: \"${KIMI_API_KEY}\""
        print "      baseURL: \"https://api.moonshot.ai/v1\""
        print "      models:"
        print "        default:"
        print "          - \"kimi-k3\""
        print "          - \"kimi-k2.6\""
        print "          - \"moonshot-v1-128k\""
        print "        fetch: true"
        print "      titleConvo: true"
        print "      titleModel: \"current_model\""
        print "      modelDisplayLabel: \"Kimi\""
      }
      if (byok == "yes") {
        # Same gateway as the OpenRouter entry upstream ships, but keyed per
        # user, so anyone can spend their own credit without a shared secret.
        print "    - name: \"OpenRouter (own key)\""
        print "      apiKey: \"user_provided\""
        print "      baseURL: \"https://openrouter.ai/api/v1\""
        print "      models:"
        print "        default:"
        print "          - \"openai/gpt-4o-mini\""
        print "        fetch: true"
        print "      titleConvo: true"
        print "      titleModel: \"current_model\""
        print "      dropParams: [\"stop\"]"
        print "      modelDisplayLabel: \"OpenRouter (own key)\""
      }
      print mark_close
      next
    }
    { print }
  ' librechat.yaml > librechat.yaml.new

  mv librechat.yaml.new librechat.yaml
}

kimi_wanted=no
[ -z "$KIMI_API_KEY" ] || kimi_wanted=yes
byok_wanted=no
[ "$OPENROUTER_USER_KEYS" != "true" ] || byok_wanted=yes

set_managed_endpoints "$kimi_wanted" "$byok_wanted"
log "Deploy-managed endpoints — Kimi: $kimi_wanted, OpenRouter (own key): $byok_wanted"

# set_env KEY VALUE — replaces an existing assignment (commented or not) or
# appends the key. Values are written verbatim, so keep them shell-safe.
set_env() {
  local key="$1" value="$2"
  if grep -qE "^#?${key}=" .env; then
    sed -i -E "s|^#?${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

current_env() {
  sed -nE "s/^$1=(.*)$/\1/p" .env | tail -n1
}

if [ ! -f .env ]; then
  log "Generating .env from .env.example with fresh secrets"
  cp "$APP_DIR/.env.example" .env
  set_env CREDS_KEY "$(openssl rand -hex 32)"
  set_env CREDS_IV "$(openssl rand -hex 16)"
  set_env JWT_SECRET "$(openssl rand -hex 32)"
  set_env JWT_REFRESH_SECRET "$(openssl rand -hex 32)"
  set_env MEILI_MASTER_KEY "$(openssl rand -hex 32)"
  set_env POSTGRES_PASSWORD "$(openssl rand -hex 24)"
else
  log "Reusing existing .env (secrets preserved)"
fi

# Never leave a generated deployment on the example placeholders.
for key in CREDS_KEY CREDS_IV JWT_SECRET JWT_REFRESH_SECRET MEILI_MASTER_KEY; do
  [ -n "$(current_env "$key")" ] || die "$key is empty in .env — set it before deploying."
done

# Non-secret .env defaults this deployment wants but .env.example does not ship.
# Written on every run so they cannot silently drift back. Deliberately absent:
# anything that can lock the operator out (ALLOW_EMAIL_LOGIN,
# ALLOW_UNVERIFIED_EMAIL_LOGIN, ALLOW_PASSWORD_RESET) and anything secret —
# those stay in GitHub Secrets and are handled by the block above.
log "Applying non-secret .env defaults"
# MeiliSearch runs as a container, but config 1.3.14 flipped SEARCH's default
# to false, so nothing was ever searched. MEILI_MASTER_KEY is already generated.
set_env SEARCH true
# chat-rag-api is the "lite" image: remote embeddings only, so OpenAI it is.
set_env EMBEDDINGS_PROVIDER openai
set_env EMBEDDINGS_MODEL text-embedding-3-small
set_env CHUNK_SIZE 1500
set_env CHUNK_OVERLAP 100
set_env RAG_USE_FULL_CONTEXT false
# Heartbeats so Caddy does not drop the connection while a PDF is OCR'd.
set_env FILE_UPLOAD_SSE_ENABLED true
# Keep-alive must exceed the proxy's idle timeout or streams get cut. The
# request timeout also has to clear an image generation, which at high quality
# routinely runs past 60s (discussion #7492 is proxies timing that out).
set_env HTTP_KEEP_ALIVE_TIMEOUT_MS 70000
set_env HTTP_REQUEST_TIMEOUT_MS 300000
# 15 minutes of session is needlessly hostile for a handful of known users.
set_env SESSION_EXPIRY '1000 * 60 * 60'
set_env REFRESH_TOKEN_EXPIRY '(1000 * 60 * 60 * 24) * 30'
set_env LIMIT_CONCURRENT_MESSAGES true
set_env CONCURRENT_MESSAGE_MAX 3
set_env LIMIT_MESSAGE_IP true
set_env MESSAGE_IP_MAX 60
set_env MESSAGE_IP_WINDOW 1
set_env BAN_VIOLATIONS true
set_env FILE_USAGE_USER_MAX 200
set_env FILE_USAGE_USER_WINDOW 15
set_env NO_INDEX true
set_env TRUST_PROXY 1

# The Outlook MCP server authenticates each user by exchanging their Entra
# token for a Microsoft Graph token (OBO). That exchange needs the user's
# federated access token, which is only kept when token reuse is on - without
# it the API logs "No valid OpenID token available for Graph token exchange"
# and Outlook silently has no access. Only set when OpenID is actually
# configured: on a deployment without it the flag would be inert noise.
# Scope of the change: the openidJwt strategy is used only for requests
# carrying token_provider=openid, with the normal jwt strategy still in the
# chain, so Google and password logins are untouched. OpenID users may have to
# sign in once after the deploy that first sets this.
if [ -n "$(current_env OPENID_CLIENT_ID)" ]; then
  set_env OPENID_REUSE_TOKENS true
fi

# An unset DOMAIN must not move a live deployment onto its bare IP. OAuth
# callback URLs are built from DOMAIN_SERVER, so rewriting it silently breaks
# every social login. Recover the hostname .env already records and fall back
# to the IP only on a deploy that never had one. SITE_ADDRESS holds the bare
# hostname in domain mode and ":80" without one, so anything that is not a
# plain hostname means there is nothing to recover.
if [ -z "$DOMAIN" ]; then
  DOMAIN="$(current_env SITE_ADDRESS)"
  case "$DOMAIN" in
    '' | *[!A-Za-z0-9.-]*) DOMAIN="" ;;
  esac
  [ -z "$DOMAIN" ] || log "DOMAIN unset — keeping $DOMAIN from .env"
fi

# Same reasoning: an unset contact must not wipe the stored one, or the next
# certificate renewal loses its ACME account.
if [ -z "$ACME_EMAIL" ]; then
  ACME_EMAIL="$(current_env ACME_EMAIL)"
fi

if [ -n "$DOMAIN" ]; then
  set_env DOMAIN_CLIENT "https://$DOMAIN"
  set_env DOMAIN_SERVER "https://$DOMAIN"
  set_env SITE_ADDRESS "$DOMAIN"
  set_env ACME_EMAIL "$ACME_EMAIL"
else
  public_ip="$(curl -fsS --max-time 10 https://ipv4.icanhazip.com || echo localhost)"
  set_env DOMAIN_CLIENT "http://$public_ip"
  set_env DOMAIN_SERVER "http://$public_ip"
  set_env SITE_ADDRESS ":80"
  set_env ACME_EMAIL ""
fi

# An unset PROXY_NETWORK means "keep the current mode", like every other
# override below. Treating it as "switch to edge" made a deploy that simply
# did not pass the value tear a proxy-mode server off its proxy and then
# collide with it on port 80.
if [ -z "$PROXY_NETWORK" ]; then
  PROXY_NETWORK="$(current_env PROXY_NETWORK)"
fi

# Persist the mode so a bare `docker compose` in this directory behaves like
# the deploy does. Without it a manual `up -d` either fails with "network
# declared as external, but could not be found" or silently drops the api
# container off the proxy network.
set_env PROXY_NETWORK "$PROXY_NETWORK"
if [ -n "$PROXY_NETWORK" ]; then
  set_env COMPOSE_FILE "docker-compose.yml:docker-compose.proxy.yml"
  set_env COMPOSE_PROFILES ""
else
  set_env COMPOSE_FILE "docker-compose.yml"
  set_env COMPOSE_PROFILES "edge"
fi

# Settings worth changing after the first deploy, without hand-editing .env on
# the server. Each is applied only when given, so an unset one keeps its
# current value rather than reverting to the example default.
#
# OPENID_SCOPE is delivered unquoted on purpose. .env.example ships it as
# "openid profile email", and a quoted value reaches the container with the
# quotes attached, which Entra rejects as a scope. set_env writes verbatim, so
# pass the bare scope list and the quotes never appear.
for override in ALLOW_REGISTRATION ALLOW_SOCIAL_LOGIN ALLOW_SOCIAL_REGISTRATION \
                ANTHROPIC_API_KEY OPENAI_API_KEY KIMI_API_KEY OPENROUTER_KEY GOOGLE_KEY \
                SERPER_API_KEY FIRECRAWL_API_KEY \
                GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET \
                OPENID_CLIENT_ID OPENID_CLIENT_SECRET OPENID_ISSUER OPENID_SCOPE \
                OPENID_BUTTON_LABEL; do
  eval "override_value=\${$override:-}"
  [ -n "$override_value" ] || continue
  # Empty means "leave whatever is there alone", which is what makes an unset
  # secret safe — but it also left no way to take a key back out, since
  # deleting the secret is indistinguishable from never setting it. `none` is
  # that way. No provider key or boolean flag has "none" as a legitimate value.
  if [ "$override_value" = "none" ]; then
    set_env "$override" ""
    log "Cleared $override — the deploy environment says none"
    continue
  fi
  set_env "$override" "$override_value"
  log "Applied $override from the deploy environment"
done

# gpt-image-1 is reached through IMAGE_GEN_OAI_API_KEY, and OpenAIImageTools.js
# resolves that variable alone - there is no fallback to OPENAI_API_KEY. A
# deployment with a perfectly good OpenAI key therefore gets no image tools at
# all, and the failure is silent: loadTools catches the init error, logs
# "Error loading tool image_gen_oai:", and the agent simply never sees the tool.
#
# Mirroring the key we already have avoids a second secret for the same
# credential. Placed after the override loop so it picks up a key the deploy
# just delivered. A value set deliberately is never clobbered, and the literal
# "user_provided" counts as unset because loadAuthValues skips it and falls
# through to each user's own key.
image_key="$(current_env IMAGE_GEN_OAI_API_KEY)"
case "$image_key" in
  '' | user_provided)
    openai_key="$(current_env OPENAI_API_KEY)"
    if [ -n "$openai_key" ] && [ "$openai_key" != "user_provided" ]; then
      set_env IMAGE_GEN_OAI_API_KEY "$openai_key"
      log "IMAGE_GEN_OAI_API_KEY mirrored from OPENAI_API_KEY (enables image tools)"
    else
      log "No usable OPENAI_API_KEY - image tools will ask each user for a key"
    fi
    ;;
  *)
    log "IMAGE_GEN_OAI_API_KEY already set explicitly - left alone"
    ;;
esac

# GPT-5.6 rejects function tools alongside reasoning_effort on
# /v1/chat/completions. LibreChat switches such requests to /v1/responses by
# itself, but only for first-party OpenAI: a base URL override makes
# isCanonicalOpenAIBaseURL false and the request keeps the failing path, with
# nothing in the deploy output saying so. Report whether the override is set —
# the name only, never the value, since these logs are world-readable.
openai_base_override="unset"
[ -z "$(current_env OPENAI_REVERSE_PROXY)" ] || openai_base_override="set"
log "OPENAI_REVERSE_PROXY: $openai_base_override (set means GPT-5.6 reasoning keeps Chat Completions)"

set_env BUILD_COMMIT "$(git -C "$APP_DIR" rev-parse --short HEAD)"
set_env BUILD_BRANCH "$BRANCH"
set_env BUILD_DATE "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
chmod 600 .env

port_listener() {
  ss -ltnpH "( sport = :$1 )" 2>/dev/null | tr -s ' '
}

# Both failures below are answered by picking a network. A bare list rarely
# identifies which one, so name the two facts that do: the networks the api
# container already shares with the proxy, and who holds the port.
network_hints() {
  printf 'networks: %s' \
    "$(docker network ls --format '{{.Name}}' 2>/dev/null | sort | tr '\n' ' ')"
  printf '\n  LibreChat-API is on: %s' \
    "$(docker inspect LibreChat-API \
       --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
       2>/dev/null)"
  printf '\n  publishing port 80: %s' \
    "$(docker ps --filter publish=80 --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
}

# Caddy binds 80/443 on the host. If something unrelated already holds them,
# abort before touching it rather than fighting over the port. Skipped once our
# own stack owns them, and irrelevant behind an external proxy.
if [ -z "$PROXY_NETWORK" ] && [ -z "$(compose ps -q caddy 2>/dev/null)" ]; then
  for port in 80 443; do
    listener="$(port_listener "$port")"
    [ -n "$listener" ] || continue
    die "Port $port is already in use on this server:
    $listener
  LibreChat's Caddy needs 80 and 443. Free the port, set PROXY_NETWORK to run
  behind that proxy, or deploy on a separate server (see cloud-init.yaml).
  This server's $(network_hints)"
  done
fi

if [ -n "$PROXY_NETWORK" ]; then
  docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 \
    || die "PROXY_NETWORK '$PROXY_NETWORK' is not an existing docker network.
  This server's $(network_hints)"
  log "Running behind an external proxy on network $PROXY_NETWORK (no own Caddy)"
fi

# Backups run from a systemd timer rather than from this script, so they keep
# happening on the days nobody deploys. The off-site destination lives in
# /etc, not in the checkout, because `reset --hard` above would take it out.
BACKUP_ENV_FILE=/etc/librechat-backup.env
BACKUP_SSH_KEY_FILE=/root/.ssh/librechat-backup

install_backup_timer() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log "No systemd here — backups not scheduled, run backup.sh from cron instead"
    return 0
  fi

  if [ -n "$BACKUP_SSH_TARGET" ]; then
    # The GitHub deploy key opens GitHub -> server. Server -> storage is the
    # other direction and needs a key of its own, or setting the target would
    # only ever produce "Permission denied (publickey)".
    if [ ! -f "$BACKUP_SSH_KEY_FILE" ]; then
      log "Generating an outbound backup key"
      ssh-keygen -q -t ed25519 -N '' -C 'librechat-backup' -f "$BACKUP_SSH_KEY_FILE"
    fi

    umask 077
    {
      printf 'BACKUP_SSH_TARGET=%s\n' "$BACKUP_SSH_TARGET"
      printf 'BACKUP_SSH_KEY=%s\n' "$BACKUP_SSH_KEY_FILE"
      [ -z "$BACKUP_SSH_PORT" ] || printf 'BACKUP_SSH_PORT=%s\n' "$BACKUP_SSH_PORT"
      [ -z "$BACKUP_PASSPHRASE" ] || printf 'BACKUP_PASSPHRASE=%s\n' "$BACKUP_PASSPHRASE"
    } > "$BACKUP_ENV_FILE"
    umask 022
    log "Off-site backup target written to $BACKUP_ENV_FILE"

    # The public half is not a secret and is the one thing that cannot be
    # automated from here: it has to be authorised on the storage side.
    printf '\n  Authorise this key on the backup destination:\n\n    %s\n' \
      "$(cat "$BACKUP_SSH_KEY_FILE.pub")"
    printf '\n  Until it is authorised, backups still run and stay local, and the\n'
    printf '  nightly unit fails loudly on the upload.\n'
  fi

  cat > /etc/systemd/system/librechat-backup.service <<UNIT
[Unit]
Description=Back up LibreChat (database, .env, uploads, images)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
EnvironmentFile=-$BACKUP_ENV_FILE
ExecStart=$DEPLOY_DIR/backup.sh
UNIT

  # Persistent=true runs a missed backup once the server is back, which is the
  # difference between a nightly backup and a backup on nights it happened to
  # be up. The delay keeps it off the top of the hour.
  cat > /etc/systemd/system/librechat-backup.timer <<'UNIT'
[Unit]
Description=Nightly LibreChat backup

[Timer]
OnCalendar=*-*-* 03:20:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now librechat-backup.timer >/dev/null 2>&1 \
    || log "WARNING: could not enable librechat-backup.timer"
  log "Nightly backup timer installed ($(systemctl is-enabled librechat-backup.timer 2>/dev/null))"
}

install_backup_timer

log "Building and starting the stack (first build takes ~10-15 min)"
compose pull --ignore-buildable --quiet
compose up -d --build

log "Waiting for the API to become healthy"
for _ in $(seq 1 60); do
  if compose exec -T api curl -fsS http://127.0.0.1:3080/health >/dev/null 2>&1; then
    log "LibreChat is up"
    echo "    $(current_env DOMAIN_CLIENT)"
    echo "    Register the first account, then set ALLOW_REGISTRATION=false in $DEPLOY_DIR/.env"
    if [ -n "$PROXY_NETWORK" ]; then
      # Joining a second network can change which one provides the default
      # route. Losing egress here would look like "LibreChat runs but every
      # model call fails", so say it plainly instead.
      if ! compose exec -T api curl -fsS --max-time 15 -o /dev/null \
           https://cloudflare.com/cdn-cgi/trace 2>/dev/null; then
        printf '\n\033[1;31mWARNING: the api container has no outbound internet access.\033[0m\n'
        printf '  Attaching to %s appears to have taken over its default route.\n' "$PROXY_NETWORK"
        printf '  Model providers will be unreachable until this is fixed.\n'
      fi
      cat <<SNIPPET

  LibreChat is reachable from $PROXY_NETWORK but nothing routes to it yet.
  Add this to the proxy's Caddyfile and reload it:

      ${DOMAIN:-chat.example.com} {
          reverse_proxy LibreChat-API:3080 {
              flush_interval -1
          }
      }
SNIPPET
    fi
    exit 0
  fi
  sleep 5
done

die "API did not become healthy in time. Inspect: cd $DEPLOY_DIR && docker compose logs api"
