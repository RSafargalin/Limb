import assert from "node:assert/strict";

export const releaseLoadProfile = {
  durationSeconds: 30,
  ratePerSecond: 250,
  concurrency: 16,
  openLoop: true,
  minimumStartFraction: 0.99,
};

export const releaseLoadScenario = [
  {
    method: "tools/call",
    name: "echo",
    tool: "echo",
    weight: 2,
    args: { text: "load-{{seq}}-Лимб" },
  },
  {
    method: "resources/read",
    name: "read-item",
    uri: "limb-fixture://items/load-{{seq}}",
    weight: 1,
  },
  {
    method: "prompts/get",
    name: "greet",
    prompt: "greet",
    weight: 1,
    args: { name: "Ada-{{seq}}" },
  },
];

const counters = ["requests", "ok", "errors", "toolErrors"];
// Inspector 2.16.0 interleaves weights 2:1:1 in this repeating order.
const cycle = ["echo", "read-item", "greet", "echo"];

function selectCounts(value, keys) {
  if (!value || !keys.every((key) => Number.isSafeInteger(value[key]) && value[key] >= 0)) return undefined;
  return Object.fromEntries(keys.map((key) => [key, value[key]]));
}

export function summarizeReleaseLoad(result) {
  const totals = selectCounts(result, [...counters, "plannedStarts", "droppedSlots"]);
  if (!totals) return undefined;
  if (!Array.isArray(result.steps) || result.steps.length !== releaseLoadScenario.length) return totals;

  const steps = releaseLoadScenario.map(({ name }) => {
    const matches = result.steps.filter((step) => step?.name === name);
    const counts = matches.length === 1 && selectCounts(matches[0], counters);
    return counts && { name, ...counts };
  });
  return steps.every(Boolean) ? { ...totals, steps } : totals;
}

export function assertReleaseLoadSummary(load) {
  assert.ok(load, "Inspector did not report valid load counters");
  const { plannedStarts, requests, ok, errors, toolErrors, droppedSlots, steps } = load;
  const { durationSeconds, ratePerSecond, minimumStartFraction } = releaseLoadProfile;
  const offeredStarts = durationSeconds * ratePerSecond;
  const minimumStarts = Math.ceil(offeredStarts * minimumStartFraction);
  assert.equal(plannedStarts, offeredStarts, "Inspector did not plan the full start window");
  assert.equal(errors, 0, "Inspector reported request errors");
  assert.equal(toolErrors, 0, "Inspector reported tool errors");
  assert.equal(ok, requests, "Inspector did not report success for every request");
  assert.ok(requests >= minimumStarts,
    `Inspector completed ${requests} requests, below the minimum of ${minimumStarts}`);
  assert.equal(requests + droppedSlots, plannedStarts, "Load start counters disagree");
  assert.ok(steps, "Inspector did not report valid scenario step counters");

  const fullCycles = Math.floor(requests / cycle.length);
  const prefix = cycle.slice(0, requests % cycle.length);
  for (const [index, { name, weight }] of releaseLoadScenario.entries()) {
    const step = steps[index];
    const expected = fullCycles * weight + prefix.filter((value) => value === name).length;
    assert.equal(step.requests, expected, `Unexpected number of ${name} calls for the configured mix`);
    assert.equal(step.ok, step.requests, `Inspector did not report success for every ${name} request`);
    assert.equal(step.errors, 0, `Inspector reported request errors for ${name}`);
    assert.equal(step.toolErrors, 0, `Inspector reported tool errors for ${name}`);
  }
}

export async function checkReleaseLoad(inspectLoad, scenarioPath) {
  const { durationSeconds, ratePerSecond, concurrency } = releaseLoadProfile;
  const result = await inspectLoad([
    "--load",
    "--load-duration", String(durationSeconds),
    "--load-rate", String(ratePerSecond),
    "--load-concurrency", String(concurrency),
    "--load-open-loop",
    "--load-scenario", scenarioPath,
    "--load-max-error-rate", "0",
  ]);

  assert.equal(result.rate, ratePerSecond, "Inspector reported an unexpected load rate");
  assert.equal(result.concurrency, concurrency, "Inspector reported unexpected load concurrency");
  assert.equal(result.openLoop, true, "Inspector did not use open-loop scheduling");
  assert.equal(result.stoppedEarly, undefined, "Inspector stopped the load run early");
  assert.ok(
    Number.isFinite(result.elapsedMs) && result.elapsedMs >= durationSeconds * 1000,
    "Inspector did not run for the full load duration",
  );
  const summary = summarizeReleaseLoad(result);
  assertReleaseLoadSummary(summary);
  for (const { name, method, weight, tool, uri, prompt } of releaseLoadScenario) {
    const step = result.steps.find((item) => item?.name === name);
    assert.equal(step.method, method, `Unexpected method for ${name}`);
    assert.equal(step.target, tool ?? uri ?? prompt, `Unexpected target for ${name}`);
    assert.equal(step.weight, weight, `Unexpected weight for ${name}`);
  }
  return summary;
}
