"""Scripted MCP stdio peer for client-side system tests."""

import json
import os
import signal
import sys
import threading
import time


MODERN = "2026-07-28"
LEGACY = {"2025-03-26", "2025-06-18", "2025-11-25"}
EXITS = {"before-handshake", "during-handshake", "pending", "partial", "after-full"}
BATCH_SIZES = {"coalesce4": 4, "coalesce16": 16, "coalesce64": 64, "combined": 4}
MAX_RESPONSE_SIZE = 64 * 1024 * 1024
SERVER_INFO = {"name": "stdio-system-faults", "version": "1"}


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def write_all(fd, data):
    remaining = memoryview(data)
    writes = 0
    while remaining:
        remaining = remaining[os.write(fd, remaining):]
        writes += 1
    return writes


class Peer:
    def __init__(self):
        self.mode = os.getenv("LIMB_SYSTEM_FAULT", "normal")
        self.revision = os.getenv("LIMB_SYSTEM_REVISION", MODERN)
        self.audit_path = os.getenv("LIMB_SYSTEM_AUDIT")
        self.pending_count = int(os.getenv("LIMB_SYSTEM_PENDING_COUNT", "1"))
        self.exit_kind = os.getenv("LIMB_SYSTEM_EXIT_KIND", "normal")
        self.frame_bytes = int(os.getenv("LIMB_SYSTEM_FRAME_BYTES", "0"))
        self.tail_seconds = int(os.getenv("LIMB_SYSTEM_TAIL_MS", "150")) / 1000
        self.fragment_seconds = int(os.getenv("LIMB_SYSTEM_FRAGMENT_US", "3000")) / 1_000_000
        self.received = 0
        self.held = []
        self.queue = []
        self.closed = False
        self.condition = threading.Condition()
        self.audit_lock = threading.Lock()
        self.batch_worker = None
        self.stderr_worker = None
        if not (self.revision == MODERN or self.revision in LEGACY):
            raise ValueError("unknown revision")
        if self.mode not in EXITS | BATCH_SIZES.keys() | {"normal", "fragment", "stderr", "boundary"}:
            raise ValueError("unknown fault mode")
        if self.pending_count < 1 or not 0 < self.tail_seconds <= 5 or not 0 <= self.fragment_seconds <= 1:
            raise ValueError("invalid fault timing")
        if self.mode in EXITS and os.getenv("LIMB_SYSTEM_FAULT_ONCE") == "1":
            if not self.audit_path:
                raise ValueError("one-time fault requires an audit path")
            try:
                fd = os.open(self.audit_path + ".claim", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                self.mode = "normal"
            else:
                os.close(fd)

    def audit(self, phase, **details):
        if not self.audit_path:
            return
        with self.audit_lock:
            event = {
                "phase": phase,
                "pid": os.getpid(),
                "monotonicNs": time.monotonic_ns(),
                "received": self.received,
                "held": len(self.held),
                **details,
            }
            fd = os.open(self.audit_path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
            try:
                write_all(fd, encode(event) + b"\n")
            finally:
                os.close(fd)

    def terminate(self, phase):
        self.audit("exit", fault=phase, exitKind=self.exit_kind)
        if self.exit_kind.lower() in {"kill", "sigkill"}:
            os.kill(os.getpid(), signal.SIGKILL)
        raise SystemExit(73)

    def result(self, request, contents):
        if self.revision == MODERN:
            contents = {"resultType": "complete", **contents}
        return {"jsonrpc": "2.0", "id": request["id"], "result": contents}

    def emit(self, frames, reason):
        # This is the only writer in batch modes after setup, so even fragments
        # from different flushes cannot interleave.
        data = b"".join(frames)
        chunks = [data]
        fragmented = []
        utf8_cuts = 0
        escape_cuts = 0
        if self.mode in {"fragment", "combined"}:
            utf8_cut = next((i for i in range(1, len(data)) if data[i] & 0xC0 == 0x80), None)
            escape_cut = data.find(b"\\") + 1
            cuts = {cut for cut in (utf8_cut, escape_cut) if cut and cut < len(data)}
            for candidate in (len(data) // 3, 2 * len(data) // 3):
                if len(cuts) < 2:
                    cuts.add(candidate)
            first, second = sorted(cuts)
            chunks = [data[:first], data[first:second], data[second:]]
            utf8_cuts = sum(data[cut] & 0xC0 == 0x80 for cut in cuts)
            escape_cuts = int(escape_cut in cuts)
            start = 0
            for index, frame in enumerate(frames):
                end = start + len(frame)
                if any(start < cut < end for cut in cuts):
                    fragmented.append(index)
                start = end
        sizes = []
        writes = []
        for index, chunk in enumerate(chunks):
            writes.append(write_all(1, chunk))
            sizes.append(len(chunk))
            if index + 1 < len(chunks) and self.fragment_seconds:
                time.sleep(self.fragment_seconds)
        self.audit("flush", reason=reason, frames=len(frames), bytes=len(data),
                   chunks=sizes, writes=writes, fragmentedFrames=len(fragmented),
                   fragmentedFrameIndices=fragmented, utf8Cuts=utf8_cuts, escapeCuts=escape_cuts)

    def send_application(self, frame):
        if self.mode not in BATCH_SIZES:
            self.emit([frame], "application")
            return
        with self.condition:
            self.queue.append((time.monotonic(), frame))
            self.condition.notify()

    def flush_batches(self):
        group_size = BATCH_SIZES[self.mode]
        while True:
            with self.condition:
                while not self.queue and not self.closed:
                    self.condition.wait()
                if not self.queue:
                    return
                if len(self.queue) >= group_size:
                    count, reason = group_size, "full"
                elif self.closed:
                    count, reason = len(self.queue), "eof"
                else:
                    oldest, _ = self.queue[0]
                    remaining = oldest + self.tail_seconds - time.monotonic()
                    if remaining > 0:
                        self.condition.wait(remaining)
                        continue
                    count, reason = len(self.queue), "timer"
                frames = [frame for _, frame in self.queue[:count]]
                del self.queue[:count]
            self.emit(frames, reason)

    def write_stderr(self):
        count = 0
        block = b"e" * 0x10000
        try:
            for _ in range(256):
                write_all(2, block)
                count += len(block)
                time.sleep(0.001)
        except BrokenPipeError:
            self.audit("stderr-interrupted", bytes=count)
            return
        self.audit("stderr-complete", bytes=count)

    def handshake(self, request):
        method = "server/discover" if self.revision == MODERN else "initialize"
        if request.get("method") != method:
            raise ValueError("client sent an unexpected handshake method")
        capabilities = {"tools": {"listChanged": False}}
        if self.revision == MODERN:
            result = {
                "supportedVersions": [self.revision],
                "capabilities": capabilities,
                "ttlMs": 0,
                "cacheScope": "private",
                "_meta": {"io.modelcontextprotocol/serverInfo": SERVER_INFO},
            }
        else:
            result = {
                "protocolVersion": self.revision,
                "serverInfo": SERVER_INFO,
                "capabilities": capabilities,
            }
        return encode(self.result(request, result)) + b"\n"

    def tool_reply(self, request):
        params = request.get("params", {})
        arguments = params.get("arguments", {})
        name = params.get("name")
        if name == "system_state":
            content = f"{os.getpid()} {len(self.held)}"
        elif name == "system_echo":
            token = arguments.get("token")
            if not isinstance(token, str):
                raise ValueError("system_echo requires a string token")
            size = arguments.get("responseBytes")
            if size is not None and (type(size) is not int or not 0 <= size <= MAX_RESPONSE_SIZE):
                raise ValueError("invalid responseBytes")
            content = token if size is None else "x" * size
        else:
            raise ValueError("unknown test tool")
        result = self.result(request, {"content": [{"type": "text", "text": content}]})
        frame = encode(result)
        target = arguments.get("frameBytes", self.frame_bytes) if self.mode == "boundary" else 0
        if type(target) is not int or not 0 <= target <= MAX_RESPONSE_SIZE:
            raise ValueError("invalid frameBytes")
        if target:
            if len(frame) > target:
                raise ValueError("requested frameBytes cannot fit the specified response")
            result["result"]["content"][0]["text"] += "x" * (target - len(frame))
            frame = encode(result)
        return frame + b"\n"

    def application(self, request):
        if "id" not in request:
            self.audit("notification", method=request.get("method"))
            return
        method = request.get("method")
        params = request.get("params", {})
        echo = method == "tools/call" and params.get("name") == "system_echo"
        self.received += 1
        self.audit("application-received", method=method, requestId=request["id"],
                   tool=params.get("name"))
        try:
            if method != "tools/call":
                raise ValueError("unsupported application request")
            frame = self.tool_reply(request)
        except ValueError as error:
            frame = encode({"jsonrpc": "2.0", "id": request["id"],
                            "error": {"code": -32602, "message": str(error)}}) + b"\n"
        if not echo or self.mode not in {"pending", "partial", "after-full"}:
            self.send_application(frame)
            return
        self.held.append(frame)
        self.audit("reply-held", requestId=request["id"])
        if len(self.held) == self.pending_count:
            if self.mode == "partial":
                self.emit([self.held[0][:len(self.held[0]) // 2]], "partial")
            elif self.mode == "after-full":
                self.emit([self.held.pop(0)], "after-full")
            self.terminate(self.mode)

    def run(self):
        self.audit("start", mode=self.mode, revision=self.revision)
        if self.mode == "before-handshake":
            self.terminate(self.mode)
        first = sys.stdin.buffer.readline()
        if not first:
            return
        reply = self.handshake(json.loads(first))
        self.audit("handshake-received")
        if self.mode == "during-handshake":
            self.emit([reply[:len(reply) // 2]], "during-handshake")
            self.terminate(self.mode)
        self.emit([reply], "handshake")
        if self.mode in BATCH_SIZES:
            self.batch_worker = threading.Thread(target=self.flush_batches, daemon=True)
            self.batch_worker.start()
        if self.mode == "stderr":
            self.stderr_worker = threading.Thread(target=self.write_stderr, daemon=True)
            self.stderr_worker.start()
        for line in sys.stdin.buffer:
            self.application(json.loads(line))
        if self.batch_worker:
            with self.condition:
                self.closed = True
                self.condition.notify()
            self.batch_worker.join(timeout=5)
        if self.stderr_worker:
            self.stderr_worker.join(timeout=5)
        self.audit("eof")


if __name__ == "__main__":
    Peer().run()
