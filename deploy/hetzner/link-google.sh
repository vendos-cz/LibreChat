#!/usr/bin/env bash
#
# Let an account that predates Google sign-in use it.
#
#   APPLY=1 ./link-google.sh
#
# LibreChat refuses a social login when an account with the same email already
# exists under a different provider, and it has no account-linking flow — so
# the accounts registered before Google was configured are locked out of it.
#
# Setting `provider` to google is enough: the Google strategy matches an
# existing user by email once the provider agrees. The password is deliberately
# left in place, and localStrategy.js checks only that a password exists and
# matches — never the provider — so email sign-in keeps working and this cannot
# lock anyone out.
#
# Reports and changes nothing unless APPLY=1. Emails are masked, because this
# runs from a public repository's Actions logs.
set -euo pipefail

APPLY="${APPLY:-}"
EMAIL="${EMAIL:-}"
MONGO_CONTAINER="${MONGO_CONTAINER:-chat-mongodb}"
MONGO_DB="${MONGO_DB:-LibreChat}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (or via sudo)."

docker inspect "$MONGO_CONTAINER" >/dev/null 2>&1 \
  || die "No container named '$MONGO_CONTAINER' on this server."

if [ -n "$APPLY" ]; then
  log "Applying — the selected account will be switched to the google provider"
else
  log "Report only — pass APPLY=1 to write the change"
fi

# The whole decision runs inside mongosh so the account is selected and updated
# in one place, and so a mismatch cannot silently update the wrong document.
docker exec -i \
  -e TARGET_EMAIL="$EMAIL" \
  -e DO_APPLY="$APPLY" \
  "$MONGO_CONTAINER" mongosh --quiet "$MONGO_DB" --eval '
  const wanted = (process.env.TARGET_EMAIL || "").trim().toLowerCase();
  const apply = Boolean(process.env.DO_APPLY);

  const mask = (email) => {
    if (!email) return "(none)";
    const at = email.indexOf("@");
    if (at < 1) return "(malformed)";
    const name = email.slice(0, at);
    const head = name.slice(0, 1);
    const tail = name.length > 1 ? name.slice(-1) : "";
    return head + "***" + tail + email.slice(at);
  };

  const locals = db.users.find({ provider: "local" }).sort({ createdAt: 1 }).toArray();
  print("accounts on the local provider: " + locals.length);
  for (const user of locals) {
    print("  " + mask(user.email) +
          "  role=" + (user.role || "?") +
          "  password=" + Boolean(user.password) +
          "  created=" + (user.createdAt ? user.createdAt.toISOString().slice(0, 10) : "?"));
  }

  if (locals.length === 0) {
    print("nothing to do — no account is on the local provider");
    quit(0);
  }

  // Without an explicit email the oldest local account is the one that
  // predates Google, but only act unattended when it is unambiguous.
  let target;
  if (wanted) {
    target = locals.find((user) => (user.email || "").toLowerCase() === wanted);
    if (!target) {
      print("REFUSING: no local-provider account matches the requested email");
      quit(1);
    }
  } else if (locals.length === 1) {
    target = locals[0];
  } else {
    print("REFUSING: " + locals.length + " local accounts exist — name one with EMAIL=");
    quit(1);
  }

  print("target: " + mask(target.email));

  if (!target.password) {
    print("REFUSING: the target has no password, so switching provider would lock it out");
    quit(1);
  }

  if (!apply) {
    print("report only — nothing written");
    quit(0);
  }

  const result = db.users.updateOne(
    { _id: target._id, provider: "local" },
    { $set: { provider: "google" } },
  );
  print("matched=" + result.matchedCount + " modified=" + result.modifiedCount);

  const after = db.users.findOne({ _id: target._id });
  print("provider is now: " + after.provider);
  print("password still present: " + Boolean(after.password));
  if (after.provider !== "google" || !after.password) {
    print("REFUSING to report success: the document is not in the expected state");
    quit(1);
  }
'

log "Done — sign in with Google, or keep using the password; both work now"
