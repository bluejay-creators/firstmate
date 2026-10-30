// Firstmate steering-inbox listener for omp (Oh My Pi).
//
// Delivery today works the other way around: firstmate writes a durable
// record into the task's steering inbox and then types a constant doorbell
// line into the worker's pane (bin/fm-task-inbox-lib.sh). Two weak spots
// motivated this listener: an agent mid-turn never sees its inbox until the
// typed doorbell lands after it settles, and the doorbell is skipped whenever
// the pane's composer holds unsent text. This extension replaces the typed
// line for a session that loads it: it polls the session's own inbox
// directory and delivers each new record straight into the session through
// omp's message API - as a follow-up that opens its own turn when the agent
// is idle, and with deliverAs "steer" while it is mid-turn, so the steer is
// injected at the next safe boundary of the running turn (verified in the
// omp binary: "steer" steers into a running turn; "nextTurn" is only pulled
// from the queue when a run already follows). Nothing is ever typed into
// the pane.
//
// Contract with the shell side (bin/fm-task-inbox-lib.sh owns the shared
// pieces):
//   - Heartbeat: this extension keeps <inbox-dir>/.listener alive (rewritten
//     every poll; format "<pid>\t<epoch-ms>"), removing it at
//     session_shutdown. While that file is fresh and written by a live pid,
//     fm-send and the watcher send no doorbell; a stale or absent heartbeat
//     falls back to today's doorbell path untouched. The shell-side live
//     check lives in bin/fm-task-inbox-listener-lib.sh, which also owns the
//     freshness tolerance as FM_INBOX_LISTENER_STALE_SECS (default 30).
//   - Ack: the `mv` into handled/ remains the only acknowledgement. This
//     extension performs that move itself, only after delivery is confirmed
//     CONSUMED: an idle delivery raises before_agent_start carrying the exact
//     sent text; a mid-turn delivery joins the running run as a user
//     message_start carrying that text (the same consumption contract
//     .omp/extensions/fm-primary-omp-watch.ts states for its follow-ups). A
//     send that omp rejects leaves the record in place, unconsumed, for a
//     later poll or the doorbell fallback. A delivery still unconsumed at a
//     replacement shutdown (/new, /resume, /fork) is re-delivered by the
//     successor session's listener, which loads in the same process.
//     Within a live session, five consecutive idle polls without consumption
//     release only the in-memory send claim and retry the same durable record.
//     Busy/continuing turns reset that idle count; expiry never acknowledges
//     or skips a record. This remains at-least-once if the host delays rather
//     than drops a queued message. The default poll makes that idle grace 15s.
//   - Dedupe and restart safety: records are listed in numeric order and one
//     delivery is in flight at a time; a record already in handled/ is never
//     delivered. A listener restarted after a crash finds no live heartbeat
//     of its predecessor, scans only records still outside handled/, and
//     therefore redelivers nothing already acknowledged. session_start
//     re-arms and rescans immediately so a replacement session picks up
//     whatever its predecessor left unconsumed.
//
// Loading: any omp session can opt in with `-e <absolute-path>` (fleet
// workers and secondmates get it from bin/fm-spawn.sh). The inbox directory
// resolves from $FM_TASK_INBOX, which fm-spawn exports into every launch;
// with that unset the extension stays inert rather than guessing at a path.
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

// The omp extension API surface this file uses (declared locally as in
// fm-primary-omp-watch.ts; omp ships no separately installable types).
interface ExtensionAPI {
  on?: (event: string, handler: (event: unknown, ctx: unknown) => unknown) => void;
  sendUserMessage: (content: string, options?: { deliverAs?: string }) => unknown;
}

interface TextPart {
  type: string;
  text?: unknown;
}

interface IncomingMessage {
  role?: unknown;
  content?: unknown;
}

function positiveInteger(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

const pollMs = positiveInteger("FM_INBOX_LISTENER_POLL_MS", 3000);
const idlePollLimit = 5;
const inboxDir = process.env.FM_TASK_INBOX || "";
const heartbeatPath = inboxDir ? join(inboxDir, ".listener") : "";

function heartbeatPid(): number | null {
  let content: string;
  try {
    content = readFileSync(heartbeatPath, "utf8");
  } catch {
    return null;
  }
  const pid = Number((content.split("\t")[0] || "").trim());
  return Number.isInteger(pid) && pid > 0 ? pid : null;
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
  return true;
}

// An earlier listener's heartbeat must not outlive its writer: the shell-side
// freshness check also refuses a dead pid, and a live replacement removes a
// foreign stale record before publishing its own.
function clearStaleHeartbeat(): void {
  const pid = heartbeatPid();
  if (pid === null) return;
  if (pid !== process.pid && pidAlive(pid)) return;
  try {
    unlinkSync(heartbeatPath);
  } catch {
    // A concurrent writer owns it now; the next heartbeat pass republishes.
  }
}

function writeHeartbeat(): void {
  if (!heartbeatPath) return;
  try {
    mkdirSync(inboxDir, { recursive: true });
    writeFileSync(heartbeatPath, `${process.pid}\t${Date.now()}`, "utf8");
  } catch {
    // A heartbeat that cannot be written only means the sender falls back to
    // the doorbell; delivery through the listener still works.
  }
}

function removeHeartbeat(): void {
  if (!heartbeatPath) return;
  if (heartbeatPid() !== process.pid) return;
  try {
    unlinkSync(heartbeatPath);
  } catch {
    // Already gone or raced by another listener; nothing to remove.
  }
}

// Record names are the inbox contract's zero-padded numeric NNN.msg.
function listRecords(): string[] {
  let names: string[];
  try {
    names = readdirSync(inboxDir);
  } catch {
    return [];
  }
  return names
    .filter((n) => /^\d+\.msg$/.test(n) && existsSync(join(inboxDir, n)))
    .sort((a, b) => parseInt(a, 10) - parseInt(b, 10));
}

function readBody(path: string): string | null {
  let content: string;
  try {
    content = readFileSync(path, "utf8");
  } catch {
    return null;
  }
  const marker = content.indexOf("\n--\n");
  return marker === -1 ? null : content.slice(marker + 4);
}

// The text omp carries in a user message_start: sendUserMessage wraps a
// string as one text part (mirrors fm-primary-omp-watch.ts).
function userMessageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  let out = "";
  for (const part of content as TextPart[]) {
    if (part && typeof part === "object" && part.type === "text" && typeof part.text === "string") {
      out += part.text;
    }
  }
  return out;
}

