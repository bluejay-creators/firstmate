# Run 2: live quiet-mode validation on an omp 18.8.7 primary (2026-10-10, target 4ff62989)

Lab: disposable `$TMPDIR/fm-lab.*` holding a clone of the target commit, a private tmux server
(`-L fm-lab`, 180x45), a real `omp --no-session --model openai-codex/gpt-6-astra` primary started in
that clone (FM_HOME = the clone, machine's existing omp login), and the real quiet daemon launched by
`bin/fm-afk-launch.sh enter` + `start` (FM_AFK_MODE=quiet, FM_SUPERVISOR_TARGET=%0). Torn down in the
same run; no fleet session, pane, or home was touched. Round 1's files (no `run2-` prefix) came from
the previous commit 9230e9e; only the composer idle regex and its test changed since.

- `run2-omp-18.8.7-composer-state-live.txt`: the real `fm_tmux_composer_state` on the live pane:
  idle with the learn-once hint `empty`, `hello captain` typed `pending`, erased `empty`; the
  base-commit (fb75c1f) libraries read all three `unknown`. Byte captures:
  `run2-omp-18.8.7-idle-pane-with-hint.ansi.txt`, `run2-omp-18.8.7-typed-pane.ansi.txt`,
  `run2-omp-18.8.7-idle-after-erase.ansi.txt`.
- `run2-omp-arm-command-pane.txt`: `/fm-watch-arm-omp` armed watcher 72253 through the extension.
- `run2-quiet-entry.txt`: quiet-check, enter, start; daemon launched in a detached lab tmux session.
- `run2-quiet-routine-signal-handoff.txt`: a routine `working` status under quiet. The pre-quiet
  extension watcher exited `reason=actionable-signal successor=none` (extension stood down, no
  successor beside the daemon); the omp pane hash was unchanged before and after.
- `run2-quiet-failure-escalation.txt`: an appended `failed` status under quiet: daemon
  `wake: signal` -> `escalate:` -> doorbell injected into the omp composer; the model opened a turn;
  `state/.afk` still `quiet`. (The first `failed` write replaced the status log in place, a fixture
  error: the daemon's recorded offset sat past it and it read `already escalated`; appending, as the
  product does, escalated at once.)
- `run2-quiet-daemon.log`: idle on `watcher: already running pid 72253`, `wake: check: rearm-resurface`,
  `self-handle: ... routine signal: working` (no injection), `wake force-self: heartbeat` (no
  injection), `escalate: ... failed`, `daemon shutting down`.
- `run2-quiet-exit-and-rearm.txt`: `bin/fm-afk-launch.sh stop` cleared the flag; within 700 ms the
  extension re-armed watcher 68877 with no tool call; its ancestry is fm-watch.sh <- fm-watch-arm.sh
  <- omp (pid 48152).
- `run2-omp-primary-full-transcript.txt`: the whole primary scrollback. Lines that reached the
  conversation: the arm result, one failure doorbell under quiet, and after quiet exit the single
  documented `check: rearm-resurface` wake. The routine signal and the heartbeat produced nothing.
- `unit-fm-composer-lib.log`, `unit-fm-omp-harness.log`, `unit-fm-watch-triage-quiet.log`: the
  targeted test files (the triage log is the two new quiet tests run alone).
