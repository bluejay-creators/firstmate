#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - the portable regression for the omp (Oh My Pi)
# adapter: detection, session-lock identity, tmux liveness classification, the
# spawn launch line and worker posture overlay, pre-launch model validation, the
# per-task busy-state extension, the extension supervision model and ownership
# proof, and the two tracked primary extensions driven over a fake omp API.
#
# omp's identity, launch, and lifecycle checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, a settings schema,
# an extension event). This suite pins the LOGIC with real processes, a fake
# omp binary, and a plain Node host, so CI enforces it with no omp installed;
# FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh is the live guard that
# catches vendor drift against a real omp. Neither replaces the other.
#
# The load-bearing contracts:
#   1. omp publishes no marker; the anchored process name `omp` is the ancestry
#      evidence, and ompd/comp never identify.
#   2. FM_OMP_HARNESS=omp is a precedence override that needs a real omp
#      ancestor: it beats an inherited CLAUDECODE under omp and is inert when it
#      leaks into a worker whose ancestry holds no omp.
#   3. Every omp launch clears foreign markers, carries the tracked posture
#      overlay, --auto-approve, --cwd, and (for a crewmate) one -e pointing at
#      state/<id>.omp-ext.ts; a secondmate launch names that same busy -e and
#      nothing else, leaving its primary extensions to auto-discovery.
#   4. A <provider>/<id> model is validated only when `omp models --json` lists
#      that provider; an unlisted provider passes through with a notice.
#   5. Busy state: agent_start is busy, agent_end with willContinue stays busy,
#      a plain agent_end is idle, turn_end is a notification only.
#   6. The turn-end guard extension compels one continuation on exit 2 and
#      stands down when the payload already carries stop_hook_active.
#   7. The watch extension arms through fm_watch_arm_omp and delivers an
#      actionable close as one follow-up.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
export NODE_NO_WARNINGS=1

# A process whose kernel-recorded identity is the bare name `omp`: a SYMLINK to
# the system shell, never a copy (a copied platform binary fails macOS code
# signing). macOS reports the symlink name through `ps -o comm=`, which is the
# exact signal under test. Every `-c` body below ends in a no-op so bash does
# not exec-optimize the single command away and replace the named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in omp ompd comp; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# --- 1. Detection --------------------------------------------------------------

test_detection_anchored_name_and_marker_precedence() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "a process named omp must detect as omp, got '$out'"
  for decoy in ompd comp; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$bin/$decoy" -c '"$1"; :' _ "$HARNESS")
    [ "$out" != omp ] || fail "'$decoy' merely contains omp and must not detect as omp"
  done
  # The marker beats an inherited CLAUDECODE only under a real omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS under an omp ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # ...and is inert when it leaks into a worker with no omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked FM_OMP_HARNESS without an omp ancestor must not relabel a claude worker, got '$out'"
  pass "fm-harness: omp detects by its anchored name; the marker is a precedence override that needs real omp ancestry"
}

test_lock_identity_and_liveness_classification() {
  fm_harness_process_matches omp '' || fail "session-lock identity must accept the exact omp name"
  fm_harness_process_matches /usr/local/bin/omp 'omp --cwd /x' || fail "session-lock identity must accept an omp path"
  ! fm_harness_process_matches ompd '' || fail "session-lock identity must not accept ompd"
  ! fm_harness_process_matches comp '' || fail "session-lock identity must not accept comp"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_agent_process_classify_name omp)" = agent ] || fail "tmux liveness must classify omp as an agent"
  [ "$(fm_agent_process_classify_name /opt/omp/bin/omp)" = agent ] || fail "tmux liveness must classify an omp path as an agent"
  [ "$(fm_agent_process_classify_name ompd)" != agent ] || fail "tmux liveness must not classify ompd as an agent"
  [ "$(fm_agent_process_classify_name comp)" != agent ] || fail "tmux liveness must not classify comp as an agent"
  pass "session lock and tmux liveness: omp is anchored, decoys stay out"
}

# --- 2. Launch ---------------------------------------------------------------

# A fake omp that answers `models --json` with a two-provider catalog and exits
# 0 for everything else (the launch itself is only recorded by the fake tmux).
make_fake_omp() {  # <fakebin>
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"},{"provider":"ollama","id":"qwen3:8b","selector":"ollama/qwen3:8b"}]}'
    ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  make_fake_omp "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

test_spawn_launch_line_and_worker_wiring() {
  local rec id=omp-launch-q1 out status launch state
  rec=$(make_spawn_case launch omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra --effort medium)
  status=$?
  expect_code 0 "$status" "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  state="$HOME_DIR/state"
  assert_grep "harness=omp" "$state/$id.meta" "meta missing harness=omp"
  assert_grep "model=openai-codex/gpt-6-astra" "$state/$id.meta" "meta missing the pinned model"
  assert_grep "effort=medium" "$state/$id.meta" "meta missing the pinned effort"
  assert_present "$state/$id.omp-ext.ts" "omp spawn did not write the per-task extension"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$FAKEBIN_DIR/omp'" \
    "omp launch did not clear foreign markers and establish its own at the launch boundary"
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$WT_DIR'" \
    "omp launch did not carry the tracked posture overlay, --auto-approve, and the pinned working directory"
  assert_contains "$launch" "--model 'openai-codex/gpt-6-astra' --thinking 'medium' -e '$state/$id.omp-ext.ts'" \
    "omp launch did not pass the model, thinking level, and the state-resident worker extension"
  assert_contains "$launch" "encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md'" "omp launch lost the canonical typed launch-brief envelope"
  case "$launch" in
    *"-e '$state/$id.omp-ext.ts' \"\$("*) ;;
    *) fail "omp launch must keep exactly one positional brief after the extension flag: $launch" ;;
  esac
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] \
    || fail "omp spawn must seed the busy-state contract"
  pass "fm-spawn: the omp launch line clears markers, pins posture, and wires the state-resident extension"
}

test_spawn_model_validation_scoped_to_listed_providers() {
  local rec id out status
  rec=$(make_spawn_case model-refused omp omp-model-refused-q2)
  read_case_record "$rec"
  id=omp-model-refused-q2
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-nope)
  status=$?
  expect_code 1 "$status" "a model absent from a listed provider must refuse"
  assert_contains "$out" "is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the listing evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case model-bridge omp omp-model-bridge-q3)
  read_case_record "$rec"
  id=omp-model-bridge-q3
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model claude-bridge/claude-opus-4-8)
  status=$?
  expect_code 0 "$status" "an extension-registered provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "pass-through did not state its reason"
  assert_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-bridge/claude-opus-4-8'" "pass-through model did not reach the launch line"

  rec=$(make_spawn_case model-fuzzy omp omp-model-fuzzy-q4)
  read_case_record "$rec"
  id=omp-model-fuzzy-q4
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model astra)
  status=$?
  expect_code 0 "$status" "a bare fuzzy pattern is omp's own matcher's job: $out"
  pass "fm-spawn: omp model validation is scoped to providers the listing can prove"
}

test_secondmate_launch_relies_on_discovery() {
  # A seeded secondmate home, launched for real through fm-spawn on omp: the
  # launch must carry the posture overlay and pin --cwd to the home. Its only
  # -e is the state-resident busy extension: omp auto-discovers the home's
  # tracked .omp/extensions, and a file named both ways loads twice.
  local world home fakebin launchlog out status launch
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  # FM_BACKEND=tmux pins the fake tmux even where the developer shell carries a
  # live Herdr environment; without it auto-detection would spawn a real pane.
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" omp --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "omp secondmate spawn should succeed: $out"
  assert_grep "harness=omp" "$world/home/state/sm.meta" "secondmate meta missing harness=omp"
  launch=$(cat "$launchlog")
  [ "$(printf '%s\n' "$launch" | grep -o ' -e ' | wc -l | tr -d ' ')" = 1 ] \
    || fail "an omp secondmate launch must name exactly one -e: omp auto-discovers .omp/extensions and a file named both ways loads twice: $launch"
  assert_contains "$launch" "-e '$world/home/state/sm.omp-ext.ts'" "an omp secondmate launch must load the parent-home busy extension: $launch"
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$home'" "secondmate launch lost the posture overlay or the pinned home directory: $launch"
  assert_contains "$launch" "FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$fakebin/omp'" "secondmate launch lost the omp marker or executable"
  assert_contains "$launch" "FM_SUPERVISION_MODEL=extension" "an omp secondmate must run the extension supervision model"
  assert_present "$world/home/state/sm.omp-ext.ts" "a secondmate must receive the per-task busy extension"
  pass "fm-spawn: a real omp secondmate launch loads only the busy -e and auto-discovers its primary extensions"
}

