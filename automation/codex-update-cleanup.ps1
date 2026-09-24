# Functions only. Dot-source after the authorized watcher has started.
function Get-UpdateBuildInventory {
  param([Parameter(Mandatory)][string]$RequestRoot)
  $root = [IO.Path]::GetFullPath((Join-Path $RequestRoot 'build'))
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
  # Check parents and every child before descending; never follow junctions.
  $parent = Get-Item -LiteralPath $root
  while ($parent) {
    if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "cleanup refuses reparse point: $($parent.FullName)" }
    $parent = $parent.Parent
  }
  $queue = [Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($root)
  while ($queue.Count) {
    $directory = $queue.Dequeue()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "cleanup refuses reparse point: $($item.FullName)" }
      if (-not $item.FullName.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'cleanup target escaped run build root' }
      if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
      else {
        [pscustomobject]@{ path=$item.FullName; length=$item.Length; sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
      }
    }
  }
}

function Save-UpdateCleanupManifest {
  param([Parameter(Mandatory)][string]$RequestRoot, [Parameter(Mandatory)][string]$AuthorizationId)
  $inventory = @(Get-UpdateBuildInventory $RequestRoot)
  $manifest = @{ authorization_id=$AuthorizationId; root=[IO.Path]::GetFullPath((Join-Path $RequestRoot 'build')); files=$inventory; status='awaiting-stable-restart' }
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
  $actual = @(Get-UpdateBuildInventory $RequestRoot)
  $expected = @{}
  foreach ($file in $manifest.files) {
    $full = [IO.Path]::GetFullPath([string]$file.path)
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $expected.ContainsKey($full)) { throw 'invalid cleanup manifest path' }
    $expected[$full] = $file
  }
  if ($actual.Count -ne $expected.Count) { throw 'build inventory changed; cleanup deferred' }
  foreach ($file in $actual) {
    if (-not $expected.ContainsKey($file.path) -or $file.sha256 -ne $expected[$file.path].sha256 -or $file.length -ne $expected[$file.path].length) {
      throw "build file changed; cleanup deferred: $($file.path)"
    }
  }
  $removed = 0
  [long]$bytes = 0
  foreach ($file in $actual) {
    # Check once more immediately before a single-file removal. No recursive
    # shell deletion or removal of the run's signed recovery artifacts.
    if ((Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ne $file.sha256) { throw 'build file changed during cleanup' }
    Remove-Item -LiteralPath $file.path -ErrorAction Stop
    $removed++
    $bytes += $file.length
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
