import assert from "node:assert/strict";

export const codecs = ["default", "FoundationJSON"];

export const revisions = [
  { version: "2025-03-26", era: "legacy", invalidParams: true },
  { version: "2025-06-18", era: "legacy", invalidParams: true },
  { version: "2025-11-25", era: "legacy", invalidParams: false },
  { version: "2026-07-28", era: "modern", invalidParams: false },
];

export function assertFixtureRevisions(actual) {
  assert.ok(Array.isArray(actual), "Fixture must list its supported MCP revisions");
  assert.deepEqual(actual.toSorted(), revisions.map(({ version }) => version).toSorted(),
    "Inspector matrix must cover exactly the MCP revisions supported by Limb");
}

export function requiredChecks({ invalidParams }, release) {
  return [
    "initialize", "tools-list", "echo", "protocol-version", "invalid-arguments",
    ...(invalidParams ? ["legacy-wire-error"] : []),
    "short-load", "resource-updates", "persistent-connection", "progress-cancellation",
    ...(release ? ["sustained-load"] : []),
  ];
}
