#!/usr/bin/env python3
"""Durably couple a captain ask's board task and native inbox delivery.

Usage: FM_HOME=HOME fm_route_ask.py send --key REQUEST --owner OWNER
         --title TITLE --source LINK --message-file FILE [--task ID] [--due DATE]
       FM_HOME=HOME fm_route_ask.py list
       FM_HOME=HOME fm_route_ask.py check

config/beads-board and fm_bead_accountability own board addressing/CLI hygiene.
The board commits the exact outbox intent BEFORE native delivery. A failed
transport leaves an actionable pending task, never a delivered taskless ask.
Retry the identical key/input: creation acknowledgements may be lost and native
delivery is idempotent, including after a crash. Changed asks need a new key;
--task attaches that new request to an existing nonterminal task. Existing
specification, ETA commitments and unrelated metadata are preserved; a recorded
commitment/captain ownership transfer precedes reassignment. --due is passed
only for creation; board-required deadlines are never invented/waived.

Task metadata.route_ask owns the current intent and completion; local receipts
are recovery/integrity evidence, NEVER a task or waiting-list authority. list
reads only the board. check also flags receipt/inbox references without tasks
and pending routing, without sending, repairing or registering a watcher.
Only explicitly tagged routed asks can be classified; generic FYI/answer
messages remain fm-send, not guessed tasks. Use this command for captain asks.
Native delivery IDs deduplicate delivery; follow-through lives on the
canonical board, not a second pending-reply task. firstmate uses its own native
Inbox; other owners use fm-send's recorded local/remote task selector. Missing
routes stop with the canonical task pending, never fall back to pane guesses.
"""
import argparse
from datetime import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from fm_bead_accountability import atomic_json, board_command, configured_board

ROOT = Path(__file__).resolve().parent
MARKER = re.compile(r"(?:^|\bdelivery=[a-f0-9]{16} )\[fm-route-ask task=([A-Za-z0-9_.-]+) request=([A-Za-z0-9_.:-]+)\]\s*$")

def native_environment(home):
    return dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home),
                FM_STATE_OVERRIDE=str(home / "state"), FM_DATA_OVERRIDE=str(home / "data"),
                FM_CONFIG_OVERRIDE=str(home / "config"))


