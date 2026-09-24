[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [version]$ExpectedUpdateVersion,

  [switch]$RestartApprovedForThisUpdate,

  [ValidatePattern('^[0-9a-fA-F]{32}$')]
  [string]$StandingAuthorizationId,

  [switch]$RepairCurrentStorePackage,

  [switch]$AllowStoreBaselineForUpgrade,

  [switch]$ValidateOnly,

  [ValidateRange(15, 180)]
  [int]$AuthorizationMinutes = 120,

  [ValidateRange(1, 30)]
  [int]$StablePackageSeconds = 3,

  [ValidateRange(5, 120)]
  [int]$StableRestartSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$automationRoot = Join-Path $env:USERPROFILE '.codex\automation'
$watcherPath = Join-Path $automationRoot 'watch-codex-update-cycle.ps1'
$repairScriptPath = Join-Path $automationRoot 'codex-post-update-repair.ps1'
$patchScriptPath = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch\scripts\patch_codex_fast_mode_windows_msix.ps1'
$authorizationPath = Join-Path $automationRoot 'update-cycle-authorization.json'
$authorizationLastPath = Join-Path $automationRoot 'update-cycle-authorization.last.json'
$standingAuthorizationPath = Join-Path $automationRoot 'standing-update-authorization.json'
$lockPath = Join-Path $automationRoot 'update-cycle-active.lock'
$persistentTaskName = 'Codex Desktop Post-Update Repair'
$expectedPackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
$expectedPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$expectedScope = 'browser-computer-use-plus-custom-model-visibility'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-ValidStandingAuthorization {
  param([Parameter(Mandatory)][string]$AuthorizationId)

  if (-not (Test-Path -LiteralPath $standingAuthorizationPath -PathType Leaf)) {
    throw "standing update authorization is missing: $standingAuthorizationPath"
  }
  try {
    $standingAuthorization = Get-Content -LiteralPath $standingAuthorizationPath -Raw | ConvertFrom-Json -DateKind String
  } catch {
    throw "standing update authorization is unreadable: $($_.Exception.Message)"
  }
  $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ([int]$standingAuthorization.schema -ne 1 -or
      [string]$standingAuthorization.status -ne 'active' -or
      -not [string]::Equals([string]$standingAuthorization.authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([string]$standingAuthorization.scope, $expectedScope, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$standingAuthorization.package_name, 'OpenAI.Codex', [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$standingAuthorization.package_family_name, $expectedPackageFamilyName, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$standingAuthorization.manifest_publisher, $expectedPublisher, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$standingAuthorization.authorized_user_sid, $currentSid, [StringComparison]::OrdinalIgnoreCase) -or
      [bool]$standingAuthorization.allow_future_store_versions -ne $true -or
      [bool]$standingAuthorization.allow_automatic_restart_repair -ne $true) {
    throw 'standing update authorization does not match this user and the exact OpenAI.Codex package scope'
  }
  return $standingAuthorization
}

function Resolve-StablePwsh7 {
  function Test-UnsafePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
      return $true
    }
    $normalized = [System.IO.Path]::GetFullPath($Path)
    return (
      $normalized -match '(?i)\\\.cache\\codex-runtimes\\' -or
      $normalized -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\'
    )
  }

  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
    'C:\Program Files\PowerShell\7\pwsh.exe'
  )
  $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) {
    $candidates += $command.Source
  }

  foreach ($candidate in $candidates | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      continue
    }
    try {
      $probeJson = & $candidate -NoProfile -NonInteractive -Command (
        '[pscustomobject]@{ ProcessPath=[Environment]::ProcessPath; PSHOME=$PSHOME; Version=$PSVersionTable.PSVersion.ToString() } | ConvertTo-Json -Compress'
      ) 2>$null
      if ($LASTEXITCODE -ne 0 -or -not $probeJson) {
        continue
      }
      $probe = ($probeJson | Select-Object -Last 1) | ConvertFrom-Json
      if ([version][string]$probe.Version -ge [version]'7.5' -and
          -not (Test-UnsafePath -Path ([string]$probe.ProcessPath)) -and
          -not (Test-UnsafePath -Path (Join-Path ([string]$probe.PSHOME) 'pwsh.exe'))) {
        return [System.IO.Path]::GetFullPath([string]$probe.ProcessPath)
      }
    } catch {
      continue
    }
  }
  throw 'an external PowerShell 7.5 or newer executable was not found; Codex-bundled runtimes are refused'
}

