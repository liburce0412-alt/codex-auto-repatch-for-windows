[CmdletBinding()]
param(
  [string]$NodePath
)

# Fixture-level tests for repair-cua-surface-lock.ps1. Nothing here touches the real Codex home:
# every case builds its own throwaway tree, so an unknown future layout can never be edited by a test.
$ErrorActionPreference = 'Stop'
$LogPrefix = '[test-cua-surface-lock]'
$script:Failures = 0
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')

$RepairScript = Join-Path $PSScriptRoot 'repair-cua-surface-lock.ps1'
if (-not (Test-Path -LiteralPath $RepairScript -PathType Leaf)) {
  throw "$LogPrefix repair script not found: $RepairScript"
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if ($Condition) {
    Write-Host "$LogPrefix PASS $Message"
  } else {
    Write-Host "$LogPrefix FAIL $Message"
    $script:Failures++
  }
}

function New-FixtureHome {
  param([string]$Label)

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("cua-surface-lock-" + $Label + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $plugin = Join-Path $root 'plugins\cache\openai-bundled\unified-computer-use\99.0.0'
  New-Item -ItemType Directory -Force -Path (Join-Path $plugin 'scripts') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $plugin 'resources') | Out-Null
  $script:FixtureRoots.Add($root)
  return $root
}

function Remove-FixtureHome {
  param([string]$Path)
  $resolved = [IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith($temporaryBase + '\cua-surface-lock-', [StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing fixture cleanup outside TEMP: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

function Assert-VerifyFails {
  param([string]$FixtureRoot, [string]$Message)
  $failed = $false
  try { & $RepairScript -CodexHome $FixtureRoot -VerifyOnly -SkipSourceCopies -Json | Out-Null } catch { $failed = $true }
  Assert-True $failed $Message
}

function New-FixtureDescription {
  param([string]$Root)

  $path = Join-Path $Root 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\resources\computer-description.md'
  $body = @"
If the user specifies an app to use, get the app by name, bundle ID, or path:

``````javascript
let app = await cua.getApp("Example App");
``````
"@
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, ($body -replace "`r`n", "`n" -replace "`n", "`r`n"), $encoding)
  return $path
}

function New-FixtureLaunch {
  param([string]$Path, [string]$SurfacesExpression, [string]$SurfacesValue = 'browser')

  # The bundled plugin scripts ship with LF; keep that convention so the newline handling in the
  # patcher is exercised the same way the real launch.mjs exercises it.
  $body = @"
import process from "node:process";
const executable = process.env.CUA_REPL_NODE_REPL_PATH;
$SurfacesExpression
if (!executable) { throw new Error("missing"); }
console.log([...surfaces].join(","));
"@
  $body = $body -replace "`r`n", "`n"

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $body, $encoding)

  if ($SurfacesValue -ne $null) {
    $mcp = Join-Path (Split-Path -Parent $Path) '..\.mcp.json'
    $mcpPath = [System.IO.Path]::GetFullPath($mcp)
    $json = @"
{
  "mcpServers": {
    "cua_repl": {
      "env": {
        "CUA_REPL_ENABLED_SURFACES": "$SurfacesValue"
      }
    }
  }
}
"@
    [System.IO.File]::WriteAllText($mcpPath, ($json -replace "`r`n", "`n"), $encoding)
  }
}

$OriginalExpression = @'
  const surfaces = new Set(
    (process.env.CUA_REPL_ENABLED_SURFACES ?? "browser,computer").split(",").map((surface) => surface.trim()).filter(Boolean)
  );
'@

$UnknownExpression = @'
  const allowed = (process.env.CUA_REPL_ENABLED_SURFACES ?? "browser").split(",");
  const surfaces = new Set(allowed);
'@

# --- 1. verify mode flags an unpatched fixture and leaves it untouched -------------------------

$fixtureHome = New-FixtureHome 'original'
$launch = Join-Path $fixtureHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $launch -SurfacesExpression $OriginalExpression
$description = New-FixtureDescription -Root $fixtureHome
$before = [System.IO.File]::ReadAllText($launch)
$beforeDescription = [System.IO.File]::ReadAllText($description)
$mcpPath = Join-Path $fixtureHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\.mcp.json'
$beforeMcpHash = (Get-FileHash -LiteralPath $mcpPath).Hash

$threw = $false
try { & $RepairScript -CodexHome $fixtureHome -VerifyOnly -SkipSourceCopies | Out-Null } catch { $threw = $true }
Assert-True $threw 'verify-only fails (throws) while the fixture is unpatched'
Assert-True ([System.IO.File]::ReadAllText($launch) -eq $before) 'verify-only does not write the launch script'
Assert-True ([System.IO.File]::ReadAllText($description) -eq $beforeDescription) 'verify-only does not write the description'

# --- 2. install patches both targets without changing the generated MCP config ----------------

& $RepairScript -CodexHome $fixtureHome -Install -SkipSourceCopies | Out-Null
$patchedText = [System.IO.File]::ReadAllText($launch)
$patchedDescription = [System.IO.File]::ReadAllText($description)
$mcpPath = Join-Path $fixtureHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\.mcp.json'

Assert-True ($patchedText -match 'CUA_SURFACE_LOCK_PATCH') 'install writes the surface patch marker'
Assert-True ($patchedText -match '"computer"\s*\]\);') 'install appends the forced computer surface'
Assert-True (-not $patchedText.Contains("`r")) 'install keeps the launch script LF-only, mirroring the shipped file'
Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $launch) -Filter 'launch.mjs.bak-*').Count -ge 1) 'install leaves one adjacent launch backup'
Assert-True ($patchedDescription -match 'CUA_WINDOWS_DESCRIPTION_PATCH') 'install writes the description patch marker'
Assert-True ($patchedDescription -match 'cua\.computer\.list_windows') 'install adds the Windows window-based entry point'
Assert-True ($patchedDescription -match 'Native app bindings are unavailable for windows') 'install warns that the macOS app binding is unavailable on Windows'
Assert-True ($patchedDescription.Contains("`r`n")) 'install keeps the description CRLF, mirroring the shipped resource'
Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $description) -Filter 'computer-description.md.bak-*').Count -ge 1) 'install leaves one adjacent description backup'
Assert-True ((Get-FileHash -LiteralPath $mcpPath).Hash -eq $beforeMcpHash) 'install leaves the generated .mcp.json byte-identical'
$patchedHash = (Get-FileHash -LiteralPath $launch).Hash
$backupCount = @(Get-ChildItem -LiteralPath (Split-Path $launch) -Filter 'launch.mjs.bak-*').Count

