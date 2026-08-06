#!/usr/bin/env python3
import importlib.util
import io
import socket
import time
import unittest
from pathlib import Path
from unittest import mock


READER_PATH = Path(__file__).parents[1] / "bin" / "backends" / "herdr-eventwait.py"
SPEC = importlib.util.spec_from_file_location("herdr_eventwait", READER_PATH)
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)


class FailingSocket:
    def settimeout(self, _timeout):
        pass

    def recv(self, _size):
        raise OSError("receive failed")


class ClosingStreamSocket:
    def __init__(self):
        self.chunks = [
            b'{"result":{"type":"subscription_started"}}\n',
            b"",
        ]

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, _request):
        pass

    def recv(self, _size):
        return self.chunks.pop(0)


class RejectedSubscriptionSocket(ClosingStreamSocket):
    def __init__(self):
        self.chunks = [b'{"result":{"type":"not_started"}}\n']


class RecordingFocusSocket(ClosingStreamSocket):
    """Acks the subscription, streams one pane.focused event, then closes."""

    def __init__(self):
        self.sent = b""
        self.chunks = [
            b'{"result":{"type":"subscription_started"}}\n',
            b'{"event":"pane_focused","data":'
            b'{"pane_id":"w1:p7","workspace_id":"w1"}}\n'
            b'{"event":"pane_agent_status_changed","data":'
            b'{"pane_id":"w1:p9","workspace_id":"w1","agent_status":"idle"}}\n',
            b"",
        ]

    def sendall(self, request):
        self.sent += request


class EventWaitReadLineTest(unittest.TestCase):
    def test_deadline_is_clean_timeout(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)

        line, buf, outcome = READER._read_line(left, b"", time.monotonic())

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "timeout")

    def test_peer_closure_is_runtime_failure(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        right.close()

        line, buf, outcome = READER._read_line(
            left, b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "closed")

    def test_receive_error_is_runtime_failure(self):
        line, buf, outcome = READER._read_line(
            FailingSocket(), b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "error")

    def test_main_reports_early_stream_closure(self):
        stdout = io.StringIO()
        with mock.patch.object(READER.socket, "socket", return_value=ClosingStreamSocket()):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 4)
        self.assertEqual(stdout.getvalue(), "@subscribed\n")

    def test_main_does_not_signal_readiness_before_valid_ack(self):
        stdout = io.StringIO()
        with mock.patch.object(
            READER.socket, "socket", return_value=RejectedSubscriptionSocket()
        ):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 3)
        self.assertEqual(stdout.getvalue(), "")


class EventWaitFocusModeTest(unittest.TestCase):
    def test_focus_mode_subscribes_session_wide_and_projects_only_focus(self):
        stdout = io.StringIO()
        sock = RecordingFocusSocket()
        with mock.patch.object(READER.socket, "socket", return_value=sock):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "--focus", "socket", "1"])

        self.assertEqual(result, 4)
        # One session-wide pane.focused subscription, carrying no pane list:
        # the placement decision belongs to the bash side, not the transport.
        self.assertIn(b'"type": "pane.focused"', sock.sent)
        self.assertNotIn(b'"pane_id"', sock.sent)
        # Only focus events are projected, and only as pane and workspace.
        self.assertEqual(stdout.getvalue(), "@subscribed\nw1:p7\tw1\n")

    def test_focus_mode_rejects_a_pane_list(self):
        self.assertEqual(
            READER.main(["herdr-eventwait.py", "--focus", "socket", "1", "w1:p1"]), 2
        )

    def test_status_mode_still_requires_at_least_one_pane(self):
        self.assertEqual(READER.main(["herdr-eventwait.py", "socket", "1"]), 2)


class EventNameMatchTest(unittest.TestCase):
    """Herdr subscribes with dots and streams with underscores (0.8.0), while
    0.7.x echoed dots back. Matching only one spelling drops every event and
    looks identical to an idle stream, so both must be accepted."""

    def test_underscored_envelope_matches_dotted_subscription(self):
        self.assertTrue(READER._event_matches("pane_focused", "pane.focused"))
        self.assertTrue(
            READER._event_matches(
                "pane_agent_status_changed", "pane.agent_status_changed"
            )
        )

    def test_dotted_envelope_still_matches(self):
        self.assertTrue(READER._event_matches("pane.focused", "pane.focused"))

    def test_a_different_event_never_matches(self):
        self.assertFalse(READER._event_matches("pane_moved", "pane.focused"))
        self.assertFalse(READER._event_matches("", "pane.focused"))
        self.assertFalse(READER._event_matches(None, "pane.focused"))


if __name__ == "__main__":
    unittest.main()
