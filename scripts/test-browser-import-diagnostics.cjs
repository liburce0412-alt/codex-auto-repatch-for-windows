const assert = require('node:assert/strict');
const vm = require('node:vm');
const { patchSource } = require('./patch-browser-import-diagnostics.cjs');

const source = 'class Importer{logger={error(){}};/*browser-profile-import*/constructor(session){this.session=session;this.allowed=true}get #e(){return this.session}async isImportAllowed(){return this.allowed}async importBrowserProfile(e){if(!await this.isImportAllowed())throw Error(`disabled by managed policy`);let t=e;await this.#e.browserProfileImporter.list();return await this.#e.browserProfileImporter.import(t)}async listImportableBrowserProfiles(){return []}}';
const result = patchSource(source);
assert.equal(result.status, 'patched');
assert.equal(patchSource(result.source).status, 'already-patched');
assert.equal(patchSource(result.source).source, result.source);
assert.equal(patchSource('class Legacy{}').status, 'not-applicable');
assert.throws(() => patchSource(source + source), /exactly once/);
assert.throws(() => patchSource('browserProfileImporter'), /exactly once/);
assert.throws(() => patchSource(source.replace('}async listImportableBrowserProfiles(){', '}async renamed(){')), /boundary/);
assert.throws(() => patchSource(source.replace('this.isImportAllowed()', 'this.otherPolicy()')), /shape/);
assert.throws(() => patchSource(source + '/*CODEX_BROWSER_IMPORT_DIAGNOSTICS_V1*/'), /incomplete/);
assert.throws(() => patchSource(result.source.replace('throw importError}', 'throw Error(`changed`)}')), /incomplete/);

(async () => {
  const Importer = vm.runInNewContext(result.source + ';Importer', { Error });
  const expected = { cookies: { status: 'success' } };
  const request = { importCookies: true };
  let calls = 0;
  const native = { list: async () => [], import: async input => {
    assert.equal(input, request); calls++; return expected;
  } };
  const subject = new Importer({ browserProfileImporter: native });
  const logs = [];
  subject.logger.error = (...args) => logs.push(args);
  assert.equal(await subject.importBrowserProfile(request), expected);
  assert.equal(calls, 1);
  assert.equal(logs.length, 0);
  const nativeError = new Error('Browser import helper returned no response.');
  native.import = async () => { throw nativeError; };
  await assert.rejects(subject.importBrowserProfile(request), error => error === nativeError);
  assert.equal(logs[0][0], 'Browser profile import exception');
  assert.equal(logs[0][1].sensitive.error, nativeError);
  assert.deepEqual(Object.keys(logs[0][1].safe), ['errorName']);
  assert.deepEqual(Object.keys(logs[0][1].sensitive), ['error']);
  subject.logger.error = () => { throw new Error('logger failed'); };
  await assert.rejects(subject.importBrowserProfile(request), error => error === nativeError);
  const listError = new Error('list failed');
  native.list = async () => { throw listError; };
  await assert.rejects(subject.importBrowserProfile(request), error => error === listError);
  subject.allowed = false;
  await assert.rejects(subject.importBrowserProfile(request), /disabled by managed policy/);
  console.log('BROWSER_IMPORT_DIAGNOSTICS_TESTS_PASSED behavior_cases=5 guard_cases=7');
})().catch(error => { console.error(error); process.exitCode = 1; });
