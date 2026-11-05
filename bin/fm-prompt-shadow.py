#!/usr/bin/env python3
"""External OMP approval observer. SHADOW ONLY: never sends input or changes rules.

Run once (read-only except optional private journal):
  python3 bin/fm-prompt-shadow.py --home PRIMARY_HOME --policy REVIEWED_JSON
Use --state-dir PRIVATE_DIR for durable first-seen times and resolved findings.
Use --watch to rescan every 20 seconds; --route additionally publishes redacted
cards through the existing captain board and Inbox route. Without --route all
card/page effects are predictions. Neither mode ever approves a native prompt.
The caller must supervise this process; no daemon or runtime setting is installed.

Policy schema fm-prompt-shadow-policy.v2: grants is a list of exact objects with
repository (owner/repo), cwd (absolute task worktree), branch, session_id,
account (catalog credential slot), pr_author (reviewed PR ownership actor), and
evidence (private captain-grant reference). These are reviewed origin AND exclusive
branch-ownership grants, not discovered permission from a git remote. Empty grants
is safe. Missing policy means no write grants. No wildcard or protected grants.
The existing generated ghx owner/account catalog selects the credential slot;
metadata reads use that explicit ghx account, never token stores or /user.
pr_author is ownership evidence, NOT a claim about a token's authenticated subject.
Installation credentials can supply repository facts without a user endpoint;
missing repository push-permission facts deny write predictions. Plain gh writes
require a card because this observer cannot prove another process's inherited
credential overrides; plain gh read predictions require matching active account.
Tier-0 grammar covers finite git metadata/diff forms (patch reads require
--no-ext-diff --no-textconv), bd show/list/ready/status/stats/search/export,
and gh/ghx PR/issue/run/repo reads plus repository-scoped GET API reads.
Output files, config/auth, alternate board stores, jq/templates, web/browser
actions, downloads, unknown flags and shell expansion always require a card.

Native firstmate.omp-approval.v1 snapshots come from each --home's existing
state/captain-asks/omp/{outbox,pending,handled}. Session JSONL is read ONLY through
Herdr's current session-path binding. On older OMP without native snapshots, only
an unelided final `Allow tool: bash` / `Command:` display exactly equal to the one
unresolved session tool call can produce a shadow prediction. Missing, wrapped,
changed or partial displays require a card. Inbox tab-prompts.py supplies the
all-workspace detector pattern; no rendered-only path can ever approve a prompt.

stdout is redacted fm-prompt-finding.v1 JSONL for Inbox/manual comparison and
Temporal ingestion. command_source is a private file reference, never command
text. first_seen_at is the native requestedAt when available, otherwise the first
external observation. In --route shadow mode every detected pending prompt gets
its manual-review card immediately, before forge classification; stall_card_due
marks the 120s deadline. At >600s the configured content-free phone notifier and
Inbox escalation are requested. Resolved means observed native/tool termination,
not proof of execution. Disappearance alone is never resolution. Unreadable scans
exit nonzero rather than declaring an empty healthy fleet. Same-UID sources and
the reviewed policy are trusted; this is not a hostile-same-UID security boundary.
"""

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

SCHEMA = 'fm-prompt-finding.v1'
# Reuse the merge-policy owner's protected names instead of another list.
_policy_spec = importlib.util.spec_from_file_location('prompt_merge_policy', Path(__file__).with_name('fm-merge-policy.py'))
_shared_policy = importlib.util.module_from_spec(_policy_spec)
_policy_spec.loader.exec_module(_shared_policy)
PROTECTED = re.compile(r'^(?:' + '|'.join(re.escape(name) for name in _shared_policy.FEATURE_PROTECTED_REFS)
                       + r'|release(?:/.*)?)$')
REPO = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z')
BRANCH = re.compile(r'[A-Za-z0-9][A-Za-z0-9._/-]*\Z')


class Unsafe(Exception):
    pass


