param([string]$HelperPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'codex-appdata-backup.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $HelperPath
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$expectedPath = "$sid\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\OpenAI.Codex_2p2nqsd0c76g0\App"
$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-startup-test-' + [guid]::NewGuid().ToString('N'))
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:checks++
}
function Reject([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -like $Pattern) { $script:checks++; return }
    throw
  }
  throw "expected rejection: $Pattern"
}
function Reset-Registry([int]$State = 2) {
  $script:registry = @{State=[long]$State; UserEnabledStartupOnce=[long]0}
  $script:writes = 0
  $script:reads = 0
  $script:readError = 0
  $script:writeError = 0
  $script:wrongType = $false
  $script:ignoreWrites = $false
  $script:changeOnSecondRead = $false
  $script:packageCount = 0
  $script:packageFamily = 'OpenAI.Codex_2p2nqsd0c76g0'
  $script:applicationId = 'App'
  $script:startupCategory = 'windows.startupTask'
  $script:startupTaskId = 'App'
  $script:packageQueries = 0
  $script:creates = 0
  $script:createError = 0
  $script:policyOnManifest = 0
  $script:policyOnCreate = 0
}
function Get-AppxPackage {
  param($Name,$ErrorAction)
  if ($Name -cne 'OpenAI.Codex') { throw 'wrong package query' }
  $script:packageQueries++
  for ($i=0; $i -lt $script:packageCount; $i++) {
    [pscustomobject]@{PackageFamilyName=$script:packageFamily;PackageFullName='fixture'}
  }
}
function Get-AppxPackageManifest {
  param($Package,$ErrorAction)
  if ($Package -cne 'fixture') { throw 'wrong manifest query' }
  if ($script:policyOnManifest) { $script:registry=@{State=[long]$script:policyOnManifest} }
  [xml]('<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5"><Applications><Application Id="{0}"><Extensions><uap5:Extension Category="{1}"><uap5:StartupTask TaskId="{2}" /></uap5:Extension></Extensions></Application></Applications></Package>' -f $script:applicationId,$script:startupCategory,$script:startupTaskId)
}
# Intercept the native provider itself: no test can write the live startup key.
function Invoke-CimMethod {
  param($Namespace,$ClassName,$MethodName,$Arguments,$ErrorAction)
  if ($Namespace -ne 'root/default' -or $ClassName -ne 'StdRegProv' -or
      $Arguments.hDefKey -ne [uint32]2147483651 -or
      $Arguments.sSubKeyName -cne $expectedPath) { throw 'wrong native registry target' }
  switch ($MethodName) {
    'EnumValues' {
      $script:reads++
      if ($script:readError) { return @{ReturnValue=$script:readError} }
      if ($null -eq $script:registry) { return @{ReturnValue=2} }
      if ($script:changeOnSecondRead -and $script:reads -eq 2) { $script:registry.State=0L }
      $names = @($script:registry.Keys)
      $types = @($names | ForEach-Object { if ($script:wrongType) { 1 } else { 4 } })
      return @{ReturnValue=0;sNames=$names;Types=$types}
    }
    'GetDWORDValue' {
      if ($Arguments.sValueName -notin @('State','UserEnabledStartupOnce')) { throw 'unexpected value read' }
      if ($null -eq $script:registry -or -not $script:registry.ContainsKey($Arguments.sValueName)) { return @{ReturnValue=2} }
      return @{ReturnValue=0;uValue=$script:registry[$Arguments.sValueName]}
    }
    'CreateKey' {
      if ($Arguments.ContainsKey('sValueName')) { throw 'CreateKey received a value name' }
      $script:creates++
      if ($script:createError) { return @{ReturnValue=$script:createError} }
      if ($null -eq $script:registry) { $script:registry=@{} }
      if ($script:policyOnCreate) { $script:registry.State=[long]$script:policyOnCreate }
      return @{ReturnValue=0}
    }
    'SetDWORDValue' {
      if ($Arguments.sValueName -notin @('State','UserEnabledStartupOnce')) { throw 'unexpected value write' }
      $script:writes++
      if (-not $script:ignoreWrites -and -not $script:writeError) { $script:registry[$Arguments.sValueName]=[long]$Arguments.uValue }
      return @{ReturnValue=$script:writeError}
    }
    default { throw "unexpected registry operation: $MethodName" }
  }
}
try {
  New-Item -ItemType Directory -Path $root | Out-Null
  foreach ($state in 0,1,2) {
    Reset-Registry $state
    $script:registry.UserEnabledStartupOnce=1L
    $backup = Join-Path $root "state-$state"
    Save-CodexAppDataBackup (Join-Path $root 'absent-source') $backup 'fixture' -PreserveStartupTask
    Assert ($script:writes -eq 0) 'snapshot changed startup preference'
    $manifest = Assert-CodexAppDataBackup $backup
    Assert ($manifest.startup_task.state -eq $state) 'startup choice missing from manifest'
    Reset-Registry (2 - $state)
    Restore-CodexAppDataBackup (Join-Path $root 'restored') $backup
    Assert ($script:registry.State -eq $state -and $script:registry.UserEnabledStartupOnce -eq 1) 'startup choice did not round-trip'
    $priorWrites = $script:writes
    Restore-CodexAppDataBackup (Join-Path $root 'restored') $backup
    Assert ($script:writes -eq $priorWrites) 'identical startup restoration was not idempotent'
  }
  foreach ($policy in 3,4) {
    Reset-Registry $policy
    $snapshot = Get-CodexStartupTaskSnapshot
    Reset-Registry 2
    Restore-CodexStartupTaskSnapshot $snapshot
    Assert ($script:writes -eq 0) 'old policy state was replayed'
    Reset-Registry 1
    $snapshot = Get-CodexStartupTaskSnapshot
    Reset-Registry $policy
    Restore-CodexStartupTaskSnapshot $snapshot
    Assert ($script:writes -eq 0) 'current policy state was overwritten'
  }
  Reset-Registry 1
  $script:registry.Remove('UserEnabledStartupOnce')
  $snapshot = Get-CodexStartupTaskSnapshot
  Reset-Registry 2
  $script:registry.Remove('UserEnabledStartupOnce')
  Restore-CodexStartupTaskSnapshot $snapshot
  Assert ($script:registry.State -eq 1 -and -not $script:registry.ContainsKey('UserEnabledStartupOnce')) 'absent optional value was invented'
  Reset-Registry
  $script:registry=$null
  $snapshot = Get-CodexStartupTaskSnapshot
  Restore-CodexStartupTaskSnapshot $snapshot
  Assert ($script:writes -eq 0) 'absent original task was invented'
  Reset-Registry 1
  $snapshot = Get-CodexStartupTaskSnapshot
  $script:registry=$null
  Reject { Restore-CodexStartupTaskSnapshot $snapshot } '*task is missing*'
  Assert ($script:writes -eq 0 -and $script:creates -eq 0) 'unregistered package created a startup preference'
  foreach ($state in 0,1,2) {
    Reset-Registry $state
    $script:registry.UserEnabledStartupOnce=1L
    $snapshot = Get-CodexStartupTaskSnapshot
    Reset-Registry
    $script:registry=$null
    $script:packageCount=1
    Restore-CodexStartupTaskSnapshot $snapshot
    Assert ($script:registry.State -eq $state -and $script:registry.UserEnabledStartupOnce -eq 1 -and $script:creates -eq 1) 'fresh installed startup preference did not round-trip'
    $priorWrites=$script:writes
    Restore-CodexStartupTaskSnapshot $snapshot
    Assert ($script:writes -eq $priorWrites -and $script:creates -eq 1 -and $script:packageQueries -eq 1) 'fresh startup restoration was not idempotent'
  }
  foreach ($invalid in 'family','multiple','application','category','task') {
    Reset-Registry 1
    $snapshot = Get-CodexStartupTaskSnapshot
    $script:registry=$null
    $script:packageCount=1
    switch ($invalid) {
      'family' { $script:packageFamily='Other.Package_family' }
      'multiple' { $script:packageCount=2 }
      'application' { $script:applicationId='Other' }
      'category' { $script:startupCategory='windows.other' }
      'task' { $script:startupTaskId='Other' }
    }
    Reject { Restore-CodexStartupTaskSnapshot $snapshot } '*task is missing*'
    Assert ($script:writes -eq 0 -and $script:creates -eq 0) "invalid $invalid registered a startup preference"
  }
  foreach ($policy in 3,4) {
    foreach ($during in 'manifest','create') {
      Reset-Registry 1
      $snapshot = Get-CodexStartupTaskSnapshot
      $script:registry=$null
      $script:packageCount=1
      if ($during -eq 'manifest') { $script:policyOnManifest=$policy } else { $script:policyOnCreate=$policy }
      Restore-CodexStartupTaskSnapshot $snapshot
      Assert ($script:registry.State -eq $policy -and $script:writes -eq 0) "fresh policy $policy was overwritten during $during"
    }
  }
  foreach ($failure in 'create','write','readback') {
    Reset-Registry 1
    $snapshot = Get-CodexStartupTaskSnapshot
    $script:registry=$null
    $script:packageCount=1
    switch ($failure) {
      'create' { $script:createError=5; $pattern='*cannot restore Codex startup key*' }
      'write' { $script:writeError=5; $pattern='*cannot restore Codex startup value*' }
      'readback' { $script:ignoreWrites=$true; $pattern='*without State*' }
    }
    Reject { Restore-CodexStartupTaskSnapshot $snapshot } $pattern
  }
  Reset-Registry 1
  $snapshot = Get-CodexStartupTaskSnapshot
  $snapshot.sid='S-1-5-21-1-2-3-4'
  Reject { Restore-CodexStartupTaskSnapshot $snapshot } '*another user*'
  Assert ($script:writes -eq 0) 'wrong-user snapshot wrote registry values'
  Reset-Registry
  $script:wrongType=$true
  Reject { Get-CodexStartupTaskSnapshot } '*not DWORD*'
  Reset-Registry
  $script:readError=5
  Reject { Save-CodexAppDataBackup 'absent' (Join-Path $root 'failed-read') 'fixture' -PreserveStartupTask } '*cannot read*'
  Assert (-not (Test-Path (Join-Path $root 'failed-read'))) 'failed startup read left a valid-looking backup'
  Reset-Registry 1
  $script:changeOnSecondRead=$true
  Reject { Save-CodexAppDataBackup 'absent' (Join-Path $root 'changed') 'fixture' -PreserveStartupTask } '*changed during backup*'
  Reset-Registry 1
  $snapshot = Get-CodexStartupTaskSnapshot
  Reset-Registry 2
  $script:ignoreWrites=$true
  Reject { Restore-CodexStartupTaskSnapshot $snapshot } '*readback mismatch*'
  Reset-Registry 2
  $script:writeError=5
  Reject { Restore-CodexStartupTaskSnapshot $snapshot } '*cannot restore*'
  Reset-Registry 2
  $script:readError=5
  $legacy = Join-Path $root 'legacy'
  Save-CodexAppDataBackup 'absent' $legacy 'fixture'
  Restore-CodexAppDataBackup (Join-Path $root 'restored') $legacy
  Assert ($script:reads -eq 0 -and $script:writes -eq 0) 'legacy snapshot unexpectedly accessed startup registry'
  $manifest = Get-Content (Join-Path $legacy 'manifest.json') -Raw | ConvertFrom-Json
  $manifest | Add-Member startup_task ([pscustomobject]@{sid=$sid;state='1';user_enabled_once=0})
  [IO.File]::WriteAllText((Join-Path $legacy 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6))
  Reject { Restore-CodexAppDataBackup (Join-Path $root 'invalid-restore') $legacy } '*invalid Codex startup snapshot value*'
  Assert (-not (Test-Path (Join-Path $root 'invalid-restore'))) 'invalid startup snapshot was validated after restoring files'
  "STARTUP_PREFERENCE_PASSED: $checks checks; mocked native registry; live startup state never written"
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($root)
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if (-not $resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $resolvedRoot) -notmatch '^codex-startup-test-[a-f0-9]{32}$') { throw 'unsafe fixture cleanup target' }
  if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
  if (Test-Path -LiteralPath $resolvedRoot) { throw 'startup fixture cleanup failed' }
}
