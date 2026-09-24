[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot,
  [string]$PatchScriptPath
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[test-computer-use-surface]'
$scriptPath = if ([string]::IsNullOrWhiteSpace($PatchScriptPath)) {
  Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
} else { $PatchScriptPath }

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $scriptPath,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
  throw "patch script did not parse: $($parseErrors[0].Message)"
}

$patcherAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value.Contains("const marker = 'CODEX_CUA_WINDOWS_SURFACE_V1';") -and
      $node.Value.Contains('current CUA surface anchors not found exactly once')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded Windows CUA surface patcher was not found in the patch script'
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the Windows CUA surface regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('computer-use-surface-' + [guid]::NewGuid().ToString('N'))
if (-not [IO.Path]::GetFullPath($fixtureRoot).StartsWith($temp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'fixture root is outside TemporaryRoot'
}
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchComputerUseSurface.cjs'
[System.IO.File]::WriteAllText($patcherPath, $patcherAst.Value, [System.Text.UTF8Encoding]::new($false))

function Invoke-PatcherFixture {
  param(
    [string]$Name,
    [string]$Source,
    [int]$ExpectedExitCode
  )

  $assetPath = Join-Path $fixtureRoot ($Name + '.js')
  [System.IO.File]::WriteAllText($assetPath, $Source, [System.Text.UTF8Encoding]::new($false))
  $previousErrorActionPreference = $ErrorActionPreference
  $hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
  $previousNativePreference = $null
  try {
    $ErrorActionPreference = 'Continue'
    if ($hasNativePreference) {
      $previousNativePreference = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
    }
    $output = @(& $node.Source $patcherPath $assetPath 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($hasNativePreference) {
      $PSNativeCommandUseErrorActionPreference = $previousNativePreference
    }
  }
  if ($exitCode -ne $ExpectedExitCode) {
    throw "$Name patcher exit mismatch: expected=$ExpectedExitCode actual=$exitCode output=$($output -join ' | ')"
  }
  return [pscustomobject]@{
    AssetPath = $assetPath
    Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
  }
}

$positiveSource = @'
function exposePlugin(r,i,a,e){if(!r.installed||i==null||a&&e.platform!==`darwin`)return null;return true;}
function buildSurface(f,l,t,u){let p;p=f&&l.platform===`darwin`&&t.computerUse&&u.enabled&&u.paths.serviceAppPath!=null;return p;}
'@
$gateSource = $positiveSource
$positiveSource += '/*computerUseNodeRepl*/'
$positive = Invoke-PatcherFixture -Name 'current-darwin-gates' -Source $positiveSource -ExpectedExitCode 0
if ($positive.Output -cne 'patched') {
  throw "positive fixture did not report patched: $($positive.Output)"
}
$patched = [System.IO.File]::ReadAllText($positive.AssetPath)
if (-not $patched.Contains('CODEX_CUA_WINDOWS_SURFACE_V1')) {
  throw 'positive fixture is missing the patch marker'
}
if (-not $patched.Contains('e.platform!==`darwin`&&e.platform!==`win32`')) {
  throw 'positive fixture did not admit win32 in the plugin exposure gate'
}
if (-not $patched.Contains('l.platform===`win32`&&t.computerUse&&t.computerUseNodeRepl)')) {
  throw 'positive fixture did not admit win32 in the generated CUA surface gate'
}
& $node.Source --check $positive.AssetPath 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw 'positive fixture produced invalid JavaScript'
}

$secondOutput = @(& $node.Source $patcherPath $positive.AssetPath 2>&1)
if ($LASTEXITCODE -ne 0 -or (($secondOutput -join "`n").Trim() -cne 'already-patched')) {
  throw "positive fixture was not idempotent: exit=$LASTEXITCODE output=$($secondOutput -join ' | ')"
}
if ([IO.File]::ReadAllText($positive.AssetPath) -cne $patched) {
  throw 'idempotent invocation changed the patched file'
}

$legacyPatched = $patched.Replace('l.platform===`win32`&&t.computerUse)', 'l.platform===`win32`&&t.computerUse&&t.computerUseNodeRepl)')
$legacy = Invoke-PatcherFixture -Name 'legacy-patched-surface' -Source $legacyPatched -ExpectedExitCode 0
if ($legacy.Output -cne 'already-patched' -or [IO.File]::ReadAllText($legacy.AssetPath) -cne $legacyPatched) {
  throw 'legacy patched surface was not preserved'
}

$behaviorPath = Join-Path $fixtureRoot 'behavior.cjs'
[IO.File]::WriteAllText($behaviorPath, @'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context);
let cases = 0;
for (const platform of ['darwin', 'win32', 'linux']) {
  for (const f of [false, true]) for (const computerUse of [false, true])
  for (const computerUseNodeRepl of [undefined, false, true]) for (const enabled of [false, true])
  for (const serviceAppPath of [null, '/service']) {
    const expected = f && computerUse && (platform === 'win32' ? computerUseNodeRepl :
      platform === 'darwin' && enabled && serviceAppPath !== null);
    const actual = context.buildSurface(f, {platform}, {computerUse, computerUseNodeRepl},
      {enabled, paths: {serviceAppPath}});
    assert.equal(actual, expected, JSON.stringify({platform,f,computerUse,computerUseNodeRepl,enabled,serviceAppPath}));
    cases++;
  }
  for (const installed of [false, true]) for (const skill of [null, 'skill'])
  for (const computerPlugin of [false, true]) {
    const expected = !installed || skill === null || computerPlugin && !['darwin','win32'].includes(platform) ? null : true;
    assert.equal(context.exposePlugin({installed}, skill, computerPlugin, {platform}), expected);
    cases++;
  }
}
console.log(`CUA_BEHAVIOR_MATRIX_PASSED cases=${cases}`);
'@, [Text.UTF8Encoding]::new($false))
& $node.Source $behaviorPath $positive.AssetPath
if ($LASTEXITCODE -ne 0) { throw 'CUA platform/feature behavior matrix failed' }

$modernReadiness = 'function ready(t,o,a,n,e,s){return t.browserUseTinysky&&!o&&a.nodePath!=null&&a.nodeReplPath!=null&&n.Gu(e,`mcpToolExposure`)&&s?.plugin.installed===!0&&s.plugin.enabled&&s.plugin.availability===`AVAILABLE`}'
$modernSource = $gateSource + $modernReadiness
$modern = Invoke-PatcherFixture -Name 'current-without-node-repl-flag' -Source $modernSource -ExpectedExitCode 0
$modernPatched = [IO.File]::ReadAllText($modern.AssetPath)
if ($modern.Output -cne 'patched' -or $modernPatched.Contains('computerUseNodeRepl')) {
  throw 'modern layout must not add a removed feature dependency'
}
$modernSecond = Invoke-PatcherFixture -Name 'modern-idempotent' -Source $modernPatched -ExpectedExitCode 0
if ($modernSecond.Output -cne 'already-patched' -or [IO.File]::ReadAllText($modernSecond.AssetPath) -cne $modernPatched) {
  throw 'modern layout is not idempotent'
}
$modernBehaviorPath = Join-Path $fixtureRoot 'modern-behavior.cjs'
[IO.File]::WriteAllText($modernBehaviorPath, @'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context);
let cases = 0;
for (const platform of ['darwin', 'win32', 'linux']) {
  for (const f of [false, true]) for (const computerUse of [false, true])
  for (const enabled of [false, true]) for (const serviceAppPath of [null, '/service']) {
    const expected = f && computerUse && (platform === 'win32' ||
      platform === 'darwin' && enabled && serviceAppPath !== null);
    assert.equal(context.buildSurface(f, {platform}, {computerUse}, {enabled, paths:{serviceAppPath}}), expected);
    cases++;
  }
}
for (const browserUseTinysky of [false, true]) for (const wsl of [false, true])
for (const nodePath of [null, '/node']) for (const nodeReplPath of [null, '/repl'])
for (const exposure of [false, true]) for (const installed of [false, true])
for (const enabled of [false, true]) for (const availability of ['AVAILABLE','DISABLED']) {
  const ready = !!context.ready({browserUseTinysky}, wsl, {nodePath,nodeReplPath},
    {Gu:()=>exposure,Wu:()=>exposure}, 'version', {plugin:{installed,enabled,availability}});
  const expected = browserUseTinysky && !wsl && nodePath !== null && nodeReplPath !== null &&
    exposure && installed && enabled && availability === 'AVAILABLE';
  assert.equal(ready, expected);
  assert.equal(context.buildSurface(ready,{platform:'win32'},{computerUse:true},{enabled:false,paths:{serviceAppPath:null}}),expected);
  cases++;
}
console.log(`MODERN_CUA_BEHAVIOR_MATRIX_PASSED cases=${cases}`);
'@, [Text.UTF8Encoding]::new($false))
& $node.Source $modernBehaviorPath $modern.AssetPath
if ($LASTEXITCODE -ne 0) { throw 'modern CUA readiness/platform behavior matrix failed' }
& $node.Source --check $modern.AssetPath
if ($LASTEXITCODE -ne 0) { throw 'modern CUA output syntax check failed' }

$negativeSource = 'const unrelated={platform:`darwin`,computerUse:true};'
$negative = Invoke-PatcherFixture -Name 'unknown-layout' -Source $negativeSource -ExpectedExitCode 2
if ($negative.Output -cne 'current CUA surface anchors not found exactly once: plugin=0 surface=0') {
  throw "unknown layout failed for the wrong reason: $($negative.Output)"
}
if ([System.IO.File]::ReadAllText($negative.AssetPath) -cne $negativeSource) {
  throw 'unknown layout was modified'
}

$duplicateSource = $positiveSource + $positiveSource
$duplicate = Invoke-PatcherFixture -Name 'duplicate-anchors' -Source $duplicateSource -ExpectedExitCode 2
if ($duplicate.Output -cne 'current CUA surface anchors not found exactly once: plugin=2 surface=2') {
  throw "duplicate anchors failed for the wrong reason: $($duplicate.Output)"
}
if ([System.IO.File]::ReadAllText($duplicate.AssetPath) -cne $duplicateSource) {
  throw 'duplicate-anchor fixture was modified'
}

function Assert-RejectedUnchanged {
  param([string]$Name, [string]$Source)
  $result = Invoke-PatcherFixture -Name $Name -Source $Source -ExpectedExitCode 2
  if ([IO.File]::ReadAllText($result.AssetPath) -cne $Source) {
    throw "$Name was modified despite rejection"
  }
}

# PR #62 must migrate using the verified layout, not just the marker.
$modernGate = 'p=f&&t.computerUse&&(l.platform===`darwin`&&u.enabled&&u.paths.serviceAppPath!=null||l.platform===`win32`)'
$pr62Gate = 'p=f&&(l.platform===`darwin`&&t.computerUse&&u.enabled&&u.paths.serviceAppPath!=null||l.platform===`win32`&&t.computerUse)'
$legacyGate = 'p=f&&(l.platform===`darwin`&&t.computerUse&&u.enabled&&u.paths.serviceAppPath!=null||l.platform===`win32`&&t.computerUse&&t.computerUseNodeRepl)'
foreach ($migration in @(
  @{ Name='pr62-modern'; Source=$modernPatched.Replace($modernGate,$pr62Gate); Expected=$modernPatched },
  @{ Name='pr62-legacy'; Source=$patched.Replace($legacyGate,$pr62Gate); Expected=$patched },
  @{ Name='old-patch-on-modern'; Source=$modernPatched.Replace($modernGate,$legacyGate); Expected=$modernPatched }
)) {
  $result = Invoke-PatcherFixture $migration.Name $migration.Source 0
  if ($result.Output -cne 'patched' -or [IO.File]::ReadAllText($result.AssetPath) -cne $migration.Expected) {
    throw "migration failed: $($migration.Name)"
  }
  $again = Invoke-PatcherFixture ($migration.Name+'-again') $migration.Expected 0
  if ($again.Output -cne 'already-patched' -or [IO.File]::ReadAllText($again.AssetPath) -cne $migration.Expected) { throw 'migration is not idempotent' }
}
foreach ($source in @($modernSource, $modernPatched, $modernPatched.Replace($modernGate,$pr62Gate))) {
  Assert-RejectedUnchanged ('corrupt-ready-'+[guid]::NewGuid()) ($source.Replace('t.browserUseTinysky','t.unknownFlag'))
  Assert-RejectedUnchanged ('duplicate-ready-'+[guid]::NewGuid()) ($source + $modernReadiness)
}
Assert-RejectedUnchanged 'missing-readiness' $gateSource
Assert-RejectedUnchanged 'mixed-readiness' ($modernSource + '/*computerUseNodeRepl*/')
Write-Output 'PR62_MIGRATION_AND_READINESS_GUARDS_PASSED'

$source8451 = $modernSource.Replace('n.Gu(', 'n.Wu(')
$result8451 = Invoke-PatcherFixture 'store-8451' $source8451 0
$patched8451 = [IO.File]::ReadAllText($result8451.AssetPath)
if ($result8451.Output -cne 'patched' -or $patched8451 -cne $modernPatched.Replace('n.Gu(', 'n.Wu(')) { throw '8451 migration mismatch' }
& $node.Source $modernBehaviorPath $result8451.AssetPath
if ($LASTEXITCODE) { throw '8451 readiness behavior matrix failed' }
$again8451 = Invoke-PatcherFixture 'store-8451-again' $patched8451 0
if ($again8451.Output -cne 'already-patched') { throw '8451 not idempotent' }
Assert-RejectedUnchanged 'mixed-ready-symbols' ($source8451 + $modernReadiness)
Assert-RejectedUnchanged 'unknown-ready-symbol' ($source8451.Replace('n.Wu(', 'n.Unknown('))
Assert-RejectedUnchanged 'corrupt-ready-8451' ($source8451.Replace('a.nodePath!=null', 'true'))

Assert-RejectedUnchanged 'marker-only' '/*CODEX_CUA_WINDOWS_SURFACE_V1*/const unrelated=1;'
Assert-RejectedUnchanged 'marker-with-original-gates' ($positiveSource + '/*CODEX_CUA_WINDOWS_SURFACE_V1*/')
Assert-RejectedUnchanged 'marker-with-corrupt-gate' ($patched.Replace('t.computerUseNodeRepl)', 't.unknownFlag)'))
Assert-RejectedUnchanged 'mixed-current-legacy-patches' ($patched + $legacyPatched)
Assert-RejectedUnchanged 'patched-without-marker' ($patched.Replace('/*CODEX_CUA_WINDOWS_SURFACE_V1*/', ''))
Assert-RejectedUnchanged 'duplicate-marker' ($patched + '/*CODEX_CUA_WINDOWS_SURFACE_V1*/')
Assert-RejectedUnchanged 'duplicate-patched-gates' ($patched + $patched)
Assert-RejectedUnchanged 'mixed-original-patched' ($positiveSource + $patched)
$originalPluginGate = 'if(!r.installed||i==null||a&&e.platform!==`darwin`)return null;'
$patchedPluginGate = 'if(!r.installed||i==null||a&&(e.platform!==`darwin`&&e.platform!==`win32`))return null;'
Assert-RejectedUnchanged 'partial-plugin-only' ($positiveSource.Replace($originalPluginGate, $patchedPluginGate))
Assert-RejectedUnchanged 'missing-plugin-gate' ($positiveSource.Replace($originalPluginGate, ''))

# Import only reviewed function definitions; never execute the package install entry point.
foreach ($name in @('Find-ComputerUseSurfaceTarget', 'Assert-ComputerUseSurfaceOptions', 'Patch-ChromePluginWindowsRegistryParsing', 'Invoke-NpxAsar')) {
  $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
  if (-not $functionAst) { throw "missing testable function: $name" }
  . ([scriptblock]::Create($functionAst.Extent.Text))
}
function Fail([string]$Message) { throw $Message }
function Write-Log([string]$Message) { Write-Verbose $Message }
function Assert-Fails {
  param([scriptblock]$Action, [string]$Pattern)
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -like $Pattern) { return }
    throw
  }
  throw "expected failure matching: $Pattern"
}

$selectionRoot = Join-Path $fixtureRoot 'selection'
$buildRoot = Join-Path $selectionRoot '.vite\build'
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
$candidate = Join-Path $buildRoot 'renamed-main.js'
$metadata = '/*CUA_REPL_ENABLED_SURFACES cuaReplSurfaces computerUseNodeRepl*/'
[IO.File]::WriteAllText($candidate, $positiveSource + $metadata)
if ((Find-ComputerUseSurfaceTarget $selectionRoot) -cne $candidate) { throw 'content-based selection failed' }
$metadata = '/*CUA_REPL_ENABLED_SURFACES cuaReplSurfaces*/'
[IO.File]::WriteAllText($candidate, $modernSource + $metadata)
if ((Find-ComputerUseSurfaceTarget $selectionRoot) -cne $candidate) { throw '26.917 selection without retired flag failed' }
[IO.File]::WriteAllText($candidate, $source8451 + $metadata)
if ((Find-ComputerUseSurfaceTarget $selectionRoot) -cne $candidate) { throw '8451 selection failed' }
[IO.File]::WriteAllText($candidate, $patched + $metadata)
if ((Find-ComputerUseSurfaceTarget $selectionRoot) -cne $candidate) { throw 'patched target selection failed' }
$secondCandidate = Join-Path $buildRoot 'second-main.js'
[IO.File]::WriteAllText($secondCandidate, $positiveSource + $metadata)
Assert-Fails { Find-ComputerUseSurfaceTarget $selectionRoot } '*exactly one*found 2*'
Remove-Item -LiteralPath $secondCandidate
[IO.File]::WriteAllText($candidate, 'const unrelated=1;')
Assert-Fails { Find-ComputerUseSurfaceTarget $selectionRoot } '*exactly one*found 0*'
[IO.File]::WriteAllText($candidate, '/*CODEX_CUA_WINDOWS_SURFACE_V1*/')
if ((Find-ComputerUseSurfaceTarget $selectionRoot) -cne $candidate) { throw 'incomplete marker must reach strict patch validation' }
Assert-Fails { Find-ComputerUseSurfaceTarget (Join-Path $fixtureRoot 'missing') } '*vite build directory not found*'

$OnlyComputerUseSurface = $true
$OnlyBrowserComputerUse = $false
$OnlyModelExperience = $false
$OnlyBundledMarketplaceCopy = $false
$AddLocalPluginMarketplace = $false
$VerifyFastModeRequest = $false
Assert-ComputerUseSurfaceOptions
foreach ($option in @('OnlyBrowserComputerUse','OnlyModelExperience','OnlyBundledMarketplaceCopy','AddLocalPluginMarketplace','VerifyFastModeRequest')) {
  Set-Variable -Name $option -Value $true
  Assert-Fails { Assert-ComputerUseSurfaceOptions } '*OnlyComputerUseSurface cannot be combined*'
  Set-Variable -Name $option -Value $false
}
$guardCall = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-ComputerUseSurfaceOptions' }, $true)
$outputRootCall = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Resolve-OutputRoot' }, $true)
if (-not $guardCall -or $guardCall.Extent.StartOffset -ge $outputRootCall.Extent.StartOffset) {
  throw 'mode conflicts must be rejected before resolving or creating the output root'
}

$workApp = Join-Path $fixtureRoot 'work-app'
$chromeScripts = Join-Path $workApp 'resources\plugins\openai-bundled\plugins\chrome\scripts'
New-Item -ItemType Directory -Force -Path $chromeScripts | Out-Null
$chromeFile = Join-Path $chromeScripts 'installed-browsers.js'
$chromeOriginal = 'if (match && match[1] === label) return stripRegistryString(match[2]);'
[IO.File]::WriteAllText($chromeFile, $chromeOriginal)
if ((Patch-ChromePluginWindowsRegistryParsing $workApp) -cne 'skipped-targeted-computer-use-surface' -or
    [IO.File]::ReadAllText($chromeFile) -cne $chromeOriginal) {
  throw 'targeted CUA mode modified the unrelated Chrome plugin'
}
$OnlyComputerUseSurface = $false
if ((Patch-ChromePluginWindowsRegistryParsing $workApp) -cne 'patched') { throw 'normal Chrome patch path regressed' }
Write-Output 'CUA_FAIL_CLOSED_SELECTION_AND_SCOPE_PASSED'

& {
  function Invoke-FakeAsarRunner {
    $script:asarRunnerArguments = @($args)
    $global:LASTEXITCODE = $script:asarRunnerExit
  }
  function Get-Command {
    param([string]$Name, [string]$ErrorAction)
    if ($Name -cne 'npx') { throw "unexpected command lookup: $Name" }
    if ($useNpx) { [pscustomobject]@{ Source = 'Invoke-FakeAsarRunner' } }
  }
  function Get-RequiredCommand {
    param([string]$Name)
    if ($Name -cne 'pnpm') { throw "unexpected fallback lookup: $Name" }
    $script:asarFallbackRequested = $true
    [pscustomobject]@{ Source = 'Invoke-FakeAsarRunner' }
  }
  foreach ($useNpx in @($true, $false)) {
    $script:asarFallbackRequested = $false
    $script:asarRunnerExit = 0
    Invoke-NpxAsar 'extract' 'source' 'target'
    $expectedArguments = if ($useNpx) { '--yes|asar|extract|source|target' } else { 'dlx|asar|extract|source|target' }
    if (($script:asarRunnerArguments -join '|') -cne $expectedArguments -or
        $script:asarFallbackRequested -ne (-not $useNpx)) {
      throw 'ASAR runner selection or arguments are incorrect'
    }
    $script:asarRunnerExit = 23
    Assert-Fails { Invoke-NpxAsar 'extract' 'source' 'target' } '*ASAR extract failed with exit code 23*'
  }
  $global:LASTEXITCODE = 0
}
Write-Output 'ASAR_RUNNER_FALLBACK_PASSED'

& {
  # Execute the production automatic-repair branch with real surface selection and
  # patching. Other gates are already patched; packing is isolated from Desktop.
  $branch = $ast.Find({ param($n)
    $n -is [System.Management.Automation.Language.IfStatementAst] -and
    $n.Clauses[0].Item1.Extent.Text -ceq '$OnlyBrowserComputerUse'
  }, $true)
  if (-not $branch) { throw 'automatic Browser/Computer Use branch missing' }
  $body = $branch.Clauses[0].Item2.Extent.Text
  $fixturePatcherRoot = Split-Path -Parent $scriptPath
  $runBranch = [scriptblock]::Create($body.Substring(1, $body.Length - 2).Replace('$PSScriptRoot', '$fixturePatcherRoot'))
  $extractDir = $selectionRoot
  $nodePath = $node.Source
  $patchers = @{ BrowserUse='browser'; ComputerUse='computer'; NodeReplTrustedPaths='trusted'; CustomModels='models'; ComputerUseSurface=$patcherPath }
  $asarPath = Join-Path $fixtureRoot 'automatic-app.asar'
  $newAsarPath = Join-Path $fixtureRoot 'automatic-new.asar'
  $IncludeCustomModelVisibility = $true
  $DryRun = $false
  $script:automaticPackCount = 0
  function Write-Log { param($Message) }
  function Find-BrowserComputerUsePatchTargets { return @{} }
  function Find-CustomModelsPatchTarget { return $candidate }
  function Invoke-NodePatcher {
    param($NodePath, $Patcher, $Arguments)
    if ($Patcher -ne $patcherPath) { return 'already-patched' }
    $result = & $NodePath $Patcher @Arguments 2>&1
    if ($LASTEXITCODE) { throw 'surface patch rejected fixture' }
    return ($result -join "`n").Trim()
  }
  function Invoke-NpxAsar {
    param($Action, $Source, $Target)
    if ($Action -ne 'pack') { throw 'unexpected ASAR action' }
    $script:automaticPackCount++
    [IO.File]::WriteAllText($Target, [IO.File]::ReadAllText($candidate))
  }
  [IO.File]::WriteAllText($candidate, $positiveSource + $metadata)
  if ((& $runBranch) -ne $true -or $script:automaticPackCount -ne 1 -or
      -not [IO.File]::ReadAllText($asarPath).Contains('CODEX_CUA_WINDOWS_SURFACE_V1')) {
    throw 'automatic mode skipped the new surface patch when older gates were already patched'
  }
  if ((& $runBranch) -ne $false -or $script:automaticPackCount -ne 1) {
    throw 'automatic mode repacked an already patched surface'
  }
  $DryRun = $true
  [IO.File]::WriteAllText($candidate, $positiveSource + $metadata)
  if ((& $runBranch) -ne $false -or $script:automaticPackCount -ne 1) {
    throw 'automatic dry run packed an artifact'
  }
  $DryRun = $false
  [IO.File]::WriteAllText($candidate, 'const unknownLayout=1;')
  Assert-Fails { & $runBranch } '*exactly one*found 0*'
  [IO.File]::WriteAllText($candidate, '/*CODEX_CUA_WINDOWS_SURFACE_V1*/')
  Assert-Fails { & $runBranch } '*surface patch rejected*'
  [IO.File]::WriteAllText($candidate, $positiveSource + $metadata)
  [IO.File]::WriteAllText($secondCandidate, $positiveSource + $metadata)
  Assert-Fails { & $runBranch } '*exactly one*found 2*'
  if ($script:automaticPackCount -ne 1) { throw 'failed surface validation packed an artifact' }
  Write-Output 'AUTOMATIC_CUA_SURFACE_INTEGRATION_PASSED'
}

Remove-Item -LiteralPath $fixtureRoot -Recurse
Write-Output "Windows CUA surface regression passed: $fixtureRoot"
