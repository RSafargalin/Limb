import assert, { AssertionError } from 'node:assert/strict';
import test from 'node:test';
import {
  assertCancelledResponseAbsent,
  assertLoadResponses,
} from './observations.mjs';

const result = (id, value) => ({ jsonrpc: '2.0', id, result: { value } });
const error = (id, message) => ({
  jsonrpc: '2.0', id, error: { code: -32603, message, data: { retryable: false } },
});

test('cancellation allows a same-ID request, unrelated replies, and a notification', () => {
  assert.doesNotThrow(() => assertCancelledResponseAbsent([
    { jsonrpc: '2.0', id: 7, method: 'ping' },
    result('7', 'string ID'),
    error(8, 'unrelated error'),
    { jsonrpc: '2.0', method: 'notifications/progress', params: { progressToken: 7, progress: 1 } },
  ], 7));
});

test('cancellation rejects a result for the cancelled ID after unrelated traffic', () => {
  assert.throws(() => assertCancelledResponseAbsent([
    result(8, 'unrelated'),
    { jsonrpc: '2.0', id: 7, method: 'ping' },
    result(7, 'late success'),
  ], 7), AssertionError);
});

test('cancellation rejects an error response for the cancelled ID', () => {
  assert.throws(() => assertCancelledResponseAbsent([
    error(7, 'numeric ID'),
    error('7', 'late error'),
  ], '7'), AssertionError);
});

test('load accepts full result and error responses in any order with distinct typed IDs', () => {
  const expected = [result(1, { count: 3 }), error('1', 'failed')];
  const observed = [error('1', 'failed'), result(1, { count: 3 })];
  assert.doesNotThrow(() => assertLoadResponses(expected, observed));
});

test('load rejects successful replies whose payloads are swapped between IDs', () => {
  const expected = [result(1, 'numeric'), result('1', 'string')];
  const observed = [result('1', 'numeric'), result(1, 'string')];
  assert.throws(() => assertLoadResponses(expected, observed), AssertionError);
});

test('load rejects a full error response with a changed payload', () => {
  const expected = [error(1, 'failed')];
  const observed = [error(1, 'failed')];
  observed[0].error.data.retryable = true;
  assert.throws(() => assertLoadResponses(expected, observed), AssertionError);
});

test('load rejects a duplicate ID even when all expected replies are present', () => {
  const expected = [result(1, 'first'), result(2, 'second')];
  const observed = [result(1, 'first'), result(2, 'second'), result(1, 'first')];
  assert.throws(() => assertLoadResponses(expected, observed), AssertionError);
});

test('load rejects a missing reply', () => {
  const expected = [result(1, 'first'), result(2, 'second')];
  const observed = [result(1, 'first')];
  assert.throws(() => assertLoadResponses(expected, observed), AssertionError);
});

test('load rejects an unexpected reply even when all expected replies are present', () => {
  const expected = [result(1, 'first')];
  const observed = [result(1, 'first'), result('1', 'unexpected')];
  assert.throws(() => assertLoadResponses(expected, observed), AssertionError);
});
