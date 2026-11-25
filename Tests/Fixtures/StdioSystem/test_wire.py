#!/usr/bin/env python3
"""Exercise the system fixture through newline-delimited JSON-RPC over pipes."""

import argparse
import json
import os
import selectors
import subprocess
import tempfile
import time


MODERN = "2026-07-28"
CLIENT = {"name": "limb-stdio-system-wire", "version": "1"}
TIMEOUT = 30
FRAGMENT_PAUSE = 0.02
SIZES = (1024, 65536, 1048576)


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def encode(message):
    return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


class Wire:
    def __init__(self, server, limit):
        self.stderr = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(
                [server],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self.stderr,
                env={**os.environ, "LIMB_SYSTEM_FRAME_LIMIT": str(limit)},
                bufsize=0,
            )
        except BaseException:
            self.stderr.close()
            raise
        self.input = self.process.stdin
        self.output = self.process.stdout
        self.pending = bytearray()
        self.stderr_tail = ""
        self.read_limit = max(4 * 1024 * 1024, 2 * limit)

    def __enter__(self):
        os.set_blocking(self.input.fileno(), False)
        os.set_blocking(self.output.fileno(), False)
        return self

    def __exit__(self, *_):
        self.input.close()
        try:
            self.process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)
        finally:
            self.output.close()
            self.stderr.seek(max(0, self.stderr.seek(0, os.SEEK_END) - 4096))
            self.stderr_tail = self.stderr.read().decode("utf-8", errors="replace")
            self.stderr.close()

    def exchange(self, chunks, count, pause=0):
        """Bound pipe reads and writes with one deadline, including write backpressure."""
        deadline = time.monotonic() + TIMEOUT
        ready_to_write = time.monotonic()
        output = []
        writes = 0
        chunks = iter(chunks)
        outgoing = memoryview(next(chunks, b""))
        with selectors.DefaultSelector() as selector:
            selector.register(self.output, selectors.EVENT_READ)
            while outgoing or len(output) < count:
                now = time.monotonic()
                require(now < deadline, f"timed out receiving {count} responses; got {len(output)}")
                writing = bool(outgoing) and now >= ready_to_write
                if writing:
                    selector.register(self.input, selectors.EVENT_WRITE)
                wait = deadline - now
                if outgoing and not writing:
                    wait = min(wait, ready_to_write - now)
                events = selector.select(wait)
                if writing:
                    selector.unregister(self.input)
                if pause:
                    events.sort(key=lambda event: event[1])
                for key, event in events:
                    if event == selectors.EVENT_WRITE:
                        outgoing = outgoing[os.write(key.fd, outgoing):]
                        writes += 1
                        if not outgoing:
                            outgoing = memoryview(next(chunks, b""))
                            ready_to_write = time.monotonic() + pause
                        continue
                    data = os.read(key.fd, 65536)
                    require(data, f"stdout closed after {len(output)} of {count} responses")
                    require(not outgoing or count == 0 or not pause,
                            "server wrote a response before the fragmented frame was complete")
                    self.pending.extend(data)
                    while (newline := self.pending.find(b"\n")) >= 0:
                        payload = self.pending[:newline]
                        del self.pending[:newline + 1]
                        output.append((json.loads(payload.decode("utf-8")), newline + 1))
                        require(len(output) <= count, "received an unexpected extra response")
                    require(len(self.pending) <= self.read_limit, "stdout line exceeded read bound")
        require(not self.pending, "stdout contains an unexpected partial frame")
        return output, writes

    def finish(self):
        self.input.close()
        with selectors.DefaultSelector() as selector:
            selector.register(self.output, selectors.EVENT_READ)
            require(selector.select(TIMEOUT), "stdout remained open after stdin EOF")
            require(not os.read(self.output.fileno(), 65536), "unexpected output after stdin EOF")
        require(self.process.wait(timeout=2) == 0, "server exited unsuccessfully")