export default function (pi: ExtensionAPI): void {
  if (!inboxDir) return; // not a fleet launch; stay inert

  // Busy state from omp's structural loop events (agent_start / agent_end),
  // the same events the fleet's busy-state contract consumes; never from a
  // rendered surface and never from ctx.isIdle(), which the busy contract
  // already proved reads false at a natural TUI agent_end.
  let busy = false;
  let timer: NodeJS.Timeout | null = null;
  // Only exact consumption acknowledges a record. A dropped host queue entry
  // may be retried after bounded idle polls, but never while a turn is busy.
  let pending: { record: string; content: string; idlePolls: number } | null = null;

  function ack(record: string): void {
    try {
      mkdirSync(join(inboxDir, "handled"), { recursive: true });
      renameSync(record, join(inboxDir, "handled", basename(record)));
    } catch {
      // A concurrent move (the worker itself read the inbox) is the same
      // acknowledgement; a real failure leaves the record for the doorbell
      // fallback (once this heartbeat goes stale) or redelivery by a later
      // listener, matching the doorbell era's at-least-once posture.
    }
  }

  // Consumption: an idle delivery raises before_agent_start with the prompt;
  // a mid-turn delivery joins the running run as a user message_start.
  // Either finishing event carries the exact sent text.
  function maybeConsume(text: string): void {
    if (pending && pending.content === text) {
      ack(pending.record);
      pending = null;
    }
  }

  function deliverOne(polling = false): void {
    if (pending) {
      if (!existsSync(pending.record)) {
        pending = null; // the resident acknowledged it independently
      } else if (!busy && polling && ++pending.idlePolls >= idlePollLimit) {
        pending = null; // unconsumed stays durable; retry the same first record
      } else {
        if (busy) pending.idlePolls = 0;
        return;
      }
    }
    const next = listRecords()[0];
    if (!next) return;
    const path = join(inboxDir, next);
    const body = readBody(path);
    if (body === null) return; // unreadable or mid-write; retry next poll
    const content = `Firstmate instruction from your steering inbox (record ${next}):\n\n${body}\n\nDelivered in-session by the inbox listener, which acknowledged the record once the run accepted it.`;
    const delivery = { record: path, content, idlePolls: 0 };
    pending = delivery; // consumption may be synchronous with sendUserMessage
    try {
      // Idle: a follow-up opens its own turn. Mid-turn: "steer" queues the
      // message into the running run's steering lane, injected at its next
      // safe boundary instead of failing the busy send.
      pi.sendUserMessage(content, { deliverAs: busy ? "steer" : "followUp" });
    } catch {
      if (pending === delivery) pending = null;
      return; // rejected send: nothing consumed, record stays put
    }
  }
  function startPolling(): void {
    if (timer) return;
    clearStaleHeartbeat();
    writeHeartbeat();
    timer = setInterval(() => {
      writeHeartbeat();
      deliverOne(true);
    }, pollMs);
    timer.unref();
  }

  pi.on?.("session_start", () => {
    busy = false;
    // pending is NOT reset here: session_shutdown already cleared an
    // unconsumed predecessor delivery, and a pending record from THIS binding
    // (the tail's load-time deliverOne ran before session_start on some omp
    // builds) is still owed its consumption tracking; deliverOne dedupes.
    startPolling();
    deliverOne();
  });
  pi.on?.("agent_start", () => {
    busy = true;
  });
  pi.on?.("agent_end", (event: unknown) => {
    busy = (event as { willContinue?: unknown } | null)?.willContinue === true;
    if (busy) return;
    deliverOne();
  });
  pi.on?.("before_agent_start", (event: unknown) => {
    const prompt = (event as { prompt?: unknown } | null)?.prompt;
    if (typeof prompt === "string") maybeConsume(prompt);
  });
  pi.on?.("message_start", (event: unknown) => {
    const message = (event as { message?: unknown } | null)?.message;
    if (!message || typeof message !== "object") return;
    const incoming = message as IncomingMessage;
    if (incoming.role === "user") maybeConsume(userMessageText(incoming.content));
  });
  pi.on?.("session_shutdown", () => {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
    // An unconsumed delivery stays unacked: the durable record remains for
    // the replacement session's listener (around /new, /resume, /fork) or
    // the doorbell fallback after an ungraceful exit.
    pending = null;
    removeHeartbeat();
  });

  // Plain load (a session_start may already have fired before this -e
  // finished binding on some omp builds): arm immediately too.
  startPolling();
  deliverOne();
}
