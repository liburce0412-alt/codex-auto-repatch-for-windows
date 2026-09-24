[CmdletBinding()]
param(
  [string]$TaskName = 'Codex Desktop Post-Update Repair'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$automationRoot = Join-Path $env:USERPROFILE '.codex\automation'
$authorizationPath = Join-Path $automationRoot 'standing-update-authorization.json'
$installerPath = Join-Path $automationRoot 'install-codex-post-update-automation.ps1'
$backupRoot = Join-Path $env:USERPROFILE '.codex\backups\post-update-automation'
$expectedPackageName = 'OpenAI.Codex'
$expectedPackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
$expectedPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$expectedScope = 'browser-computer-use-plus-custom-model-visibility'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
  throw "standing automation installer is missing: $installerPath"
}
$package = Get-AppxPackage -Name $expectedPackageName -PackageTypeFilter Main -ErrorAction SilentlyContinue |
  Sort-Object Version -Descending |
  Select-Object -First 1
if (-not $package) {
  throw 'OpenAI.Codex is not installed'
}
if (-not [string]::Equals([string]$package.PackageFamilyName, $expectedPackageFamilyName, [StringComparison]::Ordinal) -or
    -not [string]::Equals([string]$package.Publisher, $expectedPublisher, [StringComparison]::Ordinal)) {
  throw 'installed package identity does not match the standing authorization scope'
}

New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$previousAuthorizationBackup = $null
if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
  $previousAuthorizationBackup = Join-Path $backupRoot ("standing-update-authorization.{0}.json.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
  Copy-Item -LiteralPath $authorizationPath -Destination $previousAuthorizationBackup -Force
}

$authorizationId = [Guid]::NewGuid().ToString('N')
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$authorization = [ordered]@{
  schema = 1
  status = 'active'
  authorization_id = $authorizationId
  scope = $expectedScope
  granted_at = [DateTimeOffset]::UtcNow.ToString('o')
  expires_at = $null
  authorized_user_sid = $identity.User.Value
  authorized_user_name = $identity.Name
  package_name = $expectedPackageName
  package_family_name = $expectedPackageFamilyName
  manifest_publisher = $expectedPublisher
  allowed_source_signature = 'Store'
  resulting_signature = 'Developer'
  allow_future_store_versions = $true
  allow_same_version_store_repair = $true
  allow_automatic_restart_repair = $true
  reject_automatic_downgrade = $true
  trigger_mode = 'appx-store-register-event-with-logon-fallback'
  periodic_polling = $false
  resident_process = $false
}
$temporaryPath = "$authorizationPath.$PID.tmp"
try {
  [System.IO.File]::WriteAllText(
    $temporaryPath,
    (($authorization | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
    $utf8NoBom
  )
  [System.IO.File]::Move($temporaryPath, $authorizationPath, $true)
  & $installerPath -TaskName $TaskName -StandingAuthorizationId $authorizationId
} catch {
  if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
    [System.IO.File]::Delete($temporaryPath)
  }
  if ($previousAuthorizationBackup -and (Test-Path -LiteralPath $previousAuthorizationBackup -PathType Leaf)) {
    Copy-Item -LiteralPath $previousAuthorizationBackup -Destination $authorizationPath -Force
  } elseif (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
    [System.IO.File]::Delete($authorizationPath)
  }
  throw
}

[pscustomobject]@{
  StandingAuthorization = 'Active'
  AuthorizationId = $authorizationId
  Scope = $expectedScope
  PackageFamilyName = $expectedPackageFamilyName
  FutureStoreVersions = $true
  AutomaticRestartRepair = $true
  TriggerMode = 'Store registration event + delayed logon fallback'
  PeriodicPolling = $false
  ResidentProcess = $false
  PreviousAuthorizationBackup = $previousAuthorizationBackup
} | Format-List
