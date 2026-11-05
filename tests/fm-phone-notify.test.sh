#!/usr/bin/env bash
# Content-free, default-off away-daemon phone hints through the public helpers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-supervise-daemon.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-supervise-daemon.sh"

TMP_ROOT=$(fm_test_tmproot fm-phone-notify)
ORIGINAL_PATH=$PATH
NOW=10000
_now() { printf '%s\n' "$NOW"; }
# Isolate pane transport, not the phone hook or batching implementation.
inject_msg() { printf '%s\n' "$1" >> "$FM_HOME/injected"; }

new_case() {
  FM_HOME="$TMP_ROOT/$1"
  FM_CONFIG_OVERRIDE="$FM_HOME/config"
  FM_DATA_OVERRIDE="$FM_HOME/data"
  FM_STATE_OVERRIDE="$FM_HOME/state"
  LOG="$FM_HOME/daemon.log"
  FM_PHONE_CALLS="$FM_HOME/calls"
  FM_PHONE_RC=0
  FM_PHONE_HANG=0
  mkdir -p "$FM_CONFIG_OVERRIDE" "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE" "$FM_HOME/fakebin"
  : > "$FM_STATE_OVERRIDE/.afk"
  : > "$LOG"
  : > "$FM_PHONE_CALLS"
  cat > "$FM_HOME/fakebin/fm-notify-phone" <<'FAKE'
#!/usr/bin/env bash
stdin=$(cat)
printf '%s|%s|%s\n' "$#" "$*" "$stdin" >> "$FM_PHONE_CALLS"
if [ "$FM_PHONE_HANG" = 1 ]; then sleep 60; fi
printf 'untrusted bridge output\n' >&2
exit "$FM_PHONE_RC"
FAKE
  chmod +x "$FM_HOME/fakebin/fm-notify-phone"
  PATH="$FM_HOME/fakebin:$ORIGINAL_PATH"
  export FM_HOME FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PHONE_CALLS FM_PHONE_RC FM_PHONE_HANG PATH
  WEDGE_ALARM_LAST_EPOCH=0
  FM_SUPERVISOR_BACKEND=herdr
  FM_WEDGE_ALARM_CHANNEL=off
  export FM_SUPERVISOR_BACKEND FM_WEDGE_ALARM_CHANNEL
}

flush_secret_batch() {
  escalate_add "$FM_STATE_OVERRIDE" 'check: private digest text; task secret-task; reason private reason' \
    || fail 'could not enqueue test escalation'
  escalate_flush "$FM_STATE_OVERRIDE" || fail 'phone hook blocked digest delivery'
  wait
}

new_case default-off
flush_secret_batch
inject_wedge_alarm "$FM_STATE_OVERRIDE" 999
wait
[ ! -s "$FM_PHONE_CALLS" ] || fail 'absent config sent a phone hint'
pass 'phone hook is off by default for digest and wedge alarms'

new_case enabled
printf 'fm-notify-phone\n' > "$FM_CONFIG_OVERRIDE/phone-notify"
flush_secret_batch
[ "$(cat "$FM_PHONE_CALLS")" = '1|away-digest-ready|' ] \
  || fail 'batch did not send exactly one content-free template with empty stdin'
[ -s "$FM_HOME/injected" ] || fail 'digest did not reach pane transport'
assert_not_contains "$(cat "$LOG")" 'untrusted bridge output' 'bridge output leaked into log'
pass 'enabled batch sends exactly one template, without digest text or stdin'