function Get-CodexPackage {
  return Get-AppxPackage -Name 'OpenAI.Codex' -PackageTypeFilter Main -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
}

function Get-CodexManifestMainExecutablePath {
  param([Parameter(Mandatory)][object]$Package)

  $installRoot = [System.IO.Path]::GetFullPath([string]$Package.InstallLocation).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $manifestPath = Join-Path $installRoot 'AppxManifest.xml'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Codex manifest is missing: $manifestPath"
  }
  $manifest = [xml][System.IO.File]::ReadAllText($manifestPath)
  $applications = @($manifest.Package.Applications.Application)
  $application = $applications | Where-Object { [string]$_.Id -eq 'App' } | Select-Object -First 1
  if (-not $application -and $applications.Count -eq 1) {
    $application = $applications[0]
  }
  $relativeExecutable = [string]$application.Executable
  if ([string]::IsNullOrWhiteSpace($relativeExecutable) -or [System.IO.Path]::IsPathRooted($relativeExecutable)) {
    throw 'Codex manifest does not declare a safe relative executable'
  }
  $executablePath = [System.IO.Path]::GetFullPath((Join-Path $installRoot $relativeExecutable))
  if (-not $executablePath.StartsWith($installRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Codex manifest executable is invalid: $executablePath"
  }
  return $executablePath
}

function Get-CodexMainProcess {
  param([Parameter(Mandatory)][string]$ExactPath)

  $name = [System.IO.Path]::GetFileName($ExactPath).Replace("'", "''")
  return Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CreationDate -and
      -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
      -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
      $_.CommandLine -notmatch '(?i)(?:^|\s)--type(?:=|\s)' -and
      [string]::Equals(
        [System.IO.Path]::GetFullPath([string]$_.ExecutablePath),
        $ExactPath,
        [StringComparison]::OrdinalIgnoreCase
      )
    } |
    Sort-Object CreationDate -Descending |
    Select-Object -First 1
}

function Get-ExpectedPackageFullName {
  param(
    [Parameter(Mandatory)][string]$BaselinePackageFullName,
    [Parameter(Mandatory)][version]$BaselineVersion,
    [Parameter(Mandatory)][version]$ExpectedVersion
  )

  $versionToken = '_{0}_' -f [string]$BaselineVersion
  $tokenIndex = $BaselinePackageFullName.IndexOf($versionToken, [StringComparison]::OrdinalIgnoreCase)
  if ($tokenIndex -lt 1) {
    throw "cannot derive the expected package identity from $BaselinePackageFullName"
  }
  return $BaselinePackageFullName.Substring(0, $tokenIndex) +
    ('_{0}_' -f [string]$ExpectedVersion) +
    $BaselinePackageFullName.Substring($tokenIndex + $versionToken.Length)
}

