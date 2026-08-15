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
apt-get install -y -qq ca-certificates curl git gnupg ufw ipset iproute2

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

cd "$DEPLOY_DIR"

if [ ! -f librechat.yaml ]; then
  log "Seeding librechat.yaml from librechat.example.yaml"
  cp "$APP_DIR/librechat.example.yaml" librechat.yaml
fi

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

set_env BUILD_COMMIT "$(git -C "$APP_DIR" rev-parse --short HEAD)"
set_env BUILD_BRANCH "$BRANCH"
set_env BUILD_DATE "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
chmod 600 .env

port_listener() {
  ss -ltnpH "( sport = :$1 )" 2>/dev/null | tr -s ' '
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
  behind that proxy, or deploy on a separate server (see cloud-init.yaml)."
  done
fi

if [ -n "$PROXY_NETWORK" ]; then
  docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 \
    || die "PROXY_NETWORK '$PROXY_NETWORK' is not an existing docker network."
  log "Running behind an external proxy on network $PROXY_NETWORK (no own Caddy)"
fi

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
