import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { assertCancelledResponseAbsent } from "./observations.mjs";

const stepsURI = "limb-fixture://state/steps";

export async function checkProgressAndCancellation(
  { version, era }, { binary, timeout, echoText, textContent },
) {
  const client = new Client(
    { name: "limb-inspector-verifier", version: "1" },
    {
      supportedProtocolVersions: [version],
      versionNegotiation: era === "modern" ? { mode: { pin: version } } : { mode: "legacy" },
    },
  );
  const cancellationFrames = [];
  let captureCancellation = false;
  let cancelledId;
  let cancelledProgressToken;
  class ObservedTransport extends StdioClientTransport {
    async start() {
      const receive = this.onmessage;
      this.onmessage = (message, extra) => {
        if (captureCancellation) cancellationFrames.push(message);
        receive?.call(this, message, extra);
      };
      await super.start();
    }

    async send(message, options) {
      if (message.method === "tools/call" && message.params?.name === "run_steps"
          && message.params?.arguments?.mode === "cancel") {
        assert.equal(cancelledId, undefined, "Expected one cancellable call");
        cancelledId = message.id;
        cancelledProgressToken = message.params._meta?.progressToken;
      }
      await super.send(message, options);
    }
  }
  const transport = new ObservedTransport({
    command: binary,
    args: [version],
    stderr: "ignore",
  });

  const call = (name, args, options) => client.callTool({ name, arguments: args }, { timeout, ...options });
  const assertResult = (result, expected) => {
    assert.equal(result.isError ?? false, false);
    assert.equal(textContent(result), expected);
  };
  const readState = async (readTimeout = timeout) => {
    const { contents } = await client.readResource(
      { uri: stepsURI }, { timeout: readTimeout, cacheMode: "bypass" },
    );
    assert.equal(contents.length, 1, stepsURI);
    const [state] = contents;
    assert.partialDeepStrictEqual(state, { uri: stepsURI, mimeType: "text/plain" });
    assert.equal(typeof state.text, "string", stepsURI);
    return state.text;
  };

  try {
    await client.connect(transport, { timeout });
    assert.equal(client.getNegotiatedProtocolVersion(), version);
    assertResult(await call("protocol_version", {}), version);
    assert.equal(await readState(), "idle");

    const completionProgress = [];
    const { promise: observedProgress, resolve: observeProgress } = Promise.withResolvers();
    const completion = call("run_steps", { mode: "complete" }, {
      onprogress: (progress) => {
        completionProgress.push(progress);
        observeProgress(progress);
      },
    }).then((result) => {
      assert.notEqual(completionProgress.length, 0, "Expected progress before tool completion");
      return result;
    });
    const release = observedProgress.then((progress) => {
      assert.deepEqual(progress, { progress: 1, total: 1, message: "completed" });
      return call("run_steps", { mode: "continue" });
    });
    const [completed, released] = await Promise.all([completion, release]);
    assert.deepEqual(completionProgress, [{ progress: 1, total: 1, message: "completed" }]);
    assertResult(released, "released");
    assertResult(completed, "completed");
    assert.equal(await readState(), "completed");

    const controller = new AbortController();
    const cancellationProgress = [];
    await assert.rejects(call("run_steps", { mode: "cancel" }, {
      signal: controller.signal,
      onprogress: (progress) => {
        cancellationProgress.push(progress);
        captureCancellation = true;
        controller.abort(new Error("cancel run_steps after observing progress"));
      },
    }), { message: /cancel run_steps after observing progress/ });

    // The client aborts locally before the fixture processes the cancellation notification.
    const deadline = performance.now() + timeout;
    let state = await readState();
    while (state === "running" && performance.now() < deadline) {
      await delay(25);
      const remaining = Math.ceil(deadline - performance.now());
      if (remaining <= 0) break;
      state = await readState(remaining);
    }
    assert.equal(state, "cancelled", "The fixture should observe the cancellation notification");
    assertResult(await call("echo", { text: echoText }), echoText);
    assert.deepEqual(cancellationProgress, [{ progress: 1, total: 2, message: "started" }]);
  } finally {
    await client.close();
  }
  assert.ok(typeof cancelledProgressToken === "string" || Number.isSafeInteger(cancelledProgressToken), "Missing progress token used for the cancelled request");
  assertCancelledResponseAbsent(cancellationFrames, cancelledId, cancelledProgressToken);
}