def self_notes(home):
    if not (home / "state/inbox").exists():
        return []
    result = subprocess.run(["bash", str(ROOT / "fm-inbox.sh"), "receipts",
                             "--all-pending", "--all-handled", "--all-replies"],
                            env=native_environment(home), capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError("native Inbox receipts unavailable")
    value = json.loads(result.stdout)
    if value.get("omitted"):
        raise RuntimeError("native Inbox receipts incomplete")
    return value["pending"] + value["handled"]



def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def rows(board):
    result = {}
    for line in board_command(board, "export", "--no-memories").splitlines():
        if line.strip():
            row = json.loads(line)
            if not isinstance(row, dict) or not isinstance(row.get("id"), str):
                raise ValueError("invalid board export")
            if row["id"] in result:
                raise ValueError("duplicate board task")
            result[row["id"]] = row
    return result


def route(row):
    metadata = row.get("metadata") or {}
    value = metadata.get("route_ask") if isinstance(metadata, dict) else None
    return value if isinstance(value, dict) and value.get("version") == 1 else None


def projection(board_rows):
    """The route-specific plate/waiting projection has no receipt dependency."""
    result = []
    for task, row in board_rows.items():
        intent = route(row)
        if intent and row.get("status") not in {"closed", "tombstone"}:
            metadata = row.get("metadata") or {}
            result.append(dict(id=task, title=row.get("title"), assignee=row.get("assignee"),
                               author=metadata.get("author"), status=row.get("status"),
                               eta=metadata.get("eta"), etaby=metadata.get("etaby"),
                               eta_asked=intent["eta_asked"], source=intent["source"],
                               routing=intent["state"]))
    return sorted(result, key=lambda row: row["id"])


def integrity(home, board_rows):
    findings = set()
    for path in (home / "state/routed-asks").glob("*.json"):
        try:
            receipt = json.loads(path.read_text())
            task = receipt.get("task")
            if task and task not in board_rows:
                findings.add(("routed-note-without-task", task))
            elif not task:
                committed = any(route(row) and route(row).get("origin") == str(home)
                                and route(row).get("key") == receipt.get("key")
                                for row in board_rows.values())
                if not committed:
                    findings.add(("uncommitted-route", receipt.get("key", path.stem)))
        except (ValueError, OSError, AttributeError):
            findings.add(("unreadable-route-receipt", path.name))
    # Cover lost local receipts as well as already-acknowledged native notes.
    for pattern in ("*.inbox/*.msg", "*.inbox/handled/*.msg"):
        for path in (home / "state").glob(pattern):
            if path.is_symlink():
                continue
            with path.open(encoding="utf-8") as stream:
                for line in stream:
                    if line.rstrip("\n") == "--":
                        header = stream.readline()
                        break
                else:
                    header = ""
            for match in MARKER.finditer(header):
                if match[1] not in board_rows:
                    findings.add(("routed-note-without-task", match[1]))
    for note in self_notes(home):
        header = note["body"].splitlines()[0] if note.get("body") else ""
        for match in MARKER.finditer(header):
            if match[1] not in board_rows:
                findings.add(("routed-note-without-task", match[1]))
    for task, row in board_rows.items():
        intent = route(row)
        if intent and intent.get("state") != "delivered" and row.get("status") not in {"closed", "tombstone"}:
            findings.add(("routing-pending", task))
    return [dict(kind=kind, id=task) for kind, task in sorted(findings)]


def deliver(home, intent, task):
    body = (f"[fm-route-ask task={task} request={intent['key']}]\n"
            f"ETA asked {intent['eta_asked']}\nSource: {intent['source']}\n\n{intent['message']}")
    environment = native_environment(home)
    if intent["owner"] == "firstmate":
        command = ["bash", str(ROOT / "fm-inbox.sh"), "note", "--request-id",
                   "route-ask-" + intent["delivery_id"], "--", body]
    else:
        command = ["bash", str(ROOT / "fm-send.sh"), intent["owner"],
                   "--delivery-id", intent["delivery_id"], body]
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"native delivery unconfirmed (exit {result.returncode}); task {task} remains pending; retry identical input")


