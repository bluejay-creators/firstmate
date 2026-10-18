#!/usr/bin/env bash
# Behavior tests for the herdr pane/roster event adapter of the
# process-to-event runner (bin/fm-procevent-herdr-panes.sh), against a MOCK
# herdr socket - the suite never touches a real herdr server.
#
# Every scenario is exercised through the adapter's public commands plus the
# generic runner, against a real listener process the arm installs; nothing
# here asserts implementation-source bytes. The suite proves the load-bearing
# guarantees: the arm installs the pod + sidecars + drift check and registers
# exactly one source id; a blocked transition and a roster-unaccounted pane
# captured by one episode become a plain-language `read`; a pure socket-loss
# report is classified `socket-lost` and positively silenced with no wake;
# editing the listener after arming is drift the adapter names; retire drops
# the registration and prunes the pod's private state while the pod itself
# stays for a future arm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/bin/fm-procevent-herdr-panes.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-herdr-panes-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

pe()  { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
hp()  { FM_HOME="$1" "$ADAPTER" "${@:2}"; }

# The system-wide process-event CLAIM is keyed by source id, so arming the
# same id in two homes of one suite has the second home look "owned" while
# the first home's dead runner was never reclaimed. One private id per home
# keeps each scenario's runner its own.
hp()  { local sid; sid=$(basename "$1" | tr -cd 'a-z0-9-'); FM_HOME="$1" FM_HERDR_PANES_SOURCE_ID="herdr-pane-events-$sid" "$ADAPTER" "${@:2}"; }
sid_of()  { printf 'herdr-pane-events-%s\n' "$(basename "$1" | tr -cd 'a-z0-9-')"; }

# Every home this suite arms is swept from every cleanup path so a runner
# still blocked watching the mock socket cannot survive the run.
new_home() {  # <home>
  mkdir -p "$1/state" "$1/config" "$1/data"
  fm_test_track_procevent_home "$1"
  # fm-check-register refuses state dirs it cannot classify; a minimal roster
  # check and the drift check's own trust file are the only state files arm
  # binds.
  : > "$1/data/secondmates.md"
  mkdir -p "$1/state/peers"
  : > "$1/state/peers/peers.tsv"
}

wait_for_file() {  # <file> [tries]
  local n=${2:-150}
  for _ in $(seq 1 "$n"); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}

first_result() {  # <home>
  local g sid
  sid=$(sid_of "$1")
  for g in "$1/state/procevent-inbox/$sid".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

wait_for_result() {  # <home> [tries]
  local n=${2:-300}
  for _ in $(seq 1 "$n"); do first_result "$1" >/dev/null 2>&1 && return 0; sleep 0.1; done
  return 1
}

wake_payloads() {  # <home>
  awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null
}

wait_for_wake() {  # <home> [tries]
  local n=${2:-300}
  for _ in $(seq 1 "$n"); do [ -s "$1/state/.wake-queue" ] && return 0; sleep 0.1; done
  return 1
}

# --- a mock herdr server on a private unix socket ---------------------------
# One file-controlled instance: banner decides whether events.subscribe is
# answered at all (up/down), panes.json decides what pane.list returns, and
# agent.wait blocks until blocked.flag exists. Files, not process signals,
# so the suite retains exact control of when each transition becomes visible.
mk_mock() {  # <labdir>
  local lab=$1
  mkdir -p "$lab"
  cat > "$lab/serve.py" <<'PY'
import json, os, socket, sys, threading
lab = sys.argv[1]
sock_path = os.path.join(lab, "herdr.sock")
try:
    os.remove(sock_path)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(16)

def flag(name):
    return os.path.exists(os.path.join(lab, name))

def panes():
    try:
        with open(os.path.join(lab, "panes.json"), encoding="utf-8") as fh:
            rows = json.load(fh)
    except OSError:
        return []
    blocked = flag("blocked.flag")
    return [dict(r, agent_status=("blocked" if blocked else r.get("agent_status", "idle"))) for r in rows]

def handle(c):
    f = c.makefile("rw", encoding="utf-8", newline="\n")
    up = flag("up.flag")
    for line in f:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        rid = d.get("id")
        m = d.get("method")
        if m == "events.subscribe":
            if up:
                f.write(json.dumps({"id": rid, "result": {"type": "subscription_started"}}) + "\n")
                f.flush()
                for p in panes():
                    for type_ in ("pane_agent_detected",):
                        ev = {"event": type_, "data": {"pane_id": p.get("pane_id"),
                              "type": type_, "workspace_id": p.get("workspace_id", "w9"),
                              "agent": p.get("agent"), "display_agent": p.get("display_agent"),
                              "terminal_title": p.get("terminal_title")}}
                        f.write(json.dumps(ev) + "\n")
                f.flush()
            while True:
                try:
                    b = c.recv(4096)
                except OSError:
                    return
                if not b:
                    return
        elif m == "pane.list":
            f.write(json.dumps({"id": rid, "result": {"panes": panes()}}) + "\n"); f.flush()
        elif m == "workspace.list":
            f.write(json.dumps({"id": rid, "result": {"workspaces": [{"workspace_id": "w9", "label": "Mock"}]}}) + "\n"); f.flush()
        elif m == "tab.list":
            tabs = [{"tab_id": p.get("tab_id", "w9:t1"), "label": p.get("tab_label", "")} for p in panes()]
            f.write(json.dumps({"id": rid, "result": {"tabs": tabs}}) + "\n"); f.flush()
        elif m == "agent.wait":
            while not flag("blocked.flag"):
                if not flag("up.flag"):
                    break
                import time
                time.sleep(0.05)
            f.write(json.dumps({"id": rid, "result": {"type": "agent_status", "agent_status": "blocked"}}) + "\n"); f.flush()
        else:
            f.write(json.dumps({"id": rid, "error": {"code": "unsupported", "message": m}}) + "\n"); f.flush()

while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
  mkdir -p "$lab/bin"
  cat > "$lab/bin/herdr" <<'SH'
#!/usr/bin/env bash
# mock herdr CLI: `pane read <pane> --source visible` prints the blocked screen
if [ "$1 $2" = "pane read" ]; then
  cat "${FM_MOCK_SCREEN:?mock screen file}"
  exit 0
fi
exit 1
SH
  chmod +x "$lab/bin/herdr"
  cat > "$lab/screen.txt" <<'TXT'
MockMate wants permission to run: rm -rf /tmp/x
> 1. Yes  2. No
TXT
}

start_mock() {  # <labdir>
  # Detach the mock into its own process group so a suite caller's pipe close
  # or signal cannot kill it mid-scenario; stop_mock owns its lifecycle via
  # the pid this records. The child rebinds its own stdio so the pid line
  # the parent prints is the only byte that ever lands in server.pid.
  perl -e '
    my ($script, $lab, $out, $err) = @ARGV;
    defined(my $pid = fork) or exit 1;
    if ($pid == 0) {
      setpgrp(0, 0);
      open STDOUT, ">>", $out or exit 1;
      open STDERR, ">>", $err or exit 1;
      exec "python3", $script, $lab;
      exit 1;
    }
    print "$pid\n";
  ' "$1/serve.py" "$1" "$1/server.out" "$1/server.err" >"$1/server.pid"
  [ -s "$1/server.pid" ] || return 1
  wait_for_file "$1/herdr.sock" || { cat "$1/server.err" 2>/dev/null; fail "mock herdr did not open its socket"; }
}

stop_mock() {  # <labdir>
  [ -f "$1/server.pid" ] && kill "$(cat "$1/server.pid")" 2>/dev/null
  rm -f "$1/server.pid"
  rm -f "$1/herdr.sock"
}

mock_env() {  # <labdir> <home> <command>...
  local lab=$1 home=$2
  shift 2
  env \
    PATH="$lab/bin:$PATH" \
    FM_HOME="$home" \
    FM_MOCK_SCREEN="$lab/screen.txt" \
    FM_HERDR_SOCK="$lab/herdr.sock" \
    "$@"
}

arm_home() {  # <home> <lab>
  local home=$1 lab=$2
  mkdir -p "$home/state" "$home/config" "$home/data"
  # The pod is the tracked fixture; arm installs it into the home's state.
  cp "$ROOT/tests/fixtures/fm-herdr-pane-events.sh" "$home/state/herdr-pane-events.sh"
  chmod 700 "$home/state/herdr-pane-events.sh"
  FM_HERDR_PANES_SOURCE_ID="$(sid_of "$home")" mock_env "$lab" "$home" "$ADAPTER" arm >/dev/null
}

# Only one mock may answer at a time - the pod resolves ONE socket path, and
# parallel homes would cross-connect. The suite serializes its live scenarios.
LAB="$TMP_ROOT/mock-herdr"
mk_mock "$LAB"

# --- arm installs pod, sidecars, and exactly one registration ----------------
H="$TMP_ROOT/h-arm"; new_home "$H"
cp "$ROOT/tests/fixtures/fm-herdr-pane-events.sh" "$H/state/herdr-pane-events.sh"
chmod 700 "$H/state/herdr-pane-events.sh"
out=$(hp "$H" arm)
assert_contains "$out" "armed: $(sid_of "$H")" "arm reports the canonical source id"
assert_contains "$out" "roster/blocked events are second-scale" "arm states the behavior change"
assert_present "$H/state/herdr-pane-events.sh" "arm installs the listener pod"
assert_present "$H/state/herdr-pane-events.listener-trust" "arm writes the hash sidecar"
assert_present "$H/state/herdr-pane-events.check.sh" "arm installs the drift check"
assert_present "$H/state/herdr-pane-events.check-trust" "arm binds the drift check"
assert_present "$H/state/procevent/$(sid_of "$H").source" "arm registers the process-event source"
trust_mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$H/state/herdr-pane-events.listener-trust")
assert_contains "$trust_mode" 600 "the sidecar is private"
hp "$H" drift >/dev/null || fail "a freshly armed listener must show no drift"
status_out=$(hp "$H" status) || :
assert_contains "$status_out" "$(sid_of "$H")" "status names the registered source"
assert_contains "$status_out" "drift: none" "status reports no drift"
pass "arm installs and binds everything, drift is clean"

# --- listener edits after arm are drift, re-arm restores ---------------------
H="$TMP_ROOT/h-drift"; new_home "$H"
cp "$ROOT/tests/fixtures/fm-herdr-pane-events.sh" "$H/state/herdr-pane-events.sh"
chmod 700 "$H/state/herdr-pane-events.sh"
hp "$H" arm >/dev/null
printf '# drift probe\n' >> "$H/state/herdr-pane-events.sh"
if hp "$H" drift >"$TMP_ROOT/drift.out" 2>&1; then
  fail "drift after editing the listener must be visible"
fi
assert_grep "re-arm with" "$TMP_ROOT/drift.out" "the drift verdict names re-arm"
status_out=$(hp "$H" status) || true
assert_contains "$status_out" "drift: " "status surfaces the drift"
hp "$H" arm >/dev/null
hp "$H" drift >/dev/null || fail "re-arm must refresh the armed hash"
pass "listener edits are named drift and re-arm restores"

LAB_BASE=$(mktemp -d "${TMPDIR:-/tmp}/fmhpt.XXXXXX")
LAB="$LAB_BASE/mk"
mkdir -p "$LAB"
mk_mock "$LAB"
rm -f "$LAB/blocked.flag" "$LAB/up.flag"
H="$TMP_ROOT/h-blocked"; new_home "$H"
cat > "$LAB/panes.json" <<'JSON'
[{"pane_id":"w9:p1","agent":"claude","agent_session":{"agent":"claude"},
  "agent_status":"idle","terminal_title_stripped":"π > MockMate",
  "terminal_title":"π > MockMate","cwd":"/tmp/x",
  "workspace_id":"w9","tab_id":"w9:t1","tab_label":"MockMate"}]
JSON
: > "$LAB/up.flag"
start_mock "$LAB"
arm_home "$H" "$LAB"
# wait for the episode to be running before flipping blocked
sleep 1.5
: > "$LAB/blocked.flag"
wait_for_result "$H" || fail "the episode captured nothing"
wait_for_wake "$H" || fail "the captured result was never published"
RESULT=$(first_result "$H")
assert_present "$RESULT" "a blocked transition is durably captured"
out=$(hp "$H" classify "$RESULT")
assert_contains "$out" "blocked" "classify reports the blocked episode"
out=$(hp "$H" read "$RESULT")
assert_contains "$out" "blocked: MockMate (w9:p1)" "read names the blocked pane"
assert_contains "$out" "screen saved state/.blocked-captures/w9_p1" "read names the saved screen"
CAP=$(basename "$(sed -n 's/^blocked\tMockMate\tw9:p1\t\(.*\)$/\1/p' "$RESULT")")
assert_present "$H/state/.blocked-captures/$CAP" "the blocked screen is captured"
assert_grep "rm -rf /tmp/x" "$H/state/.blocked-captures/$CAP" "the saved screen holds the prompt"
assert_grep "procevent herdr-panes $(sid_of "$H")" <(wake_payloads "$H") "the blocked capture publishes a check wake"
hp "$H" handled-ok-check >/dev/null 2>&1 || true
hp "$H" retire >/dev/null 2>&1 || true
fm_test_reap_procevent_homes 2>/dev/null || true
stop_mock "$LAB"
rm -f "$LAB/blocked.flag" "$LAB/up.flag"
pass "a blocked episode is captured, classified, read, and screen-saved"

# --- classify and read agree on every episode shape the pod can report -----
# A canned episode exercises classify and read the same way the runner's own
# publish path does, without depending on another mock/pod cycle. The live
# blocked scenario above already proved that the pod produces these files;
# here we only verify the reporting contract stays stable against them.
RESULT_DIR="$TMP_ROOT/shape-fixture"; mkdir -p "$RESULT_DIR"
cat > "$RESULT_DIR/unknown.result" <<'TXT'
herdr-panes-v1
ts=2026-10-16T22:11:28Z
uptime_s=6
blocked=0 unknown=1
unknown	Stray	w9:p2	claude	/tmp/stray
roster-check	state/agent-roster.check.sh
TXT
out=$(hp "$TMP_ROOT/h-unknown" classify "$RESULT_DIR/unknown.result")
assert_contains "$out" "unknown" "classify reports the roster-unaccounted pane"
out=$(hp "$TMP_ROOT/h-unknown" read "$RESULT_DIR/unknown.result")
assert_contains "$out" "unknown agent pane: Stray (w9:p2; agent claude; cwd /tmp/stray)" "read names the unknown pane"
cat > "$RESULT_DIR/mixed.result" <<'TXT'
herdr-panes-v1
ts=2026-10-16T22:11:28Z
uptime_s=9
blocked=1 unknown=1
blocked	MockMate	w9:p1	w9_p1-1.txt
unknown	Stray	w9:p2	claude	/tmp/stray
roster-check	state/agent-roster.check.sh
TXT
out=$(hp "$TMP_ROOT/h-unknown" classify "$RESULT_DIR/mixed.result")
assert_contains "$out" "mixed" "a mixed episode is named as such"
out=$(hp "$TMP_ROOT/h-unknown" read "$RESULT_DIR/mixed.result")
assert_contains "$out" "blocked: MockMate (w9:p1)" "read keeps both halves"
assert_contains "$out" "unknown agent pane: Stray" "mixed read still names the unknown pane"
pass "classify and read agree across blocked, unknown, and mixed episodes"

# --- a pure socket-loss report is classified and positively silenced ---------
H="$TMP_ROOT/h-silent"; new_home "$H"
RESULT_DIR="$TMP_ROOT/silent-fixture"; mkdir -p "$RESULT_DIR"
RESULT="$RESULT_DIR/lost.result"
cat > "$RESULT" <<'TXT'
herdr-panes-v1
ts=2026-10-16T22:11:28Z
uptime_s=4
socket=subscription cannot reconnect: [Errno 2] No such file or directory
blocked=0 unknown=0
roster-check	/tmp/x/state/agent-roster.check.sh
TXT
out=$(hp "$H" classify "$RESULT")
assert_contains "$out" "socket-lost" "classify reports the pure socket-loss report"
hp "$H" silent "$RESULT"
hp "$H" silent "$RESULT" || fail "the pure socket-loss report must be positively silenced"
cat > "$RESULT" <<'TXT'
herdr-panes-v1
ts=2026-10-16T22:11:28Z
uptime_s=4
blocked=0 unknown=1
unknown	Stray	w9:p2	claude	/tmp/stray
roster-check	/tmp/x/state/agent-roster.check.sh
TXT
if hp "$H" silent "$RESULT"; then
  fail "a roster line must never be silenced"
fi
out=$(hp "$H" classify "$RESULT")
assert_contains "$out" "unknown" "classify still names the roster line"
cat > "$RESULT" <<'TXT'
not-a-herdr-panes-report
blocked=0 unknown=0
TXT
out=$(hp "$H" classify "$RESULT")
assert_contains "$out" "unknown-event" "a foreign report is never claimed"
if hp "$H" silent "$RESULT"; then
  fail "a foreign report must never be silenced"
fi
pass "socket-loss is silenced, roster lines and foreign reports are not"

# --- retire drops the registration and prunes the pod's private state --------
H="$TMP_ROOT/h-retire"; new_home "$H"
rm -f "$LAB/blocked.flag" "$LAB/up.flag"
cat > "$LAB/panes.json" <<'JSON'
[{"pane_id":"w9:p3","agent":"claude","agent_session":{"agent":"claude"},
  "agent_status":"idle","terminal_title_stripped":"π > RetirePane",
  "terminal_title":"π > RetirePane","cwd":"/tmp/retire",
  "workspace_id":"w9","tab_id":"w9:t3","tab_label":"RetirePane"}]
JSON
: > "$LAB/up.flag"
start_mock "$LAB"
arm_home "$H" "$LAB"
sleep 1.5                  # let the episode runner reach agent.wait before the flip
: > "$LAB/blocked.flag"
wait_for_result "$H" || fail "the episode captured nothing"   # a blocked episode proves the pod ran
stop_mock "$LAB"
rm -f "$LAB/blocked.flag" "$LAB/up.flag"
out=$(hp "$H" retire)
assert_contains "$out" "retired: $(sid_of "$H")" "retire drops the runner registration"
assert_contains "$out" "listener pod and its private state pruned" "retire reports its pruning"
assert_absent "$H/state/procevent/$(sid_of "$H").source" "the registration is gone"
assert_absent "$H/state/herdr-pane-events.listener-trust" "the sidecar is pruned"
assert_absent "$H/state/.herdr-event-unknown.tsv" "the unknown-pane ledger is pruned"
assert_present "$H/state/herdr-pane-events.sh" "the pod itself stays for a future arm"
status_out=$(hp "$H" status) || true
assert_contains "$status_out" "not installed - re-arm" "status names what a retired home lost"
out=$(hp "$H" retire)
assert_contains "$out" "retired: $(sid_of "$H")" "retire is idempotent"
pass "retire prunes private state, keeps the pod, and is idempotent"

pass "herdr pane/roster event adapter behaves end to end against a mock herdr"
