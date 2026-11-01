"""Regression checks for action accounting at stream end, without sockets."""
import unittest

from integration import validate_action_accounting


class ActionAccountingTest(unittest.TestCase):
    def setUp(self):
        self.accept = dict(action_id='accept', channel=1, read_id='read-1', group='virus')
        self.reject = dict(action_id='reject', channel=2, read_id='read-2', group=None)
        self.ack = dict(action_id='accept', channel=1, read_id='read-1', status=0)
        self.end = dict(unacknowledged_actions=1, confirmed={'virus': 1}, pending={'virus': 0})

    def test_last_action_can_remain_unresolved_at_stream_end(self):
        self.assertEqual(validate_action_accounting([self.accept, self.reject], [self.ack], self.end), {'reject'})

    def test_unresolved_accept_retains_its_reservation(self):
        end = dict(unacknowledged_actions=1, confirmed={}, pending={'virus': 1})
        self.assertEqual(validate_action_accounting([self.accept], [], end), {'accept'})
        end['confirmed']['virus'] = 1
        with self.assertRaises(AssertionError):
            validate_action_accounting([self.accept], [], end)

    def test_unreported_missing_ack_is_rejected(self):
        self.end['unacknowledged_actions'] = 0
        with self.assertRaises(AssertionError):
            validate_action_accounting([self.accept, self.reject], [self.ack], self.end)

    def test_duplicate_unknown_mismatched_and_failed_acks_are_rejected(self):
        for acks in ([self.ack, self.ack],
                     [dict(self.ack, action_id='unknown')],
                     [dict(self.ack, read_id='other-read')],
                     [dict(self.ack, channel=2)],
                     [dict(self.ack, status=1)]):
            with self.subTest(acks=acks), self.assertRaises(AssertionError):
                validate_action_accounting([self.accept, self.reject], acks, self.end)

    def test_wrong_reservation_and_duplicate_decision_are_rejected(self):
        end = dict(unacknowledged_actions=1, confirmed={}, pending={'virus': 0})
        with self.assertRaises(AssertionError):
            validate_action_accounting([self.accept], [], end)
        with self.assertRaises(AssertionError):
            validate_action_accounting([self.accept, self.accept], [], end)


if __name__ == '__main__':
    unittest.main()