test_secondmate_config_pinned_model_is_validated() {
  # The same seeded secondmate home, but the harness and model come from the
  # primary's config/secondmate-harness rather than the command line: the
  # durable pin lands on MODEL after the harness case arm, so an unlisted id
  # under a listed provider must still be refused before endpoint creation.
  local world home fakebin launchlog out status
  world="$TMP_ROOT/secondmate-config-model"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  printf 'omp openai-codex/gpt-nope\n' > "$world/home/config/secondmate-harness"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" --secondmate 2>&1)
  status=$?
  expect_code 1 "$status" "a config-pinned unlisted omp model must refuse the secondmate spawn: $out"
  assert_contains "$out" "omp model 'openai-codex/gpt-nope' is not listed by 'omp models --json' although provider 'openai-codex' is" \
    "the refusal did not name the config-pinned model under its listed provider: $out"
  assert_absent "$world/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$launchlog" ] || fail "a refused secondmate spawn must record no launch: $(cat "$launchlog")"
  pass "fm-spawn: the config/secondmate-harness model pin is validated against the omp catalog before launch"
}

# --- 3. Busy state -------------------------------------------------------------

drive_omp_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
// ctx.isIdle() reads false at a natural TUI agent_end on omp; the extension
// must go idle on a plain agent_end regardless of it.
const ctx = { isIdle: () => false };
switch (process.env.MODE) {
  case "handlers": console.log(Object.keys(handlers).sort().join(" ")); break;
  case "agent-start": await handlers["agent_start"]({ type: "agent_start" }, ctx); break;
  case "end-continuing": await handlers["agent_end"]({ type: "agent_end", willContinue: true }, ctx); break;
  case "end-final": await handlers["agent_end"]({ type: "agent_end" }, ctx); break;
  case "turn-end": await handlers["turn_end"]({ type: "turn_end", turnIndex: 0 }, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_busy_extension_lifecycle() {
  local rec id=omp-busy-q5 out state ext
  rec=$(make_spawn_case busy omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"
  out=$(drive_omp_ext "$ext" handlers) || fail "handler listing failed: $out"
  case " $out " in
    *" agent_settled "*) fail "the omp extension must not listen for agent_settled (omp has no such event)" ;;
  esac
  for handler in agent_start agent_end turn_end; do
    case " $out " in
      *" $handler "*) ;;
      *) fail "the omp extension must register $handler, got '$out'" ;;
    esac
  done

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext'"

  out=$(drive_omp_ext "$ext" end-continuing) || fail "continuing agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_end with willContinue must stay busy (a session_stop continuation is coming)"

  out=$(drive_omp_ext "$ext" end-final) || fail "final agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "idle omp-ext" ] || fail "a plain agent_end must classify 'idle omp-ext'"

  # A record from another harness's writer is never trusted for omp.
  fm_busy_source_trusted omp pi-ext && fail "omp must not trust the Pi extension's records"
  fm_busy_source_trusted omp omp-ext || fail "omp must trust its own extension's records"
  pass "omp extension: agent_start busy, willContinue stays busy, plain agent_end idle, turn_end a notification"
}

# --- 4. Control, composer, supervision model -----------------------------------

test_control_composer_and_model_tables() {
  [ "$(fm_control_exit_command omp)" = /quit ] || fail "omp exit command must be /quit"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp leaves its composer empty and needs no clear key"
  [ "$(fm_control_harness_wiring_paths omp /wt /st id1)" = "/st/id1.omp-ext.ts" ] || fail "omp wiring path must be the state-resident extension"
  printf 'Working…\n' | fm_busy_lines_match omp || fail "omp busy regex must match the TUI ellipsis form"
  printf 'Working...\n' | fm_busy_lines_match omp && fail "omp busy regex must not match the three-dot form no supervised pane renders"
  printf ' ⠧ 11s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the braille spinner plus elapsed cell"
  printf ' ⣾ 3s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the status-set spinner frames, not only the activity set"
  printf ' 󰵗  · gpt-6-astra · 36.7%%/41K\n' | fm_busy_lines_match omp && fail "an idle omp status row must not read busy"
  printf 'esc to interrupt\n' | fm_busy_lines_match omp && fail "omp must not borrow Claude's footer"
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named-model")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_SUPERVISION_MODEL \
    "$bin/omp" -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = extension ] || fail "an omp primary must run the extension supervision model, got '$out'"
  pass "control, composer, and supervision-model tables carry omp's verified values"
}

# --- 5. Ownership proof --------------------------------------------------------

# Stand up the durable evidence a live omp session leaves behind: both tracked
# extensions under the case root and one marker per extension recording that
# build plus the session pid in state/.lock.
record_omp_session() {  # <root> <home> <session-pid> [omit] [drift]
  local root=$1 home=$2 session_pid=$3 omit=${4:-} drift=${5:-} pair source marker version
  mkdir -p "$root/.omp/extensions" "$home/state"
  for pair in \
    "fm-primary-omp-watch.ts:.omp-watch-extension-loaded:watch" \
    "fm-primary-turnend-guard.ts:.omp-turnend-extension-loaded:turnend"; do
    source=${pair%%:*}
    marker=${pair#*:}; marker=${marker%%:*}
    printf '// %s\n' "${pair##*:}" > "$root/.omp/extensions/$source"
    [ "$omit" = "${pair##*:}" ] && continue
    if [ "$drift" = "${pair##*:}" ]; then
      version="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    else
      version=$(bash -c '. "$1"; fm_pi_extension_version "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$root/.omp/extensions/$source") || return 1
    fi
    printf '%s\n%s\n' "$version" "$session_pid" > "$home/state/$marker"
  done
  printf '%s\n' "$session_pid" > "$home/state/.lock"
}

owns() {  # <root> <home>
  bash -c '. "$1"; fm_omp_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$2/state" "$1"
}

test_ownership_proof_is_omp_keyed() {
  local root home pid
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own/root"; home="$TMP_ROOT/own/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the omp session"
  owns "$root" "$home" || fail "a live session that loaded both omp extensions must own supervision"
  bash -c '. "$1"; fm_pi_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    && fail "omp markers must never satisfy the Pi proof"
  bash -c '. "$1"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    || fail "the shared extension proof must accept the omp pair"

  root="$TMP_ROOT/own-drift/root"; home="$TMP_ROOT/own-drift/home"
  record_omp_session "$root" "$home" "$pid" "" watch || fail "could not record the drifted session"
  owns "$root" "$home" && fail "a session that loaded an older watch build must not own supervision"
  root="$TMP_ROOT/own-omit/root"; home="$TMP_ROOT/own-omit/home"
  record_omp_session "$root" "$home" "$pid" turnend || fail "could not record the partial session"
  owns "$root" "$home" && fail "a session missing the turn-end guard extension must not own supervision"
  root="$TMP_ROOT/own-dead/root"; home="$TMP_ROOT/own-dead/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the dead session"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  owns "$root" "$home" && fail "a dead session must not own supervision"

  # The pull-guard verdict tolerates the extension's own hand-off only with the proof.
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own-verdict/root"; home="$TMP_ROOT/own-verdict/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the verdict session"
  touch "$home/state/.last-watcher-beat"
  local verdict
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "${verdict%% *}" = true ] || fail "an unheld lock with a fresh beacon and the omp proof must be healthy, got '$verdict'"
  rm -f "$home/state/.omp-turnend-extension-loaded"
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "$verdict" = "false no-watcher" ] || fail "without the proof the same hand-off must alarm as no-watcher, got '$verdict'"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-wake-lib: the omp ownership proof is keyed on its own extensions and gates the hand-off tolerance"
}

# --- 6. The tracked primary extensions over a fake omp API ----------------------

install_omp_extension_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/typebox"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" \
    "$ROOT/.pi/extensions/lib/fm-extension-debug.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$repo/bin/"
  cp "$ROOT/bin/fm-wake-drain.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-classify-lib.sh" \
    "$ROOT/bin/fm-line-cap-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-lease-lib.sh" \
    "$ROOT/bin/fm-afk-contract.sh" "$ROOT/bin/fm-path-lib.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-wake-drain.sh"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
}

test_turnend_guard_extension_compels_one_continuation() {
  local repo home out status
  repo="$TMP_ROOT/guard/repo"; home="$TMP_ROOT/guard/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat); printf '%s\n' "$payload" >> "${FM_GUARD_LOG:?}"
case "$payload" in *'"stop_hook_active":true'*) exit 0 ;; esac
printf 'guard says: repair with fm_watch_arm_omp\n' >&2; exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-watch-arm.sh*'&'*) printf 'fm watcher-arm seatbelt: blocked\n' >&2; exit 2 ;; esac; exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-cd-pretool-check.sh"
  # shellcheck disable=SC2016 # $2 expands in the generated script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_GUARD_LOG="$TMP_ROOT/guard/guard.log" FM_HOME="$home" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
