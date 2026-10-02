$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$automation = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $automation 'codex-post-update-repair.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Restore-PackagedCuaRuntime', 'Wait-ForCurrentCuaRuntime')) {
  $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  if (-not $definition) { throw "Missing function: $name" }
  . ([scriptblock]::Create($definition.Extent.Text))
}
$testRoot = Join-Path $PSScriptRoot ('fixture-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot 'package\app\resources\cua_node'
[void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'bin\node_modules\fixture'))
foreach ($name in @('manifest.json','bin\node.exe','bin\node_repl.exe','bin\node_modules\fixture\empty')) {
  [IO.File]::WriteAllText((Join-Path $sourceRoot $name), $(if ($name.EndsWith('empty')) { '' } else { $name }))
}
$package = [pscustomobject]@{ InstallLocation=(Join-Path $testRoot 'package'); PackageFullName='fixture-package' }
$script:observedPackage = $package
function Get-CodexPackage { $script:observedPackage }
function Write-RepairLog { param($Message) }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch { if ($_.Exception.Message -like $Pattern) { return }; throw }
  throw "Expected rejection: $Pattern"
}
$previousLocalAppData = $env:LOCALAPPDATA
try {
  $env:LOCALAPPDATA = Join-Path $testRoot 'local'
  Restore-PackagedCuaRuntime -Package $package
  $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  $published = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter 'recovered-*')
  Assert ($published.Count -eq 1) 'Complete runtime was not published exactly once'
  foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse) {
    $target = Join-Path $published[0].FullName ([IO.Path]::GetRelativePath($sourceRoot, $file.FullName))
    Assert ((Get-FileHash -LiteralPath $file.FullName).Hash -eq (Get-FileHash -LiteralPath $target).Hash) 'Recovered content mismatch'
  }
  $script:observedPackage = [pscustomobject]@{PackageFullName='changed-package'}
  Assert-Throws { Restore-PackagedCuaRuntime -Package $package } '*package changed*'
  Assert (@(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter 'recovered-*').Count -eq 1) 'Version change published an invalid runtime'
  Assert (@(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter '.staging-*').Count -eq 1) 'Failed staging evidence was not preserved'
  $script:observedPackage = $package
  $script:match = $null
  $script:recoveries = 0
  function Get-MatchingCurrentCuaRuntime { $script:match }
  function Restore-PackagedCuaRuntime { $script:recoveries++; $script:match = @{Root='verified-runtime'} }
  Assert ($null -eq (Wait-ForCurrentCuaRuntime -Package $package)) 'Read-only check unexpectedly changed state'
  Assert ($script:recoveries -eq 0) 'Read-only check performed recovery'
  Assert ((Wait-ForCurrentCuaRuntime -Package $package -AllowLaunch).Root -eq 'verified-runtime') 'Missing runtime was not recovered immediately'
  [void](Wait-ForCurrentCuaRuntime -Package $package -AllowLaunch)
  Assert ($script:recoveries -eq 1) 'Existing matching runtime was unnecessarily rebuilt'
} finally { $env:LOCALAPPDATA = $previousLocalAppData }
Write-Output 'RUNTIME_RECOVERY_PASSED: content hashes; empty files; version-change rejection; failed staging retained; read-only check; immediate recovery; matching runtime reuse'
