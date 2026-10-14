#!/usr/bin/env bash
# tests/fm-inbox-listener.test.sh - portable regression for the omp steering
# inbox listener (.omp/extensions/fm-inbox-listener.ts), its shell-side live
# check (bin/fm-task-inbox-listener-lib.sh), and the doorbell producers that
# must stay out of a live listener's pane (fm_task_inbox_ring /
# fm_task_inbox_due_action in bin/fm-task-inbox-lib.sh, consumed by
# bin/fm-send.sh and bin/fm-watch.sh).
#
# No real omp is needed: the extension is driven over a fake ExtensionAPI in a
# plain Node host, and the shell side is exercised with a fake backend, so CI
# enforces the classifier with real processes everywhere tmux runs.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

LISTENER_EXT="$ROOT/.omp/extensions/fm-inbox-listener.ts"
TMP_ROOT=$(fm_test_tmproot fm-inbox-listener)
export NODE_NO_WARNINGS=1

[ -f "$LISTENER_EXT" ] || fail "listener extension missing at $LISTENER_EXT"

# Drive the extension in Node against a fake omp API. $1 = inbox dir, $2 = a
# Node driver body run with `pi` (the fake API) and `handlers` (event map) in
# scope, plus helper `fire(name, event)`.
run_listener_driver() {  # <inbox-dir> <driver-body-file> [extra-env...]
  local inbox=$1 body=$2
  shift 2
  env FM_TASK_INBOX="$inbox" EXT="$LISTENER_EXT" "$@" node --experimental-strip-types --input-type=module -e '
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
const handlers = new Map();
const sent = [];
globalThis.sent = sent;
globalThis.fire = (name, event) => {
  const list = handlers.get(name) ?? [];
  for (const h of list) h(event, {});
};
const pi = {
  on(name, handler) {
    handlers.set(name, [...(handlers.get(name) ?? []), handler]);
  },
  sendUserMessage(content, options) {
    if (process.env.REJECT_SENDS === "1") throw new Error("fixture: busy send rejected");
    sent.push({ content, options: options ?? {} });
    return undefined; // omp sendUserMessage returns synchronously (no promise)
  },
};
globalThis.pi = pi;
process.on("unhandledRejection", (e) => { throw e; });
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await import(pathToFileURL(process.env.DRIVER_BODY).href);
' 2>&1
}

write_record() {  # <inbox-dir> <seq-name> <body>
  local dir=$1 name=$2
  mkdir -p "$dir/handled"
  printf 'schema=fm-task-inbox.v1\nat=2026-10-13T00:00:00Z\n--\n%s' "$3" > "$dir/$name"
}

# --- 1. Idle delivery + consumption ack -------------------------------------

test_idle_delivery_acks_once() {
  local inbox="$TMP_ROOT/idle.inbox" body out
  write_record "$inbox" 001.msg "ship it"
  body="$TMP_ROOT/driver-idle.mjs"
  cat > "$body" <<'JS'
fire("agent_start", {});
const prompt = sent[0]?.content;
if (typeof prompt !== "string" || !prompt.includes("ship it")) throw new Error(`idle delivery missing body: ${JSON.stringify(sent)}`);
if (sent[0].options.deliverAs !== "followUp") throw new Error(`idle delivery must be a followUp, got ${sent[0].options.deliverAs}`);
// Consume exactly as omp reports: before_agent_start with the exact prompt.
fire("before_agent_start", { prompt });
fire("agent_end", {});
fire("agent_start", {});
fire("before_agent_start", { prompt: "unrelated prompt" });
fire("agent_end", {});
if (sent.length !== 1) throw new Error(`no redelivery after consumption: ${sent.length} sends`);
if (sent.some((m) => !m.content.includes("record 001.msg"))) throw new Error("delivery must name the record");
JS
  out=$(DRIVER_BODY="$body" run_listener_driver "$inbox" "$body") || fail "idle driver failed: $out"
  [ -f "$inbox/handled/001.msg" ] || fail "consumed idle record must be acknowledged into handled/"
  [ -f "$inbox/.listener" ] || fail "a live listener must publish its heartbeat"
  pass "listener delivers one idle record as a follow-up, consumes it at before_agent_start, and acks exactly once"
}

