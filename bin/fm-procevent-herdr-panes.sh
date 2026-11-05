#!/usr/bin/env bash
# Process-event adapter for the herdr pane/roster event source of a FIRSTMATE
# HOME (where the roster checks and the herdr session live), never a worktree.
#
#   fm-procevent-herdr-panes.sh arm
#   fm-procevent-herdr-panes.sh retire
#   fm-procevent-herdr-panes.sh status
#   fm-procevent-herdr-panes.sh drift
#   fm-procevent-herdr-panes.sh cmd_source-argv
#   fm-procevent-herdr-panes.sh relisten
#   fm-procevent-herdr-panes.sh silent <result-file>
#   fm-procevent-herdr-panes.sh classify <result-file>
#   fm-procevent-herdr-panes.sh read <result-file>
#
# One `arm` turns the home's 5-minute agent-roster poll into a second-scale
# roster event: it installs a LOCAL, hash-pinned copy of the listener pod at
# $STATE/herdr-pane-events.sh, records one drift check and trust sidecar the
# existing watcher already knows how to run, and registers source id
# herdr-pane-events under adapter herdr-panes with the generic process-event
# runner. The runtime contract the pod fulfills:
#
#   - one invocation is one EPISODE: the pod watches the herdr socket API
#     ($HERDR_SOCKET_PATH, protocol 22) until it has one notable change worth
#     waking this home for, prints a bounded herdr-panes-v1 report on stdout,
#     and exits; the runner captures that report durably and publishes an
#     ordinary `check` wake, then the `relisten` contract below starts the
#     next blocked episode in the same runner without stacking sockets;
#   - notable changes are (a) an agent pane the home's roster cannot account
#     for (secondmates, peers, state/*.meta workers, roster/adhoc.tsv), which
#     the home's own agent-roster check then auto-registers into adhoc.tsv
#     exactly like its 5-minute pass, and (b) an agent pane ENDING a blocked
#     episode it entered after the listener armed, with the pane's visible
#     screen saved exactly like the home's peer-blocked check saves it;
#   - blocked is detected by a per-pane server-side `agent.wait <pane> --until
#     blocked` (the wait reply IS the transition), because on herdr 0.9.3 the
#     pane.agent_status_changed subscription event is accepted but never
#     emitted; that is the protocol finding the pod README names precisely;
#   - the pod never starts, stops, or restarts the herdr server, and the
#     runner's own launch floor spaces reconnect retries after a socket loss.
#
# `silent` marks a socket-loss-only report handled without a firstmate wake:
# the runner has already relistened, so the loss is the repair. Every roster
# or blocked line wakes firstmate, whose handler reads the result with `read`,
# marks it handled with `fm-procevent.sh handled herdr-pane-events
# <sequence>`, and runs the report's named roster check for side effects.
#
# Arm prunes the LISTENER'S OWN private state (pod, sidecars, markers), never
# the runner's registered source, which `retire`/`sweep-home` own. NOTHING
# under the home's checked-out firstmate repo is touched after install except
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SOURCE_ID=${FM_HERDR_PANES_SOURCE_ID:-herdr-pane-events}
ADAPTER=herdr-panes
LISTENER=${FM_HERDR_EVENT_LISTENER:-$STATE/herdr-pane-events.sh}
TRUST="$STATE/herdr-pane-events.listener-trust"
DRIFT_CHECK="$STATE/herdr-pane-events.check.sh"
PROCEVENT="$SCRIPT_DIR/fm-procevent.sh"
CHECK_REGISTER="$SCRIPT_DIR/fm-check-register.sh"
CHECK_UNREGISTER="$SCRIPT_DIR/fm-check-unregister.sh"

die() { printf 'fm-procevent-herdr-panes: %s\n' "$1" >&2; exit 1; }

sha256() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

write_drift_check() {  # under $STATE, executable
  umask 077
  cat > "$DRIFT_CHECK" <<'DRIFT'
#!/usr/bin/env bash
# fm-check-interval: 300
# Custom watcher check: drift fail-safe for the herdr pane/roster EVENT source
# ($STATE/herdr-pane-events.sh, armed through
# bin/fm-procevent-herdr-panes.sh arm). The process-event runner pins the
# registered argv by file identity, so editing the listener pod leaves the
# running generation on the old bytes and the relisten adoption refuses the
# new ones: without this check, editing the pod silently reverts roster and
# blocked detection to the home's 5-minute poll. One wake line per drifted
# hash (marker $STATE/.herdr-event-drift). Liveness is owned by the runner's
# own reconcile/stranded wakes, not repeated here.
set -u
S=${FM_STATE_OVERRIDE:-__STATE__}
LISTENER="$S/herdr-pane-events.sh"
TRUST="$S/herdr-pane-events.listener-trust"
MARKER="$S/.herdr-event-drift"
[ -f "$LISTENER" ] && [ -f "$TRUST" ] || exit 0
live=$(shasum -a 256 "$LISTENER" | awk '{print $1}')
armed=$(awk 'NR==2{print; exit}' "$TRUST")
[ -n "$armed" ] || exit 0
if [ "$live" = "$armed" ]; then
  rm -f "$MARKER"
  exit 0
fi
prev=$(cat "$MARKER" 2>/dev/null || true)
[ "$prev" = "$live" ] && exit 0
printf '%s\n' "$live" > "$MARKER"
printf 'herdr-event-listener drifted: %s/herdr-pane-events.sh no longer matches the armed registration (%s/herdr-pane-events.listener-trust). Roster and blocked detection runs on stale bytes. Re-arm: bin/fm-procevent-herdr-panes.sh arm\n' "$S" "$S"
DRIFT
  sed -i '' "s|__STATE__|$STATE|g" "$DRIFT_CHECK"
  chmod 700 "$DRIFT_CHECK"
}

