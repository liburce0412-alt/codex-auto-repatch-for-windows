[CmdletBinding()]
param(
  [string]$TaskName = 'Codex Desktop Post-Update Repair',

  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9a-fA-F]{32}$')]
  [string]$StandingAuthorizationId,

  [ValidateRange(10, 120)]
  [int]$EventDelaySeconds = 30,

  [ValidateRange(1, 30)]
  [int]$LogonDelayMinutes = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$automationRoot = Join-Path $env:USERPROFILE '.codex\automation'
$runnerPath = Join-Path $automationRoot 'invoke-codex-standing-update.ps1'
$manualRunnerPath = Join-Path $automationRoot 'codex-post-update-repair.ps1'
$authorizationPath = Join-Path $automationRoot 'standing-update-authorization.json'
$stableIconPath = Join-Path $env:USERPROFILE '.codex\assets\codex-desktop.ico'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex.lnk'
$backupRoot = Join-Path $env:USERPROFILE '.codex\backups\post-update-automation'
$expectedPackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
$expectedPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$expectedScope = 'browser-computer-use-plus-custom-model-visibility'
$appUserModelId = "$expectedPackageFamilyName!App"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

function Resolve-StablePwshAlias {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
    'C:\Program Files\PowerShell\7\pwsh.exe'
  )
  $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) {
    $candidates += $command.Source
  }
  foreach ($candidate in ($candidates | Select-Object -Unique)) {
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
      $unsafe = [string]$probe.ProcessPath -match '(?i)\\\.cache\\codex-runtimes\\|\\WindowsApps\\OpenAI\.Codex_[^\\]+\\' -or
        (Join-Path ([string]$probe.PSHOME) 'pwsh.exe') -match '(?i)\\\.cache\\codex-runtimes\\|\\WindowsApps\\OpenAI\.Codex_[^\\]+\\'
      if ([version][string]$probe.Version -ge [version]'7.5' -and -not $unsafe) {
        return [System.IO.Path]::GetFullPath($candidate)
      }
    } catch {
      continue
    }
  }
  throw 'an external PowerShell 7.5 or newer executable was not found; Codex-bundled runtimes are refused'
}

foreach ($requiredPath in @($runnerPath, $manualRunnerPath, $authorizationPath)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "required standing automation component is missing: $requiredPath"
  }
}

$authorization = Get-Content -LiteralPath $authorizationPath -Raw | ConvertFrom-Json -DateKind String
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = $currentIdentity.User.Value
if ([int]$authorization.schema -ne 1 -or
    [string]$authorization.status -ne 'active' -or
    -not [string]::Equals([string]$authorization.authorization_id, $StandingAuthorizationId, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals([string]$authorization.scope, $expectedScope, [StringComparison]::Ordinal) -or
    -not [string]::Equals([string]$authorization.package_family_name, $expectedPackageFamilyName, [StringComparison]::Ordinal) -or
    -not [string]::Equals([string]$authorization.manifest_publisher, $expectedPublisher, [StringComparison]::Ordinal) -or
    -not [string]::Equals([string]$authorization.authorized_user_sid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'standing update authorization does not match this user and task scope'
}

$pwshPath = Resolve-StablePwshAlias
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
  $shortcutBackup = Join-Path $backupRoot "Codex.lnk.$stamp.bak"
  Copy-Item -LiteralPath $shortcutPath -Destination $shortcutBackup -Force
  Write-Host "shortcut backup: $shortcutBackup"
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
  $taskBackup = Join-Path $backupRoot "scheduled-task.$stamp.xml"
  $taskXml = Export-ScheduledTask -TaskName $TaskName
  [System.IO.File]::WriteAllText($taskBackup, $taskXml, [System.Text.UTF8Encoding]::new($false))
  Write-Host "scheduled task backup: $taskBackup"
}

$shortcutShell = New-Object -ComObject WScript.Shell
$shortcut = $shortcutShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:WINDIR 'explorer.exe'
$shortcut.Arguments = "shell:AppsFolder\$appUserModelId"
$shortcut.WorkingDirectory = $env:WINDIR
if (Test-Path -LiteralPath $stableIconPath) { $shortcut.IconLocation = "$stableIconPath,0" }
$shortcut.Description = 'Codex Desktop'
$shortcut.WindowStyle = 1
$shortcut.Save()
Write-Host "shortcut updated: $shortcutPath"

$quotedRunnerPath = '"' + $runnerPath.Replace('"', '""') + '"'
$taskArguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedRunnerPath -StandingAuthorizationId $($StandingAuthorizationId.ToLowerInvariant())"
$action = New-ScheduledTaskAction -Execute $pwshPath -Argument $taskArguments -WorkingDirectory $automationRoot

$taskNamespace = 'Root/Microsoft/Windows/TaskScheduler'
$subscription = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-AppXDeploymentServer/Operational">
    <Select Path="Microsoft-Windows-AppXDeploymentServer/Operational">*[System[(EventID=400)]] and *[EventData[Data[@Name='DeploymentOperation']='6' and Data[@Name='CallingProcess']='svchost.exe,wuauserv' and Data[@Name='PackageDisplayName']='ChatGPT']]</Select>
  </Query>
</QueryList>
'@
$eventTrigger = New-CimInstance `
  -CimClass (Get-CimClass -Namespace $taskNamespace -ClassName MSFT_TaskEventTrigger) `
  -ClientOnly `
  -Property @{
    Enabled = $true
    Id = 'StoreCodexRegistered'
    Delay = "PT$($EventDelaySeconds)S"
    Subscription = $subscription.Trim()
  }
$logonTrigger = New-CimInstance `
  -CimClass (Get-CimClass -Namespace $taskNamespace -ClassName MSFT_TaskLogonTrigger) `
  -ClientOnly `
  -Property @{
    Enabled = $true
    Id = 'LogonFallback'
    Delay = "PT$($LogonDelayMinutes)M"
    UserId = $currentSid
  }
$principal = New-ScheduledTaskPrincipal -UserId $currentSid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -RestartCount 2 `
  -RestartInterval (New-TimeSpan -Minutes 5) `
  -ExecutionTimeLimit (New-TimeSpan -Hours 3)
$task = New-ScheduledTask `
  -Action $action `
  -Trigger @($eventTrigger, $logonTrigger) `
  -Principal $principal `
  -Settings $settings `
  -Description 'Event-driven standing authorization for exact OpenAI.Codex Store updates; no resident process or periodic polling.'

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
Enable-ScheduledTask -TaskName $TaskName | Out-Null

$savedTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
$savedXml = Export-ScheduledTask -TaskName $TaskName
if ([string]$savedTask.State -eq 'Disabled' -or
    $savedXml -notmatch '<EventTrigger' -or
    $savedXml -notmatch '<LogonTrigger' -or
    $savedXml -match '<Repetition>' -or
    $savedXml -notmatch [regex]::Escape($StandingAuthorizationId.ToLowerInvariant())) {
  throw 'registered standing task did not preserve the event-driven authorization contract'
}

[pscustomobject]@{
  TaskName = $savedTask.TaskName
  TaskState = $savedTask.State
  Trigger = 'AppXDeploymentServer Event 400 / Store Register / ChatGPT'
  EventDelaySeconds = $EventDelaySeconds
  LogonFallbackDelayMinutes = $LogonDelayMinutes
  PeriodicPolling = $false
  ResidentProcess = $false
  Shortcut = $shortcutPath
  AuthorizationId = $StandingAuthorizationId.ToLowerInvariant()
} | Format-List
