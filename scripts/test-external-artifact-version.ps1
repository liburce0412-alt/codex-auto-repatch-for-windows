$ErrorActionPreference = 'Stop'
$patchPath = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$repairPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'automation\codex-post-update-repair.ps1'
$tokens = $null
$errors = $null
# Windows PowerShell 5.1 otherwise reads no-BOM Chinese source as ANSI.
$ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($patchPath), [ref]$tokens, [ref]$errors)
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
$ForceRebuild = $true
$OnlyModelExperience = $false
$OnlyBundledMarketplaceCopy = $false
$OnlyComputerUseSurface = $false
$OnlyNodeReplProxyEnv = $false
$OnlyComputerUseSurfaceAndProxyEnv = $false
foreach ($case in @(
  @{ Preserve=$true; Install=$true; Scoped=$true; Reject=$true },
  @{ Preserve=$true; Install=$true; Scoped=$false; Reject=$true },
  @{ Preserve=$true; Install=$false; Scoped=$false; Reject=$false },
  @{ Preserve=$true; Install=$false; Scoped=$true; Reject=$false },
  @{ Preserve=$false; Install=$true; Scoped=$false; Reject=$false })) {
  $PreserveSourceVersion=$case.Preserve; $Install=$case.Install; $OnlyBrowserComputerUse=$case.Scoped
  $rejected=$false
  try { . ([scriptblock]::Create($guard.Extent.Text)) } catch { $rejected=$true }
  if ($rejected -ne $case.Reject) { throw 'Invalid direct-install/version combination was not rejected as expected.' }
  $checks++
}
$PreserveSourceVersion = $true; $Install = $false; $OnlyBrowserComputerUse = $false
foreach ($mode in @('OnlyModelExperience','OnlyBundledMarketplaceCopy','OnlyComputerUseSurface','OnlyNodeReplProxyEnv','OnlyComputerUseSurfaceAndProxyEnv','CachedBuild')) {
  if ($mode -eq 'CachedBuild') { $ForceRebuild = $false } else { Set-Variable -Name $mode -Value $true }
  $rejected = $false
  try { . ([scriptblock]::Create($guard.Extent.Text)) } catch { $rejected = $true }
  if (-not $rejected) { throw "Exact-version preparation accepted unsupported mode: $mode" }
  if ($mode -eq 'CachedBuild') { $ForceRebuild = $true } else { Set-Variable -Name $mode -Value $false }
  $checks++
}
foreach ($PreserveSourceVersion in @($true, $false)) {
  $script:increments=0
  . ([scriptblock]::Create($versionChoice.Extent.Text))
  if ($script:increments -ne [int](-not $PreserveSourceVersion)) { throw 'Version increment violated the external-artifact contract.' }
  $checks++
}
$repairAst = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($repairPath), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Automatic repair parse failed.' }
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
$packageArgs = [regex]::Match($repair, '(?s)    \$packageArguments = @\(.*?(?=    \$packageResult =)')
if (-not $packageArgs.Success) { throw 'Automatic preparation argument builders are missing.' }
$sourceCandidate = @{AppPath='fixture-source'}
$OutputRoot = 'fixture-output'
foreach ($PrepareExternalInstall in @($true, $false)) {
  . ([scriptblock]::Create($packageArgs.Value))
  foreach ($arguments in @(,$packageArguments)) {
    if (($arguments -contains '-PreserveSourceVersion') -ne $PrepareExternalInstall -or
        @($arguments | Where-Object { $_ -like '-Only*' -or $_ -eq '-IncludeCustomModelVisibility' }).Count -ne 0 -or
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
# Automatic preparation must run the expensive package producer only once.
$producerCalls = @($repairAst.FindAll({param($n)
  $n -is [Management.Automation.Language.CommandAst] -and
  $n.GetCommandName() -eq 'Invoke-PwshScript' -and
  $n.Extent.Text -match '-ScriptPath \$PatchScript'
}, $true))
if ($producerCalls.Count -ne 1) { throw 'Automatic preparation must have exactly one complete package build.' }
$checks++
$watcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'automation\watch-codex-update-cycle.ps1'
$watcherAst = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($watcherPath), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Automatic watcher parse failed.' }
$scopeGuards = @($repairAst, $watcherAst) | ForEach-Object {
  $_.Find({param($n)
    $n -is [Management.Automation.Language.IfStatementAst] -and
    $n.Extent.Text.StartsWith('if ([string]$authorization.scope', [StringComparison]::OrdinalIgnoreCase)
  }, $true)
}
if (@($scopeGuards).Count -ne 2 -or @($scopeGuards | Where-Object { -not $_ }).Count) { throw 'Full-scope authorization guards are missing.' }
foreach ($scopeGuard in $scopeGuards) {
  foreach ($scope in @('full-non-phone', 'browser-computer-use-plus-custom-model-visibility', 'unknown', '')) {
    $authorization = [pscustomobject]@{scope=$scope}
    $rejected = $false
    try { . ([scriptblock]::Create($scopeGuard.Extent.Text)) } catch { $rejected = $true }
    if ($rejected -eq ($scope -eq 'full-non-phone')) { throw "Incorrect authorization decision for scope: $scope" }
    $checks++
  }
}
$pluginArgs = $repairAst.Find({param($n)
  $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$pluginRepairArguments'
}, $true)
if (-not $pluginArgs) { throw 'Plugin argument builder missing.' }
. ([scriptblock]::Create($pluginArgs.Extent.Text))
if (($pluginRepairArguments -join ',') -ne '-VerifyOnly') { throw 'Automatic full repair retained scoped plugin arguments.' }
$checks++
$automaticCleanup = @($watcherAst.FindAll({param($n)
  $n -is [Management.Automation.Language.CommandAst] -and
  $n.GetCommandName() -in @('Save-UpdateCleanupManifest','Invoke-VerifiedUpdateCleanup','Invoke-CodexHistoryCleanup')
}, $true))
if ($errors.Count -or $automaticCleanup.Count) { throw 'Ordinary/history cleanup must remain separate from automatic installation.' }
$checks++
Write-Output "External artifact version/producer regression passed: checks=$checks"
