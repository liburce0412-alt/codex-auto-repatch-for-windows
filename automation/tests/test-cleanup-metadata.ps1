$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../codex-update-cleanup.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-cleanup-metadata-' + [guid]::NewGuid().ToString('N'))
$build = Join-Path $root 'build'
$state = Join-Path $root 'state.json'
$manifestPath = Join-Path $root 'cleanup-manifest.json'
function Assert($Value, $Message) { if (-not $Value) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch { if ($_.Exception.Message -like $Pattern) { return }; throw }
  throw "Expected rejection: $Pattern"
}
try {
  [void][IO.Directory]::CreateDirectory($build)
  $file = Join-Path $build 'generated.txt'
  [IO.File]::WriteAllText($file, 'original')
  [IO.File]::WriteAllText($state, '{"authorization_id":"fixture","status":"repair-restart-stable"}')
  $sentinel = Join-Path $root 'retained.msix'
  [IO.File]::WriteAllText($sentinel, 'recovery')
  & {
    function Get-UpdateCleanupFileHash { throw 'Metadata cleanup must not read file content' }
    [void](Save-UpdateCleanupManifest $root fixture)
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert ($manifest.schema -eq 2 -and -not $manifest.files[0].PSObject.Properties['sha256']) 'metadata manifest contains hashes'
    [IO.File]::SetLastWriteTimeUtc($file, [datetime]::UtcNow.AddDays(-1))
    Reject { Invoke-VerifiedUpdateCleanup $root fixture $state } '*file changed*'
    [void](Save-UpdateCleanupManifest $root fixture)
    $extra = Join-Path $build 'extra.txt'
    [IO.File]::WriteAllText($extra, 'extra')
    Reject { Invoke-VerifiedUpdateCleanup $root fixture $state } '*inventory changed*'
    Remove-Item -LiteralPath $extra
    $link = Join-Path $build 'outside'
    New-Item -ItemType Junction -Path $link -Target $root | Out-Null
    try { Reject { Invoke-VerifiedUpdateCleanup $root fixture $state } '*reparse point*' }
    finally { [IO.Directory]::Delete($link, $false) }
    $result = Invoke-VerifiedUpdateCleanup $root fixture $state
    Assert ($result.Files -eq 1 -and -not (Test-Path -LiteralPath $build)) 'metadata cleanup failed'
    Assert (Test-Path -LiteralPath $sentinel) 'recovery artifact removed'
  }
  [void][IO.Directory]::CreateDirectory($build)
  [IO.File]::WriteAllText($file, 'original')
  $stamp = [IO.File]::GetLastWriteTimeUtc($file)
  $legacy = @{authorization_id='fixture';root=$build;status='awaiting-stable-restart';files=@(Get-UpdateBuildInventory $root -IncludeHashes)}
  [IO.File]::WriteAllText($manifestPath, ($legacy | ConvertTo-Json -Depth 6))
  [IO.File]::WriteAllText($file, 'modified')
  [IO.File]::SetLastWriteTimeUtc($file, $stamp)
  Reject { Invoke-VerifiedUpdateCleanup $root fixture $state } '*file changed*'
  [IO.File]::WriteAllText($file, 'original')
  $result = Invoke-VerifiedUpdateCleanup $root fixture $state
  Assert ($result.Files -eq 1) 'legacy hash cleanup failed'
  Write-Output 'CLEANUP_METADATA_PASSED: zero content reads; changed timestamp; extra file; junction; recovery retention; legacy same-size corruption detection and cleanup'
} finally {
  if (([IO.Path]::GetFullPath($root)).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $root -Recurse -ErrorAction Stop
  }
}
