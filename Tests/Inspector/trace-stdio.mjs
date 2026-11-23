import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { writeFileSync } from "node:fs";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";

const [binary, version, tracePath] = process.argv.slice(2);
assert.equal(process.argv.length, 5);

const trace = [];
let bytes = 0;

function observe(direction) {
  let pending = Buffer.alloc(0);
  return new Transform({
    transform(chunk, _encoding, callback) {
      try {
        bytes += chunk.length;
        assert.ok(bytes <= 32 * 1024 * 1024, "Inspector wire capture exceeded its byte limit");
        const at = performance.now();
        const buffer = Buffer.concat([pending, chunk]);
        let start = 0;
        for (let end = buffer.indexOf(10); end !== -1; end = buffer.indexOf(10, start)) {
          const message = JSON.parse(buffer.toString("utf8", start, end));
          trace.push({ direction, at, message });
          start = end + 1;
        }
        pending = buffer.subarray(start);
        callback(null, chunk);
      } catch (error) {
        callback(error);
      }
    },
    flush(callback) {
      callback(pending.length === 0 ? undefined : new Error(`Incomplete ${direction} stdio message`));
    },
  });
}

const fixture = spawn(binary, [version], { stdio: ["pipe", "pipe", "inherit"] });
try {
  const [[code, signal]] = await Promise.all([
    once(fixture, "close"),
    pipeline(process.stdin, observe("request"), fixture.stdin),
    pipeline(fixture.stdout, observe("response"), process.stdout, { end: false }),
  ]);
  assert.equal(signal, null, `Fixture terminated by ${signal}`);
  assert.equal(code, 0, `Fixture exited ${code}`);
  writeFileSync(tracePath, JSON.stringify(trace), { flag: "wx" });
} finally {
  if (fixture.exitCode === null && fixture.signalCode === null) fixture.kill();
}
