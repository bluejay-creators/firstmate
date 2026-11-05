#!/usr/bin/env python3
"""Exact-action consent records; no server, command execution, or automatic enablement.

Usage: fm-approval-ledger.py --config FILE stage --descriptor FILE
       fm-approval-ledger.py --config FILE card --id CARD_ID
       fm-approval-ledger.py --config FILE phone --action HASH --evidence FILE
       fm-approval-ledger.py --config FILE import-legacy --action HASH --evidence FILE
       fm-approval-ledger.py --config FILE check --request FILE
       fm-approval-ledger.py --config FILE consume --request FILE
       fm-approval-ledger.py --config FILE revoke --action HASH --reason TEXT
       fm-approval-ledger.py --config FILE observe --request FILE --outcome OUTCOME
       fm-approval-ledger.py --config FILE trace --record FILE
       fm-approval-ledger.py --config FILE execution --receipt FILE

The descriptor is immutable. Its native request is captured by the real gate,
not reconstructed from a card title. Signed choice run-<descriptor SHA256> binds
the complete descriptor through the existing phone choice protocol. Only a
pinned P256 approval key is accepted. Legacy imports are explicitly different:
a configured trusted Main coordinator attests preserved human provenance, exact
scope, no later denial, and no completed execution. This is a same-UID trusted
coordinator boundary, not hostile same-UID isolation or a phone signature.

Config schema firstmate.approval-ledger-config.v1 requires absolute store and
phoneKeys paths, mode shadow|enforce, and optional legacyImporter. Nothing
creates this config or changes its mode. Stage/phone/import never execute the
action. Consume is atomic and only spends a grant in enforce mode. A spent or
uncertain action is never replayed. A trace carries an AuthZEN-shaped request,
decision, reasons, and actual Cedar policy ids. Native outcomes and observed
enclosing-tool returns/throws are separate records, never proof of an effect.
Shadow mode records would-release/would-deny without changing a native choice.
The descriptor's mode is signed scope: a shadow answer cannot become a live
grant just by changing the configured mode. Native owner closure and observed
tool results wait for the short ledger write lock; admission remains nonblocking.
The native client additionally requires a pinned nativeBridge helper and an
explicit OMP_APPROVAL_LEDGER_CONFIG path; no caller creates or activates it.
For that client, nativeBridge is {python: ABSOLUTE_INTERPRETER,
program: ABSOLUTE_LEDGER_SCRIPT, sha256: SCRIPT_SHA256}; the private config and
phoneKeys files must be owned by the user and mode 0600, with a mode-0700 store.
Descriptors bind native session/dialog/call, complete consent hash, cwd,
argument/environment hashes, optional repository HEAD, reviewed entrypoint
bytes, nondelegable subject/scope, explicit mode, nonce, deadline and one use.
The coordinator first captures the real pending owner with observe, then stages
the immutable descriptor. Card projects its complete review surface and choices;
opaque consent must never be parsed as a phone-options block or truncated by a
consumer. Phone preserves the original id/choice/options/options_hash/text/ts/sig.
This program is the crypto/state journal, not a command runner or a replacement
for the native Cedar enforcer and its existing hard denials. Same-UID callers
and the explicitly configured legacy importer are trusted; this is not an OS
credential boundary. A missing or indeterminate result never authorizes retry.
"""

import argparse
import base64
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

HEX = re.compile(r"[0-9a-f]{64}\Z")
MAX_JSON = 1_048_576
SCHEMA = "firstmate.approval-action.v1"
P256_SPKI = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")


class Error(Exception):
    pass


class Busy(Error):
    pass


def require(condition, message):
    if not condition:
        raise Error(message)


