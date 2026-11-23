import assert from "node:assert/strict";
import { test } from "node:test";
import { assertFixtureRevisions } from "./matrix.mjs";
import { checkReleaseLoad, summarizeReleaseLoad } from "./verify-release-load.mjs";

const scenarioPath = "/tmp/release-scenario.json";

function inspectorLoad(counts = [3750, 1875, 1875]) {
  const requests = counts.reduce((sum, count) => sum + count, 0);
  const steps = [
    { name: "echo", method: "tools/call", target: "echo", weight: 2 },
    { name: "read-item", method: "resources/read", target: "limb-fixture://items/load-{{seq}}", weight: 1 },
    { name: "greet", method: "prompts/get", target: "greet", weight: 1 },
  ].map((step, index) => ({ ...step, requests: counts[index], ok: counts[index], errors: 0, toolErrors: 0 }));
  return {
    rate: 250,
    concurrency: 16,
    openLoop: true,
    elapsedMs: 30000,
    plannedStarts: 7500,
    requests,
    ok: requests,
    errors: 0,
    toolErrors: 0,
    droppedSlots: 7500 - requests,
    steps,
  };
}

test("sustained load accepts the full cycle and a valid 99 percent prefix", async () => {
  for (const counts of [[3750, 1875, 1875], [3713, 1856, 1856]]) {
    const result = inspectorLoad(counts);
    const summary = await checkReleaseLoad(async () => result, scenarioPath);
    assert.deepEqual(summary, {
      plannedStarts: 7500,
      requests: result.requests,
      ok: result.ok,
      errors: 0,
      toolErrors: 0,
      droppedSlots: result.droppedSlots,
      steps: result.steps.map(({ name, requests, ok, errors, toolErrors }) =>
        ({ name, requests, ok, errors, toolErrors })),
    });
  }
});

test("sustained load rejects the correct cycle when starts fall below 99 percent", async () => {
  await assert.rejects(() => checkReleaseLoad(async () => inspectorLoad([3712, 1856, 1856]), scenarioPath));
});

test("sustained load rejects skew even with all planned requests successful", async () => {
  const result = inspectorLoad([7498, 1, 1]);
  await assert.rejects(() => checkReleaseLoad(async () => result, scenarioPath));
});

for (const [field, invalid] of [["method", "prompts/get"], ["target", "not-echo"], ["weight", 1]]) {
  test("sustained load rejects an incorrect step " + field, async () => {
    const result = inspectorLoad();
    result.steps[0][field] = invalid;
    await assert.rejects(() => checkReleaseLoad(async () => result, scenarioPath));
  });
}

test("load projection retains safe totals when the step breakdown is unavailable", () => {
  const result = inspectorLoad([3712, 1856, 1856]);
  result.ok -= 2;
  result.errors = 1;
  result.toolErrors = 1;
  result.latencies = [25, 100];
  result.logPath = "/private/test/inspector.log";
  delete result.steps;
  const summary = summarizeReleaseLoad(result);
  const { steps, ...totals } = summary;
  assert.ok(steps === undefined || (Array.isArray(steps) && steps.length === 0));
  assert.deepEqual(totals, {
    plannedStarts: 7500,
    requests: 7424,
    ok: 7422,
    errors: 1,
    toolErrors: 1,
    droppedSlots: 76,
  });
});

test("fixture revisions must match the whole matrix regardless of order", () => {
  const revisions = ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"];
  assert.doesNotThrow(() => assertFixtureRevisions(revisions));
  assert.doesNotThrow(() => assertFixtureRevisions([...revisions].reverse()));
  assert.throws(() => assertFixtureRevisions([...revisions, "2026-12-01"]));
  assert.throws(() => assertFixtureRevisions(revisions.slice(1)));
  assert.throws(() => assertFixtureRevisions([...revisions, revisions[0]]));
  assert.throws(() => assertFixtureRevisions([...revisions.slice(1), revisions[1]]));
});
