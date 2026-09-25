# Functions only. The caller holds the update executor locks.
function Assert-HistoryCleanupPath {
  param([string]$Path, [string]$Parent)
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $boundary = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
  if (-not $full.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'history cleanup escaped its boundary' }
  $attributes = [IO.File]::GetAttributes($full)
  $item = if ($attributes -band [IO.FileAttributes]::Directory) { [IO.DirectoryInfo]::new($full) } else { [IO.FileInfo]::new($full) }
  while ($item) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "history cleanup refuses reparse point: $($item.FullName)" }
    $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
  }
  return $full
}

function Get-HistoryCleanupInventory {
  param([string]$Root, [string]$Parent)
  $rootPath = Assert-HistoryCleanupPath $Root $Parent
  $queue = [Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($rootPath)
  while ($queue.Count) {
    foreach ($item in [IO.DirectoryInfo]::new($queue.Dequeue()).EnumerateFileSystemInfos()) {
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "history cleanup refuses reparse point: $($item.FullName)" }
      if (-not $item.FullName.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'history inventory escaped root' }
      if ($item -is [IO.DirectoryInfo]) { $queue.Enqueue($item.FullName) }
      else {
        $stream = [IO.File]::OpenRead($item.FullName)
        try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
        finally { $stream.Dispose() }
        [pscustomobject]@{ path=$item.FullName; length=$item.Length; sha256=$hash }
      }
    }
  }
}