# --- 3. the patched file is still valid JavaScript --------------------------------------------

if (-not $NodePath) {
  $resolved = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($resolved) { $NodePath = $resolved.Source }
}
if ($NodePath -and (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
  & $NodePath --check $launch 2>&1 | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) 'node --check accepts the patched module'
  $savedSurfaces = $env:CUA_REPL_ENABLED_SURFACES
  $savedExecutable = $env:CUA_REPL_NODE_REPL_PATH
  try {
    $env:CUA_REPL_ENABLED_SURFACES = 'browser'
    $env:CUA_REPL_NODE_REPL_PATH = 'fixture-only'
    $surfaceOutput = (& $NodePath $launch) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $surfaceOutput -eq 'browser,computer') 'real JavaScript exposes computer while the environment stays browser'
  } finally {
    $env:CUA_REPL_ENABLED_SURFACES = $savedSurfaces
    $env:CUA_REPL_NODE_REPL_PATH = $savedExecutable
  }
} else {
  Write-Host "$LogPrefix SKIP node --check (node not found)"
}

# --- 4. install is idempotent and verify now passes -------------------------------------------

$stable = [System.IO.File]::ReadAllText($launch)
$stableDescription = [System.IO.File]::ReadAllText($description)
& $RepairScript -CodexHome $fixtureHome -Install -SkipSourceCopies | Out-Null
Assert-True ([System.IO.File]::ReadAllText($launch) -eq $stable) 'second install is a no-op for the launch script'
Assert-True ([System.IO.File]::ReadAllText($description) -eq $stableDescription) 'second install is a no-op for the description'
Assert-True ((Get-FileHash -LiteralPath $launch).Hash -eq $patchedHash) 'second install preserves the patched hash'
Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $launch) -Filter 'launch.mjs.bak-*').Count -eq $backupCount) 'second install creates no duplicate backup'

