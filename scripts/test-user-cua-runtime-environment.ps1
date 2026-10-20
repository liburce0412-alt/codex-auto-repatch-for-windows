param()
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'install-computer-use-local.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
foreach ($name in @('Get-FinalFileIdentityPath', 'Test-PathMatchesAnyCurrentFile', 'Test-CuaRuntimeEnvironmentPaths')) {
  $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $fn) { throw "Missing function: $name" }
  . ([scriptblock]::Create($fn.Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('cua-env-test-' + [guid]::NewGuid().ToString('N'))
$checks = 0
function Assert-Rejected {
  param([scriptblock]$Action, [string]$Expected)
  try { & $Action } catch {
    if ($_.Exception.Message -notlike $Expected) { throw }
    return
  }
  throw "Expected rejection: $Expected"
}
try {
  foreach ($name in @('current', 'recovered', 'unverified')) {
    $bin = Join-Path $root "$name\bin"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    foreach ($leaf in @('node.exe','node_repl.exe')) { [IO.File]::WriteAllText((Join-Path $bin $leaf), 'fixture') }
  }
  $current = Join-Path $root 'current\bin'
  $recovered = Join-Path $root 'recovered\bin'
  $unverified = Join-Path $root 'unverified\bin'
  $inventory = [pscustomobject]@{ AllowedCuaBinRoots = @($current, $recovered); NodePath = (Join-Path $current 'node.exe'); NodeReplPath = (Join-Path $current 'node_repl.exe') }
  foreach ($bin in @($current,$recovered)) {
    Test-CuaRuntimeEnvironmentPaths $inventory (Join-Path $bin 'node_repl.exe') (Join-Path $bin 'node.exe')
    $checks++
  }
  Assert-Rejected { Test-CuaRuntimeEnvironmentPaths $inventory (Join-Path $recovered 'node_repl.exe') (Join-Path $current 'node.exe') } '*same verified current-package bin*'
  $checks++
  Assert-Rejected { Test-CuaRuntimeEnvironmentPaths $inventory (Join-Path $unverified 'node_repl.exe') (Join-Path $unverified 'node.exe') } '*same verified current-package bin*'
  $checks++
  Assert-Rejected { Test-CuaRuntimeEnvironmentPaths $inventory '' (Join-Path $current 'node.exe') } '*missing runtime*'
  $checks++
  Assert-Rejected { Test-CuaRuntimeEnvironmentPaths $inventory (Join-Path $current 'missing.exe') (Join-Path $current 'node.exe') } '*missing runtime*'
  $checks++
  Assert-Rejected { Test-CuaRuntimeEnvironmentPaths $inventory (Join-Path $current 'node.exe') (Join-Path $current 'node_repl.exe') } '*same verified current-package bin*'
  $checks++
  $inventory.AllowedCuaBinRoots = @($current)
  Assert-Rejected { Test-CuaRuntimeEnvironmentPaths $inventory (Join-Path $recovered 'node_repl.exe') (Join-Path $recovered 'node.exe') } '*same verified current-package bin*'
  $checks++
} finally {
  if (Test-Path -LiteralPath $root) {
    $resolved = [IO.Path]::GetFullPath($root)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolved) -ine $parent -or (Split-Path -Leaf $resolved) -notmatch '^cua-env-test-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path' }
    if (@(Get-ChildItem -LiteralPath $resolved -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Fixture contains a reparse point' }
    Remove-Item -LiteralPath $resolved -Force -Recurse
    if (Test-Path -LiteralPath $resolved) { throw 'Fixture cleanup failed' }
  }
}
Write-Output "USER_CUA_RUNTIME_ENVIRONMENT_TESTS_PASSED checks=$checks"
