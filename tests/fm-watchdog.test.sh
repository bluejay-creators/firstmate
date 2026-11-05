#!/usr/bin/env bash
# Drive the public watchdog with real beacon mtimes and real fixture processes.
# Only clock and transport are adapted; no Herdr, Keychain or device is contacted.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watchdog)
ORIGINAL_PATH=$PATH
REAL_DATE=$(command -v date)
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = +%s ]; then cat "$WATCHDOG_CLOCK"; else exec "$WATCHDOG_REAL_DATE" "$@"; fi
SH
cat > "$BIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1:$2" in
  agent:get)
    jq -n --arg pane "$3" --arg home "${WATCHDOG_FOREGROUND:-$FM_HOME}" --arg kind "${WATCHDOG_AGENT:-omp}" \
      '{result:{agent:{agent:$kind,foreground_cwd:$home,pane_id:$pane}}}' ;;
  pane:process-info)
    read -r name < <(ps -p "$WATCHDOG_PROCESS_PID" -o ucomm=)
    read -r argv0 _rest < <(ps -p "$WATCHDOG_PROCESS_PID" -o args=)
    jq -n --arg pane "$4" --arg name "${name##*/}" --arg argv0 "${argv0##*/}" \
      '{result:{type:"pane_process_info",process_info:{pane_id:$pane,foreground_processes:[{name:$name,argv0:$argv0}]}}}' ;;
  agent:prompt)
    printf 'attempt\n' >> "$FM_HOME/prompts"
    [ "${WATCHDOG_PROMPT_FAIL:-0}" = 0 ] || exit 1
    [ "${WATCHDOG_PROMPT_HANG:-0}" = 0 ] || sleep 60
    printf 'private transport response\n' ;;
  *) exit 2 ;;
esac
SH
cat > "$BIN/fm-notify-phone" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'attempt\n' >> "$FM_HOME/phones"
if [ "$#" != 3 ] || [ "$1" != --batch-id ] || ! [[ "$2" =~ ^[0-9a-f]{64}$ ]] \
  || [ "$3" != watcher-down ] || [ -n "$(cat)" ]; then
  : > "$FM_HOME/unsafe-phone-input"
  exit 2
fi
printf 'private bridge response\n' >&2
exit "${WATCHDOG_PHONE_RC:-0}"
SH
chmod +x "$BIN/date" "$BIN/herdr" "$BIN/fm-notify-phone"
export WATCHDOG_REAL_DATE="$REAL_DATE"
export PATH="$BIN:$ORIGINAL_PATH" HERDR_SESSION=watchdog-test

