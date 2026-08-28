#!/usr/bin/env bash
#
# Back up everything that cannot be rebuilt from the repository.
#
#   ./backup.sh
#
# Four things matter, and only one of them is the database:
#
#   .env            CREDS_KEY and CREDS_IV. Every user-provided API key in
#                   Mongo is encrypted with them, so without this file those
#                   rows are permanently unreadable - restoring Mongo alone
#                   gets you a database of ciphertext. It also holds the JWT
#                   secrets and every provider key.
#   mongo           conversations, users, agents, memories, shared links.
#   uploads         files people attached, and the source documents the RAG
#                   index was built from.
#   images          generated images. Referenced from messages, so losing them
#                   leaves dead thumbnails in old conversations.
#
# Deliberately not backed up, because both are indexes derived from the above
# and are cheaper to rebuild than to store: meili-data (rebuilt by
# `npm run reset-meili-sync`) and pgdata (the vector store, rebuilt by
# re-uploading to the RAG API).
#
# Off-site copy, one of two backends, GitHub taking precedence when both are set:
#
#   BACKUP_GITHUB_REPO   owner/repo. Each archive becomes a release asset, not a
#                        commit - assets live outside the object store, so they
#                        can be deleted and the repository does not grow. Needs
#                        BACKUP_GITHUB_TOKEN with contents write on that repo.
#   BACKUP_SSH_TARGET    an scp destination, e.g. a Hetzner Storage Box.
#
# Neither set means local only, which protects against a bad migration, a
# dropped collection or a wrong restore, but not against losing this server.
#
# BACKUP_PASSPHRASE encrypts .env *inside* the archive rather than the archive
# itself, so the config and the dumps stay readable at the destination while the
# credentials do not travel in the clear.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/librechat}"
KEEP="${KEEP:-14}"
MONGO_CONTAINER="${MONGO_CONTAINER:-chat-mongodb}"
MONGO_DB="${MONGO_DB:-LibreChat}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-librechat}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/librechat/deploy/hetzner}"
BACKUP_SSH_TARGET="${BACKUP_SSH_TARGET:-}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
BACKUP_SSH_PORT="${BACKUP_SSH_PORT:-}"
BACKUP_SSH_KEY="${BACKUP_SSH_KEY:-}"
BACKUP_GITHUB_REPO="${BACKUP_GITHUB_REPO:-}"
BACKUP_GITHUB_TOKEN="${BACKUP_GITHUB_TOKEN:-}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (or via sudo)."
[ -d "$DEPLOY_DIR" ] || die "No deployment at $DEPLOY_DIR."
[ -f "$DEPLOY_DIR/.env" ] || die "$DEPLOY_DIR/.env is missing — nothing would be restorable."

docker inspect "$MONGO_CONTAINER" >/dev/null 2>&1 \
  || die "No container named '$MONGO_CONTAINER' on this server."

# mongodump is the only correct way to copy a running MongoDB: tarring its data
# directory under load yields an archive that may not replay. Fail rather than
# silently produce one of those.
docker exec "$MONGO_CONTAINER" sh -c 'command -v mongodump' >/dev/null 2>&1 || die \
  "mongodump is not in the $MONGO_CONTAINER image, so a consistent dump cannot be
  taken. Install it there (mongodb-database-tools) rather than falling back to
  tarring the volume, which produces an archive that may not restore."

stamp="$(date -u +%Y%m%d-%H%M%S)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
archive="$BACKUP_DIR/librechat-$stamp.tar.gz"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

log "Dumping MongoDB ($MONGO_DB)"
docker exec "$MONGO_CONTAINER" mongodump \
  --db "$MONGO_DB" --archive --gzip > "$stage/mongo.archive.gz"

log "Copying .env and librechat.yaml"
cp "$DEPLOY_DIR/.env" "$stage/env"
[ -f "$DEPLOY_DIR/librechat.yaml" ] && cp "$DEPLOY_DIR/librechat.yaml" "$stage/librechat.yaml"