for (const name of ["session_start", "before_agent_start", "session_compact", "session_shutdown", "tool_call", "session_stop"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
if (handlers.has("agent_settled")) throw new Error("omp guard must not listen for agent_settled");
const ctx = { sessionManager: { getSessionId: () => "s1" } };
handlers.get("session_start")({ type: "session_start" }, ctx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!first?.message?.content?.includes("FIRSTMATE_OP: v1 session-start: OMP DIGEST source=startup")) throw new Error(`first start did not deliver a startup digest: ${JSON.stringify(first)}`);
if (first.message.display !== false || first.message.customType !== "firstmate-sessionstart-nudge") throw new Error("digest message lost its persistent shape");
// A later in-process session_start is a replacement and maps to clear.
handlers.get("session_start")({ type: "session_start" }, ctx);
const second = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!second?.message?.content?.includes("source=clear")) throw new Error(`in-process replacement did not map to clear: ${JSON.stringify(second)}`);
const allowed = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "ls" } }, {});
if (allowed.block) throw new Error("an ordinary command was blocked");
const blocked = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, {});
if (blocked.block !== true || !blocked.reason.includes("seatbelt")) throw new Error(`backgrounded arm was not blocked: ${JSON.stringify(blocked)}`);
const r1 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: false }, {});
if (r1?.continue !== true) throw new Error(`guard exit 2 did not compel a continuation: ${JSON.stringify(r1)}`);
if (!r1.additionalContext.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`continuation context is not typed operational input: ${r1.additionalContext}`);
if (!r1.additionalContext.includes("TURN WOULD END BLIND") || !r1.additionalContext.includes("repair with fm_watch_arm_omp")) throw new Error("continuation dropped the guard text");
const r2 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, {});
if (r2 !== undefined) throw new Error(`the flagged second stop must stand down, got ${JSON.stringify(r2)}`);
const payloads = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (payloads.join("|") !== '{"stop_hook_active":false}|{"stop_hook_active":true}') throw new Error(`guard payloads were ${payloads.join("|")}`);
if (!existsSync(`${process.env.FM_HOME}/state/.omp-turnend-extension-loaded`)) throw new Error("loaded marker was not written");
await handlers.get("session_shutdown")({}, {});
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard extension contract: $out"
  [ -z "$out" ] || fail "omp guard extension test printed output: $out"
  pass ".omp turn-end guard: digest delivery, seatbelt block, one compelled continuation, flagged stop stands down"
}

test_watch_extension_arms_and_delivers() {
  local repo home out status
  repo="$TMP_ROOT/watch/repo"; home="$TMP_ROOT/watch/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child closes with one actionable reason; every successor
  # stays up, so exactly one wake exists to consume.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
# A live arm child alone is not healthy: every round touches the beacon so the
# ownership no-op below sees the fresh beat the post-fm-5gh5 check requires.
: > "$FM_HOME/state/.last-watcher-beat"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  printf 'signal: omp-e2e done\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; let command = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(n, o) { if (n === "fm-watch-arm-omp") command = o.handler; },
  registerTool(t) { tool = t; },
  // omp sendUserMessage returns synchronously, not a promise.
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
// Pin this conversation's send closure as the generation's wake channel.
// The owning primary session_start is what claims the channel (fm-otu).
await handlers.get("session_start")({ type: "session_start" }, {});
if (!tool || tool.name !== "fm_watch_arm_omp") throw new Error("fm_watch_arm_omp was not registered");
if (!command) throw new Error("/fm-watch-arm-omp was not registered");
if (tool.parameters?.type !== "object") throw new Error("tool parameters must be an empty object schema");
const result = await tool.execute();
if (!/^watcher: started omp extension arm child 1;/.test(result.content[0].text)) throw new Error(`unexpected arm result: ${result.content[0].text}`);
const marker = readFileSync(`${process.env.FM_HOME}/state/.omp-watch-extension-loaded`, "utf8").split("\n");
if (marker[1] !== String(process.pid)) throw new Error("loaded marker must record the session pid");
const again = await tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) throw new Error(`redundant arm was not an ownership no-op: ${again.content[0].text}`);
await new Promise((r) => setTimeout(r, 2500));
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (!/^⁣FIRSTMATE_OP: v1 watcher: ⚓ wake · signal: omp-e2e done/.test(sent[0].m)) throw new Error(`unexpected wake text: ${sent[0].m}`);
if (sent[0].o?.deliverAs !== "followUp") throw new Error("wake must be delivered as a follow-up");
// The wake is consumed when omp starts the next run with that exact prompt.
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("a consumed wake must not ride the replacement handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension contract: $out"
  [ -z "$out" ] || fail "omp watch extension test printed output: $out"
  pass ".omp watch extension: fm_watch_arm_omp arms once, repeats as a no-op, and delivers an actionable close as one follow-up"
}

# The ownership answer verifies liveness, not just the recorded slot (fm-5gh5):
# a child whose process has exited, and a live child whose watcher stopped
# beating, both fail armOwnershipHealthy, so startArm can never answer
# "unchanged" for either. Driven through the exported decision function with
# real child processes, no fake omp API needed.
test_watch_extension_ownership_requires_a_live_beating_child() {
  local repo home out status
  repo="$TMP_ROOT/watch-liveness/repo"; home="$TMP_ROOT/watch-liveness/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # FM_GUARD_GRACE is the turn-end guard's own staleness override, which keeps
  # this test keyed on the guard's threshold rather than a test constant.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_GUARD_GRACE=2 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { writeFileSync, utimesSync } from "node:fs";
const beat = `${process.env.FM_HOME}/state/.last-watcher-beat`;
const mod = await import(pathToFileURL(process.env.EXT).href);
if (typeof mod.armOwnershipHealthy !== "function") throw new Error("armOwnershipHealthy was not exported");
// A live child with no beacon at all is not a beating watcher.
const live = spawn("sleep", ["30"]);
if (mod.armOwnershipHealthy({ child: live })) throw new Error("a live child with no beacon passed as healthy");
// A fresh beacon makes the same live child healthy.
const now = new Date();
writeFileSync(beat, "beat\n");
utimesSync(beat, now, now);
if (!mod.armOwnershipHealthy({ child: live })) throw new Error("a live child with a fresh beacon must be healthy");
// Once the beacon ages past the guard grace the same live child is not beating.
await new Promise((r) => setTimeout(r, 2600));
if (mod.armOwnershipHealthy({ child: live })) throw new Error("a live child with a stale beacon passed as healthy");
// A child whose process is gone never owns the slot, fresh beacon or not.
live.kill("SIGKILL");
await new Promise((r) => live.once("exit", r));
const deadline = Date.now() + 5000;
while ((live.exitCode === null && live.signalCode === null) && Date.now() < deadline) {
  await new Promise((r) => setTimeout(r, 25));
}
const nowDead = new Date();
utimesSync(beat, nowDead, nowDead);
if (mod.armOwnershipHealthy({ child: live })) throw new Error("a dead child with a fresh beacon passed as healthy");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch arm ownership liveness contract: $out"
  [ -z "$out" ] || fail "omp watch arm ownership liveness test printed output: $out"
  pass ".omp watch extension: arm ownership requires a live child AND a fresh watcher beat"
}

# An opted-in home spawns the supervision host in the arm's place; its streamed
# status line drives readiness and the handling handoff, and a handed-back
# wake is delivered with every host line and the away note.
test_watch_extension_runs_the_supervision_host() {  # [away|quiet]
  local kind=${1:-away} repo home log out status f
  repo="$TMP_ROOT/watch-host-$kind/repo"; home="$TMP_ROOT/watch-host-$kind/home"; log="$TMP_ROOT/watch-host-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  if [ "$kind" = quiet ]; then
    # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
    # QUIET): the extension asks the record owner, so the same handback carries
    # no away note.
    for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$repo/bin/$f"; done
    FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
      || fail "fixture: could not record quiet mode"
  else
    : > "$home/state/.afk-contract"
  fi
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s args=%s primary=%s predecessor=%s\n' "$$" "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  sleep 1
  printf 'signal: omp-host done\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\nsupervision-host: outcome 1 for demo [captain]: fixture\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-2\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    RECORD_KIND="$kind" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.some((row) => row.startsWith("plain-arm="))) throw new Error(`an opted-in home ran the plain arm: ${rows.join(" | ")}`);
const hosts = rows.filter((row) => row.startsWith("host="));
if (hosts.length !== 2) throw new Error(`expected the host and one successor host, got: ${rows.join(" | ")}`);
if (!hosts.every((row) => / args=park --restart primary=omp /.test(row))) throw new Error(`the host must run as 'park --restart' with the omp pin: ${hosts.join(" | ")}`);
if (!/predecessor=[0-9]+$/.test(hosts[1])) throw new Error(`the successor host did not receive the closed host as its predecessor: ${hosts[1]}`);
if (!rows.includes(`confirmed generation=gen-2 watcher=${hosts[1].replace(/^host=([0-9]+).*/, "$1")}`)) {
  throw new Error(`the handling handoff was not confirmed against the successor host's cycle: ${rows.join(" | ")}`);
}
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
for (const needle of [
  "signal: omp-host done",
  "supervision-host: the away session could not take this wake: fixture; this wake is yours",
  "supervision-host: outcome 1 for demo [captain]: fixture",
]) {
  if (!sent[0].m.includes(needle)) throw new Error(`the follow-up lacks '${needle}': ${sent[0].m}`);
}
const awayNote = sent[0].m.includes("not from the captain: it is not a return");
if (process.env.RECORD_KIND === "quiet" ? awayNote : !awayNote) {
  throw new Error(`the away note must appear exactly under an away record (${process.env.RECORD_KIND}): ${sent[0].m}`);
}
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host mode ($kind record): $out"
  [ -z "$out" ] || fail "omp watch extension host test printed output: $out"
  pass ".omp watch extension: an opted-in home runs the supervision host and relays every host line ($kind record)"
}

