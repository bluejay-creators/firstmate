#!/usr/bin/env bash
# fm-ask-mai.sh - one-shot configured-model call for mechanical routing.
#
# Returns ONLY the model's answer text on stdout (no reasoning, no headers).
# Fails CLOSED: non-zero exit on transport/timeout/HTTP-error/empty/truncated
# answer so the caller escalates on its own thread rather than trusting a
# silent stub. The operator pins the model in config/mai-gateway.json;
# arguments and FM_MAI_MODEL cannot select another model.
#
# Usage:  fm-ask-mai.sh <prompt> [max_tokens]
# Config: $FM_CONFIG_OVERRIDE/mai-gateway.json (default $FM_HOME/config),
#         required object with nonempty url, token_command, and model strings.
# Env:    F2_GATEWAY_TOKEN_CMD   optional token-command override
#         F2_GATEWAY_URL         optional inference-host override
#         FM_MAI_TIMEOUT_SECS    request cap per attempt (default 180)
#         FM_MAI_RETRIES         attempts total (default 3)
#         FM_MAI_RETRY_DELAY_SECS  base backoff between attempts (default 5, doubles)
#
# Exit codes: 2 usage/config/no token, 3 transport or HTTP error after retry,
# 4 empty/null content, 5 finish_reason=length or content_filter.
set -euo pipefail

die() { printf 'fm-ask-mai: %s: %s\n' "$1" "$2" >&2; exit "$3"; }

[ "${1-}" = "--help" ] && { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0; }
[ "${FM_MAI_MODEL+x}" != x ] || die usage "FM_MAI_MODEL may not select a model; use the operator configuration" 2
[ $# -ge 1 ] && [ $# -le 2 ] || die usage "expected prompt and optional max_tokens; model is not selectable" 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
gateway=$(jq -ec '
  select(type == "object")
  | select(all(.url, .token_command, .model; type == "string" and test("\\S")))
' "$CONFIG/mai-gateway.json" 2>/dev/null) \
  || die config "mai-gateway.json requires url, token_command, and model" 2

prompt=$1
max=${2:-512}
model=$(printf '%s' "$gateway" | jq -r '.model')
cmd=${F2_GATEWAY_TOKEN_CMD:-$(printf '%s' "$gateway" | jq -r '.token_command')}
url=${F2_GATEWAY_URL:-$(printf '%s' "$gateway" | jq -r '.url')}
# shellcheck disable=SC2088 # Match the literal operator-written tilde prefix.
case "$cmd" in '~') cmd=$HOME ;; '~/'*) cmd="$HOME/${cmd#'~/'}" ;; esac
timeout=${FM_MAI_TIMEOUT_SECS:-180}
retries=${FM_MAI_RETRIES:-3}
delay=${FM_MAI_RETRY_DELAY_SECS:-5}

token=$("$cmd") || die auth "no token from $cmd" 2
body=$(jq -nc --arg m "$model" --arg p "$prompt" --argjson k "$max" \
  '{model:$m,messages:[{role:"user",content:$p}],max_tokens:$k,temperature:0,reasoning_effort:"low"}')

# Bounded retry handles transient gateway saturation without wedging a routing
# decision. Retries apply to transport and HTTP failures only - a structured
# empty or truncated answer is a definitive model verdict for that prompt,
# ending the call immediately.
attempt=1
while :; do
  raw=$(mktemp "${TMPDIR:-/tmp}/fm-ask-mai.XXXXXX")
  http_code=$(curl -sS --max-time "$timeout" -o "$raw" -w '%{http_code}' \
    -X POST "$url/chat/completions" \
    -H "Authorization: Bearer $token" -H "content-type: application/json" \
    -d "$body" 2>&1) || { curl_err=$http_code
      rm -f "$raw"
      http_code=000
      cause=${curl_err##*curl: }
      cause=${cause%%$'\n'*}
      if [ "$attempt" -lt "$retries" ]; then
        sleep "$delay"; delay=$((delay * 2)); attempt=$((attempt + 1)); continue
      fi
      die transport "$cause" 3
    }

  # HTTP error: surface the gateway's own cause fragment, never the body bytes.
  if [ "$http_code" != 200 ]; then
    cause=$(jq -r '.error.message? // .message? // empty' "$raw" 2>/dev/null || true)
    [ -n "$cause" ] || cause="status $http_code"
    rm -f "$raw"
    if [ "$attempt" -lt "$retries" ]; then
      sleep "$delay"; delay=$((delay * 2)); attempt=$((attempt + 1)); continue
    fi
    die transport "$cause" 3
  fi

  text=$(jq -r '.choices[0].message.content // empty' <"$raw")
  finish=$(jq -r '.choices[0].finish_reason // empty' <"$raw")
  rm -f "$raw"
  case "$finish" in
    length|content_filter) die "$finish" "answer truncated or filtered" 5 ;;
  esac
  [ -n "$text" ] || die empty "no content in answer (finish=${finish:-none})" 4
  printf '%s\n' "$text"
  exit 0
done
