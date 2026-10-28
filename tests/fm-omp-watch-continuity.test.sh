#!/usr/bin/env bash
# Notification suppression must not suppress the next owned watcher cycle.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-watch-continuity)
export NODE_NO_WARNINGS=1

run_continuity_case() {
  local mode=$1 repo home out status
  repo="$TMP_ROOT/$mode/repo"
  home="$TMP_ROOT/$mode/home"
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" \
    "$repo/node_modules/typebox" "$home/state" "$home/config"
  cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" \
    "$ROOT/.pi/extensions/lib/fm-extension-debug.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$repo/bin/"
  cp "$ROOT/bin/fm-wake-drain.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-classify-lib.sh" \
    "$ROOT/bin/fm-line-cap-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-lease-lib.sh" \
    "$ROOT/bin/fm-afk-contract.sh" "$ROOT/bin/fm-path-lib.sh" "$repo/bin/"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf '%s\n' "$$" >> "$FM_HOME/state/arms"
round=$(( $(wc -l < "$FM_HOME/state/arms") ))
if [ "$FM_CONTINUITY_CASE" = empty-failure ] && [ "$round" -gt 1 ]; then
  exit 1
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture\n' "$$"
touch "$FM_HOME/state/.last-watcher-beat"
if [ "$round" -gt 1 ]; then
  while [ ! -e "$FM_HOME/state/release-$round" ]; do sleep 0.05; done
fi
if [ "$FM_CONTINUITY_CASE" = stale ] && [ "$round" -le 2 ]; then
  printf 'stale: fixture stopped responding\n'
elif [ "$round" -eq 1 ]; then
  printf 'check: already drained\n'
else
  printf 'check: fresh inbox note\n'
fi
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-wake-drain.sh"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_WAKE_QUEUE="$home/state/.wake-queue" FM_ROOT_OVERRIDE="$repo" FM_CONTINUITY_CASE="$mode" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const mode = process.env.FM_CONTINUITY_CASE;
const queue = `${state}/.wake-queue`;
const handlers = new Map();
const sent = [];
const arms = () => existsSync(`${state}/arms`) ? readFileSync(`${state}/arms`, "utf8").trim().split("\n") : [];
const until = async (condition, message) => {
  const deadline = Date.now() + 5000;
  while (!condition() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
  if (!condition()) throw new Error(message);
};
const row = (seq, kind, reason, key = `fixture-${seq}`) => `${Math.floor(Date.now() / 1000)}\t${seq}\t${kind}\t${key}\t${reason}\n`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const capture = (seq, generation) => row(seq, "check", `procevent herdr-panes fixture ${generation}`, `procevent:fixture:${generation}`);
const drained = () => readFileSync(queue, "utf8").trim() === "";
const isCapture = mode.startsWith("capture");
let rejectHidden = mode === "capture-rejected";
writeFileSync(queue, mode === "stale" ? row(1, "stale", "stale: fixture stopped responding") : isCapture ? capture(1, 40) : "");
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {}, registerTool() {},
  sendUserMessage(content) { sent.push(content); },
  sendMessage: isCapture ? (message) => {
    if (rejectHidden) {
      rejectHidden = false;
      throw new Error("fixture rejects the first hidden send before acceptance");
    }
    sent.push(message.content);
  } : undefined,
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
try {
  await handlers.get("session_start")({ type: "session_start" }, {});
  if (isCapture) {
    const consume = async (content) => {
      await handlers.get("message_start")({ message: { role: "custom", customType: "fm.wake", content } }, {});
    };
    await until(() => sent.length === 1, "initial captured result never arrived");
    await until(drained, "initial capture presentation was not acknowledged");
    let current = 2;
    let expected = 1;
    if (mode === "capture-rejected") {
      await handlers.get("before_agent_start")({ prompt: sent[0] }, {});
      writeFileSync(queue, capture(2, 40));
      writeFileSync(`${state}/release-2`, "");
      await until(() => sent.length === 2, "a rejected hidden send incorrectly earned a capture receipt");
      await until(drained, "retried presentation was not acknowledged");
      if (!sent[1].includes("procevent:fixture:40")) throw new Error("rejected capture was lost");
      await consume(sent[1]);
      current = 3;
      expected = 2;
    } else {
      await consume(sent[0]);
    }

    // Reconciliation legitimately requeues an unhandled capture under a new
    // queue sequence. Its source-generation identity has not changed.
    writeFileSync(queue, capture(current, 40));
    writeFileSync(`${state}/release-${current}`, "");
    await until(drained, "reannounced capture presentation was not acknowledged");
    if (sent.length !== expected) throw new Error("an already accepted capture woke the session twice");
    await until(() => arms().length >= current + 1, "capture coalescing lost the owned successor");

    writeFileSync(queue, capture(current + 1, 40) + row(current + 2, "check", "fresh inbox decision"));
    writeFileSync(`${state}/release-${current + 1}`, "");
    await until(() => sent.length === expected + 1, "coalescing a capture lost unrelated fresh work");
    await until(drained, "mixed capture presentation was not acknowledged");
    if (!sent[expected].includes("fresh inbox decision") || sent[expected].includes("procevent:fixture:40")) {
      throw new Error("the mixed wake repeated the accepted capture or lost its fresh row");
    }
    await consume(sent[expected]);

    writeFileSync(queue, capture(current + 3, 41));
    writeFileSync(`${state}/release-${current + 2}`, "");
    await until(() => sent.length === expected + 2, "a fresh generation of the same source was suppressed");
    await until(drained, "fresh capture presentation was not acknowledged");
    if (!sent[expected + 1].includes("procevent:fixture:41")) throw new Error("fresh source generation missing");
    await consume(sent[expected + 1]);

    // Receipt scope is the owning session, not a permanent handled marker.
    // An unhandled capture can be recovered in a replacement session.
    await handlers.get("session_shutdown")({}, {});
    writeFileSync(queue, capture(current + 4, 40));
    await handlers.get("session_start")({ type: "session_start" }, {});
    writeFileSync(`${state}/release-${current + 4}`, "");
    await until(() => sent.length === expected + 3, "replacement session lost the unhandled capture");
    await until(drained, "replacement capture presentation was not acknowledged");
    if (!sent[expected + 2].includes("procevent:fixture:40")) throw new Error("replacement capture missing");
    await consume(sent[expected + 2]);
  } else if (mode === "empty-failure") {
    await until(() => sent.length > 0, "suppressed wake lost the bounded restoration failure");
    if (sent.length !== 1 || !sent[0].includes("watcher: FAILED")) {
      throw new Error("continuity failure must be surfaced once, not silently suppressed");
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (arms().length !== 3) throw new Error("restoration escaped its configured retry bound");
  } else {
    await until(() => arms().length >= 2, "suppressing a drained close stopped supervision: no successor");
    let current = 2;
    if (mode === "stale") {
      await until(() => sent.length === 1, "initial stale wake did not arrive");
      await handlers.get("before_agent_start")({ prompt: sent[0] }, {});
      writeFileSync(queue, row(2, "stale", "stale: fixture stopped responding"));
      writeFileSync(`${state}/release-2`, "");
      await until(() => arms().length >= 3, "suppressing a repeated stale close stopped supervision: no successor");
      if (sent.length !== 1) throw new Error("an identical stale repeat was delivered twice");
      current = 3;
    } else if (sent.length !== 0) {
      throw new Error("a drained wake must remain silent");
    }
    process.kill(Number(arms()[current - 1]), 0);
    writeFileSync(queue, row(3, "check", "check: fresh inbox note"));
    writeFileSync(`${state}/release-${current}`, "");
    const expected = mode === "stale" ? 2 : 1;
    await until(() => sent.length >= expected, "a fresh note after the suppressed close never arrived");
    if (sent.length !== expected || !sent[expected - 1].includes("check: fresh inbox note")) {
      throw new Error(`suppression lost or duplicated the later actionable wake: ${JSON.stringify(sent)}`);
    }
    await until(() => arms().length >= current + 1, "fresh-note delivery has no successor");
    process.kill(Number(arms()[current]), 0);
    await handlers.get("before_agent_start")({ prompt: sent[expected - 1] }, {});
  }
} finally {
  await handlers.get("session_shutdown")({}, {});
}
JS
)
  status=$?
  expect_code 0 "$status" "omp $mode continuity: $out"
  [ -z "$out" ] || fail "omp $mode continuity printed unexpected output: $out"
  pass "omp $mode suppression preserves later delivery and bounded ownership"
}

run_continuity_case empty
run_continuity_case stale
run_continuity_case empty-failure
run_continuity_case capture
run_continuity_case capture-rejected