flush_secret_batch
[ "$(wc -l < "$FM_PHONE_CALLS" | tr -d ' ')" = 1 ] || fail 'repeat batch bypassed rate limit'
# A fresh process has no in-memory rate state, as after a daemon restart.
restart_out=$(PHONE_NOW=$NOW bash -c '
  . "$1"
  _now() { printf "%s\\n" "$PHONE_NOW"; }
  phone_notify "$FM_STATE_OVERRIDE" away-digest-ready
  wait
' phone-restart "$ROOT/bin/fm-supervise-daemon.sh" 2>&1) || fail 'restarted notifier process failed'
[ -z "$restart_out" ] || fail "restarted notifier emitted unexpected output: $restart_out"
[ "$(wc -l < "$FM_PHONE_CALLS" | tr -d ' ')" = 1 ] || fail 'restart bypassed durable rate reservation'
NOW=10599
flush_secret_batch
[ "$(wc -l < "$FM_PHONE_CALLS" | tr -d ' ')" = 1 ] || fail 'template retried before ten minutes'
NOW=10600
flush_secret_batch
[ "$(wc -l < "$FM_PHONE_CALLS" | tr -d ' ')" = 2 ] || fail 'template did not become eligible at ten minutes'
pass 'per-template rate reservation survives restart and honors the ten-minute boundary'

new_case holds
: > "$FM_CONFIG_OVERRIDE/phone-notify"
cat > "$FM_DATA_OVERRIDE/backlog.md" <<'BACKLOG'
## Queued
- [ ] one - Private question (kind: captain) (hold: private reason) (hold-kind: captain)
- [ ] two - Another private question (kind: ship) (hold: private reason) (hold-kind: captain)

## Done
- [x] closed - Answered question (kind: captain) (hold: private answer) (hold-kind: captain)
BACKLOG
flush_secret_batch
[ "$(cat "$FM_PHONE_CALLS")" = '2|decisions-waiting 2|' ] \
  || fail 'held decision count was wrong or leaked text'
inject_wedge_alarm "$FM_STATE_OVERRIDE" 999
wait
[ "$(cat "$FM_PHONE_CALLS")" = $'2|decisions-waiting 2|\n1|urgent|' ] \
  || fail 'urgent wedge hint was not independent and content-free'
pass 'empty config uses default CLI; held decisions send only a count, wedge sends urgent'

new_case concurrent
printf 'fm-notify-phone\n' > "$FM_CONFIG_OVERRIDE/phone-notify"
for _attempt in 1 2 3 4; do
  phone_notify "$FM_STATE_OVERRIDE" urgent
done
wait
[ "$(cat "$FM_PHONE_CALLS")" = '1|urgent|' ] || fail 'concurrent workers bypassed template rate lock'
pass 'concurrent notification workers reserve only one attempt per template'

announcement=$(bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'private away instructions') \
  || fail 'away entry with phone config failed'
assert_contains "$announcement" 'Optional content-free phone hints may run' 'enabled entry still claimed no phone channel'
assert_contains "$announcement" 'still waits for your return' 'enabled entry lost hold-for-return'
pass 'away entry acknowledges optional hints without promising delivery or phone answers'

new_case failing
printf 'fm-notify-phone\n' > "$FM_CONFIG_OVERRIDE/phone-notify"
FM_PHONE_RC=9
export FM_PHONE_RC
flush_secret_batch
assert_contains "$(cat "$LOG")" 'phone notify: away-digest-ready failed (exit 9)' 'failure was not logged'
flush_secret_batch
[ "$(wc -l < "$FM_PHONE_CALLS" | tr -d ' ')" = 1 ] || fail 'failed attempt was retried inside rate window'
[ "$(wc -l < "$FM_HOME/injected" | tr -d ' ')" = 2 ] || fail 'phone failure prevented subsequent digest delivery'
pass 'CLI failure is logged, rate-limited, and cannot stop daemon delivery'

new_case hung
printf 'fm-notify-phone\n' > "$FM_CONFIG_OVERRIDE/phone-notify"
FM_PHONE_HANG=1
export FM_PHONE_HANG
start=$SECONDS
escalate_add "$FM_STATE_OVERRIDE" 'check: private text' || fail 'could not enqueue hang test'
escalate_flush "$FM_STATE_OVERRIDE" || fail 'hung phone CLI blocked delivery'
[ $((SECONDS - start)) -lt 3 ] || fail 'phone dispatch blocked daemon path'
wait
[ $((SECONDS - start)) -lt 10 ] || fail 'hung phone process was not bounded'
assert_contains "$(cat "$LOG")" 'failed (exit 124)' 'phone timeout was not logged'
pass 'hung CLI is asynchronous and killed within its five-second bound'

new_case disabled-paths
printf 'mode: quiet\n' > "$FM_STATE_OVERRIDE/.afk-contract"
printf 'fm-notify-phone\n' > "$FM_CONFIG_OVERRIDE/phone-notify"
flush_secret_batch
[ ! -s "$FM_PHONE_CALLS" ] || fail 'quiet posture sent phone hint'
rm "$FM_STATE_OVERRIDE/.afk-contract" "$FM_STATE_OVERRIDE/.afk"
phone_notify "$FM_STATE_OVERRIDE" urgent
wait
[ ! -s "$FM_PHONE_CALLS" ] || fail 'inactive away posture sent phone hint'
: > "$FM_STATE_OVERRIDE/.afk"
printf 'missing-phone-cli\n' > "$FM_CONFIG_OVERRIDE/phone-notify"
flush_secret_batch
assert_contains "$(cat "$LOG")" 'not on PATH' 'missing command was not logged'
printf 'fm-notify-phone; private text\n' > "$FM_CONFIG_OVERRIDE/phone-notify"
flush_secret_batch
[ ! -s "$FM_PHONE_CALLS" ] || fail 'shell-fragment config executed a CLI'
pass 'quiet, inactive, missing-command, and shell-fragment configurations cannot send'