sync_trust() {
  umask 077
  { printf 'herdr-pane-events-listener-v1\n'; sha256 "$LISTENER"; } > "$TRUST.tmp" \
    && mv -f -- "$TRUST.tmp" "$TRUST"
}

cmd_arm() {
  [ -d "$STATE" ] || die "arm: unavailable home state: $STATE"
  [ -f "$LISTENER" ] || die "arm: listener pod is unavailable: $LISTENER"
  umask 077
  write_drift_check
  sync_trust
  "$PROCEVENT" register "$ADAPTER" "$SOURCE_ID" -- "$(cmd_source_argv)" >/dev/null
  "$PROCEVENT" ensure-listening "$SOURCE_ID" >/dev/null
  [ -x "$CHECK_REGISTER" ] && "$CHECK_REGISTER" herdr-pane-events >/dev/null 2>&1 || true
  printf 'armed: %s (herdr-panes) - roster/blocked events are second-scale; the 5-minute roster poll stays the fallback\n' "$SOURCE_ID"
  printf 'verify: bin/fm-procevent.sh list\n'
}

cmd_retire() {
  local msg
  msg=$("$PROCEVENT" retire "$SOURCE_ID" 2>&1) || die "$msg"
  rm -f -- "$TRUST"
  [ -x "$CHECK_UNREGISTER" ] && "$CHECK_UNREGISTER" herdr-pane-events >/dev/null 2>&1 || true
  rm -f -- "$STATE/.herdr-event-unknown.tsv" "$STATE/.herdr-pane-events.latest"
  rm -f -- "$STATE"/.herdr-blocked/* 2>/dev/null
  printf '%s; listener pod and its private state pruned\n' "$msg"
  printf 'note: %s (the listener pod) stays for a future arm; remove it by hand to fully uninstall\n' "$LISTENER"
}

cmd_status() {
  local rc=0
  printf 'registration: '
  if "$PROCEVENT" list 2>/dev/null | awk 'NR==1 || $1=="'"$SOURCE_ID"'"'; then
    :
  else
    printf 'unavailable (fm-procevent.sh list failed)\n'
    rc=1
  fi
  printf 'listener: %s\n' "$LISTENER"
  if [ -f "$LISTENER" ]; then printf '  present\n'; else printf '  MISSING - re-arm with %s arm\n' "$0"; rc=1; fi
  printf 'trust: %s\n' "$TRUST"
  if [ -f "$TRUST" ]; then
    printf '  armed-hash %s\n' "$(awk 'NR==2{print; exit}' "$TRUST")"
  else
    printf '  MISSING - drift check is silent and unarmed edits are invisible; re-arm\n'
    rc=1
  fi
  printf 'drift check: %s\n' "$DRIFT_CHECK"
  if [ -x "$DRIFT_CHECK" ]; then printf '  installed\n'; else printf '  not installed - re-arm\n'; rc=1; fi
  cmd_drift && printf 'drift: none\n' || true
  return "$rc"
}

cmd_drift() {  # exit 0 no drift (or nothing to compare); 1 list drifted state
  [ -f "$LISTENER" ] && [ -f "$TRUST" ] || return 0
  local live armed
  live=$(sha256 "$LISTENER")
  armed=$(awk 'NR==2{print; exit}' "$TRUST")
  if [ -n "$armed" ] && [ "$live" != "$armed" ]; then
    printf 'drift: %s (live %s, armed %s) - re-arm with %s arm\n' "$LISTENER" "$live" "$armed" "$0"
    return 1
  fi
  return 0
}

cmd_classify() {  # <result-file> -> blocked|unknown|mixed|socket-lost|unknown-event
  local f=${1:-}
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(sed -n '1p' "$f")" = herdr-panes-v1 ] || { printf 'unknown-event\n'; return 0; }
  local blocked unknown
  blocked=$(sed -n 's/^blocked=\([0-9][0-9]*\) .*/\1/p' "$f" | head -1)
  unknown=$(sed -n 's/^blocked=[0-9][0-9]* unknown=\([0-9][0-9]*\)$/\1/p' "$f" | head -1)
  case "$blocked" in ''|*[!0-9]*) blocked=0 ;; esac
  case "$unknown" in ''|*[!0-9]*) unknown=0 ;; esac
  if [ "$blocked" -gt 0 ] && [ "$unknown" -gt 0 ]; then
    printf 'mixed\n'
  elif [ "$blocked" -gt 0 ]; then
    printf 'blocked\n'
  elif [ "$unknown" -gt 0 ]; then
    printf 'unknown\n'
  elif grep -q '^socket=' "$f"; then
    printf 'socket-lost\n'
  else
    printf 'unknown-event\n'
  fi
  return 0
}

