param()
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'),
  [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Recoverable runner failed to parse.' }
$launch = $ast.Find({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -eq 'Start-AndValidateCodex'
}, $true)
. ([scriptblock]::Create($launch.Extent.Text))
function Write-Log { param($Message) }
function Start-Process { param($FilePath, $ArgumentList) }
function Start-Sleep {
  param($Milliseconds, $Seconds)
  $script:now = $script:now.AddMinutes(1)
}
function Get-Date { $script:now }
function Get-AppxPackageManifest {
  param($Package)
  [xml]'<Package><Applications><Application Id="App" Executable="app\ChatGPT.exe"/></Applications></Package>'
}
function Resolve-RepairPhysicalPath {
  param($Path)
  $Path.Replace('C:\registered\pkg', 'D:\physical\pkg')
}
function Get-Process { param($Name, $ErrorAction) $script:candidate }
$package = [pscustomobject]@{
  InstallLocation = 'C:\registered\pkg'
  PackageFamilyName = 'fixture'
  Version = [version]'1.0.0.0'
}
foreach ($case in @(
  @{ Path='D:\physical\pkg\app\ChatGPT.exe'; Window=1; Responding=$true; Accept=$true },
  @{ Path='D:\other\app\ChatGPT.exe'; Window=1; Responding=$true; Accept=$false },
  @{ Path='D:\physical\pkg\app\ChatGPT.exe'; Window=0; Responding=$true; Accept=$false },
  @{ Path='D:\physical\pkg\app\ChatGPT.exe'; Window=1; Responding=$false; Accept=$false }
)) {
  $script:now = [datetime]'2026-01-01'
  $script:candidate = [pscustomobject]@{
    Path=$case.Path; Id=123; HasExited=$false
    MainWindowHandle=$case.Window; Responding=$case.Responding
  }
  $script:candidate | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
  $accepted = $true
  try { Start-AndValidateCodex -Package $package -PatchedVersion ([version]'1.0.0.1') -CliPath 'unused' }
  catch {
    if ($_.Exception.Message -notlike 'Codex did not start from the installed package path:*') { throw }
    $accepted = $false
  }
  if ($accepted -ne $case.Accept) {
    throw "Launch path acceptance was incorrect: $($case | ConvertTo-Json -Compress)"
  }
}
Write-Output 'Recoverable launch accepts responsive physical aliases and rejects other packages or unusable windows.'