$ok = $true
try { & $RepairScript -CodexHome $fixtureHome -VerifyOnly -SkipSourceCopies | Out-Null } catch { $ok = $false }
Assert-True $ok 'verify-only passes once both targets are patched'

$json = & $RepairScript -CodexHome $fixtureHome -Json -SkipSourceCopies | ConvertFrom-Json
Assert-True ($json.ok -eq $true) 'json report marks ok'
Assert-True (@($json.targets | Where-Object { $_.Patch -eq 'description' }).Count -ge 1) 'json report covers the description target'

# --- 5. rollback restores both original blocks --------------------------------------------------

& $RepairScript -CodexHome $fixtureHome -Rollback -SkipSourceCopies | Out-Null
$restored = [System.IO.File]::ReadAllText($launch)
$restoredDescription = [System.IO.File]::ReadAllText($description)
Assert-True ($restored -notmatch 'CUA_SURFACE_LOCK_PATCH') 'rollback removes the surface marker'
Assert-True ($restored.Contains("const surfaces = new Set(`n    (process.env.CUA_REPL_ENABLED_SURFACES")) 'rollback restores the original expression shape'
Assert-True ($restored -eq $before) 'rollback reproduces the original launch script byte for byte'
Assert-True ($restoredDescription -notmatch 'CUA_WINDOWS_DESCRIPTION_PATCH') 'rollback removes the description marker'
Assert-True ($restoredDescription -eq $beforeDescription) 'rollback reproduces the original description byte for byte'
Assert-True ((Get-FileHash -LiteralPath $mcpPath).Hash -eq $beforeMcpHash) 'the complete install/rollback cycle preserves .mcp.json'

Remove-FixtureHome $fixtureHome

# --- 6. an unrecognized layout is reported, never edited ---------------------------------------

$fixtureHome2 = New-FixtureHome 'unknown'
$launch2 = Join-Path $fixtureHome2 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $launch2 -SurfacesExpression $UnknownExpression
$before2 = [System.IO.File]::ReadAllText($launch2)
$mcp2 = Join-Path (Split-Path (Split-Path $launch2)) '.mcp.json'
$beforeMcp2 = (Get-FileHash -LiteralPath $mcp2).Hash

$threw2 = $false
try { & $RepairScript -CodexHome $fixtureHome2 -VerifyOnly -SkipSourceCopies | Out-Null } catch { $threw2 = $true }
$json2 = & $RepairScript -CodexHome $fixtureHome2 -Json -SkipSourceCopies | ConvertFrom-Json
Assert-True ($threw2) 'an unrecognized layout fails verification'
Assert-True ($json2.targets[0].State -eq 'unsupported') 'an unrecognized layout is classified unsupported'
Assert-True ($json2.ok -eq $false) 'an unrecognized layout reports ok=false'

$installedAnyway = $true
try { & $RepairScript -CodexHome $fixtureHome2 -Install -SkipSourceCopies | Out-Null } catch { $installedAnyway = $false }
Assert-True ($installedAnyway) 'install does not throw on an unrecognized layout'
Assert-True ([System.IO.File]::ReadAllText($launch2) -eq $before2) 'install never edits an unrecognized layout'
Assert-True ((Get-FileHash -LiteralPath $mcp2).Hash -eq $beforeMcp2) 'an unsupported layout never changes .mcp.json'

Remove-FixtureHome $fixtureHome2

# --- 7. markers alone are not a valid patch ----------------------------------------------------