def require(ok, reason):
    if not ok:
        raise Unsafe(reason)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def stamp(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00', 'Z')


def epoch(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def private_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and not info.st_mode & 0o022 and info.st_size <= 8 * 1024 * 1024,
                'untrusted-source')
        return json.load(stream)


def run(args, cwd=None):
    # No shell, command eval, environment override from the pending tool, pager,
    # credential output, auth switching or retries. Capture all failures privately.
    environment = {key: os.environ[key] for key in
                   ('HOME', 'PATH', 'USER', 'TMPDIR', 'LANG', 'GH_CONFIG_DIR',
                    'HERDR_SOCKET', 'HERDR_SESSION', 'HERDR_INSTANCE',
                    'BLUEJAY_ACCOUNTS_CONFIG') if key in os.environ}
    environment.update({'GIT_TERMINAL_PROMPT': '0', 'GH_PROMPT_DISABLED': '1',
                        'GIT_PAGER': 'cat', 'PAGER': 'cat'})
    environment['FM_HOME'] = str(cwd) if cwd else os.environ.get('FM_HOME', '')
    result = subprocess.run(args, cwd=cwd, env=environment, text=True,
                            capture_output=True, timeout=5 if args[0] == 'herdr' else 15)
    require(result.returncode == 0, 'source-unavailable')
    return result.stdout


def git(cwd, *args):
    return run(['git', '-c', 'core.fsmonitor=false', '-C', str(cwd), *args]).strip()


def account_for(repository, requested=None):
    """Reuse the nonsecret generated owner/account API used by fm-pr-lib.sh."""
    profile = Path(os.environ.get('BLUEJAY_ACCOUNTS_CONFIG',
                   str(Path.home() / 'Git/bluejay-creators/bluejay-setup/config/accounts.generated.sh')))
    info = profile.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o022, 'untrusted-account-catalog')
    script = '''
set -eu
. "$1"
account=$(bluejay_github_owner_account "$2")
login=$(bluejay_github_login "$account")
selected=$login
if [ -n "$3" ]; then
  selected=$(bluejay_github_login "$3" 2>/dev/null) || selected=$3
fi
printf '%s\\n%s\\n%s\\n' "$account" "$login" "$selected"
'''
    rows = run(['bash', '-c', script, 'prompt-account', str(profile),
                repository.split('/')[0], requested or '']).splitlines()
    require(len(rows) == 3 and all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', row) for row in rows),
            'invalid-account-catalog')
    require(rows[1] == rows[2], 'wrong-repository-account')
    return {'account': rows[0], 'login': rows[1]}


def api(endpoint, account):
    return json.loads(run(['ghx', 'run', account['account'], '--', 'api',
                          '--hostname', 'github.com', endpoint]))


def origin_repo(value):
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?', value)
    require(match is not None, 'unknown-origin')
    return match[1]


def policy_read(path):
    if path is None:
        return []
    raw = private_json(path)
    require(set(raw) == {'schema', 'grants'} and raw['schema'] == 'fm-prompt-shadow-policy.v2'
            and isinstance(raw['grants'], list), 'invalid-policy')
    for grant in raw['grants']:
        require(set(grant) == {'repository', 'cwd', 'branch', 'session_id', 'account', 'pr_author', 'evidence'}, 'invalid-grant')
        require(all(isinstance(v, str) and v and '\0' not in v for v in grant.values()), 'invalid-grant')
        require(REPO.fullmatch(grant['repository']) and Path(grant['cwd']).is_absolute()
                and BRANCH.fullmatch(grant['branch']) and not PROTECTED.fullmatch(grant['branch'])
                and '..' not in grant['branch'] and '@{' not in grant['branch'], 'invalid-grant')
        require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', grant['account'])
                and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*(?:\[bot\])?', grant['pr_author']),
                'invalid-grant-actor')
    return raw['grants']


def literal_segments(command):
    require(isinstance(command, str) and command and '\0' not in command, 'partial-command')
    # Fail closed on expansion, redirection, pipelines, scripts and separators.
    # Quoted ordinary prose may contain semicolons; shlex keeps it as data.
    require(not any(c in command for c in ('$','`','\n','\r','\\')), 'nonliteral-command')
    quote_state = None
    for index, char in enumerate(command):
        if quote_state:
            if char == quote_state:
                quote_state = None
        elif char in ('"', "'"):
            quote_state = char
        else:
            require(char not in '*?[]#{}' and not
                    (char == '~' and (index == 0 or command[index - 1].isspace()
                                      or command[index - 1] in ':=')), 'nonliteral-shell-expansion')
    lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|<>()')
    lexer.whitespace_split = True
    lexer.commenters = ''
    words = list(lexer)
    segments, current = [], []
    for word in words:
        if word == '&&':
            require(current, 'partial-command')
            segments.append(current)
            current = []
        else:
            require(not re.fullmatch(r'[;&|<>()]+', word), 'unsupported-shell-operator')
            current.append(word)
    require(current, 'partial-command')
    return segments + [current]


def options(words, values, switches=()):
    result, positionals = {}, []
    index = 0
    while index < len(words):
        word = words[index]
        if word.startswith('-'):
            key, equal, value = word.partition('=')
            require(key in values or key in switches, 'unknown-option')
            require(key not in result, 'duplicate-option')
            if key in values:
                if not equal:
                    index += 1
                    require(index < len(words), 'partial-option')
                    value = words[index]
                require(bool(value), 'partial-option')
                result[key] = value
            else:
                require(not equal, 'unknown-option')
                result[key] = True
        else:
            positionals.append(word)
        index += 1
    return result, positionals


def branch_safe(repository, branch, account):
    require(BRANCH.fullmatch(branch) and not PROTECTED.fullmatch(branch), 'protected-branch')
    metadata = api('repos/' + repository, account)
    require(metadata.get('full_name', '').lower() == repository.lower()
            and metadata.get('permissions', {}).get('push') is True, 'unverified-repository-permission')
    require(branch != metadata['default_branch'], 'protected-default-branch')
    data = api('repos/' + repository + '/branches/' + quote(branch, safe=''), account)
    require(data.get('name') == branch and data.get('protected') is False, 'protected-or-unknown-branch')


