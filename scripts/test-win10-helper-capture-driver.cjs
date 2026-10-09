const assert = require('node:assert/strict');
const {test} = require('node:test');
const {validatePlatform, validateTarget, selectWindow, approveTestWindow, decodeScreenshot} = require('./win10-helper-capture-driver.cjs');
const config = {token: 'fixture', targetProcessId: 42};
const state = {token: 'fixture', processId: 42, windowId: 99, foreground: true, timestamp: 1000};
const window = {app: 'test.exe', id: 99, title: 'Codex Win10 Capture Test fixture'};

test('accepts Win10 client and rejects Win11, Server, other platforms and failed OS probes', () => {
  validatePlatform('win32', 19045, 1);
  for (const args of [['win32', 26300, 1], ['win32', 19045, 3], ['linux', 19045, 1],
    ['win32', 9600, 1], ['win32', NaN, 1], ['win32', 19045, NaN]]) {
    assert.throws(() => validatePlatform(...args));
  }
});

test('accepts the fresh foreground target owned by this run', () => {
  assert.equal(validateTarget(state, config, 1500), state);
  assert.equal(selectWindow([window], state, config.token), window);
});
for (const [name, changed] of [
  ['focus moved to another application', {foreground: false}],
  ['target process replaced', {processId: 43}],
  ['state came from a different run', {token: 'other'}],
  ['test window no longer has a handle', {windowId: 0}],
  ['test target stopped updating', {timestamp: -1000}],
  ['state timestamp is malformed', {timestamp: '1000'}]
]) {
  test(`stops when ${name}`, () => assert.throws(() => validateTarget({...state, ...changed}, config, 1500)));
}
test('refuses another window with the same title and a duplicate identity', () => {
  assert.throws(() => selectWindow([{...window, id: 100}], state, config.token));
  assert.throws(() => selectWindow([window, window], state, config.token));
});
test('approval is confined to the test app and Computer Use connector', () => {
  const request = {meta: {connector_id: 'computer-use', tool_params: {app: 'test.exe'}}};
  assert.deepEqual(approveTestWindow(request, window.app), {action: 'accept'});
  assert.throws(() => approveTestWindow(request, 'other.exe'));
  assert.throws(() => approveTestWindow({meta: {connector_id: 'other', tool_params: {app: window.app}}}, window.app));
});
test('accepts inline image bytes and rejects paths, URLs and malformed image headers', () => {
  const bytes = Buffer.from('ffd8ff001122', 'hex');
  assert.deepEqual(decodeScreenshot({url: `data:image/jpeg;base64,${bytes.toString('base64')}`}).bytes, bytes);
  for (const url of ['file:///C:/private.png', 'https://example.test/private.png',
    'data:image/jpeg;base64,AAAA', 'data:image/jpeg;base64,abc']) {
    assert.throws(() => decodeScreenshot({url}));
  }
});
