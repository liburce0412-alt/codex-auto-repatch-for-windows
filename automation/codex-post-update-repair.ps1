[CmdletBinding()]
param(
  [switch]$CheckOnly,
  [switch]$Force,
  [switch]$Launch,
  [switch]$Background,
  [switch]$AllowVisibleAppRepair,
  [switch]$OneClickAuthorized,
  [switch]$PrepareExternalInstall,
  [switch]$PostInstallOnly,
  [version]$ExpectedVersion,
  [string]$ExpectedPackageFullName,
  [ValidatePattern('^[0-9a-fA-F]{32}$')]
  [string]$AuthorizationId,
  [ValidateRange(1, 168)]
  [int]$RetryHours = 6,
  [string]$OutputRoot = (Join-Path $env:USERPROFILE 'Downloads\codex-msix-repack')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AutomationRoot = Join-Path $env:USERPROFILE '.codex\automation'
$LogRoot = Join-Path $AutomationRoot 'logs'
$StatePath = Join-Path $AutomationRoot 'post-update-state.json'
$LockPath = Join-Path $AutomationRoot 'post-update-repair.lock'
$AuthorizationLastPath = Join-Path $AutomationRoot 'update-cycle-authorization.last.json'
$InstallHandoffRoot = Join-Path $AutomationRoot 'install-handoffs'
$StableIconPath = Join-Path $env:USERPROFILE '.codex\assets\codex-desktop.ico'
$SkillRoot = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch'
$BackupScript = Join-Path $SkillRoot 'scripts\manage-codex-backups.ps1'
$PluginRepairScript = Join-Path $SkillRoot 'scripts\install-computer-use-local.ps1'
$PatchScript = Join-Path $SkillRoot 'scripts\patch_codex_fast_mode_windows_msix.ps1'
$AppUserModelId = 'OpenAI.Codex_2p2nqsd0c76g0!App'
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$script:ResolvedExternalPwsh = $null

New-Item -ItemType Directory -Force -Path $AutomationRoot, $LogRoot, $InstallHandoffRoot, (Split-Path -Parent $StableIconPath) | Out-Null
$RunLog = Join-Path $LogRoot "post-update-$RunStamp.log"

function Write-RepairLog {
  param([string]$Message)

  $line = '{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $Message
  Write-Host $line
  [System.IO.File]::AppendAllText($RunLog, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Read-RepairState {
  $state = [ordered]@{}
  if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    return $state
  }

  try {
    $value = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    foreach ($property in $value.PSObject.Properties) {
      $state[$property.Name] = $property.Value
    }
  } catch {
    Write-RepairLog "warning: ignored unreadable state file: $($_.Exception.Message)"
  }
  return $state
}

function Write-RepairState {
  param([System.Collections.IDictionary]$State)

  $State['schema'] = 1
  $tempPath = "$StatePath.tmp-$PID"
  $json = ($State | ConvertTo-Json -Depth 10) + [Environment]::NewLine
  [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
}

function Get-StateText {
  param(
    [System.Collections.IDictionary]$State,
    [string]$Name
  )

  if ($State.Contains($Name) -and $null -ne $State[$Name]) {
    return [string]$State[$Name]
  }
  return ''
}

function Get-CodexPackage {
  return Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
}

function Get-PackageManifestDesktopExecutablePath {
  param([Parameter(Mandatory)][string]$PackageRoot)

  try {
    $resolvedRoot = [System.IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    $manifestPath = Join-Path $resolvedRoot 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
      return $null
    }
    $manifest = [xml][System.IO.File]::ReadAllText($manifestPath)
    $applications = @($manifest.Package.Applications.Application)
    $matches = @($applications | Where-Object { [string]$_.Id -eq 'App' })
    if ($matches.Count -eq 1) {
      $application = $matches[0]
    } elseif ($matches.Count -eq 0 -and $applications.Count -eq 1) {
      $application = $applications[0]
    } else {
      return $null
    }
    $relativeExecutable = [string]$application.Executable
    if ([string]::IsNullOrWhiteSpace($relativeExecutable) -or [System.IO.Path]::IsPathRooted($relativeExecutable)) {
      return $null
    }
    $executablePath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $relativeExecutable))
    if (-not $executablePath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
      return $null
    }
    return $executablePath
  } catch {
    return $null
  }
}

function Get-CodexSourceCandidate {
  param([object]$InstalledPackage)

  $candidates = [System.Collections.Generic.List[object]]::new()
  $seen = @{}
  $addCandidate = {
    param(
      [string]$AppPath,
      [object]$Version,
      [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($AppPath) -or
        -not (Test-Path -LiteralPath (Join-Path $AppPath 'resources\app.asar') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $AppPath 'resources\rg.exe') -PathType Leaf)) {
      return
    }
    $resolvedAppPath = (Resolve-Path -LiteralPath $AppPath -ErrorAction Stop).ProviderPath
    $key = $resolvedAppPath.TrimEnd('\').ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
      return
    }
    $seen[$key] = $true
    $packageRoot = Split-Path -Parent $resolvedAppPath
    if (-not (Get-PackageManifestDesktopExecutablePath -PackageRoot $packageRoot)) {
      return
    }
    $candidates.Add([pscustomobject]@{
      AppPath = $resolvedAppPath
      PackageRoot = $packageRoot
      PackageFullName = Split-Path -Leaf $packageRoot
      Version = [version]$Version
      Source = $Source
    })
  }

  & $addCandidate (Join-Path $InstalledPackage.InstallLocation 'app') $InstalledPackage.Version 'current-user-package'

  $selected = $candidates | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $selected) {
    throw 'no complete Codex package source was found'
  }
  return $selected
}

function Get-VisibleCodexProcesses {
  $visible = @()
  foreach ($process in (Get-Process -Name 'Codex', 'ChatGPT' -ErrorAction SilentlyContinue)) {
    try {
      if (
        $process.Path -like '*\WindowsApps\OpenAI.Codex_*\app\Codex.exe' -or
        $process.Path -like '*\WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe'
      ) {
        if ($process.MainWindowHandle -ne 0 -and $process.Responding) {
          $visible += $process
        }
      }
    } catch {
      continue
    }
  }
  return $visible
}

function Test-UnsafeCodexPowerShellPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $true
  }
  $normalized = [System.IO.Path]::GetFullPath($Path)
  return (
    $normalized -match '(?i)\\\.cache\\codex-runtimes\\' -or
    $normalized -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\'
  )
}

