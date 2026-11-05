# Beads propulsion dispatcher

The bounded propulsion dispatcher turns ready Beads work into accountable assignment.
It is a small change controller, not a scheduling framework: firstmate remains the accountable owner of every dispatch, and the dispatcher only computes a plan and surfaces decision points.
The behavioral contract below is the single owner; `bin/fm-propel.sh`'s header cross-references this page instead of restating it.

## Private configuration

The dispatcher and peer roster resolve the shared board from an explicit `FM_BOARD` override, otherwise `config/beads-board` under the effective `FM_HOME`.
This board resolver does not honor `FM_CONFIG_OVERRIDE`, and neither consumer has a built-in shared-board path.
[`bin/fm-bead-board-lib.sh`](../bin/fm-bead-board-lib.sh) owns the board-file format and path resolution.
The existing `config/propel-beads-dir` still selects only this home's discovery board.

Private `config/propel-domains` supplies ordered domain labels, one per line with blank lines and comments ignored.
The first configured matching domain selects the domain used for assignment.
Private `config/propel-profile.json` supplies one profile object with harness `omp` and a nonblank `model`; propulsion refuses a missing profile, an array, another harness, or an effort override rather than choosing or inventing a profile.
These domain and profile reads use `FM_CONFIG_OVERRIDE` when set, otherwise the effective home selected by `FM_HOME`, `FM_ROOT_OVERRIDE`, then the tracked code root.
Missing or invalid required settings stop propulsion without a dispatch.
[`bin/fm-propel.sh`'s header and help](../bin/fm-propel.sh) own the exact configuration and invocation contract.

The propulsion pin is independent of global `config/crew-dispatch.json` rules/defaults. Moving an existing propulsion default into private configuration must not change how unrelated workers are routed.
Installing private settings and activating the source change are separate from merging it.

## State machine

Each run walks the same six stages in order.

1. **DISCOVER.** Reads this home's ready beads from the `.beads` store configured in `config/propel-beads-dir` (the home itself when it holds `.beads`), intersected with the privately configured shared board's `bd --readonly --sandbox list --status open`.
   When this home has no board of its own, the shared board is the discover surface too.
2. **FILTER.** A bead is dropped when `bd ready` did not name it, when the title already sits `in_flight` or `queued` in this home's tasks-axi backlog, when a `state/<task-id>.meta` names matching work already under way in any local home, or when the roster has zero idle panes (a capacity gate, never silently an external wait).
3. **CLASSIFY.** Labels route each surviving bead to `ship`, `scout`, or `captain`.
   `captain` beads and beads with an explicit `model:<name>` label are surfaced as decision lines in the plan, never dispatched; everything else is `ship` or `scout`.
4. **ASSIGN.** Pairs a ship- or scout-class bead with one stable assignee: an idle roster pane first, then a registered secondmate whose `data/secondmates.md` scope covers the bead's domain, then at most one fresh crewmate per run.
   Every planned dispatch is pinned to omp and the privately configured propulsion model; another harness or model requires an explicit captain decision.
   `config/project-capacity` capacity is `bin/fm-propel-pane-check.sh`'s verdict, delegated to `bin/fm-project-capacity-lib.sh`.
5. **RECURSE.** A readiness blocked on an open bead routes the blocker as the new actionable item; the waiter keeps waiting.
6. **TIME GATES.** `deferred` beads, or `defer_until`-gated ones, are external waits surfaced through the durable wake queue at their gate date instead of active assignment.

## Surface

A dry run is the default and writes `state/.propel-plan.json` (private mode 0600) and a one-line-per-action plan with the pinned harness on each dispatch row.
`--only-tasks=<id>[,<id>...]` pins the whole plan - actions and time gates - to the named board beads.
`--emit-wakes` (the mode the registered custom check uses) prints only fresh surfaces, gated by `state/.propel-wake-gates/`: one `propel: dispatch <bead> -> <assignee>` per dispatching action, plus each fresh captain decision and time gate, so an idle plan and every repeated poll print nothing at all.
Every source read is read-only: `bd` always runs with `--readonly --sandbox`, `tasks-axi` only lists, the roster only observes, and the dispatcher writes only inside this home's own `state/`.
An unknown source anywhere sets the verdict to `unknown` and emits no dispatch at all.

## Registered check

The custom watcher check `state/propel-ready.check.sh` is this dispatcher invoked with `--emit-wakes`; it trips only when the plan carries a fresh dispatch, captain decision, or time gate.
Registration binds the check to its bytes through `bin/fm-check-register.sh propel-ready`; `docs/configuration.md`'s custom-check section owns the trust model.

## Why bounded

The dispatcher never mass-spawns, never claims a dispatch without an observable pane/worktree/branch attached, and never reinterprets a capacity gate as an external wait.
Autoscaling, fair queueing across projects, and shadow-vs-liveness plurality stays with firstmate supervision; the dispatcher only names what firstmate would notice next.

## Task accountability and committed deadlines

The separate accountability observation uses the same configured Beads board, native dependency edges and `bd ready`; it does not run this dispatcher.
[`bin/fm-bead-accountability-check.sh`](../bin/fm-bead-accountability-check.sh) owns check installation and [`bin/fm_bead_accountability.py`](../bin/fm_bead_accountability.py) owns polling and ETA recording.
The check runs in the board's one owning home, using its existing Inbox and check registration rather than a second scheduler or notification service.
Its findings name an owner or data defect; the responsible session advances already authorized work without another permission request.
It never launches a worker, changes an assignee, renews a lease or overrides a protected-action approval.
The hot owning session retains its existing session/task lease and consolidates any separately authorized helpers.

### Board contract

`assignee` is the single accountable principal, never the bead creator's `owner` field or a comma-separated owner list.
Blocking `blocks` and `waits-for` edges between nonterminal tasks must be acyclic.
An active blocked task must name a live dependency or an explicit wait.
`deferred` status, a future `defer_until`, or the labels `parked`, `deferred`, `deprioritized`, `snoozed` and `consolidation` suppress progress and deadline escalation.
An additional `metadata.wait` has a `kind` of `parked`, `deferred`, `consolidation`, `external` or `approval`, a nonempty `reason`, and an optional timezone-aware `until`.
A dated wait expires rather than suppressing work indefinitely.
Waiting does not excuse an ownerless task or a dependency cycle.
Captain-labelled tasks remain with the captain-request loop, not agent deadline notices.
Use [`fm_route_ask.py`](../bin/fm_route_ask.py) for a routed captain ask; its `--help` owns durable coupling, replay and orphan-check mechanics.

Ready-but-unstarted work is observed until it leaves `bd ready`.
Unrelated board edits do not reset that observation clock.
The grace period reuses `eta:<N>m`/`eta:<N>h` and `config/bead-eta-defaults`, with a 240-minute ready-work fallback.
This duration is an observation threshold, not an invented committed deadline.

### Named person waits and follow-ups

For a task waiting on someone else, use native `blocked` status, the `waiting` label, a nonempty `metadata.waitingon`, and timezone-aware native `due_at` as its follow-up date.
This is the Beads equivalent of Taskwarrior's waiting status, `+waiting`, `waitingon` and `due`; it is not a second copy of a personal task.
The task is idle until that date or an explicitly recorded `metadata.waiting_reply` containing an actual reply's `id` and the matching episode's `waitingon` and `due_at`.
The owning agent records that receipt during its existing inbox handling; an arbitrary update timestamp is never treated as a reply, and the check does not invent a person-to-message correlation.
A retained receipt for a different person or follow-up date cannot release a renewed wait.
Other explicit deferral, consolidation or approval waits still take precedence.

One board/task/person/follow-up-date tuple defines one waiting episode.
At its first reply or date trigger, the check emits one follow-up and delivers one idempotent Inbox item; a later reply after the date does not raise it again.
It does not dispatch work or emit a second overdue/ready notice while that same named wait awaits owner action.
The owner resumes the task by clearing the waiting label/receipt and native blocked state, or records a new future follow-up; use `waiting_reply: null` to clear a receipt because Beads metadata updates merge omitted keys.
Retain unrelated task metadata and the received reply's source reference; revising a wait is not permission to erase a missed committed ETA or skip its owner-authored revision.
Without a message-to-task binding, reply-driven automatic correlation cannot be inferred safely; the existing owning agent must record the positive receipt.


### ETA authority and slip receipts

The bead metadata stores `eta` as an explicit-timezone date, `etaby` as its committing assignee, `eta_reason` as the current owner-authored explanation, and `eta_history` as an array of retained revisions.
The ETA command requires the current single assignee, a future date and a nonempty reason.
Each revision retains the new date/author, `recorded_at`, the reason and the previous date/author; it updates the metadata in one Beads write while preserving other metadata.
A changed `updated_at` never moves the committed deadline.
The owner must revise a slipped commitment; the checker only reports missing or late information and never invents a reason.
The owner argument is an accountability check against the bead, not a new authentication or permission system.

One missed date/author pair on one board/task defines one Inbox notification identity.
The same identity is used whether first observed overdue or discovered later in retained revision history.
The Inbox notice points back to the bead for its current reason and date, so it is not a stale second ETA store.
Existing `fm-inbox.sh note --request-id` and `announce` make delivery durable and retryable, including a crash after note acceptance but before the local receipt.
Private check state contains only readiness observations and finding/delivery receipts.
A board or Inbox failure is reported as unavailable, never counted as a delivered notice.

### Activation boundary

Install the check only after the source change and activation are separately approved.
Reconcile the older private agent-ready and duration-only monitors during that activation so each operational signal has one owner; preserve any distinct captain-request monitoring.
The committed-date check does not reinterpret an old duration label as a promised finish date.
The focused regression is `tests/fm-bead-accountability.test.sh`; runtime acceptance uses an isolated board and Inbox, never a live dispatch or customer operation.

