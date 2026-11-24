import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const modernVersion = '2026-07-28';
const legacyVersion = '2025-11-25';
const clientInfo = { name: 'readme-smoke', version: '1.0.0' };
const text = 'Привет';
const codec = process.argv[2] ?? 'default';
assert.ok(process.argv.length <= 3 && ['default', 'FoundationJSON'].includes(codec),
  'Usage: node Tests/Inspector/readme-smoke.mjs [default|FoundationJSON]');

function swiftBuild(directory, args, capture = false) {
  const result = spawnSync('swift', ['build', ...args], {
    cwd: directory,
    encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    timeout: 15 * 60 * 1000,
    killSignal: 'SIGKILL',
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `swift build ${args.join(' ')} exited with ${result.signal ?? result.status}`);
  return result.stdout?.trim();
}

async function checkEcho(executable, modern) {
  const child = spawn(executable, { stdio: ['pipe', 'pipe', 'inherit'] });
  const exited = once(child, 'close');
  // Attach a handler immediately so spawn errors also surface if the conversation fails first.
  exited.catch(() => {});
  const reader = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const lines = reader[Symbol.asyncIterator]();
  let inputError;
  child.stdin.on('error', (error) => { inputError = error; });
  const meta = modern ? {
    _meta: {
      'io.modelcontextprotocol/protocolVersion': modernVersion,
      'io.modelcontextprotocol/clientInfo': clientInfo,
      'io.modelcontextprotocol/clientCapabilities': {},
    },
  } : {};

  function send(message) {
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
  }

  async function receive(id) {
    for (;;) {
      const line = await lines.next();
      if (line.done) {
        throw inputError ?? new Error(`EchoServer closed stdout before responding to request ${id}`);
      }
      const message = JSON.parse(line.value);
      assert.equal(message.jsonrpc, '2.0');
      if (typeof message.method === 'string' && !Object.hasOwn(message, 'id')) continue;
      assert.equal(message.id, id);
      assert.ok(!Object.hasOwn(message, 'error'), JSON.stringify(message));
      assert.ok(Object.hasOwn(message, 'result'), JSON.stringify(message));
      return message.result;
    }
  }

  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(
      `Timed out checking README EchoServer over ${modern ? modernVersion : legacyVersion} stdio`
    )), 15_000);
  });
  try {
    const conversation = async () => {
      if (modern) {
        send({ id: 1, method: 'server/discover', params: meta });
        const discovery = await receive(1);
        assert.equal(discovery.resultType, 'complete');
        assert.ok(discovery.supportedVersions.includes(modernVersion));
      } else {
        send({ id: 1, method: 'initialize', params: {
          protocolVersion: legacyVersion, capabilities: {}, clientInfo,
        } });
        const initialization = await receive(1);
        assert.equal(initialization.protocolVersion, legacyVersion);
        send({ method: 'notifications/initialized' });
      }

      send({ id: 2, method: 'tools/call', params: {
        name: 'echo', arguments: { text }, ...meta,
      } });
      const echo = await receive(2);
      if (modern) assert.equal(echo.resultType, 'complete');
      if (Object.hasOwn(echo, 'isError')) assert.equal(echo.isError, false);
      assert.deepEqual(echo.content, [{ type: 'text', text }]);
      child.stdin.end();
      const [code, signal] = await exited;
      assert.equal(signal, null);
      assert.equal(code, 0);
    };
    await Promise.race([conversation(), deadline]);
  } finally {
    clearTimeout(timer);
    child.stdin.destroy();
    child.kill('SIGKILL');
    reader.close();
    await exited.catch(() => {});
  }
}

const readme = await readFile(join(repository, 'README.md'), 'utf8');
const swiftBlocks = [...readme.matchAll(/^```swift\r?\n([\s\S]*?)^```[ \t]*$/gm)]
  .map((match) => match[1]);
const manifests = swiftBlocks.filter((block) => block.startsWith('// swift-tools-version:'));
const sources = swiftBlocks.filter((block) => block.includes('@main'));
assert.equal(manifests.length, 1, 'Expected exactly one Swift manifest in README.md');
assert.equal(sources.length, 1, 'Expected exactly one Swift executable in README.md');
const taggedDependency = /\.package\(url:\s*"https:\/\/github\.com\/RSafargalin\/Limb\.git",\s*exact:\s*"[^"]+"\)/g;
assert.equal([...manifests[0].matchAll(taggedDependency)].length, 1,
  'Expected exactly one tagged Limb dependency in the README manifest');
const traits = codec === 'FoundationJSON' ? ', traits: ["FoundationJSON"]' : '';
const manifest = manifests[0].replace(taggedDependency,
  `.package(name: "Limb", path: "../Limb"${traits})`);

const directory = await mkdtemp(join(tmpdir(), 'limb-readme-smoke-'));
try {
  const fixture = join(directory, 'EchoServer');
  const sourceDirectory = join(fixture, 'Sources', 'EchoServer');
  await mkdir(sourceDirectory, { recursive: true });
  await symlink(repository, join(directory, 'Limb'), 'dir');
  await writeFile(join(fixture, 'Package.swift'), manifest);
  await writeFile(join(sourceDirectory, 'EchoServer.swift'), sources[0]);

  swiftBuild(fixture, []);
  const executable = join(swiftBuild(fixture, ['--show-bin-path'], true), 'EchoServer');
  await checkEcho(executable, true);
  await checkEcho(executable, false);
  console.log(`README EchoServer passed with ${codec} over MCP ${modernVersion} and ${legacyVersion}`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
