#!/usr/bin/env python3
"""Publish native OMP approval snapshots through the existing captain board.

Internal engine for fm-captain-ask.sh --approval-event FILE and
--approval-reconcile. FM_HOME must name the owning primary home explicitly.
The board and Git-hook hygiene remain owned by fm-bead-board-lib.sh.
No database is initialized, no server is started, and no command in a card
is executed. --dry-run uses the native board's create preview only.

Input is firstmate.omp-approval.v1 JSON with approvalId, sessionId,
approvalKind, requestedAt, prompt, choices and origin. toolCallId/toolName
are included only when the native caller supplies them. Optional command,
commandCwd and reason are final native display snapshots.
Resolution carries kind (approved/denied/cancelled/timeout/unavailable), optional
choice and reason. Approved/denied resolutions require the actual native choice.
Never supply earlier tool-call input or raw credential-bearing arguments.

One board task is keyed by native session/approval identity. Immutable
request fingerprints reject identity reuse with changed intent. Requested
replays cannot reopen a terminal prompt. Permission resolution is never
reported as command completion. Pending files survive backend errors and
are retried only by a later event or the existing watcher reconciliation.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

SCHEMA = "firstmate.omp-approval.v1"
KINDS = {"tool", "settings", "consent"}
RESOLUTIONS = {"approved", "denied", "cancelled", "timeout", "unavailable"}
ENV_KEYS = ("HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE")
CHECK_DEADLINE = None
BOARD_PROGRAM = r'''
set -u
. "$1"
shift
rc=0
fm_bead_board_ready || rc=$?
case "$rc" in
  0) ;;
  1) printf '%s\n' 'No captain board is configured for this home' >&2; exit 69 ;;
  *) printf '%s\n' 'The configured captain board is unavailable' >&2; exit 69 ;;
esac
fm_bead_board_bd "$@"
'''


class Error(Exception):
    pass


class Busy(Error):
    pass


def text(value, field, *, optional=False):
    if optional and value is None:
        return None
    if not isinstance(value, str) or not value or "\0" in value:
        raise Error(f"{field} must be a nonempty string without NUL")
    return value


def display_text(value, field):
    if not isinstance(value, str):
        raise Error(f"{field} must be a string")
    return value


def normalize(raw):
    if not isinstance(raw, dict) or raw.get("schema") != SCHEMA:
        raise Error("Unsupported native approval snapshot schema")
    allowed = {"schema", "approvalId", "sessionId", "toolCallId", "toolName",
               "approvalKind", "requestedAt", "prompt", "origin", "command",
               "commandCwd", "choices", "reason", "resolution"}
    if set(raw) - allowed:
        raise Error("Native approval snapshot contains unsupported fields")
    request = {"schema": SCHEMA}
    for field in ("approvalId", "sessionId", "approvalKind", "requestedAt"):
        request[field] = text(raw.get(field), field)
    request["prompt"] = display_text(raw.get("prompt"), "prompt")
    if request["approvalKind"] not in KINDS:
        raise Error("Unsupported native approval kind")
    choices = raw.get("choices")
    if not isinstance(choices, list) or not choices:
        raise Error("The native approval must include its offered choices")
    request["choices"] = [text(choice, "choices[]") for choice in choices]
    for field in ("toolCallId", "toolName"):
        value = text(raw.get(field), field, optional=True)
        if value is not None:
            request[field] = value
    for field in ("command", "commandCwd", "reason"):
        if raw.get(field) is not None:
            request[field] = display_text(raw[field], field)
    if request.get("toolName") == "bash" and "command" not in request:
        raise Error("A Bash approval requires the final native command snapshot")
    origin = raw.get("origin")
    if not isinstance(origin, dict) or set(origin) - {"machine", "tabLabel", "paneId", "cwd"}:
        raise Error("Invalid native approval origin")
    request["origin"] = {
        "machine": text(origin.get("machine"), "origin.machine"),
        "cwd": text(origin.get("cwd"), "origin.cwd"),
    }
    for field in ("tabLabel", "paneId"):
        value = text(origin.get(field), f"origin.{field}", optional=True)
        if value is not None:
            request["origin"][field] = value
    resolution = raw.get("resolution")
    if resolution is not None:
        if not isinstance(resolution, dict) or set(resolution) - {"kind", "choice", "reason"}:
            raise Error("Invalid native approval resolution")
        resolution = {key: text(value, f"resolution.{key}") for key, value in resolution.items()}
        if resolution.get("kind") not in RESOLUTIONS:
            raise Error("Unsupported native approval resolution")
        if resolution["kind"] in {"approved", "denied"} and not resolution.get("choice"):
            raise Error("A native decision requires the actual selected choice")
        if "choice" in resolution and resolution["choice"] not in request["choices"]:
            raise Error("The observed native choice was not offered")
    return request, resolution


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode()).hexdigest()


def identity(request):
    return digest([request["sessionId"], request["approvalId"]])


def fingerprint(request):
    return digest({
        **{key: value for key, value in request.items() if key != "origin"},
        "cwd": request["origin"]["cwd"],
    })


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".approval-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


@contextlib.contextmanager
def locked(path):
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Busy("Native approval publication is already running; retry the unchanged event file") from None
        yield
    finally:
        os.close(fd)


class Board:
    def __init__(self, home):
        self.home = home
        self.environment = {key: os.environ[key] for key in ENV_KEYS if key in os.environ}
        self.environment["FM_HOME"] = str(home)
        self.library = Path(__file__).resolve().with_name("fm-bead-board-lib.sh")

    def run(self, arguments):
        timeout = 30
        if CHECK_DEADLINE is not None:
            timeout = min(timeout, CHECK_DEADLINE - time.monotonic())
            if timeout <= 0:
                raise Error("Native approval reconciliation exceeded its check window; events remain pending")
        process = subprocess.Popen(
            arguments,
            cwd=self.home, env=self.environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Error("Captain-board operation timed out; native event remains pending") from None
        finally:
            if process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
        if process.returncode:
            raise Error(f"Captain-card operation failed (exit {process.returncode}); native event remains pending")
        return output

    def call(self, *args):
        return self.run(["bash", "-c", BOARD_PROGRAM, "fm-approval-board", str(self.library), *args])

    def lookup(self, bead):
        rows = json.loads(self.call("list", "--id", bead, "--all", "--limit", "1", "--json"))
        if not isinstance(rows, list) or len(rows) > 1:
            raise Error("Unexpected bounded captain-board lookup response")
        if rows and rows[0].get("id") != bead:
            raise Error("Captain-board lookup returned another task")
        return rows[0] if rows else None


def safe_block(value):
    value = "".join(char if char in "\n\t" or ord(char) >= 32 else f"\\u{ord(char):04x}"
                    for char in value)
    fence = "`" * max(3, 1 + max((len(run) for run in re.findall(r"`+", value)), default=0))
    return f"{fence}text\n{value}\n{fence}"


def card(request, key):
    origin = request["origin"]
    actor = " ".join((origin.get("tabLabel") or "OMP").split())
    kind = request["approvalKind"]
    tool = request.get("toolName")
    action = {"settings": "a settings change", "consent": "a consent request"}.get(kind)
    if action is None:
        action = "a Bash command" if tool == "bash" else (tool or "a tool request")
    title = f"Approve {action} in {actor}?"
    location = f"{origin['machine']}; {actor}"
    if origin.get("paneId"):
        location += f"; pane {origin['paneId']}"
    parts = [
        "Presentation unchecked: native permission requests are surfaced immediately, not held for shape review.",
        f"WHERE TO ACT: the original native prompt on {location}. This card records the request; it cannot apply a phone answer to the native dialog.",
        f"AFFECTS: {tool or kind}; session {request['sessionId']}; directory {origin['cwd']}.",
        "WHY:\n" + safe_block(request.get("reason", "No separate reason was supplied; see the final native prompt below.")),
    ]
    if "command" in request:
        parts.append("FINAL COMMAND:\n" + safe_block(request["command"]))
    if "commandCwd" in request:
        parts.append("EXPLICIT COMMAND DIRECTORY:\n" + safe_block(request["commandCwd"]))
    parts.extend([
        "FINAL NATIVE PROMPT:\n" + safe_block(request["prompt"]),
        "NATIVE CHOICES:\n" + safe_block(json.dumps(request["choices"], ensure_ascii=False)),
        "Approve or deny only in that original prompt. Permission is not proof the command ran. This card never executes command text or grants an always-allow rule.",
    ])
    metadata = {"approval": {
        "schema": SCHEMA, "kind": "native-omp", "sourceKey": key,
        "fingerprint": fingerprint(request), "request": request,
        "actionLocation": "agent-tab", "shape": "unchecked",
        "permissionState": "pending", "executionEstablished": False,
    }}
    return title, "\n\n".join(parts), metadata


def validate_owned(row, key, expected_fingerprint):
    metadata = row.get("metadata")
    approval = metadata.get("approval") if isinstance(metadata, dict) else None
    if not isinstance(approval, dict):
        raise Error("Existing captain task has no native approval ownership record")
    if approval.get("sourceKey") != key or approval.get("fingerprint") != expected_fingerprint:
        raise Error("Existing captain task belongs to another request; refusing to overwrite it")


def publication_result(state, key):
    resolution = state.get("resolution")
    return {"beadId": state["beadId"],
            "state": resolution["kind"] if resolution else "pending",
            "sourceKey": key, "origin": state["request"]["origin"]}


def publish(home, pending, handled, key, dry_run=False):
    pending_path, handled_path = pending / f"{key}.json", handled / f"{key}.json"
    path = pending_path if pending_path.exists() else handled_path
    state = json.loads(path.read_text())
    request, resolution = state["request"], state.get("resolution")
    display_fingerprint = digest(request)
    if (not dry_run and state.get("published") and
            state.get("publishedResolution") == resolution and
            state.get("publishedRequest") == display_fingerprint):
        return publication_result(state, key)
    board = Board(home)
    if not state.get("beadId"):
        prefix = board.call("config", "get", "issue_prefix").strip()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", prefix):
            raise Error("Configured captain-board prefix is invalid")
        state["beadId"] = f"{prefix}-omp-{key[:24]}"
        if not dry_run:
            atomic_json(path, state)
    bead = state["beadId"]
    title, body, metadata = card(request, key)
    row = board.lookup(bead)
    with tempfile.TemporaryDirectory(prefix="approval-publish-", dir=pending.parent) as directory:
        body_file = Path(directory) / "body.txt"
        metadata_file = Path(directory) / "metadata.json"
        body_file.write_text(body)
        metadata_file.write_text(json.dumps(metadata))
        if row is None:
            arguments = ["create", "--id", bead, "--title", title,
                         "--type", "task", "--assignee", "captain", "--labels",
                         "captain,firstmate-ask,omp-approval", "--priority", "1",
                         "--body-file", str(body_file), "--metadata", "@" + str(metadata_file), "--json"]
            if dry_run:
                board.call(*arguments, "--dry-run")
                return {"beadId": bead, "state": "preview", "sourceKey": key}
            try:
                board.call(*arguments)
            except Error:
                row = board.lookup(bead)
                if row is None:
                    raise
            else:
                row = board.lookup(bead)
        if row is None:
            raise Error("Created captain task could not be read back")
        validate_owned(row, key, metadata["approval"]["fingerprint"])
        if dry_run:
            return {"beadId": bead, "state": row.get("status"), "sourceKey": key}
        current_metadata = row["metadata"]
        display_changed = current_metadata["approval"].get("request") != request
        if display_changed:
            current_metadata["approval"]["request"] = request
        resolution_changed = resolution is not None and (
            current_metadata["approval"].get("permissionState") != resolution["kind"] or
            current_metadata["approval"].get("nativeResolution") != resolution)
        if resolution_changed:
            current_metadata["approval"]["permissionState"] = resolution["kind"]
            current_metadata["approval"]["nativeResolution"] = resolution
        if display_changed or resolution_changed:
            metadata_file.write_text(json.dumps(current_metadata))
            board.call("update", bead, "--metadata", "@" + str(metadata_file))
        if resolution:
            if row.get("status") != "closed":
                reason = ("Native UI selected: " + resolution["choice"]
                          if resolution["kind"] in {"approved", "denied"}
                          else "Native request ended without a decision: " + resolution["kind"])
                board.call("close", bead, "--reason", reason)
        elif not state.get("shapeNoticeSent"):
            note = f"Native OMP approval card {bead} needs presentation review only. Preserve its bound request and permission choices. It was surfaced immediately as an unchecked native-security request."
            try:
                board.run(["bash", str(Path(__file__).resolve().with_name("fm-inbox.sh")), "note",
                           "--request-id", "approval-shape-" + key[:32], "--", note])
            except Error:
                raise Error("Captain card exists, but its shape-review notice remains pending") from None
            state["shapeNoticeSent"] = True
        state["published"] = True
        state["publishedResolution"] = resolution
        state["publishedRequest"] = display_fingerprint
        if resolution:
            atomic_json(handled_path, state)
            if pending_path.exists():
                pending_path.unlink()
        else:
            atomic_json(pending_path, state)
    return publication_result(state, key)


def merged_state(path, request, resolution):
    state = json.loads(path.read_text()) if path.exists() else {"request": request}
    if fingerprint(state["request"]) != fingerprint(request):
        raise Error("Native approval identity was reused with changed intent")
    request["origin"] = {**state["request"]["origin"], **request["origin"]}
    state["request"] = request
    if resolution:
        if state.get("resolution") and state["resolution"] != resolution:
            raise Error("Native approval has conflicting terminal observations")
        state["resolution"] = resolution
    return state


def ingest(home, event, dry_run=False):
    request, resolution = normalize(json.loads(event.read_text()))
    key = identity(request)
    root = home / "state" / "captain-asks" / "omp"
    pending, handled = root / "pending", root / "handled"
    path = pending / f"{key}.json"
    if not path.exists() and (handled / path.name).exists():
        path = handled / path.name
    if dry_run:
        state = merged_state(path, request, resolution)
        with tempfile.TemporaryDirectory(prefix="approval-preview-") as temporary:
            preview = Path(temporary)
            preview_pending, preview_handled = preview / "pending", preview / "handled"
            preview_pending.mkdir()
            preview_handled.mkdir()
            atomic_json(preview_pending / f"{key}.json", state)
            return publish(home, preview_pending, preview_handled, key, True)
    for directory in (root, pending, handled, root / "locks"):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with locked(root / "locks" / f"{key}.lock"):
        path = pending / f"{key}.json"
        if not path.exists() and (handled / path.name).exists():
            path = handled / path.name
        state = merged_state(path, request, resolution)
        atomic_json(path, state)
        return publish(home, pending, handled, key)


def reconcile(home):
    root = home / "state" / "captain-asks" / "omp"
    pending, handled = root / "pending", root / "handled"
    results, failures, attempted, busy = [], [], set(), []
    for event in sorted((root / "outbox").glob("*.json")):
        try:
            if not re.fullmatch(r"[a-f0-9]{64}", event.stem):
                raise Error("Unexpected native approval outbox filename")
            request, _ = normalize(json.loads(event.read_text()))
            attempted.add(identity(request))
            results.append(ingest(home, event))
            event.unlink()
        except Busy:
            busy.append(event.name)
        except (Error, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures.append({"event": event.name, "error": str(error)})
    for path in sorted(pending.glob("*.json")):
        key = path.stem
        if key in attempted:
            continue
        try:
            if not re.fullmatch(r"[a-f0-9]{64}", key):
                raise Error("Unexpected native approval state filename")
            with locked(root / "locks" / f"{key}.lock"):
                if path.exists():
                    results.append(publish(home, pending, handled, key))
        except Busy:
            busy.append(key)
        except (Error, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures.append({"sourceKey": key, "error": str(error)})
    return {"results": results, "errors": failures, "busy": busy}


def check_result(home, result):
    marker = home / "state" / "captain-asks" / "omp" / ".publication-error.json"
    messages = sorted({failure["error"] for failure in result["errors"]})
    if not messages:
        if result["busy"] and not result["results"]:
            return
        if marker.exists():
            marker.unlink()
            print("native-approvals: publication error cleared")
        return
    previous = json.loads(marker.read_text()) if marker.exists() else None
    if previous != messages:
        atomic_json(marker, messages)
        print("native-approvals: publication pending: " + "; ".join(messages))


def main():
    global CHECK_DEADLINE
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--event", type=Path)
    mode.add_argument("--protocol", action="store_true")
    mode.add_argument("--reconcile", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.protocol:
        print(SCHEMA)
        return
    if args.dry_run and not args.event:
        parser.error("--dry-run requires --event FILE")
    if not os.environ.get("FM_HOME"):
        raise Error("FM_HOME is required for native approval routing")
    home = Path(os.environ["FM_HOME"]).resolve()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda received, _frame: sys.exit(128 + received))
    if args.check:
        CHECK_DEADLINE = time.monotonic() + 20
    result = reconcile(home) if (args.reconcile or args.check) else ingest(home, args.event, args.dry_run)
    if args.check:
        check_result(home, result)
    else:
        print(json.dumps(result, ensure_ascii=False))
        if args.reconcile and result["errors"]:
            sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except Busy as error:
        print(f"fm-approval-prompt: {error}", file=sys.stderr)
        sys.exit(75)
    except (Error, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"fm-approval-prompt: {error}", file=sys.stderr)
        sys.exit(1)
