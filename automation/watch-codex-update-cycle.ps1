[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [version]$BaselineVersion,

  [Parameter(Mandatory)]
  [version]$ExpectedUpdateVersion,

  [switch]$RepairCurrentStorePackage,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$ExpectedPackageFullName,

  [Parameter(Mandatory)]
  [string]$BaselinePackageFullName,

  [Parameter(Mandatory)]
  [int]$BaselineMainProcessId,

  [Parameter(Mandatory)]
  [DateTimeOffset]$BaselineMainProcessCreationDate,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$BaselineMainProcessPath,

  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9a-fA-F]{32}$')]
  [string]$AuthorizationId,

  [Parameter(Mandatory)]
  [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
  [string]$RepairPwshPath,

  [Parameter(Mandatory)]
  [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
  [string]$RepairScriptPath,

  [ValidateRange(5, 180)]
  [int]$TimeoutMinutes = 90,

  [ValidateRange(1, 30)]
  [int]$StablePackageSeconds = 3,

  [ValidateRange(5, 120)]
  [int]$StableRestartSeconds = 20,

  [ValidateRange(5, 120)]
  [int]$FinalProcessTimeoutMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$automationRoot = Join-Path $env:USERPROFILE '.codex\automation'
$logRoot = Join-Path $automationRoot 'logs'
$statePath = Join-Path $automationRoot 'update-cycle-active.json'
$lockPath = Join-Path $automationRoot 'update-cycle-active.lock'
$authorizationPath = Join-Path $automationRoot 'update-cycle-authorization.json'
$authorizationLastPath = Join-Path $automationRoot 'update-cycle-authorization.last.json'
$repairStatePath = Join-Path $automationRoot 'post-update-state.json'
$patchScriptPath = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch\scripts\patch_codex_fast_mode_windows_msix.ps1'
$installHandoffRoot = Join-Path $automationRoot 'install-handoffs'
$installRequestRoot = Join-Path $installHandoffRoot $AuthorizationId.ToLowerInvariant()
$installHandoffPath = Join-Path $installRequestRoot 'pending-msix-install.json'
$installHandoffLastPath = Join-Path $installRequestRoot 'completed-msix-install.json'
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$logPath = Join-Path $logRoot "update-cycle-$runStamp-$PID.log"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:progressJournal = $null
$script:repairBegan = $false
$script:cliFallbackOpened = $false

function Write-UpdateProgress {
  param([hashtable]$Event)
  if (-not $script:progressJournal) { return }
  try {
    $Event['time'] = Get-Date -Format 'HH:mm:ss'
    [IO.File]::AppendAllText($script:progressJournal, (($Event | ConvertTo-Json -Compress -Depth 5) + "`n"), $utf8NoBom)
  } catch { Write-Warning "Progress display write failed; repair continues: $($_.Exception.Message)" }
}

function Start-UpdateProgressWindow {
  if ($script:progressJournal) { return }
  $script:progressJournal = Join-Path $logRoot "update-cycle-$runStamp-$PID.progress.log"
  [IO.File]::WriteAllText($script:progressJournal, '', $utf8NoBom)
  $viewer = Join-Path $automationRoot 'show-codex-update-progress.ps1'
  try {
    $startTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    $viewerArgs = @('-NoProfile', '-File', ('"{0}"' -f $viewer), '-JournalPath', ('"{0}"' -f $script:progressJournal),
      '-LogRoot', ('"{0}"' -f $logRoot), '-MonitorId', "$PID", '-MonitorStartTicks', "$startTicks")
    # The user explicitly requested a visible progress terminal. It is read-only
    # and independent from the worker, so closing it cannot stop deployment.
    Start-Process -FilePath $RepairPwshPath -ArgumentList $viewerArgs -WindowStyle Normal | Out-Null
  } catch { Write-CycleLog "progress window could not open: $($_.Exception.Message); journal=$script:progressJournal" }
}

function Write-CycleLog {
  param([string]$Message)

  $line = '{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $Message
  [System.IO.File]::AppendAllText(
    $logPath,
    $line + [Environment]::NewLine,
    $utf8NoBom
  )
  Write-UpdateProgress @{ kind = 'log'; text = $line }
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

function Test-AuthorizedSchedulerLaunch {
  try {
    $authorization = if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
      Assert-RepairAuthorization -Authorization (Read-RepairAuthorization)
    } else {
      Assert-RepairAuthorization -Authorization (Read-RepairAuthorization -Path $authorizationLastPath) -AllowConsumed
    }
    $expectedTaskName = 'Codex One-Click Update {0} {1}' -f [string]$ExpectedUpdateVersion, $AuthorizationId.Substring(0, 8).ToLowerInvariant()
    $task = Get-ScheduledTask -TaskName $expectedTaskName -ErrorAction Stop
    $actions = @($task.Actions)
    if ([string]$task.State -ne 'Running' -or
        [string]$task.TaskPath -ne '\' -or
        $actions.Count -ne 1 -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$actions[0].Execute), [System.IO.Path]::GetFullPath($RepairPwshPath), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$actions[0].WorkingDirectory), [System.IO.Path]::GetFullPath($automationRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-TextSha256 -Value ([string]$actions[0].Arguments)), [string]$authorization.task_arguments_sha256, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$task.Principal.RunLevel -ne 'Limited') {
      return $false
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principalUser = [string]$task.Principal.UserId
    $principalMatches = [string]::Equals($principalUser, $identity.Name, [StringComparison]::OrdinalIgnoreCase) -or
      [string]::Equals($principalUser, $identity.User.Value, [StringComparison]::OrdinalIgnoreCase)
    if (-not $principalMatches) {
      try {
        $principalSid = ([System.Security.Principal.NTAccount]::new($principalUser)).Translate(
          [System.Security.Principal.SecurityIdentifier]
        ).Value
        $principalMatches = [string]::Equals($principalSid, $identity.User.Value, [StringComparison]::OrdinalIgnoreCase)
      } catch {
        return $false
      }
    }
    if (-not $principalMatches) {
      return $false
    }

    $requiredArgumentFragments = @(
      ('-File "{0}"' -f $PSCommandPath),
      ('-ExpectedUpdateVersion "{0}"' -f [string]$ExpectedUpdateVersion),
      ('-ExpectedPackageFullName "{0}"' -f $ExpectedPackageFullName),
      ('-AuthorizationId {0}' -f $AuthorizationId),
      ('-RepairPwshPath "{0}"' -f $RepairPwshPath),
      ('-RepairScriptPath "{0}"' -f $RepairScriptPath)
    )
    foreach ($fragment in $requiredArgumentFragments) {
      if ([string]$actions[0].Arguments.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        return $false
      }
    }

    $currentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
    $taskInfo = $task | Get-ScheduledTaskInfo -ErrorAction Stop
    if (-not $currentProcess.CreationDate -or -not $taskInfo.LastRunTime) {
      return $false
    }
    $processCreatedAt = [DateTimeOffset]::new([datetime]$currentProcess.CreationDate)
    $taskStartedAt = [DateTimeOffset]::new([datetime]$taskInfo.LastRunTime)
    if ([math]::Abs(($processCreatedAt - $taskStartedAt).TotalSeconds) -gt 120) {
      return $false
    }

    $scheduleService = $null
    $taskFolder = $null
    $registeredTask = $null
    $runningInstances = @()
    try {
      $scheduleService = New-Object -ComObject 'Schedule.Service'
      $scheduleService.Connect()
      $taskFolder = $scheduleService.GetFolder('\')
      $registeredTask = $taskFolder.GetTask($expectedTaskName)
      $runningInstances = @($registeredTask.GetInstances(0))
      return @($runningInstances | Where-Object { [int]$_.EnginePID -eq $PID }).Count -eq 1
    } finally {
      foreach ($instance in $runningInstances) {
        if ($instance -and [System.Runtime.InteropServices.Marshal]::IsComObject($instance)) {
          [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($instance)
        }
      }
      foreach ($comObject in @($registeredTask, $taskFolder, $scheduleService)) {
        if ($comObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
          [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
        }
      }
    }
  } catch {
    return $false
  }
}

function Assert-ExternalDesktopRepairContext {
  $engineProbe = Get-ExternalPwshProbe -Candidate $RepairPwshPath
  if (-not $engineProbe -or
      -not [string]::Equals($engineProbe.ProcessPath, [Environment]::ProcessPath, [StringComparison]::OrdinalIgnoreCase) -or
      (Test-UnsafeCodexPowerShellPath -Path ([Environment]::ProcessPath)) -or
      (Test-UnsafeCodexPowerShellPath -Path (Join-Path $PSHOME 'pwsh.exe'))) {
    throw 'the update watcher is not running in its authorized external PowerShell host'
  }

  $nextProcessId = $PID
  for ($depth = 0; $depth -lt 24 -and $nextProcessId -gt 0; $depth++) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$nextProcessId" -ErrorAction SilentlyContinue
    if (-not $process) {
      if ($depth -gt 0 -and (Test-AuthorizedSchedulerLaunch)) {
        Write-CycleLog "accepted unresolved scheduler ancestor only after exact running-task contract validation: pid=$nextProcessId"
        break
      }
      throw "could not prove external watcher process lineage: unresolved pid=$nextProcessId"
    }
    $path = [string]$process.ExecutablePath
    if ((-not [string]::IsNullOrWhiteSpace($path) -and (Test-UnsafeCodexPowerShellPath -Path $path)) -or
        [string]$process.Name -match '^(?i:Codex|ChatGPT)\.exe$') {
      throw "unsafe Codex Desktop process lineage detected before install: pid=$nextProcessId path=$path"
    }
    $nextProcessId = [int]$process.ParentProcessId
  }
  return $engineProbe
}

function Write-CycleState {
  param(
    [string]$Status,
    [hashtable]$Details = @{}
  )

  $stageNames = @{
    'armed'='等待商店更新或已授权的重启'; 'updated-package-detected'='已检测到新商店版'
    'prepare-running'='检查兼容性、同步组件并构建补丁'; 'prepared-install-validated'='补丁包校验通过，准备安装（官方恢复包可选）'
    'installed-awaiting-finalize'='补丁已安装，正在完成配置'; 'patched-process-detected'='已启动，检查窗口稳定性'
    'repair-restart-stable'='更新与重补丁完成，启动检查通过'; 'store-preserved'='补丁未应用：已保留商店版'
    'store-restored'='补丁失败：已恢复官方商店版'; 'failed-prepare'='补丁准备失败，保留商店版'
    'store-recovery-failed'='恢复未成功，已保留恢复包和日志，需要处理'
    'failed-install'='补丁安装失败，准备打开 Codex CLI'; 'failed-finalize'='补丁完成检查失败，准备打开 Codex CLI'
    'repair-failed-cli-opened'='重补丁未完成，已打开 Codex CLI 备用终端'; 'cli-fallback-failed'='重补丁失败，CLI 终端未能打开，请查看日志'
  }
  $stageText = if ($stageNames.ContainsKey($Status)) { $stageNames[$Status] } else { $Status }
  Write-UpdateProgress @{ kind = 'stage'; text = $stageText }

  $state = [ordered]@{
    schema = 2
    updated_at = [DateTimeOffset]::Now.ToString('o')
    status = $Status
    monitor_pid = $PID
    baseline_version = [string]$BaselineVersion
    expected_update_version = [string]$ExpectedUpdateVersion
    expected_package_full_name = $ExpectedPackageFullName
    authorization_id = $AuthorizationId.ToLowerInvariant()
    baseline_package_full_name = $BaselinePackageFullName
    baseline_main_process_id = $BaselineMainProcessId
    baseline_main_process_creation_date = $BaselineMainProcessCreationDate.ToUniversalTime().ToString('o')
    baseline_main_process_path = $BaselineMainProcessPath
    log_path = $logPath
  }
  foreach ($entry in $Details.GetEnumerator()) {
    if ($state.Contains($entry.Key)) {
      throw "state detail key is reserved: $($entry.Key)"
    }
    $state[$entry.Key] = $entry.Value
  }

  $temporaryPath = Join-Path $automationRoot (
    '.update-cycle-active.json.tmp-{0}-{1}' -f $PID, [Guid]::NewGuid().ToString('N')
  )
  $replacementBackupPath = Join-Path $automationRoot (
    '.update-cycle-active.json.replace-backup-{0}-{1}' -f $PID, [Guid]::NewGuid().ToString('N')
  )
  $json = ($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine
  $bytes = $utf8NoBom.GetBytes($json)
  $temporaryStream = $null
  try {
    try {
      $temporaryStream = [System.IO.FileStream]::new(
        $temporaryPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::WriteThrough
      )
      $temporaryStream.Write($bytes, 0, $bytes.Length)
      $temporaryStream.Flush($true)
    } finally {
      if ($temporaryStream) {
        $temporaryStream.Dispose()
      }
    }

    if ([System.IO.File]::Exists($statePath)) {
      [System.IO.File]::Replace($temporaryPath, $statePath, $replacementBackupPath, $true)
    } else {
      [System.IO.File]::Move($temporaryPath, $statePath)
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

function Remove-CurrentOneClickTaskDefinition {
  $expectedTaskName = 'Codex One-Click Update {0} {1}' -f [string]$ExpectedUpdateVersion, $AuthorizationId.Substring(0, 8).ToLowerInvariant()
  $record = $null
  foreach ($candidatePath in @($authorizationLastPath, $authorizationPath)) {
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
      continue
    }
    try {
      $candidate = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json -DateKind String
      if ([string]::Equals([string]$candidate.authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase) -and
          [string]::Equals([string]$candidate.task_name, $expectedTaskName, [StringComparison]::Ordinal)) {
        $record = $candidate
        break
      }
    } catch {
      continue
    }
  }
  if (-not $record) {
    return
  }
  if (Test-Path -LiteralPath $installHandoffPath -PathType Leaf) {
    try {
      $handoff = Read-InstallHandoff
      $handoffStatus = [string]$handoff.status
      $mustRetain = $handoffStatus -in @('prepared', 'installing', 'failed-install', 'installed-awaiting-finalize')
      if ($mustRetain) {
        Write-CycleLog "retaining recovery task because the exact install handoff has not reached completed: $expectedTaskName"
        return
      }
    } catch {
      Write-CycleLog "retaining recovery task because install recovery state could not be proven terminal: $($_.Exception.Message)"
      return
    }
  }
  $task = Get-ScheduledTask -TaskName $expectedTaskName -ErrorAction SilentlyContinue
  if ($task) {
    Unregister-ScheduledTask -TaskName $expectedTaskName -Confirm:$false -ErrorAction Stop
    Write-CycleLog "removed terminal one-click task definition: $expectedTaskName"
  }
}

function Get-CodexPackage {
  return Get-AppxPackage -Name 'OpenAI.Codex' -PackageTypeFilter Main -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
}

function Get-CodexManifestMainExecutablePath {
  param([object]$Package)

  if (-not $Package -or [string]::IsNullOrWhiteSpace([string]$Package.InstallLocation)) {
    return $null
  }

  try {
    $installRoot = [System.IO.Path]::GetFullPath([string]$Package.InstallLocation)
    $installRoot = $installRoot.TrimEnd(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    )
    $manifestPath = Join-Path $installRoot 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
      return $null
    }

    $manifest = [xml][System.IO.File]::ReadAllText($manifestPath)
    $applications = @($manifest.Package.Applications.Application)
    $application = $applications | Where-Object { [string]$_.Id -eq 'App' } | Select-Object -First 1
    if (-not $application -and $applications.Count -eq 1) {
      $application = $applications[0]
    }
    $relativeExecutable = [string]$application.Executable
    if ([string]::IsNullOrWhiteSpace($relativeExecutable) -or
        [System.IO.Path]::IsPathRooted($relativeExecutable)) {
      return $null
    }

    $relativeExecutable = $relativeExecutable.Replace(
      [System.IO.Path]::AltDirectorySeparatorChar,
      [System.IO.Path]::DirectorySeparatorChar
    )
    $executablePath = [System.IO.Path]::GetFullPath((Join-Path $installRoot $relativeExecutable))
    $installPrefix = $installRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $executablePath.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      return $null
    }
    return $executablePath
  } catch {
    return $null
  }
}

function Test-CompletePackage {
  param([object]$Package)

  if (-not $Package) {
    return $false
  }
  $mainExecutablePath = Get-CodexManifestMainExecutablePath -Package $Package
  if ([string]::IsNullOrWhiteSpace($mainExecutablePath)) {
    return $false
  }
  $appAsarPath = Join-Path ([string]$Package.InstallLocation) 'app\resources\app.asar'
  return (
    (Test-Path -LiteralPath $mainExecutablePath -PathType Leaf) -and
    (Test-Path -LiteralPath $appAsarPath -PathType Leaf)
  )
}

function Test-ExpectedPackage {
  param([object]$Package)

  if (-not $Package) {
    return $false
  }
  try {
    $candidateVersion = [version][string]$Package.Version
  } catch {
    return $false
  }
  return (
    $candidateVersion -eq $ExpectedUpdateVersion -and
    [string]::Equals(
      [string]$Package.PackageFullName,
      $ExpectedPackageFullName,
      [StringComparison]::OrdinalIgnoreCase
    ) -and
    ($RepairCurrentStorePackage -or
      -not [string]::Equals(
        [string]$Package.PackageFullName,
        $BaselinePackageFullName,
        [StringComparison]::OrdinalIgnoreCase
      ))
  )
}

function Get-ProcessCreationInstant {
  param([object]$Process)

  if (-not $Process -or -not $Process.CreationDate) {
    return $null
  }
  return [DateTimeOffset]::new([datetime]$Process.CreationDate).ToUniversalTime()
}

function Get-ProcessByIdentity {
  param(
    [int]$ProcessId,
    [DateTimeOffset]$CreationDate,
    [string]$ExactPath
  )

  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if (-not $process -or
      [string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
      -not [string]::Equals(
        [System.IO.Path]::GetFullPath([string]$process.ExecutablePath),
        [System.IO.Path]::GetFullPath($ExactPath),
        [StringComparison]::OrdinalIgnoreCase
      )) {
    return $null
  }

  $actualCreationDate = Get-ProcessCreationInstant -Process $process
  if (-not $actualCreationDate -or
      $actualCreationDate.UtcDateTime.Ticks -ne $CreationDate.ToUniversalTime().UtcDateTime.Ticks) {
    return $null
  }
  return $process
}

function Get-CodexMainProcess {
  param([object]$Package)

  $expectedPath = Get-CodexManifestMainExecutablePath -Package $Package
  if ([string]::IsNullOrWhiteSpace($expectedPath)) {
    return $null
  }
  $executableName = [System.IO.Path]::GetFileName($expectedPath)
  $wqlExecutableName = $executableName.Replace("'", "''")
  return Get-CimInstance Win32_Process -Filter "Name='$wqlExecutableName'" -ErrorAction SilentlyContinue |
    Where-Object {
      -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
      -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
      $_.CreationDate -and
      [string]::Equals(
        [System.IO.Path]::GetFullPath([string]$_.ExecutablePath),
        $expectedPath,
        [StringComparison]::OrdinalIgnoreCase
      ) -and
      $_.CommandLine -notmatch '(?i)(?:^|\s)--type(?:=|\s)'
    } |
    Sort-Object CreationDate -Descending |
    Select-Object -First 1
}

function Test-CodexMainWindowReady {
  param([object]$Process)

  if (-not $Process) {
    return $false
  }
  try {
    $desktopProcess = Get-Process -Id ([int]$Process.ProcessId) -ErrorAction Stop
    return $desktopProcess.MainWindowHandle -ne 0 -and $desktopProcess.Responding
  } catch {
    return $false
  }
}

function Get-CodexManifestApplicationId {
  param([Parameter(Mandatory)][object]$Package)

  try {
    $manifestPath = Join-Path ([string]$Package.InstallLocation) 'AppxManifest.xml'
    $manifest = [xml][System.IO.File]::ReadAllText($manifestPath)
    $applications = @($manifest.Package.Applications.Application)
    $matches = @($applications | Where-Object { [string]$_.Id -eq 'App' })
    if ($matches.Count -eq 1) {
      return [string]$matches[0].Id
    }
    if ($matches.Count -eq 0 -and $applications.Count -eq 1) {
      return [string]$applications[0].Id
    }
  } catch {
    return $null
  }
  return $null
}

function Ensure-ExpectedCodexDesktopRunning {
  param([Parameter(Mandatory)][string]$Reason)

  try {
    $package = Get-CodexPackage
    if (-not (Test-ExpectedPackage -Package $package) -or -not (Test-CompletePackage -Package $package)) {
      Write-CycleLog "fallback launch skipped because the exact complete expected package is unavailable: reason=$Reason"
      return $false
    }
    $mainProcess = Get-CodexMainProcess -Package $package
    if ($mainProcess -and (Test-CodexMainWindowReady -Process $mainProcess)) {
      Write-CycleLog "fallback launch not needed; responsive Desktop is already open: reason=$Reason pid=$($mainProcess.ProcessId)"
      return $true
    }
    $applicationId = Get-CodexManifestApplicationId -Package $package
    if ([string]::IsNullOrWhiteSpace($applicationId) -or [string]::IsNullOrWhiteSpace([string]$package.PackageFamilyName)) {
      Write-CycleLog "fallback launch skipped because the package AUMID is unavailable: reason=$Reason"
      return $false
    }
    $aumid = '{0}!{1}' -f [string]$package.PackageFamilyName, $applicationId
    Write-CycleLog "starting exact expected Desktop package after a repair stop: reason=$Reason aumid=$aumid"
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList "shell:AppsFolder\$aumid" | Out-Null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 500
      $mainProcess = Get-CodexMainProcess -Package (Get-CodexPackage)
      if ($mainProcess -and (Test-CodexMainWindowReady -Process $mainProcess)) {
        Write-CycleLog "fallback Desktop launch is responsive: reason=$Reason pid=$($mainProcess.ProcessId)"
        return $true
      }
    }
    Write-CycleLog "warning: fallback Desktop launch did not produce a responsive window within 30 seconds: reason=$Reason"
  } catch {
    Write-CycleLog "warning: fallback Desktop launch failed: reason=$Reason error=$($_.Exception.Message)"
  }
  return $false
}

function Get-ProcessIdentityKey {
  param([object]$Process)

  $creationDate = Get-ProcessCreationInstant -Process $Process
  if (-not $creationDate) {
    return $null
  }
  return '{0}|{1}|{2}' -f (
    [int]$Process.ProcessId,
    $creationDate.UtcDateTime.Ticks,
    [System.IO.Path]::GetFullPath([string]$Process.ExecutablePath).ToLowerInvariant()
  )
}

function Write-JsonFileAtomically {
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [Parameter(Mandatory)]
    [object]$Value
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

function Read-RepairAuthorization {
  param([string]$Path = $authorizationPath)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "one-click update authorization is missing: $Path"
  }
  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
  } catch {
    throw "one-click update authorization is unreadable: $($_.Exception.Message)"
  }
}

function Assert-RepairAuthorization {
  param(
    [Parameter(Mandatory)]
    [object]$Authorization,
    [switch]$AllowConsumed
  )

  $expectedStatus = if ($AllowConsumed) { 'consumed' } else { 'armed' }
  if ([int]$Authorization.schema -ne 1 -or [string]$Authorization.status -ne $expectedStatus) {
    throw "one-click update authorization is not $expectedStatus"
  }
  if (-not [string]::Equals([string]$Authorization.authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'one-click update authorization id does not match the watcher'
  }
  if ([version][string]$Authorization.baseline_version -ne $BaselineVersion -or
      [version][string]$Authorization.expected_update_version -ne $ExpectedUpdateVersion -or
      [bool]$Authorization.repair_current_store_package -ne [bool]$RepairCurrentStorePackage -or
      -not [string]::Equals([string]$Authorization.baseline_package_full_name, $BaselinePackageFullName, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([string]$Authorization.expected_package_full_name, $ExpectedPackageFullName, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'one-click update authorization package scope does not match the watcher'
  }
  if ([int]$Authorization.baseline_main_process_id -ne $BaselineMainProcessId -or
      -not [string]::Equals([string]$Authorization.baseline_main_process_path, $BaselineMainProcessPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'one-click update authorization process scope does not match the watcher'
  }
  $authorizedCreationDate = [DateTimeOffset]::Parse([string]$Authorization.baseline_main_process_creation_date)
  if ($authorizedCreationDate.ToUniversalTime().UtcDateTime.Ticks -ne
      $BaselineMainProcessCreationDate.ToUniversalTime().UtcDateTime.Ticks) {
    throw 'one-click update authorization process creation time does not match the watcher'
  }
  $expiresAt = [DateTimeOffset]::Parse([string]$Authorization.expires_at)
  if (-not $AllowConsumed -and [DateTimeOffset]::UtcNow -ge $expiresAt.ToUniversalTime()) {
    throw "one-click update authorization expired at $($expiresAt.ToString('o'))"
  }
  if ([string]$Authorization.scope -ne 'browser-computer-use-plus-custom-model-visibility') {
    throw "one-click update authorization has an unsupported scope: $($Authorization.scope)"
  }
  $expectedTaskName = 'Codex One-Click Update {0} {1}' -f [string]$ExpectedUpdateVersion, $AuthorizationId.Substring(0, 8).ToLowerInvariant()
  $patcherDrifted = $false
  $repairScriptDrifted = $false
  if (-not $AllowConsumed) {
    $patcherDrifted = -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Authorization.patch_script_path), [System.IO.Path]::GetFullPath($patchScriptPath), [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([string]$Authorization.patch_script_sha256, (Get-FileHash -LiteralPath $patchScriptPath -Algorithm SHA256).Hash, [StringComparison]::OrdinalIgnoreCase)
    $repairScriptDrifted = -not (Test-Path -LiteralPath $RepairScriptPath -PathType Leaf) -or
      -not [string]::Equals([string]$Authorization.repair_script_sha256, (Get-FileHash -LiteralPath $RepairScriptPath -Algorithm SHA256).Hash, [StringComparison]::OrdinalIgnoreCase)
  }
  if (-not [string]::Equals([string]$Authorization.task_name, $expectedTaskName, [StringComparison]::Ordinal) -or
      -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Authorization.watcher_path), [System.IO.Path]::GetFullPath($PSCommandPath), [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([string]$Authorization.watcher_sha256, (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Authorization.repair_script_path), [System.IO.Path]::GetFullPath($RepairScriptPath), [StringComparison]::OrdinalIgnoreCase) -or
      (-not $AllowConsumed -and $repairScriptDrifted) -or
      (-not $AllowConsumed -and $patcherDrifted) -or
      -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Authorization.repair_engine_path), [System.IO.Path]::GetFullPath($RepairPwshPath), [StringComparison]::OrdinalIgnoreCase) -or
      -not $Authorization.PSObject.Properties['task_arguments_sha256'] -or
      [string]$Authorization.task_arguments_sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
      -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Authorization.install_request_root), [System.IO.Path]::GetFullPath($installRequestRoot), [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Authorization.install_handoff_path), [System.IO.Path]::GetFullPath($installHandoffPath), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'one-click update authorization component hashes, task identity, or recovery paths do not match the watcher'
  }
  return $Authorization
}

function Set-UnconsumedAuthorizationFailure {
  param([Parameter(Mandatory)][string]$FailureMessage)

  if (-not (Test-Path -LiteralPath $authorizationPath -PathType Leaf)) {
    return
  }
  try {
    $record = Read-RepairAuthorization
    $expectedTaskName = 'Codex One-Click Update {0} {1}' -f [string]$ExpectedUpdateVersion, $AuthorizationId.Substring(0, 8).ToLowerInvariant()
    if ([int]$record.schema -ne 1 -or
        [string]$record.status -ne 'armed' -or
        -not [string]::Equals([string]$record.authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$record.task_name, $expectedTaskName, [StringComparison]::Ordinal)) {
      return
    }
    $failedRecord = [ordered]@{}
    foreach ($property in $record.PSObject.Properties) {
      $failedRecord[$property.Name] = $property.Value
    }
    $failedRecord['status'] = 'failed'
    $failedRecord['result'] = 'watcher-failed-before-consume'
    $failedRecord['result_at'] = [DateTimeOffset]::UtcNow.ToString('o')
    $failedRecord['error'] = $FailureMessage
    Write-JsonFileAtomically -Path $authorizationPath -Value $failedRecord
    Write-CycleLog 'marked the unconsumed authorization terminal after watcher startup failure'
  } catch {
    Write-CycleLog "warning: could not mark the unconsumed authorization terminal: $($_.Exception.Message)"
  }
}

function Consume-RepairAuthorization {
  $authorization = Assert-RepairAuthorization -Authorization (Read-RepairAuthorization)
  $claimPath = Join-Path $automationRoot ('.update-cycle-authorization.claimed-{0}.json' -f $AuthorizationId.ToLowerInvariant())
  if ([System.IO.File]::Exists($claimPath)) {
    throw "a consumed authorization claim already exists: $claimPath"
  }
  [System.IO.File]::Move($authorizationPath, $claimPath)
  try {
    $claimed = Assert-RepairAuthorization -Authorization (Read-RepairAuthorization -Path $claimPath)
    $record = [ordered]@{}
    foreach ($property in $claimed.PSObject.Properties) {
      $record[$property.Name] = $property.Value
    }
    $record['status'] = 'consumed'
    $record['consumed_at'] = [DateTimeOffset]::UtcNow.ToString('o')
    $monitorProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
    $record['monitor_pid'] = $PID
    $record['monitor_creation_date'] = ([DateTimeOffset]::new([datetime]$monitorProcess.CreationDate)).ToUniversalTime().ToString('o')
    Write-JsonFileAtomically -Path $authorizationLastPath -Value $record
    return [pscustomobject]$record
  } finally {
    if ([System.IO.File]::Exists($claimPath)) {
      [System.IO.File]::Delete($claimPath)
    }
  }
}

function Update-ConsumedAuthorization {
  param(
    [Parameter(Mandatory)]
    [string]$Status,
    [hashtable]$Details = @{}
  )

  $authorization = Assert-RepairAuthorization -Authorization (Read-RepairAuthorization -Path $authorizationLastPath) -AllowConsumed
  $record = [ordered]@{}
  foreach ($property in $authorization.PSObject.Properties) {
    $record[$property.Name] = $property.Value
  }
  $record['result'] = $Status
  $record['result_at'] = [DateTimeOffset]::UtcNow.ToString('o')
  foreach ($entry in $Details.GetEnumerator()) {
    $record[$entry.Key] = $entry.Value
  }
  Write-JsonFileAtomically -Path $authorizationLastPath -Value $record
}

function Bind-ConsumedAuthorizationToCurrentMonitor {
  $authorization = Assert-RepairAuthorization -Authorization (Read-RepairAuthorization -Path $authorizationLastPath) -AllowConsumed
  $record = [ordered]@{}
  foreach ($property in $authorization.PSObject.Properties) {
    $record[$property.Name] = $property.Value
  }
  $monitorProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
  $record['monitor_pid'] = $PID
  $record['monitor_creation_date'] = ([DateTimeOffset]::new([datetime]$monitorProcess.CreationDate)).ToUniversalTime().ToString('o')
  $record['monitor_bound_at'] = [DateTimeOffset]::UtcNow.ToString('o')
  Write-JsonFileAtomically -Path $authorizationLastPath -Value $record
  return [pscustomobject]$record
}

function Read-InstallHandoff {
  if (-not (Test-Path -LiteralPath $installHandoffPath -PathType Leaf)) {
    throw "prepared install handoff is missing: $installHandoffPath"
  }
  try {
    return Get-Content -LiteralPath $installHandoffPath -Raw | ConvertFrom-Json -DateKind String
  } catch {
    throw "prepared install handoff is unreadable: $($_.Exception.Message)"
  }
}

function Write-InstallHandoffState {
  param(
    [Parameter(Mandatory)][string]$Status,
    [hashtable]$Details = @{}
  )

  $handoff = Read-InstallHandoff
  $record = [ordered]@{}
  foreach ($property in $handoff.PSObject.Properties) {
    $record[$property.Name] = $property.Value
  }
  $record['status'] = $Status
  $record['updated_at'] = [DateTimeOffset]::UtcNow.ToString('o')
  foreach ($entry in $Details.GetEnumerator()) {
    $record[$entry.Key] = $entry.Value
  }
  Write-JsonFileAtomically -Path $installHandoffPath -Value $record
  return [pscustomobject]$record
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

function Get-RequiredArchiveEntry {
  param(
    [Parameter(Mandatory)][object]$Archive,
    [Parameter(Mandatory)][string]$EntryPath
  )

  $normalized = $EntryPath.Replace('\', '/')
  $matches = @($Archive.Entries | Where-Object {
      [string]::Equals([string]$_.FullName, $normalized, [StringComparison]::OrdinalIgnoreCase)
    })
  if ($matches.Count -ne 1) {
    throw "MSIX must contain exactly one $normalized entry; found $($matches.Count)"
  }
  return $matches[0]
}

function Read-RequiredStreamBytes {
  param(
    [Parameter(Mandatory)][System.IO.Stream]$Stream,
    [Parameter(Mandatory)][int]$Count,
    [Parameter(Mandatory)][string]$Label
  )

  $bytes = New-Object byte[] $Count
  $offset = 0
  while ($offset -lt $Count) {
    $read = $Stream.Read($bytes, $offset, $Count - $offset)
    if ($read -le 0) {
      throw "could not read the complete $Label"
    }
    $offset += $read
  }
  return $bytes
}

function Get-PreparedMsixRuntimeContract {
  param([Parameter(Mandatory)][string]$Path)

  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $manifestEntry = Get-RequiredArchiveEntry -Archive $archive -EntryPath 'AppxManifest.xml'
    $manifestReader = [System.IO.StreamReader]::new($manifestEntry.Open())
    try {
      $manifest = [xml]$manifestReader.ReadToEnd()
    } finally {
      $manifestReader.Dispose()
    }

    $applications = @($manifest.Package.Applications.Application)
    $appMatches = @($applications | Where-Object { [string]$_.Id -eq 'App' })
    if ($appMatches.Count -eq 1) {
      $application = $appMatches[0]
    } elseif ($appMatches.Count -eq 0 -and $applications.Count -eq 1) {
      $application = $applications[0]
    } else {
      throw "MSIX manifest does not identify one Desktop application: App matches=$($appMatches.Count) applications=$($applications.Count)"
    }

    $relativeExecutable = ([string]$application.Executable).Replace('\', '/')
    $segments = @($relativeExecutable.Split('/') | Where-Object { $_ -ne '' })
    if ([string]::IsNullOrWhiteSpace($relativeExecutable) -or
        [System.IO.Path]::IsPathRooted($relativeExecutable) -or
        $relativeExecutable.StartsWith('/') -or
        $segments.Count -lt 2 -or
        @($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -ne 0) {
      throw "MSIX manifest Desktop executable path is unsafe: $relativeExecutable"
    }
    $executableEntry = Get-RequiredArchiveEntry -Archive $archive -EntryPath $relativeExecutable
    $appRoot = ($segments[0..($segments.Count - 2)] -join '/')
    $asarEntryPath = "$appRoot/resources/app.asar"
    $asarEntry = Get-RequiredArchiveEntry -Archive $archive -EntryPath $asarEntryPath

    $executableStream = $executableEntry.Open()
    $executableMemory = [System.IO.MemoryStream]::new()
    try {
      $executableStream.CopyTo($executableMemory)
      $executableText = [System.Text.Encoding]::ASCII.GetString($executableMemory.ToArray())
    } finally {
      $executableMemory.Dispose()
      $executableStream.Dispose()
    }
    $integrityPattern = '\[\{"file":"resources\\\\app\.asar","alg":"SHA256","value":"([0-9a-fA-F]{64})"\}\]'
    $integrityMatches = [regex]::Matches($executableText, $integrityPattern)
    if ($integrityMatches.Count -gt 1) {
      throw "manifest Desktop executable contains duplicate Electron app.asar integrity records: $relativeExecutable count=$($integrityMatches.Count)"
    }
    $embeddedHash = $null
    $integrityMode = 'none'
    if ($integrityMatches.Count -eq 1) {
      $embeddedHash = $integrityMatches[0].Groups[1].Value.ToLowerInvariant()
      $integrityMode = 'embedded-sha256'
    } elseif ($executableText -match '(?i)app\.asar') {
      throw "manifest Desktop executable references app.asar without a recognized Electron integrity record: $relativeExecutable"
    }

    $asarStream = $asarEntry.Open()
    try {
      $pickleHeader = Read-RequiredStreamBytes -Stream $asarStream -Count 16 -Label 'ASAR pickle header'
      $headerSize = [BitConverter]::ToUInt32($pickleHeader, 12)
      if ($headerSize -le 0 -or [long]$headerSize -gt ([long]$asarEntry.Length - 16L)) {
        throw "invalid packaged ASAR JSON header size: $headerSize"
      }
      $headerBytes = Read-RequiredStreamBytes -Stream $asarStream -Count ([int]$headerSize) -Label 'ASAR JSON header'
    } finally {
      $asarStream.Dispose()
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $headerHash = (($sha.ComputeHash($headerBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
      $sha.Dispose()
    }
    if ($embeddedHash -and $embeddedHash -ine $headerHash) {
      throw "packaged Desktop ASAR integrity mismatch: executable=$relativeExecutable embedded=$embeddedHash header=$headerHash"
    }
    return [pscustomobject]@{
      ExecutablePath = $relativeExecutable
      AsarPath = $asarEntryPath
      IntegrityMode = $integrityMode
      EmbeddedSha256 = $embeddedHash
      HeaderSha256 = $headerHash
    }
  } finally {
    $archive.Dispose()
  }
}

function Assert-PreparedInstallHandoff {
  param([Parameter(Mandatory)][object]$Authorization)

  $handoff = Read-InstallHandoff
  if ([int]$handoff.schema -ne 1 -or
      [string]$handoff.status -notin @('prepared', 'installing', 'failed-install', 'installed-awaiting-finalize')) {
    throw "prepared install handoff has no resumable state: $($handoff.status)"
  }
  if (-not [string]::Equals([string]$handoff.authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase) -or
      [version][string]$handoff.expected_version -ne $ExpectedUpdateVersion -or
      -not [string]::Equals([string]$handoff.expected_package_full_name, $ExpectedPackageFullName, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'prepared install handoff does not match the authorized package scope'
  }
  $expectedArtifactPath = Join-Path $installRequestRoot ('OpenAI.Codex_{0}_patched.msix' -f [string]$ExpectedUpdateVersion)
  $artifactPath = [System.IO.Path]::GetFullPath([string]$handoff.artifact_path)
  if (-not [string]::Equals($artifactPath, [System.IO.Path]::GetFullPath($expectedArtifactPath), [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "prepared MSIX path is missing or outside the authorization-derived recovery directory: $artifactPath"
  }
  $artifact = Get-Item -LiteralPath $artifactPath
  $artifactHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
  if ([long]$artifact.Length -ne [long]$handoff.artifact_length -or
      -not [string]::Equals($artifactHash, [string]$handoff.artifact_sha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'prepared MSIX length or SHA-256 changed after the handoff was published'
  }
  $signature = Get-AuthenticodeSignature -LiteralPath $artifactPath
  $identity = Get-MsixManifestIdentity -Path $artifactPath
  $runtimeContract = Get-PreparedMsixRuntimeContract -Path $artifactPath
  if ([string]$signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
      [string]$identity.Name -ne 'OpenAI.Codex' -or
      [version][string]$identity.Version -ne $ExpectedUpdateVersion -or
      [string]$identity.Architecture -ne 'x64' -or
      -not [string]::Equals([string]$identity.Name, [string]$handoff.manifest_name, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$identity.Publisher, [string]$handoff.manifest_publisher, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$signature.SignerCertificate.Subject, [string]$identity.Publisher, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$signature.SignerCertificate.Thumbprint, [string]$handoff.signer_thumbprint, [StringComparison]::OrdinalIgnoreCase) -or
      [string]$handoff.plugin_preflight -ne 'passed' -or
      -not [string]::Equals([string]$handoff.repair_script_sha256, [string]$Authorization.repair_script_sha256, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([string]$handoff.patch_script_sha256, [string]$Authorization.patch_script_sha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'prepared MSIX signature, signer, manifest identity, or producer hash is not authorized'
  }
  return [pscustomobject]@{
    Record = $handoff
    ArtifactPath = $artifactPath
    ArtifactSha256 = $artifactHash
    Signature = $signature
    Identity = $identity
    RuntimeContract = $runtimeContract
  }
}

function Stop-CodexPackageProcesses {
  param([object]$Package)

  if (-not $Package) {
    return
  }
  $installRoot = [System.IO.Path]::GetFullPath([string]$Package.InstallLocation).TrimEnd('\')
  foreach ($process in (Get-Process -Name 'Codex', 'ChatGPT' -ErrorAction SilentlyContinue)) {
    try {
      if ($process.Path -and $process.Path.StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-CycleLog "stopping exact Codex package process before independent install: pid=$($process.Id) path=$($process.Path)"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
      }
    } catch {
      continue
    }
  }
}

function Invoke-RemoveCodexAppxPackage {
  param([Parameter(Mandatory)][object]$Package)

  . (Join-Path $automationRoot 'codex-appdata-backup.ps1')
  $dataRoot = Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0'
  $backupRoot = Join-Path $installRequestRoot 'appdata-backup'
  Save-CodexAppDataBackup -DataRoot $dataRoot -BackupRoot $backupRoot -PackageFullName $Package.PackageFullName
  [void](Assert-CodexAppDataBackup $backupRoot)
  [void](Write-InstallHandoffState -Status 'installing' -Details @{appdata_backup=$backupRoot})
  Write-CycleLog 'package application data snapshot verified; removing exact current-user Store package'
  # PreserveApplicationData is supported only for loose-file development apps.
  # Store removal is permitted only after the mandatory data snapshot above.
  Remove-AppxPackage -Package $Package.PackageFullName -ErrorAction Stop
}

function Restore-PreparedPackageData {
  $backupRoot = Join-Path $installRequestRoot 'appdata-backup'
  if (Test-Path -LiteralPath $backupRoot) {
    . (Join-Path $automationRoot 'codex-appdata-backup.ps1')
    Restore-CodexAppDataBackup -DataRoot (Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0') -BackupRoot $backupRoot
    Write-CycleLog 'package application data restored and hashes verified; recovery snapshot retained'
  }
}

function Get-ArchiveSignatureHash {
  param([string]$Path)
  $archive = [IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.GetEntry('AppxSignature.p7x')
    if (-not $entry) { throw 'official recovery package has no AppxSignature.p7x' }
    $stream = $entry.Open()
    try { return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash } finally { $stream.Dispose() }
  } finally { $archive.Dispose() }
}

function Assert-StoreRecoveryArtifact {
  $record = Read-InstallHandoff
  if (-not $record -or -not $record.PSObject.Properties['store_recovery_path']) {
    throw 'no verified official Store recovery artifact is recorded; package replacement is disabled'
  }
  $path = Join-Path $installRequestRoot 'official-store.msix'
  if ([string]$record.store_recovery_path -ne $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw 'official Store recovery artifact path is missing or changed'
  }
  $signature = Get-AuthenticodeSignature -LiteralPath $path
  $identity = Get-MsixManifestIdentity -Path $path
  if ($signature.Status -ne 'Valid' -or
      (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string]$record.store_recovery_sha256 -or
      (Get-ArchiveSignatureHash $path) -ne [string]$record.store_signature_sha256 -or
      $identity.Name -ne 'OpenAI.Codex' -or [version]$identity.Version -ne $ExpectedUpdateVersion -or
      $identity.Architecture -ne 'x64' -or
      $identity.Publisher -ne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B') {
    throw 'official Store recovery artifact identity, signature or content verification failed'
  }
  return $path
}

function Save-StoreRecoveryArtifact {
  param([Parameter(Mandatory)][object]$Package)
  # Accept only a signed original MSIX whose embedded signature is byte-identical
  # to this registered Store build. An extracted folder or re-signed copy is not
  # an official recovery package. The user explicitly waived mandatory recovery
  # media on 2026-09-24; its absence must not block a validated patch install.
  $source = Join-Path $automationRoot "store-recovery\$ExpectedUpdateVersion\original.msix"
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    Write-CycleLog 'official recovery MSIX is unavailable; continuing under the user-approved optional-recovery policy'
    return $false
  }
  if ([string]$Package.SignatureKind -ne 'Store' -or -not (Test-ExpectedPackage $Package) -or -not (Test-CompletePackage $Package)) {
    throw 'cannot establish recovery identity from an unexpected Store package'
  }
  $signaturePath = Join-Path $Package.InstallLocation 'AppxSignature.p7x'
  $expectedSignatureHash = (Get-FileHash -LiteralPath $signaturePath -Algorithm SHA256).Hash
  $sourceLock = [IO.File]::Open($source, 'Open', 'Read', 'Read')
  try {
    if ((Get-AuthenticodeSignature -LiteralPath $source).Status -ne 'Valid' -or
        (Get-ArchiveSignatureHash $source) -ne $expectedSignatureHash) {
      throw 'STORE_PRESERVED: recovery file is not the signed original for the installed Store build'
    }
    $destination = Join-Path $installRequestRoot 'official-store.msix'
    Copy-Item -LiteralPath $source -Destination $destination
    [void](Write-InstallHandoffState -Status 'prepared' -Details @{
      store_recovery_path = $destination
      store_recovery_sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
      store_signature_sha256 = $expectedSignatureHash
    })
  } finally { $sourceLock.Dispose() }
  [void](Assert-StoreRecoveryArtifact)
  Write-CycleLog 'official Store recovery MSIX verified against the registered Store signature; rollback is available'
  return $true
}

function Open-CliAfterRepairFailure {
  param([string]$Reason)
  if ($script:cliFallbackOpened) { return $true }
  try {
    . (Join-Path $automationRoot 'start-codex-cli-fallback.ps1')
    $terminal = Start-CodexCliFallbackTerminal -PwshPath $RepairPwshPath -Reason $Reason -LogPath $logPath
    $script:cliFallbackOpened = $true
    $details = @{ repair_failure=$Reason; cli_terminal_pid=$terminal.TerminalId; cli_path=$terminal.CliPath; cleanup='retained-for-diagnosis' }
    Write-CycleState -Status 'repair-failed-cli-opened' -Details $details
    if (Test-Path -LiteralPath $installHandoffPath -PathType Leaf) {
      [void](Write-InstallHandoffState -Status 'repair-failed-cli-opened' -Details $details)
    }
    Write-CycleLog "interactive Codex CLI fallback terminal opened: pid=$($terminal.TerminalId) path=$($terminal.CliPath); failed build and logs retained"
    return $true
  } catch {
    $fallbackError = $_.Exception.Message
    Write-CycleLog "Codex CLI fallback could not open: $fallbackError"
    Write-CycleState -Status 'cli-fallback-failed' -Details @{ repair_failure=$Reason; fallback_error=$fallbackError; cleanup='retained-for-diagnosis' }
    if (Test-Path -LiteralPath $installHandoffPath -PathType Leaf) {
      [void](Write-InstallHandoffState -Status 'cli-fallback-failed' -Details @{ fallback_error=$fallbackError })
    }
    return $false
  }
}
function Invoke-AddCodexAppxPackage {
  param([Parameter(Mandatory)][string]$Path)

  Add-AppxPackage -Path $Path -ErrorAction Stop
}

function Invoke-ElevatedCodexAppxPackage {
  param([Parameter(Mandatory)][object]$Prepared)

  # Pass data separately from code, and pin the exact validated artifact across UAC.
  $request = @{
    path = $Prepared.ArtifactPath
    hash = $Prepared.ArtifactSha256
    thumbprint = $Prepared.Signature.SignerCertificate.Thumbprint
    user_sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  } | ConvertTo-Json -Compress
  $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
  $command = @'
$ErrorActionPreference = 'Stop'
try {
  $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
  if ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $request.user_sid) { throw 'Administrator must be the same Windows user' }
  # Hold a read lock so the checked package cannot be replaced before deployment.
  $stream = [IO.File]::Open($request.path, 'Open', 'Read', 'Read')
  try {
    if ((Get-FileHash -InputStream $stream -Algorithm SHA256).Hash -ne $request.hash) { throw 'Prepared package hash changed' }
    $signature = Get-AuthenticodeSignature -LiteralPath $request.path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $request.thumbprint) { throw 'Prepared package signature changed' }
    Add-AppxPackage -Path $request.path -ErrorAction Stop
  } finally { $stream.Dispose() }
  exit 0
} catch { exit 1 }
'@
  $command = $command.Replace('__PAYLOAD__', $payload)
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  Write-CycleLog 'requesting UAC for exact validated MSIX installation only; watcher remains unelevated'
  try {
    $process = Start-Process -FilePath $RepairPwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
  } catch {
    throw "administrator installation was cancelled or could not start; recovery artifact retained: $($_.Exception.Message)"
  }
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    throw "administrator installation failed (exit=$($process.ExitCode)); recovery artifact retained; see Windows AppXDeploymentServer event log"
  }
}

function Install-PreparedCodexPackage {
  param([Parameter(Mandatory)][object]$Authorization)

  $prepared = Assert-PreparedInstallHandoff -Authorization $Authorization
  . (Join-Path $automationRoot 'start-codex-cli-fallback.ps1')
  [void](Get-VerifiedFallbackCli)
  $currentPackage = Get-CodexPackage
  if ($currentPackage -and
      [string]$prepared.Record.status -in @('installing', 'failed-install', 'installed-awaiting-finalize') -and
      (Test-ExpectedPackage -Package $currentPackage) -and
      (Test-CompletePackage -Package $currentPackage) -and
      [string]$currentPackage.SignatureKind -eq 'Developer') {
    Write-CycleLog 'exact Developer package is already installed; resuming at post-install finalization'
    Restore-PreparedPackageData
    [void](Write-InstallHandoffState -Status 'installed-awaiting-finalize' -Details @{
        installed_at = [DateTimeOffset]::UtcNow.ToString('o')
        recovery_action = 'already-installed-exact-artifact'
      })
    return $currentPackage
  }

  if ($currentPackage) {
    if (-not (Test-ExpectedPackage -Package $currentPackage) -or
        -not (Test-CompletePackage -Package $currentPackage) -or
        [string]$currentPackage.SignatureKind -ne 'Store') {
      throw "refusing to replace an unexpected package: version=$($currentPackage.Version) signature=$($currentPackage.SignatureKind) package=$($currentPackage.PackageFullName)"
    }
    # Best-effort recovery media is separate from mandatory patched-artifact
    # identity, hash, signature, producer and runtime-contract validation.
    try { [void](Save-StoreRecoveryArtifact -Package $currentPackage) }
    catch { Write-CycleLog "optional Store recovery artifact unavailable or invalid; not usable for rollback: $($_.Exception.Message)" }
    [void](Write-InstallHandoffState -Status 'installing' -Details @{
        install_started_at = [DateTimeOffset]::UtcNow.ToString('o')
        artifact_sha256 = $prepared.ArtifactSha256
      })
    Stop-CodexPackageProcesses -Package $currentPackage
    $prepared = Assert-PreparedInstallHandoff -Authorization $Authorization
    Write-CycleLog "removing exact authorized Store package: $($currentPackage.PackageFullName)"
    Invoke-RemoveCodexAppxPackage -Package $currentPackage
  } else {
    Write-CycleLog 'Codex package is absent; resuming installation from the validated prepared artifact'
    [void](Write-InstallHandoffState -Status 'installing' -Details @{
        install_resumed_at = [DateTimeOffset]::UtcNow.ToString('o')
        artifact_sha256 = $prepared.ArtifactSha256
      })
  }

  $lastInstallError = $null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $prepared = Assert-PreparedInstallHandoff -Authorization $Authorization
      Write-CycleLog "installing validated prepared MSIX: attempt=$attempt path=$($prepared.ArtifactPath)"
      Invoke-AddCodexAppxPackage -Path $prepared.ArtifactPath
      $lastInstallError = $null
      break
    } catch {
      $lastInstallError = $_
      Write-CycleLog "prepared MSIX install attempt failed: attempt=$attempt error=$($_.Exception.Message)"
      if ($_.ToString() -match '(?i)0x80073D28') {
        # One UAC request only. Cancellation must not trigger another prompt.
        try {
          $prepared = Assert-PreparedInstallHandoff -Authorization $Authorization
          Invoke-ElevatedCodexAppxPackage -Prepared $prepared
          $lastInstallError = $null
        } catch {
          $lastInstallError = $_
        }
        break
      }
      if ($attempt -lt 3) {
        Start-Sleep -Seconds 2
      }
    }
  }
  if ($lastInstallError) {
    [void](Write-InstallHandoffState -Status 'failed-install' -Details @{
        failed_at = [DateTimeOffset]::UtcNow.ToString('o')
        install_error = ($lastInstallError.Exception.Message -replace '[\r\n]+', ' ').Trim()
      })
    throw "validated prepared MSIX could not be installed: $($lastInstallError.Exception.Message)"
  }

  $installed = Get-CodexPackage
  if (-not (Test-ExpectedPackage -Package $installed) -or
      -not (Test-CompletePackage -Package $installed) -or
      [string]$installed.SignatureKind -ne 'Developer') {
    [void](Write-InstallHandoffState -Status 'failed-install' -Details @{
        failed_at = [DateTimeOffset]::UtcNow.ToString('o')
        install_error = 'Add-AppxPackage returned without the exact complete Developer package'
      })
    throw "prepared MSIX install did not produce the exact Developer package: version=$($installed.Version) signature=$($installed.SignatureKind) package=$($installed.PackageFullName)"
  }
  Restore-PreparedPackageData
  [void](Write-InstallHandoffState -Status 'installed-awaiting-finalize' -Details @{
      installed_at = [DateTimeOffset]::UtcNow.ToString('o')
      recovery_action = if ($currentPackage) { 'installed-exact-artifact' } else { 'recovered-exact-artifact' }
    })
  Write-CycleLog "exact Developer package installed independently: $($installed.PackageFullName)"
  return $installed
}

function Invoke-OneClickRepair {
  param([Parameter(Mandatory)][ValidateSet('Prepare', 'Finalize')][string]$Phase)

  $phaseLabel = $Phase.ToLowerInvariant()
  $repairStdoutPath = Join-Path $logRoot "update-cycle-$runStamp-$PID-repair-$phaseLabel.stdout.log"
  $repairStderrPath = Join-Path $logRoot "update-cycle-$runStamp-$PID-repair-$phaseLabel.stderr.log"
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $RepairPwshPath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $arguments = @(
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', $RepairScriptPath,
      '-Force',
      '-Launch',
      '-AllowVisibleAppRepair',
      '-OneClickAuthorized',
      '-ExpectedVersion', [string]$ExpectedUpdateVersion,
      '-ExpectedPackageFullName', $ExpectedPackageFullName,
      '-AuthorizationId', $AuthorizationId.ToLowerInvariant()
    )
  if ($Phase -eq 'Prepare') {
    $arguments += @('-PrepareExternalInstall', '-OutputRoot', (Join-Path $installRequestRoot 'build'))
  } else {
    $arguments += '-PostInstallOnly'
  }
  foreach ($argument in $arguments) {
    [void]$startInfo.ArgumentList.Add($argument)
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $stdoutStream = [System.IO.FileStream]::new($repairStdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 1, [System.IO.FileOptions]::WriteThrough)
  $stderrStream = [System.IO.FileStream]::new($repairStderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 1, [System.IO.FileOptions]::WriteThrough)
  Write-UpdateProgress @{ kind='follow'; paths=@($repairStdoutPath, $repairStderrPath) }
  Write-CycleLog "starting authorized scoped repair phase=$Phase engine=$RepairPwshPath script=$RepairScriptPath"
  try {
    if (-not $process.Start()) {
      throw 'failed to start the authorized scoped repair process'
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
  Write-CycleLog "authorized scoped repair phase=$Phase exited: code=$exitCode stdout=$repairStdoutPath stderr=$repairStderrPath"
  return $exitCode
}

function Get-VerifiedRepairState {
  param([DateTimeOffset]$ConsumedAt)

  if (-not (Test-Path -LiteralPath $repairStatePath -PathType Leaf)) {
    throw "repair state is missing after the repair process: $repairStatePath"
  }
  $state = Get-Content -LiteralPath $repairStatePath -Raw | ConvertFrom-Json -DateKind String
  if ([string]$state.last_status -ne 'success' -or
      [version][string]$state.last_successful_version -ne $ExpectedUpdateVersion -or
      -not [string]::Equals([string]$state.last_successful_package_full_name, $ExpectedPackageFullName, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([string]$state.one_click_authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'repair process did not persist an exact successful one-click result'
  }
  $successAt = [DateTimeOffset]::Parse([string]$state.last_success_at)
  if ($successAt.ToUniversalTime() -lt $ConsumedAt.ToUniversalTime()) {
    throw 'repair success state predates the consumed one-click authorization'
  }
  return $state
}

function Complete-PreparedOneClickRepair {
  param(
    [Parameter(Mandatory)][object]$Authorization,
    [Parameter(Mandatory)][DateTimeOffset]$ConsumedAt,
    [Parameter(Mandatory)][hashtable]$PackageDetails
  )

  try {
    $installedPackage = Install-PreparedCodexPackage -Authorization $Authorization
    $handoffAfterInstall = Read-InstallHandoff
    $PackageDetails['install_finished_at'] = [DateTimeOffset]::UtcNow.ToString('o')
    $PackageDetails['install_artifact_sha256'] = [string]$handoffAfterInstall.artifact_sha256
    $PackageDetails['recovery_action'] = [string]$handoffAfterInstall.recovery_action
    Write-CycleState -Status 'installed-awaiting-finalize' -Details $PackageDetails
  } catch {
    $failureMessage = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    $PackageDetails['repair_error'] = $failureMessage
    $PackageDetails['repair_exit_code'] = -1
    Write-CycleState -Status 'failed-install' -Details $PackageDetails
    Update-ConsumedAuthorization -Status 'repair-failed' -Details @{ error = $failureMessage; repair_exit_code = -1 }
    Write-CycleLog "independent exact-artifact install failed: $failureMessage"
    [void](Open-CliAfterRepairFailure -Reason 'independent-install-failed')
    return 7
  }

  try {
    if (-not (Test-Path -LiteralPath $RepairScriptPath -PathType Leaf) -or
        -not [string]::Equals([string]$Authorization.repair_script_sha256, (Get-FileHash -LiteralPath $RepairScriptPath -Algorithm SHA256).Hash, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'post-install finalization script no longer matches the consumed authorization'
    }
    $repairExitCode = Invoke-OneClickRepair -Phase Finalize
  } catch {
    $failureMessage = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    $PackageDetails['repair_error'] = $failureMessage
    $PackageDetails['repair_exit_code'] = -1
    Write-CycleState -Status 'failed-finalize' -Details $PackageDetails
    Update-ConsumedAuthorization -Status 'repair-failed' -Details @{ error = $failureMessage; repair_exit_code = -1 }
    Write-CycleLog "authorized post-install finalization failed to execute: $failureMessage"
    [void](Open-CliAfterRepairFailure -Reason 'finalize-execution-failed')
    return 8
  }
  $PackageDetails['repair_finished_at'] = [DateTimeOffset]::UtcNow.ToString('o')
  $PackageDetails['repair_exit_code'] = $repairExitCode
  if ($repairExitCode -ne 0) {
    Write-CycleState -Status 'failed-finalize' -Details $PackageDetails
    Update-ConsumedAuthorization -Status 'repair-failed' -Details @{ repair_exit_code = $repairExitCode }
    [void](Open-CliAfterRepairFailure -Reason 'finalize-returned-nonzero')
    return 8
  }

  try {
    [void](Get-VerifiedRepairState -ConsumedAt $ConsumedAt)
    $patchedPackage = Get-CodexPackage
    if (-not (Test-ExpectedPackage -Package $patchedPackage) -or
        -not (Test-CompletePackage -Package $patchedPackage) -or
        [string]$patchedPackage.SignatureKind -ne 'Developer') {
      throw "final package is not the authorized Developer package: version=$($patchedPackage.Version) signature=$($patchedPackage.SignatureKind) package=$($patchedPackage.PackageFullName)"
    }
  } catch {
    $failureMessage = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    $PackageDetails['repair_error'] = $failureMessage
    Write-CycleState -Status 'failed-finalize' -Details $PackageDetails
    Update-ConsumedAuthorization -Status 'repair-failed' -Details @{ error = $failureMessage; repair_exit_code = $repairExitCode }
    Write-CycleLog "authorized repair result verification failed: $failureMessage"
    [void](Open-CliAfterRepairFailure -Reason 'finalize-result-verification-failed')
    return 8
  }

  $PackageDetails['final_signature'] = 'Developer'
  Write-CycleState -Status 'repair-process-succeeded' -Details $PackageDetails
  $restartKey = ''
  $restartStableSince = [DateTimeOffset]::MinValue
  $finalDeadline = [DateTimeOffset]::UtcNow.AddMinutes($FinalProcessTimeoutMinutes)
  while ([DateTimeOffset]::UtcNow -lt $finalDeadline) {
    $currentPackage = Get-CodexPackage
    $mainProcess = Get-CodexMainProcess -Package $currentPackage
    if ((Test-ExpectedPackage -Package $currentPackage) -and
        (Test-CompletePackage -Package $currentPackage) -and
        [string]$currentPackage.SignatureKind -eq 'Developer' -and
        $mainProcess -and
        (Test-CodexMainWindowReady -Process $mainProcess)) {
      $candidateRestartKey = Get-ProcessIdentityKey -Process $mainProcess
      if ($candidateRestartKey -ne $restartKey) {
        $restartKey = $candidateRestartKey
        $restartStableSince = [DateTimeOffset]::UtcNow
        $newProcessCreationDate = Get-ProcessCreationInstant -Process $mainProcess
        $PackageDetails['new_main_process_id'] = [int]$mainProcess.ProcessId
        $PackageDetails['new_main_process_creation_date'] = $newProcessCreationDate.ToString('o')
        $PackageDetails['new_main_process_path'] = [string]$mainProcess.ExecutablePath
        Write-CycleLog "patched Developer process detected: pid=$($mainProcess.ProcessId) creation=$($newProcessCreationDate.ToString('o')) path=$($mainProcess.ExecutablePath)"
        Write-CycleState -Status 'patched-process-detected' -Details $PackageDetails
      } elseif (([DateTimeOffset]::UtcNow - $restartStableSince).TotalSeconds -ge $StableRestartSeconds) {
        $PackageDetails['stable_restart_seconds'] = $StableRestartSeconds
        Write-CycleLog "one-click update completed: version=$($currentPackage.Version) signature=$($currentPackage.SignatureKind) pid=$($mainProcess.ProcessId)"
        Write-CycleState -Status 'repair-restart-stable' -Details $PackageDetails
        Update-ConsumedAuthorization -Status 'success' -Details @{
          repair_exit_code = $repairExitCode
          final_signature = 'Developer'
          final_process_id = [int]$mainProcess.ProcessId
          recovery_action = [string]$PackageDetails['recovery_action']
        }
        [void](Write-InstallHandoffState -Status 'completed' -Details @{
            completed_at = [DateTimeOffset]::UtcNow.ToString('o')
            final_process_id = [int]$mainProcess.ProcessId
          })
        try {
          Move-Item -LiteralPath $installHandoffPath -Destination $installHandoffLastPath -Force
        } catch {
          Write-CycleLog "warning: completed handoff archival failed: $($_.Exception.Message)"
        }
        try {
          Write-UpdateProgress @{ kind='stage'; text='启动检查通过，核对本轮清理清单' }
          . (Join-Path $automationRoot 'codex-update-cleanup.ps1')
          $cleaned = Invoke-VerifiedUpdateCleanup -RequestRoot $installRequestRoot -AuthorizationId $AuthorizationId -CycleStatePath $statePath
          $PackageDetails['cleanup'] = 'completed'
          $PackageDetails['cleanup_files'] = $cleaned.Files
          $PackageDetails['cleanup_bytes'] = $cleaned.Bytes
          Write-CycleLog "cleanup completed: files=$($cleaned.Files) bytes=$($cleaned.Bytes); official recovery MSIX, signed patched MSIX, logs and user data retained"
        } catch {
          $PackageDetails['cleanup'] = 'deferred'
          $PackageDetails['cleanup_error'] = $_.Exception.Message
          Write-CycleLog "cleanup deferred; Desktop remains successfully repaired: $($_.Exception.Message)"
        }
        Write-CycleState -Status 'repair-restart-stable' -Details $PackageDetails
        return 0
      }
    } else {
      $restartKey = ''
      $restartStableSince = [DateTimeOffset]::MinValue
    }
    Start-Sleep -Seconds 1
  }

  Write-CycleLog 'timed out waiting for the authorized patched Developer process to become stable'
  Write-CycleState -Status 'timed-out-before-patched-restart' -Details $PackageDetails
  Update-ConsumedAuthorization -Status 'repair-failed' -Details @{ error = 'timed out waiting for patched Developer process'; repair_exit_code = $repairExitCode }
  [void](Open-CliAfterRepairFailure -Reason 'terminal-window-stability-timeout')
  return 9
}

function Invoke-CodexUpdateMonitor {
  if ($RepairCurrentStorePackage) {
    if ($ExpectedUpdateVersion -ne $BaselineVersion -or
        -not [string]::Equals($ExpectedPackageFullName, $BaselinePackageFullName, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'current Store package recovery requires the expected and baseline package identities to match exactly'
    }
  } elseif ($ExpectedUpdateVersion -le $BaselineVersion) {
    throw "expected update version must be greater than baseline: baseline=$BaselineVersion expected=$ExpectedUpdateVersion"
  }

  [void](Assert-ExternalDesktopRepairContext)
  if (Test-Path -LiteralPath $installHandoffPath -PathType Leaf) {
    $resumeRecord = Read-InstallHandoff
    if ([string]$resumeRecord.status -in @('prepared', 'installing', 'failed-install', 'installed-awaiting-finalize')) {
      $consumedAuthorization = Assert-RepairAuthorization -Authorization (Read-RepairAuthorization -Path $authorizationLastPath) -AllowConsumed
      Start-UpdateProgressWindow
      [void](Assert-PreparedInstallHandoff -Authorization $consumedAuthorization)
      $consumedAuthorization = Bind-ConsumedAuthorizationToCurrentMonitor
      $script:repairBegan = $true
      [void](Write-InstallHandoffState -Status ([string]$resumeRecord.status) -Details @{
          monitor_pid = $PID
          monitor_creation_date = [string]$consumedAuthorization.monitor_creation_date
          resumed_at = [DateTimeOffset]::UtcNow.ToString('o')
        })
      $consumedAt = [DateTimeOffset]::Parse([string]$consumedAuthorization.consumed_at)
      $resumeDetails = @{
        authorization_scope = [string]$consumedAuthorization.scope
        authorization_granted_at = [string]$consumedAuthorization.granted_at
        authorization_expires_at = [string]$consumedAuthorization.expires_at
        authorization_consumed_at = $consumedAt.ToString('o')
        repair_engine_path = $RepairPwshPath
        repair_script_path = $RepairScriptPath
        resumed_handoff_status = [string]$resumeRecord.status
      }
      Write-CycleLog "resuming validated two-stage install before baseline checks: status=$($resumeRecord.status)"
      Write-CycleState -Status 'resuming-prepared-install' -Details $resumeDetails
      return Complete-PreparedOneClickRepair -Authorization $consumedAuthorization -ConsumedAt $consumedAt -PackageDetails $resumeDetails
    }
  }

  $authorization = Assert-RepairAuthorization -Authorization (Read-RepairAuthorization)
  Start-UpdateProgressWindow
  $authorizationExpiresAt = [DateTimeOffset]::Parse([string]$authorization.expires_at).ToUniversalTime()
  $baselinePackage = Get-CodexPackage
  if (-not $baselinePackage) {
    throw 'OpenAI.Codex is not installed for the monitor user at startup'
  }
  if ([version][string]$baselinePackage.Version -ne $BaselineVersion -or
      -not [string]::Equals(
        [string]$baselinePackage.PackageFullName,
        $BaselinePackageFullName,
        [StringComparison]::OrdinalIgnoreCase
      )) {
    throw "baseline package no longer matches: version=$($baselinePackage.Version) package=$($baselinePackage.PackageFullName)"
  }

  $manifestBaselinePath = Get-CodexManifestMainExecutablePath -Package $baselinePackage
  $normalizedBaselinePath = [System.IO.Path]::GetFullPath($BaselineMainProcessPath)
  if ([string]::IsNullOrWhiteSpace($manifestBaselinePath) -or
      -not [string]::Equals(
        $manifestBaselinePath,
        $normalizedBaselinePath,
        [StringComparison]::OrdinalIgnoreCase
      )) {
    throw "baseline main process path does not match AppxManifest.xml: supplied=$normalizedBaselinePath manifest=$manifestBaselinePath"
  }

  $baselineIdentity = @{
    ProcessId = $BaselineMainProcessId
    CreationDate = $BaselineMainProcessCreationDate
    ExactPath = $normalizedBaselinePath
  }
  $baselineProcess = Get-ProcessByIdentity @baselineIdentity
  if (-not $baselineProcess -or
      [string]::IsNullOrWhiteSpace([string]$baselineProcess.CommandLine) -or
      $baselineProcess.CommandLine -match '(?i)(?:^|\s)--type(?:=|\s)') {
    throw "baseline Codex main process identity is not running: pid=$BaselineMainProcessId creation=$($BaselineMainProcessCreationDate.ToString('o')) path=$normalizedBaselinePath"
  }

  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  $timeoutSeconds = [double]($TimeoutMinutes * 60)
  $authorizationDetails = @{
    authorization_scope = [string]$authorization.scope
    authorization_granted_at = [string]$authorization.granted_at
    authorization_expires_at = [string]$authorization.expires_at
    repair_engine_path = $RepairPwshPath
    repair_script_path = $RepairScriptPath
  }
  Write-CycleLog "armed one-click update: authorization=$AuthorizationId baselineVersion=$BaselineVersion expectedVersion=$ExpectedUpdateVersion expectedPackage=$ExpectedPackageFullName baselinePid=$BaselineMainProcessId"
  Write-CycleState -Status 'armed' -Details $authorizationDetails

  while ($clock.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    if ([DateTimeOffset]::UtcNow -ge $authorizationExpiresAt) {
      Write-CycleLog "authorization expired before the update began: $($authorizationExpiresAt.ToString('o'))"
      Write-CycleState -Status 'authorization-expired' -Details $authorizationDetails
      return 2
    }
    if (-not (Get-ProcessByIdentity @baselineIdentity)) {
      Write-CycleLog "baseline main process exited: pid=$BaselineMainProcessId"
      Write-CycleState -Status 'baseline-process-exited' -Details $authorizationDetails
      break
    }
    Start-Sleep -Seconds 1
  }
  if (Get-ProcessByIdentity @baselineIdentity) {
    Write-CycleLog 'timed out waiting for the baseline main process identity to exit'
    Write-CycleState -Status 'timed-out-before-exit' -Details $authorizationDetails
    return 3
  }

  $stableKey = ''
  $stableSinceSeconds = [double]::NaN
  $updatedPackage = $null
  while ($clock.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    if ([DateTimeOffset]::UtcNow -ge $authorizationExpiresAt) {
      Write-CycleLog "authorization expired before the exact updated package became stable: $($authorizationExpiresAt.ToString('o'))"
      Write-CycleState -Status 'authorization-expired' -Details $authorizationDetails
      return 4
    }
    $candidate = Get-CodexPackage
    if ((Test-ExpectedPackage -Package $candidate) -and
        (Test-CompletePackage -Package $candidate) -and
        [string]$candidate.SignatureKind -eq 'Store') {
      $candidateKey = '{0}|{1}|{2}|{3}' -f (
        [string]$candidate.Version,
        [string]$candidate.PackageFullName,
        [string]$candidate.SignatureKind,
        [string]$candidate.InstallLocation
      )
      if ($candidateKey -ne $stableKey) {
        $stableKey = $candidateKey
        $stableSinceSeconds = $clock.Elapsed.TotalSeconds
        Write-CycleLog "exact update candidate detected: $candidateKey"
      } elseif (($clock.Elapsed.TotalSeconds - $stableSinceSeconds) -ge $StablePackageSeconds) {
        $updatedPackage = $candidate
        break
      }
    } else {
      $stableKey = ''
      $stableSinceSeconds = [double]::NaN
    }
    Start-Sleep -Seconds 1
  }

  if (-not $updatedPackage) {
    Write-CycleLog "timed out waiting for complete exact Codex package $ExpectedPackageFullName"
    Write-CycleState -Status 'timed-out-before-package-change' -Details $authorizationDetails
    return 5
  }

  $packageDetails = @{
    authorization_scope = [string]$authorization.scope
    authorization_granted_at = [string]$authorization.granted_at
    authorization_expires_at = [string]$authorization.expires_at
    repair_engine_path = $RepairPwshPath
    repair_script_path = $RepairScriptPath
    detected_version = [string]$updatedPackage.Version
    detected_package_full_name = [string]$updatedPackage.PackageFullName
    detected_signature = [string]$updatedPackage.SignatureKind
    detected_install_location = [string]$updatedPackage.InstallLocation
  }
  Write-CycleState -Status 'updated-package-detected' -Details $packageDetails

  $consumedAuthorization = Consume-RepairAuthorization
  $script:repairBegan = $true
  $consumedAt = [DateTimeOffset]::Parse([string]$consumedAuthorization.consumed_at)
  $packageDetails['authorization_consumed_at'] = $consumedAt.ToString('o')
  $packageDetails['repair_started_at'] = [DateTimeOffset]::UtcNow.ToString('o')
  Write-CycleState -Status 'prepare-running' -Details $packageDetails

  try {
    $prepareExitCode = Invoke-OneClickRepair -Phase Prepare
  } catch {
    $failureMessage = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    $packageDetails['repair_finished_at'] = [DateTimeOffset]::UtcNow.ToString('o')
    $packageDetails['repair_exit_code'] = -1
    $packageDetails['repair_error'] = $failureMessage
    Write-CycleState -Status 'failed-prepare' -Details $packageDetails
    Update-ConsumedAuthorization -Status 'repair-failed' -Details @{ error = $failureMessage; repair_exit_code = -1 }
    Write-CycleLog "authorized scoped repair failed to execute: $failureMessage"
    [void](Open-CliAfterRepairFailure -Reason 'prepare-execution-failed')
    return 6
  }

  $packageDetails['prepare_finished_at'] = [DateTimeOffset]::UtcNow.ToString('o')
  $packageDetails['prepare_exit_code'] = $prepareExitCode
  if ($prepareExitCode -ne 0) {
    Write-CycleState -Status 'failed-prepare' -Details $packageDetails
    Update-ConsumedAuthorization -Status 'repair-failed' -Details @{ repair_exit_code = $prepareExitCode; phase = 'prepare' }
    [void](Open-CliAfterRepairFailure -Reason 'prepare-returned-nonzero')
    return 7
  }

  try {
    $prepared = Assert-PreparedInstallHandoff -Authorization $consumedAuthorization
    $packageDetails['install_artifact_path'] = $prepared.ArtifactPath
    $packageDetails['install_artifact_sha256'] = $prepared.ArtifactSha256
    . (Join-Path $automationRoot 'codex-update-cleanup.ps1')
    $cleanupCount = Save-UpdateCleanupManifest -RequestRoot $installRequestRoot -AuthorizationId $AuthorizationId
    Write-CycleLog "cleanup planned for $cleanupCount build files after stable restart; recovery artifacts and logs excluded"
    Write-CycleState -Status 'prepared-install-validated' -Details $packageDetails
  } catch {
    $failureMessage = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    $packageDetails['repair_error'] = $failureMessage
    try {
      [void](Write-InstallHandoffState -Status 'failed-validation' -Details @{
          failed_at = [DateTimeOffset]::UtcNow.ToString('o')
          validation_error = $failureMessage
        })
    } catch {
      Write-CycleLog "warning: could not persist failed-validation handoff state: $($_.Exception.Message)"
    }
    Write-CycleState -Status 'failed-validation' -Details $packageDetails
    Update-ConsumedAuthorization -Status 'repair-failed' -Details @{ error = $failureMessage; repair_exit_code = $prepareExitCode; phase = 'handoff-validation' }
    Write-CycleLog "prepared install validation failed before package removal: $failureMessage"
    [void](Open-CliAfterRepairFailure -Reason 'handoff-validation-failed-before-removal')
    return 8
  }
  return Complete-PreparedOneClickRepair -Authorization $consumedAuthorization -ConsumedAt $consumedAt -PackageDetails $packageDetails
}

function Test-MonitorHasCurrentRecord {
  # A superseded logon task must not overwrite the newer monitor's state or
  # launch Desktop. Matching records still undergo all normal authorization,
  # expiry, scheduler, artifact and process-lineage checks below.
  foreach ($recordPath in @($authorizationPath, $authorizationLastPath)) {
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
      $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
      if ([string]::Equals([string]$record.authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    }
  }
  return (Test-Path -LiteralPath $installHandoffPath -PathType Leaf)
}

if (-not (Test-MonitorHasCurrentRecord)) {
  New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
  Write-CycleLog 'ignored superseded one-click task: no matching authorization or pending install handoff; shared state and Desktop left unchanged'
  exit 0
}

$lockStream = $null
$lockAcquired = $false
$exitCode = 1
try {
  New-Item -ItemType Directory -Force -Path $automationRoot, $logRoot | Out-Null
  $lockStream = [System.IO.FileStream]::new(
    $lockPath,
    [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )
  $lockAcquired = $true
  $exitCode = Invoke-CodexUpdateMonitor
} catch {
  $failureMessage = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
  try {
    Write-CycleLog "failed: $failureMessage"
  } catch {
    # The task exit code remains authoritative if even the run-specific log is unavailable.
  }
  if ($lockStream) {
    try {
      Write-CycleState -Status 'failed' -Details @{ error = $failureMessage }
    } catch {
      # Do not hide the original failure when the shared state path is also unavailable.
    }
  }
  if ($lockAcquired) {
    Set-UnconsumedAuthorizationFailure -FailureMessage $failureMessage
  }
  if ($script:repairBegan) {
    [void](Open-CliAfterRepairFailure -Reason 'watcher-top-level-failure')
  } else {
    [void](Ensure-ExpectedCodexDesktopRunning -Reason 'watcher-top-level-failure')
  }
  $exitCode = 1
} finally {
  Write-UpdateProgress @{ kind='done'; exit_code=$exitCode; text=$(if ($exitCode -eq 0) { '更新流程已结束。请以以上启动检查和清理结果为准。' } else { "重补丁未完成（退出码 $exitCode）。请查看上方 Codex CLI 启动结果；失败文件与日志未清理。" }) }
  if ($lockStream) {
    $lockStream.Dispose()
  }
  if ($lockAcquired) {
    try {
      Remove-CurrentOneClickTaskDefinition
    } catch {
      try {
        Write-CycleLog "warning: could not remove terminal one-click task definition: $($_.Exception.Message)"
      } catch {
        # The watcher result remains authoritative if terminal cleanup logging also fails.
      }
    }
  }
}

exit $exitCode