function Write-JsonFileAtomically {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object]$Value
  )

  $parent = Split-Path -Parent $Path
  $leaf = Split-Path -Leaf $Path
  $temporaryPath = Join-Path $parent ('.{0}.tmp-{1}-{2}' -f $leaf, $PID, [Guid]::NewGuid().ToString('N'))
  $replacementBackupPath = Join-Path $parent ('.{0}.replace-backup-{1}-{2}' -f $leaf, $PID, [Guid]::NewGuid().ToString('N'))
  try {
    [System.IO.File]::WriteAllText(
      $temporaryPath,
      (($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
      $utf8NoBom
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

function Quote-TaskArgument {
  param([Parameter(Mandatory)][string]$Value)

  if ($Value.Contains('"')) {
    throw 'task arguments must not contain a double quote'
  }
  return '"' + $Value + '"'
}

function Get-TextSha256 {
  param([Parameter(Mandatory)][string]$Value)

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    return ([System.BitConverter]::ToString($hash)).Replace('-', '')
  } finally {
    $sha256.Dispose()
  }
}

function Remove-StaleOneClickTasks {
  foreach ($recordPath in @($authorizationPath, $authorizationLastPath)) {
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
      continue
    }
    try {
      $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -DateKind String
      $recordId = [string]$record.authorization_id
      $recordVersion = [version][string]$record.expected_update_version
      if ($recordId -notmatch '^[0-9a-fA-F]{32}$') {
        continue
      }
      $derivedTaskName = 'Codex One-Click Update {0} {1}' -f [string]$recordVersion, $recordId.Substring(0, 8).ToLowerInvariant()
      if (-not [string]::Equals([string]$record.task_name, $derivedTaskName, [StringComparison]::Ordinal)) {
        continue
      }
      $expired = [DateTimeOffset]::UtcNow -ge ([DateTimeOffset]::Parse([string]$record.expires_at)).ToUniversalTime()
      $terminal = -not [string]::IsNullOrWhiteSpace([string]$record.result)
      if (-not $expired -and -not $terminal) {
        continue
      }
      $handoffPath = if ($record.PSObject.Properties['install_handoff_path']) {
        [string]$record.install_handoff_path
      } else {
        ''
      }
      if (-not [string]::IsNullOrWhiteSpace($handoffPath) -and (Test-Path -LiteralPath $handoffPath -PathType Leaf)) {
        $handoff = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json -DateKind String
        $handoffStatus = [string]$handoff.status
        if ($handoffStatus -in @('prepared', 'installing', 'failed-install', 'installed-awaiting-finalize')) {
          Write-Warning "retaining exact-artifact recovery task because its handoff has not reached completed: $derivedTaskName"
          continue
        }
      }
      $task = Get-ScheduledTask -TaskName $derivedTaskName -ErrorAction SilentlyContinue
      if ($task -and [string]$task.State -ne 'Running') {
        Unregister-ScheduledTask -TaskName $derivedTaskName -Confirm:$false -ErrorAction Stop
      }
    } catch {
      Write-Warning "stale one-click task cleanup skipped for $recordPath`: $($_.Exception.Message)"
    }
  }
}

$standingAuthorization = if ([string]::IsNullOrWhiteSpace($StandingAuthorizationId)) {
  $null
} else {
  Get-ValidStandingAuthorization -AuthorizationId $StandingAuthorizationId
}

if (-not $ValidateOnly -and -not $RestartApprovedForThisUpdate -and -not $standingAuthorization) {
  throw 'this update cycle was not explicitly authorized to restart Codex'
}
foreach ($requiredPath in @($watcherPath, $repairScriptPath, $patchScriptPath,
    (Join-Path $automationRoot 'show-codex-update-progress.ps1'),
    (Join-Path $automationRoot 'start-codex-cli-fallback.ps1'),
    (Join-Path $automationRoot 'codex-appdata-backup.ps1'),
    (Join-Path $automationRoot 'open-codex-cli-fallback.ps1'),
    (Join-Path $automationRoot 'codex-update-cleanup.ps1'))) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "required one-click update component is missing: $requiredPath"
  }
}

$persistentTask = Get-ScheduledTask -TaskName $persistentTaskName -ErrorAction SilentlyContinue
if ($persistentTask -and [string]$persistentTask.State -ne 'Disabled' -and -not $standingAuthorization) {
  throw "the unscoped periodic repair task must remain disabled: $persistentTaskName"
}
if (-not $ValidateOnly) {
  Remove-StaleOneClickTasks
}

$lockProbe = $null
try {
  $lockProbe = [System.IO.File]::Open(
    $lockPath,
    [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )
} catch [System.IO.IOException] {
  throw 'another Codex update watcher is already active'
} finally {
  if ($lockProbe) {
    $lockProbe.Dispose()
  }
}

if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
  try {
    $existingAuthorization = Get-Content -LiteralPath $authorizationPath -Raw | ConvertFrom-Json
    $existingExpiry = [DateTimeOffset]::Parse([string]$existingAuthorization.expires_at)
    if ([string]$existingAuthorization.status -eq 'armed' -and [DateTimeOffset]::UtcNow -lt $existingExpiry.ToUniversalTime()) {
      throw "an unexpired one-click update authorization is already armed: $($existingAuthorization.authorization_id)"
    }
  } catch {
    if ($_.Exception.Message -like 'an unexpired one-click update authorization*') {
      throw
    }
  }
  if (-not $ValidateOnly) {
    [System.IO.File]::Delete($authorizationPath)
  }
}