# Checked here, on the plaintext, because the file may be encrypted next.
grep -q '^CREDS_KEY=.' "$stage/env" \
  || die ".env has no CREDS_KEY — a restore from this archive could not decrypt stored keys"

# Only .env is encrypted, not the whole archive: it is the one member that must
# not be readable wherever the archive ends up, and leaving the rest in the
# clear is what lets a destination — or a person, or Claude — open the config
# and the dumps without the passphrase. Everything else in here is recoverable
# data; .env is credentials.
env_member="env"
if [ -n "$BACKUP_PASSPHRASE" ]; then
  log "Encrypting .env inside the archive"
  printf '%s' "$BACKUP_PASSPHRASE" | openssl enc -aes-256-cbc -pbkdf2 -salt \
    -pass stdin -in "$stage/env" -out "$stage/env.enc"
  rm -f "$stage/env"
  env_member=env.enc
else
  log "BACKUP_PASSPHRASE unset — .env goes into the archive in the clear"
fi

# Volumes are read through a throwaway container, so this works whether or not
# the app is running and needs no knowledge of where docker keeps them.
copy_volume() {
  volume="${COMPOSE_PROJECT}_$1"
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    log "Volume $volume does not exist — skipping"
    return 0
  fi
  log "Archiving volume $volume"
  docker run --rm -v "$volume:/data:ro" -v "$stage:/out" alpine \
    tar czf "/out/$1.tar.gz" -C /data .
}

copy_volume librechat-uploads
copy_volume librechat-images

log "Packing $archive"
tar czf "$archive" -C "$stage" .
chmod 600 "$archive"

# A backup nobody opened is a guess. Read the archive back and require the two
# members that make a restore possible at all to be present and non-trivial.
log "Verifying the archive"
listing="$(tar tzvf "$archive")" || die "the archive is not readable"

require_member() {
  size="$(printf '%s\n' "$listing" | awk -v want="./$1" '$NF == want { print $3; found = 1 }
    END { if (!found) print "missing" }')"
  case "$size" in
    missing) die "$1 is not in the archive" ;;
    '') die "could not read the size of $1 in the archive" ;;
  esac
  [ "$size" -ge "$2" ] || die "$1 is only $size bytes — expected at least $2"
}

require_member "$env_member" 200
require_member mongo.archive.gz 1024

log "Archive verified: $(du -h "$archive" | cut -f1)"
printf '%s\n' "$listing" | awk '{ printf "    %-24s %10s\n", $NF, $3 }'

gh_api() {
  method="$1"
  url="$2"
  shift 2
  curl -sS -X "$method" \
    -H "Authorization: Bearer $BACKUP_GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$@" "$url"
}

