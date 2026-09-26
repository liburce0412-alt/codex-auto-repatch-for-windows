[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot,
  [string]$OriginalHelperPath
 )

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\windows-cua-runtime.ps1')
$temp = [IO.Path]::GetFullPath($TemporaryRoot)
$root = Join-Path $temp ('windows-cua-runtime-' + [guid]::NewGuid().ToString('N'))
if (-not $root.StartsWith($temp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'fixture root is outside TemporaryRoot'
}
$modules = Join-Path $root 'node_modules'
$doc = Join-Path $modules '@oai\cua-repl\instructions\windows\computer.md'
$otherDoc = Join-Path $modules '@oai\cua-repl\instructions\macos\computer.md'
$backup = Join-Path $root 'backup'
$cases = 0
function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -cne $Expected) { throw "${Message}: expected=$Expected actual=$Actual" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -notlike $Pattern) { throw }
    return
  }
  throw "Expected error: $Pattern"
}
$oldDoc = @'
If the user specifies an app to use, get the app by name, bundle ID, or path:

```javascript
let app = await cua.getApp("Example App");
```
'@
$oldDoc = $oldDoc.Replace("`r`n", "`n").TrimEnd() + "`n"
try {
  Assert-Equal (Repair-WindowsCuaEntryInstructions $modules) 'not-applicable' 'missing docs'
  $cases++
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $doc), (Split-Path -Parent $otherDoc) | Out-Null
  [IO.File]::WriteAllText($doc, $oldDoc)
  [IO.File]::WriteAllText($otherDoc, $oldDoc)
  Assert-Throws { Repair-WindowsCuaEntryInstructions $modules -VerifyOnly } '*unsupported app-name binding*'
  Assert-Equal ([IO.File]::ReadAllText($doc)) $oldDoc 'verify-only must not write'
  $cases++
  Assert-Equal (Repair-WindowsCuaEntryInstructions $modules -BackupRoot $backup) 'patched' 'original docs'
  $patched = [IO.File]::ReadAllText($doc)
  Assert-Equal $patched.Contains('cua.getApp({ windowId: windowIdFromInventory })') $true 'window binding'
  Assert-Equal $patched.Contains('cua.computer.launch_app({ app: appId })') $true 'launch path'
  $saved = Get-ChildItem -LiteralPath $backup -Recurse -File -Filter computer.md.original
  Assert-Equal $saved.Count 1 'backup count'
  Assert-Equal ([IO.File]::ReadAllText($saved.FullName)) $oldDoc 'backup content'
  Assert-Equal ([IO.File]::ReadAllText($otherDoc)) $oldDoc 'macOS instructions preserved'
  $cases++
  Assert-Equal (Repair-WindowsCuaEntryInstructions $modules -BackupRoot $backup) 'already-patched' 'repeat patch'
  Assert-Equal (Repair-WindowsCuaEntryInstructions $modules -VerifyOnly) 'already-patched' 'verify patch'
  Assert-Equal ([IO.File]::ReadAllText($doc)) $patched 'idempotence'
  $cases++
  [IO.File]::WriteAllText($doc, $oldDoc.Replace("`n", "`r`n"))
  Assert-Equal (Repair-WindowsCuaEntryInstructions $modules) 'patched' 'CRLF original'
  $cases++
  $vendorFix = 'Use cua.listWindows() then cua.getApp({ windowId: selectedId }).'
  [IO.File]::WriteAllText($doc, $vendorFix)
  Assert-Equal (Repair-WindowsCuaEntryInstructions $modules) 'already-correct' 'vendor fix'
  Assert-Equal ([IO.File]::ReadAllText($doc)) $vendorFix 'vendor fix preserved'
  $cases++
  [IO.File]::WriteAllText($doc, 'Unknown future instructions')
  Assert-Throws { Repair-WindowsCuaEntryInstructions $modules } '*unrecognized Windows CUA*'
  Assert-Equal ([IO.File]::ReadAllText($doc)) 'Unknown future instructions' 'unknown docs preserved'
  $cases++

  $fixtureHelper = Join-Path $root 'helper.exe'
  $fixturePatcher = Join-Path $root 'patcher.ps1'
  $stub = @'
