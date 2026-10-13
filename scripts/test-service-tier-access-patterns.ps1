[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot,
  [string]$CurrentAsset
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('service-tier-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
foreach ($entry in @(
    @{ Name = 'request.cjs'; Anchor = 'const speedAccessOriginalRe =' },
    @{ Name = 'ui.cjs'; Anchor = 'const speedUiPrefix =' }
  )) {
  $body = $ast.Find({ param($node)
      $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value.Contains($entry.Anchor)
    }, $true)
  if (-not $body) { throw "patcher not found: $($entry.Name)" }
  [IO.File]::WriteAllText((Join-Path $root $entry.Name), $body.Value, $utf8)
}
foreach ($name in @('Test-FastModeRequestTargetText', 'Test-ServiceTierAccessUiTargetText')) {
  $definition = $ast.Find({ param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
  Invoke-Expression $definition.Extent.Text
}
if ($CurrentAsset) {
  $current = [IO.File]::ReadAllText($CurrentAsset)
  if (-not (Test-FastModeRequestTargetText $current) -or
      -not (Test-ServiceTierAccessUiTargetText $current)) { throw 'current asset target discovery failed' }
}
$testPath = Join-Path $root 'behavior.cjs'
[IO.File]::WriteAllText($testPath, @'
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');
const root = __dirname;
let checks = 0;
const request = 'async function bga(e,t){let n=await _ga(e,t);if(n!==`chatgpt`&&n!==`personalAccessToken`)return null;let r=await KPe(e,t,{priority:`critical`});return e.query.setData(Hd,{authMethod:n,hostId:t},r),oee(r)}';
const ui = 'function KVi(e){let t=(0,qVi.c)(10),n=G(Li),r=e?.hostId??n,i=BYe(r),a=i?.authMethod===`chatgpt`||i?.authMethod===`personalAccessToken`,o=i?.authMethod??null,s;t[0]!==r||t[1]!==o?(s={authMethod:o,hostId:r},t[0]=r,t[1]=o,t[2]=s):s=t[2];let{data:c,isPending:l}=Zs(Hd,s),u=!!i?.isLoading||a&&l,d;t[3]!==c||t[4]!==u||t[5]!==a?(d=a&&!u&&c!=null?oee(c):null,t[3]=c,t[4]=u,t[5]=a,t[6]=d):d=t[6];let f=d,p;return t[7]!==u||t[8]!==f?(p={serviceTierAccess:f,isLoading:u},t[7]=u,t[8]=f,t[9]=p):p=t[9],p}var qVi;';
function patch(name, source, expected = 'patched') {
  const file = path.join(root, `fixture-${checks}.js`);
  fs.writeFileSync(file, source);
  const result = spawnSync(process.execPath, [path.join(root, name + '.cjs'), file], {encoding:'utf8'});
  const actual = fs.readFileSync(file, 'utf8');
  if (expected === 'reject') {
    assert.equal(result.status, 2, result.stdout + result.stderr);
    assert.equal(actual, source);
  } else {
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(result.stdout, expected);
    const syntax = spawnSync(process.execPath, ['--check', file], {encoding:'utf8'});
    assert.equal(syntax.status, 0, syntax.stderr);
  }
  checks++;
  return actual;
}
function convert(data) {
  const f = data.requirements?.featureRequirements;
  const fast = f?.fast_mode !== false;
  return {fast, ultrafast:(data.supportsIndependentSpeedModes === true || fast) && f?.ultrafast_mode !== false};
}
async function checkRequest(source) {
  for (const auth of ['chatgpt', 'personalAccessToken', 'apikey', 'amazonBedrock', null]) {
    for (const fast of [true, false, undefined]) for (const ultra of [true, false, undefined]) {
      for (const independent of [true, false]) {
        const events = [];
        const data = {requirements:{featureRequirements:{fast_mode:fast,ultrafast_mode:ultra}},supportsIndependentSpeedModes:independent};
        const manager = {query:{setData(key, args, actual) {
          assert.equal(key, 'requirements');
          assert.equal(args.authMethod, auth);
          assert.equal(args.hostId, 'host');
          assert.equal(actual, data);
          events.push('cache');
        }}};
        const fn = vm.runInNewContext(source + ';bga', {
          Hd:'requirements',
          _ga:async (m, host) => {assert.equal(m, manager);assert.equal(host, 'host');events.push('auth');return auth;},
          KPe:async (m, host, options) => {assert.equal(m, manager);assert.equal(host, 'host');assert.equal(options.priority, 'critical');events.push('requirements');return data;},
          oee:actual => {assert.equal(actual, data);events.push('convert');return convert(actual);},
        }, {timeout:1000});
        assert.deepEqual(await fn(manager, 'host'), convert(data));
        assert.deepEqual(events, ['auth','requirements','cache','convert']);
        checks++;
      }
    }
  }
  for (const failedAt of ['auth','requirements','cache','convert']) {
    const failure = new Error(failedAt);
    const step = name => {if (name === failedAt) throw failure;};
    const fn = vm.runInNewContext(source + ';bga', {
      Hd:0,_ga:async()=>{step('auth');return 'apikey';},
      KPe:async()=>{step('requirements');return {};},
      oee:()=>step('convert'),
    });
    await assert.rejects(fn({query:{setData:()=>step('cache')}}, 'host'), e => e === failure);
    checks++;
  }
}
function checkUi(source) {
  let state;
  const memo = Array(10).fill(Symbol.for('react.memo_cache_sentinel'));
  const fn = vm.runInNewContext(source + ';KVi', {
    qVi:{c:()=>memo},Li:0,Hd:'requirements',G:()=> 'default-host',
    BYe:host => {assert.equal(host, state.host);return state.auth;},
    Zs:(key, args) => {
      assert.equal(key, 'requirements');assert.equal(args.hostId, state.host);
      assert.equal(args.authMethod, state.auth?.authMethod ?? null);
      return {data:state.data,isPending:state.pending};
    },oee:convert,
  });
  for (const auth of ['chatgpt','personalAccessToken','apikey','amazonBedrock',null]) {
    for (const loading of [true,false]) for (const pending of [true,false]) {
      for (const fast of [true,false,undefined]) for (const ultra of [true,false,undefined]) {
        for (const present of [true,false]) {
          state = {host:checks % 2 ? 'explicit-host':'default-host',auth:auth === null ? null:{authMethod:auth,isLoading:loading},pending,
            data:present ? {requirements:{featureRequirements:{fast_mode:fast,ultrafast_mode:ultra}},supportsIndependentSpeedModes:true}:null};
          const result = fn(state.host === 'default-host' ? undefined:{hostId:state.host});
          const isLoading = (state.auth?.isLoading === true) || pending;
          assert.equal(result.isLoading, isLoading);
          const expected = !isLoading && present ? convert(state.data):null;
          assert.deepEqual(JSON.parse(JSON.stringify(result.serviceTierAccess)), expected);
          checks++;
        }
      }
    }
  }
}
(async()=>{
  const patchedRequest = patch('request', request);
  assert.equal(patch('request', patchedRequest, 'already-patched'), patchedRequest);
  await checkRequest(patchedRequest);
  const patchedUi = patch('ui', ui);
  assert.equal(patch('ui', patchedUi, 'already-patched'), patchedUi);
  assert.equal(patchedUi.replace('/*CODEX_SERVICE_TIER_ACCESS_UI_V1*/!0', 'i?.authMethod===`chatgpt`||i?.authMethod===`personalAccessToken`'), ui);
  checkUi(patchedUi);
  for (const source of [request + request,request + patchedRequest,patchedRequest + patchedRequest,
    request.replace('hostId:t','hostId:other'),request.replace('oee(r)','oee(other)'),request.replace('return null','return!1')]) patch('request', source, 'reject');
  for (const source of [ui + ui,ui + patchedUi,patchedUi + patchedUi,
    ui.replace('oee(c)','oee(other)'),ui.replace('isLoading:u','isLoading:other'),
    patchedUi.replace('oee(c)','oee(other)'),
    ui + '/*CODEX_SERVICE_TIER_ACCESS_UI_V1*/const unknown=1;',
    patchedUi + '/*CODEX_SERVICE_TIER_ACCESS_UI_V1*/const unknown=1;',
    '/*CODEX_SERVICE_TIER_ACCESS_UI_V1*/const unknown=1;']) patch('ui', source, 'reject');
  const renamed = request.replaceAll('bga','request$').replaceAll('_ga','auth$').replaceAll('KPe','requirements$').replaceAll('oee','convert$');
  patch('request', renamed);
  if (process.argv[2]) {
    const current = fs.readFileSync(process.argv[2], 'utf8');
    const first = patch('request', current);
    const second = patch('ui', first);
    assert.equal(patch('request', second, 'already-patched'), second);
    assert.equal(patch('ui', second, 'already-patched'), second);
    assert.equal(second.replace('/*CODEX_SERVICE_TIER_ACCESS_UI_V1*/!0','i?.authMethod===`chatgpt`||i?.authMethod===`personalAccessToken`')
      .replace('let n=await _ga(e,t);let r=await KPe(e,t,{priority:`critical`})','let n=await _ga(e,t);if(n!==`chatgpt`&&n!==`personalAccessToken`)return null;let r=await KPe(e,t,{priority:`critical`})'), current);
    checks++;
  }
  console.log(`SERVICE_TIER_ACCESS_PASSED checks=${checks}`);
})().catch(error=>{console.error(error);process.exitCode=1;});
'@, $utf8)
$node = (Get-Command node).Source
& $node $testPath $CurrentAsset
if ($LASTEXITCODE -ne 0) { throw 'service-tier access regression failed' }
Write-Output "Service-tier access regression passed: $root"
