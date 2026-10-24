function Set-CodexCliOverride {
  param([Parameter(Mandatory)][string]$Path)

  $managedPattern = '^' + [regex]::Escape((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\post-update-')) + '\d+\.\d+\.\d+\.\d+\\codex\.exe$'
  if ($Path -notmatch $managedPattern -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw 'CLI override target is not a verified managed runtime path'
  }
  $userValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
  $processValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'Process')
  # Preserve explicit custom overrides, including a process/machine override without a user value.
  if ([string]::IsNullOrWhiteSpace($userValue) -and
      -not [string]::IsNullOrWhiteSpace($processValue) -and $processValue -notmatch $managedPattern) { return }
  $changed = $false
  if (([string]::IsNullOrWhiteSpace($userValue) -or $userValue -match $managedPattern) -and $userValue -ine $Path) {
    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $Path, 'User')
    $userValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
    if ($userValue -ine $Path) { throw 'user CODEX_CLI_PATH readback failed' }
    $changed = $true
  }
  if ([string]::IsNullOrWhiteSpace($processValue) -or $processValue -match $managedPattern) {
    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $userValue, 'Process')
  }
  if ($changed) {
    Publish-UserEnvironmentChange
    Write-Host "User CODEX_CLI_PATH updated: $Path"
  }
}

function Publish-UserEnvironmentChange {
  $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell is required to publish the user environment change: $windowsPowerShell"
  }

  $broadcastScript = @'
$ErrorActionPreference = 'Stop'
if (-not ('Codex.PostUpdate.NativeMethods' -as [type])) {
  Add-Type -TypeDefinition @"
namespace Codex.PostUpdate {
  using System;
  using System.Runtime.InteropServices;

  public static class NativeMethods {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
      IntPtr hWnd,
      uint Msg,
      UIntPtr wParam,
      string lParam,
      uint fuFlags,
      uint uTimeout,
      out UIntPtr lpdwResult
    );
  }
}
"@
}

$result = [UIntPtr]::Zero
[void][Codex.PostUpdate.NativeMethods]::SendMessageTimeout(
  [IntPtr]0xffff,
  0x001A,
  [UIntPtr]::Zero,
  'Environment',
  0x0002,
  5000,
  [ref]$result
)
'@
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($broadcastScript))
  $output = & $windowsPowerShell @(
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass',
    '-EncodedCommand', $encodedCommand
  ) 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "failed to publish the user environment change: $(($output | Out-String).Trim())"
  }
}
