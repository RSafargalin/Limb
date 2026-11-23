import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { assertFixtureRevisions, codecs, requiredChecks, revisions } from "./matrix.mjs";
import { checkLiveConnection, checkResourceNotifications } from "./verify-live.mjs";
import { checkReleaseLoad, releaseLoadProfile, releaseLoadScenario, summarizeReleaseLoad } from "./verify-release-load.mjs";
import { checkProgressAndCancellation } from "./verify-steps.mjs";
import { checkWireLoad } from "./verify-wire-load.mjs";

const launcher = fileURLToPath(new URL(
  "./node_modules/@modelcontextprotocol/inspector/clients/launcher/build/index.js",
  import.meta.url,
));
const traceLauncher = fileURLToPath(new URL("./trace-stdio.mjs", import.meta.url));
const echoText = 'Привет, 世界 🌿 "quoted" \\path\nsecond line\tend';
const timeout = 5_000;
const [binary, codec, resultsDirectory] = process.argv.slice(2);
if (process.argv.length < 4 || process.argv.length > 5 || !binary || !isAbsolute(binary)
    || !codecs.includes(codec) || (resultsDirectory !== undefined && !isAbsolute(resultsDirectory))) {
  console.error("Usage: node Tests/Inspector/verify.mjs <absolute fixture binary> <codec> [<absolute results directory>]");
  process.exit(2);
}

const scenarioPath = resultsDirectory && join(resultsDirectory, "release-load.json");
if (scenarioPath) writeFileSync(scenarioPath, JSON.stringify(releaseLoadScenario));
const fixtureVersions = spawnSync(binary, ["--protocol-versions"], { encoding: "utf8", timeout, killSignal: "SIGKILL" });
assert.ifError(fixtureVersions.error);
assert.equal(fixtureVersions.status, 0, `Could not read the fixture's supported MCP revisions: ${fixtureVersions.stderr}`);
assertFixtureRevisions(fixtureVersions.stdout.trimEnd().split(/\r?\n/));

function inspect({ version, era }, method, options = [], expectedStatus = 0, processTimeout = 15_000, observeResult, tracePath) {
  const server = tracePath === undefined ? [binary, version] : [process.execPath, traceLauncher, binary, version, tracePath];
  const invocation = spawnSync(process.execPath, [
    launcher, "--cli", "--protocol-era", era, "--format", "json",
    "--connect-timeout", String(timeout), "--stored-auth-only", "--method", method,
    ...options, "--", ...server,
  ], {
    encoding: "utf8",
    timeout: processTimeout,
    killSignal: "SIGKILL",
    maxBuffer: 1024 * 1024,
  });

  const { status, stdout, stderr, error, signal } = invocation;
  const output = `stdout: ${JSON.stringify(stdout)}\nstderr: ${JSON.stringify(stderr)}`;
  let result;
  try {
    result = JSON.parse(stdout)?.result;
  } catch {
    // Startup and timeout failures can leave stdout empty or incomplete.
  }
  if (result && typeof result === "object") observeResult?.(result);
  assert.ok(!error, `Inspector process failed: ${error}\n${output}`);
  assert.equal(signal, null, `Inspector terminated by ${signal}\n${output}`);
  assert.equal(status, expectedStatus, `Inspector exited ${status}, expected ${expectedStatus}\n${output}`);

  if (status === 1) {
    assert.equal(stdout.trim(), "", `Invalid params should produce no stdout\n${output}`);
  } else {
    assert.ok(result && typeof result === "object", `Missing or invalid Inspector result envelope\n${output}`);
  }

  let diagnostic;
  if (status !== 0) {
    // JSON mode emits the error envelope on stderr, which can also contain logs.
    const envelopes = [];
    for (const line of stderr.split(/\r?\n/)) {
      try {
        const envelope = JSON.parse(line);
        if (envelope?.error && typeof envelope.error === "object") {
          envelopes.push(envelope.error);
        }
      } catch {
        // Allow plain-text diagnostic lines.
      }
    }
    assert.equal(envelopes.length, 1, `Expected one Inspector error envelope\n${output}`);
    [diagnostic] = envelopes;
  }
  return { result, diagnostic };
}

