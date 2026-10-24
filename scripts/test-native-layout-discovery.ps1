[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$TemporaryRoot,
  [string]$CurrentExtractDir
)

$ErrorActionPreference = 'Stop'
$taskTokens = $null
$taskErrors = $null
$taskAst = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'), [ref]$taskTokens, [ref]$taskErrors)
if ($taskErrors.Count) { throw $taskErrors[0].Message }
foreach ($name in @('Find-PatchTargets', 'Find-UltraSliderTarget', 'Invoke-RgList',
    'Test-CustomModelVisibilityExpression', 'Test-FastModeRequestTargetText', 'Test-ServiceTierAccessUiTargetText')) {
  $definition = $taskAst.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
  }, $true)
  if (-not $definition) { throw "Missing function: $name" }
  . ([scriptblock]::Create($definition.Extent.Text))
}
function Fail([string]$Message) { throw $Message }
function Write-Log([string]$Message) { Write-Verbose $Message }
$power = $taskAst.Find({ param($node)
  $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value.Contains("const marker = 'CODEX_POWER_SLIDER_V1';")
}, $true)
if (-not $power) { throw 'Missing Power slider patcher' }
$root = [IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\')
$fixture = Join-Path $root ('native-layout-' + [guid]::NewGuid().ToString('N'))
if (-not $fixture.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid fixture path' }
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
  $patcher = Join-Path $fixture 'power.cjs'
  [IO.File]::WriteAllText($patcher, $power.Value, [Text.UTF8Encoding]::new($false))
  $asset = Join-Path $fixture 'app-primary-fixture.js'
  $source = 'const label="composer.modelPicker.power.ultraUsageWarning";function ModelPickerPowerSliderFastTrackParticles(){}'
  [IO.File]::WriteAllText($asset, $source, [Text.UTF8Encoding]::new($false))
  $output = & node $patcher $asset
  if ($LASTEXITCODE -ne 0 -or $output -cne 'already-patched' -or [IO.File]::ReadAllText($asset) -cne $source) {
    throw 'Native Power slider must be left unchanged'
  }
  if ($CurrentExtractDir) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $targets = Find-PatchTargets (Get-Command rg).Source $CurrentExtractDir
    if ($watch.Elapsed.TotalSeconds -ge 90) { throw 'Target discovery stalled on the current asset set' }
    if ((Split-Path -Leaf $targets.PowerSlider) -notlike 'app-primary-*.js') { throw 'Native Power slider target was not selected' }
    $bytes = [IO.File]::ReadAllBytes($targets.PowerSlider)
    $output = & node $patcher $targets.PowerSlider
    if ($LASTEXITCODE -ne 0 -or $output -cne 'already-patched' -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($targets.PowerSlider)) -cne [Convert]::ToBase64String($bytes)) {
      throw 'Current native Power slider was modified'
    }
    Write-Output "CURRENT_NATIVE_LAYOUT_DISCOVERY_PASSED seconds=$([math]::Round($watch.Elapsed.TotalSeconds, 2))"
  }
  Write-Output 'NATIVE_POWER_SLIDER_NO_WRITE_PASSED'
} finally {
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
