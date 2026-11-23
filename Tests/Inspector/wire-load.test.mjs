import assert from 'node:assert/strict';
import test from 'node:test';
import { checkWireLoad } from './verify-wire-load.mjs';

const request = (at, id, method, params) => ({
  direction: 'request', at, message: { jsonrpc: '2.0', id, method, params },
});
const response = (at, id, result) => ({
  direction: 'response', at, message: { jsonrpc: '2.0', id, result },
});
const echoParams = (text) => ({ name: 'echo', arguments: { text } });
const echoResult = (text) => ({
  content: [{ type: 'text', text }], resultType: 'complete',
});

function shortTrace() {
  return [
    request(0, 'setup', 'logging/setLevel', { level: 'info' }),
    response(1, 'setup', { resultType: 'complete' }),
    request(10, 1, 'tools/call', echoParams('inspector-load-1')),
    request(20, '1', 'tools/call', echoParams('inspector-load-2')),
    { direction: 'response', at: 21, message: { jsonrpc: '2.0', method: 'notifications/message' } },
    response(30, '1', echoResult('inspector-load-2')),
    response(40, 1, echoResult('inspector-load-1')),
  ];
}

const shortSummary = { requests: 2, steps: [{ name: 'echo', requests: 2 }] };
const shortOptions = { modern: true, mixed: false };

test('short wire load matches out-of-order replies by typed ID and measures traced timing', () => {
  const evidence = checkWireLoad(shortTrace(), shortSummary, shortOptions);
  assert.equal(evidence.matched, 2);
  assert.equal(evidence.startWindowMs, 10);
  assert.ok(evidence.p50Ms >= 10);
  assert.ok(evidence.p95Ms >= evidence.p50Ms && evidence.p95Ms <= 30);
});

test('mixed wire load verifies echo, resource contents, and prompt messages', () => {
  const uri = 'limb-fixture://items/load-2';
  const trace = [
    request(1, 1, 'tools/call', echoParams('load-1-Лимб')),
    request(2, 2, 'resources/read', { uri }),
    request(3, 3, 'prompts/get', { name: 'greet', arguments: { name: 'Ada-3' } }),
    response(4, 3, {
      resultType: 'complete',
      messages: [
        { role: 'user', content: { type: 'text', text: 'Hello, Ada-3.' } },
        { role: 'assistant', content: { type: 'text', text: 'Ready.' } },
      ],
    }),
    response(5, 2, {
      resultType: 'complete',
      contents: [{ uri, mimeType: 'text/plain', text: 'item:load-2' }],
      ttlMs: 0,
      cacheScope: 'private',
    }),
    response(6, 1, echoResult('load-1-Лимб')),
  ];
  const summary = {
    requests: 3,
    steps: ['echo', 'read-item', 'greet'].map((name) => ({ name, requests: 1 })),
  };
  const options = { modern: true, mixed: true };
  assert.equal(checkWireLoad(trace, summary, options).matched, 3);

  for (const change of [
    (frames) => { frames[3].message.result.messages[1].content.text = 'Wait.'; },
    (frames) => { frames[4].message.result.contents[0].text = 'item:load-1'; },
  ]) {
    const wrongResponse = structuredClone(trace);
    change(wrongResponse);
    assert.throws(() => checkWireLoad(wrongResponse, summary, options));
  }
});

for (const [name, change] of [
  ['swapped response payloads with correct aggregate counts', (trace) => {
    const first = trace[5].message;
    const second = trace[6].message;
    [first.result, second.result] = [second.result, first.result];
  }],
  ['wrong resultType for the modern revision', (trace) => {
    trace[5].message.result.resultType = 'partial';
  }],
  ['explicit null isError in a tool result', (trace) => {
    trace[5].message.result.isError = null;
  }],
  ['missing response', (trace) => { trace.pop(); }],
  ['duplicate response', (trace) => {
    trace.push(response(41, 1, echoResult('inspector-load-1')));
  }],
  ['unexpected response ID', (trace) => {
    trace[6].message.id = 99;
  }],
  ['reply before its request', (trace) => {
    const reply = trace.pop();
    reply.at = 5;
    trace.splice(2, 0, reply);
  }],
  ['non-monotonic timestamps', (trace) => { trace[6].at = 29; }],
]) {
  test('wire load rejects ' + name, () => {
    const trace = shortTrace();
    change(trace);
    assert.throws(() => checkWireLoad(trace, shortSummary, shortOptions));
  });
}

test('wire load rejects a request window shorter than the minimum', () => {
  assert.throws(() => checkWireLoad(shortTrace(), shortSummary, {
    ...shortOptions,
    minimumStartWindowMs: 11,
  }));
});

test('wire load rejects step counts that disagree with the observed calls', () => {
  assert.throws(() => checkWireLoad(shortTrace(), {
    requests: 2,
    steps: [{ name: 'echo', requests: 1 }],
  }, shortOptions));
});
