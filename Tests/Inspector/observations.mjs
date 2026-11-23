import assert from "node:assert/strict";

function hasResponseBody(message) {
  return Object.hasOwn(message, "result") || Object.hasOwn(message, "error");
}

function isRequestID(id) {
  return typeof id === "string" || Number.isSafeInteger(id);
}

export function assertCancelledResponseAbsent(frames, cancelledId) {
  assert.ok(isRequestID(cancelledId), "Missing cancelled request ID");
  for (const frame of frames) {
    assert.ok(
      frame.id !== cancelledId || Object.hasOwn(frame, "method") || !hasResponseBody(frame),
      `Server replied to cancelled request ${JSON.stringify(cancelledId)}`,
    );
  }
}

export function assertLoadResponses(expected, observed) {
  const pending = new Map();
  for (const response of expected) {
    const { id } = response;
    assert.ok(isRequestID(id) && response.jsonrpc === "2.0" && !Object.hasOwn(response, "method")
      && Object.hasOwn(response, "result") !== Object.hasOwn(response, "error"), "Invalid expected response");
    assert.ok(!pending.has(id), `Duplicate expected ID ${JSON.stringify(id)}`);
    pending.set(id, response);
  }
  for (const response of observed) {
    const { id } = response;
    assert.ok(pending.has(id), `Unexpected or duplicate response ID ${JSON.stringify(id)}`);
    assert.deepEqual(response, pending.get(id), `Wrong response for request ${JSON.stringify(id)}`);
    pending.delete(id);
  }
  assert.equal(pending.size, 0, `Missing replies for ${pending.size} requests`);
}