def canonical(value):
    # Descriptors carry strings, booleans, null, and safe integer timestamps;
    # raw arbitrary tool arguments are bound by their native SHA256, not re-encoded.
    def valid(item):
        if isinstance(item, dict):
            require(all(isinstance(key, str) for key in item), "non-string JSON key")
            for entry in item.values():
                valid(entry)
        elif isinstance(item, list):
            for entry in item:
                valid(entry)
        else:
            require(item is None or isinstance(item, (str, bool)) or
                    type(item) is int and abs(item) <= 9007199254740991,
                    "unsupported canonical JSON value")
    valid(value)
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def action_options(action_hash):
    return [{"id": "run-" + action_hash, "label": "Approve this exact action once"},
            {"id": "deny", "label": "Do not approve this action"}]


def native_identity(request):
    return digest([request["sessionId"], request["approvalId"]])


def text(value, field):
    require(isinstance(value, str) and value and "\0" not in value, f"invalid {field}")
    return value


def sha(value, field):
    require(isinstance(value, str) and HEX.fullmatch(value), f"invalid {field}")
    return value


def read_json(path, *, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_size <= MAX_JSON, "invalid JSON file")
        if private:
            require(info.st_uid == os.getuid() and info.st_mode & 0o077 == 0, "insecure consent file")
        raw = stream.read(MAX_JSON + 1)
    require(len(raw) <= MAX_JSON, "JSON file too large")
    return json.loads(raw)


def read_input(path):
    if path != "-":
        return read_json(path)
    raw = sys.stdin.buffer.read(MAX_JSON + 1)
    require(len(raw) <= MAX_JSON, "JSON input too large")
    return json.loads(raw)


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".consent-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical(value) + b"\n")
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


