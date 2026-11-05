#!/usr/bin/env bash
# Pin the shared recovery-loop contract: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
# --successor-inbox isolates the inbox regression; --successor-queue runs all
# fresh-queue boundaries. FM_TEST_WATCH_BIN may select a preserved fixture build.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="${FM_TEST_WATCH_BIN:-$ROOT/bin/fm-watch.sh}"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data" "$home/config"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# Record real terminal poll waits, with an optional fixture action after the
# third quiet sweep. The action runs while the watcher waits on this child, so
# append/confirmation and append/consumption boundaries do not depend on timing.
install_successor_poll_recorder() {  # <fakebin>
  cat > "$1/sleep" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$#" -eq 1 ] && [ "$1" = 1 ] \
  && [ "$PPID" = "$(cat "$FM_STATE_OVERRIDE/.watch.lock/pid" 2>/dev/null || true)" ]; then
  poll=$(cat "$FM_STATE_OVERRIDE/.test-polls" 2>/dev/null || echo 0)
  poll=$((poll + 1))
  if [ "$poll" -eq 3 ] && [ -n "${FM_TEST_QUEUE_ACTION:-}" ]; then
    bash "$FM_TEST_QUEUE_ACTION" > "$FM_STATE_OVERRIDE/.test-action.out" 2>&1
    printf '%s\n' "$?" > "$FM_STATE_OVERRIDE/.test-action.status"
  fi
  printf '%s\n' "$poll" > "$FM_STATE_OVERRIDE/.test-polls"
fi
exec "$FM_TEST_REAL_SLEEP" "$@"
SH
  chmod +x "$1/sleep"
}

