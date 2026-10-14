#!/usr/bin/env bash
# fm-ask-mai-coalesce.sh - pre-delivery wake triage and compaction classifier
# for an extension's "deliver pending actionables" fan-out.
#
# Reads the latest N rows (epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload) from a
# durable wake queue and classifies each as one of:
# - routine deterministically:
#   - `heartbeat` kind (regular idle cadence wake);
#   - `signal:` whose newest unmatched trailing status line (since the last
#     delivered wake for that task) is a bare `working: ...` progress note or
#     a bare `paused: ...` declared wait - strictly that known-safe routine
#     shape, never a decision/credential/stuck/blocked/done class.
# - routine by MAI verdict (`absorb`):
#   - only `signal:` kinds (MAI never gates stale/check/watcher/procevent/unknown rows);
#   - only the exact in-set answer; any error, timeout, missing binary, or
#     out-of-set/uncertain answer leaves the row deliverable (existing
#     fail-open contract in bin/fm-ask-mai-wake.sh);
#   - gated by <home>/config/mai-routing, and by FM_MAI_TRIAGE_TIMEOUT_SECS
#     (default 20, valid 1..120) as a latency bound, matching fleet convention.
# - deliver: anything else.
#
# The signal: gate deliberately reads only the trailing (since-last-wake)
# span, so a bare "working: pull request published" is absorbed while a
# decision+resolved pair older than that span still shows "resolved" as the
# newest action - exactly the shape fm-classify-lib.sh already classifies.
# Any absorbed row also tentatively advances that task's quiet cursor
# (state/.fm-quietsince-<task>) to its current size, so a second wake never
# re-reads the same absorbed span.
#
# Emits one JSON object to stdout {"deliver":[{kind,key,payload}],
# "absorbed":[{kind,key,summary}]}; the caller decides fan-out/ack. Never
# echoes parse-by-regex lines, never waits on the caller, and never touches
# outside state except the bounded triage log (state/triage.log) and the
# quiet cursor files state/.fm-quietsince-*.
#
# Usage: fm-ask-mai-coalesce.sh <home> <queue-file> <count>
#   <home>       firstmate home whose config/mai-routing gates MAI routing
#   <queue-file> durable wake queue, newest row last
#   <count>      trailing rows to classify (positive integer)
# Env: FM_MAI_TRIAGE_TIMEOUT_SECS bounds a single MAI routing call
# (default 20, valid 1..120) and is handed to bin/fm-ask-mai-wake.sh as its
# per-call timeout so the routing can never stall a wake delivery.
# Wake-entry shape: bin/fm-wake-lib.sh. Status-verb semantics:
# bin/fm-classify-lib.sh. Triage-log naming convention: bin/fm-watch.sh's
# triage_log.
set -euo pipefail

home=${1:?"usage: fm-ask-mai-coalesce.sh <home> <queue-file> <count>"}
queue=${2:?"usage: fm-ask-mai-coalesce.sh <home> <queue-file> <count>"}
count=${3:?"usage: fm-ask-mai-coalesce.sh <home> <queue-file> <count>"}
case "$count" in ''|*[!0-9]*) printf 'fm-ask-mai-coalesce: count must be a positive integer\n' >&2; exit 2 ;; esac
[ "$count" -ge 1 ] || { printf 'fm-ask-mai-coalesce: count must be >= 1\n' >&2; exit 2; }
[ -r "$queue" ] || { printf 'fm-ask-mai-coalesce: wake queue unreadable: %s\n' "$queue" >&2; exit 2; }

command -v jq >/dev/null || { printf 'fm-ask-mai-coalesce: jq is required\n' >&2; exit 2; }

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

# shellcheck disable=SC2034 # FM_STATE_OVERRIDE/FM_ROOT_OVERRIDE/FM_HOME resolve this in fm-wake-lib.sh.
FM_MAI_TRIAGE_TIMEOUT_SECS=${FM_MAI_TRIAGE_TIMEOUT_SECS:-20}
case "$FM_MAI_TRIAGE_TIMEOUT_SECS" in ''|*[!0-9]*) FM_MAI_TRIAGE_TIMEOUT_SECS=20 ;; esac
[ "$FM_MAI_TRIAGE_TIMEOUT_SECS" -ge 1 ] 2>/dev/null || FM_MAI_TRIAGE_TIMEOUT_SECS=20
[ "$FM_MAI_TRIAGE_TIMEOUT_SECS" -le 120 ] 2>/dev/null || FM_MAI_TRIAGE_TIMEOUT_SECS=20

triage_note() {
  [ -n "${FM_STATE_OVERRIDE:-}" ] || [ -n "${STATE:-}" ] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "${FM_STATE_OVERRIDE:-${STATE}}/triage.log" 2>/dev/null || true
}

quiet_cursor_file() { # <task>
  printf '%s' "${FM_STATE_OVERRIDE:-${STATE}}/.fm-quietsince-$1"
}

# <byte-offset> under which actable_status_verb must start reading; 0 means the
# whole log is still in scope.
quiet_cursor_read() { # <task>
  local f
  f=$(quiet_cursor_file "$1")
  local out=0
  if [ -r "$f" ]; then
    out=$(cat -- "$f" 2>/dev/null)
    case "$out" in ''|*[!0-9]*) out=0 ;; esac
  fi
  printf '%s' "$out"
}

