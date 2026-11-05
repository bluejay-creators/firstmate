#!/usr/bin/env python3
"""Finite, language-neutral merge facts and grants; no expression evaluator.

The fm-pr-merge.sh header owns the operator interface and precedence.
This executable reads one JSON facts object on stdin and emits one JSON decision.
Invalid policy/facts fail closed, including duplicate or unknown fields.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone

KINDS = {"keys", "iam", "dns", "destructive", "schema-migration", "spend",
         "production-deploy", "customer-data-write", "outward-message"}
NONPROD_ENVIRONMENTS = {"kstage", "staging", "nonprod", "internal", "feature"}
FEATURE_PROTECTED_REFS = {"main", "master", "staging", "kstage", "pilot", "prod", "production"}
ENVIRONMENTS = NONPROD_ENVIRONMENTS | {"pilot", "prod", "other"}
# These signals cannot be removed by a grant or by a configured safe path.
SENSITIVE = {
    "keys": ["*secret*", "*credential*", "*.pem", "*.key", "*keychain*"],
    "iam": ["*iam*", "*permission*", "*rbac*", "*authorization*"],
    "dns": ["*dns*", "*route53*", "*cloudflare*"],
    "destructive": ["*destroy*", "*purge*", "*drop*", "*delete*"],
    "schema-migration": ["*migration*", "*schema*", "*.sql"],
    "spend": ["*billing*", "*spend*", "*budget*", "*payment*"],
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field: " + key)
        result[key] = value
    return result


def loads(value):
    return json.loads(value, object_pairs_hook=object_pairs)


def fields(value, names, optional=()):
    require(type(value) is dict and set(names) <= set(value)
            and set(value) <= set(names) | set(optional), "unknown or missing fields")


def text(value):
    return isinstance(value, str) and bool(value.strip()) and not any(ord(c) < 32 for c in value)


def strings(value):
    return type(value) is list and all(text(item) for item in value) and len(set(value)) == len(value)


def policy_read(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"version": 1, "bindings": [], "grants": [], "sensitive_paths": []}
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o022 and info.st_nlink == 1,
            "policy must be an owned, non-writable-by-others regular single-link file")
    with open(path, encoding="utf-8") as source:
        policy = loads(source.read())
    fields(policy, ["version", "bindings", "grants", "sensitive_paths"])
    require(type(policy["version"]) is int and policy["version"] == 1, "unknown policy version")
    require(all(type(policy[key]) is list for key in ("bindings", "grants", "sensitive_paths")), "invalid policy lists")
    seen = set()
    for binding in policy["bindings"]:
        fields(binding, ["repository", "base", "system", "environment", "autonomous_paths"])
        require(all(text(binding[key]) for key in ("repository", "base", "system")), "invalid binding")
        require(binding["environment"] in ENVIRONMENTS, "unknown environment")
        require(strings(binding["autonomous_paths"]), "invalid autonomous paths")
        identity = (binding["repository"], binding["base"])
        require(identity not in seen, "ambiguous repository/base binding")
        seen.add(identity)
    seen = set()
    scopes = set()
    for grant in policy["grants"]:
        fields(grant, ["id", "repository", "system", "environment", "all_checks_green", "report_after"],
               ["required_proof"])
        require(all(text(grant[key]) for key in ("id", "repository", "system")), "invalid grant")
        require(grant["environment"] in NONPROD_ENVIRONMENTS
                and grant["all_checks_green"] is True and grant["report_after"] is True,
                "unsupported standing grant")
        proof = grant.get("required_proof", "forge-checks")
        require(proof in ("forge-checks", "local-tests", "forge-or-local-tests"),
                "unknown grant proof requirement")
        require(grant["environment"] != "feature" or proof == "forge-or-local-tests",
                "feature grants require green forge checks or local test proof")
        require(grant["id"] not in seen, "duplicate grant id")
        seen.add(grant["id"])
        scope = (grant["repository"], grant["system"], grant["environment"])
        require(scope not in scopes, "ambiguous grant scope")
        scopes.add(scope)
    for rule in policy["sensitive_paths"]:
        fields(rule, ["kind", "patterns"])
        require(rule["kind"] in KINDS and strings(rule["patterns"]) and rule["patterns"], "invalid sensitivity rule")
    return policy


def forge_json(command):
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    return loads(result.stdout)


def collect_paths(facts):
    """Read complete changed paths between two matching live identity reads."""
    provider, host, path, number = (facts[key] for key in ("provider", "host", "path", "number"))
    if provider == "github":
        command = ["gh", "api"]
        endpoint = f"repos/{path}/pulls/{number}"
        identity = lambda value: (value["head"]["sha"], value["base"]["ref"], value["html_url"])
    elif provider == "gitlab":
        from urllib.parse import quote
        command = ["glab", "api", "--hostname", host]
        endpoint = f"projects/{quote(path, safe='')}/merge_requests/{number}"
        identity = lambda value: (value["sha"], value["target_branch"], value["web_url"])
    else:
        command = ["tea", "api", "--login", facts["login"], "--repo", path]
        endpoint = f"/repos/{path}/pulls/{number}"
        identity = lambda value: (value["head"]["sha"], value["base"]["ref"], value["html_url"])
    before = forge_json(command + [endpoint])
    expected = (facts["head"], facts["base"], facts["url"])
    require(identity(before) == expected, "PR identity changed before path read")
    paths = []
    if provider == "gitlab":
        changes = forge_json(command + [endpoint + "/changes?access_raw_diffs=true"])
        require(changes.get("overflow") is False and identity(changes) == expected, "incomplete GitLab changes")
        require(type(changes.get("changes")) is list and changes["changes"], "missing GitLab changes")
        for change in changes["changes"]:
            paths.extend([change["old_path"], change["new_path"]])
    else:
        count = before.get("changed_files")
        require(type(count) is int and count > 0, "missing changed-file count")
        require(provider != "github" or count <= 3000, "GitHub changed-file limit exceeded")
        entries = []
        page = 1
        while True:
            query = f"?per_page=100&page={page}" if provider == "github" else f"?limit=100&page={page}"
            batch = forge_json(command + [endpoint + "/files" + query])
            require(type(batch) is list, "invalid changed-file page")
            entries.extend(batch)
            require(len(entries) <= count, "inconsistent changed-file count")
            if not batch or len(entries) == count:
                break
            page += 1
        require(len(entries) == count, "incomplete changed-file list")
        require(len({entry["filename"] for entry in entries}) == count, "duplicate changed-file pages")
        for entry in entries:
            paths.append(entry["filename"])
            if entry.get("previous_filename"):
                paths.append(entry["previous_filename"])
    require(identity(forge_json(command + [endpoint])) == expected, "PR identity changed during path read")
    require(paths and all(text(path) and not path.startswith("/") and ".." not in path.split("/") for path in paths), "invalid changed paths")
    return sorted(set(paths))


def collect_default_branch(facts):
    """The default target is live repository metadata, never a name guess."""
    provider, host, path = (facts[key] for key in ("provider", "host", "path"))
    if provider == "github":
        command = ["gh", "api", f"repos/{path}"]
    elif provider == "gitlab":
        from urllib.parse import quote
        command = ["glab", "api", "--hostname", host, f"projects/{quote(path, safe='')}"]
    else:
        command = ["tea", "api", "--login", facts["login"], "--repo", path, f"/repos/{path}"]
    metadata = forge_json(command)
    require(type(metadata) is dict, "repository metadata is unreadable")
    branch = metadata.get("default_branch")
    require(text(branch), "repository default branch is unreadable")
    return branch


def local_test_receipt_read(path, facts):
    """Read successful local checks; never execute commands supplied by a receipt."""
    if path is None:
        return None
    info = os.lstat(path)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o022 and info.st_nlink == 1,
            "local test receipt must be an owned, non-writable-by-others regular single-link file")
    with open(path, "rb") as source:
        raw = source.read()
    receipt = loads(raw.decode("utf-8"))
    fields(receipt, ["version", "repository", "number", "base", "head", "checks"])
    require(type(receipt["version"]) is int and receipt["version"] == 1,
            "unknown local test receipt version")
    require(type(receipt["number"]) is int and receipt["number"] > 0
            and str(receipt["number"]) == facts["number"]
            and all(receipt[key] == facts[key] for key in ("repository", "base", "head")),
            "local test receipt does not match the verified repository/PR/base/head")
    require(type(receipt["checks"]) is list and receipt["checks"], "missing local test results")
    for check in receipt["checks"]:
        fields(check, ["command", "exit_code"])
        require(text(check["command"]) and type(check["exit_code"]) is int and check["exit_code"] == 0,
                "local test receipt contains an invalid or failed check")
    return {**receipt, "sha256": hashlib.sha256(raw).hexdigest()}


def decide(policy, facts, collect=False, local_test_receipt=None):
    fields(facts, ["version", "provider", "host", "path", "number", "url", "repository", "head", "base",
                   "all_checks_green", "forge_checks_passed", "default_branch",
                   "approval", "away", "kinds", "paths", "login"])
    require(type(facts["version"]) is int and facts["version"] == 1, "unknown facts version")
    require(facts["provider"] in ("github", "gitlab", "forgejo"), "unknown forge")
    require(all(text(facts[key]) for key in ("host", "path", "number", "url", "repository", "head")), "invalid identity facts")
    require(facts["repository"] == "https://" + facts["host"] + "/" + facts["path"], "inconsistent repository identity")
    route = {"github": "/pull/", "gitlab": "/-/merge_requests/", "forgejo": "/pulls/"}[facts["provider"]]
    require(facts["number"].isdigit() and int(facts["number"]) > 0
            and facts["url"] == facts["repository"] + route + facts["number"], "inconsistent PR identity")
    require(re.fullmatch(r"[0-9a-fA-F]{40,64}", facts["head"]) is not None, "invalid verified head")
    require(isinstance(facts["base"], str) and isinstance(facts["approval"], str), "invalid approval/base")
    require(isinstance(facts["login"], str) and (not facts["base"] or text(facts["base"])), "invalid base/login facts")
    require(not facts["approval"] or text(facts["approval"]), "invalid approval reference")
    require(type(facts["away"]) is bool and type(facts["all_checks_green"]) is bool, "invalid check/posture facts")
    require(type(facts["forge_checks_passed"]) is bool, "invalid forge proof facts")
    require(facts["default_branch"] is None or text(facts["default_branch"]),
            "invalid repository default branch")
    require(strings(facts["kinds"]) and set(facts["kinds"]) <= KINDS, "unknown change kind")
    require(facts["paths"] is None or strings(facts["paths"]), "invalid path facts")
    require(facts["paths"] is None or all(
        not path.startswith("/") and ".." not in path.split("/") for path in facts["paths"]),
        "invalid changed paths")
    receipt = local_test_receipt_read(local_test_receipt, facts)
    bindings = [binding for binding in policy["bindings"]
                if binding["repository"] == facts["repository"] and binding["base"] == facts["base"]]
    binding = bindings[0] if bindings else None
    environment = binding["environment"] if binding else "unknown"
    grants = [grant for grant in policy["grants"] if binding and all(
        grant[key] == binding[key] for key in ("repository", "system", "environment"))]
    require(len(grants) <= 1, "ambiguous matching grants")
    # Paths need not be read for an attended concrete approval: every possible
    # path kind already requires exactly that approval. Autonomy/away cannot guess.
    if collect and environment == "feature" and grants and not facts["approval"]:
        facts["default_branch"] = collect_default_branch(facts)
    if collect and facts["paths"] is None and (facts["away"] or (grants and not facts["approval"])):
        facts["paths"] = collect_paths(facts)
    kinds = set(facts["kinds"])
    rules = list(SENSITIVE.items()) + [(rule["kind"], rule["patterns"]) for rule in policy["sensitive_paths"]]
    for kind, patterns in rules:
        if any(fnmatch.fnmatchcase(path.lower(), pattern.lower()) for path in facts["paths"] or [] for pattern in patterns):
            kinds.add(kind)
    reason = "captain approval required outside an explicit grant"
    authority = None
    # Hard rules precede sensitivity, concrete approval, and the standing grant.
    if not facts["all_checks_green"] and environment in ("pilot", "prod", "unknown"):
        reason = "red or missing checks are forbidden for pilot/prod or an unknown environment"
    elif facts["away"] and (kinds or facts["paths"] is None):
        reason = "sensitive or unclassified changes require an attended captain"
    elif facts["approval"]:
        authority = "captain"
        reason = "caller-attested concrete captain approval"
    elif kinds:
        reason = "sensitive change requires captain approval: " + ", ".join(sorted(kinds))
    elif environment in ("pilot", "prod"):
        reason = "pilot/prod always require captain approval"
    elif grants and facts["all_checks_green"] and facts["paths"] and all(
            any(fnmatch.fnmatchcase(path, pattern) for pattern in binding["autonomous_paths"])
            for path in facts["paths"]):
        proof = grants[0].get("required_proof", "forge-checks")
        if environment == "feature" and (not facts["default_branch"]
                or facts["base"] == facts["default_branch"] or facts["base"] in FEATURE_PROTECTED_REFS):
            reason = "feature grants cannot authorize default, protected or unclassified targets"
        elif proof == "local-tests" and receipt is None:
            reason = "an exact-head successful local test receipt is required"
        elif proof == "forge-or-local-tests" and not facts["forge_checks_passed"] and receipt is None:
            reason = "successful forge checks or an exact-head local test receipt are required"
        else:
            authority = "grant"
            reason = "explicit nonproduction green grant"
    return {"version": 1, "allowed": authority is not None, "authority": authority,
            "reason": reason, "environment": environment, "kinds": sorted(kinds),
            "grant": grants[0]["id"] if authority == "grant" else None,
            "report_after": authority == "grant", "local_test_receipt": receipt, "facts": facts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--collect", action="store_true")
    parser.add_argument("--local-test-receipt")
    args = parser.parse_args()
    try:
        decision = decide(policy_read(args.config), loads(sys.stdin.read()), args.collect,
                          args.local_test_receipt)
        decision["decided_at"] = datetime.now(timezone.utc).isoformat()
        print(json.dumps(decision, sort_keys=True))
        return 0 if decision["allowed"] else 1
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print("error: merge policy refused: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
