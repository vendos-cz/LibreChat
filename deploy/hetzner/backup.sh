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
# Off-site copy: set BACKUP_SSH_TARGET to an scp destination and the archive is
# shipped there as well. Unset means local only - which protects against a bad
# migration, a dropped collection, or a wrong restore, but not against losing
# this server. Set BACKUP_PASSPHRASE too and only an encrypted copy leaves the
# machine, because the archive contains .env in the clear.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/librechat}"
KEEP="${KEEP:-14}"
MONGO_CONTAINER="${MONGO_CONTAINER:-chat-mongodb}"
MONGO_DB="${MONGO_DB:-LibreChat}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-librechat}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/librechat/deploy/hetzner}"
BACKUP_SSH_TARGET="${BACKUP_SSH_TARGET:-}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"

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

require_member env 200
require_member mongo.archive.gz 1024

grep -q '^CREDS_KEY=.' "$stage/env" \
  || die "the copied .env has no CREDS_KEY — a restore could not decrypt stored keys"

log "Archive verified: $(du -h "$archive" | cut -f1)"
printf '%s\n' "$listing" | awk '{ printf "    %-24s %10s\n", $NF, $3 }'

if [ -n "$BACKUP_SSH_TARGET" ]; then
  outgoing="$archive"
  if [ -n "$BACKUP_PASSPHRASE" ]; then
    log "Encrypting the off-site copy"
    outgoing="$stage/librechat-$stamp.tar.gz.enc"
    printf '%s' "$BACKUP_PASSPHRASE" | openssl enc -aes-256-cbc -pbkdf2 -salt \
      -pass stdin -in "$archive" -out "$outgoing"
  else
    log "BACKUP_PASSPHRASE unset — shipping the archive unencrypted, .env included"
  fi
  log "Copying to $BACKUP_SSH_TARGET"
  scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$outgoing" "$BACKUP_SSH_TARGET" \
    || die "the off-site copy failed — the local archive is kept at $archive"
else
  log "BACKUP_SSH_TARGET unset — local copy only, this server is a single point of failure"
fi

# Rotate last, so a failure above never costs an older backup.
log "Keeping the newest $KEEP archives"
# `ls` on a glob that matches nothing exits non-zero, and pipefail would then
# fail the whole run right after a good backup.
{ ls -1t "$BACKUP_DIR"/librechat-*.tar.gz 2>/dev/null || true; } | tail -n "+$((KEEP + 1))" \
  | while read -r stale; do
      printf '    removing %s\n' "$stale"
      rm -f "$stale"
    done

log "Done — $archive"
