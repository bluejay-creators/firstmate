#!/usr/bin/env bash
# tests/fm-quiet-wakes.test.sh - quiet-wake handling: compact wake text
# construction, --brief --ack drain, and the MAI wake coalesce shell's
# deterministic-absorb and fail-open contracts. Framework: tests/lib.sh.
# Runner: bin/fm-test-run.sh paths.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
COALESCE="$ROOT/bin/fm-ask-mai-coalesce.sh"
TMP_ROOT=$(fm_test_tmproot fm-quiet-wakes)

make_home() { # <name>
  local d=$TMP_ROOT/$1
  mkdir -p "$d/state" "$d/config"
  printf '%s' "$d"
}

# Append a queue row for <kind> <key> <payload> at seq <n>.
seed_queue_row() { # <home> <seq> <kind> <key> <payload>
  local home=$1 seq=$2 kind=$3 key=$4 payload=$5 epoch
  epoch=$(date +%s)
  printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$key" "$payload" >> "$home/state/.wake-queue"
}

# The drain needs a recovery generation marker to accept acknowledgements.
# seed_recovery <home>: publishes one pending episode so --ack-through has a
# generation to bind to.
seed_recovery() { # <home>
  local home=$1
  printf 'pending:downtime:%s\n' "$(date +%s)-quiet-test" > "$home/state/.watcher-down"
}


# The compact banner's byte shape and the historical-body absence are pinned
# behaviorally in tests/fm-omp-harness.test.sh's wake-text assertion on
# sent[0].m, which drives the real production extension. This file owns only
# the drain and coalesce contracts below.

test_quiet_drain_compact_and_self_ack() {
  local home dir RC
  dir=$TMP_ROOT/quiet-self-ack; mkdir -p "$dir"
  home=$(make_home quiet-self-ack)
  seed_recovery "$home"
  seed_queue_row "$home" 1 heartbeat "" "heartbeat cadence"
  seed_queue_row "$home" 2 signal task-x.status "signal: task-x.status"
  printf 'working [at=1700000000]: half way\n' > "$home/state/task-x.status"
  printf '0' > "$home/state/.fm-quietsince-task-x.status"

  FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$DRAIN" --brief --ack >"$dir/stdout" 2>"$dir/stderr"
  RC=$?
  expect_code 0 "$RC" "--brief --ack with only routine rows must ack itself"
  assert_not_contains "$(cat "$dir/stderr")" "WAKE_ACK_REQUIRED" "self-ack keeps stderr free of ack command"
  assert_contains "$(cat "$dir/stdout")" "heartbeat" "heartbeat presented in --brief"
  assert_contains "$(cat "$dir/stdout")" "signal" "signal presented in --brief"
  [ -s "$home/state/.wake-queue" ] && { fail "queue must be empty after self-ack"; }
  pass "--brief --ack absorbs routine heartbeats and bare working: signal rows"
}

test_quiet_drain_keeps_ack_for_actionable() {
  local home dir RC
  dir=$TMP_ROOT/quiet-actionable; mkdir -p "$dir"
  home=$(make_home quiet-actionable)
  seed_recovery "$home"
  seed_queue_row "$home" 1 signal task-y.status "signal: task-y.status"
  printf 'needs-decision [at=1700000000]: choose\n' > "$home/state/task-y.status"
  printf '0' > "$home/state/.fm-quietsince-task-y.status"

  FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$DRAIN" --brief --ack >"$dir/stdout" 2>"$dir/stderr"
  RC=$?
  expect_code 0 "$RC" "--brief --ack still returns 0 when an actionable row survives"
  assert_contains "$(cat "$dir/stderr")" "WAKE_ACK_REQUIRED" "no self-ack; ack command must follow the handling turn"
  [ -s "$home/state/.wake-queue" ] || fail "queue must retain the actionable row: cat $home/state/.wake-queue"
  pass "--brief --ack keeps ack command for needs-decision rows"
}

test_coalesce_heartbeat_absorbed() {
  local home out RC
  home=$(make_home coalesce-heartbeat)
  seed_queue_row "$home" 1 heartbeat "" "heartbeat cadence"
  out=$(FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
        "$COALESCE" "$home" "$home/state/.wake-queue" 1 2>&1)
  RC=$?
  expect_code 0 "$RC" "heartbeat coalesce must succeed"
  assert_contains "$out" '"deliver":[]' "heartbeat delivers empty bucket"
  assert_contains "$out" '"absorbed":[{"kind":"heartbeat"' "heartbeats are routine"
  pass "coalesce shell: heartbeat rows absorb deterministically"
}

