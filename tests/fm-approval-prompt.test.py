#!/usr/bin/env python3
"""Exercise the public CLI against an isolated, persistent board fixture."""
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ASK = ROOT / "bin/fm-captain-ask.sh"
BD = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home = Path(os.environ['FM_HOME'])
a = sys.argv[1:]
rows_file = home / 'rows.json'
rows = json.loads(rows_file.read_text())
with (home / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps(a) + '\n')
def flag(name):
    return a[a.index(name) + 1]
def persist():
    rows_file.write_text(json.dumps(rows))
if a == ['config', 'get', 'issue_prefix']:
    print('test')
elif a[0] == 'list':
    if (home / 'lookup-fails').exists():
        sys.exit(23)
    print(json.dumps([row for row in rows if row['id'] == flag('--id')]))
elif a[0] == 'create':
    row = dict(id=flag('--id'), title=flag('--title'), status='open',
               description=Path(flag('--body-file')).read_text(),
               metadata=json.loads(Path(flag('--metadata')[1:]).read_text()))
    if '--dry-run' not in a:
        assert not any(old['id'] == row['id'] for old in rows)
        rows.append(row)
        persist()
    if (home / 'lost-create-receipt').exists():
        sys.exit(24)
    print(json.dumps(row))
elif a[0] == 'update':
    if (home / 'update-fails').exists():
        sys.exit(25)
    row = next(row for row in rows if row['id'] == a[1])
    row['metadata'] = json.loads(Path(flag('--metadata')[1:]).read_text())
    persist()
elif a[0] == 'close':
    if (home / 'close-fails').exists():
        sys.exit(26)
    row = next(row for row in rows if row['id'] == a[1])
    row.update(status='closed', close_reason=flag('--reason'))
    persist()
else:
    sys.exit(2)