cmd_silent() {  # <result-file>; exit 0 silences the wake (and auto-handles)
  local f=${1:-}
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(sed -n '1p' "$f")" = herdr-panes-v1 ] || return 1
  local counts blocked unknown
  counts=$(sed -n 's/^blocked=\([0-9][0-9]*\) unknown=\([0-9][0-9]*\)$/\1 \2/p' "$f" | head -1)
  blocked=${counts%% *}
  unknown=${counts##* }
  case "$blocked" in ''|*[!0-9]*) blocked=1 ;; esac
  case "$unknown" in ''|*[!0-9]*) unknown=1 ;; esac
  [ "$blocked" -eq 0 ] && [ "$unknown" -eq 0 ] && grep -q '^socket=' "$f"
}

cmd_read() {  # <result-file>: bounded plain-language consumption
  local f=${1:-} _kind name pane cap agent cwd counts classification
  [ -f "$f" ] && [ ! -L "$f" ] || die "read: unavailable result file"
  [ "$(sed -n '1p' "$f")" = herdr-panes-v1 ] || die "read: not a herdr-panes-v1 result"
  classification=$(cmd_classify "$f") || classification=unknown-event
  counts=$(sed -n 's/^blocked=\([0-9][0-9]* unknown=[0-9][0-9]*\)$/\1/p' "$f" | head -1)
  printf 'report: herdr-panes (%s; %s)\n' "$classification" "$counts"
  sed -n 's/^socket=/socket-note: /p' "$f"
  while IFS=$'\t' read -r _kind name pane cap; do
    [ "$_kind" = blocked ] || continue
    printf 'blocked: %s (%s)%s\n' "$name" "$pane" \
      "$( [ "$cap" != '-' ] && [ -n "$cap" ] && printf ' - screen saved state/.blocked-captures/%s' "$cap" )"
  done < "$f"
  while IFS=$'\t' read -r _kind name pane agent cwd; do
    [ "$_kind" = unknown ] || continue
    printf 'unknown agent pane: %s (%s; agent %s; cwd %s)\n' "$name" "$pane" "$agent" "$cwd"
  done < "$f"
  sed -n 's|^roster-check\t|side effects: run |p' "$f" | head -1
}

cmd_source_argv() {
  [ -f "$LISTENER" ] && [ ! -L "$LISTENER" ] || die "listener pod is unavailable: $LISTENER"
  printf '%s\n' "$LISTENER"
}

case "${1:-}" in
  arm)  shift; cmd_arm "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  status) shift; cmd_status "$@" ;;
  drift) shift; cmd_drift "$@" ;;
  cmd_source-argv) shift; cmd_source_argv "$@" ;;
  relisten)
    # One runner stays subscribed; each episode end starts one more blocked
    # window immediately. Exit 0 is the whole contract.
    [ -f "$LISTENER" ] && [ ! -L "$LISTENER" ]
    ;;
  silent)  shift; cmd_silent "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  read) shift; cmd_read "$@" ;;
  *)
    cat >&2 <<EOF
usage: fm-procevent-herdr-panes.sh <command>
  arm        install the listener under \$STATE, sidecars, and drift check,
             register source $SOURCE_ID under adapter $ADAPTER, and
             ensure-listening. Roster/blocked events become second-scale.
  retire     retire the runner registration (its liveness stops) and prune
             the pod's private state; the pod itself stays for a future arm.
  status     registration, listener, sidecar, drift check, and drift verdict.
  drift      exit 0 when the listener's live bytes match the armed arm hash.
  cmd_source-argv   print the listener argv fm-procevent registers and runs
  relisten          exit 0 while this adapter wants the same runner to begin
                    another blocked episode right after this one
  silent <result>   exit 0 when the captured report needs no firstmate wake
                    (a pure socket-loss report, already repaired by relisten)
  classify <result> blocked | unknown | mixed | socket-lost | unknown-event
  read <result>     bounded plain-language contents of a captured report
arm:  bin/fm-procevent-herdr-panes.sh arm
stop: bin/fm-procevent-herdr-panes.sh retire
EOF
    exit 2
    ;;
esac
