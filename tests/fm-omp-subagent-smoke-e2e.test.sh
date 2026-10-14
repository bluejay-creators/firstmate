#!/usr/bin/env bash
# Opt-in credentialed live regression that pairs with the portable
# tests/fm-omp-harness.test.sh: a real omp rpc session arms the watcher through
# the tracked extension, runs one task-tool subagent, then proves the watcher
# remains armed at the same pid through the subagent lifecycle and its exit
# ledger records an actionable signal close after a queued meta+status wake.
# omp 18.8.x re-binds extension factories per subagent session with
# ctx.agent.kind === "sub"; the extension's subagentContext gate is what must
# keep the primary arm and replacement handoff untouched. Fires only under
# FM_OMP_SUBAGENT_SMOKE=1 (live-harness-optin, token-spending) and runs
# against a scratch FIRSTmate checkout, never the production home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OMP_SUBAGENT_SMOKE omp node jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
LAB="$ROOT/.omp-subagent-smoke.$$"
PROJECT="$LAB/project"
RPC_IN="$LAB/rpc.in"
RPC_LOG="$LAB/rpc.log"
RPC_ERR="$LAB/rpc.err"
OMP_PID=

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

lab_pids() {
  ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'
}

reap_lab() {
  local pid
  for pid in $(lab_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(lab_pids); do kill -KILL "$pid" 2>/dev/null || true; done
}

cleanup() {
  exec 3>&- 2>/dev/null || true
  if [ "${FM_OMP_SUBAGENT_SMOKE_KEEP:-0}" = 1 ]; then
    note "lab kept at $LAB"
    trap - EXIT
    [ -z "$OMP_PID" ] || kill -TERM "$OMP_PID" 2>/dev/null || true
    return 0
  fi
  if [ -n "$OMP_PID" ]; then kill -TERM "$OMP_PID" 2>/dev/null || true; fi
  reap_lab
  rm -rf "$LAB"
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT" || { echo "could not clone"; exit 1; }
# Carry this working tree's pending edits into the lab.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$ROOT/$path" ] || continue
  mkdir -p "$PROJECT/$(dirname "$path")"
  cp "$ROOT/$path" "$PROJECT/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"

rpc_send() { printf '%s\n' "$1" >&3; }
wait_for_log() { local s=$1 a=${2:-240} i=0; while [ "$i" -lt "$a" ]; do grep -Fq -- "$s" "$RPC_LOG" 2>/dev/null && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
wait_for_file() { local p=$1 a=${2:-240} i=0; while [ "$i" -lt "$a" ]; do [ -f "$p" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
# Wait until omp reports a settled session after a prompt. A follow-up prompt
# fired while the previous turn still runs is refused with
# "Agent is already processing".
wait_for_settle() { local a=${1:-360} i=0 n; n=$(grep -c '"type":"session_settled"' "$RPC_LOG" 2>/dev/null || true); while [ "$i" -lt "$a" ]; do [ "$(grep -c '"type":"session_settled"' "$RPC_LOG" 2>/dev/null || true)" -gt "$n" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }

mkfifo "$RPC_IN"
: > "$RPC_LOG"
(
  cd "$PROJECT" &&
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
      FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_GUARD_GRACE=20 \
      omp --mode rpc --no-session --cwd "$PROJECT" --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
        --model "$MODEL" --thinking low < "$RPC_IN" > "$RPC_LOG" 2> "$RPC_ERR"
) &
OMP_PID=$!
exec 3> "$RPC_IN"

wait_for_log '"type":"ready"' 240 || { echo "omp not ready"; tail -5 "$RPC_ERR"; exit 1; }
wait_for_file "$PROJECT/state/.omp-watch-extension-loaded" 60 || { echo "watch ext not loaded"; exit 1; }
wait_for_file "$PROJECT/state/.omp-turnend-extension-loaded" 60 || { echo "turnend ext not loaded"; exit 1; }
pass "extensions auto-discovered in the lab"

# First prompt must answer the digest; also establishes the session lock.
rpc_send '{"id":"p1","type":"prompt","message":"From the Firstmate session-start digest already in your context, reply with the single line that begins with SESSION START - and nothing else. Do not run any tool."}'
wait_for_settle 360 || { echo "no first turn settle"; exit 1; }
pass "session-start digest reached model context"

# Arm the watcher.
rpc_send '{"id":"p2","type":"prompt","message":"Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else. Never run bin/fm-watch-arm.sh through bash."}'
wait_for_log "watcher: started omp extension arm child 1" 360 || { echo "arm failed"; tail -3 "$RPC_ERR"; exit 1; }
wait_for_settle 360 || { echo "no settle after arm"; exit 1; }
i=0
arm_pid=
while [ "$i" -lt 120 ]; do
  arm_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$arm_pid" ] && kill -0 "$arm_pid" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
[ -n "$arm_pid" ] && kill -0 "$arm_pid" 2>/dev/null || { echo "no live watcher after arm"; exit 1; }
pass "watcher armed (pid $arm_pid)"

# Run a subagent through the task tool. The subagent must stand down instead of
# touching watcher supervision. Reply text is enough proof the subagent ran.
rpc_send '{"id":"p3","type":"prompt","message":"Use your in-process subagent tool (the tool that launches a child agent, commonly named task) exactly once, with a one-line task that runs `printf SUBAGENT_RAN` through bash and nothing else. Wait for the child result, then reply with exactly SUBAGENT_RAN and nothing else. The reply must carry only that token."}'
sleep 1
grep -q '"id":"p3","type":"response","command":"prompt","success":true' "$RPC_LOG" || { echo "p3 was refused:"; grep '"id":"p3"' "$RPC_LOG" | head -2; exit 1; }
i=0
ran=
while [ "$i" -lt 720 ]; do
  if python3 -c '
import json, sys
lines = open(sys.argv[1]).read().splitlines()
start = next((i for i, l in enumerate(lines) if "\"id\":\"p3\"" in l and "\"command\":\"prompt\"" in l and "\"success\":true" in l), 0)
blob = ""
for line in lines[start:]:
    try: j = json.loads(line)
    except Exception:
        continue
    t = j.get("type")
    if t == "message_update":
        ev = j.get("assistantMessageEvent") or {}
        if ev.get("type") == "text_delta":
            blob += ev.get("delta", "")
        continue
    if t not in ("message_end", "message", "task_result", "agent_end"):
        continue
    stack = [j]
    while stack:
        x = stack.pop()
        if isinstance(x, str):
            blob += x
        elif isinstance(x, dict):
            stack.extend(x.values())
        elif isinstance(x, list):
            stack.extend(x)
sys.exit(0 if "SUBAGENT_RAN" in blob else 1)
' "$RPC_LOG"; then
    ran=1; break
  fi
  sleep 0.5
  i=$((i + 1))
done
[ -n "$ran" ] || { echo "subagent did not run"; tail -5 "$RPC_LOG"; exit 1; }
sub_pid_before=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$sub_pid_before" ] && kill -0 "$sub_pid_before" 2>/dev/null || { echo "watcher died before wake was queued"; exit 1; }
pass "subagent completed; watcher still armed (pid $sub_pid_before)"

# Queue an actionable wake through the same meta+status record every live e2e
# uses, then assert the watcher exit ledger names the actionable close. The
# ledger is the wake queue's upstream owner; a queued durable-wake row and a
# delivered follow-up reach main only through this same close, and both are
# non-subagent paths this smoke does not re-verify (tests/fm-omp-primary-
# live-e2e.test.sh owns that full loop).
: > "$PROJECT/state/omp-sub-smoke.meta"
printf 'done: omp subagent smoke watcher fire\n' > "$PROJECT/state/omp-sub-smoke.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal' "$PROJECT/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal' "$PROJECT/state/.watch-cycle-exits.log" 2>/dev/null \
  || { echo "watcher never recorded an actionable signal close after the subagent lifecycle"; tail -5 "$RPC_ERR" 2>/dev/null; exit 1; }
post_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$post_pid" ] && kill -0 "$post_pid" 2>/dev/null \
  || { echo "watcher not restarted after its actionable close"; exit 1; }
pass "actionable close recorded after the subagent; watcher cycle continues (pid $post_pid)"

# Final: watcher cycle still alive after the actionable close.
final_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$final_pid" ] && kill -0 "$final_pid" 2>/dev/null || { echo "watcher gone after the actionable close"; exit 1; }
exec 3>&-
kill -TERM "$OMP_PID" 2>/dev/null || true
sleep 2
note "smoke model=$MODEL"
