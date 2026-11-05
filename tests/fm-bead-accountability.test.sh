#!/usr/bin/env bash
# Behavioral contract for board ownership, graph and ETA accountability.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "$ROOT" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import fcntl
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(sys.argv.pop(1)) / 'bin'))
from fm_bead_accountability import analyze, check, slip_commitments

NOW = datetime(2026, 10, 29, 22, tzinfo=timezone.utc)
OLD = '2026-10-29T20:00:00+00:00'
PAST = '2026-10-29T21:00:00+00:00'
FUTURE = '2026-10-29T23:00:00+00:00'


def issue(name, **fields):
    row = dict(id=name, status='open', assignee='worker', issue_type='task', created_at=OLD,
               updated_at=OLD, labels=[], dependencies=[], metadata={})
    row.update(fields)
    return row


def inspect(rows, ready=(), previous=None):
    return analyze({row['id']: row for row in rows}, set(ready), NOW,
                   {'task': 30}, previous or {})


class Accountability(unittest.TestCase):
    def test_assignee_is_the_only_owner_not_creator_or_an_owner_list(self):
        rows = [issue('creator', assignee='', owner='creator'),
                issue('many', assignee='one,two'),
                issue('list', assignee=['one', 'two']),
                issue('single', assignee='worker')]
        findings, _ = inspect(rows)
        self.assertEqual({f['id'] for f in findings if f['kind'] == 'owner'},
                         {'creator', 'many', 'list'})

    def test_dependency_cycle_is_real_and_closed_dependencies_do_not_block(self):
        rows = [issue('a', dependencies=[dict(type='blocks', depends_on_id='b')]),
                issue('b', dependencies=[dict(type='waits-for', depends_on_id='a')]),
                issue('closed', status='closed', dependencies=[dict(type='blocks', depends_on_id='a')]),
                issue('waiting', status='blocked', dependencies=[dict(type='blocks', depends_on_id='closed')])]
        findings, _ = inspect(rows)
        self.assertEqual([f['detail'] for f in findings if f['kind'] == 'cycle'], ['a -> b -> a'])
        self.assertEqual([f['id'] for f in findings if f['kind'] == 'blocker'], ['waiting'])

    def test_deep_acyclic_chain_does_not_overflow(self):
        rows = [issue(str(n), dependencies=[dict(type='blocks', depends_on_id=str(n + 1))])
                for n in range(2500)]
        rows.append(issue('2500'))
        findings, _ = inspect(rows)
        self.assertFalse(any(f['kind'] == 'cycle' for f in findings))

    def test_explicit_waits_are_not_ready_or_overdue_dispatch_candidates(self):
        rows = [issue(label, labels=[label], metadata=dict(eta=PAST, etaby='worker'))
                for label in ('parked', 'deferred', 'deprioritized', 'snoozed', 'consolidation')]
        rows += [issue('date', defer_until=FUTURE, metadata=dict(eta=PAST, etaby='worker')),
                 issue('external', status='blocked', metadata=dict(
                     eta=PAST, etaby='worker', wait=dict(kind='external', reason='published result pending'))),
                 issue('status', status='deferred', metadata=dict(eta=PAST, etaby='worker'))]
        findings, observed = inspect(rows, [row['id'] for row in rows])
        self.assertEqual(findings, [])
        self.assertEqual(observed, {})

    def test_nullable_eta_does_not_reactivate_retained_owner_history(self):
        history = [dict(eta=FUTURE, etaby='worker',
                        previous=dict(eta=PAST, etaby='worker'),
                        recorded_at=NOW.isoformat(), reason='Owner-authored revision')]
        rows = [
            issue('cleared-deferred', status='deferred',
                  metadata=dict(eta=None, etaby='worker', eta_history=history)),
            issue('absent-parked', labels=['parked'],
                  metadata=dict(etaby='worker', eta_history=history)),
            issue('malformed-parked', labels=['parked'],
                  metadata=dict(eta='not-a-timestamp', etaby='worker')),
        ]
        findings, observed = inspect(rows, [row['id'] for row in rows])
        self.assertEqual([(f['kind'], f['id']) for f in findings],
                         [('invalid', 'malformed-parked')])
        self.assertEqual(observed, {})

    def test_undated_explicit_approval_is_not_a_dated_person_follow_up(self):
        rows = [
            issue('approval-null', status='blocked', labels=['waiting'], metadata=dict(
                eta=None, etaby='worker', waitingon='operator',
                wait=dict(kind='approval', reason='Await scope decision; no deadline imposed'))),
            issue('approval-absent', status='blocked', labels=['waiting'], metadata=dict(
                etaby='worker', waitingon='operator',
                wait=dict(kind='approval', reason='Await scope decision; no deadline imposed'))),
            issue('malformed-eta', status='blocked', labels=['waiting'], metadata=dict(
                eta='not-a-timestamp', etaby='worker', waitingon='operator',
                wait=dict(kind='approval', reason='Await scope decision'))),
            issue('malformed-date', status='blocked', labels=['waiting'], due_at='not-a-timestamp',
                  metadata=dict(waitingon='operator', wait=dict(kind='approval', reason='Await scope decision'))),
        ]
        findings, observed = inspect(rows, [row['id'] for row in rows])
        self.assertEqual({f['id'] for f in findings if f['kind'] == 'invalid'},
                         {'malformed-eta', 'malformed-date'})
        self.assertFalse(any(f['kind'] in ('follow-up', 'overdue', 'stalled-ready') for f in findings))
        self.assertEqual(observed, {})

    def test_expired_or_unnamed_wait_is_not_a_permanent_suppression(self):
        rows = [issue('expired', status='blocked', metadata=dict(wait=dict(
                    kind='external', reason='result pending', until=PAST))),
                issue('unnamed', status='blocked', metadata=dict(wait=dict(kind='external'))),
                issue('dependency', status='blocked', dependencies=[dict(type='blocks', depends_on_id='live')]),
                issue('live', status='in_progress')]
        findings, _ = inspect(rows)
        self.assertEqual({f['id'] for f in findings if f['kind'] == 'blocker'}, {'expired', 'unnamed'})

    def test_deadline_is_not_reset_by_status_notes_or_recent_board_updates(self):
        row = issue('late', status='in_progress', updated_at=NOW.isoformat(),
                    metadata=dict(eta=PAST, etaby='worker'))
        findings, _ = inspect([row])
        self.assertEqual([f['kind'] for f in findings], ['overdue'])
        self.assertEqual(findings[0]['commitment'], dict(eta=PAST, etaby='worker'))

    def test_ready_age_survives_unrelated_metadata_edits(self):
        row = issue('ready', updated_at=NOW.isoformat())
        findings, observed = inspect([row], ['ready'], {'ready': OLD})
        self.assertEqual([f['kind'] for f in findings], ['stalled-ready'])
        self.assertEqual(observed, {'ready': OLD})
        quiet, removed = inspect([issue('ready', status='in_progress')], (), observed)
        self.assertEqual(quiet, [])
        self.assertEqual(removed, {})

    def test_wrong_committing_owner_and_malformed_metadata_are_reported(self):
        rows = [issue('wrong', metadata=dict(eta=PAST, etaby='someone-else')),
                issue('missing-author', assignee='', metadata=dict(eta=PAST)),
                issue('malformed', metadata='invalid'),
                issue('naive', metadata=dict(eta='2026-10-29T21:00:00', etaby='worker'))]
        findings, _ = inspect(rows)
        self.assertEqual({f['id'] for f in findings if f['kind'] == 'invalid'},
                         {'wrong', 'missing-author', 'malformed', 'naive'})

    def test_revised_deadline_preserves_the_same_missed_commitment_identity(self):
        original = dict(eta=PAST, etaby='worker')
        row = issue('slip', metadata=dict(eta=FUTURE, etaby='worker', eta_history=[dict(
            eta=FUTURE, etaby='worker', previous=original, recorded_at=NOW.isoformat(),
            reason='Owner-authored explanation')]))
        self.assertEqual(slip_commitments(row, NOW), [original])
        early = issue('early', metadata=dict(eta=FUTURE, etaby='worker', eta_history=[dict(
            eta=FUTURE, etaby='worker', previous=dict(eta=FUTURE, etaby='worker'),
            recorded_at=NOW.isoformat(), reason='Rescheduled before deadline')]))
        self.assertEqual(slip_commitments(early, NOW), [])

    def test_named_person_wait_is_idle_until_due_or_a_positive_reply(self):
        row = issue('person', status='blocked', labels=['waiting'], due_at=FUTURE,
                    updated_at=NOW.isoformat(), metadata=dict(
                        waitingon='reviewer', eta=PAST, etaby='worker'))
        self.assertEqual(inspect([row], ['person']), ([], {}))
        row['metadata']['waiting_reply'] = dict(id='inbox-reply-1', waitingon='reviewer', due_at=FUTURE)
        findings, observed = inspect([row], ['person'])
        self.assertEqual([f['kind'] for f in findings], ['follow-up'])
        self.assertEqual(observed, {})

    def test_person_wait_becomes_actionable_at_the_exact_follow_up_boundary(self):
        row = issue('person', status='blocked', labels=['waiting'], due_at=FUTURE,
                    metadata=dict(waitingon='reviewer'))
        at_due = datetime.fromisoformat(FUTURE)
        due, _ = analyze({'person': row}, set(), at_due, {}, {})
        self.assertEqual([f['kind'] for f in due], ['follow-up'])

    def test_reply_does_not_override_an_explicit_consolidation_stop(self):
        row = issue('person', status='blocked', labels=['waiting', 'consolidation'],
                    due_at=PAST, metadata=dict(waitingon='reviewer',
                                              waiting_reply=dict(id='inbox-reply-1',
                                                                 waitingon='reviewer', due_at=PAST)))
        self.assertEqual(inspect([row], ['person']), ([], {}))

    def test_waiting_convention_requires_person_date_status_and_a_real_receipt_reference(self):
        rows = [issue('who', status='blocked', labels=['waiting'], due_at=FUTURE),
                issue('date', status='blocked', labels=['waiting'], metadata=dict(waitingon='peer')),
                issue('status', labels=['waiting'], due_at=FUTURE, metadata=dict(waitingon='peer')),
                issue('receipt', status='blocked', labels=['waiting'], due_at=FUTURE,
                      metadata=dict(waitingon='peer', waiting_reply=''))]
        findings, _ = inspect(rows)
        self.assertEqual({f['id'] for f in findings if f['kind'] == 'invalid'},
                         {'who', 'date', 'status', 'receipt'})

    def test_renewed_date_or_changed_person_does_not_reuse_an_old_reply(self):
        row = issue('person', status='blocked', labels=['waiting'], due_at=FUTURE,
                    metadata=dict(waitingon='reviewer', waiting_reply=dict(
                        id='inbox-reply-1', waitingon='reviewer', due_at=FUTURE)))
        self.assertEqual([f['kind'] for f in inspect([row])[0]], ['follow-up'])
        row['due_at'] = '2026-10-30T23:00:00+00:00'
        self.assertEqual(inspect([row], ['person']), ([], {}))
        row['due_at'] = FUTURE
        row['metadata']['waitingon'] = 'another-reviewer'
        self.assertEqual(inspect([row], ['person']), ([], {}))

    def test_active_owner_write_does_not_block_the_watcher_check(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'state').mkdir()
            with (home / 'state/.bead-accountability.lock').open('w') as writer:
                fcntl.flock(writer, fcntl.LOCK_EX)
                with self.assertRaises(BlockingIOError):
                    check(home, home / 'unused-board', NOW, True)


unittest.main()
PY
