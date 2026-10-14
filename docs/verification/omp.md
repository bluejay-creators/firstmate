# omp verification

Live-harness evidence for the omp (Oh My Pi) primary, refreshed by the named
commands rather than carried as undated claims.
The portable regression in `tests/fm-omp-harness.test.sh` runs in CI with no
omp installed; what follows is the surface only a real omp can answer.

## Watcher and turn-end ownership

`FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh` is the opt-in live
guard for the tracked `.omp/extensions` pair: auto-discovery, digest delivery
through `before_agent_start`, one `fm_watch_arm_omp` arm, an actionable close
with a successor and exactly one follow-up wake, and a compelled `session_stop`
continuation when the watcher is frozen past guard grace.
Its header owns the lab mechanism.

## Subagent session safety

omp re-binds extension factories per subagent session (task tool, `/tan`
clones) with fresh APIs but shared module state, and the handler context
carries `ctx.agent.kind === "sub"` for those sessions (omp's
`docs/extensions.md`, 18.8.x).
The Firstmate tracked extensions stand down on that discriminator, so a
subagent session never claims, consumes, retires, or re-arms the supervisor's
watcher, never persists the replacement handoff, and its shutdown leaves the
primary generation live.

- Portable regression: `tests/fm-omp-harness.test.sh`
  `test_watch_extension_subagent_session_never_touches_the_arm` and
  `test_turnend_guard_subagent_session_stands_down`, driven over a fake omp
  API with a `ctx.agent.kind === "sub"` context.
- Live guard: `FM_OMP_SUBAGENT_SMOKE=1 tests/fm-omp-subagent-smoke-e2e.test.sh`
  arms the watcher in a real `omp --mode rpc` session, runs one task-tool
  subagent that must answer `SUBAGENT_RAN`, asserts the same watcher pid is
  alive afterwards, then writes the `.meta` plus `.status` pair every e2e uses
  and asserts the watcher ledger records `reason=actionable-signal` - the
  observable proof the subagent lifecycle did not wed the cycle.
  Follow-up wake delivery against that close is owned by
  `tests/fm-omp-primary-live-e2e.test.sh` and is not re-verified here.
  Latest run: 2026-10-14, omp 18.8.7, model `openai-codex/gpt-6-astra`; raw
  output under the task's `data/fm-subagent-safe/smoke.out`.


## In-process subagents as supervisor dispatch

The omp primary prefers in-process subagents for bounded read-only or short
investigative work, with `bin/fm-spawn.sh` reserved for work that changes a
project, needs an isolated worktree or branch, must outlive the turn, or runs
long (`.agents/skills/harness-adapters/references/harness/omp.md`).
This posture became safe once the subagent-session stand-down above landed;
before it, a subagent's own `session_shutdown` ran `stopSessionGeneration`
against the shared generation, retiring the primary's arm and leaving
`fm_watch_arm_omp` answering `watcher: not armed - omp session is shutting
down` until omp restarted (incidents 2026-10-08 and 2026-10-13, recorded in
the home's `data/learnings.md`).
