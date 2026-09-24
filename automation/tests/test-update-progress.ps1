$ErrorActionPreference = 'Stop'
$automation = Split-Path -Parent $PSScriptRoot
$root = Join-Path $PSScriptRoot ('progress-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$journal = Join-Path $root 'progress.log'
$child = Join-Path $root 'child.log'
$nested = Join-Path $root 'nested.log'
$output = Join-Path $root 'viewer.log'
foreach ($path in @($journal,$child,$nested)) { [IO.File]::WriteAllText($path, '') }
function Event([hashtable]$Value) { [IO.File]::AppendAllText($journal, (($Value | ConvertTo-Json -Compress) + "`n")) }
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = (Get-Command pwsh.exe).Source
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
foreach ($arg in @('-NoProfile','-File',(Join-Path $automation 'show-codex-update-progress.ps1'),
  '-JournalPath',$journal,'-LogRoot',$root,'-MonitorId',"$PID",'-MonitorStartTicks',"$((Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)",'-NoPause')) { [void]$info.ArgumentList.Add($arg) }
$viewer = [Diagnostics.Process]::new()
$viewer.StartInfo = $info
$stream = [IO.FileStream]::new($output,'Create','Write','Read',1)
try {
  [void]$viewer.Start()
  $copy = $viewer.StandardOutput.BaseStream.CopyToAsync($stream)
  $errors = $viewer.StandardError.ReadToEndAsync()
  Event @{kind='stage';time='test';text='FIXTURE_STAGE'}
  Event @{kind='follow';paths=@($child)}
  [IO.File]::AppendAllText($child, ('[CODEX_PROGRESS_LOG] ' + (@{paths=@($nested)} | ConvertTo-Json -Compress) + "`n"))
  [IO.File]::AppendAllText($nested, "LIVE_NESTED_OUTPUT`n")
  $deadline = [datetime]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 100
    $reader = [IO.StreamReader]::new([IO.File]::Open($output,'Open','Read','ReadWrite'))
    try { $shown=$reader.ReadToEnd() } finally { $reader.Dispose() }
  } while (-not $shown.Contains('LIVE_NESTED_OUTPUT') -and [datetime]::UtcNow -lt $deadline)
  if (-not $shown.Contains('LIVE_NESTED_OUTPUT') -or $viewer.HasExited) { throw "nested output was not shown live before completion: $shown" }
  Event @{kind='done';exit_code=7;text='FIXTURE_FAILED_STORE_PRESERVED'}
  if (-not $viewer.WaitForExit(10000)) { throw 'viewer did not exit after completion' }
  $copy.GetAwaiter().GetResult()
  $stream.Flush()
  if ($viewer.ExitCode -ne 0 -or $errors.GetAwaiter().GetResult()) { throw 'viewer process failed' }
} finally {
  if (-not $viewer.HasExited) { $viewer.Kill() }
  $viewer.Dispose(); $stream.Dispose()
}
$shown = Get-Content -LiteralPath $output -Raw
if (-not $shown.Contains('FIXTURE_FAILED_STORE_PRESERVED')) { throw 'failure result missing' }
if (-not (Get-Process -Id $PID)) { throw 'viewer affected worker' }
Write-Output 'LIVE_PROGRESS_PASSED: stage, nested child stdout before completion, failure result, worker unaffected'
