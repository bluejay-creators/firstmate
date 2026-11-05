#!/usr/bin/env bash
# Exercise the JSON policy executable, never its implementation text.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 - "$ROOT/bin/fm-merge-policy.py" <<'PY'
import copy
import hashlib
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
                          forge_checks_passed=True, default_branch="main",
                          approval="", away=False, kinds=[], paths=["src/feature.py"], login="")
        self.policy = dict(version=1, bindings=[dict(repository=REPOSITORY, base="release-target",
                           system="platform", environment="staging", autonomous_paths=["src/*"])],
                           grants=[dict(id="fixture-grant", repository=REPOSITORY, system="platform",
                           environment="staging", all_checks_green=True, report_after=True)], sensitive_paths=[])

    def invoke(self, facts=None, policy=None, absent=False, receipt=None):
        if not absent:
            self.config.write_text(json.dumps(self.policy if policy is None else policy))
            self.config.chmod(0o600)
        command = [sys.executable, PROGRAM, "--config", str(self.config)]
        if receipt is not None:
            if type(receipt) is dict:
                path = Path(self.tmp.name) / "local-tests.json"
                path.write_text(json.dumps(receipt))
                path.chmod(0o600)
            else:
                path = Path(receipt)
            command += ["--local-test-receipt", str(path)]
        result = subprocess.run(command,
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

    def test_forge_only_grants_require_positive_ci_even_if_no_check_failed(self):
        self.facts["forge_checks_passed"] = False
        self.assertEqual(self.invoke()[0], 1)
        self.policy["grants"][0]["required_proof"] = "forge-checks"
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)
        self.facts["forge_checks_passed"] = True
        self.assertEqual(self.invoke()[0], 0)

    def receipt(self):
        return dict(version=1, repository=self.facts["repository"], number=7,
                    base=self.facts["base"], head=self.facts["head"],
                    checks=[dict(command="bash tests/behavior.test.sh", exit_code=0)])

    def test_nonproduction_grants_match_repository_system_environment_and_live_base(self):
        for repository, system, environment, base in (
                ("fixture-org/client", "fixture-service", "staging", "staging"),
                ("fixture/setup", "setup", "nonprod", "main"),
                ("fixture/firstmate", "firstmate", "internal", "main")):
            with self.subTest(system=system):
                facts, policy = copy.deepcopy(self.facts), copy.deepcopy(self.policy)
                facts.update(repository="https://github.com/" + repository, path=repository,
                             url="https://github.com/" + repository + "/pull/7", base=base)
                binding, grant = policy["bindings"][0], policy["grants"][0]
                for value in (binding, grant):
                    value.update(repository=facts["repository"], system=system, environment=environment)
                binding["base"] = base
                rc, decision = self.invoke(facts, policy)
                self.assertEqual(rc, 0)
                self.assertEqual(decision["authority"], "grant")
                self.assertEqual(decision["environment"], environment)
                facts["base"] = "unbound-target"
                self.assertEqual(self.invoke(facts, policy)[0], 1)
                facts["base"] = base
                grant["system"] = "different-system"
                self.assertEqual(self.invoke(facts, policy)[0], 1)
                grant["system"] = system
                grant["repository"] += "-different"
                self.assertEqual(self.invoke(facts, policy)[0], 1)

    def test_private_nonproduction_environment_requires_explicit_configuration(self):
        for value in (self.policy["bindings"][0], self.policy["grants"][0]):
            value["environment"] = "fixture-stage"
        self.facts["approval"] = "captain-current-instruction"
        self.assertEqual(self.invoke()[0], 2)
        self.facts["approval"] = ""
        self.policy["extra_nonproduction_environments"] = ["fixture-stage"]
        rc, decision = self.invoke()
        self.assertEqual(rc, 0)
        self.assertEqual(decision["authority"], "grant")
        self.assertEqual(decision["environment"], "fixture-stage")
        self.facts["forge_checks_passed"] = False
        self.assertEqual(self.invoke()[0], 1)
        self.facts["forge_checks_passed"] = True
        self.facts["kinds"] = ["production-deploy"]
        self.assertEqual(self.invoke()[0], 1)
        self.facts["kinds"] = []
        self.facts["all_checks_green"] = False
        self.assertEqual(self.invoke()[0], 1)
        self.facts["approval"] = "captain-named-waiver"
        self.assertEqual(self.invoke()[0], 0)

    def test_extra_nonproduction_environments_reject_reserved_and_duplicate_names(self):
        self.facts["approval"] = "captain-current-instruction"
        invalid = [None, {}, "fixture-stage", [None], [""], [" fixture-stage"],
                   ["fixture-stage "], ["fixture-stage", "fixture-stage"],
                   ["fixture-stage", "FIXTURE-STAGE"]]
        for reserved in ("staging", "nonprod", "internal", "feature", "pilot",
                         "prod", "production", "other", "default", "main", "master"):
            invalid.extend(([reserved], [reserved.upper()]))
        for names in invalid:
            with self.subTest(names=names):
                self.policy["extra_nonproduction_environments"] = names
                self.assertEqual(self.invoke()[0], 2)

    def test_local_tests_require_successful_exact_target_receipt(self):
        self.policy["grants"][0]["required_proof"] = "local-tests"
        self.assertEqual(self.invoke()[0], 1)
        rc, decision = self.invoke(receipt=self.receipt())
        self.assertEqual(rc, 0)
        self.assertEqual(decision["authority"], "grant")
        self.assertEqual(decision["local_test_receipt"]["head"], self.facts["head"])
        raw = (Path(self.tmp.name) / "local-tests.json").read_bytes()
        self.assertEqual(decision["local_test_receipt"]["sha256"], hashlib.sha256(raw).hexdigest())
        for key, wrong in (("repository", REPOSITORY + "-other"), ("number", 8),
                           ("base", "other-target"), ("head", "b" * 40)):
            with self.subTest(key=key):
                receipt = self.receipt()
                receipt[key] = wrong
                self.assertEqual(self.invoke(receipt=receipt)[0], 2)

    def test_failed_missing_or_malformed_receipt_cannot_supply_local_proof(self):
        self.policy["grants"][0]["required_proof"] = "local-tests"
        for mutation in (lambda r: r.update(checks=[]),
                         lambda r: r["checks"][0].update(exit_code=1),
                         lambda r: r["checks"][0].update(exit_code=False),
                         lambda r: r["checks"][0].update(command=""),
                         lambda r: r.update(version=True),
                         lambda r: r.update(approved=True)):
            with self.subTest(mutation=mutation):
                receipt = self.receipt()
                mutation(receipt)
                self.assertEqual(self.invoke(receipt=receipt)[0], 2)
        self.assertEqual(self.invoke(receipt=Path(self.tmp.name) / "missing.json")[0], 2)

    def test_receipt_file_ownership_contract_rejects_links_and_other_writers(self):
        self.policy["grants"][0]["required_proof"] = "local-tests"
        path = Path(self.tmp.name) / "receipt.json"
        path.write_text(json.dumps(self.receipt()))
        path.chmod(0o666)
        self.assertEqual(self.invoke(receipt=path)[0], 2)
        path.chmod(0o600)
        linked = path.with_name("receipt-link.json")
        linked.symlink_to(path)
        self.assertEqual(self.invoke(receipt=linked)[0], 2)
        linked.unlink()
        os.link(path, linked)
        self.assertEqual(self.invoke(receipt=path)[0], 2)

    def test_local_proof_never_overrides_red_checks_production_or_tier3_kind(self):
        self.policy["grants"][0]["required_proof"] = "local-tests"
        self.facts["all_checks_green"] = False
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)
        self.facts["all_checks_green"] = True
        for kind in ("production-deploy", "customer-data-write", "outward-message", "keys",
                     "iam", "dns", "destructive", "spend"):
            self.facts["kinds"] = [kind]
            self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)
        self.facts["kinds"] = []
        for environment in ("pilot", "prod"):
            self.policy["bindings"][0]["environment"] = environment
            self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)

    def feature_target(self):
        self.facts.update(base="feat", default_branch="main")
        self.policy["bindings"][0].update(base="feat", environment="feature")
        self.policy["grants"][0].update(environment="feature", required_proof="forge-or-local-tests")

    def test_feature_target_requires_successful_ci_or_exact_local_receipt(self):
        self.feature_target()
        rc, decision = self.invoke()
        self.assertEqual(rc, 0)
        self.assertEqual(decision["authority"], "grant")
        self.assertTrue(decision["report_after"])
        self.facts["forge_checks_passed"] = False
        self.assertEqual(self.invoke()[0], 1)
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 0)
        self.facts["all_checks_green"] = False
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)
        self.facts["all_checks_green"] = True
        self.policy["grants"][0].pop("required_proof")
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 2)

    def test_feature_grant_cannot_reclassify_default_protected_or_unknown_target(self):
        self.feature_target()
        for base, default in (("feat", "feat"), ("feat", None), ("main", "trunk"),
                              ("master", "trunk"), ("staging", "trunk"),
                              ("pilot", "trunk"), ("prod", "trunk"), ("production", "trunk")):
            with self.subTest(base=base, default=default):
                self.facts.update(base=base, default_branch=default)
                self.policy["bindings"][0]["base"] = base
                self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)

    def test_private_nonproduction_refs_cannot_be_feature_targets(self):
        self.feature_target()
        self.policy["extra_nonproduction_environments"] = ["fixture-stage"]
        self.facts["base"] = "fixture-stage"
        self.policy["bindings"][0]["base"] = "fixture-stage"
        self.assertEqual(self.invoke()[0], 1)
        self.facts["forge_checks_passed"] = False
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)

    def test_feature_proof_does_not_override_sensitive_changes(self):
        self.feature_target()
        self.facts["kinds"] = ["customer-data-write"]
        self.assertEqual(self.invoke()[0], 1)
        self.facts["forge_checks_passed"] = False
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)
        self.facts["approval"] = "concrete-captain-instruction"
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 0)
        self.facts["away"] = True
        self.assertEqual(self.invoke(receipt=self.receipt())[0], 1)

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

    def test_staging_red_needs_concrete_approval(self):
        self.facts["all_checks_green"] = False
        self.assertEqual(self.invoke()[0], 1)
        self.facts["approval"] = "captain-named-waiver"
        self.assertEqual(self.invoke()[0], 0)

    def test_branch_name_is_not_environment_authority(self):
        self.facts["base"] = "staging"
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
                         lambda p: p["grants"][0].update(report_after=False),
                         lambda p: p["grants"][0].update(environment="other"),
                         lambda p: p["grants"][0].update(required_proof="trust-me")):
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