'''


class PublicationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fm-approval-test-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        (self.home / "config").mkdir()
        (self.home / "board/.beads").mkdir(parents=True)
        (self.home / "config/beads-board").write_text(str(self.home / "board") + "\n")
        (self.home / "rows.json").write_text("[]")
        (self.home / "fakebin").mkdir()
        executable = self.home / "fakebin/bd"
        executable.write_text(BD)
        executable.chmod(0o700)
        self.environment = {**os.environ, "FM_HOME": str(self.home),
                            "PATH": str(executable.parent) + os.pathsep + os.environ["PATH"]}
        self.frame = dict(schema="firstmate.omp-approval.v1", approvalId="native-dialog",
                          sessionId="main-session", approvalKind="tool",
                          requestedAt="2026-10-31T20:00:00Z", toolName="bash",
                          toolCallId="call-1", command="printf final-command",
                          prompt="Allow the revised command?", choices=["Approve", "Deny"],
                          origin={"machine": "test-mac", "cwd": "/workspace"})
        self.store = self.home / "state/captain-asks/omp"

    def run_ask(self, *arguments, expected=0):
        result = subprocess.run(["bash", str(ASK), *arguments], env=self.environment,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
        return result

    def ingest(self, frame=None, *, expected=0, dry_run=False):
        path = self.home / "event.json"
        path.write_text(json.dumps(self.frame if frame is None else frame))
        args = ["--approval-event", str(path)]
        if dry_run:
            args.append("--dry-run")
        return self.run_ask(*args, expected=expected)

    def rows(self):
        return json.loads((self.home / "rows.json").read_text())

    def save_rows(self, rows):
        (self.home / "rows.json").write_text(json.dumps(rows))

    def test_replays_and_terminal_before_requested_observation_never_duplicate_or_reopen(self):
        terminal = {**self.frame, "resolution": {"kind": "denied", "choice": "Deny"}}
        self.ingest(terminal)
        for frame in (terminal, self.frame, self.frame):
            self.ingest(frame)
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "closed")
        self.assertEqual(rows[0]["metadata"]["approval"]["nativeResolution"],
                         {"kind": "denied", "choice": "Deny"})
        self.assertFalse(rows[0]["metadata"]["approval"]["executionEstablished"])
        self.assertEqual(list((self.store / "pending").glob("*.json")), [])

    def test_changed_command_choices_and_directory_cannot_reuse_permission(self):
        self.ingest()
        original = self.rows()
        for field, value in (("command", "printf different"), ("choices", ["Deny", "Approve"]),
                             ("origin", {"machine": "test-mac", "cwd": "/other"})):
            with self.subTest(field=field):
                frame = copy.deepcopy(self.frame)
                frame[field] = value
                self.ingest(frame, expected=1)
                self.assertEqual(self.rows(), original)

    def test_failed_lookup_retains_event_and_recovers_without_interpreting_failure_as_absence(self):
        (self.home / "lookup-fails").touch()
        self.ingest(expected=1)
        self.assertEqual(self.rows(), [])
        self.assertEqual(len(list((self.store / "pending").glob("*.json"))), 1)
        (self.home / "lookup-fails").unlink()
        self.run_ask("--approval-reconcile")
        self.assertEqual(self.rows()[0]["status"], "open")

    def test_lost_create_receipt_and_process_restart_recover_the_existing_question(self):
        (self.home / "lost-create-receipt").touch()
        self.ingest()
        self.ingest()
        self.run_ask("--approval-reconcile")
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0]["status"], "open")

    def test_interrupted_close_recovers_when_the_already_completed_metadata_write_is_unavailable(self):
        self.ingest()
        (self.home / "close-fails").touch()
        terminal = {**self.frame, "resolution": {"kind": "approved", "choice": "Approve"}}
        self.ingest(terminal, expected=1)
        self.assertEqual(self.rows()[0]["status"], "open")
        self.assertEqual(self.rows()[0]["metadata"]["approval"]["permissionState"], "approved")
        (self.home / "close-fails").unlink()
        (self.home / "update-fails").touch()
        self.run_ask("--approval-reconcile")
        self.assertEqual(self.rows()[0]["status"], "closed")
        self.assertFalse(self.rows()[0]["metadata"]["approval"]["executionEstablished"])

    def test_valid_empty_native_display_values_still_publish_and_resolve(self):
        self.frame.update(command="", commandCwd="", reason="", prompt="")
        self.ingest()
        self.assertEqual(self.rows()[0]["status"], "open")
        self.ingest({**self.frame, "resolution": {"kind": "approved", "choice": "Approve"}})
        self.assertEqual(self.rows()[0]["status"], "closed")
        self.assertFalse(self.rows()[0]["metadata"]["approval"]["executionEstablished"])

    def test_origin_enrichment_preserves_reviewed_wording_and_never_runs_the_command(self):
        self.frame["command"] = "touch " + str(self.home / "must-not-execute")
        self.ingest()
        rows = self.rows()
        rows[0].update(title="Reviewed human title", description="Reviewed explanation")
        self.save_rows(rows)
        enriched = copy.deepcopy(self.frame)
        enriched["origin"].update(tabLabel="Main", paneId="pane-17")
        self.ingest(enriched)
        row = self.rows()[0]
        self.assertEqual(row["title"], "Reviewed human title")
        self.assertEqual(row["description"], "Reviewed explanation")
        self.assertEqual(row["metadata"]["approval"]["request"]["origin"]["paneId"], "pane-17")
        self.assertFalse((self.home / "must-not-execute").exists())
        for directory in (self.store, self.store / "pending", self.store / "locks"):
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)

    def test_timeout_and_cancellation_are_not_denial_or_execution(self):
        for outcome in ("timeout", "cancelled"):
            frame = {**self.frame, "approvalId": outcome, "resolution": {"kind": outcome}}
            self.ingest(frame)
        self.assertEqual({row["metadata"]["approval"]["permissionState"] for row in self.rows()},
                         {"timeout", "cancelled"})
        for row in self.rows():
            self.assertNotIn("choice", row["metadata"]["approval"]["nativeResolution"])
            self.assertEqual(row["status"], "closed")

    def test_preview_does_not_create_home_state_or_a_real_question(self):
        result = self.ingest(dry_run=True)
        self.assertEqual(json.loads(result.stdout)["state"], "preview")
        self.assertEqual(self.rows(), [])
        self.assertFalse((self.home / "state").exists())

    def test_outbox_survives_busy_publisher_and_is_acknowledged_only_after_success(self):
        self.ingest()
        key = next((self.store / "pending").glob("*.json")).stem
        outbox = self.store / "outbox"
        outbox.mkdir()
        body = json.dumps({**self.frame, "resolution": {"kind": "approved", "choice": "Approve"}})
        event = outbox / (hashlib.sha256(body.encode()).hexdigest() + ".json")
        event.write_text(body)
        with (self.store / "locks" / (key + ".lock")).open("r+") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            result = json.loads(self.run_ask("--approval-reconcile").stdout)
            self.assertTrue(result["busy"])
            self.assertTrue(event.exists())
            self.assertEqual(self.rows()[0]["status"], "open")
        self.run_ask("--approval-reconcile")
        self.assertFalse(event.exists())
        self.assertEqual(self.rows()[0]["status"], "closed")
        self.assertEqual(self.rows()[0]["metadata"]["approval"]["nativeResolution"]["choice"], "Approve")

    def test_other_question_at_the_deterministic_id_is_never_overwritten(self):
        self.ingest()
        rows = self.rows()
        rows[0]["metadata"]["approval"]["sourceKey"] = "another-owner"
        rows[0]["title"] = "Unrelated question"
        self.save_rows(rows)
        frame = {**self.frame, "resolution": {"kind": "approved", "choice": "Approve"}}
        self.ingest(frame, expected=1)
        self.assertEqual(self.rows(), rows)


if __name__ == "__main__":
    unittest.main(verbosity=2)
