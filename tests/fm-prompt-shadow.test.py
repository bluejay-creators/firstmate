#!/usr/bin/env python3
"""Public shadow CLI behavior with deterministic Herdr/native/forge fixtures.

Run: python3 tests/fm-prompt-shadow.test.py
Fixtures never contact GitHub, send a key, file a live card or page a phone.
"""
import copy
from datetime import datetime, timezone, timedelta
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROGRAM = Path(__file__).resolve().parents[1] / 'bin/fm-prompt-shadow.py'
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path.home()
f = json.loads((root / 'fixture.json').read_text())
a = sys.argv[1:]
name = Path(sys.argv[0]).name
with (root / 'observed.jsonl').open('a') as s:
    s.write(json.dumps([name, a]) + '\n')
def emit(value): print(json.dumps(value))
def flag(key): return a[a.index(key) + 1]
if name == 'herdr':
    if a[:2] == ['workspace','list']:
        emit({'result': {'workspaces': [{'workspace_id':'w1'}, {'workspace_id':'w2'}]}})
    elif a[:2] == ['pane','list']:
        emit({'result': {'panes': [p for p in f['panes'] if p['workspace_id'] == flag('--workspace')]}})
    elif a[:2] == ['pane','get']:
        p = copy = next(p for p in f['panes'] if p['pane_id'] == a[2])
        if f.get('changed_session'): p['agent_session']['value'] += '.changed'
        emit({'result': {'pane':p}})
    elif a[:2] == ['pane','read']:
        p = next(p for p in f['panes'] if p['pane_id'] == a[2])
        print(f.get('rendered', {}).get(p['pane_id'], 'Allow tool: bash\nCommand: ' + f['command'] + '\napprove once / deny'))
    else: sys.exit(91)
elif name == 'git':
    if 'rev-parse' in a: print(flag('-C'))
    elif 'branch' in a: print(f.get('local_branch','task/owned'))
    elif 'remote' in a: print(f.get('origin','https://github.com/example/tools.git'))
    else: sys.exit(92)
elif name == 'gh':
    # Unscoped metadata and credential reads must never authorize a prediction.
    sys.exit(93)
elif name == 'ghx':
    if a == ['status','--json']:
        emit({'active':f.get('active_account','fixture-work')})
        sys.exit(0)
    if len(a) < 4 or a[0] != 'run': sys.exit(93)
    account = a[1]
    a = a[2:]
    if a[:1] == ['--']: a = a[1:]
    if a[:1] != ['api']: sys.exit(93)
    endpoint = a[-1]
    facts = f.get('account_facts', {}).get(account, {})
    if endpoint == 'user': sys.exit(93)  # installation tokens have no /user
    elif endpoint == 'repos/example/tools':
        emit({'full_name':'example/tools', 'default_branch':facts.get('default_branch',f.get('default_branch','main')),
              'permissions':facts.get('permissions',{'push':True})})
    elif '/branches/' in endpoint:
        from urllib.parse import unquote
        branch = unquote(endpoint.split('/branches/')[1])
        emit({'name':branch, 'protected':branch in facts.get('protected',f.get('protected',[]))})
    elif '/pulls?' in endpoint: emit(facts.get('prs', f.get('prs',[f['pr']])))
    elif endpoint.endswith('/pulls/7'): emit(facts.get('pr', f['pr']))
    else: sys.exit(93)
elif name == 'bd':
    path = root / 'board.json'
    rows = json.loads(path.read_text()) if path.exists() else []
    if a == ['config','get','issue_prefix']: print('test')
    elif a[0] == 'list': emit([r for r in rows if r['id'] == flag('--id')])
    elif a[0] == 'create':
        row = {'id':flag('--id'), 'metadata':json.loads(flag('--metadata')), 'status':'open'}
        assert not any(r['id'] == row['id'] for r in rows)
        rows.append(row); path.write_text(json.dumps(rows)); emit(row)
    else: sys.exit(94)