param($HelperPath, $CodexHome, [switch]$Install)
$state = [IO.File]::ReadAllText($HelperPath)
if ($Install) { [IO.File]::WriteAllText($HelperPath, 'patched'); return }
[pscustomobject]@{ State=$state; WindowsBuild=19045; Sha256='fixture' }
'@
  [IO.File]::WriteAllText($fixturePatcher, $stub)
  Assert-Equal (Repair-StagedWindowsComputerUseHelper $fixtureHelper $fixturePatcher $backup -PatchRequested) 'not-applicable' 'no staged helper'
  $cases++
  [IO.File]::WriteAllText($fixtureHelper, 'original-patchable')
  Assert-Equal (Repair-StagedWindowsComputerUseHelper $fixtureHelper $fixturePatcher $backup) 'skipped-not-requested' 'no implicit helper repair'
  Assert-Equal ([IO.File]::ReadAllText($fixtureHelper)) 'original-patchable' 'default must preserve a supported helper'
  $cases++
  Assert-Equal (Repair-StagedWindowsComputerUseHelper $fixtureHelper $fixturePatcher $backup -PatchRequested) 'patched' 'stage original helper'
  Assert-Equal ([IO.File]::ReadAllText($fixtureHelper)) 'patched' 'stage helper bytes'
  $cases++
  Assert-Equal (Repair-StagedWindowsComputerUseHelper $fixtureHelper $fixturePatcher $backup -PatchRequested) 'already-patched' 'stage repeat helper'
  $cases++
  [IO.File]::WriteAllText($fixtureHelper, 'unsupported')
  Assert-Equal (Repair-StagedWindowsComputerUseHelper $fixtureHelper $fixturePatcher $backup) 'skipped-not-requested' 'unknown helper does not block an unrelated repair'
  Assert-Equal ([IO.File]::ReadAllText($fixtureHelper)) 'unsupported' 'default must preserve an unknown helper'
  $cases++
  Assert-Throws { Repair-StagedWindowsComputerUseHelper $fixtureHelper $fixturePatcher $backup -PatchRequested } '*unsupported staged Windows 10 helper*'
  Assert-Equal ([IO.File]::ReadAllText($fixtureHelper)) 'unsupported' 'unknown helper preserved'
  $cases++
  [IO.File]::WriteAllText($fixturePatcher, $stub.Replace('WindowsBuild=19045', 'WindowsBuild=26100'))
  Assert-Equal (Repair-StagedWindowsComputerUseHelper $fixtureHelper $fixturePatcher $backup -PatchRequested) 'not-applicable' 'Windows 11 bypasses Win10 patch'
  Assert-Equal ([IO.File]::ReadAllText($fixtureHelper)) 'unsupported' 'Win11 helper unchanged'
  $cases++

  if ($OriginalHelperPath) {
    $realHelper = Join-Path $modules '@oai\sky\bin\windows\codex-computer-use.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $realHelper) | Out-Null
    Copy-Item -LiteralPath $OriginalHelperPath -Destination $realHelper
    $metadata = Join-Path $modules '@oai\sky\package.json'
    [IO.File]::WriteAllText($metadata, '{"version":"0.7.1"}')
    $realPatcher = Join-Path $PSScriptRoot 'patch-computer-use-helper-win10.ps1'
    Assert-Equal (Repair-StagedWindowsComputerUseHelper $realHelper $realPatcher $backup -PatchRequested) 'patched' 'real staged helper'
    Assert-Equal (Repair-StagedWindowsComputerUseHelper $realHelper $realPatcher $backup -PatchRequested) 'already-patched' 'real repeat helper'
    Assert-Equal (Get-FileHash -LiteralPath $realHelper -Algorithm SHA256).Hash 'F406A337F4EA6D794DB2E804DFBE880CE06BF8FBAEC565212411474D02E9545D' 'real helper hash'
    $cases++
  }
  Write-Output "ALL_TESTS_PASSED cases=$cases"
} finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
