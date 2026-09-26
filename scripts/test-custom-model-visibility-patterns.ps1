[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  throw "patch script is missing: $scriptPath"
}

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

$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Test-CustomModelVisibilityExpression'
  }, $true)
if (-not $functionAst) {
  throw 'custom model visibility expression helper was not found in the patch script'
}
$functionDefinition = [scriptblock]::Create($functionAst.Extent.Text)
. $functionDefinition

$patcherAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value.Contains("const marker = 'CODEX_CUSTOM_MODELS_V1';") -and
      $node.Value.Contains('const visibilityPatterns = [')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded custom model patcher was not found in the patch script'
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the custom model visibility regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('custom-model-visibility-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchCustomModels.cjs'
[System.IO.File]::WriteAllText(
  $patcherPath,
  $patcherAst.Value,
  [System.Text.UTF8Encoding]::new($false)
)

$models = @('gpt-6-astra', 'gpt-6-sol', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
$positiveFixtures = @(
  [pscustomobject]@{
    Name = 'legacy-conditional'
    Source = 'function visible(a,b,c){if(a?b.has(c.model):!c.hidden){return true}return false}'
  },
  [pscustomobject]@{
    Name = 'optional-has-conditional'
    Source = 'function visible(a,b,c,d){if(a?.has(b.model)===!0||(c?d.has(b.model):!b.hidden)){return true}return false}'
  },
  [pscustomobject]@{
    Name = 'amazon-bedrock-return'
    Source = 'function visible(a,b,c,d,e){return a?.has(b.model)===!0||(c&&d!==`amazonBedrock`?e.has(b.model):!b.hidden)}'
  },
  [pscustomobject]@{
    Name = 'codex-26-810-auto-review-return'
    Source = 'function visible(e,i,a,r,t,n){return e?.has(i.model)===!0||i.model!==`codex-auto-review`&&(a&&!r&&t!==`amazonBedrock`?n.has(i.model):!i.hidden)}'
  },
  [pscustomobject]@{
    Name = 'codex-26-825-configured-catalog-return'
    Source = 'function $ii({additionalAvailableModels:e,authMethod:t,availableModels:n,hasConfiguredModelCatalog:r,isCustomModelProvider:i,model:a,useHiddenModels:o}){return e?.has(a.model)===!0||a.model!==`codex-auto-review`&&(r&&!a.hidden||(o&&!i&&t!==`amazonBedrock`?n.has(a.model):!a.hidden))}'
  }
)
$negativeFixture = [pscustomobject]@{
  Name = 'auto-review-unrelated-ternary'
  Source = 'function visible(a,b,c,d){return a?.has(b.model)===!0||b.model!==`codex-auto-review`&&(c?d.has(b.model):!b.hidden)}'
}

function Invoke-NodePatcherFixture {
  param(
    [string]$Name,
    [string]$Source,
    [int]$ExpectedExitCode,
    [string[]]$ModelArguments = $models
  )

  $assetPath = Join-Path $fixtureRoot ($Name + '.js')
  [System.IO.File]::WriteAllText(
    $assetPath,
    $Source,
    [System.Text.UTF8Encoding]::new($false)
  )
  $arguments = @($patcherPath, $assetPath) + $ModelArguments
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $node.Source @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne $ExpectedExitCode) {
    throw "$Name patcher exit mismatch: expected=$ExpectedExitCode actual=$exitCode output=$($output -join ' | ')"
  }
  return [pscustomobject]@{
    AssetPath = $assetPath
    Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
  }
}

$previousNativePreference = $null
$hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
if ($hasNativePreference) {
  $previousNativePreference = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
}
try {
  foreach ($fixture in $positiveFixtures) {
    if (-not (Test-CustomModelVisibilityExpression -Text $fixture.Source)) {
      throw "$($fixture.Name) was rejected by the PowerShell target matcher"
    }

    $result = Invoke-NodePatcherFixture -Name $fixture.Name -Source $fixture.Source -ExpectedExitCode 0
    if ($result.Output -cne 'patched') {
      throw "$($fixture.Name) did not report patched: $($result.Output)"
    }
    $patched = [System.IO.File]::ReadAllText($result.AssetPath)
    if (-not $patched.Contains('CODEX_CUSTOM_MODELS_V1')) {
      throw "$($fixture.Name) is missing the custom model patch marker"
    }
    foreach ($model in $models) {
      if (-not $patched.Contains($model)) {
        throw "$($fixture.Name) is missing patched model: $model"
      }
    }

    $syntaxOutput = @(& $node.Source --check $result.AssetPath 2>&1)
    $syntaxExitCode = $LASTEXITCODE
    if ($syntaxExitCode -ne 0) {
      throw "$($fixture.Name) produced invalid JavaScript: $($syntaxOutput -join ' | ')"
    }

    $secondArguments = @($patcherPath, $result.AssetPath) + $models
    $secondOutput = @(& $node.Source @secondArguments 2>&1)
    $secondExitCode = $LASTEXITCODE
    if ($secondExitCode -ne 0 -or (($secondOutput -join "`n").Trim() -cne 'already-patched')) {
      throw "$($fixture.Name) was not idempotent: exit=$secondExitCode output=$($secondOutput -join ' | ')"
    }
  }

  if (Test-CustomModelVisibilityExpression -Text $negativeFixture.Source) {
    throw "$($negativeFixture.Name) was accepted by the PowerShell target matcher"
  }
  $negativeResult = Invoke-NodePatcherFixture `
    -Name $negativeFixture.Name `
    -Source $negativeFixture.Source `
    -ExpectedExitCode 2
  if ($negativeResult.Output -cne 'custom-model-visibility-target-not-found') {
    throw "$($negativeFixture.Name) failed for the wrong reason: $($negativeResult.Output)"
  }

  if (-not (Test-CustomModelVisibilityExpression -Text '/*CODEX_CUSTOM_MODELS_V1*/')) {
    throw 'the PowerShell target matcher did not recognize an already-patched asset'
  }

  $behaviorPath = Join-Path $fixtureRoot 'model-behavior.cjs'
  [IO.File]::WriteAllText($behaviorPath, @'
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const c = vm.createContext({});
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), c);
for (const id of ['gpt-6-astra', 'gpt-6-sol']) {
  assert.equal(c.visible(true, new Set(), {model:id, hidden:true}), true, id);
}
assert.equal(c.visible(true, new Set(), {model:'unrelated', hidden:true}), false);
assert.equal(c.visible(true, new Set(), {model:'gpt-6-astra,gpt-6-sol', hidden:true}), false);
'@, [Text.UTF8Encoding]::new($false))
  $csv = Invoke-NodePatcherFixture -Name 'csv-model-arguments' -Source $positiveFixtures[0].Source -ExpectedExitCode 0 -ModelArguments @(' gpt-6-astra, gpt-6-sol ', 'gpt-6-sol')
  & $node.Source $behaviorPath $csv.AssetPath
  if ($LASTEXITCODE -ne 0) { throw 'CSV model IDs were not admitted independently' }
  $updated = Invoke-NodePatcherFixture -Name 'update-existing-models' -Source ([IO.File]::ReadAllText($csv.AssetPath)) -ExpectedExitCode 0 -ModelArguments $models
  if ($updated.Output -cne 'patched') { throw 'existing forced model list was not updated' }
  & $node.Source $behaviorPath $updated.AssetPath
  if ($LASTEXITCODE -ne 0) { throw 'updated forced model list changed filtering behavior' }
  $brokenCsv = [IO.File]::ReadAllText($csv.AssetPath).Replace('["gpt-6-astra","gpt-6-sol"]', '["gpt-6-astra,gpt-6-sol"]')
  $repaired = Invoke-NodePatcherFixture -Name 'repair-old-csv-list' -Source $brokenCsv -ExpectedExitCode 0 -ModelArguments @('gpt-6-astra,gpt-6-sol')
  & $node.Source $behaviorPath $repaired.AssetPath
  if ($LASTEXITCODE -ne 0) { throw 'old literal CSV model ID was not repaired' }
  foreach ($source in @('/*CODEX_CUSTOM_MODELS_V1*/', ([IO.File]::ReadAllText($csv.AssetPath) + '/*CODEX_CUSTOM_MODELS_V1*/'))) {
    $rejected = Invoke-NodePatcherFixture -Name ('ambiguous-' + [guid]::NewGuid().ToString('N')) -Source $source -ExpectedExitCode 2
    if ([IO.File]::ReadAllText($rejected.AssetPath) -cne $source) { throw 'ambiguous existing model patch was changed' }
  }
  Write-Output 'CUSTOM_MODEL_CSV_UPDATE_AND_BEHAVIOR_PASSED'
} finally {
  if ($hasNativePreference) {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
  }
}

Write-Output "Custom model visibility predicate regression passed: $fixtureRoot"