# The omp owner stays file-gated: a home without config/supervision-host, or
# one opted out by config/supervision-host-off, spawns the plain arm and never the host.

# Fix 1a: a persisted replacement-session handoff carries its origin session
# pid and time; at replay the extension drops (and logs once) an entry whose
# predecessor process is gone AND which exceeds the age bound, while a fresh
# pending wake survives no matter which pid wrote it. The drop is written
# back, so an ordinary restart no longer re-persists the stale entry - which
# is what made the Oct 10 file's 261 wakes replay on every restart until a
# forced kill.
test_watch_extension_expires_a_stale_replacement_handoff() {
  local repo home log out status
  repo="$TMP_ROOT/watch-stale/repo"; home="$TMP_ROOT/watch-stale/home"; log="$TMP_ROOT/watch-stale/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, mkdirSync } from "node:fs";
const home = process.env.FM_HOME;
const handoffDir = `${home}/state/extensions/omp-primary-watch`;
mkdirSync(handoffDir, { recursive: true });
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const now = Date.now();
const legacyStale = { version: 1, token: `3999991-${now - 2 * 3600e3 - 1000}-1`, message: "signal: stale wake from a dead session", predecessorArmPid: "" };
const persistedLogged = { version: 1, token: `${process.pid}-${now - 2000}-2`, message: "signal: a fresh wake from the live session", predecessorArmPid: "1234", originPid: String(process.pid), originAt: now - 2000 };
writeFileSync(`${handoffDir}/session-replacement-actionable.json`, JSON.stringify({ version: 2, pending: [legacyStale, persistedLogged] }) + "\n");
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
await import(pathToFileURL(process.env.EXT).href).then((mod) => mod.default(pi));
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 80 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1) throw new Error(`expected exactly one replayed wake, saw ${sent.length}: ${JSON.stringify(sent.map((s) => s.m))}`);
if (sent[0].m.includes("stale wake from a dead session")) throw new Error(`the dead predecessor's 2h-old wake must not replay: ${sent[0].m}`);
if (!sent[0].m.includes("fresh wake from the live session")) throw new Error(`the live predecessor's fresh wake was lost: ${sent[0].m}`);
if (!sent[0].m.includes("dropped 1 stale replacement-session actionable wake")) throw new Error(`the drop was not logged on the delivered wake: ${sent[0].m}`);
const persisted = JSON.parse(readFileSync(`${handoffDir}/session-replacement-actionable.json`, "utf8")).pending;
if (persisted.some((item) => item.token === legacyStale.token)) throw new Error("an ordinary restart re-persisted the dropped stale entry");
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension stale handoff expiry: $out"
  [ -z "$out" ] || fail "omp watch extension stale handoff expiry test printed output: $out"
  pass ".omp watch extension: a dead predecessor's aged-out wake is dropped and logged once; a live predecessor's fresh wake replays"
}

