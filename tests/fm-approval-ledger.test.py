#!/usr/bin/env python3
"""Exercise real CLI grants, signatures, resource changes, restart, and races."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid
import base64

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/fm-approval-ledger.py"


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


class LedgerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fm-ledger-test-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.entrypoint = self.home / "guarded.sh"
        self.entrypoint.write_text("#!/bin/sh\nprintf 'guarded action'\n")
        self.config = self.home / "config.json"
        self.keys = self.home / "phone-keys.json"
        self.private_key = self.home / "fixture-only-key.pem"
        self.openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                     "-pkeyopt", "ec_param_enc:named_curve", "-out", str(self.private_key))
        public = self.openssl("pkey", "-in", str(self.private_key), "-pubout").stdout.decode()
        self.save(self.keys, {"approval": public})
        self.settings = {"schema": "firstmate.approval-ledger-config.v1", "store": str(self.home / "store"),
                         "phoneKeys": str(self.keys), "mode": "enforce", "legacyImporter": "Main"}
        self.save(self.config, self.settings)
        self.prompt = "Run only the reviewed guarded operation, once."
        self.request = {"schema": "firstmate.native-approval-request.v1", "sessionId": "actual-session",
                        "approvalId": "actual-dialog", "kind": "tool", "toolName": "bash", "toolCallId": "actual-call",
                        "cwd": str(self.home), "command": "bash guarded.sh", "argumentsSha256": "1" * 64,
                        "promptSha256": hashlib.sha256(self.prompt.encode()).hexdigest(), "environmentSha256": "3" * 64}
        now = int(time.time() * 1000)
        self.action = {"schema": "firstmate.approval-action.v1", "native": self.request, "mode": "enforce",
                       "subject": {"type": "NativeSession", "id": self.request["sessionId"]},
                       "delegation": {"from": "captain", "to": self.request["sessionId"], "request": "original-request",
                                      "scope": digest(self.request), "delegable": False},
                       "correlation": "original-correlation", "purpose": "Run the reviewed guarded operation",
                       "consent": self.prompt, "cardId": "test-action-card", "nonce": uuid.uuid4().hex,
                       "issuedAt": now, "expiresAt": (now // 1000 + 3600) * 1000, "uses": 1,
                       "entrypoints": [{"path": str(self.entrypoint),
                                        "sha256": hashlib.sha256(self.entrypoint.read_bytes()).hexdigest()}], "tenant": "work"}

    def openssl(self, *arguments, input=None):
        return subprocess.run(["openssl", *arguments], input=input, capture_output=True, check=True)

    def save(self, path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return path

    def command(self, operation, *, action=None, data=None, outcome="pending"):
        arguments = [sys.executable, str(CLI), "--config", str(self.config), operation]
        if operation == "stage":
            arguments += ["--descriptor", str(self.save(self.home / "descriptor.json", self.action if data is None else data))]
        elif operation in ("check", "consume", "observe"):
            arguments += ["--request", str(self.save(self.home / "request.json", self.request if data is None else data))]
            if operation == "observe":
                arguments += ["--outcome", outcome]
        elif operation in ("phone", "import-legacy"):
            arguments += ["--action", action, "--evidence", str(self.save(self.home / "evidence.json", data))]
        elif operation == "revoke":
            arguments += ["--action", action, "--reason", "fixture-revocation"]
        elif operation == "execution":
            arguments += ["--receipt", str(self.save(self.home / "receipt.json", data))]
        return arguments

    def call(self, operation, *, action=None, data=None, code=0, outcome="pending"):
        result = subprocess.run(self.command(operation, action=action, data=data, outcome=outcome), capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stderr)
        return json.loads(result.stdout) if result.stdout else None

    def stage(self):
        self.call("observe")
        self.staged = self.call("stage")
        return self.staged["action"]

    def signed_evidence(self, *, choice=None, options=None, card_id=None):
        options = options or self.staged["options"]
        evidence = {"id": self.action["cardId"] if card_id is None else card_id,
                    "choice": choice or self.staged["choice"], "text": "",
                    "options": options, "options_hash": digest(options), "ts": str(int(time.time() * 1000))}
        message = (f"{evidence['id']}|choice:{evidence['choice']}|{hashlib.sha256(b'').hexdigest()}|"
                   f"{evidence['options_hash']}|{evidence['ts']}").encode()
        evidence["sig"] = base64.b64encode(self.openssl("dgst", "-sha256", "-sign", str(self.private_key), input=message).stdout).decode()
        return evidence

    def approve(self):
        action_hash = self.stage()
        self.call("phone", action=action_hash, data=self.signed_evidence())
        return action_hash

    def legacy_evidence(self, action_hash):
        return {"kind": "coordinator-attested-legacy", "importer": "Main",
                "humanDecision": "Preserved exact approval", "originalCorrelation": self.action["correlation"],
                "sourceSha256": "6" * 64, "originalActionId": "preserved-operation",
                "originalExecutionState": "not-executed", "action": action_hash,
                "noLaterDenial": True, "noExecutionReceipt": True}

    def enforce(self):
        self.settings["mode"] = "enforce"
        self.save(self.config, self.settings)

    def test_restarted_consumers_get_only_one_use(self):
        action_hash = self.approve()
        admission = self.call("consume")
        self.assertEqual(admission["decision"], "allow-once")
        self.assertFalse(admission["executionObserved"])
        self.assertEqual(self.call("consume")["reason"], "consumed")
        self.assertEqual(self.call("stage")["phase"], "consumed")
        self.assertEqual(self.staged["action"], action_hash)

    def test_shadow_consent_cannot_be_promoted_to_live_authority_by_a_mode_flip(self):
        self.settings["mode"] = self.action["mode"] = "shadow"
        self.save(self.config, self.settings)
        self.approve()
        self.assertEqual(self.call("consume")["decision"], "would-release")
        self.assertEqual(self.call("stage")["phase"], "approved")
        self.enforce()
        self.assertEqual(self.call("consume")["reason"], "action-mode-changed")

    def test_card_identity_cannot_be_rebound_to_a_different_native_request(self):
        self.stage()
        self.request["approvalId"] = "different-native-owner"
        self.action["nonce"] = uuid.uuid4().hex
        self.action["delegation"]["scope"] = digest(self.request)
        self.call("observe")
        self.call("stage", code=1)
        self.assertEqual(self.call("consume")["reason"], "no-exact-grant")

    def test_original_signed_answer_replays_after_admission_without_another_use(self):
        action_hash = self.stage()
        evidence = self.signed_evidence()
        self.call("phone", action=action_hash, data=evidence)
        self.assertEqual(self.call("consume")["decision"], "allow-once")
        self.call("observe", outcome="approved")
        self.assertEqual(self.call("phone", action=action_hash, data=evidence)["phase"], "consumed")
        self.assertEqual(self.call("consume")["reason"], "native-owner-not-pending")

    def test_two_processes_cannot_consume_the_same_permission(self):
        self.approve()
        self.enforce()
        command = self.command("consume")
        first = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        second = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        results = []
        for process in (first, second):
            stdout, stderr = process.communicate(timeout=10)
            self.assertIn(process.returncode, (0, 75), stderr)
            results.append(json.loads(stdout)["decision"])
        self.assertEqual(results.count("allow-once"), 1)
        self.assertEqual(results.count("prompt"), 1)

    def test_wrong_choice_and_relabelled_choices_are_not_authorization(self):
        action_hash = self.stage()
        self.call("phone", action=action_hash, data=self.signed_evidence(choice="unoffered-choice"), code=1)
        changed = copy.deepcopy(self.staged["options"])
        changed[0]["label"] = "Do not execute"
        self.call("phone", action=action_hash, data=self.signed_evidence(options=changed), code=1)
        self.enforce()
        self.assertEqual(self.call("consume")["reason"], "requested")

    def test_pinned_key_rotation_revokes_unspent_phone_grant(self):
        self.approve()
        other = self.home / "different-fixture-key.pem"
        self.openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                     "-pkeyopt", "ec_param_enc:named_curve", "-out", str(other))
        self.save(self.keys, {"approval": self.openssl("pkey", "-in", str(other), "-pubout").stdout.decode()})
        self.enforce()
        self.call("consume", code=1)

    def test_changed_native_subject_arguments_environment_and_pane_do_not_match(self):
        self.approve()
        self.enforce()
        for field, value in (("sessionId", "another-session"), ("approvalId", "another-dialog"),
                             ("toolCallId", "another-call"), ("argumentsSha256", "4" * 64),
                             ("environmentSha256", "5" * 64), ("command", "bash changed.sh")):
            with self.subTest(field=field):
                changed = {**self.request, field: value}
                if field in ("sessionId", "approvalId"):
                    self.call("observe", data=changed)
                    self.assertEqual(self.call("consume", data=changed)["decision"], "prompt")
                else:
                    self.call("consume", data=changed, code=1)
        self.assertEqual(self.call("consume")["decision"], "allow-once")

    def test_entrypoint_substitution_and_later_denial_prevent_release(self):
        action_hash = self.approve()
        self.enforce()
        original = self.entrypoint.read_text()
        self.entrypoint.write_text(original + "printf 'unreviewed change'\n")
        self.assertEqual(self.call("consume")["reason"], "guarded-resource-changed")
        self.entrypoint.write_text(original)
        result = subprocess.run([sys.executable, str(CLI), "--config", str(self.config), "revoke",
                                 "--action", action_hash, "--reason", "actual native denial"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.call("consume")["reason"], "revoked")

    def test_expiry_is_rechecked_at_use_not_only_when_the_phone_answers(self):
        self.approve()
        self.enforce()
        request_file = self.save(self.home / "request.json", self.request)
        spec = importlib.util.spec_from_file_location("expiry_ledger", CLI)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        output = io.StringIO()
        with patch.object(module.time, "time", return_value=self.action["expiresAt"] // 1000), contextlib.redirect_stdout(output):
            result = module.main(["--config", str(self.config), "consume", "--request", str(request_file)])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue())["reason"], "expired")

    def test_interrupted_index_write_recovers_without_resetting_approval(self):
        action_hash = self.approve()
        request_index = self.home / "store" / ("request-" + digest(self.request) + ".json")
        request_index.unlink()
        self.assertEqual(self.call("stage")["phase"], "approved")
        self.enforce()
        self.assertEqual(self.call("consume")["decision"], "allow-once")
        request_index.unlink()
        self.assertEqual(self.call("stage")["phase"], "consumed")
        self.assertEqual(self.call("consume")["reason"], "consumed")
        self.assertTrue((self.home / "store" / (action_hash + ".json")).exists())

    def test_nonce_cannot_be_rebound_to_a_different_native_request(self):
        self.stage()
        changed = copy.deepcopy(self.action)
        changed["native"]["approvalId"] = "another-dialog"
        changed["delegation"]["scope"] = digest(changed["native"])
        self.call("observe", data=changed["native"])
        self.call("stage", data=changed, code=1)

    def test_legacy_import_requires_the_bounded_trust_path_and_provenance(self):
        action_hash = self.stage()
        evidence = self.legacy_evidence(action_hash)
        self.settings.pop("legacyImporter")
        self.save(self.config, self.settings)
        self.call("import-legacy", action=action_hash, data=evidence, code=1)
        self.settings["legacyImporter"] = "Main"
        self.save(self.config, self.settings)
        self.call("import-legacy", action=action_hash, data={**evidence, "noExecutionReceipt": False}, code=1)
        self.call("import-legacy", action=action_hash, data=evidence)
        self.enforce()
        result = self.call("consume")
        self.assertEqual(result["decision"], "allow-once")
        self.assertEqual(result["evidenceKind"], "coordinator-attested-legacy")
        self.assertFalse(result["executionObserved"])

    def test_a_real_repository_head_disappearing_prevents_release(self):
        repository = self.home / "repo"
        subprocess.run(["git", "clone", "--shared", "--no-checkout", str(ROOT), str(repository)],
                       capture_output=True, check=True)
        head = subprocess.run(["git", "-C", str(repository), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
        self.request["repository"] = {"root": str(repository), "head": head}
        self.request["cwd"] = str(repository)
        self.request["command"] = "bash " + str(self.entrypoint)
        self.action["delegation"]["scope"] = digest(self.request)
        self.approve()
        self.enforce()
        subprocess.run(["git", "-C", str(repository), "symbolic-ref", "HEAD", "refs/heads/not-created"],
                       capture_output=True, check=True)
        self.assertEqual(self.call("consume")["reason"], "guarded-resource-changed")

    def test_signed_phone_denial_closes_authority_without_a_native_yes(self):
        self.enforce()
        action_hash = self.stage()
        denied = self.call("phone", action=action_hash, data=self.signed_evidence(choice="deny"))
        self.assertEqual(denied["phase"], "denied")
        self.assertEqual(self.call("check")["decision"], "deny")
        self.call("phone", action=action_hash, data=self.signed_evidence(), code=1)
        self.enforce()
        self.assertEqual(self.call("consume")["decision"], "deny")

    def test_genuine_signature_for_another_card_is_not_this_cards_answer(self):
        action_hash = self.stage()
        self.call("phone", action=action_hash, data=self.signed_evidence(card_id="different-card"), code=1)
        self.enforce()
        self.assertEqual(self.call("consume")["reason"], "requested")

    def test_native_denial_before_staging_cannot_be_reopened_by_a_late_request(self):
        self.call("observe")
        self.call("observe", outcome="denied")
        self.assertEqual(self.call("observe")["phase"], "denied")
        self.call("stage", code=1)
        self.enforce()
        self.assertEqual(self.call("consume")["reason"], "native-owner-not-pending")

    def test_native_cancellation_revokes_an_unused_phone_approval(self):
        action_hash = self.approve()
        self.call("observe", outcome="cancelled")
        self.assertEqual(self.call("phone", action=action_hash, data=self.signed_evidence())["phase"], "revoked")
        self.enforce()
        self.assertEqual(self.call("consume")["reason"], "native-owner-not-pending")

    def test_same_preserved_legacy_action_cannot_be_imported_for_a_second_attempt(self):
        first = self.stage()
        evidence = self.legacy_evidence(first)
        self.call("import-legacy", action=first, data=evidence)
        self.enforce()
        self.assertEqual(self.call("consume")["decision"], "allow-once")
        self.request["approvalId"] = "second-attempt"
        self.action["nonce"] = uuid.uuid4().hex
        self.action["cardId"] = "second-action-card"
        self.action["delegation"]["scope"] = digest(self.request)
        second = self.stage()
        self.call("import-legacy", action=second, data={**evidence, "action": second}, code=1)
        self.assertEqual(self.call("consume")["reason"], "requested")

    def test_missing_receipt_is_not_proof_that_the_original_action_never_ran(self):
        action_hash = self.stage()
        evidence = {**self.legacy_evidence(action_hash), "originalExecutionState": "unknown"}
        self.call("import-legacy", action=action_hash, data=evidence, code=1)
        self.enforce()
        self.assertEqual(self.call("consume")["reason"], "requested")

    def test_changed_consent_or_expanding_delegation_cannot_stage(self):
        self.call("observe")
        changed = copy.deepcopy(self.action)
        changed["consent"] = "An unrelated question"
        self.call("stage", data=changed, code=1)
        for key, value in (("to", "another-session"), ("delegable", True)):
            changed = copy.deepcopy(self.action)
            changed["delegation"][key] = value
            self.call("stage", data=changed, code=1)
        self.enforce()
        self.assertEqual(self.call("consume")["reason"], "no-exact-grant")

    def test_shadow_phone_denial_does_not_change_a_real_native_choice(self):
        self.settings["mode"] = self.action["mode"] = "shadow"
        self.save(self.config, self.settings)
        action_hash = self.stage()
        self.call("phone", action=action_hash, data=self.signed_evidence(choice="deny"))
        self.assertEqual(self.call("check")["decision"], "would-deny")
        self.assertEqual(self.call("observe", outcome="approved")["phase"], "approved")
        self.assertEqual(self.call("consume")["reason"], "native-owner-not-pending")

    def test_committed_phone_denial_wins_a_racing_native_yes(self):
        self.enforce()
        action_hash = self.stage()
        self.call("phone", action=action_hash, data=self.signed_evidence(choice="deny"))
        self.assertEqual(self.call("observe", outcome="approved")["phase"], "denied")
        self.assertEqual(self.call("consume")["reason"], "native-owner-not-pending")

    def test_revocation_cannot_erase_an_existing_human_denial(self):
        self.enforce()
        action_hash = self.stage()
        self.call("phone", action=action_hash, data=self.signed_evidence(choice="deny"))
        self.assertEqual(self.call("revoke", action=action_hash)["phase"], "denied")
        self.assertEqual(self.call("consume")["decision"], "deny")

    def test_a_tool_receipt_cannot_create_permission_or_reopen_a_spent_action(self):
        action_hash = self.approve()
        receipt = {"native": self.request, "outcome": "returned", "source": "native-tool-wrapper"}
        self.call("execution", data=receipt, code=1)
        self.enforce()
        self.assertEqual(self.call("consume")["decision"], "allow-once")
        self.call("observe", outcome="approved")
        observed = self.call("execution", data=receipt)
        self.assertFalse(observed["effectVerified"])
        self.call("execution", data={**receipt, "outcome": "threw"}, code=1)
        self.call("stage", code=1)
        self.assertEqual(self.call("consume")["reason"], "native-owner-not-pending")


if __name__ == "__main__":
    unittest.main()
