param([Parameter(Mandatory)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$nodeCommand = Get-Command node -ErrorAction Stop
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('asar-cache-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$oldCache = $env:npm_config_cache
$oldLocal = $env:LOCALAPPDATA
$errors = $null; $tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Patcher parse failed' }
$fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-NpxAsar'}, $true)
. ([scriptblock]::Create($fn.Extent.Text))
$script:logs = [Collections.Generic.List[string]]::new()
function Write-Log([string]$Message) { $script:logs.Add($Message) }
function Fail([string]$Message) { throw $Message }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$script:allowNpx = $true
$script:npmSource = $null
$testRecord = @{ Downloads=0; Args=@() }
$npxStub = Join-Path $root 'npx.ps1'
$pnpmStub = Join-Path $root 'pnpm.ps1'
[IO.File]::WriteAllText($npxStub, '$testRecord.Downloads++; $testRecord.Args=@($args); $global:LASTEXITCODE=0')
[IO.File]::WriteAllText($pnpmStub, '$testRecord.Downloads++; $testRecord.Args=@($args); $global:LASTEXITCODE=0')
function Get-Command {
  param([string]$Name, $ErrorAction)
  switch ($Name) {
    'node' { return $nodeCommand }
    'npm' { if ($script:npmSource) { return [pscustomobject]@{Source=$script:npmSource} } }
    'npx' { if ($script:allowNpx) { return [pscustomobject]@{Source=$npxStub} } }
    default { throw "Unexpected command lookup: $Name" }
  }
}
function Get-RequiredCommand([string]$Name) {
  Assert ($Name -eq 'pnpm') 'Unexpected required command'
  [pscustomobject]@{Source=$pnpmStub}
}
try {
  $env:npm_config_cache = Join-Path $root 'cache'
  $env:LOCALAPPDATA = Join-Path $root 'empty-local'
  $asarRoot = Join-Path $env:npm_config_cache '_npx\z-valid\node_modules\asar'
  $null = New-Item -ItemType Directory -Path (Join-Path $asarRoot 'bin')
  $manifest = '{"name":"asar","version":"3.2.0","bin":{"asar":"./bin/asar.js"}}'
  [IO.File]::WriteAllText((Join-Path $asarRoot 'package.json'), $manifest)
  $cli = 'const fs=require("fs");const a=process.argv.slice(2);if(a[0]==="--version"){console.log("v3.2.0");process.exit(0)}if(a[0]==="fail"){process.exit(9)}fs.writeFileSync(a[2],JSON.stringify(a));'
  [IO.File]::WriteAllText((Join-Path $asarRoot 'bin\asar.js'), $cli)
  $out = Join-Path $root 'args.json'
  $unicodeSource = 'source with spaces ' + [char]0x4e2d + [char]0x6587 + '.asar'
  Invoke-NpxAsar extract $unicodeSource $out
  $actual = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($actual[1] -ceq $unicodeSource -and $actual[2] -eq $out -and $testRecord.Downloads -eq 0) 'Cached tool did not preserve arguments or attempted acquisition'

  $script:npmSource = Join-Path $root 'npm-fails.cmd'
  [IO.File]::WriteAllText($script:npmSource, "@echo off`r`necho npm configuration lookup failed 1>&2`r`nexit /b 1`r`n")
  Invoke-NpxAsar extract $unicodeSource $out
  Assert ($testRecord.Downloads -eq 0) 'npm configuration failure blocked a usable cache'
  $validCache = $env:npm_config_cache
  $env:npm_config_cache = Join-Path $root 'missing-during-npm-failure'
  Invoke-NpxAsar extract 'source' $out
  Assert ($testRecord.Downloads -eq 1) 'npm configuration failure blocked acquisition fallback'
  $testRecord.Downloads = 0
  $env:npm_config_cache = $validCache
  $script:npmSource = $null

  $badRoot = Join-Path $env:npm_config_cache '_npx\a-malformed\node_modules\asar'
  $null = New-Item -ItemType Directory -Path (Join-Path $badRoot 'bin')
  [IO.File]::WriteAllText((Join-Path $badRoot 'package.json'), '{broken')
  [IO.File]::WriteAllText((Join-Path $badRoot 'bin\asar.js'), 'process.exit(8)')
  Invoke-NpxAsar pack 'second source' $out
  Assert ($testRecord.Downloads -eq 0) 'Malformed cache prevented usable cache selection'

  $rejected = $false
  try { Invoke-NpxAsar fail 'source' $out } catch { $rejected = $_.Exception.Message -like '*ASAR fail failed with exit code 9*' }
  Assert ($rejected -and $testRecord.Downloads -eq 0) 'Selected tool failure was hidden by download fallback'

  [IO.File]::WriteAllText((Join-Path $asarRoot 'bin\asar.js'), 'process.exit(7)')
  Invoke-NpxAsar extract 'source' $out
  Assert ($testRecord.Downloads -eq 1 -and ($testRecord.Args -join '|') -eq "--yes|asar|extract|source|$out") 'Unusable cache did not use existing npx acquisition'

  $env:npm_config_cache = Join-Path $root 'missing'
  Invoke-NpxAsar pack 'source' $out
  Assert ($testRecord.Downloads -eq 2) 'Missing cache did not fall back'
  $script:allowNpx = $false
  Invoke-NpxAsar extract 'source' $out
  Assert ($testRecord.Downloads -eq 3 -and ($testRecord.Args -join '|') -eq "dlx|asar|extract|source|$out") 'pnpm-only runtime fallback regressed'
  Write-Output 'ASAR_CACHE_TESTS_PASSED cases=8; synthetic cached CLIs and acquisition stubs; no network access'
} finally {
  $env:npm_config_cache = $oldCache
  $env:LOCALAPPDATA = $oldLocal
  $base = [IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\')
  $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
  if (-not $resolved.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase) -or
      ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      @(Get-ChildItem -LiteralPath $resolved -Recurse -Attributes ReparsePoint).Count) { throw 'Test cleanup boundary mismatch' }
  Remove-Item -LiteralPath $resolved -Recurse
  if (Test-Path -LiteralPath $resolved) { throw 'Test cleanup failed' }
}
