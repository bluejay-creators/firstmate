#!/usr/bin/env bash
# External watcher watchdog for an explicitly selected omp-on-Herdr primary.
# Usage: FM_HOME=/absolute/home bash bin/fm-watchdog.sh check|plist
#
# `plist` prints a per-home LaunchAgent (RunAtLoad, StartInterval=60); it never
# installs or loads it. Render from the stable code root after merge. It pins
# FM_HOME, HOME, PATH and HERDR_SESSION (default: default) from the operator.
# `check` reads the SAME state/.last-watcher-beat mtime as fm-turnend-guard.sh.
# Age <=120 seconds is quiet. Missing or older beats open a persistent episode
# in state/.watchdog-episode, with ONE supported agent prompt attempt. Only a
# native omp agent whose foreground cwd matches FM_HOME may receive the fixed
# request through `herdr agent prompt`, using state/.firstmate-pane. We never
# run fm-watch-arm.sh, touch the beacon, stop processes, or change owner state.
# A submitted prompt is not proof of recovery: only a fresh heartbeat clears
# the episode. A newly observed beat starts a new observation if already stale.
# After 300 seconds of continued staleness since detection, reserve ONE
# content-free `fm-notify-phone --batch-id <sha256> watcher-down` attempt.
# Reservations precede I/O, including failures, so crashes/restarts cannot
# spam the pane or phone. The bridge also owns its global rate/dedup limits.
#
# Episode format (private atomic TSV): version=1, detected epoch, beat mtime
# (0=missing), phone-attempted (0|1). The home-scoped watchdog lock serializes
# manual and launchd checks; it is independent of watcher/extension ownership.
# stdout contains transition diagnostics only; launchd appends it and stderr to
# state/.watchdog.log. External responses and notification content are discarded.
# Exit 0: checked (including a logged delivery failure); 1: state/config error;
# 2: usage error. No configuration is executed as shell code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
usage() {
  printf 'Usage: FM_HOME=/absolute/home bash bin/fm-watchdog.sh check|plist\n'
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  check|plist) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
case "${FM_HOME:-}" in
  /*) ;;
  *) printf 'watchdog: explicit absolute FM_HOME is required\n' >&2; exit 1 ;;
esac
FM_HOME=$(cd "$FM_HOME" && pwd -P) || exit 1
[ -d "$FM_HOME/state" ] || { printf 'watchdog: home state directory is missing\n' >&2; exit 1; }
export FM_HOME

xml() { jq -nr --arg value "$1" '$value | @html'; }
home_hash() { printf '%s' "$FM_HOME" | shasum -a 256 | cut -c1-16; }
if [ "$1" = plist ]; then
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.firstmate.watchdog.$(home_hash)</string>
<key>ProgramArguments</key><array>
<string>/bin/bash</string><string>$(xml "$SCRIPT_DIR/fm-watchdog.sh")</string><string>check</string>
</array>
<key>WorkingDirectory</key><string>$(xml "$FM_HOME")</string>
<key>EnvironmentVariables</key><dict>
<key>FM_HOME</key><string>$(xml "$FM_HOME")</string>
<key>HOME</key><string>$(xml "$HOME")</string>
<key>PATH</key><string>$(xml "$PATH")</string>
<key>HERDR_SESSION</key><string>$(xml "${HERDR_SESSION:-default}")</string>
</dict>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>60</integer>
<key>StandardOutPath</key><string>$(xml "$FM_HOME/state/.watchdog.log")</string>
<key>StandardErrorPath</key><string>$(xml "$FM_HOME/state/.watchdog.log")</string>
</dict></plist>
EOF
  exit 0
fi

# Pin the state to the selected home, never an inherited agent's overrides.
FM_ROOT="$SCRIPT_DIR/.."
FM_ROOT_OVERRIDE=$FM_ROOT
STATE="$FM_HOME/state"
FM_STATE_OVERRIDE=$STATE
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
umask 077
lock="$STATE/.watchdog.lock"
fm_lock_try_acquire "$lock" || exit 0
trap 'fm_lock_release "$lock"' EXIT
now=$(date +%s)
log() { printf 'watchdog [at=%s]: %s\n' "$now" "$*"; }
episode="$STATE/.watchdog-episode"
[ ! -L "$episode" ] || { log 'refusing symlinked episode'; exit 1; }
if [ -e "$episode" ] && [ ! -f "$episode" ]; then
  log 'refusing non-file episode'
  exit 1
fi
beat=0
if [ -f "$STATE/.last-watcher-beat" ]; then
  beat=$(fm_path_mtime "$STATE/.last-watcher-beat") || beat=0
fi
age=$((now - beat))
if [ "$beat" -gt 0 ] && [ "$age" -le 120 ]; then
  if [ -f "$episode" ]; then
    rm "$episode"
    log "recovered: heartbeat age=${age}s"
  fi
  exit 0
fi

save_episode() {
  local temp="$episode.tmp.$$"
  printf '1\t%s\t%s\t%s\n' "$since" "$beat" "$nudged" > "$temp"
  mv -f "$temp" "$episode"
}
request_rearm() {
  local pane info
  if ! pane=$(cat "$STATE/.firstmate-pane" 2>/dev/null) \
    || ! [[ "$pane" =~ ^w[0-9]+:p[[:alnum:]]+$ ]]; then
    log 're-arm not requested: missing or invalid recorded Herdr pane'
    return
  fi
  if ! info=$(fm_run_timed 5 herdr agent get "$pane" --session "${HERDR_SESSION:-default}" 2>/dev/null) \
    || ! printf '%s' "$info" | jq -e --arg home "$FM_HOME" --arg pane "$pane" \
      '.result.agent | .agent == "omp" and .foreground_cwd == $home and .pane_id == $pane' >/dev/null 2>&1; then
    log 're-arm not requested: recorded pane is not an observable omp primary in this home'
    return
  fi
  # Native registrations can outlive the agent. Never type into a shell or
  # unknown foreground process just because an old registration still says omp.
  if ! info=$(fm_run_timed 5 herdr pane process-info --pane "$pane" --session "${HERDR_SESSION:-default}" 2>/dev/null) \
    || ! printf '%s' "$info" | jq -e --arg pane "$pane" '
      .result | .type == "pane_process_info" and .process_info.pane_id == $pane
      and (.process_info.foreground_processes | any(.name == "omp" or .argv0 == "omp"))
    ' >/dev/null 2>&1; then
    log 're-arm not requested: no verified foreground omp process'
    return
  fi
  if fm_run_timed 5 herdr agent prompt "$pane" \
    'Watcher watchdog: heartbeat stale over 120s. Drain queued wakes and re-arm with fm_watch_arm_omp. Do not run fm-watch-arm.sh outside the extension owner.' \
    --session "${HERDR_SESSION:-default}" </dev/null >/dev/null 2>&1; then
    log 're-arm request submitted; awaiting a fresh watcher heartbeat'
  else
    log 're-arm request failed or was rejected; phone escalation remains scheduled'
  fi
}

since=$now
nudged=0
previous_beat=-1
valid=0
if [ -f "$episode" ]; then
  version='' extra=''
  if read -r version since previous_beat nudged extra < "$episode" \
    && [ "$version" = 1 ] && [ -z "$extra" ] \
    && [[ "$since" =~ ^[1-9][0-9]{0,9}$ ]] \
    && [[ "$previous_beat" =~ ^(0|[1-9][0-9]{0,9})$ ]] \
    && [[ "$nudged" =~ ^[01]$ ]]; then
    valid=1
  else
    log 'invalid watchdog episode; starting a new stale observation'
  fi
fi
if [ "$valid" = 0 ] || [ "$previous_beat" != "$beat" ]; then
  since=$now
  nudged=0
  # Persist before external I/O: an ambiguous prompt must not be replayed.
  save_episode
  log "stale: heartbeat age=${age}s; requesting owner-safe recovery"
  request_rearm
fi
if [ "$since" -gt "$now" ]; then
  since=$now
  save_episode
  log 'clock moved backwards; restarted escalation observation'
fi
if [ "$nudged" = 0 ] && [ $((now - since)) -ge 300 ]; then
  nudged=1
  save_episode
  batch=$(printf '%s\n%s\n%s\n' "$FM_HOME" "$since" "$beat" | shasum -a 256 | cut -d ' ' -f 1)
  if fm_run_timed 5 fm-notify-phone --batch-id "$batch" watcher-down </dev/null >/dev/null 2>&1; then
    log 'phone watcher-down nudge dispatched (or bridge-deduplicated)'
  else
    log 'phone watcher-down nudge failed or rate-limited; attempt reserved'
  fi
fi
