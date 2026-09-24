# Package data is independent of the optional original Store MSIX.
# Keep this snapshot outside build cleanup, including after a successful repair.
function Copy-CodexDataContent {
  param([string]$Source, [string]$Destination, [bool]$Overwrite = $false)
  # File.Copy propagates Store/EFS encryption and can fail across AppX volumes.
  # Copy readable content into the destination's own filesystem policy instead.
  $inputStream = [IO.File]::Open($Source, 'Open', 'Read', 'Read')
  try {
    $mode = if ($Overwrite) { [IO.FileMode]::Create } else { [IO.FileMode]::CreateNew }
    $outputStream = [IO.File]::Open($Destination, $mode, 'Write', 'None')
    try {
      $inputStream.CopyTo($outputStream)
      $outputStream.Flush($true)
    } finally {
      $outputStream.Dispose()
    }
  } finally {
    $inputStream.Dispose()
  }
}

function Get-CodexDataDirectory {
  param([string]$Root, [string]$Name)
  if ((Test-Path -LiteralPath $Root) -and ((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unexpected package data root junction' }
  if ($Name -notin @('AC','AppData','LocalCache','LocalState','RoamingState','Settings','SystemAppData','TempState')) { throw 'unexpected package data directory' }
  $path = Join-Path $Root $Name
  if (Test-Path -LiteralPath $path) {
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      # Windows moves Store data onto an AppX volume with these exact junctions.
      $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      $suffix = "\WpSystem\$sid\AppData\Local\Packages\OpenAI.Codex_2p2nqsd0c76g0\$Name"
      if ($item.LinkType -ne 'Junction' -or [string]$item.Target -notmatch '^[A-Za-z]:\\' -or
          -not ([string]$item.Target).Substring(2).Equals($suffix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "unrecognized package data junction: $path"
      }
      $path = [string]$item.Target
    }
  }
  return $path
}

function Assert-CodexDataPath {
  param([string]$Root, [string]$RelativePath)
  $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $path = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
  if ([IO.Path]::IsPathRooted($RelativePath) -or -not $path.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'package data path escaped its root' }
  for ($cursor = $path; $cursor.Length -ge $base.Length; $cursor = Split-Path -Parent $cursor) {
    if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "unexpected nested data reparse point: $cursor" }
  }
  return $path
}

function Get-CodexDataFiles {
  param([string]$Root)
  if (-not (Test-Path -LiteralPath $Root)) { return }
  foreach ($entry in Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop) {
    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "unexpected nested data reparse point: $($entry.FullName)" }
    if ($entry.PSIsContainer) { Get-CodexDataFiles $entry.FullName } else { $entry }
  }
}

function Assert-CodexAppDataBackup {
  param([string]$BackupRoot)
  $manifest = Get-Content -LiteralPath (Join-Path $BackupRoot 'manifest.json') -Raw | ConvertFrom-Json
  if ($manifest.schema -ne 1 -or $manifest.family -ne 'OpenAI.Codex_2p2nqsd0c76g0') { throw 'invalid package data backup manifest' }
  foreach ($file in $manifest.files) {
    $parts = $file.path -split '[\\/]', 2
    if ($parts.Count -ne 2 -or $parts[0] -notin @('AC','AppData','LocalCache','LocalState','RoamingState','Settings','SystemAppData','TempState')) { throw 'invalid package data relative path' }
    $path = Assert-CodexDataPath $BackupRoot $file.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-Item -LiteralPath $path).Length -ne $file.length -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) { throw "package data backup content changed: $($file.path)" }
  }
  return $manifest
}

function Save-CodexAppDataBackup {
  param([string]$DataRoot, [string]$BackupRoot, [string]$PackageFullName)
  if (Test-Path -LiteralPath $BackupRoot) { throw 'package data backup already exists; refusing to overwrite recovery evidence' }
  New-Item -ItemType Directory -Path $BackupRoot -ErrorAction Stop | Out-Null
  $files = @()
  if (Test-Path -LiteralPath $DataRoot) {
    if ((Get-Item -LiteralPath $DataRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'unexpected package data root junction' }
    foreach ($directory in Get-ChildItem -LiteralPath $DataRoot -Force -ErrorAction Stop) {
      if (-not $directory.PSIsContainer) { throw 'unexpected file at package data root' }
      $sourceRoot = Get-CodexDataDirectory $DataRoot $directory.Name
      foreach ($file in @(Get-CodexDataFiles $sourceRoot)) {
        $relative = Join-Path $directory.Name ([IO.Path]::GetRelativePath($sourceRoot, $file.FullName))
        $destination = Assert-CodexDataPath $BackupRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        Copy-CodexDataContent $file.FullName $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash -or
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $hash) { throw 'package data changed during backup' }
        $files += @{path=$relative;length=$file.Length;sha256=$hash}
      }
    }
  }
  $manifest = @{schema=1;family='OpenAI.Codex_2p2nqsd0c76g0';package=$PackageFullName;files=@($files)}
  [IO.File]::WriteAllText((Join-Path $BackupRoot 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6))
  [void](Assert-CodexAppDataBackup $BackupRoot)
  # Re-enumerate after copying; files created, removed or changed meanwhile
  # must block removal instead of silently dropping the newest state.
  $currentFiles = @{}
  if (Test-Path -LiteralPath $DataRoot) {
    foreach ($directory in Get-ChildItem -LiteralPath $DataRoot -Force -ErrorAction Stop) {
      $sourceRoot = Get-CodexDataDirectory $DataRoot $directory.Name
      foreach ($file in @(Get-CodexDataFiles $sourceRoot)) {
        $relative = Join-Path $directory.Name ([IO.Path]::GetRelativePath($sourceRoot, $file.FullName))
        $currentFiles[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
      }
    }
  }
  if ($currentFiles.Count -ne $files.Count) { throw 'package data inventory changed during backup' }
  foreach ($file in $files) {
    if ($currentFiles[$file.path] -ne $file.sha256) { throw 'package data changed after snapshot' }
  }
}

function Restore-CodexAppDataBackup {
  param([string]$DataRoot, [string]$BackupRoot)
  # Validate the entire snapshot before writing any restored file.
  $manifest = Assert-CodexAppDataBackup $BackupRoot
  foreach ($file in $manifest.files) {
    $parts = $file.path -split '[\\/]', 2
    if ($parts.Count -ne 2) { throw 'invalid package data relative path' }
    # Windows owns these runtime/cache databases; retain their backup only.
    if ($parts[0] -in @('SystemAppData','AC','TempState')) { continue }
    $destinationRoot = Get-CodexDataDirectory $DataRoot $parts[0]
    $destination = Assert-CodexDataPath $destinationRoot $parts[1]
    $source = Assert-CodexDataPath $BackupRoot $file.path
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $file.sha256) { continue }
    Copy-CodexDataContent $source $destination $true
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $file.sha256) { throw 'restored package data hash mismatch' }
  }
}