function Get-ExternalPwshProbe {
  param([Parameter(Mandatory)][string]$Candidate)

  if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    return $null
  }
  try {
    $probeJson = & $Candidate -NoProfile -NonInteractive -Command (
      '[pscustomobject]@{ ProcessPath=[Environment]::ProcessPath; PSHOME=$PSHOME; Version=$PSVersionTable.PSVersion.ToString() } | ConvertTo-Json -Compress'
    ) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $probeJson) {
      return $null
    }
    $probe = ($probeJson | Select-Object -Last 1) | ConvertFrom-Json
    if ([version][string]$probe.Version -lt [version]'7.5' -or
        (Test-UnsafeCodexPowerShellPath -Path ([string]$probe.ProcessPath)) -or
        (Test-UnsafeCodexPowerShellPath -Path (Join-Path ([string]$probe.PSHOME) 'pwsh.exe'))) {
      return $null
    }
    return [pscustomobject]@{
      LaunchPath = [System.IO.Path]::GetFullPath($Candidate)
      ProcessPath = [System.IO.Path]::GetFullPath([string]$probe.ProcessPath)
      PSHOME = [System.IO.Path]::GetFullPath([string]$probe.PSHOME)
      Version = [version][string]$probe.Version
    }
  } catch {
    return $null
  }
}

function Resolve-Pwsh {
  if ($script:ResolvedExternalPwsh) {
    return $script:ResolvedExternalPwsh
  }

  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
    'C:\Program Files\PowerShell\7\pwsh.exe'
  )
  $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) {
    $candidates += $command.Source
  }
  $currentPwsh = Join-Path $PSHOME 'pwsh.exe'
  if (-not (Test-UnsafeCodexPowerShellPath -Path $currentPwsh)) {
    $candidates += $currentPwsh
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    $probe = Get-ExternalPwshProbe -Candidate $candidate
    if ($probe) {
      Write-RepairLog "selected external PowerShell: launch=$($probe.LaunchPath) process=$($probe.ProcessPath) version=$($probe.Version)"
      $script:ResolvedExternalPwsh = $probe.ProcessPath
      return $script:ResolvedExternalPwsh
    }
  }
  throw 'an external PowerShell 7.5 or newer executable is required; Codex-bundled runtimes are refused'
}

function Invoke-LoggedProcess {
  param(
    [string]$Label,
    [string]$FilePath,
    [string[]]$ArgumentList
  )

  $safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
  $stdoutPath = Join-Path $LogRoot "$RunStamp-$safeLabel.stdout.log"
  $stderrPath = Join-Path $LogRoot "$RunStamp-$safeLabel.stderr.log"
  Write-RepairLog "start: $Label"

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $ArgumentList) {
    [void]$startInfo.ArgumentList.Add($argument)
  }

  $stdoutStream = [System.IO.FileStream]::new($stdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 1, [System.IO.FileOptions]::WriteThrough)
  $stderrStream = [System.IO.FileStream]::new($stderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 1, [System.IO.FileOptions]::WriteThrough)
  Write-Host ('[CODEX_PROGRESS_LOG] ' + (@{ paths=@($stdoutPath, $stderrPath) } | ConvertTo-Json -Compress))
  $process = [System.Diagnostics.Process]::new()
  try {
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
      throw "failed to start: $Label"
    }
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
    [void]$process.WaitForExit()
    [void]$stdoutTask.GetAwaiter().GetResult()
    [void]$stderrTask.GetAwaiter().GetResult()
    [void]$stdoutStream.Flush($true)
    [void]$stderrStream.Flush($true)
    $exitCode = $process.ExitCode
  } finally {
    $process.Dispose()
    $stdoutStream.Dispose()
    $stderrStream.Dispose()
  }

  $stdout = [System.IO.File]::ReadAllText($stdoutPath)
  $stderr = [System.IO.File]::ReadAllText($stderrPath)
  Write-RepairLog "finish: $Label exit=$exitCode stdout=$stdoutPath stderr=$stderrPath"

  return [pscustomobject]@{
    ExitCode = $exitCode
    Stdout = $stdout
    Stderr = $stderr
    Combined = $stdout + [Environment]::NewLine + $stderr
    StdoutPath = $stdoutPath
    StderrPath = $stderrPath
  }
}

function Invoke-PwshScript {
  param(
    [string]$Label,
    [string]$ScriptPath,
    [string[]]$Arguments = @()
  )

  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "required script not found: $ScriptPath"
  }
  $pwsh = Resolve-Pwsh
  return Invoke-LoggedProcess -Label $Label -FilePath $pwsh -ArgumentList (@(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', $ScriptPath
    ) + $Arguments)
}

function Write-JsonFileAtomically {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object]$Value
  )

  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temporaryPath = Join-Path $parent ('.{0}.tmp-{1}-{2}' -f (Split-Path -Leaf $Path), $PID, [Guid]::NewGuid().ToString('N'))
  $replacementBackupPath = Join-Path $parent ('.{0}.replace-backup-{1}-{2}' -f (Split-Path -Leaf $Path), $PID, [Guid]::NewGuid().ToString('N'))
  try {
    [System.IO.File]::WriteAllText(
      $temporaryPath,
      (($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
      [System.Text.UTF8Encoding]::new($false)
    )
    if ([System.IO.File]::Exists($Path)) {
      [System.IO.File]::Replace($temporaryPath, $Path, $replacementBackupPath, $true)
    } else {
      [System.IO.File]::Move($temporaryPath, $Path)
    }
  } finally {
    if ([System.IO.File]::Exists($temporaryPath)) {
      [System.IO.File]::Delete($temporaryPath)
    }
    if ([System.IO.File]::Exists($replacementBackupPath)) {
      [System.IO.File]::Delete($replacementBackupPath)
    }
  }
}

function Get-OneClickInstallPaths {
  if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
    throw 'an authorization id is required to derive the install handoff paths'
  }
  $requestRoot = Join-Path $InstallHandoffRoot $AuthorizationId.ToLowerInvariant()
  return [pscustomobject]@{
    RequestRoot = $requestRoot
    HandoffPath = Join-Path $requestRoot 'pending-msix-install.json'
    ArtifactPath = Join-Path $requestRoot ('OpenAI.Codex_{0}_patched.msix' -f [string]$ExpectedVersion)
  }
}