# --- 2. Mid-turn delivery, ack-once under duplicated events -----------------
# A record landing while a run is in progress must be steered, not typed.
# The mid-turn window is real concurrency: the shell drops the record while
# the extension's poll loop already sees a busy turn.
test_mid_turn_steering_and_ack_once() {
  local inbox="$TMP_ROOT/mid.inbox" body out
  write_record "$inbox" 001.msg "mid-turn seed"
  body="$TMP_ROOT/driver-mid.mjs"
  cat > "$body" <<'JS'
const inbox = process.env.FM_TASK_INBOX;
// Consume the load-time idle delivery of 001, then hold a busy turn.
if (sent.length !== 1 || sent[0].options.deliverAs !== "followUp") {
  throw new Error(`seed delivery wrong: ${JSON.stringify(sent.map((m) => m.options))}`);
}
fire("before_agent_start", { prompt: sent[0].content });
fire("agent_end", {});
fire("agent_start", {}); // busy from here on
// Hand control back to the shell by idling on the event loop; the shell's
// concurrent write of 002 lands while this turn is busy. The extension's
// 3s poll will pick it up; give the test its own quicker prod via the event.
await new Promise((resolve) => setTimeout(resolve, 4000));
if (sent.length !== 2 || sent[1].options.deliverAs !== "steer") {
  throw new Error(`mid-turn delivery must be one steer, got ${JSON.stringify(sent.map((m) => m.options))}`);
}
if (!sent[1].content.includes("mid-turn steer body")) throw new Error(`mid-turn body lost: ${sent[1].content}`);
// The running run joins the steer as a user message_start; a duplicated
// emission must not re-ack or re-send.
const content = sent[1].content;
fire("message_start", { message: { role: "user", content } });
fire("message_start", { message: { role: "user", content } });
fire("agent_end", {});
await new Promise((resolve) => setTimeout(resolve, 200));
if (sent.length !== 2) throw new Error(`mid-turn redelivery after ack: ${sent.length} sends`);
JS
  out=$(
    (
      DRIVER_BODY="$body" run_listener_driver "$inbox" "$body" &
      driver_pid=$!
      sleep 1.0   # let the extension bind, consume 001, and enter busy
      write_record "$inbox" 002.msg "mid-turn steer body"
      wait "$driver_pid"
    ) 2>&1
  ) || fail "mid-turn driver failed: $out"
  [ -f "$inbox/handled/001.msg" ] || fail "seed record must be acked"
  [ -f "$inbox/handled/002.msg" ] || fail "mid-turn record must be acked once consumed"
  pass "listener steers a mid-turn record into the running turn and acks exactly once under duplicated message_start"
}

# --- 3. No redelivery after restart -----------------------------------------

test_restart_no_redelivery() {
  local inbox="$TMP_ROOT/restart.inbox" body out
  write_record "$inbox" 001.msg "first"
  body="$TMP_ROOT/driver-restart-a.mjs"
  cat > "$body" <<'JS'
fire("agent_start", {});
fire("before_agent_start", { prompt: sent[0].content });
fire("agent_end", {});
fire("session_shutdown", {});
if (sent.length !== 1) throw new Error(`setup delivery failed: ${sent.length}`);
JS
  out=$(DRIVER_BODY="$body" run_listener_driver "$inbox" "$body") || fail "restart setup driver failed: $out"
  [ -f "$inbox/handled/001.msg" ] || fail "setup record must be acked before restart"
  body="$TMP_ROOT/driver-restart-b.mjs"
  cat > "$body" <<'JS'
// Fresh process: handled/ holds 001. Nothing may be sent.
fire("session_start", {});
fire("agent_start", {});
fire("agent_end", {});
if (sent.length !== 0) throw new Error(`restart redelivered handled records: ${JSON.stringify(sent)}`);
JS
  out=$(DRIVER_BODY="$body" run_listener_driver "$inbox" "$body") || fail "restart driver failed: $out"
  # Unconsumed at shutdown: re-delivered by the replacement session.
  body="$TMP_ROOT/driver-restart-c.mjs"
  cat > "$body" <<'JS'
fire("agent_start", {});
if (sent.length !== 1) throw new Error(`setup delivery failed: ${sent.length}`);
fire("session_shutdown", {}); // never consumed
JS
  write_record "$inbox" 003.msg "unconsumed"
  out=$(DRIVER_BODY="$body" run_listener_driver "$inbox" "$body") || fail "unconsumed setup driver failed: $out"
  [ ! -f "$inbox/handled/003.msg" ] || fail "an unconsumed record must NOT be acked"
  body="$TMP_ROOT/driver-restart-d.mjs"
  cat > "$body" <<'JS'
fire("session_start", {});
fire("agent_start", {});
if (sent.length !== 1) throw new Error(`unconsumed record must be re-delivered by the successor: ${sent.length}`);
if (!sent[0].content.includes("unconsumed")) throw new Error("wrong record re-delivered");
JS
  out=$(DRIVER_BODY="$body" run_listener_driver "$inbox" "$body") || fail "successor driver failed: $out"
  pass "listener never redelivers handled records after restart and re-delivers an unconsumed one in the successor session"
}