function Get-HistoryCleanupTargets {
  param([string]$HandoffRoot, [string]$BinRoot, [string]$AuthorizationId, [version]$Version, [string[]]$ProtectedPaths)
  foreach ($parent in @($HandoffRoot, $BinRoot)) {
    if (-not (Test-Path -LiteralPath $parent)) { continue }
    foreach ($dir in Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop) {
      $versions = @()
      if ($parent -eq $HandoffRoot) {
        if ($dir.Name -notmatch '^[a-f0-9]{32}$' -or $dir.Name -eq $AuthorizationId) { continue }
        [void](Assert-HistoryCleanupPath $dir.FullName $parent)
        $names = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop | Select-Object -ExpandProperty Name)
        $build = Join-Path $dir.FullName 'build'
        if (Test-Path -LiteralPath $build) {
          [void](Assert-HistoryCleanupPath $build $dir.FullName)
          $names += @(Get-ChildItem -LiteralPath $build -Force -ErrorAction Stop | Select-Object -ExpandProperty Name)
        }
        foreach ($name in $names) {
          if ($name -match '^OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)(?:_patched\.msix)?$') { $versions += [version]$Matches[1] }
        }
      } elseif ($dir.Name -match '^post-update-(\d+\.\d+\.\d+\.\d+)$') {
        $versions = @([version]$Matches[1])
        if ($versions[0] -ge $Version) { continue }
      } else { continue }
      if (-not $versions.Count -or @($versions | Where-Object { $_ -gt $Version }).Count) { continue }
      $inUse = @($ProtectedPaths | Where-Object {
        $_ -and ([IO.Path]::GetFullPath($_).Equals($dir.FullName, [StringComparison]::OrdinalIgnoreCase) -or
          [IO.Path]::GetFullPath($_).StartsWith($dir.FullName + '\', [StringComparison]::OrdinalIgnoreCase))
      }).Count
      if (-not $inUse) { [pscustomobject]@{ root=$dir.FullName; parent=$parent } }
    }
  }
}

function Remove-HistoryCleanupTarget {
  param($Target, [object[]]$Files)
  # Validate the entire inventory before the first deletion, then each file again.
  $actual = @(Get-HistoryCleanupInventory $Target.root $Target.parent)
  $expected = @{}
  foreach ($file in $Files) {
    $full = [IO.Path]::GetFullPath($file.path)
    if (-not $full.StartsWith($Target.root + '\', [StringComparison]::OrdinalIgnoreCase) -or $expected.ContainsKey($full)) { throw 'invalid history manifest path' }
    $expected[$full] = $file
  }
  if ($actual.Count -ne $expected.Count) { throw 'history inventory changed' }
  foreach ($file in $actual) {
    if (-not $expected.ContainsKey($file.path) -or $expected[$file.path].sha256 -ne $file.sha256 -or $expected[$file.path].length -ne $file.length) { throw 'history file changed' }
  }
  foreach ($file in $actual) {
    [void](Assert-HistoryCleanupPath $file.path $Target.root)
    if ((Get-FileHash -LiteralPath $file.path -ErrorAction Stop).Hash -ne $file.sha256) { throw 'history file changed during cleanup' }
    Remove-Item -LiteralPath $file.path -ErrorAction Stop
  }
  # Re-enumerate without following junctions; only remove empty directories.
  $directories = [Collections.Generic.List[string]]::new()
  $queue = [Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($Target.root)
  while ($queue.Count) {
    $directory = $queue.Dequeue()
    [void](Assert-HistoryCleanupPath $directory $Target.parent)
    $directories.Add($directory)
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
      if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'history tree changed during cleanup' }
      $queue.Enqueue($item.FullName)
    }
  }
  foreach ($directory in $directories | Sort-Object Length -Descending) { [IO.Directory]::Delete($directory, $false) }
}

function Invoke-CodexHistoryCleanup {
  param([Parameter(Mandatory)][string]$AutomationRoot, [Parameter(Mandatory)][string]$AuthorizationId, [switch]$Preview)
  $ErrorActionPreference = 'Stop'
  $state = Get-Content -LiteralPath (Join-Path $AutomationRoot 'update-cycle-active.json') -Raw | ConvertFrom-Json
  if ($state.authorization_id -ne $AuthorizationId -or $state.status -ne 'repair-restart-stable' -or $state.final_signature -ne 'Developer') { throw 'history cleanup requires a stable successful repair' }
  $version = [version]$state.expected_update_version
  $handoffRoot = Join-Path $AutomationRoot 'install-handoffs'
  $currentRoot = Join-Path $handoffRoot $AuthorizationId
  $handoff = Get-Content -LiteralPath (Join-Path $currentRoot 'completed-msix-install.json') -Raw | ConvertFrom-Json
  if ($handoff.status -ne 'completed' -or $handoff.authorization_id -ne $AuthorizationId -or [version]$handoff.expected_version -ne $version) { throw 'latest recovery handoff is not completed' }
  $artifact = Assert-HistoryCleanupPath $handoff.artifact_path $currentRoot
  if ((Get-FileHash -LiteralPath $artifact).Hash -ne $handoff.artifact_sha256 -or
      -not (Test-Path -LiteralPath (Join-Path $currentRoot 'appdata-backup/manifest.json'))) { throw 'latest recovery artifact or backup is missing or changed' }
  $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  $main = @($processes | Where-Object { $_.Name -eq 'ChatGPT.exe' -and $_.ExecutablePath -eq $state.new_main_process_path })
  if (-not $main.Count) { throw 'verified installed Desktop is not running' }
  $protected = @($processes.ExecutablePath | Where-Object { $_ })
  $config = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.codex/config.toml') -Raw
  # Protect paths named by active configuration, not historical host registrations.
  foreach ($match in [regex]::Matches($config, 'CODEX_CLI_PATH\s*=\s*"([^"]+)"')) { $protected += $match.Groups[1].Value.Replace('\\','\') }
  $hostConfig = Join-Path $env:LOCALAPPDATA 'OpenAI/extension/extension-host-config.json'
  if (Test-Path -LiteralPath $hostConfig) { $protected += (Get-Content -LiteralPath $hostConfig -Raw | ConvertFrom-Json).codexCliPath }
  $fallback = Join-Path $AutomationRoot 'post-update-state.json'
  if (Test-Path -LiteralPath $fallback) { $protected += (Get-Content -LiteralPath $fallback -Raw | ConvertFrom-Json).stable_cli_path }
  $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin'
  $targets = @(Get-HistoryCleanupTargets $handoffRoot $binRoot $AuthorizationId $version $protected)
  $records = @()
  foreach ($target in $targets) {
    $records += [pscustomobject]@{ root=$target.root; parent=$target.parent; status='inventoried'; files=@(Get-HistoryCleanupInventory $target.root $target.parent) }
    Write-Host "History inventory complete: $($target.root) files=$($records[-1].files.Count)"
  }
  $reportRoot = Join-Path $AutomationRoot 'cleanup-reports'
  New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
  $reportPath = Join-Path $reportRoot ('history-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
  $report = @{ authorization_id=$AuthorizationId; retained_root=$currentRoot; preview=[bool]$Preview; targets=$records }
  [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8))
  foreach ($record in $records) {
    if ($Preview) { continue }
    try {
      # Recheck running executable paths immediately before each target.
      $live = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($record.root + '\', [StringComparison]::OrdinalIgnoreCase) })
      if ($live.Count) { throw 'history target is now in use' }
      Remove-HistoryCleanupTarget $record $record.files
      $record.status = 'cleaned'
      Write-Host "History cleanup complete: $($record.root)"
    } catch {
      $record.status = 'deferred'
      $record | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8))
  }
  $completed = @($records | Where-Object { $_.status -eq 'cleaned' })
  return [pscustomobject]@{ Targets=$records.Count; Cleaned=$completed.Count; Deferred=@($records | Where-Object status -eq deferred).Count; Bytes=($completed.files | Measure-Object length -Sum).Sum; CandidateBytes=($records.files | Measure-Object length -Sum).Sum; Report=$reportPath }
}