def native_request(value):
    require(isinstance(value, dict), "native request must be an object")
    required = {"schema", "sessionId", "approvalId", "kind", "toolName", "cwd",
                "argumentsSha256", "promptSha256", "environmentSha256"}
    optional = {"toolCallId", "command", "repository"}
    require(required <= value.keys() and not value.keys() - required - optional,
            "invalid native request fields")
    require(value["schema"] == "firstmate.native-approval-request.v1", "unsupported native request")
    require(value["kind"] in ("tool", "settings", "consent"), "invalid native kind")
    for key in ("sessionId", "approvalId", "toolName", "cwd"):
        text(value[key], key)
    require(Path(value["cwd"]).is_absolute(), "native cwd must be absolute")
    for key in ("argumentsSha256", "promptSha256", "environmentSha256"):
        sha(value[key], key)
    if "toolCallId" in value:
        text(value["toolCallId"], "toolCallId")
    if "command" in value:
        require(isinstance(value["command"], str), "invalid command snapshot")
    require(value["toolName"] != "bash" or "command" in value, "Bash requires its final command snapshot")
    repository = value.get("repository")
    if repository is not None:
        require(isinstance(repository, dict) and set(repository) == {"root", "head"}, "invalid repository")
        require(Path(text(repository["root"], "repository root")).is_absolute(), "absolute repository required")
        require(isinstance(repository["head"], str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", repository["head"]),
                "invalid repository head")
    canonical(value)
    return value


def descriptor(value):
    require(isinstance(value, dict) and set(value) == {
        "schema", "native", "subject", "delegation", "correlation", "purpose", "consent", "cardId",
        "nonce", "issuedAt", "expiresAt", "uses", "entrypoints", "tenant", "mode"}, "invalid action descriptor")
    require(value["schema"] == SCHEMA and type(value["uses"]) is int and value["uses"] == 1, "one-use action required")
    require(value["mode"] in ("shadow", "enforce"), "explicit signed action mode required")
    request = native_request(value["native"])
    require(value["subject"] == {"type": "NativeSession", "id": request["sessionId"]}, "subject mismatch")
    delegation = value["delegation"]
    require(isinstance(delegation, dict) and set(delegation) == {"from", "to", "request", "scope", "delegable"},
            "explicit exact delegation required")
    require(delegation["from"] == "captain" and delegation["to"] == request["sessionId"] and
            delegation["scope"] == digest(request) and delegation["delegable"] is False,
            "delegation expands or changes native scope")
    for key in ("correlation", "purpose", "consent", "cardId", "nonce", "tenant"):
        text(value[key], key)
    require(hashlib.sha256(value["consent"].encode("utf-8")).hexdigest() == request["promptSha256"],
            "consent does not match the immutable native prompt")
    text(delegation["request"], "original request")
    require(value["tenant"] == "work", "this ledger is Work-only")
    require(type(value["issuedAt"]) is int and type(value["expiresAt"]) is int and
            0 < value["expiresAt"] - value["issuedAt"] <= 86_400_000, "invalid action expiry")
    require(isinstance(value["entrypoints"], list) and value["entrypoints"], "guarded entrypoint binding required")
    for entry in value["entrypoints"]:
        require(isinstance(entry, dict) and set(entry) == {"path", "sha256"}, "invalid entrypoint")
        require(Path(text(entry["path"], "entrypoint path")).is_absolute(), "absolute entrypoint required")
        sha(entry["sha256"], "entrypoint digest")
    canonical(value)
    return value


def resources_match(action):
    request = action["native"]
    try:
        if str(Path(request["cwd"]).resolve(strict=True)) != request["cwd"]:
            return False
        for entry in action["entrypoints"]:
            fd = os.open(entry["path"], os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    return False
                checksum = hashlib.sha256()
                while chunk := stream.read(65536):
                    checksum.update(chunk)
                if checksum.hexdigest() != entry["sha256"]:
                    return False
        repository = request.get("repository")
        if repository:
            result = subprocess.run(["git", "-C", request["cwd"], "rev-parse", "--show-toplevel", "HEAD"],
                                    capture_output=True, text=True, timeout=5,
                                    env={key: os.environ[key] for key in ("HOME", "PATH", "LANG") if key in os.environ})
            if result.returncode or result.stdout.splitlines() != [repository["root"], repository["head"]]:
                return False
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def timestamp(value):
    require(type(value) in (str, int), "invalid phone timestamp")
    raw = str(value)
    if raw.isdigit():
        return int(raw)
    parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    require(parsed.utcoffset() is not None, "phone timestamp needs a timezone")
    return int(parsed.timestamp() * 1000)


def verify_phone(config, action_hash, action, evidence, *, fresh):
    require(isinstance(evidence, dict) and set(evidence) == {"id", "choice", "text", "options", "options_hash", "ts", "sig"},
            "original signed choice evidence required")
    text(evidence["id"], "card id")
    require(evidence["id"] == action["cardId"], "signature belongs to another approval card")
    require(evidence["choice"] in ("run-" + action_hash, "deny") and evidence["text"] == "",
            "choice does not answer this action")
    options = evidence["options"]
    require(options == action_options(action_hash), "original action choices changed")
    require(digest(options) == evidence["options_hash"], "options hash mismatch")
    signed_at = timestamp(evidence["ts"])
    require(action["issuedAt"] - 300_000 <= signed_at <= action["expiresAt"] + 300_000,
            "signature outside action lifetime and the phone protocol clock-skew window")
    require(not fresh or abs(int(time.time() * 1000) - signed_at) <= 300_000, "stale phone answer")
    pem = read_json(config["phoneKeys"], private=True).get("approval")
    require(isinstance(pem, str), "no pinned approval key")
    try:
        der = base64.b64decode("".join(line for line in pem.splitlines() if not line.startswith("---")), validate=True)
        require(len(der) == 91 and der.startswith(P256_SPKI), "pinned key must be named-curve P256 SPKI")
        signature = base64.b64decode(evidence["sig"], validate=True)
    except (ValueError, TypeError) as error:
        raise Error("invalid signature encoding") from error
    payload = f"{evidence['id']}|choice:{evidence['choice']}|{hashlib.sha256(b'').hexdigest()}|{evidence['options_hash']}|{evidence['ts']}"
    with tempfile.TemporaryDirectory(prefix=".verify-", dir=config["store"]) as temporary:
        directory = Path(temporary)
        (directory / "key.pem").write_text(pem)
        (directory / "signature").write_bytes(signature)
        result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(directory / "key.pem"),
                                 "-signature", str(directory / "signature")], input=payload.encode(),
                                capture_output=True, timeout=5)
    require(result.returncode == 0, "phone signature does not verify against the pinned key")