test_watch_extension_keeps_the_arm_without_the_file_or_with_off() {
  local line label repo home log out status
  for line in - off; do
    label=${line#-}; label=${label:-absent}
    repo="$TMP_ROOT/watch-host-gate-$label/repo"; home="$TMP_ROOT/watch-host-gate-$label/home"; log="$TMP_ROOT/watch-host-gate-$label/arm.log"
    install_omp_extension_fixture "$repo"
    mkdir -p "$home/state" "$home/config"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
    cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
    chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" \
      EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, writeFileSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null;
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage() { return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 60 && !existsSync(process.env.FM_ARM_LOG); i += 1) await new Promise((r) => setTimeout(r, 100));
const rows = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
if (rows.length === 0 || !rows.every((row) => row.startsWith("plain-arm="))) {
  throw new Error(`a home that does not run the host must spawn only the plain arm: ${rows.join(" | ")}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp watch extension gate ($label): $out"
    [ -z "$out" ] || fail "omp watch extension gate test printed output ($label): $out"
  done
  pass ".omp watch extension: a home without config/supervision-host or with an off file keeps the plain arm"
}

# Fix 1b: the persisted handoff list is capped at the newest entries, so an
# unconsumed-wake pile-up can never grow the file without bound; the intake
# merge writes through the same capping call, so the pile-up is bounded
# whether it arrives at session_start or mid-session while a replacement is
# queuing.
test_watch_extension_caps_the_persisted_handoff_list() {
  local repo home out status
  repo="$TMP_ROOT/watch-cap/repo"; home="$TMP_ROOT/watch-cap/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.EXT).href);
const entries = [];
for (let i = 0; i < 5; i += 1) {
  const token = `${process.pid}-${Date.now()}-${i + 1}`;
  entries.push({ version: 1, token, message: `signal: wake ${i + 1}`, predecessorArmPid: "" });
}
const kept = entries.filter((item) => !mod.handoffEntryDroppedByCap(item, entries, 3));
if (kept.length !== 3 || kept[0].token !== entries[2].token || kept[2].token !== entries[4].token) {
  throw new Error(`cap selection is wrong: ${JSON.stringify(kept.map((k) => k.token))}`);
}
if (mod.handoffEntryDroppedByCap(entries[4], entries, 3)) throw new Error("the newest entry is never a cap casualty");
// Aging ties at the same originAt resolve by token so a generation whose
// out-of-order intakes land never flips which entry survives.
const tied = [
  { version: 1, token: `7-1000-2`, message: "signal: a", predecessorArmPid: "" },
  { version: 1, token: `7-1000-1`, message: "signal: b", predecessorArmPid: "" },
];
if (mod.handoffEntryDroppedByCap(tied[0], tied, 1)) throw new Error("an out-of-order same-age entry slots before its lexically-smaller peer, so the kept set is stable");
if (!mod.handoffEntryDroppedByCap(tied[1], tied, 1)) throw new Error("an out-of-order same-age entry's peer keeps the slot, never both and never the newer");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension handoff cap: $out"
  [ -z "$out" ] || fail "omp watch extension handoff cap test printed output: $out"
  pass ".omp watch extension: the persisted replacement handoff list drops exactly the oldest beyond the cap"
}

# A host cycle boundary can close with only a "supervision-host:" line; left
# unconsumed across a session replacement it rides the persisted handoff and
# the successor session loads and replays it.
test_watch_extension_replays_a_host_only_boundary_across_replacement() {
  local repo home log out status
  repo="$TMP_ROOT/watch-host-handoff/repo"; home="$TMP_ROOT/watch-host-handoff/home"; log="$TMP_ROOT/watch-host-handoff/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  sleep 1
  printf 'supervision-host: outcome 1 for demo [captain]: fixture boundary\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1) throw new Error(`expected one boundary follow-up, saw ${sent.length}: ${JSON.stringify(sent)}`);
const boundary = "supervision-host: outcome 1 for demo [captain]: fixture boundary";
if (!sent[0].m.includes(boundary)) throw new Error(`the follow-up lacks the boundary line: ${sent[0].m}`);
// The session is replaced before omp consumes the boundary follow-up.
await handlers.get("session_shutdown")({}, {});
const stored = JSON.parse(readFileSync(handoff, "utf8"));
if (stored.pending.length !== 1 || !stored.pending[0].message.includes(boundary)) {
  throw new Error(`the unconsumed boundary did not ride the handoff: ${JSON.stringify(stored)}`);
}
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
const replays = sent.slice(1);
if (replays.some((item) => item.m.includes("watcher: FAILED"))) throw new Error(`the successor failed to load the handoff: ${JSON.stringify(replays)}`);
if (replays.length !== 1 || !replays[0].m.includes(boundary)) throw new Error(`the successor did not replay the boundary: ${JSON.stringify(replays)}`);
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: replays[0].m }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(handoff)) throw new Error("a consumed replay must not ride the replacement handoff again");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host-only handoff: $out"
  [ -z "$out" ] || fail "omp watch extension host-only handoff test printed output: $out"
  pass ".omp watch extension: a host-only boundary rides the replacement handoff and replays in the successor session"
}

# A host whose exit reaches the extension in separate stream chunks is
# delivered once at its close: a successor host whose status and signal lines
# land while the previous wake is still being delivered, with its outcome lines
# after a pause, reaches main as one follow-up carrying both.
test_watch_extension_delivers_a_split_host_close_whole() {
  local repo home log out status
  repo="$TMP_ROOT/watch-host-split/repo"; home="$TMP_ROOT/watch-host-split/home"; log="$TMP_ROOT/watch-host-split/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
started="watcher: started pid=$$ (beacon fresh) recovery-generation=gen-$$"
case "$(grep -c '^host=' "$FM_ARM_LOG")" in
  1)
    printf '%s\n' "$started"
    sleep 1
    printf 'signal: omp-host first\n'
    exit 0
    ;;
  2)
    printf '%s\nsignal: omp-host second\n' "$started"
    sleep 1
    printf 'supervision-host: outcome 2 for demo [captain]: fixture split\n'
    exit 0
    ;;
esac
printf '%s\n' "$started"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 80 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
const second = sent.filter((item) => item.m.includes("signal: omp-host second"));
if (second.length !== 1) throw new Error(`expected one follow-up for the split close, saw ${second.length}: ${JSON.stringify(sent)}`);
if (!second[0].m.includes("supervision-host: outcome 2 for demo [captain]: fixture split")) {
  throw new Error(`the split close was delivered without its outcome line: ${second[0].m}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension split host close: $out"
  [ -z "$out" ] || fail "omp watch extension split host close test printed output: $out"
  pass ".omp watch extension: a host close split across stream chunks reaches main as one whole follow-up"
}

# A subagent (task tool, /tan clone) re-binds the watch extension's factory
# against shared module state, and its events carry ctx.agent.kind === "sub".
# The rebind itself, its own session_start, and its shutdown must leave the
# primary's arm child and live generation alone, its own events must not
# consume the primary's pending wake, and its arming tool must answer with a
# stand-down instead of touching the arm. Observed on omp 18.10.4: the
# rebind happens at task spawn, before any subagent event, and no subagent
# session_shutdown follows.
test_watch_extension_subagent_session_never_touches_the_arm() {
  local repo home out status
  repo="$TMP_ROOT/watch-sub/repo"; home="$TMP_ROOT/watch-sub/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync } from "node:fs";
import { spawnSync, execFileSync } from "node:child_process";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; let command = null; const primarySent = [];
const primarySend = (m, o) => { primarySent.push({ m, o }); return undefined; };
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(n, o) { if (n === "fm-watch-arm-omp") command = o.handler; },
  registerTool(t) { tool = t; },
  sendUserMessage: primarySend,
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
// The primary session arms the watcher.
await handlers.get("session_start")({ type: "session_start" }, {});
const armResult = await tool.execute();
if (!/^watcher: (?:started omp extension arm child 1|unchanged - omp extension already owns an arm child)/.test(armResult.content[0].text)) throw new Error(`primary arm failed: ${armResult.content[0].text}`);
const markerPid = Number(execFileSync("bash", ["-c", `pgrep -f "fm-watch-arm.sh" | head -1`], { encoding: "utf8" }).trim());
if (!markerPid) throw new Error("the primary arm child was not running");
const subCtx = { agent: { kind: "sub", id: "task-1", name: "explore", depth: 1, parentId: "main" } };
// omp rebinds the factory for the subagent session on the same module.
const subHandlers = new Map(); let subToolDef = null;
const subSent = [];
const subSend = (m, o) => { subSent.push({ m, o }); return undefined; };
const subPi = {
  on(e, h) { subHandlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { subToolDef = t; },
  sendUserMessage: subSend,
};
mod.default(subPi);
// A subagent session start must not arm, re-arm, or replace anything.
await subHandlers.get("session_start")({ type: "session_start" }, subCtx);
// Its arming tool stands down and leaves the primary arm untouched.
const subTool = await subToolDef.execute(undefined, undefined, undefined, undefined, subCtx);
if (!/subagent session/.test(subTool.content[0].text)) throw new Error(`subagent tool call did not stand down: ${subTool.content[0].text}`);
if (subTool.details?.ok !== true) throw new Error("the subagent stand-down must read as non-error so the subagent model stays calm");
// Subagent agent events must not consume the pending wake owned by the primary.
await subHandlers.get("before_agent_start")({ type: "before_agent_start", prompt: "subagent prompt" }, subCtx);
// A subagent shutdown must not retire the primary arm or persist a handoff.
await subHandlers.get("session_shutdown")({}, subCtx);
const stillAlive = spawnSync("bash", ["-c", `kill -0 ${markerPid} 2>/dev/null && echo alive || echo dead`], { encoding: "utf8" }).stdout.trim();
if (stillAlive !== "alive") throw new Error(`the subagent shutdown killed the primary arm child (pid ${markerPid})`);
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) {
  throw new Error("the subagent shutdown persisted a replacement handoff");
}
if (subPi.sendUserMessage !== subSend) throw new Error("fixture harness mismatch: the rebound pi changed its send closure");
if (subSent.length !== 0) throw new Error(`the subagent conversation received or triggered a wake: ${JSON.stringify(subSent)}`);
if (primarySent.length !== 0) throw new Error(`a wake escaped before primary consumption could be observed: ${JSON.stringify(primarySent)}`);
// The primary session still owns the arm: a later lock-owning start is a
// replacement no-op, and the arm tool reports the existing child.
const again = await tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) {
  throw new Error(`the primary arm was not left owned after the subagent session: ${again.content[0].text}`);
}
const doubleCheck = spawnSync("bash", ["-c", `kill -0 ${markerPid} 2>/dev/null && echo alive || echo dead`], { encoding: "utf8" }).stdout.trim();
if (doubleCheck !== "alive") throw new Error(`the primary arm child died across the subagent lifecycle (pid ${markerPid})`);
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension subagent stand-down: $out"
  [ -z "$out" ] || fail "omp watch extension subagent test printed output: $out"
  pass ".omp watch extension: a subagent session never arms, consumes, retires, or hands off - the primary keeps its arm"
}
# omp 18.10.4 can still deliver a subagent's events with a ctx whose
# agent.kind does not read as "sub" under the kind-only test shipped with
# #9 (the 2026-10-14 canary). The gate now also accepts ctx.agent.depth > 0
# and, when even the agent field is absent, treats the event as a subagent
# unless lockOwnership() proves this process owns the fleet lock. This test
# drives each of those surfaces and asserts the primary arm survives, and
# back-checks that an ambiguous ctx under a lock-owning primary still reads
# as the primary (supervision persists).
test_watch_extension_subagent_gate_recognizes_1810_shapes() {
  local repo home out status
  repo="$TMP_ROOT/watch-sub-1810/repo"; home="$TMP_ROOT/watch-sub-1810/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync, rmSync } from "node:fs";
import { spawnSync, execFileSync } from "node:child_process";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
// The lock-owning primary arms the watcher.
await handlers.get("session_start")({ type: "session_start" }, {});
await tool.execute();
const markerPid = Number(execFileSync("bash", ["-c", `pgrep -f "fm-watch-arm.sh" | head -1`], { encoding: "utf8" }).trim());
if (!markerPid) throw new Error("the primary arm child was not running");
const alive = () => spawnSync("bash", ["-c", `kill -0 ${markerPid} 2>/dev/null && echo alive || echo dead`], { encoding: "utf8" }).stdout.trim();
if (alive() !== "alive") throw new Error("arm child not alive at start");
// (a) depth-only subagent ctx: kind is absent, depth > 0 -> shared generation must stand down.
await handlers.get("session_start")({ type: "session_start" }, { agent: { id: "s-depth", name: "sonic", depth: 1, parentId: "main" } });
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "depth-only" }, { agent: { id: "s-depth", name: "sonic", depth: 1, parentId: "main" } });
await handlers.get("session_shutdown")({}, { agent: { id: "s-depth", name: "sonic", depth: 1, parentId: "main" } });
if (alive() !== "alive") throw new Error("depth-only subagent shutdown retired the primary arm");
// (b) unknown-kind subagent ctx under the lock-owning primary: the documented
// fail-safe keeps supervision alive, so the arm child must still be there.
await handlers.get("session_start")({ type: "session_start" }, { agent: { kind: "experimental", id: "s-x", name: "x", depth: 0 } });
await handlers.get("session_shutdown")({}, { agent: { kind: "experimental", id: "s-x", name: "x", depth: 0 } });
if (alive() !== "alive") throw new Error("ambiguous-kind primary-adjacent ctx retired the primary arm");
// (c) no-agent ctx in a NON-lock-owning process: stand down. Simulate by
// removing the fleet lock; the primary arm child must still survive its own
// session_shutdown because the gate reads as a subagent and returns.
rmSync(`${process.env.FM_HOME}/state/.lock`, { force: true });
await handlers.get("session_shutdown")({}, {});
if (alive() !== "alive") throw new Error("lock-absent ambiguous shutdown retired the shared arm");
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) {
  throw new Error("lock-absent ambiguous shutdown persisted a replacement handoff");
}
if (sent.some((s) => /watcher: FAILED/.test(s.m))) throw new Error(`unexpected failure delivered: ${JSON.stringify(sent)}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension 18.10 subagent shapes: $out"
  [ -z "$out" ] || fail "omp watch extension 18.10 subagent test printed output: $out"
  pass ".omp watch extension: depth-only, ambiguous-kind, and lock-absent shutdowns leave the primary arm alone"
}

# The same 18.10.4 shapes must not corrupt the turn-end guard's primary
# sessionstart generation: a depth-only subagent start and shutdown leave the
# running generation alone, and a lock-absent ambiguous shutdown stands down
# rather than retiring the shared generation.
test_turnend_guard_subagent_gate_recognizes_1810_shapes() {
  local repo home out status
  repo="$TMP_ROOT/guard-sub-1810/repo"; home="$TMP_ROOT/guard-sub-1810/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-turnend-guard.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-arm-pretool-check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-cd-pretool-check.sh"
  # shellcheck disable=SC2016 # "$2" belongs to the generated fixture script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_HOME="$home" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, rmSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
const mainCtx = { sessionManager: { getSessionId: () => "main-session" } };
handlers.get("session_start")({ type: "session_start" }, mainCtx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, mainCtx);
if (!first?.message?.content?.includes("OMP DIGEST source=startup")) throw new Error(`primary digest missing: ${JSON.stringify(first)}`);
// Depth-only subagent: no kind. Its start must not create a generation and
// its shutdown must not retire the primary generation - proof: the next
// primary session_start counts as a "clear" (third) start, not a corrupted
// repeat, and reaches the model through before_agent_start.
const depthOnlyCtx = { agent: { id: "s-depth", name: "sonic", depth: 1, parentId: "main" } };
handlers.get("session_start")({ type: "session_start" }, depthOnlyCtx);
await handlers.get("session_shutdown")({}, depthOnlyCtx);
handlers.get("session_start")({ type: "session_start" }, mainCtx);
const clear = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi again" }, mainCtx);
if (!clear?.message?.content?.includes("source=clear")) throw new Error(`depth-only subagent corrupted the primary start count: ${JSON.stringify(clear)}`);
// Lock-absent ambiguous shutdown: the gate stands down rather than retiring
// the shared generation, so the next primary start still reads as a clear.
rmSync(`${process.env.FM_HOME}/state/.lock`, { force: true });
await handlers.get("session_shutdown")({}, {});
handlers.get("session_start")({ type: "session_start" }, mainCtx);
const secondClear = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi once more" }, mainCtx);
if (!secondClear?.message?.content?.includes("source=clear")) throw new Error(`lock-absent ambiguous shutdown retired the primary generation: ${JSON.stringify(secondClear)}`);
await handlers.get("session_shutdown")({}, mainCtx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard 18.10 subagent shapes: $out"
  [ -z "$out" ] || fail "omp turn-end guard 18.10 subagent test printed output: $out"
  pass ".omp turn-end guard: depth-only and lock-absent subagent shutdowns leave the primary generation alone"
}
test_watch_extension_subagent_gate_recognizes_1810_shapes
test_turnend_guard_subagent_gate_recognizes_1810_shapes


# The turn-end guard's session lifecycle and tool_call handlers must also stand
# down under a subagent context: its sessionstart generation belongs to the
# primary and a subagent's shutdown must not retire it, and the primary-home
# bash seatbelt does not govern a bounded in-process assistant.
test_turnend_guard_subagent_session_stands_down() {
  local repo home out status
  repo="$TMP_ROOT/guard-sub/repo"; home="$TMP_ROOT/guard-sub/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-turnend-guard.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-arm-pretool-check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-cd-pretool-check.sh"
  # shellcheck disable=SC2016 # "$2" belongs to the generated fixture script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_HOME="$home" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
const mainCtx = { sessionManager: { getSessionId: () => "main-session" } };
handlers.get("session_start")({ type: "session_start" }, mainCtx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, mainCtx);
if (!first?.message?.content?.includes("OMP DIGEST source=startup")) throw new Error(`primary digest missing: ${JSON.stringify(first)}`);
const subCtx = { agent: { kind: "sub", id: "task-1", name: "explore", depth: 1, parentId: "main" } };
// A subagent start must not create, replace, or count a sessionstart
// generation: the primary generation stays the active one.
handlers.get("session_start")({ type: "session_start" }, subCtx);
// A subagent compaction must not spawn a generation either.
await handlers.get("session_compact")({ type: "session_compact" }, subCtx);
// A subagent bash call bypasses the primary-home seatbelt.
const allowed = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, subCtx);
if (allowed.block) throw new Error("the subagent bash call was blocked by the primary seatbelt");
// A subagent session start must not inflate the primary start count, and a
// subagent shutdown must not retire the primary session machinery.
await handlers.get("session_shutdown")({}, subCtx);
handlers.get("session_start")({ type: "session_start" }, mainCtx);
const clear = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi again" }, mainCtx);
if (!clear?.message?.content?.includes("source=clear")) throw new Error(`the subagent lifecycle corrupted the primary start count: ${JSON.stringify(clear)}`);
await handlers.get("session_shutdown")({}, mainCtx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard subagent stand-down: $out"
  [ -z "$out" ] || fail "omp turn-end guard subagent test printed output: $out"
  pass ".omp turn-end guard: a subagent session leaves the primary sessionstart generation and seatbelt untouched"
}
test_watch_extension_subagent_session_never_touches_the_arm
test_turnend_guard_subagent_session_stands_down
# Wake coalescing: three delivery-time rules added to the omp watch
# extension. (1) a close whose durable wake queue is already drained is not
# re-pinged to main; (2) several pending actionable closes settle in ONE
# follow-up whose message dedupes repeated identical reason texts; (3) a
# repeat of the identical stale reason within the TTL is suppressed.
test_watch_extension_skips_delivery_when_the_queue_is_drained() {
  local repo home log out status queue
  repo="$TMP_ROOT/coalesce-empty/repo"; home="$TMP_ROOT/coalesce-empty/home"; log="$TMP_ROOT/coalesce-empty/arm.log"
  queue="$TMP_ROOT/coalesce-empty/queue"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WAKE_QUEUE="$queue" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
const queue = process.env.FM_WAKE_QUEUE;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
writeFileSync(queue, "");
const handoffDir = `${home}/state/extensions/omp-primary-watch`;
mkdirSync(handoffDir, { recursive: true });
const now = Date.now();
const entry = { version: 1, token: `${process.pid}-${now}-1`, message: "stale: platform stopped responding in its pane", predecessorArmPid: "" };
writeFileSync(`${handoffDir}/session-replacement-actionable.json`, JSON.stringify({ version: 2, pending: [entry] }) + "\n");
const handlers = new Map();
const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
await import(pathToFileURL(process.env.EXT).href).then((mod) => mod.default(pi));
await handlers.get("session_start")({ type: "session_start" }, {});
await new Promise((r) => setTimeout(r, 1500));
if (sent.length !== 0) throw new Error(`an empty queue must suppress the follow-up entirely; saw ${sent.length}: ${sent[0] && sent[0].m.slice(0, 120)}`);
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${handoffDir}/session-replacement-actionable.json`)) {
  throw new Error("a drained-queue close finished its pending record and must not ride the handoff again");
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch empty queue: $out"
  [ -z "$out" ] || fail "omp watch empty queue test printed output: $out"
  pass ".omp watch extension: a close whose durable wake queue is already drained sends no follow-up"
}

