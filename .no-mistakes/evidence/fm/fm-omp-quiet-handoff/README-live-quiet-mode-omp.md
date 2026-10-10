# Live quiet-mode validation on an omp 18.8.7 primary (2026-10-09)

Lab: disposable directory under $TMPDIR holding a clone of the target commit (9230e9e),
a private tmux server (`-L fm-lab`, 180x45), a real `omp --model openai-codex/gpt-6-astra`
primary started in that clone with the machine's normal omp login, and the real
`bin/fm-supervise-daemon.sh` launched by `bin/fm-afk-launch.sh start` from the primary's own
bash tool. Torn down in the same run. No fleet session, pane, or home was touched.

Why a clone and not the gate worktree: `bin/fm-watch-arm.sh` refuses every mode from a path
under `.no-mistakes/worktrees/` unless `fm_gate_lab_permitted` holds, and that requires every
`FM_*_OVERRIDE` to be empty; the omp extension always passes `FM_ROOT_OVERRIDE` and
`FM_CONFIG_OVERRIDE` to its arm child, so the extension-owned arm cannot run from the gate
worktree even against a marked lab home (pre-existing, not part of this change). The
repository's own `tests/fm-omp-primary-live-e2e.test.sh` uses the same clone layout.

## Composer classifier on the live pane
- `omp-18.8.7-composer-state-live.txt`: `fm_tmux_composer_state` read the real idle pane
  (learn-once hint showing) as `empty`, `hello captain` typed as `pending`, erased as `empty`;
  the base-commit (fb75c1f) copy of the same libraries read the same live idle pane `unknown`.
- `omp-18.8.7-idle-pane-with-hint.ansi.txt`, `omp-18.8.7-typed-pane.ansi.txt`: byte captures
  (`capture-pane -p -e`) of those panes.

## Quiet-mode ownership
- `omp-quiet-entry-pane.txt`: the primary entered quiet mode through its bash tool; the daemon
  launched in a detached lab tmux session supervising pane %0.
- `quiet-daemon.log`: daemon idled on `watcher: already running pid 2849` (the pre-quiet
  extension watcher), then after that watcher handed off: `wake: check: rearm-resurface`,
  `self-handle: signal: ... demo.status -> routine signal: working ...` (no injection),
  then `escalate: ... failed [at=...]: pipeline broke on demo`.
- `watch-cycle-exits.log`: the pre-quiet arm (2794/2849) closed `reason=actionable-signal`
  with `successor=none` (extension stood down, no successor beside the daemon); after quiet
  exit the self-re-armed cycle (26251/26271) closed `actionable-check` with
  `successor=started:26777`.
- `omp-quiet-failure-escalation-pane.txt`: the failure digest typed into the live omp
  composer and the model's reply; quiet stayed active.
- `omp-primary-full-transcript.txt`: the whole primary scrollback. The routine `working`
  signal produced no turn (pane hash unchanged); `fm_watch_arm_omp` under quiet returned
  `watcher: unchanged - the daemon owns supervision while state/.afk exists ...` and spawned
  no child; after `bin/fm-afk-launch.sh stop` the extension re-armed with no tool call, and
  the one expected `check: rearm-resurface` wake was delivered once.