class Ledger:
    def __init__(self, config_path):
        self.config = read_json(config_path, private=True)
        require(isinstance(self.config, dict) and self.config.get("schema") == "firstmate.approval-ledger-config.v1",
                "unsupported ledger configuration")
        require(self.config.get("mode") in ("shadow", "enforce"), "explicit ledger mode required")
        for field in ("store", "phoneKeys"):
            require(Path(text(self.config.get(field), field)).is_absolute(), f"absolute {field} required")
        self.root = Path(self.config["store"])
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.root.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0,
                "insecure consent directory")

    @contextlib.contextmanager
    def locked(self, *, wait=False):
        fd = os.open(self.root / "ledger.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0,
                    "insecure ledger lock")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
            except BlockingIOError as error:
                raise Busy("ledger busy") from error
            yield
        finally:
            os.close(fd)

    def load(self, action_hash):
        sha(action_hash, "action hash")
        record = read_json(self.root / (action_hash + ".json"), private=True)
        require(digest(descriptor(record["descriptor"])) == action_hash, "immutable action changed")
        return record

    def save(self, action_hash, record, event):
        record["audit"].append({"event": event, "at": int(time.time() * 1000)})
        atomic_json(self.root / (action_hash + ".json"), record)

    def native_state(self, request):
        try:
            state = read_json(self.root / ("native-" + native_identity(request) + ".json"), private=True)
        except FileNotFoundError:
            return None
        require(state["native"] == request, "native lifecycle identity changed")
        return state

    def native_phase(self, request):
        state = self.native_state(request)
        return state["phase"] if state is not None else None

    def observe(self, request, outcome):
        request = native_request(request)
        require(outcome in ("pending", "approved", "denied", "cancelled", "timeout", "unavailable"),
                "invalid native lifecycle outcome")
        with self.locked(wait=True):
            state = self.native_state(request)
            previous = state["phase"] if state is not None else None
            if outcome == "pending" and previous is not None:
                return {"native": native_identity(request), "phase": previous}
            action_hash = None
            record = None
            if outcome != "pending":
                try:
                    action_hash = read_json(self.root / ("request-" + digest(request) + ".json"), private=True)["action"]
                    record = self.load(action_hash)
                except FileNotFoundError:
                    pass
            requested_outcome = outcome
            if (outcome == "approved" and self.config["mode"] == "enforce" and
                    record is not None and record["descriptor"]["mode"] == "enforce" and record["phase"] == "denied"):
                # A verified phone denial committed before native admission wins
                # over a racing local Yes. This never turns an approval into execution.
                outcome = "denied"
            require(previous in (None, "pending", outcome), "native resolution conflicts with its original owner")
            if previous != outcome:
                now = int(time.time() * 1000)
                state = state or {"native": request, "observations": [], "evaluations": []}
                state.update(phase=outcome, at=now)
                state["observations"].append({"outcome": outcome, "requestedOutcome": requested_outcome, "at": now})
                # Close the owner first: an interrupted grant revocation cannot
                # leave a closed dialog eligible to consume a later answer.
                atomic_json(self.root / ("native-" + native_identity(request) + ".json"), state)
            if record is not None and record["phase"] in ("requested", "approved"):
                record.update(phase="revoked", revocationReason="native-owner-" + outcome)
                self.save(action_hash, record, "native-owner-" + outcome)
        return {"native": native_identity(request), "phase": outcome}

    def trace(self, request, evaluation):
        request = native_request(request)
        require(isinstance(evaluation, dict) and set(evaluation) ==
                {"schema", "mode", "request", "decision", "reasons", "policy_ids"}, "AuthZEN-shaped evaluation required")
        require(evaluation["schema"] == "firstmate.approval-evaluation.v1" and
                evaluation["mode"] in ("shadow", "enforce") and evaluation["decision"] in ("allow", "deny"),
                "invalid evaluation identity or decision")
        query = evaluation["request"]
        require(isinstance(query, dict) and set(query) == {"subject", "action", "resource", "context"},
                "evaluation query is incomplete")
        require(query["subject"] == {"type": "NativeSession", "id": request["sessionId"]} and
                query["action"] == {"name": "release-native-prompt", "tool": request["toolName"]} and
                query["resource"] == {"type": "NativePermission", "id": digest(request)} and
                isinstance(query["context"], dict) and query["context"].get("nativeRequestHash") == digest(request),
                "evaluation belongs to another native owner or action")
        for field in ("reasons", "policy_ids"):
            require(isinstance(evaluation[field], list) and all(isinstance(value, str) for value in evaluation[field]),
                    "evaluation reasons and policy ids must be arrays of strings")
        canonical(evaluation)
        with self.locked():
            state = self.native_state(request)
            require(state is not None, "evaluation has no registered native owner")
            state["evaluations"].append(evaluation)
            atomic_json(self.root / ("native-" + native_identity(request) + ".json"), state)
        return {"native": native_identity(request), "recorded": True}

    def stage(self, action):
        action = descriptor(action)
        now = int(time.time() * 1000)
        require(action["issuedAt"] <= now < action["expiresAt"], "action is not current")
        require(resources_match(action), "guarded resource changed")
        require(action["mode"] == self.config["mode"], "action mode changed")
        action_hash = digest(action)
        indexes = [
            self.root / ("request-" + digest(action["native"]) + ".json"),
            self.root / ("nonce-" + digest(action["nonce"]) + ".json"),
            self.root / ("card-" + digest(action["cardId"]) + ".json"),
        ]
        with self.locked():
            require(self.native_phase(action["native"]) == "pending", "the native request is no longer pending")
            for index in indexes:
                if index.exists():
                    require(read_json(index, private=True) == {"action": action_hash},
                            "request, nonce, or card already bound to another action")
            if (self.root / (action_hash + ".json")).exists():
                record = self.load(action_hash)
            else:
                record = {"descriptor": action, "phase": "requested", "audit": []}
                self.save(action_hash, record, "requested")
            # Complete an interrupted stage without resetting approval or spent state.
            for index in indexes:
                if not index.exists():
                    atomic_json(index, {"action": action_hash})
        return {"action": action_hash, "choice": "run-" + action_hash, "options": action_options(action_hash),
                "expiresAt": action["expiresAt"], "uses": 1, "phase": record["phase"]}

    def answer(self, action_hash, evidence, legacy=False):
        with self.locked():
            record = self.load(action_hash)
            # A lost response may retry the original evidence after admission or
            # closure. Returning its receipt never reopens or extends the grant.
            evidence_field = "evidence" if legacy or not isinstance(evidence, dict) or evidence.get("choice") != "deny" else "denialEvidence"
            original = record.get(evidence_field)
            same_phone_choice = (not legacy and isinstance(original, dict) and isinstance(evidence, dict) and
                                 all(original.get(key) == evidence.get(key) for key in
                                     ("id", "choice", "text", "options", "options_hash")))
            if original == evidence and evidence_field in record or same_phone_choice:
                if original != evidence:
                    verify_phone(self.config, action_hash, record["descriptor"], evidence, fresh=True)
                return {"action": action_hash, "phase": record["phase"], "decisionRecorded": True,
                        "evidenceKind": "coordinator-attested-legacy" if legacy else "phone-signed",
                        "effectVerified": False}
            require(record["descriptor"]["mode"] == self.config["mode"], "action mode changed")
            require(self.native_phase(record["descriptor"]["native"]) == "pending",
                    "the native request is no longer pending")
            denied = not legacy and isinstance(evidence, dict) and evidence.get("choice") == "deny"
            require(record["phase"] in (("requested", "approved", "denied") if denied else ("requested", "approved")),
                    "action is terminal")
            require(int(time.time() * 1000) < record["descriptor"]["expiresAt"], "action expired")
            if legacy:
                importer = self.config.get("legacyImporter")
                require(isinstance(importer, str) and importer and isinstance(evidence, dict),
                        "legacy import is not delegated")
                require(set(evidence) == {"kind", "importer", "humanDecision", "originalCorrelation", "sourceSha256",
                                          "originalActionId", "originalExecutionState", "action",
                                          "noLaterDenial", "noExecutionReceipt"}, "invalid legacy provenance")
                require(evidence["kind"] == "coordinator-attested-legacy" and evidence["importer"] == importer,
                        "wrong legacy importer")
                require(evidence["action"] == action_hash and
                        evidence["originalCorrelation"] == record["descriptor"]["correlation"] and
                        evidence["noLaterDenial"] is True and evidence["noExecutionReceipt"] is True and
                        evidence["originalExecutionState"] == "not-executed", "legacy scope is not eligible")
                text(evidence["humanDecision"], "preserved human decision")
                sha(evidence["sourceSha256"], "preserved decision source digest")
                text(evidence["originalActionId"], "stable original action identity")
            else:
                repeated = record["phase"] == ("denied" if denied else "approved")
                verify_phone(self.config, action_hash, record["descriptor"], evidence, fresh=not repeated)
            if denied:
                if record["phase"] == "denied":
                    require(record["denialEvidence"] == evidence, "conflicting denial")
                else:
                    record.update(phase="denied", denialEvidence=evidence)
                    self.save(action_hash, record, "denied")
                return {"action": action_hash, "phase": "denied", "evidenceKind": "phone-signed",
                        "executionObserved": False}
            kind = "coordinator-attested-legacy" if legacy else "phone-signed"
            if record["phase"] == "approved":
                require(record["evidence"] == evidence and record["evidenceKind"] == kind, "conflicting approval")
            if legacy:
                source_key = digest([evidence["sourceSha256"], evidence["originalCorrelation"], evidence["originalActionId"]])
                source_index = self.root / ("legacy-" + source_key + ".json")
                if source_index.exists():
                    require(read_json(source_index, private=True) == {"action": action_hash},
                            "original human action already imported")
                else:
                    # Reserve provenance before admitting the grant; an interrupted
                    # import may retry only this same immutable action.
                    atomic_json(source_index, {"action": action_hash})
            if record["phase"] == "requested":
                record.update(phase="approved", evidence=evidence, evidenceKind=kind)
                self.save(action_hash, record, "approved")
        return {"action": action_hash, "phase": "approved", "evidenceKind": kind, "executionObserved": False}

    def card(self, card_id):
        text(card_id, "card id")
        with self.locked():
            try:
                action_hash = read_json(self.root / ("card-" + digest(card_id) + ".json"), private=True)["action"]
            except FileNotFoundError:
                return {"id": card_id, "available": False}
            record = self.load(action_hash)
            action = record["descriptor"]
            require(action["cardId"] == card_id, "approval card identity changed")
            pending = self.native_phase(action["native"]) == "pending"
            current = (action["mode"] == self.config["mode"] and
                       int(time.time() * 1000) < action["expiresAt"] and resources_match(action))
            offered = pending and current and record["phase"] in ("requested", "approved", "denied")
            options = action_options(action_hash)
            native = action["native"]
            mode = action["mode"]
            lines = [
                "SHADOW ONLY: the phone choice records a comparison, not native admission." if mode == "shadow"
                else "Phone approves only this original native action, once.",
                action["consent"], "", f"Recorded decision state: {record['phase']}",
                "This answers the original native permission request; it never grants a whole session.",
                f"Actor: {native['sessionId']}", f"Native request: {native['approvalId']}",
                f"Working directory: {native['cwd']}",
                f"Native request SHA256: {digest(native)}",
                f"Action SHA256: {action_hash}",
                f"Consent SHA256: {native['promptSha256']}",
                f"Expires: {datetime.fromtimestamp(action['expiresAt'] / 1000, timezone.utc).isoformat()}",
            ]
            if native.get("repository"):
                lines.append(f"Repository: {native['repository']['root']} @ {native['repository']['head']}")
            lines.extend(f"Reviewed entrypoint: {entry['path']} @ {entry['sha256']}" for entry in action["entrypoints"])
            lines.append("SHADOW ONLY: the phone choice records a comparison, not native admission." if mode == "shadow"
                         else "One use. A mismatched, expired, revoked, closed, or unverifiable request is not admitted.")
            lines.append("Permission is not proof that the operation ran or succeeded.")
            return {"schema": "firstmate.approval-card.v1", "id": card_id, "available": True,
                    "action": action_hash, "phase": record["phase"], "mode": mode, "actionable": offered,
                    "nativePending": pending, "resourceCurrent": current, "expiresAt": action["expiresAt"],
                    "native": {"sessionId": native["sessionId"], "approvalId": native["approvalId"],
                               "promptSha256": native["promptSha256"]},
                    "title": ("Shadow proof: " if mode == "shadow" else "Authorize once: ") + action["purpose"],
                    "detail": "\n".join(lines),
                    "options": options, "options_hash": digest(options), "allow_other": False,
                    "effectVerified": False}

    def decision(self, request, consume=False):
        request = native_request(request)
        with self.locked():
            if self.native_phase(request) != "pending":
                return {"decision": "prompt", "reason": "native-owner-not-pending"}
            try:
                action_hash = read_json(self.root / ("request-" + digest(request) + ".json"), private=True)["action"]
            except FileNotFoundError:
                return {"decision": "prompt", "reason": "no-exact-grant"}
            record = self.load(action_hash)
            action = record["descriptor"]
            require(action["native"] == request, "native request changed")
            if action["mode"] != self.config["mode"]:
                return {"decision": "prompt", "reason": "action-mode-changed", "action": action_hash}
            if record["phase"] == "denied":
                verify_phone(self.config, action_hash, action, record["denialEvidence"], fresh=False)
                return {"decision": "deny" if self.config["mode"] == "enforce" else "would-deny",
                        "action": action_hash, "evidenceKind": "phone-signed",
                        "executionObserved": False}
            if record["phase"] != "approved":
                return {"decision": "prompt", "reason": record["phase"], "action": action_hash}
            if int(time.time() * 1000) >= action["expiresAt"]:
                record["phase"] = "expired"
                self.save(action_hash, record, "expired")
                return {"decision": "prompt", "reason": "expired", "action": action_hash}
            if not resources_match(action):
                return {"decision": "prompt", "reason": "guarded-resource-changed", "action": action_hash}
            require(record.get("evidenceKind") in ("phone-signed", "coordinator-attested-legacy"),
                    "unknown grant evidence")
            if record["evidenceKind"] == "phone-signed":
                verify_phone(self.config, action_hash, action, record["evidence"], fresh=False)
            else:
                require(self.config.get("legacyImporter") == record["evidence"]["importer"], "legacy delegation revoked")
            released = consume and self.config["mode"] == "enforce"
            if released:
                record["phase"] = "consumed"
                self.save(action_hash, record, "consumed")
            elif not record.get("shadowObserved"):
                record["shadowObserved"] = True
                self.save(action_hash, record, "would-release")
            return {"decision": "allow-once" if released else "would-release", "action": action_hash,
                    "evidenceKind": record["evidenceKind"], "executionObserved": False,
                    "grant": {"subject": action["subject"], "scope": action["delegation"]["scope"],
                              "delegable": action["delegation"]["delegable"], "tenant": action["tenant"],
                              "expiresAt": action["expiresAt"], "uses": action["uses"], "mode": action["mode"]}}

    def revoke(self, action_hash, reason):
        text(reason, "revocation reason")
        with self.locked():
            record = self.load(action_hash)
            if record["phase"] in ("requested", "approved"):
                record.update(phase="revoked", revocationReason=reason)
                self.save(action_hash, record, "revoked")
        return {"action": action_hash, "phase": record["phase"]}

    def execution(self, receipt):
        require(isinstance(receipt, dict) and set(receipt) == {"native", "outcome", "source"}, "observed tool result required")
        require(receipt["outcome"] in ("returned", "threw", "unknown"), "invalid observed tool outcome")
        text(receipt["source"], "tool result source")
        request = native_request(receipt["native"])
        with self.locked(wait=True):
            state = self.native_state(request)
            require(state is not None and state["phase"] == "approved", "tool result has no admitted native owner")
            if "toolResult" in state:
                require(state["toolResult"] == receipt, "conflicting observed tool result")
            else:
                state["toolResult"] = receipt
                atomic_json(self.root / ("native-" + native_identity(request) + ".json"), state)
            try:
                action_hash = read_json(self.root / ("request-" + digest(request) + ".json"), private=True)["action"]
            except FileNotFoundError:
                action_hash = None
            if action_hash is not None:
                record = self.load(action_hash)
                if record["phase"] == "consumed":
                    if "toolResult" in record:
                        require(record["toolResult"] == receipt, "conflicting admitted tool result")
                    else:
                        record["toolResult"] = receipt
                        self.save(action_hash, record, "tool-result-observed")
        return {"native": native_identity(request), "resultObserved": True, "outcome": receipt["outcome"],
                "effectVerified": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", required=True)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("stage").add_argument("--descriptor", required=True)
    commands.add_parser("card").add_argument("--id", required=True)
    for name in ("phone", "import-legacy"):
        command = commands.add_parser(name)
        command.add_argument("--action", required=True)
        command.add_argument("--evidence", required=True)
    for name in ("check", "consume"):
        commands.add_parser(name).add_argument("--request", required=True)
    command = commands.add_parser("observe")
    command.add_argument("--request", required=True, help="native request JSON file, or - for stdin")
    command.add_argument("--outcome", required=True,
                         choices=("pending", "approved", "denied", "cancelled", "timeout", "unavailable"))
    command = commands.add_parser("trace")
    command.add_argument("--record", required=True, help="JSON object containing native and evaluation")
    command = commands.add_parser("revoke")
    command.add_argument("--action", required=True)
    command.add_argument("--reason", required=True)
    command = commands.add_parser("execution")
    command.add_argument("--receipt", required=True)
    args = parser.parse_args(argv)
    try:
        ledger = Ledger(args.config)
        if args.operation == "stage":
            result = ledger.stage(read_input(args.descriptor))
        elif args.operation == "card":
            result = ledger.card(args.id)
        elif args.operation in ("phone", "import-legacy"):
            result = ledger.answer(args.action, read_input(args.evidence), args.operation == "import-legacy")
        elif args.operation in ("check", "consume"):
            result = ledger.decision(read_input(args.request), args.operation == "consume")
        elif args.operation == "observe":
            result = ledger.observe(read_input(args.request), args.outcome)
        elif args.operation == "trace":
            record = read_input(args.record)
            require(isinstance(record, dict) and set(record) == {"native", "evaluation"}, "native evaluation record required")
            result = ledger.trace(record["native"], record["evaluation"])
        elif args.operation == "revoke":
            result = ledger.revoke(args.action, args.reason)
        else:
            result = ledger.execution(read_input(args.receipt))
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except Busy:
        print(json.dumps({"decision": "prompt", "reason": "ledger-busy"}))
        return 75
    except (Error, OSError, ValueError, KeyError, TypeError, UnicodeError, subprocess.SubprocessError) as error:
        print(f"approval ledger: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
