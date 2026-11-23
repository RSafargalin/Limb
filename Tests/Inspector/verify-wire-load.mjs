import assert from "node:assert/strict";
import { assertLoadResponses } from "./observations.mjs";

const setupMethods = new Set([
  "initialize", "ping", "server/discover", "logging/setLevel", "subscriptions/listen",
  "tools/list", "prompts/list", "resources/list", "resources/templates/list",
]);
const itemBase = "limb-fixture://items/";

function expectedContent(method, params, mixed) {
  switch (method) {
    case "tools/call": {
      assert.equal(params.name, "echo");
      const text = params.arguments?.text;
      assert.equal(typeof text, "string");
      assert.match(text, mixed ? /^load-\d+-Лимб$/u : /^inspector-load-\d+$/u);
      return { step: "echo", payload: { isError: false, content: [{ type: "text", text }] } };
    }
    case "resources/read": {
      const uri = params.uri;
      assert.ok(mixed && typeof uri === "string" && uri.startsWith(itemBase));
      const item = uri.slice(itemBase.length);
      assert.match(item, /^load-\d+$/u);
      return { step: "read-item", payload: { contents: [{ uri, mimeType: "text/plain", text: `item:${item}` }] } };
    }
    case "prompts/get": {
      assert.ok(mixed);
      assert.equal(params.name, "greet");
      const name = params.arguments?.name;
      assert.equal(typeof name, "string");
      assert.match(name, /^Ada-\d+$/u);
      return { step: "greet", payload: { messages: [
        { role: "user", content: { type: "text", text: `Hello, ${name}.` } },
        { role: "assistant", content: { type: "text", text: "Ready." } },
      ] } };
    }
    default:
      assert.fail(`Unexpected load method ${method}`);
  }
}

export function checkWireLoad(trace, summary, { modern, mixed, minimumStartWindowMs = 0 }) {
  const setupIDs = new Set();
  const requests = new Map();
  const expected = [];
  const observed = [];
  const stepCounts = new Map();
  const latencies = [];
  let firstStart;
  let lastStart;
  let previousTime = 0;

  for (const { direction, at, message } of trace) {
    const { id, method, params } = message;
    assert.ok(Number.isFinite(at) && at >= previousTime && message.jsonrpc === "2.0", "Invalid or out-of-order wire record");
    previousTime = at;
    if (direction === "request") {
      if (!Object.hasOwn(message, "id") || !Object.hasOwn(message, "method")) continue;
      if (setupMethods.has(method)) {
        assert.ok(!setupIDs.has(id) && !requests.has(id), `Duplicate setup ID ${id}`);
        setupIDs.add(id);
        continue;
      }
      assert.ok(!requests.has(id) && !setupIDs.has(id), `Duplicate load request ID ${id}`);
      const { step, payload } = expectedContent(method, params, mixed);
      requests.set(id, { at, payload });
      stepCounts.set(step, (stepCounts.get(step) ?? 0) + 1);
      expected.push({ jsonrpc: "2.0", id, result: payload });
      firstStart ??= at;
      lastStart = at;
    } else {
      assert.equal(direction, "response");
      if (Object.hasOwn(message, "method") || setupIDs.has(id)) continue;
      const request = requests.get(id);
      if (!request || Object.hasOwn(message, "error")) {
        observed.push(message);
        continue;
      }
      assert.ok(message.result && typeof message.result === "object" && !Array.isArray(message.result));
      if (modern) assert.equal(message.result.resultType, "complete");
      const result = {};
      for (const field of Object.keys(request.payload)) {
        result[field] = field === "isError" && !Object.hasOwn(message.result, field) ? false : message.result[field];
      }
      observed.push({ jsonrpc: message.jsonrpc, id, result });
      const latency = at - request.at;
      assert.ok(latency >= 0, `Response preceded request ${id}`);
      latencies.push(latency);
    }
  }

  assert.equal(expected.length, summary.requests, "Wire request count disagrees with Inspector");
  assert.ok(expected.length > 0, "No load requests observed");
  if (mixed || summary.steps !== undefined) {
    assert.ok(Array.isArray(summary.steps) && summary.steps.length === stepCounts.size, "Invalid wire step summary");
    for (const step of summary.steps) {
      assert.equal(stepCounts.get(step.name), step.requests, `${step.name} wire count disagrees with Inspector`);
      stepCounts.delete(step.name);
    }
  }
  assertLoadResponses(expected, observed);
  const startWindowMs = lastStart - firstStart;
  assert.ok(startWindowMs >= minimumStartWindowMs, "The wire start window was shorter than expected");
  latencies.sort((a, b) => a - b);
  const percentile = (fraction) => latencies[Math.ceil(latencies.length * fraction) - 1];
  return { matched: expected.length, startWindowMs, p50Ms: percentile(0.5), p95Ms: percentile(0.95) };
}
