$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$automation = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $automation 'watch-codex-update-cycle.ps1'), [ref]$null, [ref]$null)
$testRoot = Join-Path $PSScriptRoot ('fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Import-WatcherFunction([string]$Name) {
  $definition = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name}, $true)
  if (-not $definition) { throw "missing function: $Name" }
  return [scriptblock]::Create($definition.Extent.Text)
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch { if ($_.Exception.Message -like $Pattern) { return }; throw }
  throw "expected rejection: $Pattern"
}

& {
  . (Import-WatcherFunction 'Install-PreparedCodexPackage')
  . (Import-WatcherFunction 'Save-StoreRecoveryArtifact')
  $automationRoot = $testRoot
  $ExpectedUpdateVersion = [version]'26.917.9434.0'
  $script:sideEffects = 0
  $script:signature='Store'
  $script:badPatch=$false
  [IO.File]::WriteAllText((Join-Path $testRoot 'start-codex-cli-fallback.ps1'), 'function Get-VerifiedFallbackCli { return $true }')
  function Assert-PreparedInstallHandoff { if($script:badPatch){throw 'invalid patched artifact'}; @{ Record=@{status='prepared'}; ArtifactSha256='fixture'; ArtifactPath='fixture.msix' } }
  function Get-CodexPackage { @{SignatureKind=$script:signature;Version='26.917.9434.0';PackageFullName='expected'} }
  function Test-ExpectedPackage { $true }
  function Test-CompletePackage { $true }
  function Stop-CodexPackageProcesses { $script:sideEffects++ }
  function Invoke-RemoveCodexAppxPackage { $script:sideEffects++ }
  function Invoke-AddCodexAppxPackage { $script:sideEffects++; $script:signature='Developer' }
  function Restore-PreparedPackageData { }
  function Write-InstallHandoffState { }
  function Write-CycleLog { }
  $installed=Install-PreparedCodexPackage @{}
  Assert ($installed.SignatureKind -eq 'Developer' -and $script:sideEffects -eq 3) 'optional recovery still blocked valid installation'
  $script:sideEffects=0; $script:signature='Store'; $script:badPatch=$true
  Assert-Throws { Install-PreparedCodexPackage @{} } 'invalid patched artifact'
  Assert ($script:sideEffects -eq 0) 'invalid patched artifact caused side effects'
}

& {
  . (Import-WatcherFunction 'Invoke-RemoveCodexAppxPackage')
  $automationRoot=$testRoot
  $installRequestRoot=$testRoot
  [IO.File]::WriteAllText((Join-Path $testRoot 'codex-appdata-backup.ps1'), '# fixture: use mocks defined in this scope')
  $script:removalCalls = 0
  $script:backupFailure = $true
  function Save-CodexAppDataBackup { if($script:backupFailure){throw 'backup failed'} }
  function Assert-CodexAppDataBackup { }
  function Write-InstallHandoffState { }
  function Write-CycleLog { }
  function Remove-AppxPackage { param($Package,[switch]$PreserveApplicationData,$ErrorAction)
    $script:removalCalls++
    Assert (-not $PreserveApplicationData) 'Store uninstall used a development-only parameter'
  }
  Assert-Throws { Invoke-RemoveCodexAppxPackage @{PackageFullName='fixture'} } 'backup failed'
  Assert ($script:removalCalls -eq 0) 'Store uninstall occurred before a verified data backup'
  $script:backupFailure=$false
  Invoke-RemoveCodexAppxPackage @{PackageFullName='fixture'}
  Assert ($script:removalCalls -eq 1) 'Store uninstall did not run after a verified backup'
}

& {
  . (Import-WatcherFunction 'Assert-StoreRecoveryArtifact')
  $installRequestRoot = Join-Path $testRoot 'recovery-validation'
  New-Item -ItemType Directory -Path $installRequestRoot | Out-Null
  $recovery = Join-Path $installRequestRoot 'official-store.msix'
  [IO.File]::WriteAllText($recovery, 'mocked signed original')
  $ExpectedUpdateVersion = [version]'26.917.9434.0'
  $record = [pscustomobject]@{ store_recovery_path=$recovery; store_recovery_sha256=(Get-FileHash $recovery).Hash; store_signature_sha256='official-signature' }
  $script:signatureStatus = 'Valid'
  $script:architecture = 'x64'
  $script:version = '26.917.9434.0'
  function Read-InstallHandoff { $record }
  function Get-AuthenticodeSignature { @{Status=$script:signatureStatus} }
  function Get-ArchiveSignatureHash { 'official-signature' }
  function Get-MsixManifestIdentity { @{Name='OpenAI.Codex'; Version=$script:version; Architecture=$script:architecture; Publisher='CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'} }
  Assert ((Assert-StoreRecoveryArtifact) -eq $recovery) 'valid recovery contract failed'
  $script:signatureStatus='HashMismatch'
  Assert-Throws { Assert-StoreRecoveryArtifact } '*verification failed*'
  $script:signatureStatus='Valid'; $script:architecture='arm64'
  Assert-Throws { Assert-StoreRecoveryArtifact } '*verification failed*'
  $script:architecture='x64'; $script:version='26.917.6896.0'
  Assert-Throws { Assert-StoreRecoveryArtifact } '*verification failed*'
  $script:version='26.917.9434.0'
  [IO.File]::WriteAllText($recovery,'tampered original')
  Assert-Throws { Assert-StoreRecoveryArtifact } '*verification failed*'
}