elif name == 'phone-fixture':
    assert a[-1] == 'urgent' and '--batch-id' in a
    emit({'status':'sent'})
else: sys.exit(95)
'''


def timestamp(seconds=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat().replace('+00:00','Z')


class ShadowTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='fm-shadow-fixture-')
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        (self.home / 'bin').mkdir()
        for name in ('herdr','gh','ghx','git','bd','phone-fixture'):
            path = self.home / 'bin' / name
            path.write_text(FAKE)
            path.chmod(0o700)
        self.worktree = self.home / 'worktree'
        self.worktree.mkdir()
        self.session = self.home / 'session.jsonl'
        self.store = self.home / 'state/captain-asks/omp/outbox'
        self.store.mkdir(parents=True)
        self.snapshot = self.store / ('0' * 64 + '.json')
        self.state = self.home / 'observer'
        self.state.mkdir(mode=0o700)
        config = self.home / 'config'
        config.mkdir()
        (self.home / 'board/.beads').mkdir(parents=True)
        (config / 'beads-board').write_text(str(self.home / 'board') + '\n')
        (config / 'phone-notify').write_text('phone-fixture\n')
        self.fixture = {'command':'pwd', 'panes':[
            {'pane_id':'w2:p9', 'workspace_id':'w2', 'agent':'omp', 'agent_status':'blocked',
             'agent_session':{'kind':'path', 'value':str(self.session)}}],
            'pr':{'state':'open', 'merged_at':None, 'user':{'login':'operator'},
                  'head':{'ref':'task/owned', 'repo':{'full_name':'example/tools'}},
                  'base':{'ref':'integration', 'repo':{'full_name':'example/tools'}}}}
        self.frame = {'schema':'firstmate.omp-approval.v1', 'approvalId':'prompt-1',
                      'sessionId':'session-1', 'toolCallId':'call-1', 'toolName':'bash',
                      'approvalKind':'tool', 'requestedAt':timestamp(), 'command':'pwd',
                      'prompt':'Allow tool: bash\nCommand: pwd', 'choices':['Approve','Deny'],
                      'origin':{'machine':'fixture', 'cwd':str(self.worktree)}}
        self.policy = self.home / 'policy.json'
        self.policy.write_text(json.dumps({'schema':'fm-prompt-shadow-policy.v2', 'grants':[
            {'repository':'example/tools','branch':'task/owned','cwd':str(self.worktree),
             'session_id':'session-1','account':'work','pr_author':'operator',
             'evidence':'private-captain-grant-fixture'}]}))
        self.env = {**os.environ, 'HOME':str(self.home), 'HERDR_ENV':'1',
                    'PATH':str(self.home / 'bin') + os.pathsep + os.environ['PATH'],
                    'FM_HOME':str(self.home), 'BLUEJAY_ACCOUNTS_CONFIG':str(self.home / 'accounts.sh')}
        self.set_account('work')
        self.write_session()

    def set_account(self, account):
        (self.home / 'accounts.sh').write_text(
            'bluejay_github_owner_account() { case \"$1\" in example) echo ' + account +
            ' ;; *) return 1 ;; esac; }\n'
            'bluejay_github_login() { case "$1" in work) echo fixture-work ;; '
            'personal) echo fixture-personal ;; *) return 1 ;; esac; }\n')
        policy = json.loads(self.policy.read_text())
        policy['grants'][0]['account'] = account
        self.policy.write_text(json.dumps(policy))
        self.fixture['active_account'] = 'fixture-' + account

    def write_session(self, command=None, ended=False):
        rows = [{'type':'session','id':'session-1','cwd':str(self.worktree)},
                {'type':'message','message':{'role':'assistant','content':[
                    {'type':'toolCall','id':'call-1','name':'bash',
                     'arguments':{'command':command or self.fixture['command'],'cwd':str(self.worktree),
                                  **self.fixture.get('tool_arguments', {})}}]}}]
        if ended:
            rows.append({'type':'message','message':{'role':'toolResult','toolCallId':'call-1'}})
        self.session.write_text(''.join(json.dumps(row) + '\n' for row in rows))

    def invoke(self, *, command=None, expected=0, route=False, native=True):
        if command is not None:
            self.fixture['command'] = command
            self.frame['command'] = command
            self.frame['prompt'] = 'Allow tool: bash\nCommand: ' + command
            self.write_session()
        (self.home / 'fixture.json').write_text(json.dumps(self.fixture))
        if native:
            self.snapshot.write_text(json.dumps(self.frame))
        elif self.snapshot.exists():
            self.snapshot.unlink()
        result = subprocess.run([sys.executable, str(PROGRAM), '--home', str(self.home),
                                 '--state-dir', str(self.state), '--policy', str(self.policy)] +
                                (['--route'] if route else []), env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stderr)
        findings = [json.loads(line) for line in result.stdout.splitlines()]
        # Raw command/prompt and native payload must not leak onto this channel.
        for finding in findings:
            self.assertNotIn('command', finding)
            self.assertNotIn('prompt', finding)
        observed = [json.loads(line) for line in (self.home / 'observed.jsonl').read_text().splitlines()]
        self.assertFalse(any(name == 'herdr' and args[:2] in
                             (['pane','send-keys'],['pane','send-text'],['pane','run'])
                             for name, args in observed))
        return findings

    def reset_state(self):
        path = self.state / 'findings.json'
        if path.exists(): path.unlink()

    def test_both_real_account_forms_and_optional_separator(self):
        for account in ('work', 'personal'):
            self.set_account(account)
            for separator in (' -- ', ' '):
                for action in ('pr create -R example/tools --head task/owned --base integration --title Review --body Details',
                               'pr edit 7 -R example/tools --body Revised',
                               'pr comment 7 -R example/tools --body Reviewed'):
                    with self.subTest(account=account, separator=separator, action=action):
                        self.reset_state()
                        finding = self.invoke(command='ghx run ' + account + separator + action)[0]
                        self.assertEqual(finding['decision'], 'would-approve')
                        self.assertEqual(finding['verified_tier'], 1)

    def test_wrong_account_and_scoped_permission_facts_deny(self):
        for command in ('ghx run personal -- pr comment 7 -R example/tools --body Reviewed',
                        'ghx run personal -- pr view 7 -R example/tools',
                        'gh pr comment 7 -R example/tools --body Reviewed',
                        'ghx run pr edit 7 -R example/tools --body Reviewed'):
            self.reset_state()
            self.assertEqual(self.invoke(command=command)[0]['decision'], 'would-card')
        self.fixture['active_account'] = 'fixture-personal'
        self.reset_state()
        self.assertEqual(self.invoke(command='gh pr view 7 -R example/tools')[0]['decision'], 'would-card')
        self.fixture['account_facts'] = {'work': {'permissions': {'push':False}},
                                         'personal': {'permissions': {'push':True}}}
        self.reset_state()
        self.assertEqual(self.invoke(command='ghx run work -- pr comment 7 -R example/tools --body Reviewed')[0]['decision'],
                         'would-card')

    def test_installation_actor_is_not_inferred_from_user_endpoint(self):
        self.fixture['pr']['user']['login'] = 'review-agent[bot]'
        policy = json.loads(self.policy.read_text())
        policy['grants'][0]['pr_author'] = 'review-agent[bot]'
        self.policy.write_text(json.dumps(policy))
        finding = self.invoke(command='ghx run work -- pr comment 7 -R example/tools --body Reviewed')[0]
        self.assertEqual(finding['decision'], 'would-approve')
        self.reset_state()
        self.fixture['account_facts'] = {'work': {'permissions': {}}}
        self.assertEqual(self.invoke(command='ghx run work -- pr comment 7 -R example/tools --body Reviewed')[0]['decision'],
                         'would-card')

    def test_safe_named_read_only_forms(self):
        commands = [
            'git status --porcelain=v1 --untracked-files=no',
            'git --no-pager log -5 --oneline HEAD',
            'git log -1 --format="%H %s" HEAD',
            'git diff --stat HEAD~1..HEAD',
            'git diff --no-ext-diff --no-textconv',
            'git show --no-patch --format=%H HEAD',
            'git branch --show-current',
            'git rev-parse --verify HEAD',
            'git ls-files --cached',
            'git remote get-url origin',
            'bd --readonly --sandbox export',
            'bd show task-123 --json',
            'bd list --status open --limit 10 --json',
            'bd ready --json',
            'bd stats',
            'gh pr view 7 --repo example/tools --json number,title',
            'gh pr list --repo example/tools --state open --limit 10',
            'gh pr checks 7 -R example/tools --required',
            'gh pr diff 7 -R example/tools --name-only',
            'gh issue view 7 -R example/tools --comments',
            'gh run view 7 -R example/tools --log-failed',
            'gh run list -R example/tools --limit 10',
            'gh repo view example/tools --json name',
            'gh api --method GET repos/example/tools/pulls/7',
            'ghx run work -- api "repos/example/tools/branches?per_page=10"',
            'ghx run work -- pr view 7 -R example/tools',
        ]
        for command in commands:
            with self.subTest(command=command):
                self.reset_state()
                finding = self.invoke(command=command)[0]
                self.assertEqual(finding['decision'], 'would-approve')
                self.assertEqual(finding['verified_tier'], 0)
        self.set_account('personal')
        self.reset_state()
        self.assertEqual(self.invoke(command='ghx run personal -- pr view 7 -R example/tools')[0]['verified_tier'], 0)

    def test_unsafe_read_options_credentials_and_output_writes_deny(self):
        commands = [
            'git log --output=/tmp/changed',
            'git log HEAD*',
            'git log ~',
            'git log --format="%G?" HEAD',
            'git diff --ext-diff',
            'git show --textconv HEAD',
            'git show --no-ext-diff --no-textconv HEAD:credentials.json',
            'git config --get credential.helper',
            'git branch new-branch',
            'bd export --output /tmp/changed',
            'bd --db /tmp/other list',
            'bd sql "select 1"',
            'gh pr view 7 -R example/tools --web',
            'gh pr view 7 -R example/tools --template "{{.body}}"',
            'gh pr view 7 -R example/tools --jq env',
            'gh run download 7 -R example/tools',
            'gh api repos/example/tools/issues --method POST',
            'gh api repos/example/tools/pulls/7 --field body=changed',
            'gh api repos/example/tools/pulls/7 --input /tmp/body',
            'gh api repos/example/tools/actions/secrets',
            'gh api user',
            'gh auth status',
            'ghx run work -- auth token',
        ]
        for command in commands:
            with self.subTest(command=command):
                self.reset_state()
                self.assertEqual(self.invoke(command=command)[0]['decision'], 'would-card')

    def test_tool_environment_and_service_context_are_not_command_only_grants(self):
        for arguments in ({'env':{'GH_TOKEN':'fixture-not-a-secret'}},
                          {'env':{'BLUEJAY_ACCOUNTS_CONFIG':'/tmp/other-catalog'}},
                          {'name':'unreviewed-service'}, {'pty':True}, {'shell':'unreviewed-shell'}):
            self.fixture['tool_arguments'] = arguments
            self.reset_state()
            self.assertEqual(self.invoke(command='ghx run work -- pr comment 7 -R example/tools --body Reviewed')[0]['decision'],
                             'would-card')


    def test_verified_tiers(self):
        for command, tier in [('pwd',0), ('git status --short --branch',0),
                              ('git push origin task/owned',1),
                              ('git push --force-with-lease origin task/owned',1),
                              ('git -C ' + str(self.worktree) + ' push -u origin HEAD:task/owned',1),
                              ('ghx run work -- pr create -R example/tools --head task/owned --base integration --title Review --body Details',1),
                              ('ghx run work pr edit 7 -R example/tools --body Revised',1),
                              ('ghx run work -- pr comment 7 --repo example/tools --body Reviewed',1),
                              ('cd ' + str(self.worktree) + ' && git push origin task/owned',1)]:
            with self.subTest(command=command):
                self.reset_state()
                finding = self.invoke(command=command)[0]
                self.assertEqual(finding['decision'],'would-approve')
                self.assertEqual(finding['verified_tier'],tier)
                self.assertEqual(finding['command_sha256'],hashlib.sha256(command.encode()).hexdigest())

    def test_unknown_protected_outward_and_config_fail_closed(self):
        commands = ['git push --force origin task/owned', 'git push origin main',
                    'git push upstream task/owned', 'git push origin task/owned:main',
                    'git push origin task/owned; gh pr create',
                    'git push origin task/owned || true', 'git push origin task/owned | cat',
                    'git push origin $(cat branch)', 'env GH_TOKEN=x git push origin task/owned',
                    'git config core.hooksPath /tmp/hooks', 'gh auth token',
                    'gh pr merge 7 -R example/tools', 'curl https://example.invalid',
                    'gh pr create -R other/tools --base integration --head task/owned',
                    'gh pr create -R example/tools --base main --head task/owned',
                    'gh pr create -R example/tools --head task/owned',
                    'gh pr create -R example/tools --base integration',
                    'gh pr comment 7 -R example/tools --body-file /tmp/unreviewed',
                    'gh pr edit 7 -R example/tools --base main',
                    'gh pr edit 7 -R example/tools --repo other/tools --body hi',
                    'gh pr comment 7 -R example/tools --body credential',
                    'gh secret set EXAMPLE -R example/tools']
        for command in commands:
            with self.subTest(command=command):
                self.reset_state()
                self.assertEqual(self.invoke(command=command)[0]['decision'],'would-card')

    def test_forge_ownership_origin_and_protection(self):
        for change in ({'origin':'https://github.com/other/tools.git'},
                       {'origin':'https://github.com/example/tools.git\nhttps://github.com/other/tools.git'},
                       {'protected':['task/owned']}, {'default_branch':'task/owned'},
                       {'local_branch':'task/other'}):
            with self.subTest(change=change):
                original = copy.deepcopy(self.fixture)
                self.fixture.update(change)
                self.reset_state()
                self.assertEqual(self.invoke(command='git push origin task/owned')[0]['decision'],'would-card')
                self.fixture = original
        for key, value in [('user',{'login':'other'}),('state','closed'),('merged_at',timestamp())]:
            original = copy.deepcopy(self.fixture['pr'])
            self.fixture['pr'][key] = value
            self.reset_state()
            self.assertEqual(self.invoke(command='git push --force-with-lease origin task/owned')[0]['decision'],'would-card')
            self.fixture['pr'] = original
        self.fixture['protected'] = ['integration']
        self.reset_state()
        self.assertEqual(self.invoke(command='ghx run work -- pr comment 7 -R example/tools --body hi')[0]['decision'],'would-card')

    def test_missing_grant_and_native_snapshot(self):
        self.policy.write_text(json.dumps({'schema':'fm-prompt-shadow-policy.v2','grants':[]}))
        self.assertEqual(self.invoke(command='git push origin task/owned')[0]['decision'],'would-card')
        self.reset_state()
        self.fixture['rendered'] = {'w2:p9':'pwd\napprove once / deny'}
        finding = self.invoke(command='pwd',native=False)[0]
        self.assertEqual(finding['decision'],'would-card')
        self.assertEqual(finding['tool_call_id'],'call-1')

    def test_legacy_full_final_display_is_exactly_bound(self):
        self.fixture['rendered'] = {'w2:p9':'Allow tool: bash\nReason: prompt rule\nCommand: pwd\napprove once / deny'}
        finding = self.invoke(native=False)[0]
        self.assertEqual(finding['decision'],'would-approve')
        self.assertTrue(finding['prompt_id'].startswith('rendered-'))
        self.fixture['rendered'] = {'w2:p9':'Allow tool: bash\nReason: changed\nCommand: pwd\napprove once / deny'}
        self.assertEqual(self.invoke(native=False)[0]['decision'],'would-card')
        self.reset_state()
        self.fixture['rendered'] = {'w2:p9':'Allow tool: bash\nCommand: pwd[…4ch elided…]\napprove once / deny'}
        self.assertEqual(self.invoke(native=False)[0]['decision'],'would-card')

    def test_native_command_prefix_is_not_full_command_evidence(self):
        self.fixture['rendered'] = {'w2:p9':'Allow tool: bash\nCommand: pwd && echo changed\napprove once / deny'}
        self.assertEqual(self.invoke()[0]['decision'],'would-card')

    def test_changed_partial_and_stale_identity(self):
        self.write_session(command='git status --short')
        self.assertEqual(self.invoke()[0]['reason'],'changed-or-partial-command')
        self.reset_state(); self.write_session()
        self.frame['requestedAt'] = timestamp(-601)
        finding = self.invoke()[0]
        self.assertEqual(finding['decision'],'would-card')
        self.assertTrue(finding['stall_card_due']); self.assertTrue(finding['page_due'])
        self.frame['requestedAt'] = timestamp()
        self.reset_state()
        self.fixture['changed_session'] = True
        self.assertEqual(self.invoke()[0]['decision'],'would-card')
        self.fixture.pop('changed_session')
        self.reset_state()
        self.fixture['rendered'] = {'w2:p9':'truncated command ...\napprove / deny'}
        self.assertEqual(self.invoke()[0]['decision'],'would-card')

    def test_same_command_changed_prompt_never_approves(self):
        self.assertEqual(self.invoke()[0]['decision'],'would-approve')
        self.frame['prompt'] = 'Different permission intent'
        self.assertEqual(self.invoke()[0]['decision'],'would-card')

    def test_resolution_is_not_execution_and_disappearance_is_not_resolution(self):
        first = self.invoke()[0]
        self.fixture['rendered'] = {'w2:p9':'ordinary editor'}
        finding = self.invoke()[0]
        self.assertEqual(finding['status'],'pending')
        self.assertEqual(finding['finding_id'],first['finding_id'])
        self.write_session(ended=True)
        finding = self.invoke()[0]
        self.assertEqual(finding['status'],'resolved')
        self.assertEqual(finding['reason'],'tool-result-observed')

    def test_all_workspaces_and_no_native_hook_are_visible(self):
        second = copy.deepcopy(self.fixture['panes'][0])
        second.update(pane_id='w1:p1',workspace_id='w1')
        self.fixture['panes'].append(second)
        findings = self.invoke(native=False)
        self.assertEqual(len(findings),2)
        self.assertTrue(all(f['decision'] == 'would-card' for f in findings))

    def test_redacted_card_phone_and_idempotent_replay(self):
        self.frame['requestedAt'] = timestamp(-601)
        finding = self.invoke(route=True)[0]
        self.assertTrue(finding.get('card_id'))
        self.assertTrue(finding.get('card_filed_at'))
        self.assertTrue(finding.get('page_request_id'))
        self.invoke(route=True)
        rows = json.loads((self.home / 'board.json').read_text())
        self.assertEqual(len(rows),1)
        observed = [json.loads(line) for line in (self.home / 'observed.jsonl').read_text().splitlines()]
        self.assertEqual(sum(name == 'phone-fixture' for name, _ in observed),1)


if __name__ == '__main__':
    unittest.main()
