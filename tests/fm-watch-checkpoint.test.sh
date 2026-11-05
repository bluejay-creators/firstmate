#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

wait_for_checkpoint_lock() {
  local home=$1 i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$home/state/.watch.lock/pid" ] \
      && [ -e "$home/state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_perl_timeout_fallback_honors_cleanup_bound_before_escalating() {
  local home fallback_bin tool tool_path status watcher_pid
  home=$(make_home perl-fallback)
  fallback_bin="$home/fallback-bin"
  mkdir -p "$home/root/bin" "$fallback_bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  for tool in bash dirname mktemp rm perl grep cat; do
    tool_path=$(command -v "$tool") || fail "could not locate $tool for the Perl fallback fixture"
    ln -s "$tool_path" "$fallback_bin/$tool"
  done
  cat > "$home/root/bin/fm-watch.sh" <<'PL'
#!/usr/bin/env perl
use strict;
use warnings;
$SIG{INT} = 'IGNORE';
open my $pid_file, '>', "$ENV{FM_HOME}/watcher.pid" or die "open pid file: $!";
printf {$pid_file} "%s\n", $$;
close $pid_file;
sleep 7;
open my $cleanup_file, '>', "$ENV{FM_HOME}/cleanup-reached" or die "open cleanup marker: $!";
print {$cleanup_file} "reached\n";
close $cleanup_file;
END {
  if (open my $exit_file, '>', "$ENV{FM_HOME}/natural-exit") {
    print {$exit_file} "natural\n";
  }
}
sleep 20;
PL
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-watch.sh"

  status=0
  PATH="$fallback_bin" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_WATCHER_CLEANUP_LOCK_BOUND=8 \
    "$home/root/bin/fm-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?

  expect_code 124 "$status" "Perl fallback checkpoint exit"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 1s" \
    "Perl fallback did not return a quiet checkpoint"
  [ -e "$home/cleanup-reached" ] || fail "the Perl fallback killed the watcher before its 8-second cleanup bound"
  [ ! -e "$home/natural-exit" ] || fail "the INT-ignoring watcher exited naturally instead of being killed"
  [ -s "$home/watcher.pid" ] || fail "the INT-ignoring watcher did not start"
  watcher_pid=$(cat "$home/watcher.pid")
  if kill -0 "$watcher_pid" 2>/dev/null; then
    fail "the INT-ignoring watcher survived the Perl fallback escalation"
  fi
  pass "Perl fallback honors the cleanup bound before escalating an INT-ignoring direct watcher"
}

test_announced_recovery_is_not_reannounced_by_next_checkpoint() {
  local home out err status marker
  home=$(make_home announced-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  append_wake "$home/state" check buried 'check: unacknowledged durable wake' \
    || fail "could not append the unacknowledged durable wake"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "first recovery checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "first checkpoint did not announce the pending recovery"
  marker=$(cat "$home/state/.watcher-down")
  case "$marker" in
    announced:downtime:*) ;;
    *) fail "first checkpoint did not leave an announced generation: $marker" ;;
  esac
  [ -s "$home/state/.wake-queue" ] \
    || fail "durable wake did not stay unacknowledged after the announcement"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?

  expect_code 124 "$status" "announced recovery checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" \
    "announced recovery checkpoint did not supervise for its bound"
  assert_not_contains "$(cat "$out")" "check: rearm-resurface" \
    "announced recovery was reannounced by the next checkpoint"
  [ "$(cat "$home/state/.watcher-down")" = "$marker" ] \
    || fail "announced recovery checkpoint changed the outstanding generation"
  grep "$(printf '\tcheck\tburied\tcheck: unacknowledged durable wake')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "unacknowledged durable wake was not retained"
  pass "an announced recovery is not reannounced by the next foreground checkpoint"
}