# --- 4. Rejected send leaves the record; heartbeat lifecycle ----------------

test_rejected_send_and_heartbeat() {
  local inbox="$TMP_ROOT/reject.inbox" body out
  write_record "$inbox" 001.msg "do not lose"
  body="$TMP_ROOT/driver-reject.mjs"
  cat > "$body" <<'JS'
fire("agent_start", {});
fire("agent_end", {});
if (sent.length !== 0) throw new Error("rejected send must not record a delivery");
JS
  out=$(DRIVER_BODY="$body" REJECT_SENDS=1 run_listener_driver "$inbox" "$body") || fail "reject driver failed: $out"
  [ -f "$inbox/001.msg" ] || fail "a rejected send must leave the record unhandled"
  body="$TMP_ROOT/driver-heartbeat.mjs"
  cat > "$body" <<'JS'
fire("agent_start", {});
fire("before_agent_start", { prompt: sent[0].content });
fire("agent_end", {});
fire("session_shutdown", {});
JS
  out=$(DRIVER_BODY="$body" run_listener_driver "$inbox" "$body") || fail "heartbeat driver failed: $out"
  [ ! -f "$inbox/.listener" ] || fail "session_shutdown must remove the listener's heartbeat"
  pass "listener leaves a rejected send unhandled and removes its heartbeat at shutdown"
}

# --- 5. Inert without FM_TASK_INBOX -----------------------------------------