# Independent identities from real processes, not a fake agent banner.
# Compile our own leaf: macOS may kill a relocated platform-signed binary.
cc -x c -o "$TMP_ROOT/omp" - <<'C'
#include <unistd.h>
int main(void) { for (;;) pause(); }
C
bash -c 'exec -a watchdog-fixture "$1" 120' _ "$TMP_ROOT/omp" &
NAME_PID=$!
bash -c 'exec -a omp sleep 120' &
ARGV_PID=$!
cleanup_processes() {
  kill "$NAME_PID" "$ARGV_PID" 2>/dev/null || true
  wait "$NAME_PID" "$ARGV_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_processes EXIT
# Wait for exec without relying on scheduling order.
for _ in $(seq 1 100); do
  read -r name < <(ps -p "$NAME_PID" -o ucomm=)
  read -r argv0 _rest < <(ps -p "$ARGV_PID" -o args=)
  [ "${name##*/}" = omp ] && [ "${argv0##*/}" = omp ] && break
  sleep 0.02
done
read -r name_argv0 _rest < <(ps -p "$NAME_PID" -o args=)
read -r argv_name < <(ps -p "$ARGV_PID" -o ucomm=)
[ "${name##*/}" = omp ] && [ "${name_argv0##*/}" != omp ] || fail "name-only identity did not diverge: kernel=$name argv0=$name_argv0"
[ "${argv0##*/}" = omp ] && [ "${argv_name##*/}" != omp ] || fail "argv-only identity did not diverge: kernel=$argv_name argv0=$argv0"

new_case() {
  FM_HOME="$TMP_ROOT/$1"
  WATCHDOG_CLOCK="$FM_HOME/clock"
  export FM_HOME WATCHDOG_CLOCK
  unset WATCHDOG_FOREGROUND WATCHDOG_AGENT WATCHDOG_PROMPT_FAIL WATCHDOG_PROMPT_HANG WATCHDOG_PHONE_RC
  export WATCHDOG_PROCESS_PID=$NAME_PID
  mkdir -p "$FM_HOME/state"
  printf 'w9:p1\n' > "$FM_HOME/state/.firstmate-pane"
  : > "$FM_HOME/prompts"
  : > "$FM_HOME/phones"
  touch -t 202001010000 "$FM_HOME/state/.last-watcher-beat"
  if [ "$(uname)" = Darwin ]; then
    BEAT=$(stat -f %m "$FM_HOME/state/.last-watcher-beat")
  else
    BEAT=$(stat -c %Y "$FM_HOME/state/.last-watcher-beat")
  fi
  NOW=$((BEAT + 121))
}
check() {
  printf '%s\n' "$NOW" > "$WATCHDOG_CLOCK"
  OUT=$(bash "$ROOT/bin/fm-watchdog.sh" check) || fail 'watchdog check failed'
  assert_not_contains "$OUT" 'private transport response' 'Herdr response leaked'
  assert_not_contains "$OUT" 'private bridge response' 'phone response leaked'
}
count() { wc -l < "$1" | tr -d ' '; }

new_case boundary
NOW=$((BEAT + 120))
check
[ "$(count "$FM_HOME/prompts")" = 0 ] || fail 'age 120 triggered recovery'
[ ! -e "$FM_HOME/state/.watchdog-episode" ] || fail 'fresh beat opened an episode'
NOW=$((BEAT + 121))
check
[ "$(count "$FM_HOME/prompts")" = 1 ] || fail 'age 121 failed to request recovery'
check
[ "$(count "$FM_HOME/prompts")" = 1 ] || fail 'next process replayed the pending prompt'
[ "$(count "$FM_HOME/phones")" = 0 ] || fail 'phone sent before recovery observation'
pass 'fresh/stale boundary triggers exactly one persisted owner-safe recovery request'

NOW=$((BEAT + 420))
check
[ "$(count "$FM_HOME/phones")" = 0 ] || fail 'phone sent at 299 seconds'
NOW=$((BEAT + 421))
check
[ "$(count "$FM_HOME/phones")" = 1 ] || fail 'continued staleness failed to nudge at 300 seconds'
check
NOW=$((NOW + 600))
check
[ "$(count "$FM_HOME/phones")" = 1 ] || fail 'restarted checks replayed phone escalation'
[ ! -e "$FM_HOME/unsafe-phone-input" ] || fail 'notification carried content or unsafe arguments'
touch "$FM_HOME/state/.last-watcher-beat"
NOW=$("$REAL_DATE" +%s)
check
[ ! -e "$FM_HOME/state/.watchdog-episode" ] || fail 'real fresh heartbeat did not close the episode'
pass 'five-minute phone boundary is content-free, restart-safe and cleared only by a real fresh beat'

new_case progress
check
# A new real heartbeat may already be stale by the next invocation. It must
# start its own observation rather than inherit an earlier outage's deadline.
touch -t 202001010001 "$FM_HOME/state/.last-watcher-beat"
NOW=$((BEAT + 421))
check
[ "$(count "$FM_HOME/prompts")" = 2 ] || fail 'new heartbeat did not start its own stale observation'
[ "$(count "$FM_HOME/phones")" = 0 ] || fail 'new progress inherited the previous outage timer'
pass 'new observed progress resets the stale episode even if the next sample is late'

for scenario in wrong-home wrong-agent stale-registration missing-pane; do
  new_case "$scenario"
  case "$scenario" in
    wrong-home) export WATCHDOG_FOREGROUND="$TMP_ROOT/unrelated-home" ;;
    wrong-agent) export WATCHDOG_AGENT=claude ;;
    stale-registration) export WATCHDOG_PROCESS_PID=$$ ;;
    missing-pane) rm "$FM_HOME/state/.firstmate-pane" ;;
  esac
  check
  [ "$(count "$FM_HOME/prompts")" = 0 ] || fail 'unbound or unrelated target received recovery input'
  NOW=$((NOW + 300))
  check
  [ "$(count "$FM_HOME/phones")" = 1 ] || fail 'unrecoverable target suppressed external escalation'
done
pass 'missing, non-omp and wrong-home panes cannot receive input but still escalate externally'

new_case argv-only
export WATCHDOG_PROCESS_PID=$ARGV_PID
check
[ "$(count "$FM_HOME/prompts")" = 1 ] || fail 'argv-only foreground identity was not accepted'
pass 'kernel-name-only and argv-only real processes independently prove foreground identity'

new_case missing-beat
rm "$FM_HOME/state/.last-watcher-beat"
check
NOW=$((NOW + 300))
check
[ "$(count "$FM_HOME/prompts")" = 1 ] || fail 'missing beacon failed to request recovery'
[ "$(count "$FM_HOME/phones")" = 1 ] || fail 'missing beacon failed to escalate'
pass 'a never-written or lost heartbeat cannot look healthy'

new_case failures
export WATCHDOG_PROMPT_FAIL=1 WATCHDOG_PHONE_RC=75
check
NOW=$((NOW + 300))
check
check
[ "$(count "$FM_HOME/prompts")" = 1 ] || fail 'rejected prompt retried without new progress'
[ "$(count "$FM_HOME/phones")" = 1 ] || fail 'failed or rate-limited phone attempt replayed'
pass 'failed/rejected transports retain their reservations across new checker processes'

new_case bounded
export WATCHDOG_PROMPT_HANG=1
start=$SECONDS
check
[ $((SECONDS - start)) -lt 15 ] || fail 'hung Herdr command stranded the external job'
NOW=$((NOW + 300))
check
[ "$(count "$FM_HOME/phones")" = 1 ] || fail 'hung recovery prevented later phone escalation'
pass 'a hung recovery transport is bounded and does not prevent the next escalation tick'

new_case concurrent
printf '%s\n' "$NOW" > "$WATCHDOG_CLOCK"
pids=()
for _ in 1 2 3 4; do
  bash "$ROOT/bin/fm-watchdog.sh" check > "$FM_HOME/out.$_" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail 'concurrent checker failed'; done
[ "$(count "$FM_HOME/prompts")" = 1 ] || fail 'concurrent checks duplicated the recovery request'
pass 'manual and scheduled checks serialize one stale episode without sharing the watcher lock'