def send(home, board, args):
    message = Path(args.message_file).read_text(encoding="utf-8")
    if not message.strip():
        raise ValueError("empty ask")
    for name, value in (("key", args.key), ("owner", args.owner)):
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}" if name == "key" else r"[A-Za-z0-9_.-]{1,64}", value):
            raise ValueError("invalid " + name)
    if not args.title.strip() or not args.source.strip() or any(c in args.source for c in "\r\n"):
        raise ValueError("title and one-line source are required")
    identity = dict(home=str(home), key=args.key)
    signature = digest(dict(identity, owner=args.owner, title=args.title, source=args.source,
                            message=message, task=args.task, due=args.due))
    directory = home / "state/routed-asks"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    receipt_path = directory / (digest(identity) + ".json")
    with (directory / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
        if receipt and (receipt["signature"] != signature or receipt["board"] != str(board)):
            raise ValueError("request key already binds different input/board; use a new key")
        current = rows(board)
        candidates = [row for row in current.values() if route(row) and
                      route(row).get("origin") == str(home) and route(row).get("key") == args.key]
        if len(candidates) > 1:
            raise ValueError("duplicate canonical routed task; nothing sent")
        task = receipt.get("task") if receipt else None
        if candidates:
            task = candidates[0]["id"]
        task = task or args.task
        old = current.get(task) if task else None
        intent = route(old) if old else None
        same = intent and intent.get("origin") == str(home) and intent.get("key") == args.key
        if same and intent.get("signature") != signature:
            raise ValueError("canonical request key binds different input; nothing sent")
        if same and intent.get("state") == "delivered":
            return dict(task=task, state="delivered", replay=True)
        if task and old is None:
            raise ValueError("referenced canonical task is missing; nothing sent")
        if old and old.get("status") in {"closed", "tombstone"}:
            raise ValueError("canonical task is terminal; nothing sent or reopened")
        if old and old.get("assignee") != args.owner:
            metadata = old.get("metadata") or {}
            if metadata.get("eta") is not None or "captain" in (old.get("labels") or []):
                raise ValueError("record the existing commitment/captain ownership transfer before routing; nothing sent")
        if receipt and task and not same:
            raise ValueError("canonical route was superseded; nothing resent")
        if not same:
            now = datetime.now().astimezone()
            intent = dict(version=1, origin=str(home), key=args.key, signature=signature,
                          owner=args.owner, source=args.source, message=message,
                          eta_asked=now.strftime("%H:%M"), eta_asked_at=now.isoformat(),
                          delivery_id=signature[:16], state="pending")
        receipt = receipt or dict(version=1, key=args.key, signature=signature,
                                  board=str(board), task=task, delivered=False)
        atomic_json(receipt_path, receipt)
        metadata = dict(author="captain", source=args.source, eta_asked=intent["eta_asked"],
                        eta_asked_at=intent["eta_asked_at"], route_ask=intent)
        if old is None:
            flags = ["create", args.title, "--assignee", args.owner, "--labels", "routed-ask",
                     "--description", message, "--metadata", json.dumps(metadata), "--json"]
            if args.due:
                flags += ["--due", args.due]
            # Native commit acknowledgement may be lost. The next invocation
            # finds the committed key in board export instead of creating again.
            created = json.loads(board_command(board, *flags, readonly=False))
            task = created["id"]
        elif not same:
            board_command(board, "update", task, "--assignee", args.owner,
                          "--metadata", json.dumps(metadata), "--json", readonly=False)
        receipt["task"] = task
        atomic_json(receipt_path, receipt)
        if not receipt["delivered"]:
            deliver(home, intent, task)
            receipt["delivered"] = True
            atomic_json(receipt_path, receipt)
        completed = dict(intent, state="delivered")
        board_command(board, "update", task, "--metadata", json.dumps(dict(route_ask=completed)),
                      "--json", readonly=False)
        return dict(task=task, state="delivered", replay=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", default=os.environ.get("FM_HOME"))
    commands = parser.add_subparsers(dest="command", required=True)
    submit = commands.add_parser("send")
    for name in ("key", "owner", "title", "source", "message-file"):
        submit.add_argument("--" + name, required=True)
    submit.add_argument("--task")
    submit.add_argument("--due")
    commands.add_parser("list")
    commands.add_parser("check")
    args = parser.parse_args()
    try:
        if not args.home:
            raise ValueError("explicit FM_HOME or --home required")
        home = Path(args.home).resolve(strict=True)
        for variable, suffix in (("FM_STATE_OVERRIDE", "state"), ("FM_DATA_OVERRIDE", "data"),
                                 ("FM_CONFIG_OVERRIDE", "config"), ("FM_ROOT_OVERRIDE", "")):
            value = os.environ.get(variable)
            if value and Path(value).resolve() != home / suffix:
                raise ValueError("explicit home conflicts with " + variable)
        board = configured_board(home)
        if board is None:
            raise ValueError("config/beads-board is required")
        if args.command == "send":
            result = send(home, board, args)
        else:
            current = rows(board)
            result = projection(current) if args.command == "list" else integrity(home, current)
        print(json.dumps(result, sort_keys=True))
        return 1 if args.command == "check" and result else 0
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.TimeoutExpired) as error:
        print("route-ask: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