& {
  . (Import-WatcherFunction 'Open-CliAfterRepairFailure')
  $automationRoot=$testRoot
  $installHandoffPath=Join-Path $testRoot 'absent-handoff.json'
  $RepairPwshPath='fixture-pwsh'
  $logPath='fixture.log'
  $script:cliFallbackOpened=$false
  $script:launches=0
  $script:failLaunch=$false
  $script:stage=''
  function Start-CodexCliFallbackTerminal { $script:launches++; if($script:failLaunch){throw 'CLI launch failed'}; @{TerminalId=42;CliPath='independent-cli'} }
  function Invoke-RemoveCodexAppxPackage { throw 'fallback must never remove an app' }
  function Invoke-AddCodexAppxPackage { throw 'fallback must never deploy an app' }
  function Write-CycleState { param($Status,$Details) $script:stage=$Status }
  function Write-CycleLog { }
  Assert (Open-CliAfterRepairFailure 'fixture') 'CLI fallback failed'
  Assert ($script:stage -eq 'repair-failed-cli-opened') 'fallback status wrong'
  Assert (Open-CliAfterRepairFailure 'repeat') 'repeat fallback failed'
  Assert ($script:launches -eq 1) 'fallback opened duplicate terminals'
  $script:cliFallbackOpened=$false; $script:failLaunch=$true
  Assert (-not (Open-CliAfterRepairFailure 'fixture')) 'CLI failure incorrectly succeeded'
  Assert ($script:stage -eq 'cli-fallback-failed') 'CLI launch failure missing'
}
. (Join-Path $automation 'codex-update-cleanup.ps1')
$requestRoot = Join-Path $testRoot 'cleanup'
$build = Join-Path $requestRoot 'build'
New-Item -ItemType Directory -Path (Join-Path $build 'nested') -Force | Out-Null
$file = Join-Path $build 'nested/a.txt'
[IO.File]::WriteAllText($file, 'generated fixture')
$sentinel = Join-Path $requestRoot 'official-store.msix'
[IO.File]::WriteAllText($sentinel, 'recovery sentinel')
$statePath = Join-Path $testRoot 'state.json'
$id = '0123456789abcdef0123456789abcdef'
[void](Save-UpdateCleanupManifest $requestRoot $id)
[IO.File]::WriteAllText($statePath, (@{authorization_id=$id;status='failed-install'} | ConvertTo-Json))
Assert-Throws { Invoke-VerifiedUpdateCleanup $requestRoot $id $statePath } '*stable successful restart*'
Assert (Test-Path -LiteralPath $file) 'failed repair cleaned build'
[IO.File]::WriteAllText($statePath, (@{authorization_id=$id;status='repair-restart-stable'} | ConvertTo-Json))
[IO.File]::WriteAllText($file, 'user changed fixture')
Assert-Throws { Invoke-VerifiedUpdateCleanup $requestRoot $id $statePath } '*file changed*'
Assert (Test-Path -LiteralPath $file) 'changed file was removed'
[IO.File]::WriteAllText($file, 'generated fixture')
$manifestPath = Join-Path $requestRoot 'cleanup-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifest.files[0].path=$sentinel
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6))
Assert-Throws { Invoke-VerifiedUpdateCleanup $requestRoot $id $statePath } '*invalid cleanup manifest path*'
[void](Save-UpdateCleanupManifest $requestRoot $id)
$result = Invoke-VerifiedUpdateCleanup $requestRoot $id $statePath
Assert ($result.Files -eq 1 -and -not (Test-Path -LiteralPath $build)) 'verified cleanup failed'
Assert ((Get-Content -LiteralPath $sentinel -Raw) -eq 'recovery sentinel') 'cleanup removed recovery artifact'
Write-Output 'UPDATE_SAFETY_PASSED: optional recovery valid install; invalid patch blocked; data backup before Store removal; CLI fallback; deduplication; launch failure; failed-run cleanup; changed file; out-of-scope file; successful cleanup'
Write-Output "Fixture evidence: $testRoot"