# Releases rather than commits, deliberately. A committed archive is permanent:
# git keeps every version forever and no rotation can reclaim it. Release assets
# live outside the object store, so they can be deleted and the repository does
# not grow.
upload_to_github() {
  log "Creating release backup-$stamp in $BACKUP_GITHUB_REPO"
  release="$(gh_api POST "https://api.github.com/repos/$BACKUP_GITHUB_REPO/releases" \
    -H 'Content-Type: application/json' \
    -d "{\"tag_name\":\"backup-$stamp\",\"name\":\"Backup $stamp\",\"body\":\"Automated LibreChat backup. .env inside the archive is encrypted when a passphrase is configured.\"}")"

  release_id="$(printf '%s' "$release" | jq -r '.id // empty')"
  if [ -z "$release_id" ]; then
    printf '  %s\n' "$(printf '%s' "$release" | jq -r '.message // "no message"' | cut -c1-200)"
    return 1
  fi

  log "Uploading the archive"
  asset="$(curl -sS -X POST \
    -H "Authorization: Bearer $BACKUP_GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'Content-Type: application/gzip' \
    --data-binary "@$archive" \
    "https://uploads.github.com/repos/$BACKUP_GITHUB_REPO/releases/$release_id/assets?name=librechat-$stamp.tar.gz")"

  # GitHub reports the stored size and state, so unlike scp this can be checked
  # rather than inferred: a truncated upload is a size mismatch, not a guess.
  state="$(printf '%s' "$asset" | jq -r '.state // empty')"
  stored="$(printf '%s' "$asset" | jq -r '.size // empty')"
  expected="$(stat -c %s "$archive")"

  if [ "$state" != "uploaded" ]; then
    printf '  upload state is "%s", not "uploaded": %s\n' "$state" \
      "$(printf '%s' "$asset" | jq -r '.message // ""' | cut -c1-200)"
    return 1
  fi
  if [ "$stored" != "$expected" ]; then
    printf '  stored %s bytes but the archive is %s — the upload was truncated\n' \
      "$stored" "$expected"
    return 1
  fi
  log "Uploaded and verified: $stored bytes"

  # Rotate the remote side too, deleting the tag as well as the release: a
  # release leaves its tag behind, and tags are refs that would accumulate in
  # the repository this scheme is meant to keep small.
  log "Keeping the newest $KEEP releases"
  gh_api GET "https://api.github.com/repos/$BACKUP_GITHUB_REPO/releases?per_page=100" \
    | jq -r '[.[] | select(.tag_name | startswith("backup-"))]
             | sort_by(.tag_name) | reverse | .['"$KEEP"':][] | "\(.id) \(.tag_name)"' \
    | while read -r stale_id stale_tag; do
        printf '    removing %s\n' "$stale_tag"
        gh_api DELETE "https://api.github.com/repos/$BACKUP_GITHUB_REPO/releases/$stale_id" >/dev/null
        gh_api DELETE "https://api.github.com/repos/$BACKUP_GITHUB_REPO/git/refs/tags/$stale_tag" >/dev/null
      done
}

upload_failed=
if [ -n "$BACKUP_GITHUB_REPO" ]; then
  if [ -z "$BACKUP_GITHUB_TOKEN" ]; then
    upload_failed=1
    printf '\n\033[1;31mWARNING: BACKUP_GITHUB_REPO is set but BACKUP_GITHUB_TOKEN is not.\033[0m\n'
  elif ! upload_to_github; then
    upload_failed=1
    printf '\n\033[1;31mWARNING: the GitHub upload failed. The local archive is kept at %s\033[0m\n' "$archive"
  fi
elif [ -n "$BACKUP_SSH_TARGET" ]; then
  # Managed storage often listens on a non-default port and offers a shell too
  # limited to read the landed file back, so the port is configurable and scp's
  # own exit status is the check that the transfer completed.
  scp_opts="-o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  [ -z "$BACKUP_SSH_PORT" ] || scp_opts="$scp_opts -P $BACKUP_SSH_PORT"
  [ -z "$BACKUP_SSH_KEY" ] || scp_opts="$scp_opts -i $BACKUP_SSH_KEY"

  log "Copying to $BACKUP_SSH_TARGET"
  # shellcheck disable=SC2086 # scp_opts is a deliberate list of separate words
  if ! scp $scp_opts "$archive" "$BACKUP_SSH_TARGET"; then
    upload_failed=1
    printf '\n\033[1;31mWARNING: the off-site copy failed. The local archive is kept at %s\033[0m\n' "$archive"
  fi
else
  log "No off-site destination set — local copy only, this server is a single point of failure"
fi

# Rotate even when the upload failed. Exiting here instead would stop rotation
# running for as long as the off-site destination stays broken, and the archives
# would then grow until they filled the disk and took the app down with them —
# a backup that causes the outage is worse than no backup.
log "Keeping the newest $KEEP archives"
# `ls` on a glob that matches nothing exits non-zero, and pipefail would then
# fail the whole run right after a good backup.
{ ls -1t "$BACKUP_DIR"/librechat-*.tar.gz 2>/dev/null || true; } | tail -n "+$((KEEP + 1))" \
  | while read -r stale; do
      printf '    removing %s\n' "$stale"
      rm -f "$stale"
    done

[ -z "$upload_failed" ] || die "the local backup succeeded but the off-site copy did not"

log "Done — $archive"
