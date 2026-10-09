[CmdletBinding()]
param(
  [string]$HelperPath,
  [string]$OutputRoot,
  [switch]$BuildTargetOnly,
  [switch]$RunCapture,
  [switch]$TestInput
)

$ErrorActionPreference = 'Stop'
if ($BuildTargetOnly -and $RunCapture) { throw 'Choose -BuildTargetOnly or -RunCapture' }
if ($TestInput -and -not $RunCapture) { throw '-TestInput requires -RunCapture' }
$patcher = Join-Path $PSScriptRoot 'patch-computer-use-helper-win10.ps1'
$source = @(& $patcher -HelperPath $HelperPath) | Select-Object -Last 1
$source | Select-Object Profile, SkyVersion, WindowsBuild, State, Sha256, EndToEndValidatedDesktopVersion
if (-not $RunCapture -and -not $BuildTargetOnly) { return }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw 'An explicit -OutputRoot is required' }
if ($RunCapture) {
  $os = Get-CimInstance Win32_OperatingSystem
  if ($source.WindowsBuild -lt 10240 -or $source.WindowsBuild -ge 22000 -or $os.ProductType -ne 1) {
    throw 'Capture diagnostics require a Windows 10 client guest/test machine; Windows 11 and Server are rejected'
  }
  if (-not [Environment]::UserInteractive) { throw 'An interactive guest console is required' }
  if ($source.State -ne 'original-patchable' -or $source.SkyVersion -ne '0.7.6') {
    throw 'This before/after diagnostic requires a supported original @oai/sky 0.7.6 helper'
  }
}

$runRoot = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ('capture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$targetExe = Join-Path $runRoot 'CodexWin10CaptureTest.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework x64 C# compiler is unavailable' }
& $compiler /nologo /target:winexe /platform:x64 /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll "/out:$targetExe" (Join-Path $PSScriptRoot 'lib\win10-capture-target.cs')
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic target compilation failed' }
if ($BuildTargetOnly) { Write-Output "Target compiled without launching: $targetExe"; return }

$skyRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $source.HelperPath))
$runtimeBin = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $skyRoot))
$nodePath = Join-Path $runtimeBin 'node.exe'
if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) { throw 'The selected runtime Node executable is unavailable' }
$fixtureSky = Join-Path $runRoot 'fixture\sky'
$fixtureHelper = Join-Path $fixtureSky 'bin\windows\codex-computer-use.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $fixtureHelper) -Force | Out-Null
Copy-Item -LiteralPath $source.HelperPath -Destination $fixtureHelper
Copy-Item -LiteralPath (Join-Path $skyRoot 'package.json') -Destination (Join-Path $fixtureSky 'package.json')
$fixtureHome = Join-Path $runRoot 'patch-backups'
$token = [guid]::NewGuid().ToString('N')
$target = $null
$report = [ordered]@{
  windowsBuild = $source.WindowsBuild; skyVersion = $source.SkyVersion
  osCaption = $os.Caption; osVersion = $os.Version
  desktopVersion = $source.CurrentDesktopVersion
  displayAdapters = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, VideoModeDescription)
  originalSha256 = $source.Sha256; patchedSha256 = $null
  sourceUnchanged = $false; rollbackPassed = $false
  visualInspection = 'pending'; endToEndValidatedDesktopVersion = $null
}
try {
  Write-Host 'Opening a dedicated test window in this Win10 guest. Focus loss, Escape, or closing it stops the test.'
  Write-Host "Input testing enabled: $([bool]$TestInput). Original Desktop helper and config will not be changed."
  $targetArguments = '"{0}" {1}' -f $runRoot, $token
  $target = Start-Process -FilePath $targetExe -ArgumentList $targetArguments -WindowStyle Normal -PassThru
  $statePath = Join-Path $runRoot 'target-state.json'
  $deadline = (Get-Date).AddSeconds(10)
  while (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    if ($target.HasExited -or (Get-Date) -gt $deadline) { throw 'The diagnostic target did not start' }
    Start-Sleep -Milliseconds 100
  }
  $configuration = [ordered]@{
    runRoot = $runRoot; token = $token; targetProcessId = $target.Id
    skyRoot = $skyRoot; helperPath = $fixtureHelper; testInput = [bool]$TestInput
  }
  $configurationPath = Join-Path $runRoot 'driver-config.json'
  [IO.File]::WriteAllText($configurationPath, ($configuration | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  $driver = Join-Path $PSScriptRoot 'win10-helper-capture-driver.cjs'
  & $nodePath $driver $configurationPath original
  if ($LASTEXITCODE -ne 0) { throw 'The original diagnostic stopped; no further capture will run' }
  & $patcher -HelperPath $fixtureHelper -CodexHome $fixtureHome -Install
  $report.patchedSha256 = (Get-FileHash -LiteralPath $fixtureHelper -Algorithm SHA256).Hash
  & $nodePath $driver $configurationPath patched
  if ($LASTEXITCODE -ne 0) { throw 'Patched capture did not pass; see patched-result.json' }
  Add-Type -AssemblyName System.Drawing
  foreach ($phase in @('original', 'patched')) {
    $phasePath = Join-Path $runRoot "$phase-result.json"
    $phaseResult = Get-Content -Raw -LiteralPath $phasePath | ConvertFrom-Json
    foreach ($frame in $phaseResult.frames) {
      $image = [Drawing.Image]::FromFile((Join-Path $runRoot $frame.file))
      try {
        $frame | Add-Member -NotePropertyName width -NotePropertyValue $image.Width
        $frame | Add-Member -NotePropertyName height -NotePropertyValue $image.Height
      } finally { $image.Dispose() }
    }
    [IO.File]::WriteAllText($phasePath, ($phaseResult | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $report[$phase] = $phaseResult
  }
} finally {
  if ($target -and -not $target.HasExited) {
    if ($target.CloseMainWindow()) { $null = $target.WaitForExit(3000) }
    if (-not $target.HasExited) { $target.Kill(); $null = $target.WaitForExit(3000) }
  }
  if ((Get-FileHash -LiteralPath $fixtureHelper -Algorithm SHA256).Hash -ne $source.Sha256) {
    & $patcher -HelperPath $fixtureHelper -CodexHome $fixtureHome -Rollback
  }
  $report.rollbackPassed = (Get-FileHash -LiteralPath $fixtureHelper -Algorithm SHA256).Hash -eq $source.Sha256
  $report.sourceUnchanged = (Get-FileHash -LiteralPath $source.HelperPath -Algorithm SHA256).Hash -eq $source.Sha256
  [IO.File]::WriteAllText((Join-Path $runRoot 'report.json'), ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
  Write-Output "Evidence saved at: $runRoot"
}
