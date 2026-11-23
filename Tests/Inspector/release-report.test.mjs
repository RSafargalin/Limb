import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const reporter = fileURLToPath(new URL("./release-report.mjs", import.meta.url));
const commit = "0123456789abcdef0123456789abcdef01234567";
const codecs = ["default", "FoundationJSON"];
const revisions = ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"];
const cells = codecs.flatMap((codec) => revisions.map((revision) => ({ codec, revision })));

const functionalChecks = [
  "initialize",
  "tools-list",
  "echo",
  "protocol-version",
  "invalid-arguments",
  "short-load",
  "resource-updates",
  "persistent-connection",
  "progress-cancellation",
];

function passingRow({ revision }, droppedSlots = 0) {
  const requests = 7500 - droppedSlots;
  const checks = [...functionalChecks, "sustained-load"];
  if (revision === "2025-03-26" || revision === "2025-06-18") {
    checks.push("legacy-wire-error");
  }
  const steps = [
    { name: "echo", requests: Math.floor(requests / 4) * 2 + Number(requests % 4 > 0) },
    { name: "read-item", requests: Math.floor((requests + 2) / 4) },
    { name: "greet", requests: Math.floor((requests + 1) / 4) },
  ].map((step) => ({ ...step, ok: step.requests, errors: 0, toolErrors: 0 }));
  return {
    status: "passed",
    checks: Object.fromEntries(checks.map((id) => [id, "passed"])),
    load: {
      plannedStarts: 7500,
      requests,
      ok: requests,
      errors: 0,
      toolErrors: 0,
      droppedSlots,
      steps,
      wire: { matched: requests, startWindowMs: 29_500, p50Ms: 1, p95Ms: 5 },
    },
  };
}

function checkSummary(results) {
  return {
    passed: Object.values(results).filter((status) => status === "passed").length,
    failed: Object.values(results).filter((status) => status === "failed").length,
    results,
  };
}