wait_for_successor_polls() {  # <state> <watcher-pid> <polls>
  local state=$1 child=$2 wanted=$3 attempt=0 poll
  while [ "$attempt" -lt 120 ]; do
    poll=$(cat "$state/.test-polls" 2>/dev/null || echo 0)
    case "$poll" in ''|*[!0-9]*) poll=0 ;; esac
    [ "$poll" -lt "$wanted" ] || return 0
    kill -0 "$child" 2>/dev/null || return 1
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_successor_recovery() {  # <output> <watcher-pid>
  local out=$1 child=$2 attempt=0
  while [ "$attempt" -lt 100 ]; do
    grep -q '^check: rearm-resurface$' "$out" 2>/dev/null && return 0
    kill -0 "$child" 2>/dev/null || return 1
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

# T3: new inbox work must bypass the predecessor-only suppression, including a
# confirmation that binds the same generation after the append. A second real
# successor then proves that unchanged, unacknowledged rows do not replay.
test_handling_successor_surfaces_fresh_durable_rows_once() {
  local mode dir home state fakebin action turn child out identity generation status expected_rows
  if [ "$#" -eq 0 ]; then
    set -- failed-handshake confirmed-handling initially-empty
  fi
  for mode in "$@"; do
    dir=$(make_case "successor-fresh-$mode")
    home="$dir/home"
    state="$dir/state"
    fakebin="$dir/fakebin"
    mkdir -p "$home/data" "$home/config"
    install_successor_poll_recorder "$fakebin"
    generation="successor.$mode.aaa"
    expected_rows=2
    if [ "$mode" = initially-empty ]; then
      printf 'acked:downtime:%s\n' "$generation" > "$state/.watcher-down"
      expected_rows=1
    else
      FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
        append_wake "$state" check predecessor 'check: predecessor still pending' \
        || fail "could not seed the predecessor row"
      if [ "$mode" = confirmed-handling ]; then
        printf 'announced:handling:%s\n' "$generation" > "$state/.watcher-down"
      else
        printf 'announced:downtime:%s\n' "$generation" > "$state/.watcher-down"
      fi
    fi
    chmod 600 "$state/.watcher-down"
    action="$dir/queue-action.sh"
    cat > "$action" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$FM_TEST_QUEUE_MODE" = initially-empty ]; then
  . "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
  fm_wake_append stale fixture 'stale: fresh fixture durable wake'
else
  "$FM_TEST_ROOT/bin/fm-inbox.sh" note --request-id successor-fresh --json 'fixture inbox wake'
fi
if [ "$FM_TEST_QUEUE_MODE" = confirmed-handling ]; then
  . "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
  fm_recovery_marker_snapshot "$STATE/.watcher-down"
  "$FM_TEST_WATCH_ARM" --handling-delivered "${FM_RECOVERY_MARKER_TOKEN##*:}" \
    --watcher-pid "$(cat "$STATE/.watch.lock/pid")"
fi
SH
    for turn in first repeat; do
      out="$dir/$turn.out"
      rm -f "$state/.test-polls" "$state/.test-action.status"
      PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
        FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
        FM_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_REAL_SLEEP="$(command -v sleep)" \
        FM_TEST_ROOT="$ROOT" FM_TEST_QUEUE_MODE="$mode" FM_TEST_QUEUE_ACTION="$action" \
        FM_TEST_WATCH_ARM="${WATCH%/*}/fm-watch-arm.sh" \
        "$WATCH" > "$out" 2>&1 &
      child=$!
      wait_for_successor_polls "$state" "$child" 1 \
        || fail "$mode/$turn successor did not complete its first quiet sweep: $(cat "$out")"
      identity=$(cat "$state/.watch.lock/pid-identity")
      [ -n "$identity" ] || fail "$mode/$turn successor identity was not published"
      if [ "$turn" = first ]; then
        wait_for_successor_polls "$state" "$child" 3 \
          || fail "$mode successor replayed predecessor work before the fresh append: $(cat "$out")"
        [ "$(cat "$state/.test-action.status")" = 0 ] \
          || fail "$mode fixture queue action failed: $(cat "$state/.test-action.out")"
        if [ "$mode" != initially-empty ]; then
          assert_contains "$(cat "$state/.test-action.out")" '"announced":true' \
            "the fixture inbox note was not durably announced"
        fi
        wait_for_successor_recovery "$out" "$child" || {
          kill -TERM "$child" 2>/dev/null || true
          wait "$child" 2>/dev/null || true
          fail "$mode successor did not surface fresh durable work within the poll budget: $(cat "$out")"
        }
        status=0
        wait "$child" || status=$?
        expect_code 0 "$status" "$mode successor recovery exit"
        [ "$(grep -c '^check: rearm-resurface$' "$out")" -eq 1 ] \
          || fail "$mode successor did not surface exactly one recovery"
        awk -F '\t' -v pid="$child" -v identity="$identity" '
          $1 == pid && $2 == identity && $3 == "check: rearm-resurface" { found=1 }
          END { exit !found }
        ' "$state/.watch-deliveries.log" \
          || fail "$mode recovery lacked identity-bound delivery evidence"
        [ "$(wc -l < "$state/.wake-queue" | tr -d '[:space:]')" = "$expected_rows" ] \
          || fail "$mode successor consumed or duplicated durable queue rows"
        if [ "$mode" = initially-empty ]; then
          grep "$(printf '\tstale\tfixture\t')" "$state/.wake-queue" >/dev/null \
            || fail "the fresh non-inbox wake was not retained"
        else
          grep "$(printf '\tcheck\tpredecessor\t')" "$state/.wake-queue" >/dev/null \
            || fail "the predecessor row did not remain pending"
          grep "$(printf '\tcheck\tinbox:')" "$state/.wake-queue" >/dev/null \
            || fail "the fresh inbox row was not retained"
        fi
        if [ "$mode" = confirmed-handling ]; then
          [ "$(recovery_marker_generation "$state/.watcher-down")" = "$generation" ] \
            || fail "the fresh handling wake orphaned the predecessor's acknowledgement generation"
        else
          [ "$(recovery_marker_generation "$state/.watcher-down")" != "$generation" ] \
            || fail "the fresh append did not open its own recovery generation"
        fi
        generation=$(recovery_marker_generation "$state/.watcher-down")
        action=
      else
        wait_for_successor_polls "$state" "$child" 4 \
          || fail "$mode repeat successor did not keep supervising: $(cat "$out")"
        ! grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" \
          || fail "$mode repeat successor replayed unchanged queue state: $(cat "$out")"
        [ "$(recovery_marker_generation "$state/.watcher-down")" = "$generation" ] \
          || fail "$mode repeat successor changed the outstanding recovery generation"
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
      fi
    done
    pass "$mode handling successors surface fresh durable work once without replaying pending predecessors"
  done
}

# T4: an advanced append counter is not evidence of pending fresh work. The
# newer row is consumed between polls while its predecessor remains queued.
test_handling_successor_ignores_consumed_fresh_rows() {
  local dir home state fakebin action out child status
  dir=$(make_case successor-consumed-fresh)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data" "$home/config"
  install_successor_poll_recorder "$fakebin"
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    append_wake "$state" check predecessor 'check: predecessor still pending' \
    || fail "could not seed the consumed-row predecessor"
  printf 'announced:downtime:consumed.1.aaa\n' > "$state/.watcher-down"
  action="$dir/queue-action.sh"
  cat > "$action" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
. "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
fm_wake_append check consumed 'check: fixture work already handled'
"$FM_TEST_ROOT/bin/fm-wake-drain.sh" --delete-sequences "$(cat "$STATE/.wake-queue.seq")"
SH
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_REAL_SLEEP="$(command -v sleep)" \
    FM_TEST_ROOT="$ROOT" FM_TEST_QUEUE_ACTION="$action" "$WATCH" > "$out" 2>&1 &
  child=$!
  wait_for_successor_polls "$state" "$child" 5 \
    || fail "the successor replayed predecessor work after a newer row was consumed: $(cat "$out")"
  [ "$(cat "$state/.test-action.status")" = 0 ] \
    || fail "the consumed-row fixture action failed: $(cat "$state/.test-action.out")"
  [ "$(cat "$state/.wake-queue.seq")" = 2 ] \
    || fail "the consumed-row fixture did not advance the append sequence"
  [ "$(wc -l < "$state/.wake-queue" | tr -d '[:space:]')" = 1 ] \
    || fail "the consumed-row fixture did not leave only its predecessor queued"
  ! grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" \
    || fail "a consumed fresh row replayed predecessor work: $(cat "$out")"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-inbox.sh" note --request-id after-consumed --json 'fixture later inbox wake' \
    > "$dir/note.json" || fail "could not append an inbox note after consumed work"
  wait_for_successor_recovery "$out" "$child" || {
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "the successor remained blind after consumed work: $(cat "$out")"
  }
  status=0
  wait "$child" || status=$?
  expect_code 0 "$status" "successor recovery after consumed work"
  pass "a consumed fresh row does not replay its predecessor or hide later inbox work"
}

# T5: capture publication may re-queue an unhandled result after an extension
# acknowledges its queued follow-up. A new queue sequence is not a new capture.
test_handling_successor_does_not_resurface_a_republished_capture() {
  local dir home state fakebin out child status attempt action
  dir=$(make_case successor-republished-capture)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data" "$home/config"
  install_successor_poll_recorder "$fakebin"
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    append_wake "$state" check procevent:fixture:1 'check: procevent fixture-adapter fixture 1' \
    || fail "could not publish the original capture"
  out="$dir/original.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  child=$!
  attempt=0
  while kill -0 "$child" 2>/dev/null && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "the original process-event capture did not surface"
  fi
  status=0
  wait "$child" || status=$?
  expect_code 0 "$status" "original process-event capture"
  assert_contains "$(cat "$out")" 'process-event result captured: procevent:fixture:1' \
    "the original capture must be delivered before its republication"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" --delete-sequences "$(cat "$state/.wake-queue.seq")" \
    || fail "could not acknowledge the queued original capture"
  action="$dir/queue-action.sh"
  cat > "$action" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
. "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
fm_wake_append check procevent:fixture:1 'check: procevent fixture-adapter fixture 1'
SH
  out="$dir/successor.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_REAL_SLEEP="$(command -v sleep)" \
    FM_TEST_ROOT="$ROOT" FM_TEST_QUEUE_ACTION="$action" "$WATCH" > "$out" 2>&1 &
  child=$!
  if ! wait_for_successor_polls "$state" "$child" 5; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "a republished capture restarted the handling recovery loop: $(cat "$out")"
  fi
  [ "$(cat "$state/.test-action.status")" = 0 ] \
    || fail "the capture republication failed: $(cat "$state/.test-action.out")"
  [ "$(cat "$state/.wake-queue.seq")" = 2 ] \
    || fail "the capture republication must have a new queue sequence"
  ! grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" \
    || fail "an already-surfaced capture was delivered again: $(cat "$out")"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-inbox.sh" note --request-id after-republished --json 'fixture fresh inbox wake' \
    > "$dir/note.json" || fail "could not append independent fresh work"
  wait_for_successor_recovery "$out" "$child" || {
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "suppressing capture republication hid independent fresh work: $(cat "$out")"
  }
  status=0
  wait "$child" || status=$?
  expect_code 0 "$status" "fresh inbox work after capture republication"
  grep "$(printf '\tcheck\tprocevent:fixture:1\t')" "$state/.wake-queue" >/dev/null \
    || fail "suppression must not discard the unhandled capture"
  printf 'pending:downtime:real-gap.1.aaa\n' > "$state/.watcher-down"
  out="$dir/downtime.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=0 FM_TEST_REAL_SLEEP="$(command -v sleep)" \
    "$WATCH" > "$out" 2>&1 &
  child=$!
  wait_for_successor_recovery "$out" "$child" || {
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "a surfaced capture receipt suppressed real downtime recovery: $(cat "$out")"
  }
  status=0
  wait "$child" || status=$?
  expect_code 0 "$status" "real downtime recovery after capture republication"
  pass "capture republication stays quiet without hiding fresh inbox work or real downtime"
}

case "${1:-}" in
  --successor-inbox)
    test_handling_successor_surfaces_fresh_durable_rows_once failed-handshake
    ;;
  --successor-queue)
    test_handling_successor_surfaces_fresh_durable_rows_once
    test_handling_successor_ignores_consumed_fresh_rows
    test_handling_successor_does_not_resurface_a_republished_capture
    ;;
  --successor-procevent)
    test_handling_successor_does_not_resurface_a_republished_capture
    ;;
  '')
    test_handling_successor_does_not_go_blind
    test_handling_successor_surfaces_fresh_durable_rows_once
    test_handling_successor_ignores_consumed_fresh_rows
    test_handling_successor_does_not_resurface_a_republished_capture
    test_unacknowledged_recovery_is_announced_once_per_generation
    ;;
  *) fail "usage: ${0##*/} [--successor-inbox | --successor-queue | --successor-procevent]" ;;
esac