$package = Get-CodexPackage
if (-not $package) {
  throw 'OpenAI.Codex is not installed'
}
if ($standingAuthorization -and
    (-not [string]::Equals([string]$package.PackageFamilyName, $expectedPackageFamilyName, [StringComparison]::Ordinal) -or
     -not [string]::Equals([string]$package.Publisher, $expectedPublisher, [StringComparison]::Ordinal))) {
  throw 'installed package identity is outside the standing authorization scope'
}
$baselineVersion = [version][string]$package.Version
if ($RepairCurrentStorePackage) {
  if ($ExpectedUpdateVersion -ne $baselineVersion) {
    throw "current Store package recovery requires the installed version exactly: installed=$baselineVersion expected=$ExpectedUpdateVersion"
  }
  if ([string]$package.SignatureKind -ne 'Store') {
    throw "current Store package recovery requires a Store-signed package: signature=$($package.SignatureKind)"
  }
} else {
  if ($ExpectedUpdateVersion -le $baselineVersion) {
    throw "expected update version must be greater than the installed version: installed=$baselineVersion expected=$ExpectedUpdateVersion"
  }
  if ([string]$package.SignatureKind -ne 'Developer' -and
      -not ($AllowStoreBaselineForUpgrade -and [string]$package.SignatureKind -eq 'Store')) {
    throw "the installed baseline is not an allowed package for this update: signature=$($package.SignatureKind)"
  }
}

