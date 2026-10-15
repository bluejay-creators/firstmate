// Firstmate primary watcher bridge for omp (Oh My Pi).
//
// A port of .pi/extensions/fm-primary-pi-watch.ts for the omp fork. The arm,
// successor, retry, and replacement-handoff logic follows the Pi contract;
// the omp-specific differences are stated once here:
//   - omp auto-discovers this file from <cwd>/.omp/extensions with no trust
//     gate, so an omp primary or secondmate started inside its home loads it
//     without -e (naming it both ways loads it twice - verified, omp 18.1.11).
//   - pi.sendUserMessage returns synchronously (no promise) in omp, so "Pi
//     accepted the follow-up" collapses to "the call returned"; consumption is
//     still tracked at before_agent_start / message_start exactly as on Pi.
//   - omp reports no session_shutdown reason, so EVERY shutdown with a pending
//     actionable close persists the replacement handoff and the next owning
//     session_start, in this process or a later one, replays it. Replaying a
//     wake main has already drained is harmless (the queue is durable and the
//     drain is idempotent); losing one across /new is not.
//   - Replacement shutdown retires the established predecessor arm before the
//     successor arms; unlike Pi, it is not retained until a distinct active
//     successor generation commits its own arm, so omp keeps the plain
//     teardown-and-rearm replacement shape.
//   - The Pi supervision branch is out of scope for omp: every actionable wake
//     is delivered to main, so no branch offer is made and no calm presentation
//     hooks exist.
//   - The arming tool is fm_watch_arm_omp and its human fallback
//     /fm-watch-arm-omp; the loaded-build marker is state/.omp-watch-extension-loaded.
//   - Supervision host: a home opted in with config/supervision-host
//     (docs/configuration.md "Supervision host" owns the gate, which
//     bin/fm-supervision-engine-lib.sh enabled answers; config/supervision-host-off opts out) spawns
//     bin/fm-supervision-host.sh park --restart in the arm's place, which
//     takes away-posture wakes itself and closes only when main is needed; its
//     header owns the output read here. A "supervision-host:" line is
//     actionable like a wake line, and the message delivered at the host's
//     close carries every such line in order while wake lines keep an
//     eight-line cap. The host
//     prints the first cycle's status line as soon as it is verified, so
//     readiness and the handling handoff work as they do for the arm, with a
//     longer readiness budget for the host's own startup. On a home that does
//     not run the host nothing below changes.
//
// Session-generation ownership (stated once here):
// omp emits session_shutdown for ordinary same-process replacements (/new,
// /resume, /fork) as well as terminal quit. This extension binds one generation
// per session activation. Only the active live generation may start, stop,
// rearm, or clear the arm child. An owning replacement session_start (or the
// first factory bind, while no live generation exists) arms its new
// generation without a model turn. A replacement
// handoff carries actionable closes that were still pending delivery; its
// durable state lives at state/extensions/omp-primary-watch/session-replacement-actionable.json.
// Stale callbacks from a prior generation are no-ops against the active replacement.
//
// Subagent session safety (stated once here):
// omp re-binds this factory for a subagent session (task tool, eval agent(),
// /tan clone) on the same evaluated module, so module state - including the
// active generation - is shared with the primary. Observed on omp 18.10.4
// with FM_OMP_EXTENSION_DEBUG_LOG: the rebind runs in the parent process right
// after before_subagent_spawn, before any subagent event and with no ctx, and
// the subagent's events then carry ctx.agent.kind === "sub" (depth > 0 for
// task children); no subagent session_shutdown followed its completion.
// A factory bind therefore activates its generation only when no live
// generation exists, so a rebind never displaces the primary's; omp's
// extension documentation owns the ctx.agent signal shape. A subagent session
// never claims, consumes, or retires the owner's arm and never persists the
// replacement handoff: every lifecycle handler and the arming tool stand down
// on that context. The 2026-10-08, 2026-10-13, and 2026-10-14 incidents were
// an unconditional activation at bind: the subagent's generation became the
// active one, the primary's read as not live, its next actionable close was
// dropped undelivered, and fm_watch_arm_omp answered "watcher: not armed -
// omp session is shutting down" until the supervisor restarted.
//
// Delivery versus consumption (stated once here):
// A main follow-up is delivered once omp accepts it (sendUserMessage returns).
// The successor pipeline never waits for the model to read it: a follow-up
// queued while main is streaming joins the running run without ever raising
// before_agent_start, so waiting on that event stalls every later close.
// Consumption is tracked only so a replacement can replay a follow-up omp had
// not consumed. An idle main consumes at before_agent_start; a streaming main
// consumes at the user message_start carrying the exact wake text; either
// event finishes the pending record, and a still-unconsumed record rides the
// replacement handoff.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
// typebox resolves inside omp's extension loader (verified, omp 18.1.11); the
// injected TypeBox compatibility shim keeps it available for tool parameters.
import { Type } from "typebox";
// The operational-input encoder is shared with the omp extensions; its owner
// resolves bin/fm-operational-input.sh relative to its own location, which is
// the same repository root this file lives in.
import { encodeFirstmateOperationalInput } from "../../.pi/extensions/lib/fm-operational-input.ts";
// Opt-in lifecycle debug log (FM_OMP_EXTENSION_DEBUG_LOG); its owner states
// the contract and is a no-op when the variable is unset.
import { extensionDebugEnabled, extensionDebugLogger } from "../../.pi/extensions/lib/fm-extension-debug.ts";


// The omp extension API surface this file uses. omp is a Pi fork and ships no
// separately installable type package, so the contract is declared locally
// rather than imported from the Pi package name.
type ExtensionAPI = {
  on?: (event: string, handler: (event: unknown, ctx: unknown) => unknown) => void;
  sendUserMessage: (content: string, options?: { deliverAs?: string }) => unknown;
  // pi.sendMessage delivers a hidden custom message; observed on omp 18.10.4:
  // customType fm.wake + display:false never renders, and with triggerTurn
  // and deliverAs 'followUp' the same message opens its own turn. omp's host
  // call is VOID (packages/coding-agent/src/modes/runtime-init.ts): it starts
  // the send, catches its own errors, and returns nothing, so a failed send
  // never rejects the caller's await - the extension reports delivery once
  // the call returns, exactly as it already does for sendUserMessage.
  sendMessage?: (message: { customType: string; content: string; display: boolean }, options?: { triggerTurn?: boolean; deliverAs?: string }) => unknown;
  registerCommand?: (name: string, command: { description: string; handler: (args: string, ctx: unknown) => Promise<void> | void }) => void;
  registerTool?: (tool: Record<string, unknown>) => void;
};

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

export type PendingActionableClose = {
  version: 1;
  token: string;
  message: string;
  predecessorArmPid: string;
  // Persisted origin: the omp session process and epoch at creation, so a
  // replacement can expire handoffs from a predecessor that is long gone
  // instead of replaying them forever (the Oct 10 case replayed 261 stale
  // wakes across every ordinary restart). Optional identically on write and
  // in-memory: absence reads as oldest on replay, never as expired.
  originPid?: string;
  originAt?: number;
  delivered?: true;
};

// One sink per module for handoff prune notes ("dropped N stale...", "dropped
// N over the cap..."): writeReplacementHandoff and the expiry wrapper push
// here from top level (where no generation exists yet), and the registered
// default body binds the sink to the CURRENT generation's queue as soon as
// it creates or activates one, so the note rides that generation's first
// delivered wake rather than becoming a wake of its own. A production load
// with no extension registered yet keeps notes here module-locally; a test
// imports only the primitives, assigns its own sink, and observes directly.
declare global {
  // eslint-disable-next-line no-var
  var __fmOmpWatchStaleNotes: { push(note: string): void; take(): string[] } | undefined;
}
function globalStaleNotes(): { push(note: string): void; take(): string[] } {
  return (globalThis.__fmOmpWatchStaleNotes ??= {
    push(note: string): void {
      staleNotesBuffer.push(note);
    },
    take(): string[] {
      return staleNotesBuffer.splice(0);
    },
  });
}
const staleNotesBuffer: string[] = [];
export const __tests = { globalStaleNotes };

type ReplacementActionableHandoff = {
  version: 2;
  pending: PendingActionableClose[];
};

type UnconsumedWake = {
  content: string;
  pending: PendingActionableClose;
};

