$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$automation = Split-Path -Parent $PSScriptRoot
function Import-Function([string]$File, [string]$Name) {
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $automation $File), [ref]$null, [ref]$null)
  $definition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
  if (-not $definition) { throw "Missing function: $Name" }
  return [scriptblock]::Create($definition.Extent.Text)
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch { if ($_.Exception.Message -like $Pattern) { return }; throw }
  throw "Expected rejection: $Pattern"
}

& {
  . (Import-Function 'invoke-codex-standing-update.ps1' 'Start-CodexPackageAndWait')
  $script:queries = 0
  $script:launches = 0
  function Get-CodexMainProcess { $script:queries++; if ($script:queries -gt 1) { [pscustomobject]@{ProcessId=42} } }
  function Start-CodexCanonicalDesktop { $script:launches++; 'external launcher stdout' }
  function Start-Process { $script:launches++; 'external launcher stdout' }
  function Start-Sleep { }
  $descriptor = [pscustomobject]@{ExecutablePath='fixture'; AppUserModelId='fixture'}
  $result = @(Start-CodexPackageAndWait -Descriptor $descriptor -TimeoutSeconds 1)
  Assert ($result.Count -eq 1 -and $result[0].ProcessId -eq 42) 'Launcher stdout contaminated the returned process'
  [void](Start-CodexPackageAndWait -Descriptor $descriptor -TimeoutSeconds 1)
  Assert ($script:launches -eq 1) 'Already-running Desktop was relaunched'
  function Get-CodexMainProcess { return $null }
  function Start-CodexCanonicalDesktop { throw 'launch failed' }
  function Start-Process { throw 'launch failed' }
  Assert-Throws { Start-CodexPackageAndWait -Descriptor $descriptor -TimeoutSeconds 1 } 'launch failed'
}

& {
  . (Import-Function 'invoke-codex-standing-update.ps1' 'Get-CodexMainProcess')
  function Resolve-CodexPhysicalPath { param($Path) [IO.Path]::GetFullPath($Path) }
  $exe = Join-Path $automation 'fixture.exe'
  function Get-CimInstance {
    [pscustomobject]@{ProcessId=1; ExecutablePath=$exe; CommandLine='ChatGPT.exe --type=renderer'}
    [pscustomobject]@{ProcessId=2; ExecutablePath=$exe; CommandLine='ChatGPT.exe --type gpu-process'}
    [pscustomobject]@{ProcessId=3; ExecutablePath=$exe; CommandLine=$null}
    [pscustomobject]@{ProcessId=4; ExecutablePath=(Join-Path $automation 'old.exe'); CommandLine='ChatGPT.exe'}
    [pscustomobject]@{ProcessId=42; ExecutablePath=$exe; CommandLine='ChatGPT.exe'}
  }
  Assert ((Get-CodexMainProcess -ExactPath $exe).ProcessId -eq 42) 'Selected a renderer, unreadable process or old package'
}