function Assert-OneClickAuthorization {
  if (-not (Test-Path -LiteralPath $AuthorizationLastPath -PathType Leaf)) {
    throw "consumed one-click authorization is missing: $AuthorizationLastPath"
  }
  try {
    $authorization = Get-Content -LiteralPath $AuthorizationLastPath -Raw | ConvertFrom-Json -DateKind String
  } catch {
    throw "consumed one-click authorization is unreadable: $($_.Exception.Message)"
  }
  if ([int]$authorization.schema -ne 1 -or [string]$authorization.status -ne 'consumed') {
    throw 'one-click repair requires a consumed authorization record'
  }
  if (-not [string]::Equals([string]$authorization.authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase) -or
      [version][string]$authorization.expected_update_version -ne $ExpectedVersion -or
      -not [string]::Equals([string]$authorization.expected_package_full_name, $ExpectedPackageFullName, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'consumed one-click authorization does not match the requested package scope'
  }
  $authorizedScriptPath = [System.IO.Path]::GetFullPath([string]$authorization.repair_script_path)
  $currentScriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
  if (-not [string]::Equals($authorizedScriptPath, $currentScriptPath, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals(
        [string]$authorization.repair_script_sha256,
        (Get-FileHash -LiteralPath $currentScriptPath -Algorithm SHA256).Hash,
        [StringComparison]::OrdinalIgnoreCase
      )) {
    throw 'repair script path or hash no longer matches the consumed authorization'
  }
  if ($PrepareExternalInstall -and
      (-not [string]::Equals([System.IO.Path]::GetFullPath([string]$authorization.patch_script_path), [System.IO.Path]::GetFullPath($PatchScript), [StringComparison]::OrdinalIgnoreCase) -or
       -not [string]::Equals([string]$authorization.patch_script_sha256, (Get-FileHash -LiteralPath $PatchScript -Algorithm SHA256).Hash, [StringComparison]::OrdinalIgnoreCase))) {
    throw 'MSIX patcher path or hash no longer matches the consumed authorization'
  }
  $engineProbe = Get-ExternalPwshProbe -Candidate ([string]$authorization.repair_engine_path)
  $unsafeCurrentProcess = Test-UnsafeCodexPowerShellPath -Path ([Environment]::ProcessPath)
  $unsafeCurrentHome = Test-UnsafeCodexPowerShellPath -Path (Join-Path $PSHOME 'pwsh.exe')
  if (-not $engineProbe -or
      -not [string]::Equals($engineProbe.ProcessPath, [Environment]::ProcessPath, [StringComparison]::OrdinalIgnoreCase) -or
      $unsafeCurrentProcess -or $unsafeCurrentHome) {
    throw 'one-click repair is not running in its authorized external PowerShell host'
  }
  if (-not $authorization.monitor_pid -or -not $authorization.monitor_creation_date) {
    throw 'consumed one-click authorization is not bound to a monitor process'
  }
  $currentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
  $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$currentProcess.ParentProcessId)" -ErrorAction Stop
  $parentCreation = [DateTimeOffset]::new([datetime]$parentProcess.CreationDate).ToUniversalTime()
  $authorizedParentCreation = [DateTimeOffset]::Parse([string]$authorization.monitor_creation_date).ToUniversalTime()
  $unsafeParentProcess = Test-UnsafeCodexPowerShellPath -Path ([string]$parentProcess.ExecutablePath)
  if ([int]$parentProcess.ProcessId -ne [int]$authorization.monitor_pid -or
      $parentCreation.UtcDateTime.Ticks -ne $authorizedParentCreation.UtcDateTime.Ticks -or
      $unsafeParentProcess) {
    throw 'one-click repair parent is not the authorized external monitor process'
  }
  return $authorization
}

function Get-MsixManifestIdentity {
  param([Parameter(Mandatory)][string]$Path)

  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.GetEntry('AppxManifest.xml')
    if (-not $entry) {
      throw 'MSIX does not contain AppxManifest.xml'
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $manifest = [xml]$reader.ReadToEnd()
    } finally {
      $reader.Dispose()
    }
  } finally {
    $archive.Dispose()
  }
  return [pscustomobject]@{
    Name = [string]$manifest.Package.Identity.Name
    Publisher = [string]$manifest.Package.Identity.Publisher
    Version = [string]$manifest.Package.Identity.Version
    Architecture = [string]$manifest.Package.Identity.ProcessorArchitecture
  }
}

function Publish-PreparedInstallHandoff {
  param(
    [Parameter(Mandatory)][string]$BuiltArtifactPath,
    [Parameter(Mandatory)][object]$SourceCandidate,
    [Parameter(Mandatory)][object]$Authorization
  )

  if (-not (Test-Path -LiteralPath $BuiltArtifactPath -PathType Leaf)) {
    throw "patched MSIX was not created at the expected path: $BuiltArtifactPath"
  }
  $paths = Get-OneClickInstallPaths
  New-Item -ItemType Directory -Force -Path $paths.RequestRoot | Out-Null
  Copy-Item -LiteralPath $BuiltArtifactPath -Destination $paths.ArtifactPath -Force
  $artifactPath = (Resolve-Path -LiteralPath $paths.ArtifactPath -ErrorAction Stop).ProviderPath
  $signature = Get-AuthenticodeSignature -LiteralPath $artifactPath
  $identity = Get-MsixManifestIdentity -Path $artifactPath
  $sourceManifest = [xml][System.IO.File]::ReadAllText((Join-Path $SourceCandidate.PackageRoot 'AppxManifest.xml'))
  $sourceIdentity = $sourceManifest.Package.Identity
  if ([string]$signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) {
    throw "prepared MSIX signature is not valid: $($signature.Status)"
  }
  if ([string]$identity.Name -ne 'OpenAI.Codex' -or
      [version][string]$identity.Version -ne $ExpectedVersion -or
      [string]$identity.Architecture -ne 'x64' -or
      -not [string]::Equals([string]$identity.Publisher, [string]$sourceIdentity.Publisher, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$signature.SignerCertificate.Subject, [string]$identity.Publisher, [StringComparison]::Ordinal)) {
    throw 'prepared MSIX manifest or signer identity does not match the authorized Codex package'
  }
  $record = [ordered]@{
    schema = 1
    status = 'prepared'
    authorization_id = $AuthorizationId.ToLowerInvariant()
    expected_version = [string]$ExpectedVersion
    expected_package_full_name = $ExpectedPackageFullName
    prepared_at = [DateTimeOffset]::UtcNow.ToString('o')
    monitor_pid = [int]$Authorization.monitor_pid
    monitor_creation_date = [string]$Authorization.monitor_creation_date
    artifact_path = $artifactPath
    artifact_length = [long](Get-Item -LiteralPath $artifactPath).Length
    artifact_sha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
    manifest_name = [string]$identity.Name
    manifest_publisher = [string]$identity.Publisher
    manifest_version = [string]$identity.Version
    manifest_architecture = [string]$identity.Architecture
    signer_subject = [string]$signature.SignerCertificate.Subject
    signer_thumbprint = [string]$signature.SignerCertificate.Thumbprint
    plugin_preflight = 'passed'
    repair_script_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    patch_script_sha256 = (Get-FileHash -LiteralPath $PatchScript -Algorithm SHA256).Hash
  }
  Write-JsonFileAtomically -Path $paths.HandoffPath -Value $record
  Write-RepairLog "prepared exact MSIX handoff: path=$artifactPath sha256=$($record.artifact_sha256) handoff=$($paths.HandoffPath)"
  return [pscustomobject]$record
}

