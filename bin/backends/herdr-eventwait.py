#!/usr/bin/env python3
"""Raw AF_UNIX subscriber for herdr's native pane.agent_status_changed stream.

This is the WIRE TRANSPORT half of the herdr push-escalation path
(bin/backends/herdr.sh fm_backend_herdr_wait_transition). It deliberately does
NOT know firstmate's supervision policy: it opens ONE connection to a herdr
session's control socket, subscribes to pane.agent_status_changed for the given
panes (all statuses, so working/idle/done edges are seen too), and prints one
projected line per event to stdout, flushing each so the bash caller can react
sub-second. The bash side normalizes each line through the shared transition
shape and applies the single-owner policy table (bin/fm-transition-lib.sh); the
bash side also decides when to stop and kills this reader.

Wire protocol (verified: herdr 0.7.3, protocol 16, newline-delimited JSON):
  request : {"id","method":"events.subscribe","params":{"subscriptions":[
             {"type":"pane.agent_status_changed","pane_id":P}, ...]}}\n
  ack     : {"id",...,"result":{"type":"subscription_started"}}\n
  stream  : {"event":"pane_agent_status_changed",
             "data":{"pane_id","workspace_id","agent_status","agent",...}}\n

The subscription type is dotted while the streamed envelope's event name is
underscored (verified: herdr 0.8.0, protocol 19); 0.7.x echoed the dotted form.
_event_matches accepts either spelling so a naming change cannot silently turn
the whole stream into what looks like an idle wait.

The same transport also serves the cockpit viewport's focus reaction
(bin/fm-cockpit.sh focus-listen), which subscribes to pane.focused instead.
That is a session-wide subscription with no pane list: herdr reports whichever
pane it just focused, and the bash side alone decides whether that pane is one
this home may move (bin/backends/herdr.sh fm_backend_herdr_cockpit_focus_place).
Keeping both subscriptions in one reader keeps a single wire-protocol owner.

  request : {"id","method":"events.subscribe","params":{"subscriptions":[
             {"type":"pane.focused"}]}}\n
  stream  : {"event":"pane_focused","data":{"pane_id","workspace_id",...}}\n

Usage: herdr-eventwait.py <socket_path> <timeout_seconds> <pane_id> [<pane_id> ...]
       herdr-eventwait.py --focus <socket_path> <timeout_seconds>
       herdr-eventwait.py --focus-once <socket_path> <timeout_seconds>

Output (one line per pane.agent_status_changed event, TAB-separated, a raw
projection - NOT the final normalized record; the bash normalizer adds the
from_status and builds the canonical shape):
  @subscribed
  <pane_id>\t<workspace_id>\t<agent_status>\t<agent>

Output in --focus or --focus-once mode (one line per pane.focused event):
  @subscribed
  <pane_id>\t<workspace_id>

Exit status:
  0  streamed until the timeout elapsed with no error - a clean bounded wait;
     the caller treats this as "no fast escalation, poll cadence preserved".
  2  bad arguments, could not connect, or could not send the subscribe request.
  3  the subscribe request did not return a subscription_started ack.
  4  the server closed the stream early or a receive operation failed.
A non-zero exit tells the bash caller to fall back to plain polling for this
cycle (the permanent fail-closed backstop), never to go silent.
"""
import json
import socket
import sys
import time

CONNECT_TIMEOUT = 5.0
ACK_TIMEOUT = 5.0
RECV_CHUNK = 65536


def _read_line(sock, buf, deadline):
    """Read one newline-terminated chunk from sock, honoring an absolute
    monotonic deadline. Returns (line_bytes_or_None, buf, outcome), where
    outcome is line, timeout, closed, or error."""
    while b"\n" not in buf:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None, buf, "timeout"
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except socket.timeout:
            return None, buf, "timeout"
        except OSError:
            return None, buf, "error"
        if not chunk:
            return None, buf, "closed"
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return line, buf, "line"


def _clean(value):
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def _event_matches(received, subscribed):
    """True when a streamed envelope's event names the subscribed type.

    Herdr names the SUBSCRIPTION with dots ("pane.focused") but stamps the
    streamed envelope with underscores ("event":"pane_focused") - verified on
    herdr 0.8.0, protocol 19. Older builds echoed the dotted form back, so both
    spellings are accepted rather than pinning either one: an unmatched name
    here is silent, and silence would look exactly like an idle stream while
    every event was really being dropped.
    """
    if not received:
        return False
    return received.replace(".", "_") == subscribed.replace(".", "_")


def main(argv):
    focus_mode = len(argv) > 1 and argv[1] in ("--focus", "--focus-once")
    focus_once = len(argv) > 1 and argv[1] == "--focus-once"
    if focus_mode:
        argv = argv[:1] + argv[2:]
        if len(argv) != 3:
            return 2
    elif len(argv) < 4:
        return 2
    sock_path = argv[1]
    try:
        timeout = float(argv[2])
    except ValueError:
        return 2
    panes = argv[3:]
    if timeout <= 0:
        return 2
    if not focus_mode and not panes:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(sock_path)
    except OSError:
        return 2

    if focus_mode:
        event_name = "pane.focused"
        subscriptions = [{"type": event_name}]
    else:
        event_name = "pane.agent_status_changed"
        subscriptions = [{"type": event_name, "pane_id": pane} for pane in panes]
    request = {
        "id": "fm-eventwait",
        "method": "events.subscribe",
        "params": {"subscriptions": subscriptions},
    }
    try:
        sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
    except OSError:
        return 2

    start = time.monotonic()
    deadline = start + timeout
    buf = b""

    # Bounded wait for the subscription_started ack (its own short budget, but
    # never past the overall deadline).
    ack_deadline = min(deadline, start + ACK_TIMEOUT)
    line, buf, outcome = _read_line(sock, buf, ack_deadline)
    if line is None:
        return 2
    try:
        ack = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 3
    result = ack.get("result") or {}
    if result.get("type") != "subscription_started":
        return 3

    sys.stdout.write("@subscribed\n")
    sys.stdout.flush()

    # Stream projected events until the deadline or the server closes.
    while True:
        line, buf, outcome = _read_line(sock, buf, deadline)
        if line is None:
            return 0 if outcome == "timeout" else 4
        try:
            message = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            continue
        if not _event_matches(message.get("event"), event_name):
            continue
        data = message.get("data") or {}
        if focus_mode:
            fields = (
                _clean(data.get("pane_id") or ""),
                _clean(data.get("workspace_id") or ""),
            )
        else:
            fields = (
                _clean(data.get("pane_id") or ""),
                _clean(data.get("workspace_id") or ""),
                _clean(data.get("agent_status") or ""),
                _clean(data.get("agent") or ""),
            )
        sys.stdout.write("\t".join(fields) + "\n")
        sys.stdout.flush()
        if focus_once:
            return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        # The bash caller stopped reading (found its actionable edge and killed
        # us). That is a normal, successful end of the wait.
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(0)