async function session(t) {
  const directory = await mkdtemp(join(tmpdir(), "limb-release-report-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const results = join(directory, "results");
  const output = join(directory, "report.json");
  await mkdir(results);
  await writeFile(
    join(directory, "swift-version.txt"),
    "Apple Swift version 6.2.3 (swiftlang-test clang-test)\nTarget: arm64-apple-macosx26.0\n",
  );

  const writeRaw = ({ codec, revision }, text) =>
    writeFile(join(results, codec + "-" + revision + ".json"), text);
  const writeRow = (cell, row) => writeRaw(cell, JSON.stringify(row));
  const writePassingMatrix = () => Promise.all(cells.map((cell) => writeRow(cell, passingRow(cell))));
  const run = ({ sha = commit, stage = "complete", exitCode = "0" } = {}) => {
    const result = spawnSync(process.execPath, [reporter, directory, output, sha, stage, exitCode], {
      encoding: "utf8",
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    return result;
  };
  const readReport = async () => JSON.parse(await readFile(output, "utf8"));
  return { directory, output, writeRaw, writeRow, writePassingMatrix, run, readReport };
}

function assertExit(result, expected) {
  assert.equal(result.status, expected, result.stdout + result.stderr);
}

function assertMatrix(report) {
  assert.equal(report.matrix.length, cells.length);
  const cellKey = ({ codec, revision }) => codec + "/" + revision;
  assert.deepEqual(report.matrix.map(cellKey).sort(), cells.map(cellKey).sort());
}

function rowFor(report, cell) {
  return report.matrix.find(({ codec, revision }) => codec === cell.codec && revision === cell.revision);
}

test("reports a complete passing matrix and strips private diagnostic data", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();
  const row = passingRow(cells[0]);
  row.logPath = "/private/test/inspector.log";
  row.checkDetails = ["secret check output"];
  row.load.latencies = [14, 17];
  row.load.steps[0].rawLatency = 14;
  await fixture.writeRow(cells[0], row);

  assertExit(fixture.run(), 0);
  const report = await fixture.readReport();
  assert.doesNotMatch(JSON.stringify(report), /secret check output|\/private\/test\/inspector\.log/);
  assert.equal(report.schemaVersion, 2);
  assert.equal(report.commit, commit);
  assert.equal(report.status, "passed");
  const packageUrl = new URL("./package.json", import.meta.url);
  const { dependencies } = JSON.parse(await readFile(packageUrl, "utf8"));
  assert.deepEqual(report.toolchain, {
    swift: "6.2.3",
    node: process.version,
    inspector: dependencies["@modelcontextprotocol/inspector"],
    mcpClient: dependencies["@modelcontextprotocol/client"],
  });
  assert.deepEqual(report.platform, { os: process.platform, arch: process.arch });
  assert.deepEqual(report.profile, {
    openLoop: true,
    durationSeconds: 30,
    ratePerSecond: 250,
    concurrency: 16,
    minimumStartFraction: 0.99,
  });
  assertMatrix(report);
  for (const cell of cells) {
    const reportedRow = rowFor(report, cell);
    const expected = passingRow(cell);
    assert.equal(reportedRow.status, expected.status);
    assert.deepEqual(reportedRow.checks, checkSummary(expected.checks));
    assert.deepEqual(reportedRow.load, expected.load);
    assert.equal(reportedRow.logPath, undefined);
  }
  assert.equal(report.failureStage, undefined);
});

test("reports completed, failed and unstarted rows after an interrupted matrix", async (t) => {
  const fixture = await session(t);
  const running = { initialize: "passed", "tools-list": "passed" };
  const failed = { ...running, echo: "failed" };
  await fixture.writeRow(cells[0], passingRow(cells[0]));
  await fixture.writeRow(cells[1], { status: "failed", checks: failed });
  await fixture.writeRow(cells[2], { status: "running", checks: running });
  await fixture.writeRow(cells[3], { ...passingRow(cells[3]), status: "running" });

  assertExit(fixture.run({ stage: "verify_default", exitCode: "1" }), 1);
  const report = await fixture.readReport();
  assert.equal(report.status, "failed");
  assert.equal(report.failureStage, "verify_default");
  assertMatrix(report);
  assert.equal(rowFor(report, cells[0]).status, "passed");
  assert.equal(rowFor(report, cells[1]).status, "failed");
  assert.deepEqual(rowFor(report, cells[1]).checks, checkSummary(failed));
  assert.equal(rowFor(report, cells[2]).status, "interrupted");
  assert.deepEqual(rowFor(report, cells[2]).checks, checkSummary(running));
  assert.equal(rowFor(report, cells[3]).status, "interrupted");
  for (const cell of cells.slice(4)) {
    assert.deepEqual(rowFor(report, cell), { ...cell, status: "not_run" });
  }
});

test("rejects malformed rows even when the runner reports success", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();
  await fixture.writeRaw(cells[0], "{");
  const missingLoad = passingRow(cells[1]);
  delete missingLoad.load;
  await fixture.writeRow(cells[1], missingLoad);
  const incorrectLoad = passingRow(cells[2]);
  incorrectLoad.load.steps[0].requests -= 1;
  await fixture.writeRow(cells[2], incorrectLoad);
  const incorrectChecks = passingRow(cells[3]);
  incorrectChecks.checks.echo = "failed";
  await fixture.writeRow(cells[3], incorrectChecks);

  assertExit(fixture.run(), 1);
  const report = await fixture.readReport();
  assert.equal(report.status, "failed");
  assertMatrix(report);
  for (const cell of cells.slice(0, 4)) {
    assert.notEqual(rowFor(report, cell).status, "passed");
  }
  for (const cell of cells.slice(4)) {
    assert.equal(rowFor(report, cell).status, "passed");
  }
});

test("a nonzero runner exit fails an otherwise passing report", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();

  assertExit(fixture.run({ exitCode: "2" }), 1);
  const report = await fixture.readReport();
  assert.equal(report.status, "failed");
  assertMatrix(report);
});

test("accepts 99 percent of planned starts and rejects dropping one additional start", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();
  for (const [cell, droppedSlots] of [[cells[0], 75], [cells[1], 76]]) {
    await fixture.writeRow(cell, passingRow(cell, droppedSlots));
  }

  assertExit(fixture.run(), 1);
  const report = await fixture.readReport();
  assert.equal(rowFor(report, cells[0]).status, "passed");
  assert.equal(rowFor(report, cells[0]).load.droppedSlots, 75);
  assert.notEqual(rowFor(report, cells[1]).status, "passed");
});

test("a missing result fails the report even when the runner exits successfully", async (t) => {
  const fixture = await session(t);
  await Promise.all(cells.slice(1).map((cell) => fixture.writeRow(cell, passingRow(cell))));

  assertExit(fixture.run(), 1);
  const report = await fixture.readReport();
  assert.equal(report.status, "failed");
  assertMatrix(report);
  assert.deepEqual(rowFor(report, cells[0]), { ...cells[0], status: "not_run" });
});

