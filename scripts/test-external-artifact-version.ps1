$ErrorActionPreference = 'Stop'
$patchPath = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$repairPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'automation\codex-post-update-repair.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($patchPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Patcher parse failed.' }
$guard = $ast.Find({param($n)
  $n -is [Management.Automation.Language.IfStatementAst] -and
  $n.Extent.Text.StartsWith('if ($PreserveSourceVersion -and ($Install')
}, $true)
$versionChoice = $ast.Find({param($n)
  $n -is [Management.Automation.Language.IfStatementAst] -and
  $n.Extent.Text.StartsWith('if ($PreserveSourceVersion)')
}, $true)
if (-not $guard -or -not $versionChoice) { throw 'Exact-artifact version gates are missing.' }
function Fail([string]$Message) { throw $Message }
function Write-Log([string]$Message) { $script:messages.Add($Message) }
function Set-MsixUpdateVersion([string]$ManifestPath) { $script:increments++; '26.924.1866.1' }
$script:messages = [Collections.Generic.List[string]]::new()
$workPackageRoot = $PSScriptRoot
$checks = 0
foreach ($case in @(
  @{ Preserve=$true; Install=$true; Scoped=$true; Reject=$true },
  @{ Preserve=$true; Install=$false; Scoped=$false; Reject=$true },
  @{ Preserve=$true; Install=$false; Scoped=$true; Reject=$false },
  @{ Preserve=$false; Install=$true; Scoped=$false; Reject=$false })) {
  $PreserveSourceVersion=$case.Preserve; $Install=$case.Install; $OnlyBrowserComputerUse=$case.Scoped
  $rejected=$false
  try { . ([scriptblock]::Create($guard.Extent.Text)) } catch { $rejected=$true }
  if ($rejected -ne $case.Reject) { throw 'Invalid direct-install/version combination was not rejected as expected.' }
  $checks++
}
foreach ($PreserveSourceVersion in @($true, $false)) {
  $script:increments=0
  . ([scriptblock]::Create($versionChoice.Extent.Text))
  if ($script:increments -ne [int](-not $PreserveSourceVersion)) { throw 'Version increment violated the external-artifact contract.' }
  $checks++
}
$repairAst = [Management.Automation.Language.Parser]::ParseFile($repairPath, [ref]$tokens, [ref]$errors)
$externalGuard = $repairAst.Find({param($n)
  $n -is [Management.Automation.Language.IfStatementAst] -and
  $n.Extent.Text.StartsWith('if (-not $PrepareExternalInstall)') -and
  $n.Extent.Text.Contains('direct installation is not supported here')
}, $true)
if (-not $externalGuard) { throw 'Automatic repair is missing its external-install contract guard.' }
foreach ($PrepareExternalInstall in @($true, $false)) {
  $rejected=$false
  try { . ([scriptblock]::Create($externalGuard.Extent.Text)) } catch { $rejected=$true }
  if ($rejected -eq $PrepareExternalInstall) { throw 'Automatic repair accepted the direct-install version contract.' }
  $checks++
}
$repair = [IO.File]::ReadAllText($repairPath)
$dryArgs = [regex]::Match($repair, '(?s)    \$dryRunArguments = @\(.*?(?=    \$dryRunResult =)')
$packageArgs = [regex]::Match($repair, '(?s)    \$packageArguments = @\(.*?(?=    \$packageResult =)')
if (-not $dryArgs.Success -or -not $packageArgs.Success) { throw 'Automatic preparation argument builders are missing.' }
$sourceCandidate = @{AppPath='fixture-source'}
$OutputRoot = 'fixture-output'
foreach ($PrepareExternalInstall in @($true, $false)) {
  . ([scriptblock]::Create($dryArgs.Value))
  . ([scriptblock]::Create($packageArgs.Value))
  foreach ($arguments in @($dryRunArguments, $packageArguments)) {
    if (($arguments -contains '-PreserveSourceVersion') -ne $PrepareExternalInstall -or
        $arguments -notcontains '-OnlyBrowserComputerUse' -or
        $arguments -notcontains '-ForceRebuild') { throw 'Automatic scope/version arguments are incorrect.' }
    $checks++
  }
  if (($packageArguments -contains '-Install') -eq $PrepareExternalInstall) { throw 'External preparation may not directly install.' }
  $checks++
}
# Execute the producer's real publication statements against recording stubs.
$producer = [regex]::Match([IO.File]::ReadAllText($patchPath), '(?s)    Invoke-MakeAppxPack \$makeappx.*?Write-Log "patched MSIX: \$msixPath"')
if (-not $producer.Success) { throw 'MSIX producer block not found.' }
function Invoke-MakeAppxPack { $script:messages.Add('pack') }
function Invoke-SignPackage { $script:messages.Add('sign') }
function Test-MsixPayload {
  param($Path)
  $script:messages.Add('payload')
  if ($script:damage) { throw 'Damaged payload fixture' }
  @{Files=1;Blocks=2}
}
$msixPath='fixture.msix'
foreach ($script:damage in @($false,$true)) {
  $script:messages.Clear()
  $rejected=$false
  try { . ([scriptblock]::Create($producer.Value)) } catch { $rejected=$true }
  if ($rejected -ne $script:damage -or ($script:messages[0..2] -join ',') -ne 'pack,sign,payload') { throw 'Payload validation did not follow signing.' }
  if (($script:messages -contains 'patched MSIX: fixture.msix') -eq $script:damage) { throw 'Damaged package was published, or valid package was suppressed.' }
  $checks++
}
Write-Output "External artifact version/producer regression passed: checks=$checks"
