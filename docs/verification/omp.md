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
clones) with fresh APIs but shared module state. On 18.8.x the handler ctx
carried `ctx.agent.kind === "sub"` for those sessions; on 18.10.x kind is not
reliably readable on shutdown, so the Firstmate tracked extensions also take
`ctx.agent.depth > 0` as a subagent, and treat any ambiguous ctx (absent
agent, absent kind, or an unrecognized kind) as a subagent whenever
`lockOwnership()` says this process is not the fleet's owning primary - a
fleet-owning primary keeps main semantics. A subagent session never claims,
consumes, retires, or re-arms the supervisor's watcher, never persists the
replacement handoff, and its shutdown leaves the primary generation live.

- Portable regression: `tests/fm-omp-harness.test.sh`
  `test_watch_extension_subagent_session_never_touches_the_arm`,
  `test_turnend_guard_subagent_session_stands_down`,
  `test_watch_extension_subagent_gate_recognizes_1810_shapes`, and
  `test_turnend_guard_subagent_gate_recognizes_1810_shapes`, driven over a
  fake omp API against the 18.8 and 18.10 ctx shapes alike.
- Live guard: `FM_OMP_SUBAGENT_SMOKE=1 tests/fm-omp-subagent-smoke-e2e.test.sh`
  arms the watcher in a real `omp --mode rpc` session, runs one task-tool
  subagent that must answer `SUBAGENT_RAN`, asserts the same watcher pid is
  alive afterwards, then writes the `.meta` plus `.status` pair every e2e uses
  and asserts the watcher ledger records `reason=actionable-signal` - the
  observable proof the subagent lifecycle did not wed the cycle.
  Latest run: 2026-10-14, omp 18.10.4, model `openai-codex/gpt-6-astra`;
  raw output under the task's `data/fm-subagent-1810/smoke.out`.

## Hidden wake delivery (2026-10-14)

The supervisor's primary omp session delivers actionable watcher wakes to
its main as a hidden custom message instead of a visible banner:
`pi.sendMessage({ customType: "fm.wake", content: ..., display: false },
{ triggerTurn: true, deliverAs: "followUp" })`; on omp 18.10.4 the host
call is void (packages/coding-agent/src/modes/runtime-init.ts starts the
send, catches its own errors, and returns nothing), so acceptance - not a
resolved promise - confirms delivery, exactly as for `sendUserMessage`.
Before that call the extension runs `bin/fm-wake-drain.sh --brief --ack`
to retire the durable row and produce the one-line summary the model
actually consumes. The drain presents its rows on stdout and the
`WAKE_ACK_REQUIRED` marker on stderr; the extension parses both channels,
keeps the ack contract out of the delivered text, and acknowledges exactly
the presented cutoff in-extension once the send is accepted, so each wake
carries only not-yet-delivered rows and the queue leaves no residue for a
later wake to repeat (the 2026-10-14 repetition and visible-render defects,
when a stdout-only parse never saw the marker and never acked).
An acknowledgement failure surfaces loudly and keeps the rows queued; the
matching `role:"custom"` `message_start` finishes the pending handoff
record so a session replacement cannot replay it. A drain failure, missing
`sendMessage`, or rejected send falls back to today's visible
`sendUserMessage` banner, which acknowledges the same presented cutoff.
Verified under `tests/fm-omp-harness.test.sh`:
`test_watch_extension_sends_a_hidden_wake_through_sendMessage`,
`test_watch_extension_falls_back_to_sendUserMessage_when_sendMessage_fails`,
`test_watch_extension_acks_each_presented_wake_once_so_it_never_repeats`,
and `test_wake_drain_brief_ack_places_the_ack_marker_on_stderr`.

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