test_watch_extension_coalesces_a_busy_pending_pile() {
  local repo home log out status queue
  repo="$TMP_ROOT/coalesce-batch/repo"; home="$TMP_ROOT/coalesce-batch/home"; log="$TMP_ROOT/coalesce-batch/arm.log"
  queue="$TMP_ROOT/coalesce-batch/queue"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WAKE_QUEUE="$queue" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, existsSync, readFileSync } from "node:fs";
const home = process.env.FM_HOME;
const queue = process.env.FM_WAKE_QUEUE;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
writeFileSync(queue, "key1\tt1\tstale\tS1\tlive\n");
const handoffDir = `${home}/state/extensions/omp-primary-watch`;
mkdirSync(handoffDir, { recursive: true });
const now = Date.now();
const entries = [
  { version: 1, token: `${process.pid}-${now}-1`, message: "stale: platform stopped responding", predecessorArmPid: "" },
  { version: 1, token: `${process.pid}-${now}-2`, message: "signal: new wake observed", predecessorArmPid: "" },
  { version: 1, token: `${process.pid}-${now}-3`, message: "stale: platform stopped responding", predecessorArmPid: "" },
];
writeFileSync(`${handoffDir}/session-replacement-actionable.json`, JSON.stringify({ version: 2, pending: entries }) + "\n");
const handlers = new Map();
const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
await import(pathToFileURL(process.env.EXT).href).then((mod) => mod.default(pi));
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 50 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1) throw new Error(`expected exactly ONE batched follow-up for 3 pending wakes, saw ${sent.length}`);
if (!sent[0].m.includes("3 wakes pending (coalesced)")) throw new Error(`batch header mismatch: ${sent[0].m.slice(0, 200)}`);
const count = (sent[0].m.match(/stopped responding/g) || []).length;
if (count !== 1) throw new Error(`repeated identical stale reason not deduped inside batch (count=${count})`);
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${handoffDir}/session-replacement-actionable.json`)) {
  const stored = JSON.parse(readFileSync(`${handoffDir}/session-replacement-actionable.json`, "utf8"));
  if (stored.pending.length !== 0) throw new Error(`a consumed batch must finish every member's pending record, saw ${stored.pending.length}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch batch: $out"
  [ -z "$out" ] || fail "omp watch batch test printed output: $out"
  pass ".omp watch extension: a busy pending pile settles in ONE batched follow-up whose message dedupes repeated reasons; one consumption finishes every batch member"
}