test_inert_without_inbox_env() {
  local out
  body="$TMP_ROOT/driver-inert.mjs"
  : > "$body"
  out=$(env -u FM_TASK_INBOX EXT="$LISTENER_EXT" DRIVER_BODY="$body" NODE_NO_WARNINGS=1 node --experimental-strip-types --input-type=module -e '
import { pathToFileURL } from "node:url";
const sent = [];
const pi = { on() {}, sendUserMessage(c) { sent.push(c); } };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
if (sent.length !== 0) throw new Error("inert binding sent");
await import(pathToFileURL(process.env.DRIVER_BODY).href);
' 2>&1) || fail "inert driver failed: $out"
  pass "listener stays inert when FM_TASK_INBOX is unset"
}

# --- 6. Shell-side live check + delivery selection --------------------------

test_shell_live_check_and_delivery_selection() {
  local state="$TMP_ROOT/state" task=t1 dir rec action ring_rc
  mkdir -p "$state"
  dir=$(fm_task_inbox_dir "$state" "$task")
  rec=$(fm_task_inbox_write "$state" "$task" "hello") || fail "inbox record write failed"

  # No heartbeat: ordinary doorbell contract.
  action=$(fm_task_inbox_due_action "$state" "$task")
  case "$action" in quiet|ring*|listener*) ;; *) fail "unexpected due action without listener: $action" ;; esac
  # A plain string liveness probe fails: a scripted impersonation cannot pass.
  printf 'I am alive\n' > "$dir/.listener"
  ! fm_task_inbox_listener_live "$rec" || fail "a malformed heartbeat must not read as live"
  printf 'not-a-pid\t%s\n' "$(date +%s)000" > "$dir/.listener"
  ! fm_task_inbox_listener_live "$rec" || fail "a heartbeat without a numeric pid must not read as live"

  # Live heartbeat from a live pid: listener verdicts, no doorbell.
  printf '%s\t%s\n' "$$" "$(($(date +%s) * 1000))" > "$dir/.listener"
  action=$(fm_task_inbox_due_action "$state" "$task")
  case "$action" in listener*) ;; *) fail "a live listener must win the ladder vote, got: $action" ;; esac
  ring_rc=0
  fm_task_inbox_ring tmux "no-such-pane" "$rec" "label" 2>/dev/null || ring_rc=$?
  [ "$ring_rc" -eq 4 ] || fail "fm_task_inbox_ring must return 4 for a live listener, got $ring_rc"

  # Stale heartbeat: the doorbell path is back (ring proceeds to backend;
  # with no real pane, 2 or 3 is acceptable - never the listener's 4).
  printf '%s\t%s\n' "99999999" "1" > "$dir/.listener"
  touch -t 202001010101 "$dir/.listener" 2>/dev/null || true
  ring_rc=0
  fm_task_inbox_ring tmux "no-such-pane" "$rec" "label" 2>/dev/null || ring_rc=$?
  case "$ring_rc" in 4) fail "a stale heartbeat must not suppress the doorbell" ;; 2|3|0) ;; *) fail "unexpected ring result for stale heartbeat: $ring_rc" ;; esac
  ! fm_task_inbox_listener_live "$rec" || fail "fm_task_inbox_listener_live must reject a stale heartbeat"

  # Fresh heartbeat but dead pid: also not live.
  printf '%s\t%s\n' "99999999" "$(date +%s)000" > "$dir/.listener"
  ! fm_task_inbox_listener_live "$rec" || fail "a dead-pid heartbeat must not read as live"

  # Live heartbeat wins over a pending retry mark too.
  printf '%s\t%s\n' "$$" "$(date +%s)000" > "$dir/.listener"
  fm_task_inbox_mark_retry "$state" "$task" "$rec"
  action=$(fm_task_inbox_due_action "$state" "$task")
  case "$action" in listener*) ;; *) fail "a live listener must spend the retry vote, got: $action" ;; esac
  [ ! -f "$dir/.retry-ring" ] || fail "a live listener must clear a pending retry mark"
  pass "shell side: live heartbeat selects listener delivery; stale or dead-pid falls back to the doorbell"
}

# --- 7. fm-send uses the listener verdict -----------------------------------

test_fm_send_chooses_listener() {
  local home="$TMP_ROOT/home" task=t2 dir out rec
  local state="$home/state" config="$home/config"
  mkdir -p "$state" "$config"
  dir="$state/$task.inbox"
  mkdir -p "$dir/handled"
  # Minimal meta for a tmux target; the pane never exists, so only the
  # listener verdict can take the listener path (4) rather than a pane error.
  cat > "$state/$task.meta" <<EOF
window=fake-window-xyz
backend=tmux
EOF
  printf '%s\t%s\n' "$$" "$(date +%s)000" > "$dir/.listener"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    FM_SEND_NO_BACKEND_CHECKS=1 bash "$ROOT/bin/fm-send.sh" "$task" -- "hello listener" 2>&1) || fail "fm-send failed: $out"
  case "$out" in
    *"no doorbell typed"*"listener"*) ;;
    *) fail "fm-send must report listener delivery for a live listener, got: $out" ;;
  esac
  rec=$(find "$dir" -maxdepth 1 -name '*.msg' -print 2>/dev/null | head -1)
  [ -n "$rec" ] || fail "fm-send must record the steer durably"
  # Without the heartbeat the same send falls back to the ordinary path.
  rm -f "$dir/.listener"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    bash "$ROOT/bin/fm-send.sh" "$task" -- "hello doorbell" 2>&1) || true
  case "$out" in
    *"no doorbell typed"*) fail "an absent listener must NOT take the listener path: $out" ;;
    *) : ;;
  esac
  pass "fm-send reports in-session delivery with a live listener and falls back to the doorbell without one"
}

test_idle_delivery_acks_once
test_mid_turn_steering_and_ack_once
test_restart_no_redelivery
test_rejected_send_and_heartbeat
test_inert_without_inbox_env
test_shell_live_check_and_delivery_selection
test_fm_send_chooses_listener

pass "all fm-inbox-listener tests"
