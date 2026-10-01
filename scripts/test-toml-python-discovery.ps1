[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\toml-config.ps1')
$checks = 0
$originalExitCode = $global:LASTEXITCODE
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:checks++
}

# Mock command discovery and process results, without changing PATH or config.
try { & {
  $script:available = @('python', 'python3', 'py')
  $script:ready = 'py'
  $script:validationExit = 0
  $script:probes = @()
  $script:warnings = @()
  function Write-Log([string]$Message) { $script:warnings += $Message }
  function Get-Command([string]$Name) {
    if ($script:available -contains $Name) { [pscustomobject]@{ Source = "Test-$Name" } }
  }
  function Invoke-TestPython([string]$Name, [object[]]$Arguments) {
    if ($Arguments[-1] -like '*CODEX_TOMLLIB_READY*') {
      $script:probes += $Name
      $global:LASTEXITCODE = 9009
      if ($script:ready -eq $Name) {
        if ($Name -eq 'py') { Assert ($Arguments[0] -eq '-3') 'Launcher did not select Python 3' }
        $global:LASTEXITCODE = 0
        'CODEX_TOMLLIB_READY'
      }
    } else {
      $global:LASTEXITCODE = $script:validationExit
    }
  }
  function Test-python { Invoke-TestPython 'python' $args }
  function Test-python3 { Invoke-TestPython 'python3' $args }
  function Test-py { Invoke-TestPython 'py' $args }

  Test-CodexTomlContent 'enabled = true'
  Assert (($script:probes -join ',') -eq 'python,python3,py') 'Broken aliases did not fall back to py'
  Assert ($script:warnings.Count -eq 0) 'Working fallback was skipped'
  $script:ready = 'python3'
  Assert ((Resolve-CodexTomlPython).Path -eq 'Test-python3') 'python3 fallback failed'
  $script:ready = 'python'
  Assert ((Resolve-CodexTomlPython).Path -eq 'Test-python') 'Primary interpreter failed'

  $script:validationExit = 86
  $message = ''
  try { Test-CodexTomlContent 'broken = [' } catch { $message = $_.Exception.Message }
  Assert ($message -like 'TOML syntax validation failed*') 'Invalid TOML was accepted'
  $script:validationExit = 9009
  $message = ''
  try { Test-CodexTomlContent 'enabled = true' } catch { $message = $_.Exception.Message }
  Assert ($message -like 'TOML validator execution failed*') 'Runtime failure was reported as invalid TOML'
  $script:validationExit = 1
  $message = ''
  try { Test-CodexTomlContent 'enabled = true' } catch { $message = $_.Exception.Message }
  Assert ($message -like 'TOML validator execution failed*') 'Generic Python failure was reported as invalid TOML'

  $script:ready = ''
  Test-CodexTomlContent 'enabled = true'
  Assert ($script:warnings[-1] -like '*no working Python with tomllib*') 'Missing parser warning not emitted'
  $script:available = @()
  Test-CodexTomlContent 'enabled = true'
  Assert ($script:warnings.Count -eq 2) 'Missing executables were not handled'
} } finally { $global:LASTEXITCODE = $originalExitCode }
Write-Output "TOML_PYTHON_DISCOVERY_PASSED checks=$checks"
