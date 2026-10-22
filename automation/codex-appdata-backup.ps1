# Package data is independent of the optional original Store MSIX.
# Keep this snapshot outside build cleanup, including after a successful repair.
function Invoke-CodexStartupRegistry {
  param(
    [ValidateSet('EnumValues','GetDWORDValue','SetDWORDValue','CreateKey')][string]$Method,
    [ValidateSet('State','UserEnabledStartupOnce')][string]$Name,
    [uint32]$Value
  )
  # HKCU may be virtualized inside Desktop. Use the current user's native task.
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $arguments = @{
    hDefKey = [uint32]2147483651
    sSubKeyName = "$sid\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\OpenAI.Codex_2p2nqsd0c76g0\App"
  }
  if ($Method -in @('GetDWORDValue','SetDWORDValue')) { $arguments.sValueName = $Name }
  if ($Method -eq 'SetDWORDValue') { $arguments.uValue = $Value }
  Invoke-CimMethod -Namespace root/default -ClassName StdRegProv -MethodName $Method -Arguments $arguments -ErrorAction Stop
}

function Get-CodexStartupTaskSnapshot {
  $snapshot = [pscustomobject]@{
    sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    state = $null
    user_enabled_once = $null
  }
  $values = Invoke-CodexStartupRegistry -Method EnumValues
  if ($values.ReturnValue -eq 2) { return $snapshot }
  if ($values.ReturnValue -ne 0) { throw "cannot read Codex startup task: $($values.ReturnValue)" }
  foreach ($pair in @(@('State','state'), @('UserEnabledStartupOnce','user_enabled_once'))) {
    $index = [Array]::IndexOf(@($values.sNames), $pair[0])
    if ($index -lt 0) {
      if ($pair[0] -eq 'State') { throw 'Codex startup task exists without State' }
      continue
    }
    if ($values.Types[$index] -ne 4) { throw "Codex startup value is not DWORD: $($pair[0])" }
    $value = Invoke-CodexStartupRegistry -Method GetDWORDValue -Name $pair[0]
    if ($value.ReturnValue -ne 0) { throw "cannot read Codex startup value: $($pair[0]) ($($value.ReturnValue))" }
    $snapshot.($pair[1]) = [long]$value.uValue
  }
  Assert-CodexStartupTaskSnapshot $snapshot
  return $snapshot
}

function Assert-CodexStartupTaskSnapshot {
  param([object]$Snapshot)
  if ($null -eq $Snapshot -or
      @($Snapshot.PSObject.Properties.Name).Count -ne 3 -or
      -not $Snapshot.PSObject.Properties['sid'] -or
      -not $Snapshot.PSObject.Properties['state'] -or
      -not $Snapshot.PSObject.Properties['user_enabled_once']) { throw 'invalid Codex startup snapshot' }
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ($Snapshot.sid -cne $sid) { throw 'Codex startup snapshot belongs to another user' }
  foreach ($name in @('state','user_enabled_once')) {
    $value = $Snapshot.$name
    $maximum = if ($name -eq 'state') { 4 } else { 1 }
    if ($null -ne $value -and
        (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $maximum)) {
      throw "invalid Codex startup snapshot value: $name"
    }
  }
  if ($null -eq $Snapshot.state -and $null -ne $Snapshot.user_enabled_once) { throw 'invalid absent Codex startup snapshot' }
}

function Assert-CodexStartupTaskUnchanged {
  param([object]$Snapshot)
  Assert-CodexStartupTaskSnapshot $Snapshot
  $current = Get-CodexStartupTaskSnapshot
  if ($current.state -cne $Snapshot.state -or $current.user_enabled_once -cne $Snapshot.user_enabled_once) {
    throw 'Codex startup preference changed during backup; refusing package removal'
  }
}

