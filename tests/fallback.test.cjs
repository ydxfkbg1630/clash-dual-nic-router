'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { normalizeConfig, createState, decideState, tick, createLogger } = require('../scripts/watch-fallback.cjs');
const config = normalizeConfig({ domesticInterface: 'Ethernet', overseasInterface: 'Wi-Fi' });
const adapters = (domestic, overseas = true) => [{ Name: 'Ethernet', ready: domestic }, { Name: 'Wi-Fi', ready: overseas }];
function fakeApi(initial, options = {}) {
  let current = initial;
  const calls = [];
  const api = async (method, resource, body) => {
    calls.push({ method, resource, body });
    if (options.fail && options.fail(method, resource, calls.length)) throw new Error('Private network details');
    if (method === 'GET') return { 'interface-name': current, mode: 'rule', tun: { enable: true } };
    if (method === 'PATCH' && !options.ignorePatch) current = body['interface-name'];
    return {};
  };
  return { api, calls, drift: value => { current = value; } };
}

test('healthy startup uses campus immediately and an unplug switches to Wi-Fi', async () => {
  const mock = fakeApi('Ethernet');
  let state = await tick(createState(), adapters(true), config, mock.api);
  assert.equal(state.appliedState, 'Ethernet');
  assert.equal(mock.calls.length, 1);
  state = await tick(state, adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Wi-Fi');
  assert.deepEqual(mock.calls.slice(1).map(call => call.method), ['GET', 'PATCH', 'GET', 'DELETE']);
  assert.deepEqual(mock.calls.find(call => call.method === 'PATCH').body, { 'interface-name': 'Wi-Fi' });
});

test('campus recovery requires three consecutive samples and flapping restarts the counter', () => {
  let state = decideState(createState(), adapters(false), config);
  state = decideState(state, adapters(true), config);
  assert.equal(state.target, 'Wi-Fi');
  assert.equal(state.recoveryCount, 1);
  state = decideState(state, adapters(false), config);
  for (let sample = 1; sample <= 3; sample++) {
    state = decideState(state, adapters(true), config);
    assert.equal(state.target, sample === 3 ? 'Ethernet' : 'Wi-Fi');
  }
});

test('both interfaces down preserve applied routing and make no mutation', async () => {
  const mock = fakeApi('Wi-Fi');
  const state = await tick({ ...createState(), appliedState: 'Wi-Fi' }, adapters(false, false), config, mock.api);
  assert.equal(state.status, 'waiting');
  assert.equal(state.appliedState, 'Wi-Fi');
  assert.deepEqual(mock.calls.map(call => call.method), ['GET']);
});

test('campus is used immediately when only campus is available during recovery', () => {
  const down = decideState(createState(), adapters(false), config);
  assert.equal(decideState(down, adapters(true, false), config).target, 'Ethernet');
});

test('GUI reload drift is corrected even when desired state is unchanged', async () => {
  const mock = fakeApi('Wi-Fi');
  let state = await tick(createState(), adapters(false), config, mock.api);
  mock.drift('Ethernet');
  state = await tick(state, adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Wi-Fi');
  assert.equal(state.changed, true);
  assert.equal(mock.calls.filter(call => call.method === 'DELETE').length, 1);
});

test('API failures retain applied state and retry on the next round', async () => {
  let fail = true;
  const mock = fakeApi('Ethernet', { fail: method => fail && method === 'PATCH' });
  const initial = { ...createState(), appliedState: 'Ethernet' };
  let state = await tick(initial, adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Ethernet');
  assert.equal(state.error, 'Mihomo API unavailable');
  assert.equal(mock.calls.filter(call => call.method === 'DELETE').length, 0);
  fail = false;
  state = await tick(state, adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Wi-Fi');
  assert.equal(state.error, null);
});

test('verification mismatch retains applied state and keeps existing connections', async () => {
  const mock = fakeApi('Ethernet', { ignorePatch: true });
  const state = await tick({ ...createState(), appliedState: 'Ethernet' }, adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Ethernet');
  assert.equal(state.error, 'Interface verification failed');
  assert.equal(mock.calls.some(call => call.method === 'DELETE'), false);
});

test('a temporarily stopped core is retried and routing is applied when it starts', async () => {
  let fail = true;
  const mock = fakeApi('Ethernet', { fail: () => fail });
  let state = await tick(createState(), adapters(false), config, mock.api);
  assert.equal(state.appliedState, null);
  assert.equal(state.error, 'Mihomo API unavailable');
  fail = false;
  state = await tick(state, adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Wi-Fi');
  assert.equal(state.error, null);
});

test('a lost verification response refreshes old connections after the next verified GET', async () => {
  const mock = fakeApi('Ethernet', { fail: (method, resource, count) => count === 3 });
  let state = await tick({ ...createState(), appliedState: 'Ethernet' }, adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Ethernet');
  assert.equal(state.closePending, true);
  state = await tick(state, adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Wi-Fi');
  assert.equal(state.closePending, false);
  assert.deepEqual(mock.calls.map(call => call.method), ['GET', 'PATCH', 'GET', 'GET', 'DELETE']);
});

test('connection refresh failure retries after verified transition', async () => {
  let fail = true;
  const mock = fakeApi('Ethernet', { fail: method => fail && method === 'DELETE' });
  let state = await tick(createState(), adapters(false), config, mock.api);
  assert.equal(state.appliedState, 'Wi-Fi');
  assert.equal(state.closePending, true);
  fail = false;
  state = await tick(state, adapters(false), config, mock.api);
  assert.equal(state.closePending, false);
  assert.equal(mock.calls.filter(call => call.method === 'PATCH').length, 1);
  assert.equal(mock.calls.filter(call => call.method === 'DELETE').length, 2);
});

test('stable state polls configuration without reconnecting', async () => {
  const mock = fakeApi('Wi-Fi');
  let state = createState();
  for (let i = 0; i < 4; i++) state = await tick(state, adapters(false), config, mock.api);
  assert.deepEqual(mock.calls.map(call => call.method), ['GET', 'GET', 'GET', 'GET']);
});

test('config validates polling and adapter values and resolves local paths', () => {
  assert.throws(() => normalizeConfig({ domesticInterface: 'a', overseasInterface: 'a' }));
  assert.throws(() => normalizeConfig({ ...config, intervalSeconds: 0 }));
  assert.throws(() => normalizeConfig({ ...config, recoverySamples: 1.5 }));
  assert.throws(() => normalizeConfig({ ...config, pipeName: '../pipe' }));
  assert.equal(normalizeConfig({ ...config, stateFile: 'state.json' }, os.tmpdir()).stateFile, path.join(os.tmpdir(), 'state.json'));
});

test('logs retain the previous generation when 256 KiB is reached', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fallback-test-'));
  try {
    const file = path.join(dir, 'watcher.log');
    fs.writeFileSync(file, 'x'.repeat(256 * 1024));
    createLogger(file)({ status: 'wifi' });
    assert.equal(fs.statSync(`${file}.last`).size, 256 * 1024);
    assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).status, 'wifi');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