function Sync-StableIcon {
  param([object]$Package)

  $sourceIcon = Join-Path $Package.InstallLocation 'app\resources\icon-chatgpt.ico'
  if (-not (Test-Path -LiteralPath $sourceIcon -PathType Leaf)) {
    Write-RepairLog "warning: package icon not found: $sourceIcon"
    return ''
  }

  $sourceHash = (Get-FileHash -LiteralPath $sourceIcon -Algorithm SHA256).Hash
  $destinationHash = ''
  if (Test-Path -LiteralPath $StableIconPath -PathType Leaf) {
    $destinationHash = (Get-FileHash -LiteralPath $StableIconPath -Algorithm SHA256).Hash
  }
  if ($sourceHash -eq $destinationHash) {
    return $sourceHash
  }

  $tempIcon = "$StableIconPath.tmp-$PID"
  $sourceStream = [System.IO.File]::Open(
    $sourceIcon,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite
  )
  try {
    $destinationStream = [System.IO.File]::Open(
      $tempIcon,
      [System.IO.FileMode]::Create,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
    try {
      $sourceStream.CopyTo($destinationStream)
    } finally {
      $destinationStream.Dispose()
    }
  } finally {
    $sourceStream.Dispose()
  }
  Move-Item -LiteralPath $tempIcon -Destination $StableIconPath -Force

  $finalHash = (Get-FileHash -LiteralPath $StableIconPath -Algorithm SHA256).Hash
  if ($finalHash -ne $sourceHash) {
    throw 'stable Codex icon hash verification failed'
  }
  Write-RepairLog "stable icon refreshed: $StableIconPath sha256=$finalHash"
  return $finalHash
}

function Publish-UserEnvironmentChange {
  $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell is required to publish the user environment change: $windowsPowerShell"
  }

  $broadcastScript = @'
$ErrorActionPreference = 'Stop'
if (-not ('Codex.PostUpdate.NativeMethods' -as [type])) {
  Add-Type -TypeDefinition @"
namespace Codex.PostUpdate {
  using System;
  using System.Runtime.InteropServices;

  public static class NativeMethods {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
      IntPtr hWnd,
      uint Msg,
      UIntPtr wParam,
      string lParam,
      uint fuFlags,
      uint uTimeout,
      out UIntPtr lpdwResult
    );
  }
}
"@
}

$result = [UIntPtr]::Zero
[void][Codex.PostUpdate.NativeMethods]::SendMessageTimeout(
  [IntPtr]0xffff,
  0x001A,
  [UIntPtr]::Zero,
  'Environment',
  0x0002,
  5000,
  [ref]$result
)
'@
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($broadcastScript))
  $publish = Invoke-LoggedProcess -Label 'publish-user-environment' -FilePath $windowsPowerShell -ArgumentList @(
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass',
    '-EncodedCommand', $encodedCommand
  )
  if ($publish.ExitCode -ne 0) {
    throw "failed to publish the user environment change: $($publish.Combined)"
  }
}

function Sync-StableCodexCli {
  param(
    [string]$SourceAppPath,
    [string]$Version
  )

  $destinationRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\post-update-$Version"
  New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null

  $runtimeFileNames = @(
    'codex.exe',
    'codex-code-mode-host.exe',
    'codex-command-runner.exe',
    'codex-windows-sandbox-setup.exe'
  )
  $runtimeHashes = [ordered]@{}
  foreach ($fileName in $runtimeFileNames) {
    $sourcePath = Join-Path $SourceAppPath "resources\$fileName"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
      throw "package Codex CLI runtime file not found: $sourcePath"
    }

    $destinationPath = Join-Path $destinationRoot $fileName
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $destinationHash = ''
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
      $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
    }

    if ($destinationHash -ne $sourceHash) {
      $temporaryPath = "$destinationPath.tmp-$PID"
      $sourceStream = [System.IO.File]::Open(
        $sourcePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
      )
      try {
        $destinationStream = [System.IO.File]::Open(
          $temporaryPath,
          [System.IO.FileMode]::Create,
          [System.IO.FileAccess]::Write,
          [System.IO.FileShare]::None
        )
        try {
          $sourceStream.CopyTo($destinationStream)
        } finally {
          $destinationStream.Dispose()
        }
      } finally {
        $sourceStream.Dispose()
      }
      Move-Item -LiteralPath $temporaryPath -Destination $destinationPath -Force

      $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
      if ($destinationHash -ne $sourceHash) {
        throw "stable Codex CLI runtime hash verification failed: $fileName"
      }
      Write-RepairLog "stable Codex CLI runtime refreshed: $destinationPath sha256=$destinationHash"
    }
    $runtimeHashes[$fileName] = $destinationHash
  }

  $destinationPath = Join-Path $destinationRoot 'codex.exe'
  $currentUserValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
  if ($currentUserValue -ine $destinationPath) {
    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $destinationPath, 'User')
    Publish-UserEnvironmentChange
    Write-RepairLog "user CODEX_CLI_PATH updated: $destinationPath"
  }
  $env:CODEX_CLI_PATH = $destinationPath

  return [pscustomobject]@{
    Path = $destinationPath
    Sha256 = $runtimeHashes['codex.exe']
    RuntimeHashes = $runtimeHashes
  }
}

function Start-CodexDesktop {
  Write-RepairLog "launching Codex Desktop via AppUserModelId: $AppUserModelId"
  Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList "shell:AppsFolder\$AppUserModelId"
}

function Test-FilesMatchByContent {
  param(
    [string]$CandidatePath,
    [string]$ReferencePath
  )

  if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $ReferencePath -PathType Leaf)) {
    return $false
  }
  if ((Get-Item -LiteralPath $CandidatePath).Length -ne (Get-Item -LiteralPath $ReferencePath).Length) {
    return $false
  }
  return (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $ReferencePath -Algorithm SHA256).Hash
}

function Get-MatchingCurrentCuaRuntime {
  param([object]$Package)

  $packageCuaRoot = Join-Path $Package.InstallLocation 'app\resources\cua_node'
  $packageNode = Join-Path $packageCuaRoot 'bin\node.exe'
  $packageNodeRepl = Join-Path $packageCuaRoot 'bin\node_repl.exe'
  foreach ($requiredPath in @($packageNode, $packageNodeRepl)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "current Codex package CUA runtime is incomplete: $requiredPath"
    }
  }

  $localCuaRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  if (-not (Test-Path -LiteralPath $localCuaRoot -PathType Container)) {
    return $null
  }

  $requiredRelativePaths = @(
    'bin\node_modules\@oai\sky\package.json',
    'bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\index.js',
    'bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\sky.js',
    'bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
  )
  foreach ($directory in @(
      Get-ChildItem -LiteralPath $localCuaRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -NotLike '.staging-*' |
        Sort-Object LastWriteTime -Descending
    )) {
    $node = Join-Path $directory.FullName 'bin\node.exe'
    $nodeRepl = Join-Path $directory.FullName 'bin\node_repl.exe'
    if (-not (Test-FilesMatchByContent $node $packageNode) -or
        -not (Test-FilesMatchByContent $nodeRepl $packageNodeRepl)) {
      continue
    }
    $complete = $true
    foreach ($relativePath in $requiredRelativePaths) {
      if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName $relativePath) -PathType Leaf)) {
        $complete = $false
        break
      }
    }
    if ($complete) {
      return [pscustomobject]@{
        Root = $directory.FullName
        NodePath = $node
        NodeReplPath = $nodeRepl
      }
    }
  }
  return $null
}