function Restore-CodexStartupTaskSnapshot {
  param([object]$Snapshot)
  Assert-CodexStartupTaskSnapshot $Snapshot
  # No choice existed, or it was policy-controlled: do not invent a preference.
  if ($null -eq $Snapshot.state -or $Snapshot.state -in @(3,4)) { return }
  $current = Get-CodexStartupTaskSnapshot
  if ($null -eq $current.state) {
    # A fresh installation may register the task before creating its user preference key.
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
    if ($packages.Count -ne 1 -or $packages[0].PackageFamilyName -cne 'OpenAI.Codex_2p2nqsd0c76g0') {
      throw 'installed Codex startup task is missing: expected current-user package is not registered'
    }
    $manifest = Get-AppxPackageManifest -Package $packages[0].PackageFullName -ErrorAction Stop
    $tasks = $manifest.SelectNodes('/*[local-name()="Package"]/*[local-name()="Applications"]/*[local-name()="Application" and @Id="App"]/*[local-name()="Extensions"]/*[local-name()="Extension" and @Category="windows.startupTask"]/*[local-name()="StartupTask" and @TaskId="App"]')
    if ($tasks.Count -ne 1) { throw 'installed Codex startup task is missing from the registered manifest' }
    $current = Get-CodexStartupTaskSnapshot
    if ($null -eq $current.state) {
      $result = Invoke-CodexStartupRegistry -Method CreateKey
      if ($result.ReturnValue -ne 0) { throw "cannot restore Codex startup key: $($result.ReturnValue)" }
      $state = Invoke-CodexStartupRegistry -Method GetDWORDValue -Name State
      if ($state.ReturnValue -eq 2) {
        $result = Invoke-CodexStartupRegistry -Method SetDWORDValue -Name State -Value $Snapshot.state
        if ($result.ReturnValue -ne 0) { throw "cannot restore Codex startup value: State ($($result.ReturnValue))" }
      } elseif ($state.ReturnValue -ne 0) {
        throw "cannot read Codex startup value: State ($($state.ReturnValue))"
      }
      $current = Get-CodexStartupTaskSnapshot
    }
  }
  if ($current.state -in @(3,4)) { return }
  foreach ($pair in @(@('UserEnabledStartupOnce','user_enabled_once'), @('State','state'))) {
    $value = $Snapshot.($pair[1])
    if ($null -eq $value -or $current.($pair[1]) -eq $value) { continue }
    # Recheck policy and task existence immediately before each write.
    $current = Get-CodexStartupTaskSnapshot
    if ($null -eq $current.state) { throw 'installed Codex startup task disappeared' }
    if ($current.state -in @(3,4)) { return }
    $result = Invoke-CodexStartupRegistry -Method SetDWORDValue -Name $pair[0] -Value $value
    if ($result.ReturnValue -ne 0) { throw "cannot restore Codex startup value: $($pair[0]) ($($result.ReturnValue))" }
  }
  $restored = Get-CodexStartupTaskSnapshot
  if ($restored.state -in @(3,4)) { return }
  if ($restored.state -ne $Snapshot.state -or
      ($null -ne $Snapshot.user_enabled_once -and $restored.user_enabled_once -ne $Snapshot.user_enabled_once)) {
    throw 'restored Codex startup preference readback mismatch'
  }
}

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
  if ($manifest.PSObject.Properties['startup_task']) { Assert-CodexStartupTaskSnapshot $manifest.startup_task }
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
  param([string]$DataRoot, [string]$BackupRoot, [string]$PackageFullName, [switch]$PreserveStartupTask)
  if (Test-Path -LiteralPath $BackupRoot) { throw 'package data backup already exists; refusing to overwrite recovery evidence' }
  $startupTask = if ($PreserveStartupTask) { Get-CodexStartupTaskSnapshot } else { $null }
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
  if ($PreserveStartupTask) { $manifest.startup_task = $startupTask }
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
  if ($PreserveStartupTask) { Assert-CodexStartupTaskUnchanged $startupTask }
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
  if ($manifest.PSObject.Properties['startup_task']) { Restore-CodexStartupTaskSnapshot $manifest.startup_task }
}
