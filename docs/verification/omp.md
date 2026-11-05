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

omp re-binds extension factories per subagent session (task tool, eval `agent()`, `/tan` clones) on the same evaluated module, so module state is shared with the primary.
Observed on omp 18.10.4 (2026-10-14) with `FM_OMP_EXTENSION_DEBUG_LOG` set: the rebind runs in the parent process right after `before_subagent_spawn`, before any subagent event and with no ctx; the subagent's `session_start`, `before_agent_start`, and `agent_end` then carry `ctx.agent = { kind: "sub", name: "task", depth: 1, parentId: "Main" }` and the primary's carry `{ kind: "main", id: "Main", depth: 0 }`; no subagent `session_shutdown` followed its completion.
The watch extension's factory therefore activates its generation only when no live generation exists, so a rebind never displaces the primary's.
Before that rule, the rebind made the subagent's generation the active one: the primary's read as not live, its next actionable close was dropped undelivered with no successor, and `fm_watch_arm_omp` answered `watcher: not armed - omp session is shutting down`.
The turn-end guard's factory bind touches no shared module state; its active sessionstart generation was unchanged across the same rebind.
Every lifecycle handler and arming entrypoint stands down on a subagent context.
Destructive shutdown requires an explicit main identity when an agent property is present; missing, malformed, null or unknown kinds do not gain authority merely because the same process owns the primary lock.
Older contexts without an agent property retain the lock-owner check.

- Portable regression: `tests/fm-omp-harness.test.sh` exercises real child ownership, ambiguous shutdowns, exact worker/secondmate argv consumption, host handoff, acknowledged-wake suppression and genuinely fresh wake delivery.
- Live guard: `FM_OMP_SUBAGENT_SMOKE=1 tests/fm-omp-subagent-smoke-e2e.test.sh` uses real OMP RPC receipts, a child-only nonce, the same live arm PID across subagent completion, and delivery of a queued wake with a live successor.
- Latest refresh: 2026-11-05 on macOS arm64, omp18.10.4; all six live checks passed without a production-home update or multiplexer pane.

```sh
FM_OMP_SUBAGENT_SMOKE=1 FM_OMP_LIVE_MODEL=openai-codex/gpt-6.1-sol bash tests/fm-omp-subagent-smoke-e2e.test.sh
```

Observed output includes:

```text
ok - extensions auto-discovered in the lab
ok - session-start digest reached model context
ok - after the subagent the arm command retains the same live primary arm
```

The guard checks parsed RPC fields and kernel PID liveness rather than arming-result prose.
Process identifiers and complete run receipts remain private task evidence.
- Debug log: `FM_OMP_EXTENSION_DEBUG_LOG=<absolute file>` before omp starts makes both tracked extensions append one JSON line per factory bind and per lifecycle event they observe (`session_start`, `before_agent_start`, `agent_end`, `session_shutdown`; the watch extension also logs `before_subagent_spawn`, arm calls, and arm child closes) with the ctx agent shape, session id, process ids, and the code path taken; `.pi/extensions/lib/fm-extension-debug.ts` owns the line format.

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
This posture became safe once the subagent-session stand-down above landed, including the factory-bind rule that keeps the primary's generation active across a subagent rebind (the earlier 2026-10-08 and 2026-10-13 incidents are recorded in the home's `data/learnings.md`).

## Steering inbox dropped-delivery recovery

The listener header in `.omp/extensions/fm-inbox-listener.ts` owns its consumption, bounded idle retry and at-least-once contract.
`bash tests/fm-inbox-listener.test.sh` exercises a dropped queued follow-up without skipping the first record, busy and `willContinue` suppression, exact-consumption acknowledgement, late duplicate consumption and synchronous consumption during send.
On 2026-10-30 with Node26.7.0, the new dropped-delivery regression failed before the change with `idle dropped delivery did not recover in order`, then the complete changed file passed.
A separate real-interval Node host of the actual extension delivered two durable records with three sends after deliberately dropping the first send, and moved both records only on exact consumption.
That smoke did not rerun a native omp interrupt or launch a worker; it is extension/timer/filesystem evidence, not a fresh vendor-runtime cancellation result.