function Test-CurrentCodexMainProcess {
  param([object]$Package)

  $appRoot = (Join-Path $Package.InstallLocation 'app').TrimEnd('\') + '\'
  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe' OR Name='Codex.exe'" -ErrorAction SilentlyContinue)) {
    if ($process.CommandLine -match '--type=' -or [string]::IsNullOrWhiteSpace($process.ExecutablePath)) {
      continue
    }
    if ($process.ExecutablePath.StartsWith($appRoot, [StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

function Stop-CodexDesktopPackageProcesses {
  param([object]$Package)

  $appRoot = (Join-Path $Package.InstallLocation 'app').TrimEnd('\') + '\'
  $targets = @()
  foreach ($process in @(Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue)) {
    try {
      if ($process.Path.StartsWith($appRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $targets += $process
      }
    } catch {
      continue
    }
  }
  if ($targets.Count -eq 0) {
    return $false
  }

  Write-RepairLog "stopping Codex Desktop before scoped plugin sync: pids=$($targets.Id -join ',')"
  foreach ($process in @($targets | Where-Object MainWindowHandle -ne 0)) {
    try {
      [void]$process.CloseMainWindow()
    } catch {
      continue
    }
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 250
    $remaining = @($targets | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue })
  } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

  foreach ($process in $remaining) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  if ($remaining.Count -gt 0) {
    Wait-Process -Id $remaining.Id -Timeout 20 -ErrorAction SilentlyContinue
  }
  $stillRunning = @($targets | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue })
  if ($stillRunning.Count -gt 0) {
    throw "Codex Desktop package processes did not stop before plugin sync: $($stillRunning.Id -join ',')"
  }
  return $true
}

function Wait-ForCurrentCuaRuntime {
  param(
    [object]$Package,
    [switch]$AllowLaunch,
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 1200
  )

  $runtime = Get-MatchingCurrentCuaRuntime -Package $Package
  if ($runtime) {
    return $runtime
  }
  if (-not $AllowLaunch) {
    return $null
  }

  if (-not (Test-CurrentCodexMainProcess -Package $Package)) {
    Start-CodexDesktop
  } else {
    Write-RepairLog 'Codex Desktop is already extracting the current CUA runtime; preserving its progress'
  }

  $startedAt = [DateTime]::UtcNow
  $deadline = $startedAt.AddSeconds($TimeoutSeconds)
  $nextProgressLog = $startedAt
  while ([DateTime]::UtcNow -lt $deadline) {
    $runtime = Get-MatchingCurrentCuaRuntime -Package $Package
    if ($runtime) {
      $elapsed = [Math]::Round(([DateTime]::UtcNow - $startedAt).TotalSeconds)
      Write-RepairLog "current CUA runtime is ready after ${elapsed}s: $($runtime.Root)"
      return $runtime
    }

    if ([DateTime]::UtcNow -ge $nextProgressLog) {
      $localCuaRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
      $stagingNames = @(
        Get-ChildItem -LiteralPath $localCuaRoot -Directory -Filter '.staging-*' -ErrorAction SilentlyContinue |
          Select-Object -ExpandProperty Name
      )
      $stagingText = if ($stagingNames.Count -gt 0) { $stagingNames -join ',' } else { '<not-started>' }
      Write-RepairLog "waiting for Codex Desktop CUA runtime extraction: staging=$stagingText"
      $nextProgressLog = [DateTime]::UtcNow.AddSeconds(30)
    }
    Start-Sleep -Seconds 5
  }

  throw "timed out after $TimeoutSeconds seconds waiting for Codex Desktop to extract the current CUA runtime"
}

function Save-PendingCuaRuntimeState {
  param(
    [System.Collections.IDictionary]$State,
    [object]$Package,
    [string]$Version,
    [string]$PackageFullName
  )

  $State['last_status'] = 'pending-runtime'
  $State['pending_runtime_since'] = [DateTime]::UtcNow.ToString('o')
  $State['last_seen_version'] = $Version
  $State['last_seen_signature'] = [string]$Package.SignatureKind
  $State['last_seen_package_full_name'] = $PackageFullName
  $State['last_log'] = $RunLog
  Write-RepairState $State
  Write-RepairLog 'repair is waiting for the first Codex Desktop launch to extract the current CUA runtime'
}

function Wait-ForRepairAndLaunch {
  param([int]$TimeoutSeconds = 900)

  Write-RepairLog "another repair is running; waiting up to $TimeoutSeconds seconds before launch"
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $probe = $null
    try {
      $probe = [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
      )
      Write-RepairLog 'background repair lock released; launching Codex Desktop'
      Start-CodexDesktop
      return
    } catch [System.IO.IOException] {
      Start-Sleep -Seconds 2
    } finally {
      if ($probe) {
        $probe.Dispose()
      }
    }
  }

  Write-RepairLog 'warning: timed out waiting for background repair; attempting normal Codex launch'
  Start-CodexDesktop
}

function Invoke-Main {
  if (($PrepareExternalInstall -or $PostInstallOnly) -and -not $OneClickAuthorized) {
    throw 'two-stage install modes require an explicitly consumed one-click authorization'
  }
  if ($PrepareExternalInstall -and $PostInstallOnly) {
    throw 'PrepareExternalInstall and PostInstallOnly are mutually exclusive'
  }

  foreach ($scope in @('User', 'Machine')) {
    $configuredCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', $scope)
    if (-not [string]::IsNullOrWhiteSpace($configuredCodexHome)) {
      throw "global CODEX_HOME is set at $scope scope; refusing to split Codex Desktop state: $configuredCodexHome"
    }
  }

  $package = Get-CodexPackage
  if (-not $package) {
    throw 'OpenAI.Codex is not installed'
  }

  $sourceCandidate = Get-CodexSourceCandidate -InstalledPackage $package
  $installedVersion = [string]$package.Version
  $version = [string]$sourceCandidate.Version
  $signature = [string]$package.SignatureKind
  $installedPackageFullName = [string]$package.PackageFullName
  $packageFullName = [string]$sourceCandidate.PackageFullName

  $oneClickAuthorization = $null
  if ($OneClickAuthorized) {
    if (-not $Force -or -not $Launch -or -not $AllowVisibleAppRepair) {
      throw 'one-click repair requires Force, Launch, and AllowVisibleAppRepair from an explicitly authorized one-time watcher'
    }
    if (-not $ExpectedVersion -or [string]::IsNullOrWhiteSpace($ExpectedPackageFullName) -or
        [string]::IsNullOrWhiteSpace($AuthorizationId)) {
      throw 'one-click repair requires an authorization id plus exact expected version and package full name'
    }
    if (-not $PrepareExternalInstall -and -not $PostInstallOnly) {
      throw 'one-click repair must select exactly one two-stage install phase'
    }
    $oneClickAuthorization = Assert-OneClickAuthorization
  }
  if ($ExpectedVersion -and [version]$sourceCandidate.Version -ne $ExpectedVersion) {
    throw "repair source version does not match the authorized version: expected=$ExpectedVersion actual=$($sourceCandidate.Version)"
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageFullName) -and
      -not [string]::Equals(
        [string]$sourceCandidate.PackageFullName,
        $ExpectedPackageFullName,
        [StringComparison]::OrdinalIgnoreCase
      )) {
    throw "repair source package does not match the authorized package: expected=$ExpectedPackageFullName actual=$($sourceCandidate.PackageFullName)"
  }
  $state = Read-RepairState
  $previousVersion = Get-StateText $state 'last_seen_version'
  $previousPackage = Get-StateText $state 'last_seen_package_full_name'
  $lastStatus = Get-StateText $state 'last_status'
  $versionChanged = (-not [string]::IsNullOrWhiteSpace($previousVersion)) -and $previousVersion -ne $version
  $packageChanged = (-not [string]::IsNullOrWhiteSpace($previousPackage)) -and $previousPackage -ne $packageFullName
  $stagedUpdateAvailable = [version]$sourceCandidate.Version -gt [version]$package.Version
  $needsFullRepatch = $Force -or $signature -ne 'Developer' -or $stagedUpdateAvailable
  $needsPluginRetry = $lastStatus -in @('pending-runtime', 'success-with-plugin-warning')
  $needsMaintenance = $needsFullRepatch -or $versionChanged -or $packageChanged -or $needsPluginRetry
  if ($PostInstallOnly) {
    if ([version][string]$package.Version -ne $ExpectedVersion -or
        -not [string]::Equals([string]$package.PackageFullName, $ExpectedPackageFullName, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$package.SignatureKind -ne 'Developer') {
      throw "post-install finalization requires the exact authorized Developer package: version=$($package.Version) signature=$($package.SignatureKind) package=$($package.PackageFullName)"
    }
    $stagedUpdateAvailable = $false
    $needsFullRepatch = $false
    $needsPluginRetry = $true
    $needsMaintenance = $true
    $versionChanged = $false
    $packageChanged = $false
  }

  Write-RepairLog "detected installed package: version=$installedVersion signature=$signature package=$installedPackageFullName"
  Write-RepairLog "selected repair source: version=$version package=$packageFullName source=$($sourceCandidate.Source) app=$($sourceCandidate.AppPath)"
  Write-RepairLog "decision: maintenance=$needsMaintenance fullRepatch=$needsFullRepatch stagedUpdate=$stagedUpdateAvailable versionChanged=$versionChanged packageChanged=$packageChanged force=$Force"

  if ($CheckOnly) {
    $summary = [pscustomobject]@{
      Version = $version
      InstalledVersion = $installedVersion
      SignatureKind = $signature
      PackageFullName = $packageFullName
      InstalledPackageFullName = $installedPackageFullName
      Source = $sourceCandidate.Source
      CodexCliPath = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
      PreviousVersion = $previousVersion
      PreviousStatus = $lastStatus
      NeedsMaintenance = $needsMaintenance
      NeedsFullRepatch = $needsFullRepatch
      NeedsPluginRetry = $needsPluginRetry
      StagedUpdateAvailable = $stagedUpdateAvailable
      VisibleWindowCount = @(Get-VisibleCodexProcesses).Count
      StatePath = $StatePath
      LogPath = $RunLog
    }
    Write-Host (($summary | Format-List | Out-String).TrimEnd())
    return 0
  }

  $stableCli = Sync-StableCodexCli -SourceAppPath $sourceCandidate.AppPath -Version $version
  $iconHash = Sync-StableIcon -Package $package
  $state['last_seen_at'] = [DateTime]::UtcNow.ToString('o')
  $state['last_seen_version'] = $version
  $state['last_seen_signature'] = $signature
  $state['last_seen_package_full_name'] = $packageFullName
  $state['stable_icon_sha256'] = $iconHash
  $state['stable_cli_path'] = $stableCli.Path
  $state['stable_cli_sha256'] = $stableCli.Sha256
  $state['stable_cli_runtime_hashes'] = $stableCli.RuntimeHashes
  if ($OneClickAuthorized) {
    $state['one_click_authorization_id'] = $AuthorizationId.ToLowerInvariant()
    $state['one_click_expected_version'] = [string]$ExpectedVersion
    $state['one_click_expected_package_full_name'] = $ExpectedPackageFullName
  }

  if (-not $needsMaintenance) {
    $state['last_status'] = 'healthy-no-change'
    $state.Remove('last_error')
    $state['last_log'] = $RunLog
    Write-RepairState $state
    Write-RepairLog 'no package update or repair drift detected'
    if ($Launch) {
      Start-CodexDesktop
    }
    return 0
  }

  $visibleProcesses = @(Get-VisibleCodexProcesses)
  if ($visibleProcesses.Count -gt 0 -and -not $AllowVisibleAppRepair) {
    $state['last_status'] = if ($needsPluginRetry) { 'pending-runtime' } else { 'deferred-visible-app' }
    $state['last_deferred_at'] = [DateTime]::UtcNow.ToString('o')
    $state['last_deferred_pids'] = @($visibleProcesses.Id)
    Write-RepairState $state
    Write-RepairLog "repair deferred because a responsive Codex window is open: pids=$($visibleProcesses.Id -join ',')"
    if ($Launch) {
      Start-CodexDesktop
    }
    return 0
  }

  if ($needsFullRepatch -and -not $OneClickAuthorized) {
    $state['last_status'] = 'requires-one-click-authorization'
    $state['authorization_required_at'] = [DateTimeOffset]::UtcNow.ToString('o')
    $state['authorization_required_version'] = $version
    $state['authorization_required_package_full_name'] = $packageFullName
    $state['last_log'] = $RunLog
    Write-RepairState $state
    Write-RepairLog 'full MSIX replacement was not started: use the exact-version one-click watcher so package removal has an independent recovery owner'
    if ($Launch) {
      Start-CodexDesktop
    }
    return 0
  }

  if ($needsPluginRetry -and -not $needsFullRepatch -and -not $Launch) {
    $runtime = Wait-ForCurrentCuaRuntime -Package $package -AllowLaunch:$OneClickAuthorized
    if (-not $runtime) {
      Save-PendingCuaRuntimeState -State $state -Package $package -Version $version -PackageFullName $packageFullName
      return 0
    }
  }

  $lastAttemptPackage = Get-StateText $state 'last_attempt_package_full_name'
  $lastAttemptAt = Get-StateText $state 'last_attempt_at'
  if (
    -not $Force -and
    $lastStatus -like 'failed*' -and
    $lastAttemptPackage -eq $packageFullName -and
    -not [string]::IsNullOrWhiteSpace($lastAttemptAt)
  ) {
    try {
      $nextRetryAt = [DateTimeOffset]::Parse($lastAttemptAt).AddHours($RetryHours)
      if ([DateTimeOffset]::UtcNow -lt $nextRetryAt) {
        $state['last_status'] = 'failed-backoff'
        Write-RepairState $state
        Write-RepairLog "repair retry deferred until $($nextRetryAt.ToString('o'))"
        if ($Launch) {
          Start-CodexDesktop
        }
        return 0
      }
    } catch {
      Write-RepairLog "warning: ignored invalid last_attempt_at value: $lastAttemptAt"
    }
  }

  $state['last_attempt_at'] = [DateTime]::UtcNow.ToString('o')
  $state['last_attempt_version'] = $version
  $state['last_attempt_package_full_name'] = $packageFullName
  $state['last_status'] = 'running'
  $state.Remove('last_error')
  Write-RepairState $state

  $pluginCommand = Get-Command -Name $PluginRepairScript -ErrorAction Stop
  if (-not $pluginCommand.Parameters.ContainsKey('BrowserComputerUseOnly')) {
    throw 'Computer Use repair script does not expose the required BrowserComputerUseOnly scope; refusing a broader repair'
  }
  $pluginRepairArguments = @('-VerifyOnly', '-BrowserComputerUseOnly')
  $restartDesktopAfterRepair = $false

  if (-not $needsPluginRetry -or $needsFullRepatch -or $versionChanged -or $packageChanged) {
    $backupResult = Invoke-PwshScript -Label 'backup' -ScriptPath $BackupScript -Arguments @('-Action', 'Backup')
    if ($backupResult.ExitCode -ne 0) {
      throw "Codex state backup failed; see $($backupResult.StderrPath)"
    }
  } else {
    Write-RepairLog 'reusing the update backup for the pending scoped plugin retry'
  }

  if (-not $needsFullRepatch) {
    $runtime = Wait-ForCurrentCuaRuntime -Package $package -AllowLaunch:$PostInstallOnly
    if (-not $runtime) {
      Save-PendingCuaRuntimeState -State $state -Package $package -Version $version -PackageFullName $packageFullName
      if ($Launch) {
        Write-RepairLog 'launching Codex Desktop once so the package can extract its CUA runtime; scoped repair remains pending'
        Start-CodexDesktop
      }
      return 0
    }
    if (Test-CurrentCodexMainProcess -Package $package) {
      $restartDesktopAfterRepair = Stop-CodexDesktopPackageProcesses -Package $package
    }
  }

  if ($needsFullRepatch -and $PrepareExternalInstall) {
    Write-RepairLog 'bootstrapping the updated Store package CUA runtime before the fail-closed plugin pre-sync'
    $runtime = Wait-ForCurrentCuaRuntime -Package $package -AllowLaunch
    if (-not $runtime) {
      throw 'updated Store package CUA runtime bootstrap returned without a matching runtime'
    }
    if (Test-CurrentCodexMainProcess -Package $package) {
      $restartDesktopAfterRepair = Stop-CodexDesktopPackageProcesses -Package $package
    }
  }

  $pluginResult = Invoke-PwshScript -Label 'plugin-sync-pre' -ScriptPath $PluginRepairScript -Arguments $pluginRepairArguments
  $pluginWarning = ''
  if ($pluginResult.ExitCode -ne 0) {
    if ($PrepareExternalInstall) {
      throw "scoped Browser/Chrome/Computer Use pre-sync failed before package handoff; the installed package was not removed. See $($pluginResult.StderrPath)"
    }
    if ($pluginResult.Combined -match 'sky requires node_repl; configure NODE_REPL_TRUSTED_SERVICES') {
      $pluginWarning = 'independent runtime verification requires trusted node_repl; files were synchronized'
      Write-RepairLog "warning: $pluginWarning"
    } else {
      $pluginWarning = "plugin pre-sync returned exit $($pluginResult.ExitCode)"
      Write-RepairLog "warning: $pluginWarning; continuing to guarded MSIX DryRun"
    }
  }

  if ($needsFullRepatch) {
    # This workflow validates the source version and identity throughout the
    # handoff. Revisioned direct installers use a different deployment contract.
    if (-not $PrepareExternalInstall) {
      throw 'Full automatic repatch requires the exact-artifact external watcher; direct installation is not supported here'
    }
    $patchCommand = Get-Command -Name $PatchScript -ErrorAction Stop
    if (-not $patchCommand.Parameters.ContainsKey('OnlyBrowserComputerUse')) {
      throw 'MSIX patch script does not expose the required OnlyBrowserComputerUse scope; refusing a broader repatch'
    }
    if (-not $patchCommand.Parameters.ContainsKey('IncludeCustomModelVisibility')) {
      throw 'MSIX patch script does not expose the required IncludeCustomModelVisibility scope; refusing a broader Model Experience repatch'
    }
    if ($PrepareExternalInstall -and -not $patchCommand.Parameters.ContainsKey('PreserveSourceVersion')) {
      throw 'MSIX patch script cannot preserve the authorized exact-artifact version'
    }
    $dryRunArguments = @(
      '-OnlyBrowserComputerUse',
      '-IncludeCustomModelVisibility',
      '-DryRun',
      '-ForceRebuild',
      '-AppPath', $sourceCandidate.AppPath,
      '-OutputRoot', $OutputRoot
    )
    if ($PrepareExternalInstall) { $dryRunArguments += @('-KeepWorkDir', '-PreserveSourceVersion') }
    else { $dryRunArguments += '-CleanupAfter' }
    $dryRunResult = Invoke-PwshScript -Label 'msix-dry-run' -ScriptPath $PatchScript -Arguments $dryRunArguments
    if ($dryRunResult.ExitCode -ne 0) {
      throw "Codex MSIX DryRun failed; no patched package was installed. See $($dryRunResult.StderrPath)"
    }

    $visibleProcessesBeforeInstall = @(Get-VisibleCodexProcesses)
    if ($visibleProcessesBeforeInstall.Count -gt 0 -and -not $AllowVisibleAppRepair) {
      $state['last_status'] = 'deferred-visible-app'
      $state['last_deferred_at'] = [DateTime]::UtcNow.ToString('o')
      $state['last_deferred_stage'] = 'after-msix-dry-run'
      $state['last_deferred_pids'] = @($visibleProcessesBeforeInstall.Id)
      $state['last_log'] = $RunLog
      Write-RepairState $state
      Write-RepairLog "MSIX install deferred because a responsive Codex window appeared during DryRun: pids=$($visibleProcessesBeforeInstall.Id -join ',')"
      if ($Launch) {
        Start-CodexDesktop
      }
      return 0
    }

    $packageArguments = @(
      '-OnlyBrowserComputerUse',
      '-IncludeCustomModelVisibility',
      '-InstallPrerequisites',
      '-ForceRebuild',
      '-AppPath', $sourceCandidate.AppPath,
      '-NoLaunch'
    )
    if (-not $PrepareExternalInstall) {
      $packageArguments += @('-Install', '-CleanupAfter', '-CleanupWindowsSdkAfterInstall')
    } else {
      # The external watcher cleans the manifest-verified run only after a
      # successful stable restart. Shared SDK caches are outside that scope.
      $packageArguments += @('-KeepWorkDir', '-PreserveSourceVersion')
    }
    $packageArguments += @('-OutputRoot', $OutputRoot)
    $packageResult = Invoke-PwshScript -Label $(if ($PrepareExternalInstall) { 'msix-package' } else { 'msix-install' }) -ScriptPath $PatchScript -Arguments $packageArguments
    if ($packageResult.ExitCode -ne 0) {
      throw "Codex MSIX repatch failed. See $($packageResult.StderrPath)"
    }

    if ($PrepareExternalInstall) {
      $artifactMatch = [regex]::Matches($packageResult.Combined, '(?im)^.*patched MSIX:\s*(?<path>[^\r\n]+?)\s*$') | Select-Object -Last 1
      if (-not $artifactMatch) {
        throw 'MSIX packager succeeded without reporting its patched artifact path'
      }
      $prepared = Publish-PreparedInstallHandoff `
        -BuiltArtifactPath $artifactMatch.Groups['path'].Value.Trim() `
        -SourceCandidate $sourceCandidate `
        -Authorization $oneClickAuthorization
      $state['last_status'] = 'install-prepared'
      $state['prepared_install_at'] = [DateTimeOffset]::UtcNow.ToString('o')
      $state['prepared_install_artifact'] = [string]$prepared.artifact_path
      $state['prepared_install_sha256'] = [string]$prepared.artifact_sha256
      $state['last_log'] = $RunLog
      Write-RepairState $state
      Write-RepairLog 'two-stage repair preparation completed without removing the installed package'
      return 0
    }

    $packageAfter = Get-CodexPackage
    if (-not $packageAfter) {
      throw 'OpenAI.Codex package is missing after repatch'
    }
    if ([string]$packageAfter.Version -ne $version -or [string]$packageAfter.SignatureKind -ne 'Developer') {
      throw "unexpected package after repatch: version=$($packageAfter.Version) signature=$($packageAfter.SignatureKind)"
    }
    if ($ExpectedVersion -and [version]$packageAfter.Version -ne $ExpectedVersion) {
      throw "installed package version does not match the authorization: expected=$ExpectedVersion actual=$($packageAfter.Version)"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageFullName) -and
        -not [string]::Equals(
          [string]$packageAfter.PackageFullName,
          $ExpectedPackageFullName,
          [StringComparison]::OrdinalIgnoreCase
        )) {
      throw "installed package identity does not match the authorization: expected=$ExpectedPackageFullName actual=$($packageAfter.PackageFullName)"
    }
    $package = $packageAfter
    $version = [string]$packageAfter.Version
    $packageFullName = [string]$packageAfter.PackageFullName
    $iconHash = Sync-StableIcon -Package $packageAfter
    $state['stable_icon_sha256'] = $iconHash
  }

  $runtime = Wait-ForCurrentCuaRuntime -Package $package -AllowLaunch:$OneClickAuthorized
  if (-not $runtime) {
    Save-PendingCuaRuntimeState -State $state -Package $package -Version $version -PackageFullName $packageFullName
    if ($Launch) {
      Write-RepairLog 'launching Codex Desktop once so the new package can extract its CUA runtime; scoped post-sync remains pending'
      Start-CodexDesktop
    }
    return 0
  }
  if (Test-CurrentCodexMainProcess -Package $package) {
    $restartDesktopAfterRepair = (Stop-CodexDesktopPackageProcesses -Package $package) -or $restartDesktopAfterRepair
  }

  $pluginPostResult = Invoke-PwshScript -Label 'plugin-sync-post' -ScriptPath $PluginRepairScript -Arguments $pluginRepairArguments
  if ($pluginPostResult.ExitCode -ne 0) {
    throw "scoped Browser/Chrome/Computer Use post-sync failed; see $($pluginPostResult.StderrPath)"
  }
  $pluginWarning = ''

  $state['last_status'] = if ([string]::IsNullOrWhiteSpace($pluginWarning)) { 'success' } else { 'success-with-plugin-warning' }
  $state['last_success_at'] = [DateTime]::UtcNow.ToString('o')
  $state['last_successful_version'] = $version
  $state['last_successful_package_full_name'] = $packageFullName
  $state['last_seen_version'] = $version
  $state['last_seen_signature'] = [string]$package.SignatureKind
  $state['last_seen_package_full_name'] = $packageFullName
  $state['plugin_warning'] = $pluginWarning
  $state['last_log'] = $RunLog
  Write-RepairState $state
  Write-RepairLog "repair completed: version=$version signature=$($package.SignatureKind) status=$($state['last_status'])"

  if ($Launch -or $restartDesktopAfterRepair) {
    Publish-UserEnvironmentChange
    Start-CodexDesktop
  }
  return 0
}

$lockStream = $null
$exitCode = 1
try {
  try {
    $lockStream = [System.IO.File]::Open(
      $LockPath,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
  } catch [System.IO.IOException] {
    Write-RepairLog 'another Codex post-update repair instance is already running'
    if ($OneClickAuthorized) {
      Write-RepairLog 'one-click authorization will not wait, retry, or launch through a competing repair instance'
      exit 73
    }
    if ($Launch) {
      Wait-ForRepairAndLaunch
    }
    exit 0
  }

  $exitCode = Invoke-Main
} catch {
  $message = $_.Exception.Message
  Write-RepairLog "failed: $message"
  if (-not $CheckOnly) {
    try {
      $failedState = Read-RepairState
      $failedState['last_status'] = 'failed'
      $failedState['last_error'] = $message
      $failedState['last_failure_at'] = [DateTime]::UtcNow.ToString('o')
      $failedState['last_log'] = $RunLog
      Write-RepairState $failedState
    } catch {
      Write-RepairLog "warning: could not persist failure state: $($_.Exception.Message)"
    }
  } else {
    Write-RepairLog 'check-only failure did not modify the persistent repair state'
  }
  if ($Launch) {
    try {
      Write-RepairLog 'repair failed safely; falling back to the currently installed Codex package'
      Start-CodexDesktop
    } catch {
      Write-RepairLog "warning: fallback Codex launch failed: $($_.Exception.Message)"
    }
  }
  $exitCode = 1
} finally {
  if ($lockStream) {
    $lockStream.Dispose()
  }
}

exit $exitCode