# The 2026-10-14 hidden-delivery contract: with a queued actionable row and
# pi.sendMessage available (omp 18.10.4), sendBatchedWake drains the queue
# itself with bin/fm-wake-drain.sh --brief --ack and delivers the one-line
# summary as a hidden custom message (customType fm.wake, display:false,
# triggerTurn:true, deliverAs followUp). The primary's chat never renders
# the wake text, and the matching role:"custom" message_start finishes the
# pending record. A drain failure or a missing sendMessage API falls back
# to today's visible sendUserMessage banner.
test_watch_extension_sends_a_hidden_wake_through_sendMessage() {
  local repo home log out status queue
  repo="$TMP_ROOT/wake-hidden/repo"; home="$TMP_ROOT/wake-hidden/home"; log="$TMP_ROOT/wake-hidden/arm.log"
  queue="$TMP_ROOT/wake-hidden/queue"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SCRIPT'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SCRIPT
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WAKE_QUEUE="$queue" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
const queue = process.env.FM_WAKE_QUEUE;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handoffDir = `${home}/state/extensions/omp-primary-watch`;
mkdirSync(handoffDir, { recursive: true });
const now = Date.now();
const entry = { version: 1, token: `${process.pid}-${now}-1`, message: "signal: omp-e2e hidden wake", predecessorArmPid: "" };
writeFileSync(`${handoffDir}/session-replacement-actionable.json`, JSON.stringify({ version: 2, pending: [entry] }) + "\n");
writeFileSync(queue, `${Math.floor(now / 1000)}\t1\tsignal\tfm-hidden-test\tsignal: omp-e2e hidden wake\n`);
const handlers = new Map();
const sent = [];
const sentHidden = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
  sendMessage(msg, opts) { sentHidden.push({ msg, opts }); return undefined; },
};
await import(pathToFileURL(process.env.EXT).href).then((mod) => mod.default(pi));
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && sentHidden.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 0) throw new Error(`the visible banner must not fire when hidden delivery works; saw ${JSON.stringify(sent)}`);
if (sentHidden.length !== 1) throw new Error(`expected exactly ONE hidden message; saw ${sentHidden.length}`);
const wake = sentHidden[0];
if (wake.msg.customType !== "fm.wake") throw new Error(`custom type mismatch: ${JSON.stringify(wake.msg)}`);
if (wake.msg.display !== false) throw new Error(`display flag must be false: ${JSON.stringify(wake.msg)}`);
if (!wake.opts || wake.opts.triggerTurn !== true) throw new Error(`triggerTurn must be true: ${JSON.stringify(wake)}`);
if (wake.opts.deliverAs !== "followUp") throw new Error(`deliverAs must be followUp: ${JSON.stringify(wake)}`);
if (!wake.msg.content.includes("fm-hidden-test")) throw new Error(`hidden wake must carry the drained row key: ${wake.msg.content}`);
if (/WAKE_ACK_REQUIRED/.test(wake.msg.content)) throw new Error(`the ack contract stays an extension concern and never rides the wake text: ${wake.msg.content}`);
// The extension acknowledged exactly the presented row as part of delivery,
// so the durable queue is already empty - the live 2026-10-14 defect left
// it queued and re-presented on every later wake.
const drainedQueue = readFileSync(queue, "utf8").trim();
if (drainedQueue !== "") throw new Error(`delivering the hidden wake must ack the presented row; queue holds: ${drainedQueue}`);
// The matching message_start finishes the pending record. Custom messages
// surface with role "custom" - observed against omp 18.10.4 by direct
// instrumentation of the runner emit path.
await handlers.get("message_start")({ type: "message_start", message: { role: "custom", customType: "fm.wake", content: wake.msg.content, attribution: "agent", timestamp: Date.now() } }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${handoffDir}/session-replacement-actionable.json`)) {
  const stored = JSON.parse(readFileSync(`${handoffDir}/session-replacement-actionable.json`, "utf8"));
  if (stored.pending.length !== 0) throw new Error(`a consumed hidden wake must finish the pending record, saw ${stored.pending.length}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch hidden wake: $out"
  [ -z "$out" ] || fail "omp watch hidden wake test printed output: $out"
  pass ".omp watch extension: a drained actionable wake reaches the model as a hidden fm.wake custom message and its message_start finishes the pending record"
}
test_watch_extension_sends_a_hidden_wake_through_sendMessage