test("reports preparation failures when Swift toolchain metadata has not been collected", async (t) => {
  const fixture = await session(t);
  await rm(join(fixture.directory, "swift-version.txt"));

  assertExit(fixture.run({ stage: "preparation", exitCode: "1" }), 1);
  const report = await fixture.readReport();
  assert.equal(report.failureStage, "preparation");
  assert.equal(report.toolchain.swift, null);
  assertMatrix(report);
  assert.ok(report.matrix.every(({ status }) => status === "not_run"));
});

test("does not overwrite an existing report file", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();
  await writeFile(fixture.output, "existing report");

  assertExit(fixture.run(), 1);
  assert.equal(await readFile(fixture.output, "utf8"), "existing report");
});

test("does not follow an output symlink", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();
  const target = join(fixture.directory, "target.json");
  await writeFile(target, "existing target");
  await symlink(target, fixture.output);

  assertExit(fixture.run(), 1);
  assert.equal(await readFile(target, "utf8"), "existing target");
  assert.equal(await readFile(fixture.output, "utf8"), "existing target");
});

test("rejects unexpected CLI metadata without writing a report", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();

  for (const args of [{ sha: "not-a-commit" }, { stage: "/private/test/log" }, { exitCode: "no" }]) {
    const result = fixture.run(args);
    assert.notEqual(result.status, 0);
    await assert.rejects(fixture.readReport(), { code: "ENOENT" });
  }
});

test("requires the exact named checks for each revision", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();

  const missingLegacy = passingRow(cells[0]);
  delete missingLegacy.checks["legacy-wire-error"];
  await fixture.writeRow(cells[0], missingLegacy);
  const replacement = passingRow(cells[1]);
  delete replacement.checks.echo;
  replacement.checks["some-other-check"] = "passed";
  await fixture.writeRow(cells[1], replacement);
  const unexpectedLegacy = passingRow(cells[2]);
  unexpectedLegacy.checks["legacy-wire-error"] = "passed";
  await fixture.writeRow(cells[2], unexpectedLegacy);
  const missingLoadCheck = passingRow(cells[3]);
  delete missingLoadCheck.checks["sustained-load"];
  await fixture.writeRow(cells[3], missingLoadCheck);

  assertExit(fixture.run(), 1);
  const report = await fixture.readReport();
  for (const cell of cells.slice(0, 4)) {
    assert.notEqual(rowFor(report, cell).status, "passed");
  }
  for (const cell of cells.slice(4)) {
    assert.equal(rowFor(report, cell).status, "passed");
  }
});

test("retains safe numeric evidence for failed sustained load", async (t) => {
  const fixture = await session(t);
  const cell = cells[0];
  const row = passingRow(cell, 76);
  row.status = "failed";
  row.checks["sustained-load"] = "failed";
  row.load.ok -= 2;
  row.load.errors = 1;
  row.load.toolErrors = 1;
  row.load.steps[0].ok -= 2;
  row.load.steps[0].errors = 1;
  row.load.steps[0].toolErrors = 1;
  delete row.load.wire;
  const expected = structuredClone(row.load);
  row.load.rawLatency = [25, 100];
  row.load.steps[0].logPath = "/private/test/inspector.log";
  await fixture.writeRow(cell, row);

  assertExit(fixture.run({ stage: "verify_default", exitCode: "1" }), 1);
  const report = await fixture.readReport();
  const reportedRow = rowFor(report, cell);
  assert.equal(reportedRow.status, "failed");
  assert.deepEqual(reportedRow.checks, checkSummary(row.checks));
  assert.deepEqual(reportedRow.load, expected);
});

test("requires consistent wire evidence for every passing sustained-load row", async (t) => {
  const fixture = await session(t);
  await fixture.writePassingMatrix();
  const invalidate = [
    (load) => { delete load.wire; },
    (load) => { load.wire.matched -= 1; },
    (load) => { load.wire.startWindowMs = 28_999; },
    (load) => { load.wire.p50Ms = -1; },
    (load) => { load.wire.p95Ms = load.wire.p50Ms - 1; },
  ];
  for (const [index, change] of invalidate.entries()) {
    const row = passingRow(cells[index]);
    change(row.load);
    await fixture.writeRow(cells[index], row);
  }

  assertExit(fixture.run(), 1);
  const report = await fixture.readReport();
  for (const cell of cells.slice(0, invalidate.length)) {
    assert.notEqual(rowFor(report, cell).status, "passed");
  }
  for (const cell of cells.slice(invalidate.length)) {
    assert.equal(rowFor(report, cell).status, "passed");
  }
});