class Suite:
    def __init__(self, wire, revision, report):
        self.wire = wire
        self.revision = revision
        self.report = report
        self.sequence = 0

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence if self.sequence % 2 else f"request-{self.sequence}"
        if self.revision >= MODERN:
            params = {
                **params,
                "_meta": {
                    "io.modelcontextprotocol/protocolVersion": self.revision,
                    "io.modelcontextprotocol/clientInfo": CLIENT,
                    "io.modelcontextprotocol/clientCapabilities": {},
                },
            }
        return request_id, encode(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        )

    def exchange(self, phase, chunks, count, pause=0):
        self.report["active_phase"] = phase
        entry = self.report["phases"].setdefault(
            phase, {"exchanges": 0, "sent_frames": 0, "received_frames": 0,
                    "stdin_bytes": 0, "stdout_bytes": 0, "write_syscalls": 0, "elapsed_ms": 0}
        )
        start = time.monotonic()
        replies, writes = self.wire.exchange(chunks, count, pause)
        entry["exchanges"] += 1
        entry["sent_frames"] += sum(chunk.count(b"\n") for chunk in chunks)
        entry["received_frames"] += len(replies)
        entry["stdin_bytes"] += sum(map(len, chunks))
        entry["stdout_bytes"] += sum(size for _, size in replies)
        entry["write_syscalls"] += writes
        entry["elapsed_ms"] += (time.monotonic() - start) * 1000
        return [reply for reply, _ in replies]

    def result(self, reply, request_id):
        require(isinstance(reply, dict), "JSON-RPC response is not an object")
        require(reply.get("jsonrpc") == "2.0" and "method" not in reply,
                "expected a JSON-RPC 2.0 response")
        actual_id = reply.get("id")
        require(type(actual_id) is type(request_id) and actual_id == request_id,
                f"expected response ID {request_id!r}, received {actual_id!r}")
        require("error" not in reply and isinstance(reply.get("result"), dict),
                f"request {request_id!r} failed with {str(reply.get('error'))[:300]}")
        result = reply["result"]
        if self.revision >= MODERN:
            require(result.get("resultType") == "complete", "expected a complete result")
        return result

    def handshake(self):
        if self.revision >= MODERN:
            request_id, frame = self.request("server/discover", {})
            reply, = self.exchange("negotiation", [frame], 1)
            versions = self.result(reply, request_id).get("supportedVersions", [])
            require(isinstance(versions, list) and self.revision in versions,
                    f"server/discover did not advertise {self.revision}")
        else:
            request_id, frame = self.request(
                "initialize", {"protocolVersion": self.revision, "capabilities": {}, "clientInfo": CLIENT}
            )
            reply, = self.exchange("negotiation", [frame], 1)
            actual = self.result(reply, request_id).get("protocolVersion")
            require(actual == self.revision, f"initialize negotiated {actual!r}")
            self.exchange("negotiation", [encode({
                "jsonrpc": "2.0", "method": "notifications/initialized"
            })], 0)

    def echo(self, token, response_bytes=None):
        arguments = {"token": token}
        if response_bytes is not None:
            arguments["responseBytes"] = response_bytes
        return self.request("tools/call", {"name": "system_echo", "arguments": arguments})

    def check_echo(self, reply, request_id, expected):
        result = self.result(reply, request_id)
        require(not result.get("isError"), f"tool call {request_id!r} returned an error")
        content = result.get("content")
        require(isinstance(content, list) and len(content) == 1,
                f"expected one content item for {request_id!r}")
        require(isinstance(content[0], dict) and content[0].get("type") == "text",
                f"expected text content for {request_id!r}")
        require(content[0].get("text") == expected, f"echo payload mismatch for {request_id!r}")

    def check_group(self, replies, expected):
        for reply in replies:
            require(isinstance(reply, dict), "group response is not an object")
            request_id = reply.get("id")
            require(type(request_id) in (str, int) and request_id in expected,
                    "group response contained an unexpected or duplicate ID")
            self.check_echo(reply, request_id, expected.pop(request_id))

    def run(self, frames, limit):
        self.handshake()
        request_id, frame = self.request("tools/list", {})
        listing, = self.exchange("tools_list", [frame], 1)
        tools = self.result(listing, request_id).get("tools", [])
        require(
            isinstance(tools, list)
            and any(isinstance(tool, dict) and tool.get("name") == "system_echo" for tool in tools),
            "tools/list omitted system_echo",
        )
        for index in range(frames):
            token = f"ordinary {index}"
            request_id, frame = self.echo(token)
            reply, = self.exchange("ordinary", [frame], 1)
            self.check_echo(reply, request_id, token)

        for index in range(frames):
            token = f"prefix-€-line\n-end-{index}"
            request_id, frame = self.echo(token)
            utf8_cut = frame.index("€".encode("utf-8")) + 1
            escape_cut = frame.index(b"\\n") + 1
            chunks = [frame[:utf8_cut], frame[utf8_cut:escape_cut], frame[escape_cut:-1], frame[-1:]]
            pause = FRAGMENT_PAUSE if index == 0 else 0
            reply, = self.exchange("fragmented", chunks, 1, pause=pause)
            self.check_echo(reply, request_id, token)
            if index == 0:
                fragment = self.report["phases"]["fragmented"]
                fragment["first_frame_chunk_bytes"] = list(map(len, chunks))
                fragment["first_frame_inter_chunk_pause_ms"] = pause * 1000

        for size in (4, 16, 64):
            phase = f"coalesced_{size}"
            for start in range(0, frames, size):
                expected = {}
                frames_to_send = []
                for index in range(start, min(start + size, frames)):
                    token = f"coalesced {size}/{index}"
                    request_id, frame = self.echo(token)
                    expected[request_id] = token
                    frames_to_send.append(frame)
                group_frames = len(frames_to_send)
                replies = self.exchange(phase, [b"".join(frames_to_send)], group_frames)
                self.check_group(replies, expected)
                entry = self.report["phases"][phase]
                entry["full_groups"] = entry.get("full_groups", 0) + int(group_frames == size)
                entry["tail_groups"] = entry.get("tail_groups", 0) + int(group_frames < size)
                entry["full_group_frames"] = entry["full_groups"] * size
                entry["tail_frames"] = entry["received_frames"] - entry["full_group_frames"]

        for group, start in enumerate(range(0, frames, 16)):
            expected = {}
            group_frames = min(16, frames - start)
            frames_to_send = []
            for index in range(start, start + group_frames):
                token = f"combined-€-line\n-end-{index}"
                request_id, frame = self.echo(token)
                expected[request_id] = token
                frames_to_send.append(frame)
            middle = group_frames // 2
            fragment = frames_to_send[middle]
            separator = "€".encode("utf-8") if group % 2 == 0 else b"\\n"
            cut = fragment.index(separator) + 1
            chunks = [
                b"".join(frames_to_send[:middle]) + fragment[:cut],
                fragment[cut:] + b"".join(frames_to_send[middle + 1:]),
            ]
            replies = self.exchange("combined", chunks, group_frames)
            self.check_group(replies, expected)
            entry = self.report["phases"]["combined"]
            entry["fragmented_frames"] = group + 1
            entry["coalesced_frames"] = entry["received_frames"] - entry["fragmented_frames"]
            entry["full_groups"] = entry.get("full_groups", 0) + int(group_frames == 16)
            entry["tail_groups"] = entry.get("tail_groups", 0) + int(group_frames < 16)
            entry["tail_frames"] = entry["received_frames"] - 16 * entry["full_groups"]

        for size in SIZES:
            pattern = "large input abcdefghijklmnopqrstuvwxyz"
            token = (pattern * (size // len(pattern) + 1))[:size]
            request_id, frame = self.echo(token)
            require(len(frame) - 1 <= limit,
                    f"configured frame limit cannot accommodate {size}-byte input payload")
            phase = f"large_request_{size}"
            reply, = self.exchange(phase, [frame], 1)
            self.check_echo(reply, request_id, token)
            self.report["phases"][phase]["payload_bytes"] = size
            request_id, frame = self.echo("large response", size)
            phase = f"large_response_{size}"
            reply, = self.exchange(phase, [frame], 1)
            self.check_echo(reply, request_id, "x" * size)
            self.report["phases"][phase]["payload_bytes"] = size

        for offset in (-1, 0, 1):
            marker = b"boundary-token:"
            request_id, short = self.echo(marker.decode("ascii"), 1)
            size = limit + offset
            require(len(short) - 1 <= size, "configured frame limit cannot fit boundary envelope")
            padding = b"q" * (size - len(short) + 1)
            frame = short.replace(marker, marker + padding, 1)
            phase = f"frame_limit_{offset:+d}"
            reply, = self.exchange(phase, [frame], 1)
            if offset <= 0:
                self.check_echo(reply, request_id, "x")
            else:
                require(
                    isinstance(reply, dict) and reply.get("jsonrpc") == "2.0"
                    and "id" in reply and reply["id"] is None and "result" not in reply
                    and isinstance(reply.get("error"), dict) and reply["error"].get("code") == -32600,
                    "oversized frame did not produce Invalid Request with null ID",
                )
                self.report["phases"][phase]["error_code"] = reply["error"]["code"]

        request_id, frame = self.echo("recovery")
        reply, = self.exchange("recovery", [frame], 1)
        self.check_echo(reply, request_id, "recovery")
        self.report["active_phase"] = "shutdown"
        self.wire.finish()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--frames", type=int, default=100)
    parser.add_argument("--frame-limit", type=int, default=2097152)
    args = parser.parse_args()

    report = {"status": "fail", "revision": args.revision, "frame_limit": args.frame_limit,
              "ordinary_frames_requested": args.frames, "frames_requested_per_mode": args.frames,
              "phases": {}}
    wire = None
    try:
        require(os.path.isabs(args.server), "--server must be an absolute path")
        require(args.frames > 0, "--frames must be positive")
        require(args.frame_limit > 0, "--frame-limit must be positive")
        wire = Wire(args.server, args.frame_limit)
        with wire:
            Suite(wire, args.revision, report).run(args.frames, args.frame_limit)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        if wire and wire.stderr_tail:
            report["stderr_tail"] = wire.stderr_tail
    else:
        report["status"] = "pass"
        del report["active_phase"]
    print(json.dumps(report, sort_keys=True))
    return int(report["status"] != "pass")


if __name__ == "__main__":
    raise SystemExit(main())
