// Opt-in lifecycle debug log for the omp primary extensions.
//
// Off by default. Setting FM_OMP_EXTENSION_DEBUG_LOG to an absolute file path
// before omp starts makes every logger returned here append one JSON line per
// call to that file; unset or empty, every logger is a no-op that never
// touches the filesystem or reads ctx. The log exists to answer one question
// with observed events rather than code reading: which session, factory
// binding, and ctx shape reached a lifecycle handler, and which code path
// that handler then took.
//
// Each line carries: ts (epoch ms), pid, ppid, ext (the extension label),
// binding (the per-factory-invocation id the caller passes), event, path (the
// code path the handler took), ctx (agent kind/id/name/depth/parentId, the
// session id from ctx.sessionManager.getSessionId(), a stable per-process
// identity number for the ctx.sessionManager object, and ctx's own keys), and
// any caller-supplied fields. Fields may be passed as a function so a disabled
// logger never evaluates them. A write failure is swallowed: debug logging
// must never change extension behaviour.
import { appendFileSync } from "node:fs";

const debugLogPath = process.env.FM_OMP_EXTENSION_DEBUG_LOG || "";

export const extensionDebugEnabled = debugLogPath !== "";

const objectIdentities = new WeakMap<object, number>();
let nextObjectIdentity = 0;

function objectIdentity(value: unknown): number | null {
  if (!value || (typeof value !== "object" && typeof value !== "function")) return null;
  const known = objectIdentities.get(value as object);
  if (known !== undefined) return known;
  nextObjectIdentity += 1;
  objectIdentities.set(value as object, nextObjectIdentity);
  return nextObjectIdentity;
}

function field(source: unknown, key: string): unknown {
  if (!source || typeof source !== "object" || !(key in source)) return undefined;
  try {
    return (source as Record<string, unknown>)[key];
  } catch (error) {
    return `<throws: ${error instanceof Error ? error.message : String(error)}>`;
  }
}

function ctxShape(ctx: unknown): Record<string, unknown> | null {
  if (!ctx || typeof ctx !== "object") return ctx === undefined ? null : { type: typeof ctx };
  const agent = field(ctx, "agent");
  const sessionManager = field(ctx, "sessionManager");
  let sessionId: unknown;
  try {
    const getSessionId = field(sessionManager, "getSessionId");
    sessionId = typeof getSessionId === "function" ? getSessionId.call(sessionManager) : undefined;
  } catch (error) {
    sessionId = `<throws: ${error instanceof Error ? error.message : String(error)}>`;
  }
  return {
    keys: Object.keys(ctx),
    hasAgent: "agent" in ctx,
    agent: agent && typeof agent === "object"
      ? {
          kind: field(agent, "kind"),
          id: field(agent, "id"),
          name: field(agent, "name"),
          depth: field(agent, "depth"),
          parentId: field(agent, "parentId"),
        }
      : agent === undefined ? undefined : { type: typeof agent },
    sessionId,
    sessionManagerIdentity: objectIdentity(sessionManager),
    ctxIdentity: objectIdentity(ctx),
  };
}

export type ExtensionDebugLog = (
  binding: number,
  event: string,
  path: string,
  ctx?: unknown,
  fields?: Record<string, unknown> | (() => Record<string, unknown>),
) => void;

export function extensionDebugLogger(ext: string): ExtensionDebugLog {
  if (!extensionDebugEnabled) return () => {};
  return (binding, event, path, ctx, fields) => {
    try {
      const line = JSON.stringify({
        ts: Date.now(),
        pid: process.pid,
        ppid: process.ppid,
        ext,
        binding,
        event,
        path,
        ctx: ctxShape(ctx),
        ...(typeof fields === "function" ? fields() : fields),
      });
      appendFileSync(debugLogPath, `${line}\n`);
    } catch {
      // Debug logging never changes extension behaviour.
    }
  };
}