def ownership(cwd, session_id, grants, requested=None):
    matches = [g for g in grants if g['session_id'] == session_id and Path(g['cwd']).resolve() == cwd]
    require(len(matches) == 1, 'missing-origin-ownership-grant')
    grant = matches[0]
    account = account_for(grant['repository'], requested or grant['account'])
    require(account_for(grant['repository'], grant['account']) == account, 'grant-account-mismatch')
    require(git(cwd, 'rev-parse', '--show-toplevel') == str(cwd), 'not-task-worktree')
    require(git(cwd, 'branch', '--show-current') == grant['branch'], 'not-owned-branch')
    urls = git(cwd, 'remote', 'get-url', '--push', '--all', 'origin').splitlines()
    require(len(urls) == 1 and origin_repo(urls[0]).lower() == grant['repository'].lower(), 'origin-grant-mismatch')
    branch_safe(grant['repository'], grant['branch'], account)
    return grant, account


def git_read(words, cwd):
    """Finite read grammar: never config, output files, helpers or textconv."""
    require(words, 'partial-git-command')
    verb, rest = words[0], words[1:]
    if verb == 'status':
        require(all(word in {'--short', '--branch', '--porcelain', '--porcelain=v1', '--porcelain=v2',
                             '--untracked-files=no', '--untracked-files=all'} for word in rest),
                'unknown-status-option')
        return True
    elif verb == 'log':
        flags, args = options(rest, {'--max-count', '-n', '--since', '--until', '--author', '--format', '--pretty'},
                              {'--oneline', '--graph', '--all', '--decorate', '--no-decorate',
                               '--stat', '--name-only', '--no-color'} |
                              {w for w in rest if re.fullmatch(r'-[1-9][0-9]{0,3}', w)})
    elif verb in ('diff', 'show'):
        flags, args = options(rest, {'--format'}, {'--stat', '--numstat', '--name-only', '--name-status', '--check',
                                                 '--cached', '--staged', '--exit-code', '--quiet', '--no-patch',
                                                 '--summary', '--no-ext-diff', '--no-textconv', '--no-color'})
        require(any(key in flags for key in ('--stat', '--numstat', '--name-only', '--name-status', '--check',
                                             '--no-patch', '--summary'))
                or ('--no-ext-diff' in flags and '--no-textconv' in flags), 'unsafe-diff-helpers')
    elif verb == 'rev-parse':
        flags, args = options(rest, set(), {'--show-toplevel', '--git-dir', '--show-prefix',
                                           '--is-inside-work-tree', '--abbrev-ref', '--verify', '--short'})
        require(flags or args, 'partial-git-read')
    elif verb == 'branch':
        flags, args = options(rest, set(), {'--show-current', '--list', '--all', '--remotes',
                                           '-a', '-r', '-v', '-vv', '--no-color'})
        require(not args, 'branch-mutation')
    elif verb == 'ls-files':
        flags, args = options(rest, set(), {'--cached', '--others', '--exclude-standard',
                                           '--modified', '--deleted', '--stage', '-s', '-z'})
        require(not args, 'unknown-file-selector')
    elif verb == 'remote':
        require(rest[:1] == ['get-url'], 'unknown-remote-read')
        _, args = options(rest[1:], set(), {'--push', '--all'})
        require(args == ['origin'], 'unknown-origin-read')
        for url in git(cwd, 'remote', 'get-url', '--all', 'origin').splitlines():
            origin_repo(url)
        return True
    else:
        return False
    if verb in ('log', 'diff', 'show', 'rev-parse'):
        require(all(all(re.fullmatch(r'(?:HEAD(?:[~^][0-9]*)?|[A-Za-z0-9][A-Za-z0-9._/-]*)', part)
                        for part in re.split(r'\.\.\.?', arg))
                    and not re.search(r'credential|secret|password|token|\.env|\.pem|\.key', arg, re.IGNORECASE)
                    for arg in args), 'unknown-or-sensitive-revision')
    else:
        require(not args, 'unknown-git-read-arguments')
    for key in ('--max-count', '-n'):
        require(key not in flags or re.fullmatch(r'[1-9][0-9]{0,4}', flags[key]), 'invalid-read-limit')
    for key in ('--format', '--pretty'):
        if key in flags:
            require((key == '--pretty' and flags[key] in ('oneline', 'short', 'medium', 'full', 'fuller'))
                    or re.fullmatch(r'(?:[^%]|%(?:H|h|s|an|ae|ad|aI|cn|ce|cd|cI|D|d|b|B|n|%))*', flags[key]),
                    'unsafe-git-format')
    return True


