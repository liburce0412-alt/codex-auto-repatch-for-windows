$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../automation/codex-history-cleanup.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-history-test-' + [guid]::NewGuid().ToString('N'))
$handoffs = Join-Path $fixture 'handoffs'
$bin = Join-Path $fixture 'bin'
$currentId = 'a' * 32
$oldId = 'b' * 32
$unknownId = 'c' * 32
$futureId = 'd' * 32
function Write-Fixture([string]$Relative, [string]$Content='fixture') {
  $path = Join-Path $fixture $Relative
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
  [IO.File]::WriteAllText($path, $Content)
  return $path
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
  $null = Write-Fixture "handoffs/$currentId/OpenAI.Codex_2.0.0.0_patched.msix"
  $oldFile = Write-Fixture "handoffs/$oldId/build/OpenAI.Codex_1.0.0.0/cache.bin"
  $null = Write-Fixture "handoffs/$unknownId/unrecognized.txt"
  $null = Write-Fixture "handoffs/$futureId/OpenAI.Codex_3.0.0.0_patched.msix"
  $protectedCli = Write-Fixture 'bin/post-update-0.5.0.0/codex.exe'
  $null = Write-Fixture 'bin/post-update-1.0.0.0/codex.exe'
  $null = Write-Fixture 'bin/post-update-2.0.0.0/codex.exe'
  $null = Write-Fixture 'bin/unknown-helper/helper.exe'
  $targets = @(Get-HistoryCleanupTargets $handoffs $bin $currentId ([version]'2.0.0.0') @($protectedCli))
  Assert-True ($targets.Count -eq 2) 'must retain current, newer, unknown and active versions'
  $old = $targets | Where-Object root -eq (Join-Path $handoffs $oldId)
  $inventory = @(Get-HistoryCleanupInventory $old.root $old.parent)
  [IO.File]::WriteAllText($oldFile, 'changed')
  $rejected = $false
  try { Remove-HistoryCleanupTarget $old $inventory } catch { $rejected = $_.Exception.Message -eq 'history file changed' }
  Assert-True $rejected 'changed file must defer before deleting'
  Assert-True (Test-Path -LiteralPath $oldFile) 'changed file was removed'
  $locked = [IO.File]::Open($oldFile, 'Open', 'ReadWrite', 'None')
  $rejected = $false
  try {
    try { $null = @(Get-HistoryCleanupInventory $old.root $old.parent) } catch { $rejected = $true }
  } finally { $locked.Dispose() }
  Assert-True $rejected 'hash worker errors must not produce an accepted partial inventory'
  # Long paths used by actual ASAR builds must be inventoried, not silently skipped.
  $relative = "handoffs/$oldId/build/OpenAI.Codex_1.0.0.0/" + (('nested-segment/' * 23)) + 'long.txt'
  $longFile = Write-Fixture $relative
  $inventory = @(Get-HistoryCleanupInventory $old.root $old.parent)
  Assert-True ($inventory.Count -eq 2) 'long file missing from inventory'
  $outside = Join-Path $fixture 'outside'
  [void][IO.Directory]::CreateDirectory($outside)
  $junction = Join-Path $old.root 'linked'
  New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
  $rejected = $false
  try { $null = @(Get-HistoryCleanupInventory $old.root $old.parent) } catch { $rejected = $_.Exception.Message -match 'reparse point' }
  Assert-True $rejected 'junction must be rejected'
  [IO.Directory]::Delete($junction, $false)
  $rejected = $false
  try { $null = Assert-HistoryCleanupPath $outside $handoffs } catch { $rejected = $_.Exception.Message -match 'boundary' }
  Assert-True $rejected 'out-of-bound target accepted'
  Remove-HistoryCleanupTarget $old $inventory
  Assert-True (-not (Test-Path -LiteralPath $old.root)) 'old tree still present'
  Assert-True (Test-Path -LiteralPath $protectedCli) 'active CLI removed'
  $null = Write-Fixture 'update-cycle-active.json' '{"authorization_id":"test","status":"repair-running","final_signature":"Developer"}'
  $rejected = $false
  try { $null = Invoke-CodexHistoryCleanup -AutomationRoot $fixture -AuthorizationId test } catch { $rejected = $_.Exception.Message -match 'stable successful repair' }
  Assert-True $rejected 'cleanup before stable success was accepted'
  Write-Host 'PASS: selection, current/active/newer/unknown preservation, changed-file and hash-error rejection, long paths, junction rejection, boundary rejection, manifest deletion, stable-success gate'
} finally {
  if (Test-Path -LiteralPath $fixture) {
    # Exact disposable fixture, with the same boundary and no-reparse checks.
    $target = [pscustomobject]@{root=$fixture;parent=[IO.Path]::GetTempPath().TrimEnd('\')}
    Remove-HistoryCleanupTarget $target @(Get-HistoryCleanupInventory $target.root $target.parent)
  }
}
