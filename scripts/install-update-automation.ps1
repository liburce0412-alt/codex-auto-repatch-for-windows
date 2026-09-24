[CmdletBinding()]
param([switch]$EnableAutomation)
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$expectedRoot = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch'
if (-not [IO.Path]::GetFullPath($skillRoot).TrimEnd('\').Equals([IO.Path]::GetFullPath($expectedRoot).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
  throw "Install the repository at $expectedRoot before enabling automation."
}
if ($PSVersionTable.PSVersion -lt [version]'7.5') { throw 'PowerShell 7.5 or later is required' }
$source = Join-Path $skillRoot 'automation'
$destination = Join-Path $env:USERPROFILE '.codex\automation'
$backup = Join-Path $env:USERPROFILE ('.codex\backups\post-update-automation\scripts-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $destination -Force | Out-Null
# Hold both executor locks through deployment. Never replace a running worker.
$locks = @()
try {
  foreach ($name in @('standing-update-active.lock','update-cycle-active.lock','post-update-repair.lock')) {
    $locks += [IO.File]::Open((Join-Path $destination $name), 'OpenOrCreate', 'ReadWrite', 'None')
  }
  $files = @(Get-ChildItem -LiteralPath $source -Filter '*.ps1' -File)
  foreach ($file in $files) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "invalid automation source: $($file.Name)" }
  }
  foreach ($file in $files) {
    $target = Join-Path $destination $file.Name
    if (Test-Path -LiteralPath $target) {
      New-Item -ItemType Directory -Path $backup -Force | Out-Null
      Copy-Item -LiteralPath $target -Destination (Join-Path $backup $file.Name)
    }
    Copy-Item -LiteralPath $file.FullName -Destination $target
    if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw "automation deployment hash mismatch: $($file.Name)" }
  }
  . (Join-Path $destination 'start-codex-cli-fallback.ps1')
  $cli = Initialize-CodexFallbackCli
  & $cli.Path --version
  if ($LASTEXITCODE -ne 0) { throw 'independent CLI startup check failed' }
  Write-Host "Automation scripts installed: $destination"
  Write-Host "Previous scripts retained: $backup"
} finally {
  foreach ($lock in $locks) { $lock.Dispose() }
}
if ($EnableAutomation) {
  & (Join-Path $destination 'grant-codex-standing-update-authorization.ps1')
} else {
  Write-Host 'Existing scheduled-task authorization is unchanged. Use -EnableAutomation for initial registration.'
}