# Substitute the native environment API so no test writes the real user registry.
Add-Type @'
public static class CodexStartupTestEnvironment {
  public static string User;
  public static string Process;
  public static bool RejectWrite;
  public static string GetEnvironmentVariable(string name, string scope) { return scope == "User" ? User : Process; }
  public static void SetEnvironmentVariable(string name, string value, string scope) {
    if (scope == "User") { if (!RejectWrite) User = value; } else Process = value;
  }
}
'@
$root = Join-Path $PSScriptRoot ('startup-fixture-' + [guid]::NewGuid().ToString('N'))
$previousLocal = $env:LOCALAPPDATA
$previousUser = $env:USERPROFILE
try {
  $env:LOCALAPPDATA = Join-Path $root 'local'
  $env:USERPROFILE = Join-Path $root 'user'
  $resources = Join-Path $root 'package\app\resources'
  [void][IO.Directory]::CreateDirectory($resources)
  [void][IO.Directory]::CreateDirectory((Join-Path $env:USERPROFILE '.codex\automation'))
  foreach ($name in @('codex.exe','codex-code-mode-host.exe','codex-command-runner.exe','codex-windows-sandbox-setup.exe')) {
    [IO.File]::WriteAllText((Join-Path $resources $name), "new package $name")
  }
  . (Join-Path $automation 'start-codex-cli-fallback.ps1')
  $setter = (Import-Function 'codex-cli-environment.ps1' 'Set-CodexCliOverride').ToString()
  . ([scriptblock]::Create($setter.Replace('[Environment]', '[CodexStartupTestEnvironment]')))
  $script:broadcasts = 0
  function Publish-UserEnvironmentChange { $script:broadcasts++ }
  function Get-AppxPackage {
    [pscustomobject]@{Version='26.1021.2667.0'; InstallLocation=(Join-Path $root 'package');
      PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Publisher='CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'}
  }
  $old = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\post-update-26.1016.8622.0\codex.exe'
  $expected = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\post-update-26.1021.2667.0\codex.exe'
  [CodexStartupTestEnvironment]::User = $old
  [CodexStartupTestEnvironment]::Process = $old
  $result = @(Initialize-CodexFallbackCli)
  Assert ($result.Count -eq 1 -and $result[0].Path -eq $expected) 'Fallback initializer returned extra output or wrong version'
  Assert ([CodexStartupTestEnvironment]::User -eq $expected -and [CodexStartupTestEnvironment]::Process -eq $expected) 'Upgrade left a stale core before Desktop startup'
  Assert ($script:broadcasts -eq 1) 'New user environment was not published exactly once'
  [CodexStartupTestEnvironment]::Process = $old
  [void](Initialize-CodexFallbackCli)
  Assert ([CodexStartupTestEnvironment]::Process -eq $expected -and $script:broadcasts -eq 1) 'Already-current user value did not refresh stale process environment'

  [CodexStartupTestEnvironment]::User = 'D:\custom-core\codex.exe'
  [CodexStartupTestEnvironment]::Process = $old
  Set-CodexCliOverride -Path $expected
  Assert ([CodexStartupTestEnvironment]::User -eq 'D:\custom-core\codex.exe' -and [CodexStartupTestEnvironment]::Process -eq 'D:\custom-core\codex.exe') 'Explicit custom user override was replaced'
  [CodexStartupTestEnvironment]::User = $null
  Set-CodexCliOverride -Path $expected
  Assert ([string]::IsNullOrWhiteSpace([CodexStartupTestEnvironment]::User) -and [CodexStartupTestEnvironment]::Process -eq 'D:\custom-core\codex.exe') 'Explicit process/machine override was replaced'
  [CodexStartupTestEnvironment]::Process = $null
  Set-CodexCliOverride -Path $expected
  Assert ([CodexStartupTestEnvironment]::User -eq $expected -and [CodexStartupTestEnvironment]::Process -eq $expected) 'Initial managed runtime setup failed'

  [CodexStartupTestEnvironment]::User = $old
  [CodexStartupTestEnvironment]::Process = $old
  [CodexStartupTestEnvironment]::RejectWrite = $true
  Assert-Throws { Set-CodexCliOverride -Path $expected } '*readback failed*'
  [CodexStartupTestEnvironment]::RejectWrite = $false
  Assert-Throws { Set-CodexCliOverride -Path (Join-Path $root 'package\app\resources\codex.exe') } '*managed runtime path*'

  # Failed runtime verification must not publish a new environment value.
  function Get-VerifiedFallbackCli { throw 'fixture verification failed' }
  Assert-Throws { Initialize-CodexFallbackCli } 'fixture verification failed'
  Assert ([CodexStartupTestEnvironment]::User -eq $old -and [CodexStartupTestEnvironment]::Process -eq $old) 'Unverified runtime changed the environment'
} finally {
  $env:LOCALAPPDATA = $previousLocal
  $env:USERPROFILE = $previousUser
  $fullRoot = [IO.Path]::GetFullPath($root)
  if (-not $fullRoot.StartsWith([IO.Path]::GetFullPath($PSScriptRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
  if (Test-Path -LiteralPath $fullRoot) {
    $items = @(Get-Item -LiteralPath $fullRoot) + @(Get-ChildItem -LiteralPath $fullRoot -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Fixture contains a reparse point' }
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
    Assert (-not (Test-Path -LiteralPath $fullRoot)) 'Fixture cleanup failed'
  }
}
Write-Output 'STANDING_STARTUP_PASSED: clean process return; main-process identity; matching CLI before launch; custom overrides preserved; verification/readback failures; fixture removed'