test_coalesce_signal_working_absorbed_then_delivers_next() {
  local home out1 out2 RC
  home=$(make_home coalesce-working)
  seed_queue_row "$home" 1 signal task-z.status "signal: task-z.status"
  printf 'working [at=1700000000]: pull-request published\n' > "$home/state/task-z.status"

  out1=$(FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
        "$COALESCE" "$home" "$home/state/.wake-queue" 1 2>&1)
  RC=$?
  expect_code 0 "$RC" "signal with bare working must coalesce"
  assert_contains "$out1" '"deliver":[]' "signal absorb bucket"
  assert_contains "$out1" '"kind":"signal"' "signal absorb"
  # Cursor advanced by the first absorb; a follow-up wake for the SAME task
  # (its trailing verb again resolves to bare working: after the first was
  # already absorbed) classifies routine on the span since the cursor.
  printf 'working [at=1700000100]: pull-request merged\n' >> "$home/state/task-z.status"
  seed_queue_row "$home" 2 signal task-z.status "signal: task-z.status"
  out2=$(FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
        "$COALESCE" "$home" "$home/state/.wake-queue" 1 2>&1)
  RC=$?
  expect_code 0 "$RC" "followup coalesce must still succeed"
  assert_contains "$out2" '"absorbed":[{"kind":"signal"' "each independent bare-working: wake is routine"
  pass "coalesce shell: each bare working: wake is routine; cursor guards only against re-reading the same span"
}

test_coalesce_signal_mai_fail_open() {
  local home out RC
  home=$(make_home coalesce-fail-open)
  : > "$home/config/mai-routing"
  seed_queue_row "$home" 1 signal task-w.status "signal: task-w.status"
  printf 'awaiting-decision [at=1700000000]: pending captain reply\n' > "$home/state/task-w.status"
  out=$(FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_MAI_TRIAGE_TIMEOUT_SECS=2 F2_GATEWAY_TOKEN_CMD=/does/not/exist F2_GATEWAY_URL=http://127.0.0.1:1/ \
      "$COALESCE" "$home" "$home/state/.wake-queue" 1 2>&1)
  RC=$?
  expect_code 0 "$RC" "fail-open coalesce must succeed despite MAI call failure"
  assert_contains "$out" '"deliver":[{"kind":"signal"' "MAI failure fails open to delivery"
  pass "coalesce shell: MAI failure delivers the wake (fail-open)"
}

test_coalesce_never_absorbs_stale_check_or_procevent() {
  local home out RC
  home=$(make_home coalesce-no-stale)
  seed_queue_row "$home" 1 stale "win1" "stale: win1 idle"
  seed_queue_row "$home" 2 check "check:x" "check: x"
  seed_queue_row "$home" 3 watcher "watch" "watcher: FAILED restart"
  out=$(FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
        "$COALESCE" "$home" "$home/state/.wake-queue" 3 2>&1)
  RC=$?
  expect_code 0 "$RC" "never-miss classes must classify"
  assert_contains "$out" '"kind":"stale"' "stale deliver bucket"
  assert_contains "$out" '"kind":"check"' "check deliver bucket"
  assert_contains "$out" '"kind":"watcher"' "watcher deliver bucket"
  assert_not_contains "$out" '"absorbed":[{"kind":"stale"' "stale never absorbed"
  assert_not_contains "$out" '"absorbed":[{"kind":"check"' "check never absorbed"
  assert_not_contains "$out" '"absorbed":[{"kind":"watcher"' "watcher never absorbed"
  pass "coalesce shell: stale / check / watcher never reach the absorb tier"
}

test_compact_protocol_call_names_brief_mode() {
  assert_contains "$(cat "$ROOT/docs/supervision-protocols/omp.md")" "bin/fm-wake-drain.sh --brief --ack" \
    "omp protocol must name --brief --ack as the default wake-handling call"
  pass "omp supervision protocol names --brief --ack"
}

# runner

tests=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
count=0
for t in $tests; do
  "$t" || exit 1
  count=$((count + 1))
done
printf 'ok - %d/%d fm-quiet-wakes tests passed\n' "$count" "$count"
