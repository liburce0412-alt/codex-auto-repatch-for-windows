# Functions only; launching is explicit so read-only validation can import this.
function Initialize-CodexFallbackCli {
  $package = Get-AppxPackage -Name OpenAI.Codex -PackageTypeFilter Main | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $package -or $package.PackageFamilyName -ne 'OpenAI.Codex_2p2nqsd0c76g0' -or
      $package.Publisher -ne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B') { throw 'expected Codex package is not installed' }
  $root = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\post-update-$($package.Version)"
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  $hashes = @{}
  foreach ($name in @('codex.exe','codex-code-mode-host.exe','codex-command-runner.exe','codex-windows-sandbox-setup.exe')) {
    $source = Join-Path $package.InstallLocation "app\resources\$name"
    $destination = Join-Path $root $name
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if (-not (Test-Path -LiteralPath $destination) -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) {
      # Byte-copy avoids propagating WindowsApps encryption attributes.
      $temporary = "$destination.$PID.tmp"
      [IO.File]::WriteAllBytes($temporary, [IO.File]::ReadAllBytes($source))
      if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $hash) { throw 'independent CLI copy verification failed' }
      [IO.File]::Move($temporary, $destination, $true)
    }
    $hashes[$name] = $hash
  }
  $statePath = Join-Path $env:USERPROFILE '.codex\automation\post-update-state.json'
  $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
  $state['stable_cli_path'] = Join-Path $root 'codex.exe'
  $state['stable_cli_sha256'] = $hashes['codex.exe']
  $state['stable_cli_runtime_hashes'] = $hashes
  [IO.File]::WriteAllText("$statePath.$PID.tmp", ($state | ConvertTo-Json -Depth 12))
  [IO.File]::Move("$statePath.$PID.tmp", $statePath, $true)
  return Get-VerifiedFallbackCli
}

function Get-VerifiedFallbackCli {
  $statePath = Join-Path $env:USERPROFILE '.codex\automation\post-update-state.json'
  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  $path = [IO.Path]::GetFullPath([string]$state.stable_cli_path)
  $binRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'))
  if (-not $path.StartsWith($binRoot + '\post-update-', [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($path) -ne 'codex.exe' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw 'stable Codex CLI path is missing or outside the independent runtime directory'
  }
  $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
  if ($hash -ne [string]$state.stable_cli_sha256) { throw 'stable Codex CLI hash changed' }
  foreach ($name in @('codex-code-mode-host.exe','codex-command-runner.exe','codex-windows-sandbox-setup.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $path) $name) -PathType Leaf)) { throw "stable CLI companion missing: $name" }
    if ($state.PSObject.Properties['stable_cli_runtime_hashes'] -and
        (Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $path) $name) -Algorithm SHA256).Hash -ne $state.stable_cli_runtime_hashes.$name) { throw "stable CLI companion hash changed: $name" }
  }
  return [pscustomobject]@{ Path=$path; Sha256=$hash }
}

function Start-CodexCliFallbackTerminal {
  param([Parameter(Mandatory)][string]$PwshPath, [string]$Reason, [string]$LogPath)
  $cli = Get-VerifiedFallbackCli
  $launcher = Join-Path $env:USERPROFILE '.codex\automation\open-codex-cli-fallback.ps1'
  $arguments = @('-NoProfile','-NoExit','-File',('"{0}"' -f $launcher),
    '-CliPath',('"{0}"' -f $cli.Path),'-CliSha256',$cli.Sha256,
    '-Reason',('"{0}"' -f ($Reason -replace '["\r\n]',' ')), '-LogPath',('"{0}"' -f $LogPath))
  # Explicitly requested interactive CLI terminal; no prompt or model override.
  $process = Start-Process -FilePath $PwshPath -ArgumentList $arguments -WorkingDirectory $env:USERPROFILE -WindowStyle Normal -PassThru
  return [pscustomobject]@{ TerminalId=$process.Id; CliPath=$cli.Path }
}
