#!/usr/bin/env bash
# Consumer-visible outbox recovery and canonical-board invariants.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 -B - "$ROOT" <<'PY'
from argparse import Namespace
from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv.pop(1)) / 'bin'))
import fm_route_ask as subject


class Store:
    def __init__(self):
        self.tasks = {}
        self.fail_create = False
        self.lose_create_ack = False
        self.fail_complete = False

    def command(self, board, verb, *args, readonly=True, **kwargs):
        if verb == 'export':
            return '\n'.join(json.dumps(row) for row in self.tasks.values())
        if verb == 'create':
            if self.fail_create:
                raise RuntimeError('native create refused')
            row = dict(id='test-' + str(len(self.tasks) + 1), title=args[0], status='open',
                       description=args[args.index('--description') + 1],
                       assignee=args[args.index('--assignee') + 1],
                       metadata=json.loads(args[args.index('--metadata') + 1]))
            self.tasks[row['id']] = row
            if self.lose_create_ack:
                self.lose_create_ack = False
                raise RuntimeError('committed create, acknowledgement lost')
            return json.dumps(row)
        if verb == 'update':
            row = self.tasks[args[0]]
            metadata = json.loads(args[args.index('--metadata') + 1])
            if metadata.get('route_ask', {}).get('state') == 'delivered' and self.fail_complete:
                self.fail_complete = False
                raise RuntimeError('completion unavailable')
            row.setdefault('metadata', {}).update(metadata)
            if '--assignee' in args:
                row['assignee'] = args[args.index('--assignee') + 1]
            return json.dumps(row)
        raise AssertionError(verb)