$baselinePackageFullName = [string]$package.PackageFullName
$expectedPackageFullName = if ($RepairCurrentStorePackage) {
  $baselinePackageFullName
} else {
  Get-ExpectedPackageFullName `
    -BaselinePackageFullName $baselinePackageFullName `
    -BaselineVersion $baselineVersion `
    -ExpectedVersion $ExpectedUpdateVersion
}
$baselineMainProcessPath = Get-CodexManifestMainExecutablePath -Package $package
$baselineMainProcess = Get-CodexMainProcess -ExactPath $baselineMainProcessPath
if (-not $baselineMainProcess) {
  throw 'the manifest-declared Codex main process must be running before arming one-click update'
}
$baselineCreationDate = [DateTimeOffset]::new([datetime]$baselineMainProcess.CreationDate)
$authorizationId = [Guid]::NewGuid().ToString('N')
$grantedAt = [DateTimeOffset]::UtcNow
$expiresAt = $grantedAt.AddMinutes($AuthorizationMinutes)
$pwshPath = Resolve-StablePwsh7
$taskName = 'Codex One-Click Update {0} {1}' -f [string]$ExpectedUpdateVersion, $authorizationId.Substring(0, 8)
$installRequestRoot = Join-Path (Join-Path $automationRoot 'install-handoffs') $authorizationId
$installHandoffPath = Join-Path $installRequestRoot 'pending-msix-install.json'

$taskArguments = @(
  '-NoProfile',
  '-NonInteractive',
  '-WindowStyle', 'Hidden',
  '-ExecutionPolicy', 'Bypass',
  '-File', (Quote-TaskArgument $watcherPath),
  '-BaselineVersion', (Quote-TaskArgument ([string]$baselineVersion)),
  '-ExpectedUpdateVersion', (Quote-TaskArgument ([string]$ExpectedUpdateVersion)),
  '-ExpectedPackageFullName', (Quote-TaskArgument $expectedPackageFullName),
  '-BaselinePackageFullName', (Quote-TaskArgument $baselinePackageFullName),
  '-BaselineMainProcessId', [string][int]$baselineMainProcess.ProcessId,
  '-BaselineMainProcessCreationDate', (Quote-TaskArgument $baselineCreationDate.ToString('o')),
  '-BaselineMainProcessPath', (Quote-TaskArgument $baselineMainProcessPath),
  '-AuthorizationId', $authorizationId,
  '-RepairPwshPath', (Quote-TaskArgument $pwshPath),
  '-RepairScriptPath', (Quote-TaskArgument $repairScriptPath),
  '-TimeoutMinutes', [string]$AuthorizationMinutes,
  '-StablePackageSeconds', [string]$StablePackageSeconds,
  '-StableRestartSeconds', [string]$StableRestartSeconds
)
if ($RepairCurrentStorePackage) {
  $taskArguments += '-RepairCurrentStorePackage'
}
$taskArguments = $taskArguments -join ' '

$authorization = [ordered]@{
  schema = 1
  status = 'armed'
  authorization_id = $authorizationId
  scope = 'browser-computer-use-plus-custom-model-visibility'
  standing_authorization_id = if ($standingAuthorization) { $StandingAuthorizationId.ToLowerInvariant() } else { '' }
  granted_at = $grantedAt.ToString('o')
  expires_at = $expiresAt.ToString('o')
  baseline_version = [string]$baselineVersion
  baseline_signature_kind = [string]$package.SignatureKind
  expected_update_version = [string]$ExpectedUpdateVersion
  repair_current_store_package = [bool]$RepairCurrentStorePackage
  baseline_package_full_name = $baselinePackageFullName
  expected_package_full_name = $expectedPackageFullName
  baseline_main_process_id = [int]$baselineMainProcess.ProcessId
  baseline_main_process_creation_date = $baselineCreationDate.ToUniversalTime().ToString('o')
  baseline_main_process_path = $baselineMainProcessPath
  watcher_path = $watcherPath
  watcher_sha256 = (Get-FileHash -LiteralPath $watcherPath -Algorithm SHA256).Hash
  repair_script_path = $repairScriptPath
  repair_script_sha256 = (Get-FileHash -LiteralPath $repairScriptPath -Algorithm SHA256).Hash
  patch_script_path = $patchScriptPath
  patch_script_sha256 = (Get-FileHash -LiteralPath $patchScriptPath -Algorithm SHA256).Hash
  repair_engine_path = $pwshPath
  task_name = $taskName
  task_arguments_sha256 = Get-TextSha256 -Value $taskArguments
  install_request_root = $installRequestRoot
  install_handoff_path = $installHandoffPath
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $pwshPath -Argument $taskArguments -WorkingDirectory $automationRoot
$resumeTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit (New-TimeSpan -Hours 4)
$task = New-ScheduledTask `
  -Action $action `
  -Trigger $resumeTrigger `
  -Principal $principal `
  -Settings $settings `
  -Description 'One-time, exact-version Codex Store update plus scoped Browser/Computer Use and custom-model repatch; generated from an explicit one-time or standing authorization.'

if ($ValidateOnly) {
  [pscustomobject]@{
    Valid = $true
    WouldArm = $false
    AuthorizationId = $authorizationId
    Scope = $authorization.scope
    ExpiresAt = $expiresAt.ToLocalTime().ToString('o')
    BaselineVersion = [string]$baselineVersion
    ExpectedVersion = [string]$ExpectedUpdateVersion
    ExpectedPackageFullName = $expectedPackageFullName
    BaselineMainProcessId = [int]$baselineMainProcess.ProcessId
    TaskName = $taskName
    RepairEngine = $pwshPath
    PersistentRepairTaskState = if ($persistentTask) { [string]$persistentTask.State } else { 'Absent' }
  } | Format-List
  return
}

$taskRegistered = $false
try {
  Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
  $taskRegistered = $true
  Write-JsonFileAtomically -Path $authorizationPath -Value $authorization

  $identityCheck = Get-CodexMainProcess -ExactPath $baselineMainProcessPath
  if (-not $identityCheck -or [int]$identityCheck.ProcessId -ne [int]$baselineMainProcess.ProcessId -or
      ([DateTimeOffset]::new([datetime]$identityCheck.CreationDate)).ToUniversalTime().UtcDateTime.Ticks -ne
      $baselineCreationDate.ToUniversalTime().UtcDateTime.Ticks) {
    throw 'the baseline Codex process changed while one-click update was being armed'
  }

  Start-ScheduledTask -TaskName $taskName
  Start-Sleep -Milliseconds 750
  $savedTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  $savedInfo = $savedTask | Get-ScheduledTaskInfo
  [pscustomobject]@{
    Armed = $true
    AuthorizationId = $authorizationId
    Scope = $authorization.scope
    ExpiresAt = $expiresAt.ToLocalTime().ToString('o')
    BaselineVersion = [string]$baselineVersion
    ExpectedVersion = [string]$ExpectedUpdateVersion
    ExpectedPackageFullName = $expectedPackageFullName
    BaselineMainProcessId = [int]$baselineMainProcess.ProcessId
    TaskName = $taskName
    TaskState = [string]$savedTask.State
    LastTaskResult = $savedInfo.LastTaskResult
    PersistentRepairTaskState = if ($persistentTask) { [string]$persistentTask.State } else { 'Absent' }
  } | Format-List
} catch {
  if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
    [System.IO.File]::Delete($authorizationPath)
  }
  if ($taskRegistered) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  }
  throw
}
