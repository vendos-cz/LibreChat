#!/usr/bin/env bash
#
# Find out which parameter combination an OpenAI model actually rejects.
#
#   MODEL=gpt-5.6 ./probe-openai.sh
#
# Agent calls to gpt-5.6 fail with a 400 that names the model rather than the
# cause. The obvious explanation was ruled out: OPENAI_REVERSE_PROXY is unset,
# so LibreChat sees a canonical base URL and should be moving reasoning
# requests to /v1/responses by itself.
#
# The remaining evidence is in the api container's log, but that log can contain
# what people typed, and this repository is public — so nothing from it is
# printed here. Instead this sends three synthetic requests of its own and
# compares them. Every field is a constant in this file; no conversation, no
# user, no stored prompt is involved.
#
#   1. chat/completions + tools + reasoning_effort
#   2. chat/completions + tools, without reasoning_effort
#   3. responses + tools + reasoning_effort
#
# Whichever of those fails tells you which one LibreChat must stop sending.
# Only the HTTP status and the provider's own error message are printed, capped,
# and the key is never echoed.
set -euo pipefail

MODEL="${MODEL:-gpt-5.6}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/librechat/deploy/hetzner}"
EFFORT="${EFFORT:-medium}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$DEPLOY_DIR/.env" ] || die "No .env at $DEPLOY_DIR."

key="$(sed -nE 's/^OPENAI_API_KEY=(.*)$/\1/p' "$DEPLOY_DIR/.env" | tail -n1)"
[ -n "$key" ] || die "OPENAI_API_KEY is empty in .env."
case "$key" in
  user_provided) die "OPENAI_API_KEY is user_provided, so there is no server-side key to probe with." ;;
esac

base="$(sed -nE 's/^OPENAI_REVERSE_PROXY=(.*)$/\1/p' "$DEPLOY_DIR/.env" | tail -n1)"
[ -n "$base" ] || base="https://api.openai.com/v1"
log "Base URL: $base"
log "Model: $MODEL"

tools='[{"type":"function","function":{"name":"get_time","description":"Get the current time","parameters":{"type":"object","properties":{},"required":[]}}}]'
messages='[{"role":"user","content":"Say OK."}]'

# The provider's message is the only thing worth printing, and it is printed
# through jq so a malformed body cannot dump the whole response into the log.
report() {
  label="$1"
  code="$2"
  body="$3"
  printf '\n  %-46s HTTP %s\n' "$label" "$code"
  if [ "$code" = "200" ]; then
    printf '    accepted\n'
    return 0
  fi
  message="$(jq -r '.error.message // "no error.message in the response"' < "$body" 2>/dev/null \
             || echo "response was not JSON")"
  printf '    %s\n' "$(printf '%s' "$message" | tr -d '\n' | cut -c1-400)"
  param="$(jq -r '.error.param // empty' < "$body" 2>/dev/null || true)"
  [ -z "$param" ] || printf '    param: %s\n' "$param"
}

probe() {
  label="$1"
  path="$2"
  payload="$3"
  body="$(mktemp)"
  code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 60 \
            -X POST "$base$path" \
            -H "Authorization: Bearer $key" \
            -H 'Content-Type: application/json' \
            -d "$payload" || echo 000)"
  report "$label" "$code" "$body"
  rm -f "$body"
}

log "Probing"

probe "chat/completions + tools + reasoning_effort" /chat/completions \
  "{\"model\":\"$MODEL\",\"messages\":$messages,\"tools\":$tools,\"reasoning_effort\":\"$EFFORT\",\"max_completion_tokens\":16}"

probe "chat/completions + tools, no reasoning_effort" /chat/completions \
  "{\"model\":\"$MODEL\",\"messages\":$messages,\"tools\":$tools,\"max_completion_tokens\":16}"

probe "chat/completions, no tools, reasoning_effort" /chat/completions \
  "{\"model\":\"$MODEL\",\"messages\":$messages,\"reasoning_effort\":\"$EFFORT\",\"max_completion_tokens\":16}"

# The Responses API takes reasoning as an object, not a flat string, so this is
# the shape LibreChat sends when useResponsesApi is on.
probe "responses + tools + reasoning" /responses \
  "{\"model\":\"$MODEL\",\"input\":\"Say OK.\",\"tools\":[{\"type\":\"function\",\"name\":\"get_time\",\"description\":\"Get the current time\",\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}],\"reasoning\":{\"effort\":\"$EFFORT\"},\"max_output_tokens\":16}"

printf '\n'
log "Done — the failing row is the combination LibreChat must stop sending"
