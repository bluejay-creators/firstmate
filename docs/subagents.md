# Worker and subagent policy

This document is the policy owner for how firstmate agents delegate work downstream: when work goes to an in-session subagent versus a spawned worker pane, the local resource-safety limits every agent must hold, and the authority boundary a downstream agent can never cross.
`docs/subagent-guard.md` owns the complementary fence in the other direction: a primary session reaching for its harness's own delegation tool to bypass fleet dispatch.

Until the enforcement roadmap below lands, every rule here is a brief-level rule rather than a mechanically enforced one.
The parent agent who issued the brief is accountable for the downstream agent's conduct, and the captain has named that accountability explicitly.

## When to delegate, and to what

- In-session subagents (the harness's task tool) are the default for delegated work inside firstmate and second-mate homes.
- Spawn a worker pane only when a subagent genuinely cannot do the work, and say why at spawn time.
  The opt-in `--worker-reason` gate (fork issue #28) enforces this fail-closed; [`docs/configuration.md`](configuration.md) owns its configuration contract.
- Scouts are read-only investigators; they never edit.

## Resource safety on the Mac

The fleet host is memory-constrained, and agent jobs have already caused memory exhaustion and kernel panics (see the incident record below).
These limits apply to every firstmate and second-mate agent and everything it delegates:

- Never run full lint suites, full test suites, or parallel test runs locally.
  Run only the changed test files, one at a time, each with a timeout.
- At most one subagent at a time per agent.
- When waking several agents after a restart or an alert, stagger the wakes rather than starting them in one burst.
- A memory guard check and an alert-only auto-kill watchdog back these limits.
  The Mac supervisor agent is the first responder to a guard alert and decides whether to pause or kill the job; firstmate is always kept informed.
  When the Mac agent is unresponsive or the situation is an emergency, firstmate acts on the alert itself; firstmate resumes any jobs it had paused once pressure clears.

## Authority boundary

Unless the brief names that exact action with the captain's explicit approval, a downstream agent (worker or subagent) must never:

- merge anything,
- force-push,
- read secret values: no `secret get`, no keychain reads, no printing credentials of any kind, or
- run destructive or infrastructure-mutating operations, including apply, destroy, and delete against real infrastructure and any cloud ssh path that can publish keys.

A past approval is never precedent: an action approved for one task grants no standing permission for the next.
Decisions that are bounded and reversible are made in-line and reported as `note:` lines, not escalated.

## Brief requirements

Every brief that dispatches downstream work must:

- restate the authority boundary and the resource-safety limits above explicitly, because a downstream agent does not inherit this document,
- name the worktree the worker operates in,
- require serial work, not parallel fan-out, and
- name the deliverable: a PR URL or a written report.

The parent verifies the worker's claims before treating the task as done; a reported check that was never run does not count.

## Enforcement roadmap

Mechanical enforcement is being designed under bead `fm-3r5y`, in two parts:

- Role-scoped credentials: workers and subagents get credentials that can push branches and open pull requests and nothing more.
  Merges go only through the guarded `fm-pr-merge` path under a separate token, and secrets sit behind the broker rather than in a readable file.
- Per-role omp policy overlays: a deny list scoped to each role, pending verification that omp can scope policy per subagent.

Until both parts land and are verified, the rules above hold as brief-level rules and the parent is accountable for them.

## Incident record

October 16-17, 2026, is the motivating incident:

- Full lint and full test suite runs caused memory exhaustion and two kernel panics on the fleet Mac host.
- After the reboot, several agents were woken simultaneously, compounding the memory pressure.
- A subagent printed credential values.
- A subagent force-pushed a branch.
- A subagent merged two pull requests, citing a past approval as precedent.
- A destructive re-apply was run against a development box.

No secret values appear in this record; the facts above are the policy rationale, not the evidence trail, which stays in the private task reports.