$markerHome = New-FixtureHome 'marker-only'
$markerLaunch = Join-Path $markerHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $markerLaunch -SurfacesExpression ($OriginalExpression + "`n// CUA_SURFACE_LOCK_PATCH")
$markerDescription = New-FixtureDescription -Root $markerHome
[IO.File]::AppendAllText($markerDescription, "`r`nCUA_WINDOWS_DESCRIPTION_PATCH", [Text.UTF8Encoding]::new($false))
$markerHash = (Get-FileHash -LiteralPath $markerLaunch).Hash
Assert-VerifyFails $markerHome 'markers without complete patches fail verification'
$markerJson = & $RepairScript -CodexHome $markerHome -Json -SkipSourceCopies | ConvertFrom-Json
Assert-True (-not $markerJson.ok) 'marker-only JSON report is not ok'
Assert-True (@($markerJson.targets | Where-Object { $_.State -eq 'unsupported' }).Count -eq 2) 'both marker-only targets are unsupported'
& $RepairScript -CodexHome $markerHome -Install -SkipSourceCopies -Json | Out-Null
Assert-True ((Get-FileHash -LiteralPath $markerLaunch).Hash -eq $markerHash) 'install does not overwrite a partial or stale patch'

# --- 8. missing mandatory files and damaged patched blocks fail closed -------------------------

$missingHome = New-FixtureHome 'missing-description'
$missingLaunch = Join-Path $missingHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $missingLaunch -SurfacesExpression $OriginalExpression
$missingDescription = New-FixtureDescription -Root $missingHome
& $RepairScript -CodexHome $missingHome -Install -SkipSourceCopies -Json | Out-Null
Remove-Item -LiteralPath $missingDescription -Force
Assert-VerifyFails $missingHome 'a missing required description fails verification'
$missingJson = & $RepairScript -CodexHome $missingHome -Json -SkipSourceCopies | ConvertFrom-Json
Assert-True (-not $missingJson.ok) 'missing description reports ok=false'
Assert-True (@($missingJson.targets | Where-Object { $_.Patch -eq 'description' -and $_.State -eq 'missing' }).Count -eq 1) 'missing description is explicitly reported'

$damagedHome = New-FixtureHome 'damaged-patch'
$damagedLaunch = Join-Path $damagedHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $damagedLaunch -SurfacesExpression $OriginalExpression
$null = New-FixtureDescription -Root $damagedHome
& $RepairScript -CodexHome $damagedHome -Install -SkipSourceCopies -Json | Out-Null
$damaged = [IO.File]::ReadAllText($damagedLaunch).Replace('    "computer"', '    "browser"')
[IO.File]::WriteAllText($damagedLaunch, $damaged, [Text.UTF8Encoding]::new($false))
Assert-VerifyFails $damagedHome 'a marker-preserving damaged patch fails verification'

# --- 9. duplicate anchors, WhatIf, and incompatible modes never write -------------------------

$duplicateHome = New-FixtureHome 'duplicate-anchor'
$duplicateLaunch = Join-Path $duplicateHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $duplicateLaunch -SurfacesExpression ($OriginalExpression + "`n" + $OriginalExpression)
$null = New-FixtureDescription -Root $duplicateHome
Assert-VerifyFails $duplicateHome 'duplicate original anchors fail verification'
$duplicateJson = & $RepairScript -CodexHome $duplicateHome -Json -SkipSourceCopies | ConvertFrom-Json
Assert-True ($duplicateJson.targets[0].State -eq 'unsupported') 'duplicate anchors are unsupported instead of partially patched'

$whatIfHome = New-FixtureHome 'whatif'
$whatIfLaunch = Join-Path $whatIfHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $whatIfLaunch -SurfacesExpression $OriginalExpression
$whatIfDescription = New-FixtureDescription -Root $whatIfHome
$whatIfHash = (Get-FileHash -LiteralPath $whatIfLaunch).Hash
$whatIfDescriptionHash = (Get-FileHash -LiteralPath $whatIfDescription).Hash
& $RepairScript -CodexHome $whatIfHome -Install -WhatIf -SkipSourceCopies -Json | Out-Null
Assert-True ((Get-FileHash -LiteralPath $whatIfLaunch).Hash -eq $whatIfHash) 'WhatIf leaves launch unchanged'
Assert-True ((Get-FileHash -LiteralPath $whatIfDescription).Hash -eq $whatIfDescriptionHash) 'WhatIf leaves description unchanged'
Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $whatIfLaunch) -Filter 'launch.mjs.bak-*').Count -eq 0) 'WhatIf creates no backup'
foreach ($writeFlags in @(@{ Install = $true; Rollback = $true }, @{ Install = $true; VerifyOnly = $true }, @{ Rollback = $true; VerifyOnly = $true })) {
  $rejected = $false
  try { & $RepairScript -CodexHome $whatIfHome -SkipSourceCopies -Json @writeFlags | Out-Null } catch { $rejected = $true }
  Assert-True $rejected ('incompatible modes rejected: ' + ($writeFlags.Keys -join ','))
}
Assert-True ((Get-FileHash -LiteralPath $whatIfLaunch).Hash -eq $whatIfHash) 'rejected modes leave launch unchanged'