class Routing(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='fm-route-behavior-')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        (self.home / 'state').mkdir()
        self.file = self.home / 'ask.txt'
        self.file.write_text('Perform the explicitly scoped source change.')
        self.args = Namespace(key='request-1', owner='worker', title='Scoped change',
                              source='https://example.invalid/asks/1',
                              message_file=str(self.file), task=None, due=None)
        self.store = Store()
        self.deliveries = []
        self.board = self.home / 'board'
        self.patch = patch.object(subject, 'board_command', self.store.command)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.transport = patch.object(subject, 'deliver', self.deliver)
        self.transport.start()
        self.addCleanup(self.transport.stop)

    def deliver(self, home, intent, task):
        # A native transport may only observe an already committed matching task.
        row = self.store.tasks[task]
        if row['metadata']['route_ask']['signature'] != intent['signature']:
            raise AssertionError('delivery precedes canonical intent')
        self.deliveries.append(intent['delivery_id'])

    def send(self):
        return subject.send(self.home, self.board, self.args)

    def test_rejected_task_commit_never_delivers_an_untracked_ask(self):
        self.store.fail_create = True
        with self.assertRaises(RuntimeError):
            self.send()
        self.assertEqual(self.deliveries, [])
        self.assertEqual(self.store.tasks, {})
        self.assertEqual(subject.integrity(self.home, {}),
                         [dict(kind='uncommitted-route', id='request-1')])

    def test_lost_create_ack_reuses_the_committed_task(self):
        self.store.lose_create_ack = True
        with self.assertRaises(RuntimeError):
            self.send()
        self.assertEqual(subject.integrity(self.home, self.store.tasks),
                         [dict(kind='routing-pending', id='test-1')])
        result = self.send()
        self.assertEqual(set(self.store.tasks), {result['task']})
        self.assertEqual(len(self.deliveries), 1)
        self.assertEqual(subject.integrity(self.home, self.store.tasks), [])

    def test_failed_transport_leaves_an_actionable_pending_task(self):
        with patch.object(subject, 'deliver', side_effect=RuntimeError('not confirmed')):
            with self.assertRaises(RuntimeError):
                self.send()
        self.assertEqual(subject.integrity(self.home, self.store.tasks),
                         [dict(kind='routing-pending', id='test-1')])
        result = self.send()
        self.assertEqual(set(self.store.tasks), {result['task']})
        self.assertEqual(subject.integrity(self.home, self.store.tasks), [])

    def test_lost_completion_write_does_not_resend_a_delivered_ask(self):
        self.store.fail_complete = True
        with self.assertRaises(RuntimeError):
            self.send()
        self.assertEqual(len(self.deliveries), 1)
        self.send()
        self.assertEqual(len(self.deliveries), 1)
        self.assertEqual(subject.integrity(self.home, self.store.tasks), [])

    def test_replay_after_success_does_not_repeat_work(self):
        self.send()
        self.send()
        self.assertEqual(len(self.deliveries), 1)

    def test_changed_input_cannot_reuse_a_delivery_key(self):
        self.send()
        self.file.write_text('A materially different ask.')
        with self.assertRaises(ValueError):
            self.send()
        self.assertEqual(len(self.deliveries), 1)
        self.assertEqual(set(self.store.tasks), {'test-1'})

    def test_existing_task_history_and_spec_are_not_replaced(self):
        history = [dict(eta='2026-11-01T10:00:00-08:00', etaby='worker', reason='prior commitment')]
        self.store.tasks['existing'] = dict(id='existing', status='in_progress',
            description='Considered specification', assignee='worker',
            metadata=dict(eta_history=deepcopy(history)))
        self.args.task = 'existing'
        self.send()
        row = self.store.tasks['existing']
        self.assertEqual(row['metadata']['eta_history'], history)
        self.assertEqual(row['description'], 'Considered specification')
        self.assertEqual(row['status'], 'in_progress')
        self.assertEqual(set(self.store.tasks), {'existing'})

    def test_terminal_task_is_neither_reopened_nor_delivered(self):
        self.store.tasks['existing'] = dict(id='existing', status='closed', metadata={})
        self.args.task = 'existing'
        with self.assertRaises(ValueError):
            self.send()
        self.assertEqual(self.deliveries, [])
        self.assertEqual(self.store.tasks['existing']['status'], 'closed')

    def test_deleted_canonical_task_is_an_orphan_not_a_successful_replay(self):
        self.send()
        self.store.tasks.clear()
        with self.assertRaises(ValueError):
            self.send()
        self.assertEqual(len(self.deliveries), 1)
        self.assertEqual(subject.integrity(self.home, {}),
                         [dict(kind='routed-note-without-task', id='test-1')])

    def test_new_request_updates_one_task_and_old_retry_cannot_overwrite_it(self):
        self.send()
        self.args.key = 'request-2'
        self.args.task = 'test-1'
        self.file.write_text('Amended scope.')
        self.send()
        self.assertEqual(set(self.store.tasks), {'test-1'})
        self.args.key = 'request-1'
        self.args.task = None
        self.file.write_text('Perform the explicitly scoped source change.')
        with self.assertRaises(ValueError):
            self.send()
        self.assertEqual(len(self.deliveries), 2)
        self.assertEqual(self.store.tasks['test-1']['metadata']['route_ask']['key'], 'request-2')

    def test_acknowledged_note_without_receipt_still_flags_a_missing_task(self):
        inbox = self.home / 'state/worker.inbox/handled'
        inbox.mkdir(parents=True)
        (inbox / '001.msg').write_text('schema=fm-task-inbox.v1\n--\ndelivery=0123456789abcdef [fm-route-ask task=missing request=r1]\nbody\n')
        self.assertEqual(subject.integrity(self.home, {}),
                         [dict(kind='routed-note-without-task', id='missing')])

    def test_quoted_marker_in_ordinary_note_body_is_not_a_routed_ask(self):
        inbox = self.home / 'state/worker.inbox'
        inbox.mkdir(parents=True)
        (inbox / '001.msg').write_text('schema=fm-task-inbox.v1\n--\nAn ordinary note\nExample: [fm-route-ask task=missing request=r1]\n')
        self.assertEqual(subject.integrity(self.home, {}), [])

    def test_waiting_projection_uses_current_board_not_receipt_success(self):
        self.send()
        self.store.tasks['test-1']['metadata']['route_ask']['state'] = 'pending'
        view = subject.projection(self.store.tasks)
        self.assertEqual([(row['id'], row['routing']) for row in view], [('test-1', 'pending')])
        self.store.tasks['test-1']['status'] = 'closed'
        self.assertEqual(subject.projection(self.store.tasks), [])


    def test_unanswered_captain_or_committed_owner_is_not_silently_reassigned(self):
        for fields in (dict(labels=['captain'], metadata={}),
                       dict(labels=[], metadata=dict(eta='2026-11-10T12:00:00-08:00', etaby='other'))):
            with self.subTest(fields=fields):
                self.store.tasks = {'existing': dict(id='existing', status='open', assignee='other', **fields)}
                before = deepcopy(self.store.tasks)
                self.args.task = 'existing'
                with self.assertRaises(ValueError):
                    self.send()
                self.assertEqual(self.store.tasks, before)
                self.assertEqual(self.deliveries, [])


unittest.main()
PY
