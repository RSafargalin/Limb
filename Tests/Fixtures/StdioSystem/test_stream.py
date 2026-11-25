#!/usr/bin/env python3
"""Exercise stream delivery and cancellation over a fixture subprocess's stdio."""
import argparse
import array
import datetime
import fcntl
import json
import os
import random
import re
import selectors
import statistics
import subprocess
import tempfile
import termios
import time
from collections import Counter
from pathlib import Path

META = "io.modelcontextprotocol/"
MODERN = "2026-07-28"
ACK = "notifications/subscriptions/acknowledged"
UPDATE = "notifications/resources/updated"
PROGRESS = "notifications/progress"
URIS = {name: f"fixture://system/{name}" for name in ("alpha", "beta")}
INFO = {"name": "stdio-system-stream-test", "version": "1"}
TIMEOUT = 20
SEED = 1879


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Peer:
    def __init__(self, executable, revision, stderr):
        self.process = subprocess.Popen(
            [executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=stderr, bufsize=0,
        )
        self.input = self.process.stdin.fileno()
        self.output = self.process.stdout.fileno()
        os.set_blocking(self.input, False)
        os.set_blocking(self.output, False)
        self.reader = selectors.DefaultSelector()
        self.reader.register(self.output, selectors.EVENT_READ)
        self.writer = selectors.DefaultSelector()
        self.writer.register(self.input, selectors.EVENT_WRITE)
        self.buffer = bytearray()
        self.next_id = 0
        self.sent = set()
        self.responses = {}
        self.frame_count = Counter()
        self.updates = Counter()
        self.active = {}
        self.acknowledged = set()
        self.cancelled = set()
        self.cancelled_while_pending = set()
        self.progress = {}
        self.completed = set()
        self.revision = revision
        self.modern = revision >= MODERN

    def send(self, method, params, request=False):
        params = dict(params)
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        request_id = None
        if request:
            self.next_id += 1
            request_id = self.next_id
            self.sent.add(request_id)
            message["id"] = request_id
            if self.modern:
                params.setdefault("_meta", {}).update({
                    META + "protocolVersion": self.revision,
                    META + "clientCapabilities": {},
                    META + "clientInfo": INFO,
                })
        payload = json.dumps(message, separators=(",", ":")).encode() + b"\n"
        deadline = time.monotonic() + TIMEOUT
        while payload:
            require(self.writer.select(max(0, deadline - time.monotonic())),
                    f"deadline writing {method}")
            try:
                payload = payload[os.write(self.input, payload):]
            except BlockingIOError:
                continue
        return request_id

    def read(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.reader.select(remaining):
                return False
            try:
                chunk = os.read(self.output, 65536)
            except BlockingIOError:
                continue
            require(chunk, f"unexpected stdout EOF (exit {self.process.poll()})")
            self.buffer.extend(chunk)
            require(len(self.buffer) <= 2**20, "oversized stdout frame")
        line, _, self.buffer = self.buffer.partition(b"\n")
        message = json.loads(line)
        require(isinstance(message, dict) and message.get("jsonrpc") == "2.0",
                f"invalid JSON-RPC frame: {message!r}")
        self.apply(message)
        return True

    def apply(self, message):
        if "id" in message and "method" not in message:
            request_id = message["id"]
            require(type(request_id) is int and request_id in self.sent,
                    f"unknown response ID {request_id!r}")
            require(request_id not in self.completed, f"duplicate response {request_id}")
            require(("result" in message) != ("error" in message), "invalid response shape")
            self.completed.add(request_id)
            self.frame_count["responses"] += 1
            if request_id in self.cancelled:
                require(request_id not in self.cancelled_while_pending,
                        f"response to fixture request cancelled while pending: {request_id}")
                # An ordinary request may finish before the server sees cancellation.
                self.frame_count["ignored_cancelled_responses"] += 1
                return
            self.responses[request_id] = message
            return
        require("id" not in message, f"unexpected server request: {message!r}")
        method = message.get("method")
        self.frame_count[method] += 1
        params = message["params"]
        subscription_id = params.get("_meta", {}).get(META + "subscriptionId")
        if method == ACK:
            require(self.modern and type(subscription_id) is int
                    and subscription_id in self.active, f"unknown acknowledgement: {message!r}")
            require(subscription_id not in self.acknowledged, "duplicate acknowledgement")
            expected = {"resourceSubscriptions": [self.active[subscription_id]]}
            require(params.get("notifications") == expected, f"unexpected filter: {message!r}")
            self.acknowledged.add(subscription_id)
        elif method == UPDATE:
            uri = params["uri"]
            if self.modern:
                require(type(subscription_id) is int and subscription_id in self.acknowledged
                        and self.active.get(subscription_id) == uri,
                        f"wrong update route or inactive stream: {message!r}")
            else:
                require(subscription_id is None and uri in self.active,
                        f"wrong legacy update route: {message!r}")
            self.updates[uri] += 1
        elif method == PROGRESS:
            token = params["progressToken"]
            require(token in self.progress, f"unknown progress token {token!r}")
            request_id, limit, indices = self.progress[token]
            require(request_id not in self.completed, "progress arrived after terminal response")
            index = params["progress"]
            require(type(index) in (int, float) and 1 <= index <= limit
                    and index == int(index), f"invalid progress index {index!r}")
            require(not indices or index > indices[-1], f"nonincreasing progress for {token!r}")
            total = params.get("total")
            require(type(total) in (int, float) and total == limit,
                    f"wrong progress total for {token!r}: {total!r}")
            indices.append(index)
        else:
            raise ValueError(f"unexpected notification: {message!r}")

    def wait(self, condition, description, timeout=TIMEOUT):
        deadline = time.monotonic() + timeout
        while not condition():
            require(self.read(deadline), f"deadline waiting for {description}")

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and self.read(deadline):
            pass

    def result(self, request_id):
        self.wait(lambda: request_id in self.responses, f"response {request_id}")
        message = self.responses.pop(request_id)
        require("error" not in message, f"request {request_id} failed: {message.get('error')!r}")
        return message["result"]

    def connect(self):
        if self.modern:
            discovery = self.result(self.send("server/discover", {}, request=True))
            require(self.revision in discovery.get("supportedVersions", []),
                    f"requested revision absent from discovery: {discovery!r}")
        else:
            result = self.result(self.send("initialize", {
                "protocolVersion": self.revision, "capabilities": {}, "clientInfo": INFO,
            }, request=True))
            require(result["protocolVersion"] == self.revision, f"revision mismatch: {result!r}")
            require(result["capabilities"]["resources"]["subscribe"] is True,
                    f"resource subscriptions unavailable: {result!r}")
            self.send("notifications/initialized", {})

    def tool(self, name, arguments=None, token=None):
        params = {"name": f"system_{name}", "arguments": arguments or {}}
        if token is not None:
            params["_meta"] = {"progressToken": token}
        return self.send("tools/call", params, request=True)

    def subscribe(self, name):
        uri = URIS[name]
        if self.modern:
            request_id = self.send("subscriptions/listen", {
                "notifications": {"resourceSubscriptions": [uri]},
            }, request=True)
            self.active[request_id] = uri
            self.wait(lambda: request_id in self.acknowledged or request_id in self.responses,
                      f"acknowledgement of {name}")
            require(request_id in self.acknowledged,
                    f"subscription ended before acknowledgement: {self.responses.get(request_id)}")
            return request_id
        self.result(self.send("resources/subscribe", {"uri": uri}, request=True))
        self.active[uri] = uri
        return uri

    def cancel(self, request_id, *, proven_pending=False):
        require(request_id not in self.completed, f"request {request_id} already completed")
        self.send("notifications/cancelled", {"requestId": request_id})
        self.cancelled.add(request_id)
        if proven_pending:
            self.cancelled_while_pending.add(request_id)

    def stop_subscription(self, subscription):
        if self.modern:
            require(subscription in self.acknowledged, "expected an acknowledged subscription")
            # The fixture keeps acknowledged subscriptions open until cancellation.
            self.cancel(subscription, proven_pending=True)
        else:
            self.result(self.send("resources/unsubscribe", {"uri": subscription}, request=True))
        del self.active[subscription]

    def close(self, verify=False):
        try:
            self.process.stdin.close()
            try:
                status = self.process.wait(timeout=3)
                if verify:
                    require(status == 0, f"server exited {status} after closing stdin")
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)
                if verify:
                    raise ValueError("server did not exit promptly after closing stdin")
        finally:
            self.reader.close()
            self.writer.close()
            self.process.stdout.close()


def tool_text(result):
    require(not result.get("isError"), f"tool error: {result!r}")
    content = result["content"]
    require(len(content) == 1 and content[0]["type"] == "text", f"invalid tool result: {result!r}")
    return content[0]["text"]


def state(peer):
    text = tool_text(peer.result(peer.tool("state")))
    pid, entered, cancelled = map(int, text.split())
    require(pid == peer.process.pid and 0 <= cancelled <= entered,
            f"invalid subprocess state: {text!r}")
    return entered, cancelled


def wait_state(peer, expected):
    deadline = time.monotonic() + 5
    while True:
        actual = state(peer)
        if actual == expected:
            return
        require(time.monotonic() < deadline, f"expected state {expected}, got {actual}")
        time.sleep(0.01)


def echo(peer, token):
    start = time.monotonic()
    returned = tool_text(peer.result(peer.tool("echo", {"token": token})))
    require(returned == token, "echo token mismatch")
    return (time.monotonic() - start) * 1000


def publish(peer, stream, count, spacing, token):
    request_id = peer.tool("publish", {
        "stream": stream, "count": count, "spacingMicros": spacing,
    }, token)
    if token is not None:
        peer.progress[token] = (request_id, count, [])
    return request_id


def finish_publish(peer, request_id, count, token):
    require(tool_text(peer.result(request_id)) == str(count), "publish result count mismatch")
    if token is not None:
        indices = peer.progress[token][2]
        require(len(indices) == count,
                f"progress {token!r}: got {len(indices)} distinct indices, expected {count}")


def measure_updates(peer, before, attempts, exact):
    counts = {name: peer.updates[URIS[name]] - before[URIS[name]] for name in URIS}
    for name, count in attempts.items():
        lower = count if exact or count == 0 else 1
        require(lower <= counts[name] <= count,
                f"{name} resource updates: got {counts[name]}, expected {lower}..{count}")
    return counts


def queued_stdout_bytes(peer):
    size = array.array("i", [0])
    fcntl.ioctl(peer.output, termios.FIONREAD, size, True)
    return size[0]


def pressure(peer, metrics, events):
    # Use the same publication workload and short echo whether stdout is read
    # immediately or left unread for the duration of the pause.
    count = max(events, 1000)
    duration = 0.25
    failures = []
    for name, pause in (("control", 0), ("slow_reader", duration)):
        before = peer.updates.copy()
        start = time.monotonic()
        token = f"pressure-{name}"
        request = publish(peer, "beta", count, 0, token)
        echo_id = peer.tool("echo", {"token": token})
        with_reading_paused = time.monotonic()
        if pause:
            time.sleep(pause)
        queued = queued_stdout_bytes(peer)
        paused_ms = (time.monotonic() - with_reading_paused) * 1000
        profile = metrics[name] = {
            "resource_update_attempts": count,
            "progress_attempts": count,
            "planned_read_pause_ms": pause * 1000,
            "observed_read_pause_ms": paused_ms,
            "unread_pipe_bytes_before_drain": queued,
        }
        try:
            require(tool_text(peer.result(echo_id)) == token, "pressure echo token mismatch")
            profile["echo_rtt_ms"] = (time.monotonic() - start) * 1000
            finish_publish(peer, request, count, None)
            profile["publish_result"] = count
            peer.drain(0.1)
        finally:
            indices = peer.progress[token][2]
            profile.update({
                "resource_updates": {stream: peer.updates[uri] - before[uri]
                                     for stream, uri in URIS.items()},
                "progress_indices": len(indices),
                "last_progress_index": indices[-1] if indices else None,
                "burst_elapsed_ms": (time.monotonic() - start) * 1000,
            })
        # MCP permits progress at the sender's chosen frequency. Strict order
        # and range are checked as frames arrive. The last index is measured
        # separately because MCP does not require a completion notification.
        try:
            require(indices, "burst produced no progress notifications")
            measure_updates(peer, before, {"alpha": 0, "beta": count}, exact=False)
            if pause:
                require(queued > 0, "slow-reader interval ended without any stdout to drain")
        except ValueError as error:
            failures.append(f"{name}: {error}")
    require(not failures, "; ".join(failures))


def run(peer, events, metrics):
    rng = random.Random(SEED)
    peer.connect()
    alpha = peer.subscribe("alpha")
    beta = peer.subscribe("beta")

    before = peer.updates.copy()
    attempts = {name: 3 for name in URIS}
    isolated_progress = Counter()
    for step in range(3):
        for name in URIS:
            token = f"isolated-{name}-{step}"
            request_id = publish(peer, name, 1, 0, token)
            finish_publish(peer, request_id, 1, token)
            isolated_progress[name] += len(peer.progress[token][2])
            peer.wait(lambda: peer.updates[URIS[name]] >= before[URIS[name]] + step + 1,
                      f"isolated update for {name}")
    peer.drain(0.03)
    metrics["isolated_updates"] = measure_updates(peer, before, attempts, exact=True)
    metrics["isolated_progress_indices"] = dict(isolated_progress)

    before = peer.updates.copy()
    names = list(URIS)
    rng.shuffle(names)
    concurrent_events = max(2, events)
    requests = {
        name: publish(peer, name, concurrent_events, 1000, f"load-{name}") for name in names
    }
    peer.wait(lambda: all(peer.progress[f"load-{name}"][2] for name in names),
              "first progress from both publishers")
    samples = []
    overlapping = 0
    for index in range(16):
        samples.append(echo(peer, f"load:{index}:{rng.getrandbits(32):08x}"))
        if all(request_id not in peer.completed for request_id in requests.values()):
            overlapping += 1
    require(overlapping > 0 or events < 10, "no echo completed while both publishers were active")
    for name, request_id in requests.items():
        finish_publish(peer, request_id, concurrent_events, None)
    peer.drain(0.1)
    progress = {name: peer.progress[f"load-{name}"][2] for name in names}
    metrics["interleaved"] = {
        "attempts_per_stream": concurrent_events,
        "spacing_micros": 1000,
        "resource_updates": {name: peer.updates[URIS[name]] - before[URIS[name]]
                             for name in names},
        "progress_indices": {name: len(indices) for name, indices in progress.items()},
        "first_progress_index": {name: indices[0] for name, indices in progress.items()},
        "last_progress_index": {name: indices[-1] for name, indices in progress.items()},
        "progress_delivery_ratio": {name: len(indices) / concurrent_events
                                    for name, indices in progress.items()},
        "echo_samples": len(samples), "echoes_completed_during_both_publishes": overlapping,
        "echo_rtt_ms_median": statistics.median(samples), "echo_rtt_ms_max": max(samples),
    }

    measure_updates(peer, before, dict.fromkeys(names, concurrent_events), exact=True)

    peer.stop_subscription(alpha)
    # On stdio cancellation has no acknowledgement. A later echo verifies that
    # the same connection still serves requests before this isolated publication.
    echo(peer, "after-alpha-cancel")
    before = peer.updates.copy()
    for name in names:
        request_id = publish(peer, name, 1, 0, None)
        finish_publish(peer, request_id, 1, None)
    peer.wait(lambda: peer.updates[URIS["beta"]] > before[URIS["beta"]], "sibling update")
    peer.drain(0.1)
    metrics["updates_after_alpha_cancel"] = measure_updates(
        peer, before, {"alpha": 0, "beta": 1}, exact=True,
    )

    metrics["pressure"] = {}
    pressure(peer, metrics["pressure"], events)

    initial = state(peer)
    holds = [peer.tool("hold"), peer.tool("hold")]
    entered, cancelled = initial
    wait_state(peer, (entered + 2, cancelled))
    peer.cancel(holds[0], proven_pending=True)
    wait_state(peer, (entered + 2, cancelled + 1))
    echo(peer, "while-sibling-held")
    peer.cancel(holds[1], proven_pending=True)
    wait_state(peer, (entered + 2, cancelled + 2))
    metrics["held_operations_cancelled"] = 2
    metrics["echo_rtt_ms_after_cancel"] = echo(peer, "after-hold-cancel")
    peer.stop_subscription(beta)
    peer.drain(0.1)
    metrics["received_frames"] = dict(peer.frame_count)
    metrics["applied_resource_updates"] = {name: peer.updates[uri] for name, uri in URIS.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--events", type=int, default=1000)
    args = parser.parse_args()
    try:
        require(re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.revision), "expected YYYY-MM-DD")
        datetime.date.fromisoformat(args.revision)
        require(args.server.is_absolute() and args.server.is_file()
                and os.access(args.server, os.X_OK), "--server must name an absolute executable")
        require(1 <= args.events <= 5000, "--events must be 1..5000")
    except ValueError as error:
        parser.error(str(error))

    metrics = {"revision": args.revision, "seed": SEED, "events": args.events}
    with tempfile.TemporaryFile() as stderr:
        peer = None
        try:
            peer = Peer(args.server, args.revision, stderr)
            run(peer, args.events, metrics)
            peer.close(verify=True)
            metrics["status"] = "pass"
        except (OSError, ValueError, KeyError, TypeError) as error:
            if peer is not None and peer.process.poll() is None:
                peer.close()
            stderr.seek(max(0, os.fstat(stderr.fileno()).st_size - 4096))
            metrics.update(status="fail", error=str(error),
                           server_stderr=stderr.read(4096).decode(errors="replace"))
        print(json.dumps(metrics, sort_keys=True))
    return int(metrics["status"] != "pass")


if __name__ == "__main__":
    raise SystemExit(main())
