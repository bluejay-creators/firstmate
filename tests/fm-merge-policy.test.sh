#!/usr/bin/env bash
# Exercise the JSON policy executable, never its implementation text.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 - "$ROOT/bin/fm-merge-policy.py" <<'PY'
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROGRAM = sys.argv.pop()
REPOSITORY = "https://github.com/fixture/platform"


class MergePolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = Path(self.tmp.name) / "merge-policy.json"
        self.facts = dict(version=1, provider="github", host="github.com", path="fixture/platform",
                          number="7", url=REPOSITORY + "/pull/7", repository=REPOSITORY,
                          head="a" * 40, base="release-target", all_checks_green=True,
                          approval="", away=False, kinds=[], paths=["src/feature.py"], login="")
        self.policy = dict(version=1, bindings=[dict(repository=REPOSITORY, base="release-target",
                           system="platform", environment="kstage", autonomous_paths=["src/*"])],
                           grants=[dict(id="fixture-grant", repository=REPOSITORY, system="platform",
                           environment="kstage", all_checks_green=True, report_after=True)], sensitive_paths=[])

    def invoke(self, facts=None, policy=None, absent=False):
        if not absent:
            self.config.write_text(json.dumps(self.policy if policy is None else policy))
            self.config.chmod(0o600)
        result = subprocess.run([sys.executable, PROGRAM, "--config", str(self.config)],
                                input=json.dumps(self.facts if facts is None else facts),
                                capture_output=True, text=True)
        return result.returncode, json.loads(result.stdout) if result.stdout else None

    def test_exact_green_grant_requires_reporting(self):
        rc, decision = self.invoke()
        self.assertEqual(rc, 0)
        self.assertEqual(decision["authority"], "grant")
        self.assertEqual(decision["grant"], "fixture-grant")
        self.assertTrue(decision["report_after"])
        self.assertEqual(decision["facts"]["head"], "a" * 40)

    def test_absence_defaults_to_concrete_approval_not_attendance(self):
        self.assertEqual(self.invoke(absent=True)[0], 1)
        self.facts["approval"] = "captain-message-123"
        rc, decision = self.invoke(absent=True)
        self.assertEqual(rc, 0)
        self.assertEqual(decision["authority"], "captain")
        self.assertEqual(decision["facts"]["approval"], "captain-message-123")

    def test_sensitive_kind_and_path_precede_safe_paths_and_grant(self):
        for kind, path in [("keys", "src/secrets.py"), ("iam", "src/iam.py"),
                           ("dns", "src/dns.py"), ("destructive", "src/destroy.py"),
                           ("schema-migration", "src/migrations/001.py"), ("spend", "src/billing.py")]:
            with self.subTest(kind=kind):
                facts = copy.deepcopy(self.facts)
                facts["paths"] = [path]
                rc, decision = self.invoke(facts)
                self.assertEqual(rc, 1)
                self.assertIn(kind, decision["kinds"])
                facts["paths"] = ["src/feature.py"]
                facts["kinds"] = [kind]
                self.assertEqual(self.invoke(facts)[0], 1)
                facts["approval"] = "captain-current-instruction"
                self.assertEqual(self.invoke(facts)[0], 0)
                facts["away"] = True
                self.assertEqual(self.invoke(facts)[0], 1)

    def test_custom_sensitivity_only_tightens(self):
        self.policy["sensitive_paths"] = [dict(kind="keys", patterns=["src/feature.py"])]
        self.assertEqual(self.invoke()[0], 1)

    def test_pilot_prod_green_need_approval_red_never_allowed(self):
        for environment in ("pilot", "prod"):
            with self.subTest(environment=environment):
                self.policy["bindings"][0]["environment"] = environment
                self.assertEqual(self.invoke()[0], 1)
                self.facts["approval"] = "captain-current-instruction"
                self.assertEqual(self.invoke()[0], 0)
                self.facts["all_checks_green"] = False
                self.assertEqual(self.invoke()[0], 1)
                self.facts["approval"] = ""
                self.facts["all_checks_green"] = True

    def test_kstage_red_needs_concrete_approval(self):
        self.facts["all_checks_green"] = False
        self.assertEqual(self.invoke()[0], 1)
        self.facts["approval"] = "captain-named-waiver"
        self.assertEqual(self.invoke()[0], 0)

    def test_branch_name_is_not_environment_authority(self):
        self.facts["base"] = "kstage"
        self.assertEqual(self.invoke()[0], 1)
        self.facts["approval"] = "captain-current-instruction"
        self.facts["all_checks_green"] = False
        self.assertEqual(self.invoke()[0], 1)

    def test_unknown_paths_and_unclassified_paths_refuse_autonomy(self):
        for paths in (None, [], ["unclassified/feature.py"]):
            with self.subTest(paths=paths):
                self.facts["paths"] = paths
                self.assertEqual(self.invoke()[0], 1)
        self.facts["approval"] = "captain-current-instruction"
        self.facts["paths"] = None
        self.assertEqual(self.invoke()[0], 0)
        self.facts["away"] = True
        self.assertEqual(self.invoke()[0], 1)

    def test_malformed_override_never_falls_back_even_with_approval(self):
        self.facts["approval"] = "captain-current-instruction"
        for mutation in (lambda p: p.update(version=2), lambda p: p.update(expression="true"),
                         lambda p: p["bindings"].append(copy.deepcopy(p["bindings"][0])),
                         lambda p: p["grants"][0].update(environment="prod"),
                         lambda p: p["grants"][0].update(report_after=False)):
            policy = copy.deepcopy(self.policy)
            mutation(policy)
            self.assertEqual(self.invoke(policy=policy)[0], 2)

    def test_unknown_facts_and_kinds_refuse(self):
        self.facts["kinds"] = ["model-says-safe"]
        self.assertEqual(self.invoke()[0], 2)
        self.facts["kinds"] = []
        self.facts["trusted_model_confidence"] = 1
        self.assertEqual(self.invoke()[0], 2)

    def test_symlink_and_duplicate_json_refuse(self):
        actual = Path(self.tmp.name) / "actual"
        actual.write_text(json.dumps(self.policy))
        self.config.symlink_to(actual)
        self.assertEqual(self.invoke(absent=True)[0], 2)
        self.config.unlink()
        self.config.write_text('{"version":1,"version":1,"bindings":[],"grants":[],"sensitive_paths":[]}')
        self.assertEqual(self.invoke(absent=True)[0], 2)


unittest.main()
PY