def bd_read(words):
    # Never SQL, config, credential data sources, alternate stores or output files.
    words = [word for word in words if word not in ('--readonly', '--sandbox', '--no-daemon')]
    require(words, 'partial-board-command')
    verb = words[0]
    require(verb in ('show', 'list', 'ready', 'status', 'stats', 'search', 'export'), 'unknown-board-action')
    values = {'--status', '--assignee', '--label', '--limit', '-n', '--priority', '--type', '--format'}
    flags, args = options(words[1:], values, {'--json', '--all', '--long', '--pretty'})
    require('--format' not in flags or flags['--format'] in ('json', 'jsonl'), 'unknown-board-format')
    require(all(not any(char in value for char in '/\\\\') for value in flags.values() if isinstance(value, str)),
            'unknown-board-selector')
    if verb == 'show':
        require(args and all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', arg) for arg in args), 'invalid-board-id')
    elif verb == 'search':
        require(len(args) == 1, 'invalid-board-query')
    else:
        require(not args, 'board-output-or-store-selector')
    return True


def forge_words(words):
    if words[0] == 'gh':
        return words[1:], None
    require(words[:2] == ['ghx', 'run'] and len(words) >= 4, 'unknown-forge-wrapper')
    requested = words[2]
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', requested), 'invalid-forge-account')
    rest = words[3:]
    if rest[:1] == ['--']:
        rest = rest[1:]
    require(rest, 'partial-forge-command')
    return rest, requested


def read_account(repository, requested):
    require(REPO.fullmatch(repository), 'invalid-read-repository')
    account = account_for(repository, requested)
    if requested is None:
        status = json.loads(run(['ghx', 'status', '--json']))
        require(status.get('active') == account['login'], 'unscoped-read-account-mismatch')
    return account


def forge_read(words, cwd, requested):
    """No --web, --jq, templates, downloads, fields/input, auth or config verbs."""
    if words[:1] == ['api']:
        flags, args = options(words[1:], {'--method', '-X', '--hostname'}, {'--paginate', '--slurp'})
        require(not ('--method' in flags and '-X' in flags)
                and flags.get('--method', flags.get('-X', 'GET')) == 'GET', 'non-get-api')
        require(flags.get('--hostname', 'github.com') == 'github.com'
                and len(args) == 1, 'unknown-api-host-or-endpoint')
        match = re.fullmatch(r'repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)'
                            r'(?:/(?:pulls|issues|branches|commits|actions/runs)'
                            r'(?:/[A-Za-z0-9._/-]+)*)?(?:\?[A-Za-z0-9_=&%.-]+)?', args[0])
        require(match is not None and '..' not in args[0], 'unknown-api-read-scope')
        read_account(match[1], requested)
        return True
    require(len(words) >= 2, 'partial-forge-command')
    pair = tuple(words[:2])
    verbs = {('pr', 'view'), ('pr', 'list'), ('pr', 'checks'), ('pr', 'diff'),
             ('issue', 'view'), ('issue', 'list'), ('run', 'view'), ('run', 'list'), ('repo', 'view')}
    if pair not in verbs:
        return False
    values = {'--repo', '-R', '--json'}
    switches = set()
    if pair[1] == 'list':
        values |= {'--limit', '-L', '--state', '--author', '--assignee', '--label', '--base', '--head',
                   '--branch', '--workflow', '--status', '--event'}
        switches |= {'--all'}
    if pair in (('pr', 'view'), ('issue', 'view')):
        switches |= {'--comments'}
    if pair == ('pr', 'checks'):
        switches |= {'--required'}
    if pair == ('pr', 'diff'):
        switches |= {'--stat', '--name-only', '--patch'}
    if pair == ('run', 'view'):
        values |= {'--job'}
        switches |= {'--log', '--log-failed', '--verbose', '--exit-status'}
    flags, args = options(words[2:], values, switches)
    require(not ('--repo' in flags and '-R' in flags), 'duplicate-option')
    require('--json' not in flags or re.fullmatch(r'[A-Za-z][A-Za-z0-9,]*', flags['--json']), 'invalid-read-fields')
    repository = flags.get('--repo', flags.get('-R'))
    if pair == ('repo', 'view'):
        require(repository is None and len(args) <= 1, 'unknown-repository-selector')
        repository = args[0] if args else None
    else:
        require(len(args) <= (0 if pair[1] == 'list' else 1)
                and all(arg.isdigit() for arg in args), 'unknown-read-target')
    if repository is None:
        repository = origin_repo(git(cwd, 'remote', 'get-url', 'origin'))
    read_account(repository, requested)
    return True


def classify(command, cwd, session_id, grants):
    tier = 0
    for words in literal_segments(command):
        if words[0] == 'cd':
            require(len(words) == 2 and Path(words[1]).is_absolute(), 'unknown-directory')
            cwd = Path(words[1]).resolve()
            continue
        if words in (['pwd'], ['date'], ['date', '-u']):
            continue
        if words[0] == 'bd':
            bd_read(words[1:])
            continue
        if words[0] == 'git':
            words = words[1:]
            if words[:1] == ['--no-pager']:
                words = words[1:]
            if words[:1] == ['-C']:
                require(len(words) >= 3 and Path(words[1]).is_absolute(), 'unknown-directory')
                cwd, words = Path(words[1]).resolve(), words[2:]
            if git_read(words, cwd):
                continue
            require(words[:1] == ['push'], 'unknown-git-action')
            flags, args = options(words[1:], set(), {'-u', '--set-upstream', '--force-with-lease'})
            grant, account = ownership(cwd, session_id, grants)
            branch = grant['branch']
            require(args in (['origin', branch], ['origin', 'HEAD:' + branch],
                             ['origin', branch + ':' + branch]), 'not-own-origin-push')
            if '--force-with-lease' in flags:
                rows = api('repos/' + grant['repository'] + '/pulls?state=all&head=' +
                           quote(grant['repository'].split('/')[0] + ':' + branch, safe=''), account)
                require(isinstance(rows, list) and len(rows) == 1 and rows[0]['state'] == 'open'
                        and rows[0].get('merged_at') is None, 'not-exclusive-unmerged-pr')
                pr_owned(rows[0], grant)
            tier = 1
            continue
        words, requested = forge_words(words)
        if forge_read(words, cwd, requested):
            continue
        require(requested is not None, 'unscoped-forge-write')
        require(words[:1] == ['pr'] and len(words) >= 2, 'unknown-action')
        action = words[1]
        require(action in ('create', 'edit', 'comment'), 'unknown-pr-action')
        grant, account = ownership(cwd, session_id, grants, requested)
        allowed = {'--repo', '-R', '--body', '-b'}
        if action in ('create', 'edit'):
            allowed |= {'--title', '-t', '--base', '-B'}
        if action == 'create':
            allowed |= {'--head', '-H'}
        flags, args = options(words[2:], allowed, {'--draft'} if action == 'create' else set())
        # Equivalent aliases cannot smuggle two inconsistent scopes.
        for a, b in (('--repo','-R'), ('--base','-B'), ('--head','-H'), ('--title','-t'), ('--body','-b')):
            require(not (a in flags and b in flags), 'duplicate-option')
        for key in ('--title', '-t', '--body', '-b'):
            if key in flags:
                require(not re.search(r'password|credential|secret|private[ -]key|'
                                      r'gh[pousr]_|github_pat_|xox[baprs]-|\bAKIA',
                                      flags[key], re.IGNORECASE),
                        'credential-sensitive-payload')
        repo = flags.get('--repo', flags.get('-R'))
        require(repo is not None and repo.lower() == grant['repository'].lower(), 'explicit-origin-repo-required')
        if action == 'create':
            require(not args, 'unexpected-pr-target')
            require(flags.get('--head', flags.get('-H')) == grant['branch'], 'explicit-owned-head-required')
            base = flags.get('--base', flags.get('-B'))
            require(base is not None, 'explicit-base-required')
        else:
            require(len(args) == 1 and args[0].isdigit(), 'explicit-pr-number-required')
            pr = api('repos/' + repo + '/pulls/' + args[0], account)
            pr_owned(pr, grant)
            base = flags.get('--base', flags.get('-B', pr['base']['ref']))
            require(pr['state'] == 'open' and pr.get('merged_at') is None, 'closed-pr')
            branch_safe(repo, pr['base']['ref'], account)
            require(api('repos/' + repo + '/pulls/' + args[0], account) == pr, 'changed-pr-facts')
        branch_safe(repo, base, account)
        tier = 1
    return tier, 'verified-read-only' if tier == 0 else 'verified-own-origin-action'


def pr_owned(pr, grant):
    repository = grant['repository'].lower()
    require(pr['head']['repo'] is not None and pr['head']['repo']['full_name'].lower() == repository
            and pr['base']['repo']['full_name'].lower() == repository
            and pr['head']['ref'] == grant['branch'], 'pr-repo-head-mismatch')
    require(pr['user']['login'].lower() == grant['pr_author'].lower(), 'not-own-pr')


def prompt_visible(text):
    # Same all-workspace rendered detection as Inbox tab-prompts.py.
    # This detects presence; rendered_request separately binds full command bytes.
    clean = [line.strip().strip('│┃').strip() for line in text.splitlines()[-30:]]
    choices = {line.lstrip('❯').strip() for line in clean}
    return any('approve' in line.lower() and 'deny' in line.lower() for line in clean) or (
        'Allow once' in choices and any('navigate' in line and 'select' in line for line in clean))


def rendered_request(text, command):
    clean = [line.strip().strip('│┃').strip() for line in text.splitlines()]
    headers = [i for i, line in enumerate(clean) if line == 'Allow tool: bash']
    require(headers and isinstance(command, str) and command, 'missing-final-display')
    block = clean[headers[-1]:]
    commands = [line for line in block if line.startswith('Command:')]
    require(commands == ['Command: ' + command] and not any('elided' in line for line in block),
            'partial-or-changed-final-display')
    require(prompt_visible('\n'.join(block)), 'missing-final-choices')
    return '\n'.join(block)


def panes_read():
    require(os.environ.get('HERDR_ENV') == '1', 'herdr-context-required')
    workspaces = json.loads(run(['herdr', 'workspace', 'list']))['result']['workspaces']
    panes = []
    for workspace in workspaces:
        panes.extend(json.loads(run(['herdr', 'pane', 'list', '--workspace', workspace['workspace_id']]))['result']['panes'])
    return panes


def session_read(path):
    session_id, session_cwd, calls, ended = None, None, {}, set()
    with path.open() as stream:
        for index, line in enumerate(stream, 1):
            try:
                row = json.loads(line)
            except ValueError:
                raise Unsafe('partial-session-record') from None
            if row.get('type') == 'session':
                session_id = row.get('id')
                session_cwd = row.get('cwd')
            message = row.get('message', {})
            if message.get('role') == 'toolResult':
                ended.add(message.get('toolCallId'))
            if message.get('role') == 'assistant':
                for item in message.get('content', []):
                    if item.get('type') == 'toolCall':
                        observed = row.get('timestamp') or message.get('timestamp')
                        if isinstance(observed, (int, float)):
                            observed = stamp(observed / 1000 if observed > 100000000000 else observed)
                        calls[item.get('id')] = ({**item, '_observed_at': observed, '_session_cwd': session_cwd}, index)
    require(isinstance(session_id, str) and session_id, 'missing-session-identity')
    return session_id, calls, ended


def snapshots_read(homes):
    values = {}
    for home in homes:
        root = home / 'state/captain-asks/omp'
        for location in ('pending', 'outbox', 'handled'):
            for path in sorted((root / location).glob('*.json')):
                raw = private_json(path)
                request = {key: value for key, value in raw.get('request', raw).items() if key != 'resolution'}
                require(request.get('schema') == 'firstmate.omp-approval.v1', 'unknown-native-snapshot')
                key = (request['sessionId'], request['approvalId'])
                previous = values.get(key)
                if previous:
                    if previous[0] != request:
                        request = {**request, '_invalid': True}
                resolution = raw.get('resolution') or (previous[2] if previous else None)
                values[key] = (request, str(path), resolution)
    return values


def evaluate(request, session_id, calls, ended, grants, now):
    require(not request.get('_invalid'), 'changed-native-prompt')
    require(request.get('sessionId') == session_id, 'session-mismatch')
    call_id = request.get('toolCallId')
    require(call_id in calls and call_id not in ended, 'stale-or-missing-tool-call')
    tool = calls[call_id][0]
    arguments = tool.get('arguments', {})
    require(not set(arguments) - {'command', 'timeout', 'cwd', 'env', 'async', 'pty', 'name', 'ready', 'i'}
            and arguments.get('env') in (None, {}) and not arguments.get('pty')
            and not arguments.get('name') and not arguments.get('ready'),
            'unverified-tool-execution-context')
    require(request.get('approvalKind') == 'tool' and request.get('toolName') == 'bash'
            and tool.get('name') == 'bash', 'nonbash-or-settings-consent')
    command = request.get('command')
    require(isinstance(command, str) and command and command == tool.get('arguments', {}).get('command'), 'changed-or-partial-command')
    require(isinstance(request.get('prompt'), str) and request['prompt']
            and isinstance(request.get('choices'), list) and len(request['choices']) >= 2,
            'partial-native-prompt')
    requested = epoch(request['requestedAt'])
    require(requested <= now + 5, 'future-prompt')
    require(now - requested <= 120, 'stale-prompt')
    cwd = request.get('commandCwd') or request['origin']['cwd']
    require(Path(cwd).is_absolute(), 'unknown-directory')
    tool_cwd = tool.get('arguments', {}).get('cwd') or tool.get('_session_cwd')
    require(tool_cwd is not None and Path(tool_cwd).resolve() == Path(cwd).resolve(), 'changed-directory')
    return classify(command, Path(cwd).resolve(), session_id, grants)


def route(finding, home, source, board):
    # Board is the existing module, not another fleet/backlog system. Redacted
    # cards send humans to the exact private source/native UI; never serialize
    # secret-bearing command/prompt bytes into a card or log.
    key = finding['finding_id']
    bead = 'prompt-' + key[:24]
    title = 'Shadow: inspect pending OMP permission request'
    detail = ('SHADOW ONLY; do not approve automatically. Session ' + finding['session_id'] +
              '; native prompt ' + finding['prompt_id'] + '; reason ' + finding['reason'] +
              '; command SHA256 ' + finding['command_sha256'] +
              '; private source ' + source + '. Act only in the original tab after reading the full command.')
    if not finding.get('card_id'):
        prefix = board.call('config', 'get', 'issue_prefix').strip()
        require(re.fullmatch(r'[A-Za-z0-9_-]+', prefix), 'invalid-board-prefix')
        bead = prefix + '-' + bead
        # Deterministic id is crash/retry safe. Validate pre-existing ownership.
        row = board.lookup(bead)
        if row is None:
            board.call('create', '--id', bead, '--title', title, '--type', 'task',
                       '--assignee', 'captain', '--labels', 'captain,firstmate-ask,omp-approval',
                       '--priority', '1', '--description', detail, '--metadata',
                       json.dumps({'promptShadow': key}), '--json')
            row = board.lookup(bead)
        require(row is not None and row.get('metadata', {}).get('promptShadow') == key, 'card-identity-mismatch')
        finding.update(card_id=bead, card_filed_at=finding['observed_at'])
    output = json.loads(run(['bash', str(Path(__file__).with_name('fm-inbox.sh')), 'note',
                             '--request-id', 'prompt-card-' + key, '--json', '--',
                             'Shadow OMP card requires Inbox review: ' + finding['card_id'] +
                             '; decision ' + finding['decision'] + '; reason ' + finding['reason'] +
                             '. Full command remains in the original tab/private source.'], cwd=home))
    finding['inbox_request_id'] = output.get('id') or 'prompt-card-' + key
    if finding['page_due'] and not finding.get('page_request_id'):
        configured = home / 'config/phone-notify'
        require(configured.is_file(), 'phone-route-unconfigured')
        executable = configured.read_text().strip()
        require(re.fullmatch(r'[A-Za-z0-9_.-]+', executable) and not executable.startswith('-'),
                'phone-route-invalid')
        run([executable, '--batch-id', key, 'urgent'])
        output = json.loads(run(['bash', str(Path(__file__).with_name('fm-inbox.sh')), 'note',
                                 '--request-id', 'prompt-page-' + key, '--json', '--',
                                 'PHONE PAGE SENT or bridge-deduplicated: OMP prompt pending >10 minutes. Card ' +
                                 finding['card_id'] + '; session ' + finding['session_id'] +
                                 '. No permission action has been taken.'], cwd=home))
        finding['page_request_id'] = output.get('id') or 'prompt-page-' + key


def scan(homes, grants, previous, now, routing=False):
    snapshots = snapshots_read(homes)
    findings, seen, candidates = [], set(), []
    # Collect EVERY pending pane before forge metadata work. In shadow routing,
    # every detected permission gets its manual-review card immediately, rather
    # than allowing a slow classifier to delay another agent's stall card.
    for pane in panes_read():
        if pane.get('agent') != 'omp' and pane.get('agent_status') != 'blocked':
            continue
        pane_id = pane['pane_id']
        ref = pane.get('agent_session', {})
        session_path = Path(ref.get('value', '/unbound-session'))
        session_id, calls, ended, source_error = 'unbound-' + digest(pane_id), {}, set(), None
        try:
            rendered = run(['herdr', 'pane', 'read', pane_id, '--source', 'visible'])
            if not prompt_visible(rendered):
                continue
            require(ref.get('kind') == 'path' and session_path.is_absolute(), 'missing-herdr-session')
            session_id, calls, ended = session_read(session_path)
        except (OSError, Unsafe, ValueError, TypeError, subprocess.TimeoutExpired):
            source_error = 'unreadable-herdr-session'
        native = [(r, source, resolution) for (sid, _), (r, source, resolution) in snapshots.items()
                  if sid == session_id and not resolution]
        if not native:
            pending = [(cid, value) for cid, value in calls.items() if cid not in ended]
            cid, (tool, line) = pending[0] if len(pending) == 1 else ('unknown', ({}, 0))
            command = tool.get('arguments', {}).get('command', '')
            request = {'sessionId': session_id, 'approvalId': 'rendered-' + digest(session_id + cid),
                       'toolCallId': cid, 'command': command,
                       'requestedAt': tool.get('_observed_at') or stamp(now)}
            try:
                prompt = rendered_request(rendered, command)
                request.update(approvalKind='tool', toolName='bash', prompt=prompt,
                               choices=['Approve', 'Deny'], origin={'cwd': tool.get('_session_cwd')},
                               commandCwd=tool.get('arguments', {}).get('cwd'), _rendered=True)
            except Unsafe:
                pass
            native = [(request, str(session_path) + ':' + str(line), None)]
        for request, source, _ in native:
            command = request.get('command', '')
            key = digest(json.dumps([session_id, request.get('toolCallId'), request['approvalId'], digest(command)]))
            old = previous.get(key, {})
            first = min(epoch(old.get('first_seen_at', request['requestedAt'])), now)
            finding = {**old, 'schema': SCHEMA, 'finding_id': key, 'session_id': session_id,
                       'tool_call_id': request.get('toolCallId', 'unknown'), 'prompt_id': request['approvalId'],
                       'command_sha256': digest(command), 'prompt_sha256': digest(request.get('prompt', '')),
                       'command_source': source, 'session_source': str(session_path),
                       'first_seen_at': stamp(first), 'observed_at': stamp(now), 'status': 'pending',
                       'decision': 'would-card', 'verified_tier': None, 'reason': 'classification-pending',
                       'stall_card_due': now - first >= 120, 'page_due': now - first > 600}
            if routing:
                route_finding(finding, homes[0])
            candidates.append((pane, request, calls, ended, source_error, old, len(native), finding))
            seen.add(key)
            findings.append(finding)
    for pane, request, calls, ended, source_error, old, native_count, finding in candidates:
        tier = None
        try:
            require(source_error is None, 'unreadable-herdr-session')
            require(pane.get('agent_status') == 'blocked', 'herdr-not-pending')
            require(native_count == 1, 'ambiguous-native-prompts')
            require(sum(other['session_id'] == finding['session_id']
                        and other['tool_call_id'] == finding['tool_call_id'] for other in findings) == 1,
                    'ambiguous-session-binding')
            require(time.time() - epoch(finding['first_seen_at']) <= 120, 'stale-prompt')
            require(not old or old.get('prompt_sha256') == finding['prompt_sha256'], 'changed-prompt-identity')
            require(old.get('status') != 'resolved', 'terminal-prompt-reused')
            require(not any(p.get('session_id') == finding['session_id']
                            and p.get('prompt_id') == finding['prompt_id']
                            and p['finding_id'] != finding['finding_id'] for p in previous.values()),
                    'changed-prompt-identity')
            tier, reason = evaluate(request, finding['session_id'], calls, ended, grants, time.time())
            current = json.loads(run(['herdr', 'pane', 'get', pane['pane_id']]))['result']['pane']
            require(current.get('agent_session') == pane.get('agent_session')
                    and current.get('agent_status') == 'blocked', 'changed-herdr-prompt')
            rendered = run(['herdr', 'pane', 'read', pane['pane_id'], '--source', 'visible'])
            display = rendered_request(rendered, request['command'])
            fresh_session, fresh_calls, fresh_ended = session_read(Path(finding['session_source']))
            require(fresh_session == finding['session_id'] and request.get('toolCallId') not in fresh_ended
                    and fresh_calls.get(request.get('toolCallId')) == calls.get(request.get('toolCallId')),
                    'stale-or-changed-tool-call')
            if request.get('_rendered'):
                require(display == request['prompt'], 'changed-final-display')
            else:
                native_body = '\n'.join(line.strip().strip('│┃').strip() for line in request['prompt'].splitlines())
                require(display == native_body or display.startswith(native_body + '\n'), 'changed-native-display')
                fresh = snapshots_read(homes).get((finding['session_id'], request['approvalId']))
                require(fresh is not None and fresh[0] == request and not fresh[2], 'changed-native-prompt')
            require(time.time() - epoch(finding['first_seen_at']) <= 120, 'stale-prompt')
        except (OSError, Unsafe, KeyError, TypeError, ValueError, subprocess.TimeoutExpired) as error:
            tier = None
            reason = str(error) if isinstance(error, Unsafe) else 'unverifiable-source'
        finding.update(decision='would-approve' if tier is not None else 'would-card',
                       verified_tier=tier, reason=reason)
    # A vanished pane is NOT proof of permission resolution. Only a terminal
    # native event or the exact session's matching tool result resolves it.
    for key, old in previous.items():
        if key in seen or old.get('status') == 'resolved':
            continue
        terminal = snapshots.get((old['session_id'], old['prompt_id']))
        tool_ended = False
        if old.get('session_source'):
            try:
                sid, _, completed = session_read(Path(old['session_source']))
                tool_ended = sid == old['session_id'] and old['tool_call_id'] in completed
            except (OSError, Unsafe):
                pass
        if (terminal and terminal[2]) or tool_ended:
            findings.append({**old, 'status': 'resolved', 'observed_at': stamp(now),
                             'reason': ('native-' + terminal[2]['kind'] if terminal and terminal[2]
                                        else 'tool-result-observed'),
                             'stall_card_due': False, 'page_due': False})
        else:
            finding = {**old, 'observed_at': stamp(now), 'decision': 'would-card',
                       'verified_tier': None, 'reason': 'pending-source-disappeared',
                       'stall_card_due': now - epoch(old['first_seen_at']) >= 120,
                       'page_due': now - epoch(old['first_seen_at']) > 600}
            if routing:
                route_finding(finding, homes[0])
            findings.append(finding)
    return findings


def route_finding(finding, home):
    try:
        spec = importlib.util.spec_from_file_location('approval_board', Path(__file__).with_name('fm-approval-prompt.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        route(finding, home, finding['command_source'], module.Board(home))
        finding.pop('routing_error', None)
    except Exception:
        # Preserve the finding and any card readback even if notification fails.
        # The next observation retries the same id, never creates another card.
        finding['routing_error'] = 'card-or-page-route-unavailable'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, action='append', required=True)
    parser.add_argument('--policy', type=Path)
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--route', action='store_true')
    parser.add_argument('--watch', action='store_true')
    args = parser.parse_args()
    require(not (args.route or args.watch) or args.state_dir is not None, 'durable-state-required')
    os.umask(0o077)
    with contextlib.ExitStack() as stack:
        state_file = None
        if args.state_dir:
            args.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            info = args.state_dir.lstat()
            require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077, 'private-state-required')
            lock = stack.enter_context(open(args.state_dir / 'lock', 'a'))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state_file = args.state_dir / 'findings.json'
        while True:
            previous = private_json(state_file) if state_file and state_file.exists() else {}
            findings = scan([p.resolve() for p in args.home], policy_read(args.policy), previous, time.time(), args.route)
            if state_file:
                previous.update({f['finding_id']: f for f in findings})
                fd, temporary = tempfile.mkstemp(dir=args.state_dir)
                with os.fdopen(fd, 'w') as stream:
                    json.dump(previous, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, state_file)
            for finding in findings:
                print(json.dumps(finding, sort_keys=True), flush=True)
            if not args.watch:
                return
            time.sleep(20)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never echo raw JSON, shell input, paths from failed subprocess output,
        # credentials or prompt fragments through exception interpolation.
        print('fm-prompt-shadow: observation failed; pending state is NOT resolved', file=sys.stderr)
        sys.exit(1)
