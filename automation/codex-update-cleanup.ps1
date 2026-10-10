# Functions only. Dot-source after the authorized watcher has started.
function Get-UpdateCleanupFileHash {
  param([Parameter(Mandatory)][string]$Path)
  $stream = [IO.File]::OpenRead($Path)
  try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
  finally { $stream.Dispose() }
}

function Get-UpdateBuildInventory {
  param([Parameter(Mandatory)][string]$RequestRoot, [switch]$IncludeHashes)
  $root = [IO.Path]::GetFullPath((Join-Path $RequestRoot 'build'))
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
  # Check parents and every child before descending; never follow junctions.
  $parent = [IO.DirectoryInfo]::new($root)
  while ($parent) {
    if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "cleanup refuses reparse point: $($parent.FullName)" }
    $parent = $parent.Parent
  }
  $queue = [Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($root)
  while ($queue.Count) {
    $directory = $queue.Dequeue()
    foreach ($item in [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos()) {
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "cleanup refuses reparse point: $($item.FullName)" }
      if (-not $item.FullName.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'cleanup target escaped run build root' }
      if ($item -is [IO.DirectoryInfo]) { $queue.Enqueue($item.FullName) }
      else {
        $record = [ordered]@{ path=$item.FullName; length=$item.Length;
          last_write_ticks=$item.LastWriteTimeUtc.Ticks; creation_ticks=$item.CreationTimeUtc.Ticks }
        if ($IncludeHashes) { $record.sha256 = Get-UpdateCleanupFileHash $item.FullName }
        [pscustomobject]$record
      }
    }
  }
}

function Save-UpdateCleanupManifest {
  param([Parameter(Mandatory)][string]$RequestRoot, [Parameter(Mandatory)][string]$AuthorizationId)
  $inventory = @(Get-UpdateBuildInventory $RequestRoot)
  # Only disposable generated build files use metadata. Signed artifacts and
  # application-data recovery snapshots live outside this root and retain hashes.
  $manifest = @{ schema=2; verification='build-metadata'; authorization_id=$AuthorizationId; root=[IO.Path]::GetFullPath((Join-Path $RequestRoot 'build')); files=$inventory; status='awaiting-stable-restart' }
  $path = Join-Path $RequestRoot 'cleanup-manifest.json'
  [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 6))
  return $inventory.Count
}

function Invoke-VerifiedUpdateCleanup {
  param([Parameter(Mandatory)][string]$RequestRoot, [Parameter(Mandatory)][string]$AuthorizationId,
    [Parameter(Mandatory)][string]$CycleStatePath)
  $state = Get-Content -LiteralPath $CycleStatePath -Raw | ConvertFrom-Json
  if ($state.authorization_id -ne $AuthorizationId -or $state.status -ne 'repair-restart-stable') {
    throw 'cleanup requires this exact authorization and a stable successful restart'
  }
  $manifestPath = Join-Path $RequestRoot 'cleanup-manifest.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $root = [IO.Path]::GetFullPath((Join-Path $RequestRoot 'build'))
  if ($manifest.authorization_id -ne $AuthorizationId -or $manifest.root -ne $root) { throw 'cleanup manifest is outside this run' }
  $metadata = $manifest.PSObject.Properties['schema'] -and $manifest.schema -eq 2
  if ($metadata -and $manifest.verification -ne 'build-metadata') { throw 'unsupported cleanup verification mode' }
  if ($manifest.PSObject.Properties['schema'] -and $manifest.schema -notin @(1,2)) { throw 'unsupported cleanup manifest schema' }
  # Existing manifests keep their original content-hash contract.
  $actual = @(Get-UpdateBuildInventory $RequestRoot -IncludeHashes:(-not $metadata))
  $expected = @{}
  foreach ($file in $manifest.files) {
    $full = [IO.Path]::GetFullPath([string]$file.path)
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $expected.ContainsKey($full)) { throw 'invalid cleanup manifest path' }
    $expected[$full] = $file
  }
  if ($actual.Count -ne $expected.Count) { throw 'build inventory changed; cleanup deferred' }
  foreach ($file in $actual) {
    $matches = $expected.ContainsKey($file.path) -and $file.length -eq $expected[$file.path].length
    if ($matches -and $metadata) {
      $matches = $file.last_write_ticks -eq $expected[$file.path].last_write_ticks -and $file.creation_ticks -eq $expected[$file.path].creation_ticks
    } elseif ($matches) { $matches = $file.sha256 -eq $expected[$file.path].sha256 }
    if (-not $matches) {
      throw "build file changed; cleanup deferred: $($file.path)"
    }
  }
  $removed = 0
  [long]$bytes = 0
  foreach ($file in $actual) {
    # Check once more immediately before a single-file removal. No recursive
    # shell deletion or removal of the run's signed recovery artifacts.
    $current = [IO.FileInfo]::new($file.path)
    if (-not $current.Exists -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'build file changed during cleanup' }
    if ($metadata) {
      if ($current.Length -ne $file.length -or $current.LastWriteTimeUtc.Ticks -ne $file.last_write_ticks -or $current.CreationTimeUtc.Ticks -ne $file.creation_ticks) { throw 'build file changed during cleanup' }
    } elseif ((Get-UpdateCleanupFileHash $file.path) -ne $file.sha256) { throw 'build file changed during cleanup' }
    Remove-Item -LiteralPath $file.path -ErrorAction Stop
    $removed++
    $bytes += $file.length
    if ($removed % 5000 -eq 0) { Write-Host "Build cleanup: $removed/$($actual.Count) files removed" }
  }
  if (Test-Path -LiteralPath $root) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)) {
      # Delete(false) fails if any new file appeared; it never recurses.
      [IO.Directory]::Delete($directory.FullName, $false)
    }
    [IO.Directory]::Delete($root, $false)
  }
  $manifest.status = 'cleaned'
  $manifest | Add-Member -NotePropertyName removed_files -NotePropertyValue $removed -Force
  $manifest | Add-Member -NotePropertyName removed_bytes -NotePropertyValue $bytes -Force
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6))
  return [pscustomobject]@{ Files=$removed; Bytes=$bytes }
}