type SessionGeneration = {
  id: number;
  stopping: boolean;
  replacement: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  cleanupTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
  pendingActionables: PendingActionableClose[];
  cleanupFailure: string;
  // Main follow-ups omp has accepted but not yet consumed, by pending token.
  // Never cleared at shutdown: a delivery continuation that runs after the
  // replacement began reads it to tell a main-queued wake (replayed) from a
  // branch-handled one (finished).
  unconsumedWakes: Map<string, UnconsumedWake>;
  // A verified successor's failure close that arrived while the pipeline was
  // still delivering the wake it was started for; its bounded retry runs once
  // that delivery settles instead of being skipped by the single-flight guard.
  deferredClose: { message: string; predecessorArmPid: string } | null;
  // Coalesce rule (3): per (pane, reason) keys last delivered within
  // staleWakeupTtlMs. Same pane emitting the identical stale reason within
  // the window does not re-ping main; a pane whose own state changed is a
  // fresh key and IS delivered. Never consulted across a fresh session_start
  // replay: a wake a replacement handed back already earned its delivery.
  deliveredStaleAt: Map<string, number>;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const hostScript = `${fmRoot}/bin/fm-supervision-host.sh`;
const marker = `${state}/.omp-watch-extension-loaded`;
const fmQuietCoalesceScript = `${fmRoot}/bin/fm-ask-mai-coalesce.sh`;
const fmWakeDrainScript = `${fmRoot}/bin/fm-wake-drain.sh`;
const handoffDir = `${state}/extensions/omp-primary-watch`;
const actionableHandoff = `${handoffDir}/session-replacement-actionable.json`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const armReadyTimeoutMs = positiveInteger(
  "FM_OMP_ARM_READY_TIMEOUT_MS",
  process.platform === "win32" ? 35000 : 12000,
);
const hostReadyTimeoutMs = Math.max(armReadyTimeoutMs, 30000);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const repairOnlyHint = "call fm_watch_arm_omp again only after a later notification says the cycle is missing, failed, or unhealthy";
const shuttingDownMessage = "watcher: not armed - omp session is shutting down";
// A persisted replacement handoff that outlives its predecessor omp session
// replays stale notifications on every ordinary restart (the Oct 10 case
// replayed 261 of them, and only a forced kill cleared the file, because a
// plain restart re-persists whatever replays). Cmp for age only against the
// origin stamp; a missing stamp reads oldest, so a handoff predating this
// bound expires as soon as its predecessor process is gone.
const handoffMaxAgeMs = positiveInteger("FM_OMP_HANDOFF_MAX_AGE_MS", 60 * 60 * 1000);
const handoffMaxPending = positiveInteger("FM_OMP_HANDOFF_MAX_PENDING", 50);

let nextGenerationId = 0;
let nextHandoffId = 0;
let activeGeneration: SessionGeneration | null = null;
const debugLog = extensionDebugLogger("omp-watch");
// One id per evaluation of this module and one per factory invocation, so the
// debug log shows whether a rebound session shares this module's state.
const debugModuleInstance = `${process.pid}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
let nextDebugBindingId = 0;
function generationDebugFields(generation: SessionGeneration): Record<string, unknown> {
  return {
    module: debugModuleInstance,
    generation: generation.id,
    stopping: generation.stopping,
    activeGeneration: activeGeneration ? activeGeneration.id : null,
    live: generationIsLive(generation),
    lock: lockOwnership(),
  };
}
let replacementHandoff: PendingActionableClose[] | null = null;
type ReplacementActionableReceiver = (pending: PendingActionableClose) => void;
type ActionableDeliveryClaim = {
  owner: SessionGeneration;
  settlement: Promise<"delivered" | "failed">;
};
type ReplacementCoordinator = {
  receiver: ReplacementActionableReceiver | null;
  pending: PendingActionableClose[];
  nextTokenId: number;
  deliveries: Map<string, ActionableDeliveryClaim>;
};
type ReplacementCoordinatorGlobal = typeof globalThis & {
  __firstmateOmpWatchReplacements?: Map<string, ReplacementCoordinator>;
};
const replacementCoordinatorGlobal = globalThis as ReplacementCoordinatorGlobal;
const replacementCoordinators = replacementCoordinatorGlobal.__firstmateOmpWatchReplacements ??= new Map<string, ReplacementCoordinator>();
function replacementCoordinatorFor(handoff: string): ReplacementCoordinator {
  const existing = replacementCoordinators.get(handoff);
  if (existing) return existing;
  const created: ReplacementCoordinator = {
    receiver: null,
    pending: [],
    nextTokenId: 0,
    deliveries: new Map(),
  };
  replacementCoordinators.set(handoff, created);
  return created;
}
const replacementCoordinator = replacementCoordinatorFor(actionableHandoff);
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
// Children the extension itself asked to exit; their close is not a failure
// of the successor and never earns a deferred retry.
const armRetired = new WeakSet<ChildProcess>();
const armRecovery = new WeakMap<ChildProcess, { generation: string; watcherPid: string }>();
const armPendingActionable = new WeakMap<ChildProcess, PendingActionableClose>();
const armHostMode = new WeakMap<ChildProcess, boolean>();

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function completedActionableLine(output: string): string {
  const newline = output.lastIndexOf("\n");
  return newline < 0 ? "" : actionableLine(output.slice(0, newline + 1));
}

// An away record, never quiet mode's (bin/fm-afk-contract.sh mode owns that
// reading): a record whose mode cannot be read as quiet reads as away.
function awayRecordPresent(): boolean {
  if (!existsSync(`${state}/.afk-contract`)) return false;
  const result = spawnSync("bash", [`${fmRoot}/bin/fm-afk-contract.sh`, "mode"], {
    encoding: "utf8",
    env: { ...process.env, FM_STATE_OVERRIDE: state },
  });
  return String(result.stdout || "").trim() !== "quiet";
}

// Whether this home runs the supervision host for an omp primary; the gate's
// owner answers, and a query that cannot run reads as no host.
function hostModeEnabled(): boolean {
  const result = spawnSync("bash", [`${fmRoot}/bin/fm-supervision-engine-lib.sh`, "enabled", config, "omp"], {
    stdio: "ignore",
  });
  return result.status === 0;
}

// The host-mode wake message: every "supervision-host:" line in order, wake
// lines capped at eight, and the away note while an away record exists.
function hostWakeMessage(output: string): string {
  let shown = 0;
  const lines = output.split(/\r?\n/).filter((line) => {
    if (/^supervision-host:/.test(line)) return true;
    if (/^(signal:|stale:|check:|heartbeat($|:))/.test(line) && shown < 8) {
      shown += 1;
      return true;
    }
    return false;
  });
  if (lines.length === 0) return "";
  if (awayRecordPresent()) {
    lines.push("This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.");
  }
  return lines.join("\n");
}

// The text omp carries in a user message_start: sendUserMessage wraps a string
// as one text part, so the joined text parts equal the sent content.
function userMessageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const part of content) {
    if (
      typeof part === "object" && part !== null &&
      (part as { type?: unknown }).type === "text" &&
      typeof (part as { text?: unknown }).text === "string"
    ) {
      parts.push((part as { text: string }).text);
    }
  }
  return parts.join("\n");
}

function nodeErrorCode(error: unknown): string {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code ?? "")
    : "";
}

function createPendingActionable(message: string, predecessorArmPid: string): PendingActionableClose {
  return {
    version: 1,
    token: `${process.pid}-${Date.now()}-${++replacementCoordinator.nextTokenId}`,
    message,
    predecessorArmPid,
    originPid: String(process.pid),
    originAt: Date.now(),
  };
}

// The creation origin of a handoff entry: the explicit stamps when present,
// otherwise derived from the token's own "<pid>-<epoch-ms>-<seq>" head -
// which means handoffs persisted by builds predating the stamps (the Oct 10
// file's 261 entries included) still carry their predecessor's pid and age
// readable at replay time.
export function handoffEntryOrigin(item: PendingActionableClose): { pid: string; atMs: number } {
  if (item.originPid !== undefined && item.originPid !== "" && item.originAt !== undefined) {
    return { pid: item.originPid, atMs: item.originAt };
  }
  const match = item.token.match(/^([0-9]+)-([0-9]+)-[0-9]+$/);
  return match ? { pid: match[1], atMs: Number(match[2]) } : { pid: "", atMs: 0 };
}

// Whether a persisted handoff entry is expired at <nowMs>: the predecessor
// omp session that created it is gone AND the entry has passed the age
// bound. A pid that is alive always keeps the entry - pid recycling keeps
// an old handoff past expiry, never the reverse, which is exactly "never
// drop a fresh pending wake from a live predecessor".
export function handoffEntryExpired(item: PendingActionableClose, nowMs: number): boolean {
  const origin = handoffEntryOrigin(item);
  if (origin.pid === "" || pidAlive(origin.pid)) return false;
  return nowMs - origin.atMs >= handoffMaxAgeMs;
}

// Whether <item> is a prune casualty when the persisted list exceeds the
// bound: it falls outside the newest <max> entries by (age, token).
export function handoffEntryDroppedByCap(item: PendingActionableClose, all: PendingActionableClose[], max: number): boolean {
  const ordered = [...all].sort((a, b) => {
    const aAt = handoffEntryOrigin(a).atMs;
    const bAt = handoffEntryOrigin(b).atMs;
    return aAt - bAt || a.token.localeCompare(b.token);
  });
  return ordered.indexOf(item) < ordered.length - max;
}

function validatePendingActionable(value: unknown): PendingActionableClose {
  const item = value as Partial<PendingActionableClose> & { version?: unknown };
  if (
    typeof value !== "object" || value === null ||
    item.version !== 1 ||
    typeof item.token !== "string" ||
    !/^[0-9]+-[0-9]+-[0-9]+$/.test(item.token) ||
    typeof item.message !== "string" ||
    (!actionableLine(item.message) &&
      !/^supervision-host:/m.test(item.message)) ||
    typeof item.predecessorArmPid !== "string" ||
    !/^[0-9]*$/.test(item.predecessorArmPid) ||
    (item.originPid !== undefined && (typeof item.originPid !== "string" || !/^[0-9]+$/.test(item.originPid))) ||
    (item.originAt !== undefined && (typeof item.originAt !== "number" || !Number.isFinite(item.originAt) || item.originAt <= 0)) ||
    (item.delivered !== undefined && item.delivered !== true)
  ) {
    throw new Error(`invalid omp replacement actionable handoff at ${actionableHandoff}`);
  }
  return value as PendingActionableClose;
}

function validateReplacementHandoff(value: unknown): { pending: PendingActionableClose[] } {
  const raw = value as Partial<ReplacementActionableHandoff>;
  if (typeof value !== "object" || value === null || raw.version !== 2 || !Array.isArray(raw.pending)) {
    throw new Error(`invalid omp replacement actionable handoff at ${actionableHandoff}`);
  }
  const pending = raw.pending.map(validatePendingActionable);
  const tokens: Record<string, true> = {};
  for (const item of pending) {
    if (tokens[item.token]) throw new Error(`invalid omp replacement actionable handoff at ${actionableHandoff}`);
    tokens[item.token] = true;
  }
  return { pending };
}

export function writeReplacementHandoff(pending: PendingActionableClose[]): void {
  // Persist only the newest handoffMaxPending entries (by origin age, then
  // token); a shutdown pile-up (the Oct 10 case) can never grow the file
  // unbounded. A fresh pending wake is always newest, so the cap never
  // drops the wake this shutdown just created.
  const kept: PendingActionableClose[] = [];
  let droppedCount = 0;
  for (const item of pending) {
    if (handoffEntryDroppedByCap(item, pending, handoffMaxPending)) droppedCount += 1;
    else kept.push(item);
  }
  if (droppedCount > 0) {
    globalStaleNotes().push(
      `watcher: dropped ${droppedCount} replacement-session actionable wake(s) over the ${handoffMaxPending}-entry persistence bound; the newest pending wakes were kept`,
    );
  }
  replacementHandoff = [...kept];
  mkdirSync(handoffDir, { recursive: true });
  const temporary = `${actionableHandoff}.tmp-${process.pid}-${++nextHandoffId}`;
  const handoff: ReplacementActionableHandoff = { version: 2, pending: kept };
  try {
    writeFileSync(temporary, `${JSON.stringify(handoff)}\n`, { mode: 0o600 });
    renameSync(temporary, actionableHandoff);
  } catch (error) {
    try {
      unlinkSync(temporary);
    } catch {
      // Preserve the original handoff publication error.
    }
    throw error;
  }
}
// The replay side of writeReplacementHandoff: drop aged-out entries whose
// predecessor session process is gone, delete or rewrite the persisted file
// so an ordinary restart no longer re-persists them, then hand the survivors
// to the ordinary load path. The durable wake queue (bin/fm-wake-drain.sh)
// already replays every wake idempotently, so an entry is lost only when it
// never reached ANY session - which this file's own persistence prevents.

export function loadReplacementHandoffWithExpiry(load: () => PendingActionableClose[], note: (text: string) => void): PendingActionableClose[] {
  let unexpired: PendingActionableClose[] = [];
  try {
    unexpired = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8"))).pending;
  } catch (error) {
    if (nodeErrorCode(error) === "ENOENT") return load();
    throw error;
  }
  const nowMs = Date.now();
  const agedOut = unexpired.filter((item) => handoffEntryExpired(item, nowMs));
  if (agedOut.length === 0) return load();
  const kept = unexpired.filter((item) => !handoffEntryExpired(item, nowMs));
  if (kept.length === 0) {
    replacementHandoff = null;
    unlinkSync(actionableHandoff);
  } else {
    writeReplacementHandoff(kept);
  }
  const origin = handoffEntryOrigin(agedOut[0]);
  note(`watcher: dropped ${agedOut.length} stale replacement-session actionable wake(s) (origin pid ${origin.pid} gone, older than ${Math.round(handoffMaxAgeMs / 60000)}m); the durable wake queue already replays these`);
  return load();
}

// Wake-coalescing primitives (one companion commit). Three rules act on a
// pending actionable close AT DELIVERY TIME so main is never woken for a
// queue someone else already drained, a busy main is not spammed one
// follow-up per queued actionable, and a pane whose agent stopped weeks
// ago retriggers no repeated identical stale ping.
//
// (1) wakeQueuePendingCount: the durable wake queue ($FM_WAKE_QUEUE, falling
// back to $STATE/.wake-queue) is the authority the watcher appended to
// before it closed. A record whose queue shows 0 valid rows is already
// drained; the close carries no fresh work for main. Rows are valid TSVs
// with kind in signal|stale|check|heartbeat.
export function wakeQueuePendingCount(queuePath: string): number {
  let text: string;
  try {
    text = readFileSync(queuePath, "utf8");
  } catch {
    return 0;
  }
  let count = 0;
  for (const line of text.split(/\r?\n/)) {
    if (!line) continue;
    const fields = line.split("\t");
    if (fields.length < 5) continue;
    if (["signal", "stale", "check", "heartbeat"].includes(fields[2])) count += 1;
  }
  return count;
}

// Default wake-queue path the extension consults. bin/fm-wake-lib.sh owns
// the name; a test overrides with FM_WAKE_QUEUE.
function extensionWakeQueuePath(): string {
  return process.env.FM_WAKE_QUEUE || `${state}/.wake-queue`;
}

// (2) A batch is a set of pending actionable closes that settle together:
// one main follow-up subsumes them all. The batch KEEPS every member (so
// consumption finishes every token's pending record), but the composite
// message dedupes repeated identical reason texts inside itself so a pane
// that emits the same line in several consecutive closes still appears
// once.
export type PendingActionableBatch = {
  items: PendingActionableClose[];
  message: string;
};
export function buildPendingActionableBatch(pending: PendingActionableClose[]): PendingActionableBatch {
  const items = [...pending];
  if (items.length === 1) return { items, message: items[0].message };
  const seen = new Set<string>();
  let dupes = 0;
  for (const item of pending) {
    if (seen.has(item.message)) { dupes += 1; continue; }
    seen.add(item.message);
  }
  const lines = [...seen].map((reason) => `- ${reason}`);
  const dupeSuffix = dupes > 0 ? ` (${dupes} duplicate reason${dupes === 1 ? "" : "s"} settled by the same delivery)` : "";
  return {
    items,
    message: `${items.length} wakes pending (coalesced)${dupeSuffix}:\n${lines.join("\n")}`,
  };
}

// (3) Per-pane temporal dedupe: the key a stale wake is keyed on. A stale
// wake's reason text begins with "stale: <pane-label> ..." - the pane is
// the stable identity. Anything else (signal:, check:, heartbeat:) is keyed
// by the full reason text alone since those reasons carry no pane address.
export function stalePaneKey(message: string): string {
  const match = message.match(/^stale:[ \t]+(\S+)/);
  return match ? `pane:${match[1]}` : `other:${message}`;
}

// Whether this item is suppressed under the temporal map: an identical
// (pane, reason) pair was already delivered within <ttlMs> and the pane has
// not changed state since. Returns false when the entry is expired or
// absent, true when it must not re-fire. Never suppress a fresh pending
// wake from a live predecessor's session_start replay.
export function staleWakeSuppressed(
  deliveredAtMs: Map<string, number>,
  item: PendingActionableClose,
  nowMs: number,
  ttlMs: number,
): boolean {
  const key = `${stalePaneKey(item.message)}|${item.message}`;
  const at = deliveredAtMs.get(key);
  if (at === undefined) return false;
  if (nowMs - at > ttlMs) return false;
  return true;
}
export const staleWakeupTtlMs = 10 * 60 * 1000;

function persistReplacementHandoff(pending: PendingActionableClose[]): void {
  if (pending.length === 0) return;
  writeReplacementHandoff(pending);
}

// The replay side of the handoff: the plain flat load, kept as the single
// call shape the wrapper and every caller share. Expiry and pruning live in
// loadReplacementHandoffWithExpiry, which activateOwnedWatch drives exactly
// once per replay; everything else (merge, clear, persist) reads and writes
// through it WITHOUT re-expiring, so only the owning session_start replays
// lose entries and a mid-session merge never silently expires anything.
export function loadReplacementHandoff(): PendingActionableClose[] {
  let stored: PendingActionableClose[] = [];
  try {
    stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8"))).pending;
  } catch (error) {
    if (nodeErrorCode(error) === "ENOENT") {
      replacementHandoff = null;
      return [];
    }
    throw error;
  }
  replacementHandoff = stored;
  return [...stored];
}

function mergeReplacementHandoff(pending: PendingActionableClose): void {
  let stored: PendingActionableClose[] = [];
  try {
    stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8"))).pending;
  } catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
  }
  if (!stored.some((item) => item.token === pending.token)) stored.push(pending);
  writeReplacementHandoff(stored);
}

function clearReplacementHandoff(pending: PendingActionableClose): void {
  try {
    const stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8"))).pending;
    const remaining = stored.filter((item) => item.token !== pending.token);
    if (remaining.length === stored.length) return;
    if (remaining.length > 0) {
      writeReplacementHandoff(remaining);
    } else {
      replacementHandoff = null;
      unlinkSync(actionableHandoff);
    }
  } catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
  }
}

function classifyClose(
  hostMode: boolean,
  stdout: string,
  stderr: string,
  code: number | null,
  signal: NodeJS.Signals | null,
): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  if (hostMode) {
    const message = hostWakeMessage(combined);
    if (message) return { kind: "actionable", message };
    const stoodDown = combined.split(/\r?\n/).find((line) => /^supervision-host stood down:/.test(line));
    if (stoodDown) return { kind: "failure", message: `watcher: FAILED - ${stoodDown}` };
  }
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - omp extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - omp extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    const script = hostMode ? "fm-supervision-host.sh" : "fm-watch-arm.sh";
    return {
      kind: "failure",
      message: `watcher: FAILED - ${script} exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - omp extension arm cycle ended without an actionable reason",
  };
}

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    replacement: false,
    child: null,
    retryTimer: null,
    cleanupTimer: null,
    retryFailures: 0,
    restoring: false,
    seq: 0,
    pendingActionables: [],
    cleanupFailure: "",
    unconsumedWakes: new Map(),
    deliveredStaleAt: new Map(),
    deferredClose: null,
  };
}

