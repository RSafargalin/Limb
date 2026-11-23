import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const mcpdo = fileURLToPath(new URL(
  "./node_modules/@modelcontextprotocol/inspector/clients/mcpdo/build/mcp-bin.js",
  import.meta.url,
));
const connection = "limb-fixture";
const statusURI = "limb-fixture://state/status";
const preferencesURI = "limb-fixture://state/preferences";
const itemTemplate = "limb-fixture://items/{name}";
const itemURI = "limb-fixture://items/%D0%9B%D0%B8%D0%BC%D0%B1";

export function checkResourceNotifications(inspectToolCall) {
  const result = inspectToolCall([
    "--tool-name", "update_status", "--tool-arg", "text=inspector-status-{{seq}}",
    "--load", "--load-subscribe", statusURI, "--load-concurrency", "1",
    "--load-requests", "5", "--load-max-error-rate", "0",
  ]);
  assert.partialDeepStrictEqual(result, {
    concurrency: 1,
    requests: 5,
    ok: 5,
    toolErrors: 0,
    errors: 0,
    errorRate: 0,
    fanout: {
      uri: statusURI,
      mode: "triggered",
      requested: 1,
      subscribed: 1,
      failed: 0,
      updates: 5,
      delivered: 5,
      missed: 0,
      sessionsMissed: 0,
      unexpected: 0,
    },
  });
  assert.equal(result.stoppedEarly, undefined);
}

function invokeMcpdo(env, args, expectedStatus = 0) {
  const { status, stdout, stderr, error, signal } = spawnSync(process.execPath, [
    mcpdo, "--format", "json", "--stored-auth-only", ...args,
  ], {
    env,
    encoding: "utf8",
    timeout: 15_000,
    killSignal: "SIGKILL",
    maxBuffer: 1024 * 1024,
  });
  const output = `mcpdo ${args.join(" ")}\nstdout: ${JSON.stringify(stdout)}\nstderr: ${JSON.stringify(stderr)}`;
  assert.ok(!error, `mcpdo process failed: ${error}\n${output}`);
  assert.equal(signal, null, `mcpdo terminated by ${signal}\n${output}`);
  assert.equal(status, expectedStatus, `mcpdo exited ${status}, expected ${expectedStatus}\n${output}`);

  let result;
  if (expectedStatus === 1) {
    assert.equal(stdout.trim(), "", output);
  } else {
    try {
      result = JSON.parse(stdout);
    } catch {
      throw new Error(`Invalid mcpdo JSON on stdout\n${output}`);
    }
  }

  let diagnostic;
  if (expectedStatus !== 0) {
    for (const line of stderr.split(/\r?\n/)) {
      try {
        diagnostic = JSON.parse(line)?.error;
      } catch {
        continue;
      }
      if (diagnostic) break;
    }
    assert.ok(diagnostic, `Missing mcpdo error envelope\n${output}`);
  }
  return { result, diagnostic };
}

function checkElicitation({ version, era }, { run, read, textContent }) {
  const toolName = "collect_preferences";
  const collect = () => run(["tools/call", toolName]).result;
  const respond = (id, answer) => run(["elicitation/respond", id, answer]).result;
  const assertResult = (result, text) => {
    assert.equal(result.elicitationPending, undefined);
    assert.equal(result.isError ?? false, false);
    assert.equal(textContent(result), text);
  };

  read(preferencesURI, "0:unset");
  if (version === "2025-03-26") {
    assertResult(collect(), "elicitation unavailable");
    read(preferencesURI, "0:unset");
    return;
  }

  const seenIDs = new Set();
  const assertForm = (result, message, field, schema) => {
    const pending = result.elicitationPending;
    assert.ok(pending, `Expected a parked elicitation for ${field}`);
    assert.equal(result.content, undefined);
    assert.partialDeepStrictEqual(pending, {
      connection,
      method: "tools/call",
      toolName,
      mode: "form",
      message,
      origin: era === "modern" ? "input-required" : "server-request",
    });
    assert.equal(pending.requestedSchema.type, "object");
    assert.deepEqual(pending.requestedSchema.properties, { [field]: schema });
    assert.deepEqual(pending.requestedSchema.required, [field]);
    const id = pending.elicitationId;
    assert.equal(typeof id, "string");
    assert.ok(id.length > 0 && !seenIDs.has(id), `Expected a new elicitation ID, got ${id}`);
    seenIDs.add(id);
    return id;
  };
  const requestName = () => assertForm(collect(), "What name should we use?", "name", { type: "string" });
  const submitName = (id, name) => assertForm(
    respond(id, JSON.stringify({ name })),
    `Which color should we use for ${name}?`,
    "color",
    { type: "string", enum: ["blue", "green"] },
  );

  // The Inspector daemon rejects ordinary RPCs while an elicitation is parked.
  assertResult(respond(requestName(), "--decline"), "decline:name");
  read(preferencesURI, "0:unset");
  assertResult(respond(submitName(requestName(), "Alan"), "--cancel"), "cancel:color");
  read(preferencesURI, "0:unset");
  const colorID = submitName(requestName(), "Ada");
  assertResult(respond(colorID, JSON.stringify({ color: "blue" })), "1:Ada:blue");
  read(preferencesURI, "1:Ada:blue");

  assertResult(respond(requestName(), "--decline"), "decline:name");
  read(preferencesURI, "1:Ada:blue");
}