# --- 10. both newline conventions and edits after installation are protected ------------------

$newlineHome = New-FixtureHome 'newline'
$newlineLaunch = Join-Path $newlineHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $newlineLaunch -SurfacesExpression $OriginalExpression
$newlineDescription = New-FixtureDescription -Root $newlineHome
[IO.File]::WriteAllText($newlineLaunch, ([IO.File]::ReadAllText($newlineLaunch) -replace "`n", "`r`n"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($newlineDescription, ([IO.File]::ReadAllText($newlineDescription) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
$newlineHash = (Get-FileHash -LiteralPath $newlineLaunch).Hash
$newlineDescriptionHash = (Get-FileHash -LiteralPath $newlineDescription).Hash
& $RepairScript -CodexHome $newlineHome -Install -SkipSourceCopies -Json | Out-Null
Assert-True (-not ([IO.File]::ReadAllText($newlineLaunch) -match "(?<!`r)`n")) 'a CRLF launch remains CRLF'
Assert-True (-not [IO.File]::ReadAllText($newlineDescription).Contains("`r")) 'an LF description remains LF'
& $RepairScript -CodexHome $newlineHome -VerifyOnly -SkipSourceCopies -Json | Out-Null
& $RepairScript -CodexHome $newlineHome -Rollback -SkipSourceCopies -Json | Out-Null
Assert-True ((Get-FileHash -LiteralPath $newlineLaunch).Hash -eq $newlineHash) 'CRLF launch rollback is byte-exact'
Assert-True ((Get-FileHash -LiteralPath $newlineDescription).Hash -eq $newlineDescriptionHash) 'LF description rollback is byte-exact'
& $RepairScript -CodexHome $newlineHome -Install -SkipSourceCopies -Json | Out-Null
[IO.File]::AppendAllText($newlineLaunch, "`r`n// retained user edit`r`n", [Text.UTF8Encoding]::new($false))
$editedHash = (Get-FileHash -LiteralPath $newlineLaunch).Hash
$rollbackRejected = $false
try { & $RepairScript -CodexHome $newlineHome -Rollback -SkipSourceCopies -Json | Out-Null } catch { $rollbackRejected = $true }
Assert-True $rollbackRejected 'rollback refuses to discard edits made after installation'
Assert-True ((Get-FileHash -LiteralPath $newlineLaunch).Hash -eq $editedHash) 'refused rollback preserves the user edit'

# A descriptor-only or incomplete layout is rejected before even a recognized description changes.
$descriptorHome = New-FixtureHome 'descriptor-only'
$descriptorPath = New-FixtureDescription -Root $descriptorHome
$descriptorHash = (Get-FileHash -LiteralPath $descriptorPath).Hash
$descriptorRejected = $false
try { & $RepairScript -CodexHome $descriptorHome -Install -SkipSourceCopies -Json | Out-Null } catch { $descriptorRejected = $true }
Assert-True $descriptorRejected 'a layout without launch.mjs is rejected before installation'
Assert-True ((Get-FileHash -LiteralPath $descriptorPath).Hash -eq $descriptorHash) 'an unsupported descriptor-only layout is not partially modified'

foreach ($fixtureRoot in $script:FixtureRoots) { Remove-FixtureHome $fixtureRoot }

if ($script:Failures -gt 0) {
  throw "$LogPrefix $($script:Failures) assertion(s) failed"
}
Write-Host "$LogPrefix all assertions passed"
