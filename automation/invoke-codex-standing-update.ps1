[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9a-fA-F]{32}$')]
  [string]$StandingAuthorizationId,

  [switch]$ValidateOnly,

  [switch]$RetryFailedVersion,

  [ValidateRange(10, 120)]
  [int]$LaunchTimeoutSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$automationRoot = Join-Path $env:USERPROFILE '.codex\automation'
$authorizationPath = Join-Path $automationRoot 'standing-update-authorization.json'
$armerPath = Join-Path $automationRoot 'arm-codex-oneclick-update.ps1'
$oneClickAuthorizationPath = Join-Path $automationRoot 'update-cycle-authorization.json'
$oneClickStatePath = Join-Path $automationRoot 'update-cycle-active.json'
$oneClickLockPath = Join-Path $automationRoot 'update-cycle-active.lock'
$lockPath = Join-Path $automationRoot 'standing-update-active.lock'
$logRoot = Join-Path $automationRoot 'logs'
$statePath = Join-Path $automationRoot 'standing-update-state.json'
$repairStatePath = Join-Path $automationRoot 'post-update-state.json'
$expectedPackageName = 'OpenAI.Codex'
$expectedPackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
$expectedPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$expectedScope = 'browser-computer-use-plus-custom-model-visibility'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$logPath = Join-Path $logRoot "standing-update-$runStamp-$PID.log"

function Write-StandingLog {
  param([Parameter(Mandatory)][string]$Message)

  $line = '{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $Message
  [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, $utf8NoBom)
}