function activateGeneration(generation: SessionGeneration): void {
  activeGeneration = generation;
}

function generationIsLive(generation: SessionGeneration): boolean {
  return activeGeneration === generation && !generation.stopping;
}

function stopGeneration(generation: SessionGeneration): ChildProcess | null {
  generation.stopping = true;
  if (generation.retryTimer) clearTimeout(generation.retryTimer);
  if (generation.cleanupTimer) clearTimeout(generation.cleanupTimer);
  generation.retryTimer = null;
  generation.cleanupTimer = null;
  const child = generation.child;
  if (child) child.kill("SIGTERM");
  generation.child = null;
  return child;
}

async function waitForGenerationChildClose(armChild: ChildProcess | null): Promise<void> {
  if (!armChild) return;
  const closed = armClose.get(armChild);
  if (!closed) return;
  await new Promise<void>((resolveWait) => {
    const timer = setTimeout(resolveWait, armRetireTimeoutMs);
    void closed.then(() => {
      clearTimeout(timer);
      resolveWait();
    });
  });
}

async function stopSessionGeneration(generation: SessionGeneration, replacement: boolean): Promise<void> {
  generation.replacement = replacement;
  let persistedTokens = "";
  try {
    if (replacement && generation.pendingActionables.length > 0) {
      persistReplacementHandoff(generation.pendingActionables);
      persistedTokens = generation.pendingActionables.map((pending) => pending.token).join("\n");
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    for (const pending of generation.pendingActionables) {
      if (replacementCoordinator.pending.some((item) => item.token === pending.token)) continue;
      replacementCoordinator.pending.push({
        ...pending,
        message: `${pending.message}\n\nwatcher: FAILED - omp extension could not persist a replacement-session actionable wake\n${detail}`,
      });
    }
    throw error;
  } finally {
    const child = stopGeneration(generation);
    await waitForGenerationChildClose(child);
  }
  const currentTokens = generation.pendingActionables.map((pending) => pending.token).join("\n");
  if (replacement && currentTokens && currentTokens !== persistedTokens) {
    persistReplacementHandoff(generation.pendingActionables);
  }
}

const cleanupOnProcessExit = () => {
  if (activeGeneration) stopGeneration(activeGeneration);
};
process.once("exit", cleanupOnProcessExit);

export default function (pi: ExtensionAPI) {
  const debugBinding = ++nextDebugBindingId;
  const debugPredecessorGeneration = activeGeneration ? activeGeneration.id : null;
  let generation = createGeneration();
  // A rebind for a subagent session must not displace the live primary
  // generation (see "Subagent session safety" above); the primary's own
  // session_start still activates its generation unconditionally.
  const bindActivates = !activeGeneration || activeGeneration.stopping;
  if (bindActivates) activateGeneration(generation);
  debugLog(debugBinding, "factory_bind", bindActivates ? "activateGeneration" : "keep-live-generation", undefined, () => ({
    ...generationDebugFields(generation),
    predecessorActiveGeneration: debugPredecessorGeneration,
  }));

  // Routine absorption mode (docs/configuration.md "Routine wake absorption"
  // owns the contract). `banner` (the default, and every unrecognized value)
  // is the #11 behavior: one informational banner for absorbed routine rows.
  // `silent` absorbs those rows with no message to the primary at all - the
  // queue rows are deleted under the wake queue lock through
  // bin/fm-wake-drain.sh --delete-sequences and the only trace is the ledger
  // and triage log - while `off` disables absorption. Read fresh each
  // delivery so a config change takes effect on the next wake.
  type WakeRoutineMode = "banner" | "silent" | "off";

  function wakeRoutineMode(): WakeRoutineMode {
    let value = "";
    try {
      value = readFileSync(`${config}/wake-routine-mode`, "utf8").trim();
    } catch {
      return "banner";
    }
    if (value === "silent" || value === "off") return value;
    return "banner";
  }

  // Periodic visibility for silent absorption (same config owner). Default
  // 30 minutes; 0 disables the digest. Malformed values fall back to the
  // default.
  function wakeRoutineDigestMins(): number {
    try {
      const raw = readFileSync(`${config}/wake-routine-digest-mins`, "utf8").trim();
      if (/^[0-9]+$/.test(raw)) return Number(raw);
    } catch {
      // Absent file: default.
    }
    return 30;
  }

  // Epoch the last issued digest covered. In-memory: sessions are long-lived
  // supervision primaries, and the rate-limit contract is at-most-every-N
  // (docs/configuration.md), so a restart may issue extra digests (never
  // swallow more).
  let lastRoutineDigestAt = 0;

  // Silent-absorption ledger. One tab-separated line per absorbed wake in
  // state/.fm-routine-absorbed.tsv: epoch, task key, summary. The leading
  // line's epoch is the digest window's "since". Cleared after each sent
  // digest, so the file holds exactly the rows the next digest will count.
  const routineAbsorbedLog = `${state}/.fm-routine-absorbed.tsv`;

  function recordSilentAbsorption(absorbed: WakeCoalesceRow[]): { count: number; sinceEpoch: number; last: string } {
    let sinceEpoch = 0;
    let count = 0;
    try {
      if (existsSync(routineAbsorbedLog)) {
        const lines = readFileSync(routineAbsorbedLog, "utf8").split("\n").filter((line) => line !== "");
        count = lines.length;
        const firstTab = lines.length > 0 ? lines[0].indexOf("\t") : -1;
        sinceEpoch = firstTab > 0 ? Number(lines[0].slice(0, firstTab)) : 0;
      }
    } catch {
      count = 0;
    }
    let last = "";
    for (const row of absorbed) {
      try {
        const epoch = Math.floor(Date.now() / 1000);
        appendFileSync(routineAbsorbedLog, `${epoch}\t${row.key}\t${row.summary || row.kind}\n`);
        if (count === 0) sinceEpoch = epoch;
        count += 1;
      } catch {
        // Losing a ledger line only degrades one digest entry.
      }
      last = `${row.key}: ${row.summary || row.kind}`;
    }
    return { count, sinceEpoch, last };
  }

  // Digest line shape:
  //   ⚓ digest · <N> routine absorbed since HH:MM (task: last status…)
  function routineDueDigestText(record: { count: number; sinceEpoch: number; last: string }): string {
    const due = new Date(record.sinceEpoch * 1000).toTimeString().slice(0, 5);
    const summary = record.last.length > 50 ? `${record.last.slice(0, 50)}…` : record.last;
    return `⚓ digest · ${record.count} routine absorbed since ${due} (${summary})`;
  }


  // Cleared after a digest is successfully sent so the "since" window and
  // count restate exactly what the last digest covered.
  function clearRoutineAbsorbedLog(): void {
    try {
      unlinkSync(routineAbsorbedLog);
    } catch {
      // A cleared ledger is courtesy; a leftover line only widens the next
      // window's count.
    }
  }

// Wake text contract. A compact one-line banner replaces the historical
// multi-line "Run bin/fm-wake-drain.sh first and handle the queued wake..."
// body. The envelope kind stays "watcher" so fm-operational-input.sh
// classification, the turn-end guard, and firstmate's supervision protocol
// are unchanged. The agent learns the new call shape from
// docs/supervision-protocols/omp.md and the bin/fm-wake-drain.sh header.
const FM_WAKE_BANNER = "⚓ wake";
const FM_WAKE_DELIVERY_RULE = "handled by bin/fm-wake-drain.sh --brief";

function wakeTruncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return `${s.slice(0, max)}…`;
}

// Decompose a wake message into its kind and a short continuation (no
// duplicate "kind:" prefix, no newlines, no absolute path stretch).
function wakeDecompose(message: string): { kind: string; rest: string } {
  const trimmed = message.split(/\r?\n/, 1)[0].trim();
  const m = /^(signal|stale|check|heartbeat|watcher|procevent)(?::\s*|\s+|$)(.*)$/.exec(trimmed);
  if (m) {
    const rest = m[2].replace(/^\s+/, "");
    return { kind: m[1], rest: rest.length > 0 ? rest : "" };
  }
  return { kind: "wake", rest: trimmed };
}

// One-line wake banner. The trailing rule names the only handling command
// the agent needs so the supervision protocol stays the contract's owner.
function formatWakeMessage(message: string): string {
  const { kind, rest } = wakeDecompose(message);
  const body = rest ? ` ${wakeTruncate(rest, 80)}` : "";
  return `${FM_WAKE_BANNER} · ${kind}:${body} — ${FM_WAKE_DELIVERY_RULE}`;
}

// One line covering one or more absorbed routine rows. The agent always
// sees the absorption count (never a silent swallow).
function formatAbsorbedWakeSummary(absorbed: { kind: string; key: string; summary?: string }[]): string {
  const previews = absorbed
    .slice(0, 2)
    .map((row) => `${row.key} (${wakeTruncate(row.summary || row.kind, 60)})`)
    .join(", ");
  const extra = absorbed.length > 2 ? `, +${absorbed.length - 2}` : "";
  return `${absorbed.length} routine absorbed: ${previews}${extra}`;
}
  // Run bin/fm-wake-drain.sh --brief --ack and return the one-line summary it
  // presents, or null when the drain fails or there is nothing to present.
  // A routine drain acks itself (its trailing marker is "(acked)"); an
  // actionable drain prints a WAKE_ACK_REQUIRED line naming the exact
  // --ack-through cutoff and recovery generation for what it presented.
  // bin/fm-wake-drain.sh owns the contract and writes that line to STDERR
  // while the rows ride stdout, so both streams are scanned: a parser that
  // reads only stdout never sees the marker, delivers the rows without
  // their ack contract, and leaves them queued to repeat on the next wake
  // (the 2026-10-14 live defect). The drain owns the queue read; the
  // extension only ever runs it immediately before sending a wake message,
  // so concurrent rows are still serialized through the queue lock.
  function drainWakeQueueBriefAck(
    owner: SessionGeneration,
  ): { text: string; ackPending: boolean; ackThrough: string | null; ackGeneration: string | null } | null {
    const drain = spawnSync("bash", [fmWakeDrainScript, "--brief", "--ack"], {
      cwd: fmRoot,
      encoding: "utf8",
      env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot, FM_WAKE_QUEUE: extensionWakeQueuePath() },
    });
    if (drain.status !== 0) {
      const detail = ((drain.stderr || "") + "\n" + (drain.stdout || "")).trim() || "no output";
      surfaceFailure(owner, `watcher: FAILED - bin/fm-wake-drain.sh --brief --ack exited ${drain.status}\n${wakeTruncate(detail, 200)}`);
      return null;
    }
    // Rows on stdout, ack marker on stderr; empty lines never survive either
    // trim, and a bounded lock skip ("WAKE DRAIN SKIPPED") just keeps the
    // queue for the next wake rather than presenting a half-drained set.
    const combined = `${(drain.stdout || "").trim()}\n${(drain.stderr || "").trim()}`.trim();
    const lines = combined.split(/\r?\n/).map((line) => line.trimEnd()).filter((line) => line !== "");
    const markerIndex = lines.findIndex((line) => line === "(acked)" || line.startsWith("WAKE_ACK_REQUIRED:"));
    const ackLine = markerIndex >= 0 ? lines[markerIndex] : undefined;
    const rows = ackLine ? lines.slice(0, markerIndex) : lines;
    if (rows.length === 0) {
      if (!ackLine) return null;
      // A marker with no rows (the empty-queue recovery notice) carries no
      // wake rows for main; treat it as nothing presented rather than waking
      // over an empty summary.
      return null;
    }
    const summary = rows.join(" · ");
    const ackPending = Boolean(ackLine?.startsWith("WAKE_ACK_REQUIRED:"));
    let ackThrough: string | null = null;
    let ackGeneration: string | null = null;
    if (ackPending && ackLine) {
      const match = /--ack-through\s+(\d+)\s+--recovery-generation\s+(\S+)/.exec(ackLine);
      if (match) {
        ackThrough = match[1];
        ackGeneration = match[2];
      }
    }
    // Only the rows ride the wake text; the ack contract stays an extension
    // concern, settled in-extension by ackPresentedWake below.
    return { text: summary, ackPending, ackThrough, ackGeneration };
  }

  // Acknowledge exactly what a --brief --ack drain presented: run its named
  // --ack-through cutoff under the queue lock so the presented rows leave
  // the durable queue and no later drain re-presents them. The cutoff the
  // drain printed was computed against the rows IT presented, and a row
  // that arrived after presentation sits above the cutoff and is never
  // consumed (claim_main_rows_locked claims only unreserved rows at or
  // below it), so acking here is safe against the interleave where a newer
  // wake landed between presentation and ack. A failed or absent ack keeps
  // the rows queued and reported, never silently swallowed; the next wake
  // then re-presents them, which is the loud failure, not the hidden one.
  function ackPresentedWake(
    owner: SessionGeneration,
    drained: { ackPending: boolean; ackThrough: string | null; ackGeneration: string | null },
  ): void {
    if (!drained.ackPending || !drained.ackThrough || !drained.ackGeneration) return;
    let ack;
    try {
      ack = spawnSync(
        "bash",
        [fmWakeDrainScript, "--ack-through", drained.ackThrough, "--recovery-generation", drained.ackGeneration],
        {
          cwd: fmRoot,
          encoding: "utf8",
          env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot, FM_WAKE_QUEUE: extensionWakeQueuePath() },
        },
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      surfaceFailure(owner, `watcher: FAILED - the presented wake could not be acknowledged\n${wakeTruncate(message, 200)}`);
      return;
    }
    if (ack.status !== 0) {
      const detail = ((ack.stderr || "") + "\n" + (ack.stdout || "")).trim() || "no output";
      surfaceFailure(owner, `watcher: FAILED - the presented wake could not be acknowledged (exit ${ack.status})\n${wakeTruncate(detail, 200)}`);
    }
  }

  async function sendWake(
    owner: SessionGeneration,
    message: string,
    pending?: PendingActionableClose,
  ): Promise<boolean> {
    if (!generationIsLive(owner)) return false;
    // Prune notes for this session ride its first delivered wake rather than
    // becoming wakes of their own; up to two from one replay (stale-drop and
    // cap) fit one line block. They ride BEFORE the compact banner so they
    // never get swallowed by the row-kind prefix.
    const notesSuffix = globalStaleNotes().take().map((note) => `\n\n${note}`).join("");
    const content = encodeFirstmateOperationalInput("watcher", `${notesSuffix}${formatWakeMessage(message)}`);
    if (pending) owner.unconsumedWakes.set(pending.token, { content, pending });
    try {
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch (error) {
      if (pending) owner.unconsumedWakes.delete(pending.token);
      throw error;
    }
    // Accepted by omp (sendUserMessage returns synchronously there; awaiting a
    // non-promise resolves at once). A generation replaced while omp was
    // accepting it may have lost the follow-up with the old session, so report
    // it undelivered and let the replacement replay the still-pending record.
    return generationIsLive(owner);
  }

  // One follow-up carrying a whole batch of pending actionable closes. The
  // batch's composite text is sent exactly once, then EACH member is
  // registered in unconsumedWakes under its own token ALL pointing at the
  // same composite content, so consumeWake (before_agent_start or the
  // matching user message_start) settles the whole batch at once.
  async function sendBatchedWake(
    owner: SessionGeneration,
    message: string,
    items: PendingActionableClose[],
  ): Promise<boolean> {
    if (items.length === 0) return false;
    if (!generationIsLive(owner)) return false;
    const notesSuffix = globalStaleNotes().take().map((note) => `\n\n${note}`).join("");
    const content = encodeFirstmateOperationalInput("watcher", `${notesSuffix}${formatWakeMessage(message)}`);
    for (const item of items) owner.unconsumedWakes.set(item.token, { content, pending: item });
    // Hidden wake path: drain the queue first so the model receives the
    // already-digested one-line summary in a hidden custom message the chat
    // never renders; the turn opens on the custom message itself through
    // triggerTurn:true. The extension acknowledges exactly the presented
    // rows as part of delivery (ackPresentedWake), so each wake carries
    // only rows not yet delivered and the durable queue never re-presents
    // them; an acknowledgement failure keeps the rows queued and surfaces
    // loudly rather than swallowing them. Fall back to today's visible
    // sendUserMessage banner when the drain fails, the outgoing hidden send
    // is rejected before omp accepts it, or the sendMessage API is missing
    // in this omp build.
    const drained = drainWakeQueueBriefAck(owner);
    if (drained && drained.text && pi.sendMessage) {
      // Re-key each pending record under the drained summary so a matching
      // role:"custom" message_start (omp 18.10.4) finishes the record; the
      // composite content keys only the visible fallback's consumption.
      const hiddenContent = encodeFirstmateOperationalInput("watcher", `${notesSuffix}${drained.text}`);
      for (const item of items) owner.unconsumedWakes.set(item.token, { content: hiddenContent, pending: item });
      try {
        await pi.sendMessage({ customType: "fm.wake", content: hiddenContent, display: false }, { triggerTurn: true, deliverAs: "followUp" });
        ackPresentedWake(owner, drained);
        return generationIsLive(owner);
      } catch {
        // Re-key to the composite so a visible-fallback consumption still
        // finishes every member.
      for (const item of items) owner.unconsumedWakes.set(item.token, { content, pending: item });
      }
    }
    if (items.length === 1) {
      try {
        await pi.sendUserMessage(content, { deliverAs: "followUp" });
        // The visible fallback still carries the rows the drain presented,
        // so acknowledge the same presentation set it delivered.
        if (drained) ackPresentedWake(owner, drained);
      } catch (error) {
        for (const item of items) owner.unconsumedWakes.delete(item.token);
        throw error;
      }
      return generationIsLive(owner);
    }
    try {
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
      if (drained) ackPresentedWake(owner, drained);
    } catch (error) {
      for (const item of items) owner.unconsumedWakes.delete(item.token);
      throw error;
    }
    return generationIsLive(owner);
  }

  // omp consumed a main follow-up: an idle main at before_agent_start, a
  // streaming main at the user message_start that joins the running run.
  // Coalesce rule (2) settles a whole batch here: every entry whose
  // recorded content matches the consumed text is finished at once (a
  // batched delivery registered one unconsumedWakes entry per batch member
  // all under the same composite text).
  function consumeWake(owner: SessionGeneration, text: string): void {
    const matched: UnconsumedWake[] = [];
    for (const [, wake] of owner.unconsumedWakes) {
      if (wake.content !== text) continue;
      matched.push(wake);
    }
    for (const wake of matched) {
      owner.unconsumedWakes.delete(wake.pending.token);
      wake.pending.delivered = true;
      try {
        finishPendingActionable(owner, wake.pending);
      } catch (error) {
        surfaceCleanupFailure(owner, error);
        schedulePendingCleanup(owner);
      }
      // Coalesce rule (3) bookkeeping: rules that fired this delivery are
      // recorded, so a pane's identical stale repeat inside the TTL quiets.
      if (/^stale:/.test(wake.pending.message)) {
        const key = `${stalePaneKey(wake.pending.message)}|${wake.pending.message}`;
        owner.deliveredStaleAt.set(key, Date.now());
      }
    }
  }

  function confirmHandlingDelivery(recovery: { generation: string; watcherPid: string }): {
    ok: boolean;
    detail: string;
  } {
    try {
      const result = spawnSync(
        "bash",
        [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
        {
          cwd: fmRoot,
          encoding: "utf8",
          env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
        },
      );
      if (result.status === 0) return { ok: true, detail: "" };
      const stderr = (result.stderr || "").trim();
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${message}`,
      };
    }
  }

  function confirmHandlingDeliveryWithRetry(
    owner: SessionGeneration,
    recovery: { generation: string; watcherPid: string },
  ): { ok: boolean; detail: string } {
    const snapshot = (): { generation: string; watcherPid: string } => {
      const current = owner.child ? armRecovery.get(owner.child) : undefined;
      return current ?? recovery;
    };
    const first = confirmHandlingDelivery(snapshot());
    if (first.ok) return first;
    return confirmHandlingDelivery(snapshot());
  }

  // Routine rows are folded into one informational banner. See
  // bin/fm-ask-mai-coalesce.sh's header for the classification contract;
  // this site owns only the delivery decision.
  type WakeCoalesceRow = { kind: string; key: string; payload?: string; summary?: string; seq?: number };

  // Delivery triage gate: called inside deliverActionableWake before a wake
  // becomes follow-up text. Fail-open on every error shape; deterministic
  // heartbeats and bare working/paused signals also strip with no MAI call
  // (bin/fm-ask-mai-coalesce.sh owns that shell).
  type WakeDeliveryDecision =
    | { action: "deliver"; absorbedNotice?: WakeCoalesceRow[] }
    | { action: "absorbed"; absorbedEntries: WakeCoalesceRow[] };

  // Numeric seq extraction uses Number(...) directly so row filtering stays
  // readable; a coalesce row carrying a usable numeric seq is acknowledged by
  // that seq, anything else falls back to a coalesce-only parse.
  function rowsFromCoalesce(value: unknown): WakeCoalesceRow[] {
    if (!Array.isArray(value)) return [];
    return value.filter((entry): entry is WakeCoalesceRow => {
      if (!entry || typeof entry !== "object") return false;
      if (!("kind" in entry) || !("key" in entry)) return false;
      return typeof (entry as { kind: unknown }).kind === "string"
        && typeof (entry as { key: unknown }).key === "string";
    });
  }

  function deliveryDecision(): WakeDeliveryDecision {
    let stdout: string;
    try {
      const result = spawnSync(
        "bash",
        [fmQuietCoalesceScript, fmHome, `${state}/.wake-queue`, "1"],
        {
          cwd: fmRoot,
          encoding: "utf8",
          env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
        },
      );
      if (result.status !== 0) return { action: "deliver" };
      stdout = String(result.stdout || "").trim();
    } catch {
      return { action: "deliver" };
    }
    if (!stdout) return { action: "deliver" };
    let parsed: unknown;
    try {
      parsed = JSON.parse(stdout);
    } catch {
      return { action: "deliver" };
    }
    if (!parsed || typeof parsed !== "object") return { action: "deliver" };
    if (!("deliver" in parsed) || !("absorbed" in parsed)) return { action: "deliver" };
    const deliver = rowsFromCoalesce((parsed as Record<string, unknown>).deliver);
    const absorbed = rowsFromCoalesce((parsed as Record<string, unknown>).absorbed);
    if (deliver.length > 0) {
      return absorbed.length > 0
        ? { action: "deliver", absorbedNotice: absorbed }
        : { action: "deliver" };
    }
    if (absorbed.length > 0) return { action: "absorbed", absorbedEntries: absorbed };
    return { action: "deliver" };
  }

  // Retire the pending items of an absorbed routine wake without sending a
  // message - the banner body's finish block and silent mode's no-digest
  // path do exactly the same work.
  function finishAbsorbedItems(owner: SessionGeneration, items: PendingActionableClose[]): void {
    for (const item of items) {
      item.delivered = true;
      try {
        finishPendingActionable(owner, item);
      } catch (error) {
        surfaceCleanupFailure(owner, error);
      }
    }
  }

  // The silent queue edit is bin/fm-wake-drain.sh --delete-sequences: only
  // the queue's owner script deletes rows, under its own lock and row
  // validation, so a contract change there lands here through the same
  // tests/fm-quiet-wakes.test.sh and tests/fm-wake-queue.test.sh gates.
  // Absorb routine queue rows with no message to the primary: each row's
  // exact queue sequence is deleted under the wake queue lock and every
  // pending item retires. The ledger record, the rate-limit check, and the
  // digest send happen only after the rows are absorbed, and the digest's
  // ledger clear follows its successful send, so a failed delete or a failed
  // send leaves the window intact rather than swallowing it. Returns true
  // when the silent absorption (and, where due, the digest send) took over
  // this turn; false when the caller must deliver instead.
  async function absorbRoutineSilently(
    owner: SessionGeneration,
    items: PendingActionableClose[],
    absorbedEntries: WakeCoalesceRow[],
  ): Promise<boolean> {
    const seqs: number[] = [];
    for (const row of absorbedEntries) {
      const seq = row.seq;
      if (typeof seq !== "number" || !Number.isFinite(seq) || seq <= 0) return false;
      seqs.push(Math.floor(seq));
    }
    if (seqs.length === 0) return false;
    const del = spawnSync("bash", [fmWakeDrainScript, "--delete-sequences", seqs.join(",")], {
      cwd: fmRoot,
      encoding: "utf8",
      env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
    });
    if (del.status !== 0) return false;
    finishAbsorbedItems(owner, items);
    const record = recordSilentAbsorption(absorbedEntries);
    const nowSec = Math.floor(Date.now() / 1000);
    const mins = wakeRoutineDigestMins();
    if (mins > 0 && record.last !== "" && (lastRoutineDigestAt === 0 || nowSec - lastRoutineDigestAt >= mins * 60)) {
      try {
        await sendWake(owner, routineDueDigestText(record), undefined);
        lastRoutineDigestAt = nowSec;
        clearRoutineAbsorbedLog();
      } catch {
        // The rows are absorbed and ledgered; a lost digest only defers
        // visibility to the next due window.
      }
    }
    return true;
  }

  async function deliverActionablesWithTriage(
    owner: SessionGeneration,
    message: string,
    items: PendingActionableClose[],
  ): Promise<boolean> {
    const mode = wakeRoutineMode();
    const decision = deliveryDecision();
    if (decision.action === "absorbed") {
      if (mode === "silent" && await absorbRoutineSilently(owner, items, decision.absorbedEntries)) {
        return true;
      }
      // Routine banner: finish every pending item so the actionables'
      // episodes retire, then send ONE informational banner with no pending
      // token - the agent reads the absorbed count, runs --brief, and
      // carries on.
      finishAbsorbedItems(owner, items);
      return await sendWake(owner, formatAbsorbedWakeSummary(decision.absorbedEntries), undefined);
    }
    // The wake still needs its turn. In silent mode a sibling routine row
    // absorbed in the same call adds no one-line banner: its rows delete
    // silently through the same absorber and the digest may still fire when
    // due, so only the deliverable wake itself rides the envelope. A failed
    // silent delete falls through to the banner path so the routine sibling
    // still surfaces through its one-line banner.
    if (mode === "silent" && decision.absorbedNotice && decision.absorbedNotice.length > 0) {
      if (await absorbRoutineSilently(owner, [], decision.absorbedNotice)) {
        return await sendBatchedWake(owner, message, items);
      }
    }
    const suffix = decision.absorbedNotice
      ? `\n\n(${formatAbsorbedWakeSummary(decision.absorbedNotice)})`
      : "";
    // No supervision branch on omp: every actionable wake goes to main.
    return await sendBatchedWake(owner, `${message}${suffix}`, items);
  }


  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message).catch(() => {
      // omp owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function enqueuePendingActionable(
    owner: SessionGeneration,
    pending: PendingActionableClose,
  ): void {
    if (owner.pendingActionables.some((item) => item.token === pending.token)) return;
    owner.pendingActionables.push(pending);
    if (owner.stopping && owner.replacement) {
      let replacementPending = pending;
      try {
        mergeReplacementHandoff(pending);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        replacementPending = {
          ...pending,
          message: `${pending.message}\n\nwatcher: FAILED - omp extension could not persist a late replacement-session actionable wake\n${detail}`,
        };
      }
      if (replacementCoordinator.receiver) {
        replacementCoordinator.receiver(replacementPending);
      } else if (replacementPending !== pending) {
        replacementCoordinator.pending.push(replacementPending);
      }
    }
  }

  function finishPendingActionable(owner: SessionGeneration, pending: PendingActionableClose): void {
    clearReplacementHandoff(pending);
    const index = owner.pendingActionables.findIndex((item) => item.token === pending.token);
    if (index >= 0) owner.pendingActionables.splice(index, 1);
    owner.cleanupFailure = "";
  }

  function surfaceCleanupFailure(
    owner: SessionGeneration,
    error: unknown,
  ): void {
    const detail = error instanceof Error ? error.message : String(error);
    if (owner.cleanupFailure === detail) return;
    owner.cleanupFailure = detail;
    surfaceFailure(owner, `watcher: FAILED - omp extension could not clear a delivered replacement-session actionable wake\n${detail}`);
  }

  function schedulePendingCleanup(owner: SessionGeneration): void {
    if (!generationIsLive(owner) || owner.cleanupTimer) return;
    const timer = setTimeout(() => {
      if (owner.cleanupTimer === timer) owner.cleanupTimer = null;
      void processPendingActionables(owner);
    }, retryDelay(1));
    timer.unref();
    owner.cleanupTimer = timer;
  }

  async function processPendingActionables(owner: SessionGeneration): Promise<void> {
    if (!generationIsLive(owner) || owner.restoring || owner.pendingActionables.length === 0) return;
    owner.restoring = true;
    const attemptedCleanup = new Set<string>();
    try {
      while (generationIsLive(owner) && owner.pendingActionables.length > 0) {
        for (const delivered of owner.pendingActionables.filter((item) => item.delivered && !attemptedCleanup.has(item.token))) {
          attemptedCleanup.add(delivered.token);
          try {
            finishPendingActionable(owner, delivered);
          } catch (error) {
            surfaceCleanupFailure(owner, error);
          }
        }
        // Coalesce rule (1): a close whose durable-wake-queue row is already
        // drained carries no work for main - mark it delivered and let the
        // cleanup path at the head of the next iteration clear it.
        const queueCount = wakeQueuePendingCount(extensionWakeQueuePath());
        for (const candidate of owner.pendingActionables.filter(
          (item) => !item.delivered && !owner.unconsumedWakes.has(item.token),
        )) {
          if (queueCount === 0) {
            candidate.delivered = true;
            continue;
          }
          // Coalesce rule (3): a pane whose stale reason we ALREADY delivered
          // inside the TTL quiets a repeat of the identical reason; only a
          // pane whose stale state changed (a fresh reason text) re-pings.
          if (/^stale:/.test(candidate.message) &&
              staleWakeSuppressed(owner.deliveredStaleAt, candidate, Date.now(), staleWakeupTtlMs)) {
            candidate.delivered = true;
          }
        }
        for (const dropped of owner.pendingActionables.filter((item) => item.delivered && !attemptedCleanup.has(item.token))) {
          attemptedCleanup.add(dropped.token);
          try {
            finishPendingActionable(owner, dropped);
          } catch (error) {
            surfaceCleanupFailure(owner, error);
          }
        }
        // Coalesce rule (2): every still-eligible close settles in ONE main
        // follow-up. The batch dedupes repeated reason texts inside itself;
        // a fresh session_start replay of ONE wake never coalesces.
        const eligible = owner.pendingActionables.filter(
          (item) => !item.delivered && !owner.unconsumedWakes.has(item.token),
        );
        if (eligible.length === 0) break;
        const batch = buildPendingActionableBatch(eligible.slice(0, 8));
        const pending = batch.items[0];
        const existingClaim = replacementCoordinator.deliveries.get(pending.token);
        if (existingClaim && existingClaim.owner !== owner) {
          const settlement = await existingClaim.settlement;
          if (!generationIsLive(owner)) return;
          if (settlement === "delivered") {
            pending.delivered = true;
            continue;
          }
          if (replacementCoordinator.deliveries.get(pending.token) === existingClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        }
        let settleClaim: (settlement: "delivered" | "failed") => void = () => {};
        const settlement = new Promise<"delivered" | "failed">((resolveSettlement) => {
          settleClaim = resolveSettlement;
        });
        const deliveryClaim = { owner, settlement };
        replacementCoordinator.deliveries.set(pending.token, deliveryClaim);
        const releaseClaim = (): void => {
          if (replacementCoordinator.deliveries.get(pending.token) === deliveryClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        };
        try {
          // A new restoration supersedes whatever became of the previous
          // successor; only a failure during this delivery is retried after it.
          owner.deferredClose = null;
          const restoration = await restoreAfterActionableClose(owner, pending.predecessorArmPid);
          if (!generationIsLive(owner)) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const message = restoration.failure ? `${batch.message}\n\n${restoration.failure}` : batch.message;
          const delivered = await deliverActionablesWithTriage(owner, message, batch.items);
          if (!delivered) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          // Coalesce rule (3) bookkeeping: recording here right at delivery
          // (not only at consumption) means even an unconsumed repeat of
          // the identical stale reason inside the TTL does not re-ping.
          for (const item of batch.items) {
            if (!/^stale:/.test(item.message)) continue;
            const key = `${stalePaneKey(item.message)}|${item.message}`;
            owner.deliveredStaleAt.set(key, Date.now());
          }
          const awaitingConsumption = owner.unconsumedWakes.has(pending.token);
          if (awaitingConsumption && !generationIsLive(owner)) {
            // omp accepted the follow-up, then the session was replaced before
            // this continuation ran: the shutdown persisted the still-pending
            // record, so a replacement waiting on this claim must replay it.
            settleClaim("failed");
            releaseClaim();
            return;
          }
          settleClaim("delivered");
          if (!awaitingConsumption) {
            // omp consumed it before this ran.
            for (const item of batch.items) {
              item.delivered = true;
              try {
                finishPendingActionable(owner, item);
              } catch (error) {
                surfaceCleanupFailure(owner, error);
              }
            }
          }
          releaseClaim();
        } catch (error) {
          settleClaim("failed");
          releaseClaim();
          throw error;
        }
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      surfaceFailure(owner, `watcher: FAILED - omp extension could not deliver an actionable wake\n${detail}`);
    } finally {
      if (generationIsLive(owner)) {
        owner.restoring = false;
        if (owner.pendingActionables.some((pending) => pending.delivered)) schedulePendingCleanup(owner);
        // No bare arm is launched here. A generation without a child at this
        // point has either delivered a typed restoration failure after its
        // bounded retries, which hands repair to main through fm_watch_arm_omp
        // (one more silent launch past the bound could hold a hung child that
        // the repair call would then report as "unchanged"), or lost a
        // verified successor during the delivery, which takes the ordinary
        // bounded, lock-checked retry it would have taken had the pipeline
        // been idle.
        const deferred = owner.deferredClose;
        owner.deferredClose = null;
        if (deferred && !owner.child && !owner.retryTimer) {
          scheduleRetry(owner, deferred.message, deferred.predecessorArmPid);
        }
      }
    }
  }

  const receiveReplacementActionable: ReplacementActionableReceiver = (pending) => {
    if (!generationIsLive(generation)) return;
    enqueuePendingActionable(generation, pending);
    void processPendingActionables(generation);
  };

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    const timeout = armHostMode.get(armChild) ? hostReadyTimeoutMs : armReadyTimeoutMs;
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), timeout);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armRetired.add(armChild);
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(owner: SessionGeneration, predecessorArmPid: string): Promise<{
    failure: string;
    recovery?: { generation: string; watcherPid: string };
  }> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return { failure: "" };
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) {
        return { failure: "", recovery: armRecovery.get(successorChild) };
      }
      if (replacement.ok) {
        failure = "watcher: FAILED - omp extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return {
            failure: `${failure}\nwatcher: FAILED - omp extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`,
          };
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - omp extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return { failure: `${failure}\nwatcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries` };
  }

  function scheduleRetry(owner: SessionGeneration, message: string, predecessorArmPid: string): void {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(owner, `watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      surfaceFailure(owner, `watcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(owner, `watcher: FAILED - omp extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function startArm(owner: SessionGeneration, predecessorArmPid = ""): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_omp to re-arm",
      };
    }
    markLoaded();
    if (owner.child) {
      return {
        ok: true,
        message: `watcher: unchanged - omp extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    if (owner.retryTimer) {
      return {
        ok: true,
        message: `watcher: unchanged - omp extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    const id = ++owner.seq;
    const hostMode = hostModeEnabled();
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: hostMode ? hostScript : armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    if (hostMode) env.FM_SUPERVISION_HOST_PRIMARY = "omp";
    const command = hostMode ? "exec \"$FM_WATCH_ARM_SCRIPT\" park --restart" : "exec \"$FM_WATCH_ARM_SCRIPT\" --restart";
    const armChild = spawn("bash", ["-lc", `config_dir="\${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; ${command}`], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    armHostMode.set(armChild, hostMode);
    owner.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let verified = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      verified = ready;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) {
        settleReadiness(true);
      }
      if (hostMode) return;
      const reason = completedActionableLine(stdout) || completedActionableLine(stderr);
      if (reason && !armPendingActionable.has(armChild)) {
        const pending = createPendingActionable(reason, String(armChild.pid ?? ""));
        armPendingActionable.set(armChild, pending);
        enqueuePendingActionable(owner, pending);
      }
    };
    const releaseChild = (): void => {
      if (owner.child === armChild) owner.child = null;
    };
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      const classification = classifyClose(hostMode, stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      debugLog(debugBinding, "arm_child_close", generationIsLive(owner) ? `${classification.kind}-handled` : `${classification.kind}-dropped-generation-not-live`, undefined, () => ({
        ...generationDebugFields(owner),
        armChild: id,
        armPid: predecessor,
      }));
      if (classification.kind === "actionable") {
        const pending = armPendingActionable.get(armChild) ?? createPendingActionable(classification.message, predecessor);
        enqueuePendingActionable(owner, pending);
        if (!generationIsLive(owner)) return;
        owner.retryFailures = 0;
        void processPendingActionables(owner);
        return;
      }
      if (!generationIsLive(owner)) return;
      if (owner.restoring) {
        // The pipeline is still delivering the wake this successor was
        // started for. A verified successor that failed on its own keeps its
        // bounded retry for the end of that delivery; an unready child closing
        // here was retired by the restoration itself.
        if (verified && !armRetired.has(armChild)) {
          owner.deferredClose = { message: classification.message, predecessorArmPid: predecessor };
        }
        return;
      }
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.restoring) return;
      scheduleRetry(owner, `watcher: FAILED - omp extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return {
      ok: true,
      message: `watcher: started omp extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`,
    };
  }

  function activateOwnedWatch(owner: SessionGeneration): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    if (lockOwnership() !== "owned") return startArm(owner);
    replacementCoordinator.receiver = receiveReplacementActionable;
    let pending: PendingActionableClose[] = [];
    let loadFailure = "";
    try {
      pending = loadReplacementHandoffWithExpiry(loadReplacementHandoff, (note) => globalStaleNotes().push(note));
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      loadFailure = `watcher: FAILED - omp extension could not load a replacement-session actionable wake\n${detail}`;
    }
    const inProcessPending = replacementCoordinator.pending.splice(0);
    for (const actionable of [...pending, ...inProcessPending]) {
      enqueuePendingActionable(owner, actionable);
    }
    if (owner.pendingActionables.length > 0) {
      if (loadFailure) surfaceFailure(owner, loadFailure);
      const armResult = startArm(owner, owner.pendingActionables[0].predecessorArmPid);
      if (!armResult.ok) {
        surfaceFailure(owner, `watcher: FAILED - omp extension could not arm before replacement wake delivery\n${armResult.message}`);
      }
      void processPendingActionables(owner);
      return armResult;
    }
    const result = startArm(owner);
    if (loadFailure) surfaceFailure(owner, `${loadFailure}\n${result.message}`);
    return result;
  }

// Subagent context gate ("Subagent session safety" at the top of this file
// owns the contract). The primary's ctx.agent.kind is "main" with depth 0 and
// a subagent's is "sub" (verified 18.8.7, 18.10.4; 18.10.4 task children also
// carry depth > 0). The gate is defensive beyond that observed shape: it takes
// depth > 0 as subagent whether or not kind is readable, and treats any
// ambiguous ctx (absent agent, absent kind, or an unrecognized kind) as a
// subagent whenever lockOwnership() proves this process is not the fleet's
// owning primary; a fleet-owning primary keeps main semantics.
// subagentShutdownContext additionally applies that lock test to a shutdown
// ctx with no agent at all, where retiring shared primary state is the
// catastrophic path.
function subagentContext(ctx: unknown): boolean {
  if (!ctx || typeof ctx !== "object" || !("agent" in ctx)) return false;
  const agent = ctx.agent;
  if (!agent || typeof agent !== "object") return false;
  if ("kind" in agent && agent.kind === "sub") return true;
  if ("depth" in agent && typeof agent.depth === "number" && agent.depth > 0) return true;
  // Ambiguous: no kind field, or a kind this extension does not recognize.
  if (!("kind" in agent) || agent.kind !== "main") return lockOwnership() !== "owned";
  return false;
}
function subagentShutdownContext(ctx: unknown): boolean {
  if (subagentContext(ctx)) return true;
  if (!ctx || typeof ctx !== "object" || !("agent" in ctx)) return lockOwnership() !== "owned";
  return false;
}
const subagentArmStatus =
  "watcher: not armed - this is a subagent session; the supervisor's omp primary owns watcher continuity, so no action is needed here";

  pi.on?.("before_agent_start", (event, ctx) => {
    if (subagentContext(ctx)) {
      debugLog(debugBinding, "before_agent_start", "subagent-skip", ctx, () => generationDebugFields(generation));
      return;
    }
    debugLog(debugBinding, "before_agent_start", "consumeWake", ctx, () => generationDebugFields(generation));
    consumeWake(generation, String((event as { prompt?: unknown })?.prompt ?? ""));
  });
  pi.on?.("message_start", (event, ctx) => {
    if (subagentContext(ctx)) return;
    if (!event || typeof event !== "object" || !("message" in event)) return;
    const message = event.message;
    if (!message || typeof message !== "object") return;
    const role = "role" in message && typeof message.role === "string" ? message.role : "";
    const customType = "customType" in message && typeof message.customType === "string" ? message.customType : "";
    const content = "content" in message ? message.content : undefined;
    // Hidden wake: the extension delivered watcher work through pi.sendMessage
    // (customType fm.wake). omp never raises before_agent_start for the turn
    // that custom message triggers, so consumption settles here, keyed on the
    // exact content the extension sent. A custom message's content is a raw
    // string (observed against omp 18.10.4).
    if (role === "custom" && customType === "fm.wake" && typeof content === "string") {
      consumeWake(generation, content);
      return;
    }
    if (role !== "user") return;
    consumeWake(generation, userMessageText(content));
  });

  pi.on?.("session_start", async (_event, ctx) => {
    if (subagentContext(ctx)) {
      debugLog(debugBinding, "session_start", "subagent-skip", ctx, () => generationDebugFields(generation));
      return;
    }
    if (generation.stopping) generation = createGeneration();
    activateGeneration(generation);
    markLoaded();
    if (lockOwnership() !== "owned") {
      debugLog(debugBinding, "session_start", "activateGeneration-not-lock-owner", ctx, () => generationDebugFields(generation));
      return;
    }
    const result = activateOwnedWatch(generation);
    debugLog(debugBinding, "session_start", "activateOwnedWatch", ctx, () => ({ ...generationDebugFields(generation), result }));
  });
  pi.on?.("session_shutdown", async (_event, ctx) => {
    if (subagentShutdownContext(ctx)) {
      debugLog(debugBinding, "session_shutdown", "subagent-skip", ctx, () => generationDebugFields(generation));
      return;
    }
    debugLog(debugBinding, "session_shutdown", "stopSessionGeneration", ctx, () => generationDebugFields(generation));
    // omp carries no shutdown reason (verified: `reason` is undefined), so the
    // replacement handoff is always persisted when anything is pending; a
    // terminal quit then merely replays an already-drained wake next start.
    if (replacementCoordinator.receiver === receiveReplacementActionable) replacementCoordinator.receiver = null;
    await stopSessionGeneration(generation, true);
  });
  // Debug-only observers: registered only when the debug log is enabled, so
  // the default extension surface is unchanged.
  if (extensionDebugEnabled) {
    pi.on?.("agent_end", (_event, ctx) => {
      debugLog(debugBinding, "agent_end", "observe", ctx, () => generationDebugFields(generation));
    });
    pi.on?.("before_subagent_spawn", (event, ctx) => {
      const spawned = event && typeof event === "object" && "agent" in event ? event.agent : undefined;
      debugLog(debugBinding, "before_subagent_spawn", "observe", ctx, () => ({ ...generationDebugFields(generation), spawned }));
    });
  }

  pi.registerCommand?.("fm-watch-arm-omp", {
    description: "Arm firstmate watcher supervision through the omp extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const subagent = subagentContext(ctx);
      const result = subagent
        ? { ok: true, message: subagentArmStatus }
        : activateOwnedWatch(generation);
      debugLog(debugBinding, "fm-watch-arm-omp", subagent ? "subagent-skip" : "activateOwnedWatch", ctx, () => ({ ...generationDebugFields(generation), result }));
      ctx?.ui?.notify?.(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_omp",
    label: "Arm firstmate watcher",
    description: "Start the first required omp watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the omp extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required omp watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
      "Call fm_watch_arm_omp only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the omp extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    execute: async (_toolCallId: unknown, _params: unknown, _signal: unknown, _onUpdate: unknown, ctx: unknown) => {
      if (subagentContext(ctx)) {
        debugLog(debugBinding, "fm_watch_arm_omp", "subagent-skip", ctx, () => generationDebugFields(generation));
        return {
          content: [{ type: "text", text: subagentArmStatus }],
          details: { ok: true, message: subagentArmStatus },
        };
      }
      const result = activateOwnedWatch(generation);
      debugLog(debugBinding, "fm_watch_arm_omp", "activateOwnedWatch", ctx, () => ({ ...generationDebugFields(generation), result }));
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
