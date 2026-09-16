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
if (-not $patched.Contains('l.platform===`win32`') -or -not $patched.Contains('t.computerUseNodeRepl')) {
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
  for (const computerUseNodeRepl of [false, true]) for (const enabled of [false, true])
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

Assert-RejectedUnchanged 'marker-only' '/*CODEX_CUA_WINDOWS_SURFACE_V1*/const unrelated=1;'
Assert-RejectedUnchanged 'marker-with-original-gates' ($positiveSource + '/*CODEX_CUA_WINDOWS_SURFACE_V1*/')
Assert-RejectedUnchanged 'marker-with-corrupt-gate' ($patched.Replace('t.computerUseNodeRepl', 't.unknownFlag'))
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
[IO.File]::WriteAllText($candidate, $patched + $metadata)
if ((Find-ComputerUseSurfaceTarget $selectionRoot) -cne $candidate) { throw 'patched target selection failed' }
$secondCandidate = Join-Path $buildRoot 'second-main.js'
[IO.File]::WriteAllText($secondCandidate, $positiveSource + $metadata)
Assert-Fails { Find-ComputerUseSurfaceTarget $selectionRoot } '*exactly one*found 2*'
Remove-Item -LiteralPath $secondCandidate -Force
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

Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
Write-Output "Windows CUA surface regression passed: $fixtureRoot"