function Write-JsonFileAtomically {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object]$Value
  )

  $temporaryPath = "$Path.$PID.tmp"
  [System.IO.File]::WriteAllText(
    $temporaryPath,
    (($Value | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    $utf8NoBom
  )
  [System.IO.File]::Move($temporaryPath, $Path, $true)
}

function Write-StandingState {
  param(
    [Parameter(Mandatory)][string]$Status,
    [System.Collections.IDictionary]$Details = @{}
  )

  $state = [ordered]@{
    schema = 1
    last_run_at = [DateTimeOffset]::UtcNow.ToString('o')
    last_status = $Status
    authorization_id = $StandingAuthorizationId.ToLowerInvariant()
    log_path = $logPath
  }
  foreach ($entry in $Details.GetEnumerator()) {
    $state[$entry.Key] = $entry.Value
  }
  Write-JsonFileAtomically -Path $statePath -Value $state
}

function Get-StandingAuthorization {
  if (-not (Test-Path -LiteralPath $authorizationPath -PathType Leaf)) {
    throw "standing update authorization is missing: $authorizationPath"
  }
  try {
    $authorization = Get-Content -LiteralPath $authorizationPath -Raw | ConvertFrom-Json -DateKind String
  } catch {
    throw "standing update authorization is unreadable: $($_.Exception.Message)"
  }

  $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ([int]$authorization.schema -ne 1 -or
      [string]$authorization.status -ne 'active' -or
      -not [string]::Equals([string]$authorization.authorization_id, $StandingAuthorizationId, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([string]$authorization.scope, $expectedScope, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$authorization.package_name, $expectedPackageName, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$authorization.package_family_name, $expectedPackageFamilyName, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$authorization.manifest_publisher, $expectedPublisher, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$authorization.authorized_user_sid, $currentSid, [StringComparison]::OrdinalIgnoreCase) -or
      [bool]$authorization.allow_future_store_versions -ne $true -or
      [bool]$authorization.allow_automatic_restart_repair -ne $true) {
    throw 'standing update authorization does not match this user and the exact OpenAI.Codex package scope'
  }
  return $authorization
}

function Get-CodexPackage {
  return Get-AppxPackage -Name $expectedPackageName -PackageTypeFilter Main -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
}

function Get-CodexManifestDescriptor {
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
  if (-not [string]::Equals([string]$manifest.Package.Identity.Name, $expectedPackageName, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$manifest.Package.Identity.Publisher, $expectedPublisher, [StringComparison]::Ordinal)) {
    throw 'installed package manifest identity is outside the standing authorization scope'
  }

  $applications = @($manifest.Package.Applications.Application)
  $application = $applications | Where-Object { [string]$_.Id -eq 'App' } | Select-Object -First 1
  if (-not $application -and $applications.Count -eq 1) {
    $application = $applications[0]
  }
  if (-not $application) {
    throw 'Codex manifest does not expose an unambiguous application entry'
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

  return [pscustomobject]@{
    ApplicationId = [string]$application.Id
    AppUserModelId = '{0}!{1}' -f $expectedPackageFamilyName, [string]$application.Id
    ExecutablePath = $executablePath
  }
}

function Get-CodexMainProcess {
  param([Parameter(Mandatory)][string]$ExactPath)

  $normalizedPath = [System.IO.Path]::GetFullPath($ExactPath)
  foreach ($process in Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe' OR Name='Codex.exe'" -ErrorAction SilentlyContinue) {
    if (-not [string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -and
        [string]::Equals([System.IO.Path]::GetFullPath([string]$process.ExecutablePath), $normalizedPath, [StringComparison]::OrdinalIgnoreCase)) {
      return $process
    }
  }
  return $null
}

function Start-CodexPackageAndWait {
  param(
    [Parameter(Mandatory)][pscustomobject]$Descriptor,
    [Parameter(Mandatory)][int]$TimeoutSeconds
  )

  $process = Get-CodexMainProcess -ExactPath $Descriptor.ExecutablePath
  if ($process) {
    return $process
  }
  Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList "shell:AppsFolder\$($Descriptor.AppUserModelId)"
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Milliseconds 500
    $process = Get-CodexMainProcess -ExactPath $Descriptor.ExecutablePath
    if ($process) {
      return $process
    }
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "Store Codex did not start within $TimeoutSeconds seconds"
}

function Test-OneClickWatcherActive {
  try {
    $probe = [System.IO.File]::Open(
      $oneClickLockPath,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
    $probe.Dispose()
    return $false
  } catch [System.IO.IOException] {
    return $true
  }
}

function Wait-ForOneClickWatcherReady {
  param(
    [Parameter(Mandatory)][string]$AuthorizationId,
    [ValidateRange(5, 60)][int]$TimeoutSeconds = 30
  )

  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    if (Test-Path -LiteralPath $oneClickStatePath -PathType Leaf) {
      try {
        $cycleState = Get-Content -LiteralPath $oneClickStatePath -Raw | ConvertFrom-Json -DateKind String
        if ([string]::Equals([string]$cycleState.authorization_id, $AuthorizationId, [StringComparison]::OrdinalIgnoreCase)) {
          if ([string]$cycleState.status -eq 'armed') {
            return
          }
          if ([string]$cycleState.status -eq 'failed') {
            throw "one-click watcher failed before taking control: $($cycleState.error)"
          }
        }
      } catch {
        if ($_.Exception.Message -like 'one-click watcher failed before taking control:*') {
          throw
        }
      }
    }
    Start-Sleep -Milliseconds 250
  } while ([DateTimeOffset]::UtcNow -lt $deadline)

  throw "one-click watcher did not confirm control within $TimeoutSeconds seconds"
}

function Wait-ForOneClickCompletion {
  param([Parameter(Mandatory)][string]$AuthorizationId)

  $cycleState = Get-Content -LiteralPath $oneClickStatePath -Raw | ConvertFrom-Json -DateKind String
  if ([string]$cycleState.authorization_id -ne $AuthorizationId) {
    throw 'one-click state changed before completion monitoring started'
  }
  $monitor = Get-Process -Id ([int]$cycleState.monitor_pid) -ErrorAction SilentlyContinue
  if ($monitor) {
    $monitor | Wait-Process -Timeout 9000 -ErrorAction Stop
  }
  $cycleState = Get-Content -LiteralPath $oneClickStatePath -Raw | ConvertFrom-Json -DateKind String
  if ([string]$cycleState.authorization_id -ne $AuthorizationId -or
      [string]$cycleState.status -ne 'repair-restart-stable') {
    throw "one-click repair did not complete: status=$($cycleState.status); log=$($cycleState.log_path)"
  }
  $handoffPath = Join-Path $automationRoot "install-handoffs\$($AuthorizationId.ToLowerInvariant())\completed-msix-install.json"
  $handoff = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json -DateKind String
  if ([string]$handoff.authorization_id -ne $AuthorizationId -or [string]$handoff.status -ne 'completed') {
    throw 'one-click install handoff did not record completion for this authorization'
  }
  $installedPackage = Get-CodexPackage
  if (-not $installedPackage -or [string]$installedPackage.SignatureKind -ne 'Developer' -or
      [string]$installedPackage.PackageFullName -ne [string]$cycleState.expected_package_full_name) {
    throw 'one-click completion does not match the installed Developer package'
  }
  Write-StandingState -Status 'success' -Details @{
    observed_version = [string]$installedPackage.Version
    observed_package_full_name = [string]$installedPackage.PackageFullName
    one_click_authorization_id = $AuthorizationId
  }
  Write-StandingLog 'exact-version Developer installation and stable restart completed'
}

New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$standingLock = $null
try {
  try {
    $standingLock = [System.IO.File]::Open(
      $lockPath,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
  } catch [System.IO.IOException] {
    return
  }

  $authorization = Get-StandingAuthorization
  $package = Get-CodexPackage
  if (-not $package) {
    throw 'OpenAI.Codex is not installed'
  }
  if (-not [string]::Equals([string]$package.PackageFamilyName, $expectedPackageFamilyName, [StringComparison]::Ordinal) -or
      -not [string]::Equals([string]$package.Publisher, $expectedPublisher, [StringComparison]::Ordinal)) {
    throw 'installed package identity is outside the standing authorization scope'
  }

  $version = [version][string]$package.Version
  $signatureKind = [string]$package.SignatureKind
  Write-StandingLog "observed package: version=$version signature=$signatureKind fullName=$($package.PackageFullName)"

  if ($signatureKind -eq 'Developer') {
    if (Test-Path -LiteralPath $oneClickStatePath -PathType Leaf) {
      $previousCycle = Get-Content -LiteralPath $oneClickStatePath -Raw | ConvertFrom-Json -DateKind String
      if ([string]$previousCycle.expected_package_full_name -eq [string]$package.PackageFullName -and
          [string]$previousCycle.status -ne 'repair-restart-stable') {
        throw "Developer package exists but its update cycle is incomplete: $($previousCycle.status); retain the install handoff for recovery"
      }
    }
    Write-StandingState -Status 'already-patched' -Details @{
      observed_version = [string]$version
      observed_package_full_name = [string]$package.PackageFullName
    }
    Write-StandingLog 'Developer-signed Codex is already installed; no action is needed'
    if ($ValidateOnly) {
      [pscustomobject]@{ Valid = $true; WouldRepair = $false; Reason = 'already-patched'; Version = [string]$version }
    }
    return
  }
  if ($signatureKind -ne 'Store') {
    throw "unsupported Codex signature kind: $signatureKind"
  }

  $descriptor = Get-CodexManifestDescriptor -Package $package
  if (Test-Path -LiteralPath $repairStatePath -PathType Leaf) {
    $repairState = Get-Content -LiteralPath $repairStatePath -Raw | ConvertFrom-Json -DateKind String
    if ($repairState.PSObject.Properties['last_successful_version'] -and
        $version -lt [version][string]$repairState.last_successful_version) {
      throw "automatic downgrade is refused: installed=$version lastSuccessful=$($repairState.last_successful_version)"
    }
  }
  if (Test-OneClickWatcherActive) {
    Write-StandingState -Status 'one-click-repair-active' -Details @{ observed_version = [string]$version }
    Write-StandingLog 'an exact-version one-click repair is already active; leaving it in control'
    return
  }

  if ($ValidateOnly) {
    Write-StandingState -Status 'validated-store-package' -Details @{
      observed_version = [string]$version
      observed_package_full_name = [string]$package.PackageFullName
    }
    [pscustomobject]@{
      Valid = $true
      WouldRepair = $true
      Version = [string]$version
      PackageFullName = [string]$package.PackageFullName
      AppUserModelId = $descriptor.AppUserModelId
    }
    return
  }

  # A failed repair must not repeatedly stop the same usable Store version.
  # A later Store version is eligible automatically; an explicit exact-version
  # armer invocation remains available for a deliberate retry after a fix.
  if (-not $RetryFailedVersion -and (Test-Path -LiteralPath $oneClickStatePath -PathType Leaf)) {
    $previousCycle = Get-Content -LiteralPath $oneClickStatePath -Raw | ConvertFrom-Json
    if ([string]$previousCycle.expected_package_full_name -eq [string]$package.PackageFullName -and
        [string]$previousCycle.status -in @('store-preserved', 'store-restored', 'store-recovery-failed', 'repair-failed-cli-opened', 'cli-fallback-failed', 'failed-prepare', 'failed-install', 'failed-finalize', 'failed-validation', 'timed-out-before-patched-restart')) {
      Write-StandingState -Status 'repair-paused-store-preserved' -Details @{ observed_version = [string]$version; reason = [string]$previousCycle.status }
      Write-StandingLog 'this Store version already had a failed repair; leaving it usable until an explicit retry or a newer Store update'
      return
    }
  }

  if (-not (Test-Path -LiteralPath $armerPath -PathType Leaf)) {
    throw "one-click armer is missing: $armerPath"
  }
  . (Join-Path $automationRoot 'start-codex-cli-fallback.ps1')
  [void](Initialize-CodexFallbackCli)
  $baselineProcess = Start-CodexPackageAndWait -Descriptor $descriptor -TimeoutSeconds $LaunchTimeoutSeconds
  Write-StandingLog "Store baseline is running: pid=$($baselineProcess.ProcessId) path=$($descriptor.ExecutablePath)"

  $armOutput = & $armerPath `
    -ExpectedUpdateVersion $version `
    -RepairCurrentStorePackage `
    -StandingAuthorizationId $StandingAuthorizationId `
    -AuthorizationMinutes 120 `
    -StablePackageSeconds 3 `
    -StableRestartSeconds 20 2>&1 | Out-String
  if ($armOutput) {
    Write-StandingLog ($armOutput.Trim())
  }
  if (-not (Test-Path -LiteralPath $oneClickAuthorizationPath -PathType Leaf)) {
    throw 'the exact-version one-click authorization was not created'
  }
  $oneClickAuthorization = Get-Content -LiteralPath $oneClickAuthorizationPath -Raw | ConvertFrom-Json -DateKind String
  if ([string]$oneClickAuthorization.status -ne 'armed' -or
      -not [string]::Equals([string]$oneClickAuthorization.standing_authorization_id, $StandingAuthorizationId, [StringComparison]::OrdinalIgnoreCase) -or
      [version][string]$oneClickAuthorization.expected_update_version -ne $version -or
      -not [string]::Equals([string]$oneClickAuthorization.expected_package_full_name, [string]$package.PackageFullName, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'the generated one-click authorization does not match the observed Store package'
  }

  Wait-ForOneClickWatcherReady -AuthorizationId ([string]$oneClickAuthorization.authorization_id)
  Write-StandingLog "one-click watcher confirmed control: authorization=$($oneClickAuthorization.authorization_id)"

  $currentBaseline = Get-CodexMainProcess -ExactPath $descriptor.ExecutablePath
  if (-not $currentBaseline -or [int]$currentBaseline.ProcessId -ne [int]$oneClickAuthorization.baseline_main_process_id) {
    throw 'the Store baseline process changed before the authorized restart'
  }
  Write-StandingState -Status 'exact-repair-armed' -Details @{
    observed_version = [string]$version
    observed_package_full_name = [string]$package.PackageFullName
    one_click_authorization_id = [string]$oneClickAuthorization.authorization_id
    one_click_task_name = [string]$oneClickAuthorization.task_name
  }
  Write-StandingLog "stopping exact Store baseline to begin authorized repair: pid=$($currentBaseline.ProcessId)"
  Stop-Process -Id ([int]$currentBaseline.ProcessId) -Force -ErrorAction Stop
  Wait-ForOneClickCompletion -AuthorizationId ([string]$oneClickAuthorization.authorization_id)
} catch {
  try {
    Write-StandingLog "failed: $($_.Exception.Message)"
    Write-StandingState -Status 'failed' -Details @{ error = $_.Exception.Message }
  } catch {
  }
  throw
} finally {
  if ($standingLock) {
    $standingLock.Dispose()
  }
}