function inspectRecordedLoad(revision, options, { processTimeout, observeResult, mixed = false } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "limb-inspector-wire."));
  try {
    const path = join(directory, "trace.json");
    const { result } = inspect(revision, "tools/call", options, 0, processTimeout, observeResult, path);
    const wire = checkWireLoad(JSON.parse(readFileSync(path, "utf8")), result, {
      modern: revision.era === "modern",
      mixed,
      minimumStartWindowMs: mixed ? (releaseLoadProfile.durationSeconds - 1) * 1_000 : 0,
    });
    return { result, wire };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function textContent(result) {
  assert.ok(Array.isArray(result.content), "tools/call result needs a content array");
  assert.equal(result.content.length, 1, "Expected one tool content item");
  const [content] = result.content;
  assert.equal(content?.type, "text");
  assert.equal(typeof content.text, "string");
  return content.text;
}

function assertMissingText(message) {
  assert.equal(typeof message, "string", "Expected an invalid-argument diagnostic");
  assert.match(message, /\btext\b[^\n]*\bmissing required field\b/i);
}

async function checkLegacyWireError(version) {
  const client = new Client(
    { name: "limb-inspector-verifier", version: "1" },
    { supportedProtocolVersions: [version], versionNegotiation: { mode: "legacy" } },
  );
  const transport = new StdioClientTransport({
    command: binary,
    args: [version],
    stderr: "ignore",
  });
  try {
    await client.connect(transport, { timeout });
    await assert.rejects(
      client.callTool({ name: "echo", arguments: {} }, { timeout }),
      (error) => {
        assert.equal(error.code, -32602, `Expected JSON-RPC Invalid params. Received ${error}`);
        assertMissingText(error.message);
        return true;
      },
      "The official client should receive a JSON-RPC error for missing text",
    );
  } finally {
    await client.close();
  }
}

async function verify(revision) {
  const { version, era, invalidParams } = revision;
  const label = `${codec} ${version} (${era})`;
  const rowPath = resultsDirectory && join(resultsDirectory, `${codec}-${version}.json`);
  const checks = {};
  let load;
  let failures = 0;

  function checkpoint(status = "running") {
    if (!rowPath) return;
    const pending = `${rowPath}.tmp`;
    writeFileSync(pending, JSON.stringify({ status, checks, load }));
    renameSync(pending, rowPath);
  }

  checkpoint();

  async function check(id, action) {
    try {
      await action();
      checks[id] = "passed";
    } catch (error) {
      checks[id] = "failed";
      failures += 1;
      console.error(`[${label}] ${id}\n${error.stack ?? error}`);
    }
    checkpoint();
  }

  await check("initialize", () => {
    const { result } = inspect(revision, "initialize");
    assert.equal(result.protocolVersion, version);
    assert.equal(result.serverInfo?.name, "limb-inspector-fixture");
  });

  await check("tools-list", () => {
    const { result } = inspect(revision, "tools/list", ["--strict"]);
    assert.ok(Array.isArray(result.tools), "tools/list result needs a tools array");
    assert.deepEqual(result.tools.map((tool) => tool.name).sort(), [
      "collect_preferences", "echo", "protocol_version", "run_steps", "update_status",
    ]);
    for (const [name, argument] of [["echo", "text"], ["run_steps", "mode"], ["update_status", "text"]]) {
      const tool = result.tools.find((tool) => tool.name === name);
      assert.equal(tool.inputSchema?.type, "object", name);
      assert.equal(tool.inputSchema.properties?.[argument]?.type, "string", name);
      assert.deepEqual(tool.inputSchema.required, [argument], name);
    }
    const steps = result.tools.find((tool) => tool.name === "run_steps");
    assert.deepEqual(steps.inputSchema.properties.mode.enum?.toSorted(), ["cancel", "complete", "continue"]);
  });

  await check("echo", () => {
    const { result } = inspect(revision, "tools/call", [
      "--tool-name", "echo", "--tool-args-json", JSON.stringify({ text: echoText }),
    ]);
    assert.equal(result.isError ?? false, false);
    assert.equal(textContent(result), echoText);
  });

  await check("protocol-version", () => {
    const { result } = inspect(revision, "tools/call", ["--tool-name", "protocol_version"]);
    assert.equal(result.isError ?? false, false);
    assert.equal(textContent(result), version);
  });

  await check("invalid-arguments", () => {
    const { result, diagnostic } = inspect(revision, "tools/call", [
      "--tool-name", "echo", "--tool-args-json", "{}",
    ], invalidParams ? 1 : 5);
    if (invalidParams) {
      assert.equal(diagnostic.code, "error");
      assert.match(diagnostic.message, /^Invalid params\b/i);
      assertMissingText(diagnostic.message);
    } else {
      assert.equal(diagnostic.code, "tool_is_error");
      assert.equal(result.isError, true);
      assertMissingText(textContent(result));
    }
  });

  if (invalidParams) {
    await check("legacy-wire-error", () => checkLegacyWireError(version));
  }

  await check("short-load", () => {
    const { result } = inspectRecordedLoad(revision, [
      "--tool-name", "echo", "--tool-arg", "text=inspector-load-{{seq}}",
      "--load", "--load-requests", "20", "--load-concurrency", "4",
      "--load-max-error-rate", "0",
    ]);
    assert.equal(result.concurrency, 4);
    assert.equal(result.requests, 20);
    assert.equal(result.ok, 20);
    assert.equal(result.toolErrors, 0);
    assert.equal(result.errors, 0);
    assert.equal(result.stoppedEarly, undefined);
  });

  await check("resource-updates", () => {
    checkResourceNotifications((options) => inspect(revision, "tools/call", options).result);
  });

  await check("persistent-connection", () => {
    checkLiveConnection(revision, { binary, timeout, echoText, textContent, assertMissingText });
  });

  await check("progress-cancellation", () => {
    return checkProgressAndCancellation(revision, { binary, timeout, echoText, textContent });
  });

  if (scenarioPath) {
    const { durationSeconds } = releaseLoadProfile;
    console.log(`[${label}] ${durationSeconds}s mixed Inspector load`);
    await check("sustained-load", async () => {
      await checkReleaseLoad(
        (options) => {
          const { result, wire } = inspectRecordedLoad(revision, options, {
            mixed: true,
            processTimeout: durationSeconds * 1000 + 15_000,
            observeResult: (observed) => { load = summarizeReleaseLoad(observed); checkpoint(); },
          });
          load = { ...load, wire };
          return result;
        },
        scenarioPath,
      );
    });
  }

  const expected = requiredChecks(revision, Boolean(scenarioPath));
  if (Object.keys(checks).length !== expected.length || !expected.every((id) => Object.hasOwn(checks, id))) {
    failures += 1;
    console.error(`[${label}] Checks did not match the required set`);
  }
  checkpoint(failures ? "failed" : "passed");
  console.log(failures ? `FAIL ${label} (${failures} failed checks)` : `PASS ${label}`);
  return failures;
}

for (const revision of revisions) {
  if (await verify(revision)) {
    process.exitCode = 1;
  }
}