test_never_announced_recovery_is_announced_once() {
  local home out err status
  home=$(make_home pending-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'pending:downtime:unreported.1.aaa\n' > "$home/state/.watcher-down"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?

  expect_code 0 "$status" "pending recovery checkpoint exit"
  [ "$(grep -c '^check: rearm-resurface$' "$out" || true)" -eq 1 ] \
    || fail "never-announced recovery did not surface exactly once: $(cat "$out")"
  [ "$(cat "$home/state/.watcher-down")" = 'announced:downtime:unreported.1.aaa' ] \
    || fail "never-announced recovery did not retain its announced generation"
  pass "a never-announced recovery still surfaces once from a foreground checkpoint"
}

test_queue_append_during_checkpoint_still_resurfaces() {
  local home out err status checkpoint_pid
  home=$(make_home queue-append)
  out="$home/out.txt"
  err="$home/err.txt"

  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" &
  checkpoint_pid=$!
  wait_for_checkpoint_lock "$home" || {
    kill "$checkpoint_pid" 2>/dev/null || true
    wait "$checkpoint_pid" 2>/dev/null || true
    fail "queue-append checkpoint did not take the watcher lock"
  }
  append_wake "$home/state" check concurrent 'check: appended during checkpoint' \
    || fail "could not append a durable wake during the checkpoint"
  status=0
  wait "$checkpoint_pid" || status=$?

  expect_code 0 "$status" "queue-append checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "queue append during checkpoint did not resurface"
  grep "$(printf '\tcheck\tconcurrent\tcheck: appended during checkpoint')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "queue append was not retained durably after checkpoint recovery"
  pass "a queue append during a foreground checkpoint still resurfaces"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home f
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
  # QUIET), so the checkpoint keeps its attended bound beside it.
  for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The Codex owner stays file-gated: without config/supervision-host, or with
# config/supervision-host-off, the checkpoint never runs the host.
test_host_checkpoint_needs_the_file_and_honors_off() {
  local home line
  home=$(make_host_home host-gate)
  for line in - off; do
    rm -f "$home/config/supervision-host" "$home/config/supervision-host-off" "$home/host-env"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    run_host_checkpoint "$home" boundary --seconds 1
    [ ! -e "$home/host-env" ] || fail "a Codex home whose config/supervision-host is ${line/-/absent} ran the supervision host"
  done
  pass "checkpoint: a Codex home without config/supervision-host, or with an off file, never runs the host"
}

# A check carrying `# fm-check-interval: <seconds>` runs on its own cadence
# while checks without the marker keep the FM_CHECK_INTERVAL default: with the
# default far above either checkpoint bound, only the marked check may fire.
test_per_check_interval_runs_one_check_faster_than_the_default() {
  local home seed_status seq gen seed_epoch fast_stamp_mtime slow_stamp_mtime
  home=$(make_home per-check-interval)
  cat > "$home/state/fast.check.sh" <<'SH'
#!/usr/bin/env bash
# fm-check-interval: 1
printf 'fast check fired\n'
SH
  cat > "$home/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'slow check fired\n'
SH
  chmod 0700 "$home/state/fast.check.sh" "$home/state/slow.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" fast >/dev/null \
    || fail "could not register the fast custom check"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" slow >/dev/null \
    || fail "could not register the slow custom check"
  # First-ever sweep fires every check (no stamps yet); once the wake is
  # acknowledged and recovery announced, the second sweep is the measured one.
  seed_status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 5 >"$home/seed.out" 2>"$home/seed.err" || seed_status=$?
  expect_code 0 "$seed_status" "the seeding checkpoint did not fire: $(cat "$home/seed.out" "$home/seed.err")"
  grep -F "slow check fired" "$home/seed.out" >/dev/null || fail "the seeding sweep skipped the unmarked check"
  seq=$(awk -F'\t' 'END{print $2}' "$home/state/.wake-queue")
  gen=$(sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p' "$home/seed.err" | head -1)
  [ -n "$gen" ] || gen=$(sed -n 's/^pending:downtime://p' "$home/state/.watcher-down" | head -1)
  [ -n "$gen" ] || gen=$(sed -n 's/^announced:downtime://p' "$home/state/.watcher-down" | head -1)
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 \
    || fail "could not acknowledge the seed wake (seq=$seq gen=$gen marker=$(cat "$home/state/.watcher-down" 2>/dev/null))"
  seed_epoch=$(date +%s); sleep 2.2
  # The polling watcher re-tocks its sweep gate once per FM_POLL cycle, so the
  # marked check's next run lands on the next poll, not mid-sleep. The fast-
  # window checkpoint may also exit first on the recovery announcement; the
  # stamp times are the measured evidence.
  FM_HOME="$home" FM_POLL=0.5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 5 >"$home/fast.out" 2>"$home/fast.err" || true
  fast_stamp_mtime=$(stat -f %m "$home/state/.last-check/fast.check.sh" 2>/dev/null || stat -c %Y "$home/state/.last-check/fast.check.sh")
  slow_stamp_mtime=$(stat -f %m "$home/state/.last-check/slow.check.sh" 2>/dev/null || stat -c %Y "$home/state/.last-check/slow.check.sh")
  [ "$fast_stamp_mtime" -ge "$seed_epoch" ] \
    || fail "the 1-second marked check did not re-run inside the fast window (stamp $fast_stamp_mtime < seed $seed_epoch): $(cat "$home/fast.out" "$home/fast.err")"
  [ "$slow_stamp_mtime" -le "$seed_epoch" ] \
    || fail "the unmarked check re-ran before its FM_CHECK_INTERVAL elapsed"
  pass "per-check interval: a marked check runs on its own cadence while unmarked checks keep FM_CHECK_INTERVAL"
}

# When an earlier check (alphabetically first) emits on every sweep, a later
# check must still run and stamp in the same sweep: waking mid-sweep exits
# the watcher before the later check's stamp advances, which starved
# propel-ready/slack-unreads behind peers/gh-events in the live home (2026-10-16).
test_sweep_runs_every_due_check_before_waking() {
  local home status
  home=$(make_home sweep-starvation)
  cat > "$home/state/aaa-first.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'first check fired\n'
SH
  cat > "$home/state/zzz-last.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'last check fired\n'
SH
  chmod 0700 "$home/state/aaa-first.check.sh" "$home/state/zzz-last.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" aaa-first >/dev/null \
    || fail "could not register the leading check"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" zzz-last >/dev/null \
    || fail "could not register the trailing check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=3 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 10 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 0 "$status" "the sweep checkpoint did not surface the firing checks: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "first check fired" "the leading check's wake did not reach the checkpoint"
  assert_contains "$(cat "$home/out.txt")" "last check fired" \
    "the trailing check starved: the wake exited the sweep before its due run"
  [ -e "$home/state/.last-check/aaa-first.check.sh" ] || fail "the leading check left no stamp"
  [ -e "$home/state/.last-check/zzz-last.check.sh" ] \
    || fail "the trailing check left no stamp, so a restart would starve it again"
  grep -E '	[0-9]+	check	.*/aaa-first\.check\.sh	.*first check fired' "$home/state/.wake-queue" >/dev/null \
    || fail "the leading check's queue row is missing its reason"
  grep -E '	[0-9]+	check	.*/zzz-last\.check\.sh	.*last check fired' "$home/state/.wake-queue" >/dev/null \
    || fail "the trailing check's queue row is missing its reason"
  pass "sweep: every due check runs and stamps before the wake, so a restart cannot starve trailing checks"
}



# The real host under a fake Codex harness that holds the home's session lock.
# shellcheck disable=SC2016 # the fake harness's script expands in its own shell
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

test_quiet_checkpoint_exits_124_cleanly
test_perl_timeout_fallback_honors_cleanup_bound_before_escalating
test_announced_recovery_is_not_reannounced_by_next_checkpoint
test_never_announced_recovery_is_announced_once
test_queue_append_during_checkpoint_still_resurfaces
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_per_check_interval_runs_one_check_faster_than_the_default
test_sweep_runs_every_due_check_before_waking
test_real_host_checkpoint_ends_quietly_at_its_bound
