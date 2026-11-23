import { AssertionError } from "node:assert/strict";
import { linkSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { codecs, requiredChecks, revisions } from "./matrix.mjs";
import { assertReleaseLoadSummary, releaseLoadProfile, summarizeReleaseLoad } from "./verify-release-load.mjs";

const stages = new Set([
  "preparation", "dependencies", "build_default", "verify_default",
  "build_foundation", "verify_foundation", "complete",
]);
function readOptional(path) {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw error;
  }
}

function checkSummary(record, expected) {
  if (!record || typeof record !== "object" || Array.isArray(record)) return undefined;
  const entries = Object.entries(record);
  if (entries.some(([id, status]) => !expected.includes(id) || !["passed", "failed"].includes(status))) {
    return undefined;
  }
  const passed = entries.filter(([, status]) => status === "passed").length;
  return { passed, failed: entries.length - passed, results: Object.fromEntries(entries) };
}

function passedLoad(load) {
  try {
    assertReleaseLoadSummary(load);
    return true;
  } catch (error) {
    if (error instanceof AssertionError) return false;
    throw error;
  }
}

function matrixRow(session, codec, revision) {
  const row = { codec, revision: revision.version };
  const text = readOptional(join(session, "results", `${codec}-${revision.version}.json`));
  if (text === undefined) return { ...row, status: "not_run" };

  let record;
  try {
    record = JSON.parse(text);
  } catch (error) {
    if (error instanceof SyntaxError) return { ...row, status: "failed" };
    throw error;
  }
  const expected = requiredChecks(revision, true);
  const checks = checkSummary(record?.checks, expected);
  const load = summarizeReleaseLoad(record?.load);
  if (record?.status === "running") return { ...row, status: "interrupted", checks, load };
  const passed = record?.status === "passed" && checks?.passed === expected.length && passedLoad(load);
  return { ...row, status: passed ? "passed" : "failed", checks, load };
}

function publish(path, report) {
  const temporary = mkdtempSync(join(dirname(path), ".limb-inspector-"));
  const pending = join(temporary, "report.json");
  try {
    writeFileSync(pending, JSON.stringify(report, null, 2) + "\n");
    linkSync(pending, path);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

const [session, output, commit, stage, exit] = process.argv.slice(2);
if (process.argv.length !== 7 || !session || !output || !/^[a-f0-9]{40}$/.test(commit)
    || !stages.has(stage) || !/^\d{1,3}$/.test(exit) || Number(exit) > 255) {
  console.error("Usage: node release-report.mjs <session-dir> <output.json> <commit> <stage> <run-exit-code>");
  process.exit(2);
}

const matrix = codecs.flatMap((codec) => revisions.map((revision) => matrixRow(session, codec, revision)));
const passed = Number(exit) === 0 && stage === "complete" && matrix.every((row) => row.status === "passed");
const swift = readOptional(join(session, "swift-version.txt"))?.match(/\bSwift version (\d+(?:\.\d+)+)\b/)?.[1] ?? null;
const { dependencies } = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
const report = {
  schemaVersion: 2,
  commit,
  status: passed ? "passed" : "failed",
  profile: releaseLoadProfile,
  toolchain: {
    swift,
    node: process.version,
    inspector: dependencies["@modelcontextprotocol/inspector"],
    mcpClient: dependencies["@modelcontextprotocol/client"],
  },
  platform: { os: process.platform, arch: process.arch },
  matrix,
  failureStage: passed ? undefined : stage,
};

publish(output, report);
console.log(`Release report (${report.status}): ${output}`);
process.exitCode = passed ? 0 : 1;