# When sendMessage is absent or rejected, the extension falls back to the
# visible sendUserMessage follow-up so the wake still reaches main. The
# pre-existing sendBatchedWake contract - one message per batch; matching
# user-role message_start finishes the record - is unchanged.
test_watch_extension_falls_back_to_sendUserMessage_when_sendMessage_fails() {
  local repo home log out status queue
  repo="$TMP_ROOT/wake-fallback/repo"; home="$TMP_ROOT/wake-fallback/home"; log="$TMP_ROOT/wake-fallback/arm.log"
  queue="$TMP_ROOT/wake-fallback/queue"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SCRIPT'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SCRIPT
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WAKE_QUEUE="$queue" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
const queue = process.env.FM_WAKE_QUEUE;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handoffDir = `${home}/state/extensions/omp-primary-watch`;
mkdirSync(handoffDir, { recursive: true });
const now = Date.now();
const entry = { version: 1, token: `${process.pid}-${now}-1`, message: "signal: omp-e2e fallback wake", predecessorArmPid: "" };
writeFileSync(`${handoffDir}/session-replacement-actionable.json`, JSON.stringify({ version: 2, pending: [entry] }) + "\n");
writeFileSync(queue, `${Math.floor(now / 1000)}\t1\tsignal\tfm-fallback-test\tsignal: omp-e2e fallback wake\n`);
const handlers = new Map();
const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
  // sendMessage intentionally absent: the extension must fall back.
};
await import(pathToFileURL(process.env.EXT).href).then((mod) => mod.default(pi));
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1) throw new Error(`expected the visible follow-up when sendMessage is missing; saw ${sent.length}`);
if (!sent[0].m.includes("omp-e2e fallback wake")) throw new Error(`fallback wake text mismatch: ${sent[0].m.slice(0, 240)}`);
if (sent[0].o?.deliverAs !== "followUp") throw new Error("fallback wake must be delivered as a follow-up");
{
  const drainedQueue = readFileSync(queue, "utf8").trim();
  if (drainedQueue !== "") throw new Error(`the visible fallback must also ack the presented row; queue holds: ${drainedQueue}`);
}
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${handoffDir}/session-replacement-actionable.json`)) {
  const stored = JSON.parse(readFileSync(`${handoffDir}/session-replacement-actionable.json`, "utf8"));
  if (stored.pending.length !== 0) throw new Error("the fallback follow-up must finish the pending record");
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch fallback wake: $out"
  [ -z "$out" ] || fail "omp watch fallback wake test printed output: $out"
  pass ".omp watch extension: an absent sendMessage API still delivers the actionable wake through the visible follow-up"
}
test_watch_extension_falls_back_to_sendUserMessage_when_sendMessage_fails

test_watch_extension_suppresses_a_repeat_stale_reason_within_the_ttl() {
  local repo home out status queue
  repo="$TMP_ROOT/coalesce-stale/repo"; home="$TMP_ROOT/coalesce-stale/home"; queue="$TMP_ROOT/coalesce-stale/queue"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WAKE_QUEUE="$queue" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.EXT).href);
// Within one generation, an identical stale repeat inside the TTL is
// suppressed; an entry past the TTL is not. The map keys on the pane that
// the stale reason addresses, so a pane whose stale state changed (a fresh
// reason text) is a fresh key and re-delivers.
const now = Date.now();
const item = { version: 1, token: `7-${now}-1`, message: "stale: platform stopped responding in its pane", predecessorArmPid: "" };
const map = new Map();
const key = `${mod.stalePaneKey(item.message)}|${item.message}`;
map.set(key, now - 1000);
if (!mod.staleWakeSuppressed(map, item, now, mod.staleWakeupTtlMs)) {
  throw new Error("an identical stale repeat inside the TTL must be suppressed");
}
if (mod.staleWakeSuppressed(map, item, now + mod.staleWakeupTtlMs + 1000, mod.staleWakeupTtlMs)) {
  throw new Error("a stale repeat past the TTL must not be suppressed");
}
const other = { ...item, message: "stale: platform now reads idle, not stopped" };
if (mod.staleWakeSuppressed(map, other, now, mod.staleWakeupTtlMs)) {
  throw new Error("a pane whose stale state changed is a fresh key and must not be suppressed");
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch stale TTL: $out"
  [ -z "$out" ] || fail "omp watch stale TTL test printed output: $out"
  pass ".omp watch extension: an identical stale repeat inside the TTL is suppressed; a pane whose stale state changed re-delivers"
}
# The 2026-10-14 live repetition defect, pinned against the PRODUCTION
# bin/fm-wake-drain.sh: its --brief --ack contract writes the presented rows
# on stdout and the WAKE_ACK_REQUIRED marker on STDERR. The pre-fix parser
# read only stdout, never saw the marker, never acked, and the very next
# drain re-presented the same row beside anything new. Two consecutive
# hidden wakes must carry once-delivered rows only, and the queue must be
# empty afterwards.
test_watch_extension_acks_each_presented_wake_once_so_it_never_repeats() {
  local repo home log out status queue
  repo="$TMP_ROOT/wake-repeat/repo"; home="$TMP_ROOT/wake-repeat/home"; log="$TMP_ROOT/wake-repeat/arm.log"
  queue="$TMP_ROOT/wake-repeat/queue"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SCRIPT'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30
SCRIPT
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # Session 1: the wake drains, delivers hidden, consumes, and - with the
  # ack fix - leaves the queue empty and no persisted handoff.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WAKE_QUEUE="$queue" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
const queue = process.env.FM_WAKE_QUEUE;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handoffDir = `${home}/state/extensions/omp-primary-watch`;
mkdirSync(handoffDir, { recursive: true });
const now = Date.now();
const entry = { version: 1, token: `${process.pid}-${now}-1`, message: "signal: first actionable", predecessorArmPid: "" };
writeFileSync(`${handoffDir}/session-replacement-actionable.json`, JSON.stringify({ version: 2, pending: [entry] }) + "\n");
writeFileSync(queue, `${Math.floor(now / 1000)}\t1\tsignal\tfm-repeat\tsignal: first actionable\n`);
const handlers = new Map();
const sent = [];
const sentHidden = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
  sendMessage(msg, opts) { sentHidden.push({ msg, opts }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && sentHidden.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sentHidden.length !== 1) throw new Error(`first wake must deliver hidden; got ${sentHidden.length} (visible: ${sent.length})`);
if (!sentHidden[0].msg.content.includes("first actionable")) throw new Error(`first wake lost its row: ${sentHidden[0].msg.content}`);
await handlers.get("message_start")({ type: "message_start", message: { role: "custom", customType: "fm.wake", content: sentHidden[0].msg.content, attribution: "agent", timestamp: Date.now() } }, {});
await handlers.get("session_shutdown")({}, {});
const drained = readFileSync(queue, "utf8").trim();
if (drained !== "") throw new Error(`the first wake must ack its presented row; queue holds: ${drained}`);
// A consumed wake leaves no persisted handoff for the replacement to
// replay; the file either never wrote or holds an empty pending list.
if (existsSync(`${handoffDir}/session-replacement-actionable.json`)) {
  const stored = JSON.parse(readFileSync(`${handoffDir}/session-replacement-actionable.json`, "utf8"));
  if (stored.pending.length !== 0) throw new Error(`the first wake must not survive its consumption in the handoff: ${stored.pending.length}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch repetition session 1: $out"

  # Session 2 (the live defect replay): a REPLACEMENT session replays the
  # arm's later close. With the ack fix its drain sees ONLY the new row; the
  # pre-fix build left row 1 queued and re-presented it beside row 2.
  printf '%s\t2\tsignal\tfm-repeat\tsignal: second actionable\n' "$(date +%s)" >> "$queue"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WAKE_QUEUE="$queue" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, readFileSync } from "node:fs";
const home = process.env.FM_HOME;
const queue = process.env.FM_WAKE_QUEUE;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handoffDir = `${home}/state/extensions/omp-primary-watch`;
mkdirSync(handoffDir, { recursive: true });
const entry = { version: 1, token: `${process.pid}-${Date.now()}-2`, message: "signal: second actionable", predecessorArmPid: "" };
writeFileSync(`${handoffDir}/session-replacement-actionable.json`, JSON.stringify({ version: 2, pending: [entry] }) + "\n");
const handlers = new Map();
const sent = [];
const sentHidden = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
  sendMessage(msg, opts) { sentHidden.push({ msg, opts }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && sentHidden.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sentHidden.length !== 1) throw new Error(`the replacement wake must deliver hidden; got ${sentHidden.length} (visible: ${sent.length})`);
const wakeText = sentHidden[0].msg.content;
if (!wakeText.includes("second actionable")) throw new Error(`second wake lost its own row: ${wakeText}`);
if (wakeText.includes("first actionable")) throw new Error(`REPETITION: the replacement wake re-carried the already-delivered row: ${wakeText}`);
const drained = readFileSync(queue, "utf8").trim();
if (drained !== "") throw new Error(`the replacement wake must ack its presented row too; queue holds: ${drained}`);
await handlers.get("message_start")({ type: "message_start", message: { role: "custom", customType: "fm.wake", content: wakeText, attribution: "agent", timestamp: Date.now() } }, {});
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch repetition session 2: $out"
  [ -z "$out" ] || fail "omp watch repetition test printed output: $out"
  pass ".omp watch extension: consecutive wakes carry only not-yet-delivered rows and the queue leaves no residue"
}
test_watch_extension_acks_each_presented_wake_once_so_it_never_repeats

# The production drain contract the extension now parses: --brief --ack
# presents the rows on STDOUT and the WAKE_ACK_REQUIRED marker on STDERR.
# Any refactor that moves the marker back to stdout would silently
# reactivate the historical stdout-only misreading, so pin the channel
# against the real script through its executable interface.
test_wake_drain_brief_ack_places_the_ack_marker_on_stderr() {
  local home drain_out drain_err
  home="$TMP_ROOT/ack-contract/home"
  mkdir -p "$home/state" "$home/config"
  printf '%s\t9\tsignal\tfm-ack\tsignal: ack me once\n' "$(date +%s)" > "$home/state/.wake-queue"
  drain_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" --brief --ack 2>/dev/null </dev/null || true)
  drain_err=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" --brief --ack 2>&1 >/dev/null </dev/null || true)
  printf '%s' "$drain_out" | grep -q "ack me once" || fail "the drain must present the row on stdout: $drain_out"
  printf '%s' "$drain_out" | grep -q "WAKE_ACK_REQUIRED" && fail "the ack marker must not ride stdout: $drain_out"
  printf '%s' "$drain_err" | grep -q "WAKE_ACK_REQUIRED" || fail "the ack marker must ride stderr: $drain_err"
  pass "fm-wake-drain --brief --ack presents rows on stdout and the ack marker on stderr"
}
test_wake_drain_brief_ack_places_the_ack_marker_on_stderr


test_detection_anchored_name_and_marker_precedence
test_lock_identity_and_liveness_classification
test_spawn_launch_line_and_worker_wiring
test_spawn_model_validation_scoped_to_listed_providers
test_secondmate_launch_relies_on_discovery
test_secondmate_config_pinned_model_is_validated
test_busy_extension_lifecycle
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
test_watch_extension_ownership_requires_a_live_beating_child
test_watch_extension_runs_the_supervision_host
test_watch_extension_runs_the_supervision_host quiet
test_watch_extension_keeps_the_arm_without_the_file_or_with_off
test_watch_extension_expires_a_stale_replacement_handoff
test_watch_extension_caps_the_persisted_handoff_list
test_watch_extension_replays_a_host_only_boundary_across_replacement
test_watch_extension_delivers_a_split_host_close_whole
test_watch_extension_skips_delivery_when_the_queue_is_drained
test_watch_extension_coalesces_a_busy_pending_pile
test_watch_extension_suppresses_a_repeat_stale_reason_within_the_ttl
