const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const script = fs.readFileSync(path.join(__dirname, 'patch_codex_fast_mode_windows_msix.ps1'), 'utf8').replace(/\r\n/g, '\n');
const anchor = "Set-Content -LiteralPath $bundledMarketplaceCopyPatcherPath -Encoding UTF8 -Value @'\n";
const start = script.indexOf(anchor);
assert.notEqual(start, -1);
const sourceStart = start + anchor.length;
const sourceEnd = script.indexOf("\n'@", sourceStart);
assert.notEqual(sourceEnd, -1);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-marketplace-test-'));
const patcher = path.join(root, 'patcher.cjs');
fs.writeFileSync(patcher, script.slice(sourceStart, sourceEnd));
const nativeCopy = 'require(`./windows-file-copy-fixture.js`);';
const retirement = 'async function retire(client){let{plugins:saved}=await client.getUserSavedConfiguration();typeof saved==`object`&&saved&&!Array.isArray(saved)&&Object.hasOwn(saved,`sites@openai-bundled`)&&await client.uninstallPlugin({pluginId:`sites@openai-bundled`})}';
const research = '{...catalog.plugins.deepResearch,isAvailable:({features:flags})=>flags.deepResearch}';
const sites = '{...catalog.plugins.sites,isAvailable:({features:flags})=>flags.sites}';
let cases = 0;
function run(name, source, expectedStatus, check) {
  const file = path.join(root, name + '.js');
  fs.writeFileSync(file, nativeCopy + source);
  const before = fs.readFileSync(file, 'utf8');
  const result = spawnSync(process.execPath, [patcher, file], { encoding: 'utf8' });
  assert.equal(result.status, expectedStatus, result.stderr);
  const after = fs.readFileSync(file, 'utf8');
  if (expectedStatus) {
    assert.equal(after, before, 'failed recognition must not write the file');
  } else {
    assert.equal(spawnSync(process.execPath, ['--check', file]).status, 0);
    check(after);
    const repeat = spawnSync(process.execPath, [patcher, file], { encoding: 'utf8' });
    assert.equal(repeat.status, 0, repeat.stderr);
    assert.equal(repeat.stdout, 'already-patched');
    assert.equal(fs.readFileSync(file, 'utf8'), after);
  }
  cases++;
}
try {
  run('legacy', `const plugins=[${sites},${research}];`, 0, after => {
    assert.ok(after.includes('codex_windows_sites_bundled_plugin_available'));
    assert.ok(after.includes('codex_windows_deep_research_bundled_plugin_available'));
  });
  run('retired-sites', retirement + `const plugins=[${research}];`, 0, after => {
    assert.ok(after.includes(retirement), 'preserve the retirement function');
    assert.ok(!after.includes('codex_windows_sites_bundled_plugin_available'));
    assert.ok(after.includes('codex_windows_deep_research_bundled_plugin_available'));
  });
  run('missing-sites', `const plugins=[${research}];`, 2);
  run('duplicate-retirement', retirement + retirement.replace('retire(', 'retireAgain(') + `const plugins=[${research}];`, 2);
  run('retirement-with-sites-descriptor', retirement + `const plugins=[{...catalog.plugins.sites,isAvailable:()=>false},${research}];`, 2);
  run('missing-research', retirement + 'const plugins=[];', 2);
  process.stdout.write(`Bundled marketplace regression passed: ${cases} cases\n`);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