export function checkLiveConnection(
  { version, era, invalidParams },
  { binary, timeout, echoText, textContent, assertMissingText },
) {
  // Keep the generated Unix socket path below the operating system's length limit.
  const daemonDir = mkdtempSync("/tmp/li-");
  const env = {
    ...process.env,
    MCP_INSPECTOR_DAEMON_DIR: daemonDir,
    MCP_INSPECTOR_DAEMON_TOKEN: randomUUID(),
  };
  const run = (args, expectedStatus) => invokeMcpdo(
    env, ["--connection", connection, ...args], expectedStatus,
  );
  const read = (uri, text) => {
    const { result } = run(["resources/read", uri]);
    assert.equal(result.contents.length, 1, uri);
    assert.partialDeepStrictEqual(result.contents[0], { uri, mimeType: "text/plain", text });
  };

  const failures = [];
  try {
    run(["connect", "--era", era, "--connect-timeout", String(timeout), "--", binary, version]);
    const { result: details } = run(["connections/show"]);
    assert.partialDeepStrictEqual(details, {
      name: connection,
      protocolEra: era,
      protocolVersion: version,
      serverInfo: { name: "limb-inspector-fixture" },
    });

    const { result: resources } = run(["resources/list"]);
    assert.ok(resources.resources.some(({ uri, name, mimeType }) => (
      uri === statusURI && name === "status" && mimeType === "text/plain"
    )), "resources/list should include the status resource");
    assert.ok(resources.resources.some(({ uri, mimeType }) => (
      uri === preferencesURI && mimeType === "text/plain"
    )), "resources/list should include the preferences resource");
    read(statusURI, "ready");

    const changed = "updated by mcpdo";
    const { result: update } = run(["tools/call", "update_status", JSON.stringify({ text: changed })]);
    assert.equal(update.isError ?? false, false);
    assert.equal(textContent(update), changed);
    read(statusURI, changed);

    const { result: invalid, diagnostic } = run(
      ["tools/call", "update_status", "{}"], invalidParams ? 1 : 5,
    );
    if (invalidParams) {
      assert.equal(diagnostic.code, "error");
      assert.match(diagnostic.message, /^Invalid params\b/i);
      assertMissingText(diagnostic.message);
    } else {
      assert.equal(diagnostic.code, "tool_is_error");
      assert.equal(invalid.isError, true);
      assertMissingText(textContent(invalid));
    }
    read(statusURI, changed);
    const { result: echo } = run(["tools/call", "echo", JSON.stringify({ text: echoText })]);
    assert.equal(echo.isError ?? false, false);
    assert.equal(textContent(echo), echoText);

    const { result: templates } = run(["resources/templates/list"]);
    assert.ok(templates.resourceTemplates.some(({ uriTemplate, name }) => (
      uriTemplate === itemTemplate && name === "item"
    )), "resources/templates/list should include the item template");
    read(itemURI, "item:Лимб");

    const { result: prompts } = run(["prompts/list"]);
    const greet = prompts.prompts.find(({ name }) => name === "greet");
    assert.ok(greet?.arguments?.some(({ name, required }) => name === "name" && required === true),
      "prompts/list should expose greet with a required name argument");
    const { result: prompt } = run(["prompts/get", "greet", "--prompt-args", "name=Ada"]);
    assert.equal(prompt.messages.length, 2);
    assert.partialDeepStrictEqual(prompt.messages[0], {
      role: "user", content: { type: "text", text: "Hello, Ada." },
    });
    assert.partialDeepStrictEqual(prompt.messages[1], {
      role: "assistant", content: { type: "text", text: "Ready." },
    });

    for (const [type, ref, prefix, values] of [
      ["ref/prompt", "greet", "A", ["Ada", "Alan"]],
      ["ref/resource", itemTemplate, "al", ["alpha", "alpine"]],
    ]) {
      const { result } = run([
        "prompts/complete", "--complete-ref-type", type, "--complete-ref", ref,
        "--complete-arg-name", "name", "--complete-arg-value", prefix,
      ]);
      assert.deepEqual(result, { values, total: 2, hasMore: false }, ref);
    }

    checkElicitation({ version, era }, { run, read, textContent });
  } catch (error) {
    failures.push(error);
  } finally {
    try {
      invokeMcpdo(env, ["daemon", "stop"]);
    } catch (error) {
      failures.push(error);
    }
    try {
      rmSync(daemonDir, { recursive: true, force: true });
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length === 1) throw failures[0];
  if (failures.length > 1) {
    throw new AggregateError(
      failures,
      failures.map((error) => error?.stack ?? String(error)).join("\n"),
    );
  }
}