quiet_cursor_write() { # <task> <byte-offset>
  local f
  f=$(quiet_cursor_file "$1")
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$2" > "$f" 2>/dev/null || true
}

# Trim to one line, max 100 characters (coaligned with fm-quiet-omp-wake.sh's
# banner budget), trailing whitespace removed.
summary_of() {
  local s=$1
  s=${s%%$'\n'*}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "${s:0:100}"
}

# Print the newest meaningful trailing verb from the tail of <status-file>
# starting at byte offset <from> (0 = whole file). Only trailing context is
# relevant: the watcher-classified signal already got us to this wake, so the
# later lines are the thing a second-layer triage can absorb as routine.
# Verb vocabulary per fm-classify-lib.sh's verb-aware classification.
actable_status_verb() { # <status-file> <from-byte-offset>
  local file=$1 from=$2 size span line last_token verb_now=
  case "$from" in ''|*[!0-9]*) from=0 ;; esac
  size=$(fm_status_span_size "$file" 2>/dev/null)
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$from" -ge "$size" ] 2>/dev/null; then
    span=$(cat -- "$file" 2>/dev/null) || return 0
  else
    # tail -c +N is byte offset N-1, so (from+1) starts reading exactly at "from".
    span=$(tail -c +$((from + 1)) -- "$file" 2>/dev/null) || return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|[[:space:]]*) continue ;; esac
    last_token=${line%%[[:space:]:]*}
    case "$last_token" in
      working|paused|done|blocked|failed|needs-decision|awaiting-decision|needs-credential|resolved|note|watcher)
        verb_now=$last_token ;;
    esac
  done <<EOF
$span
EOF
  printf '%s' "$verb_now"
}

entries=$(tail -n "$count" -- "$queue" 2>/dev/null || true)
[ -n "$entries" ] || { printf '{"deliver":[],"absorbed":[]}\n'; exit 0; }

deliver_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-ask-mai-coalesce.deliver.XXXXXX") || exit 1
absorbed_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-ask-mai-coalesce.absorbed.XXXXXX") || exit 1
cleanup() { rm -f -- "$deliver_tmp" "$absorbed_tmp"; }
trap cleanup EXIT

mai_routing=off
[ -e "$home/config/mai-routing" ] && mai_routing=on

LC_ALL=C
absorbed_count=0
while IFS=$'\t' read -r _epoch _seq kind key payload; do
  # Skip structurally-odd rows (the drain already retires malformed ones; this
  # helper is a filter, not a validator). Empty payloads are fine: a heartbeat
  # arrives with one.
  [ -n "$kind" ] || continue
  cause=$payload
  task=$key
  status_file=
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    status_file=$FM_STATE_OVERRIDE/$task
  else
    status_file=${STATE:-${home}/state}/$task
  fi

  decision=deliver
  case "$kind" in
    heartbeat)
      decision=absorb
      ;;
    signal)
      case "$cause" in
        signal:*)
          if [ -f "$status_file" ]; then
            from=$(quiet_cursor_read "$task")
            verb=$(actable_status_verb "$status_file" "$from")
            case "$verb" in
              working|paused)
                decision=absorb
                ;;
            esac
          fi
          ;;
      esac
      if [ "$decision" = deliver ] && [ "$mai_routing" = on ] && [ -n "${F2_GATEWAY_TOKEN_CMD:-}" ]; then
        # MAI classifies the reason string only; anything but a clean token
        # 'absorb' keeps the row deliverable (existing fail-open contract).
        answer=$("$SCRIPT_DIR/fm-ask-mai-wake.sh" "$home" "$cause" 2>/dev/null || true)
        answer=$(printf '%s' "$answer" | tr -d '[:space:]')
        if [ -z "$answer" ]; then
          triage_note "MAI coalesce: no verdict for signal $task (fail-open to delivery)"
        elif [ "$answer" = absorb ]; then
          decision=absorb
        fi
      fi
      ;;
    *) : ;; # never gate stale/check/watcher/procevent/coalesce-failure rows here.
  esac

  if [ "$decision" = absorb ]; then
    if [ "$kind" = signal ] && [ -f "$status_file" ]; then
      size=$(LC_ALL=C wc -c < "$status_file" 2>/dev/null | tr -d '[:space:]' || true)
      case "$size" in ''|*[!0-9]*) ;; *) quiet_cursor_write "$task" "$size" ;; esac
    fi
    absorbed_count=$((absorbed_count + 1))
    jq -nc --arg k "$kind" --arg key "$task" --arg s "$(summary_of "$cause")" \
      '{kind:$k,key:$key,summary:$s}' >> "$absorbed_tmp"
  else
    jq -nc --arg k "$kind" --arg key "$task" --arg p "$cause" \
      '{kind:$k,key:$key,payload:$p}' >> "$deliver_tmp"
  fi
done <<EOF
$entries
EOF

[ "$absorbed_count" -eq 0 ] || \
  triage_note "quiet-wake coalesce: absorbed $absorbed_count routine wake(s) (see state/.fm-quietsince-* cursors)"

jq -nc \
  --slurpfile deliver "$deliver_tmp" \
  --slurpfile absorbed "$absorbed_tmp" \
  '{deliver:($deliver // []), absorbed:($absorbed // [])}'
