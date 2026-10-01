function ConvertTo-CodexTomlString {
  param([AllowEmptyString()][string]$Value)

  if ($Value -notmatch "['\x00-\x1f\x7f]") {
    return "'$Value'"
  }
  # TOML literal strings cannot escape apostrophes; use a basic string instead.
  $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
  $escaped = [regex]::Replace($escaped, '[\x00-\x1f\x7f]', {
    param($match)
    return '\u{0:x4}' -f [int][char]$match.Value
  })
  return '"' + $escaped + '"'
}

function Resolve-CodexTomlPython {
  # A Windows App Execution Alias can exist without a working interpreter.
  # Probe the parser before passing any configuration to the process.
  foreach ($name in @('python', 'python3', 'py')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { continue }
    $arguments = @()
    if ($name -eq 'py') { $arguments = @('-3') }
    try {
      $probe = & $command.Source @arguments -c 'import tomllib; print("CODEX_TOMLLIB_READY")' 2>$null
      if ($LASTEXITCODE -eq 0 -and $probe -contains 'CODEX_TOMLLIB_READY') {
        return [pscustomobject]@{ Path = $command.Source; Arguments = $arguments }
      }
    } catch {
      # Try the next interpreter if this launcher cannot start Python/tomllib.
    }
  }
  return $null
}

function Test-CodexTomlContent {
  param([AllowEmptyString()][string]$Content)

  $python = Resolve-CodexTomlPython
  if (-not $python) {
    Write-Log 'warning: no working Python with tomllib found; skipping TOML syntax validation'
    return
  }
  $arguments = $python.Arguments
  $validator = @'
import sys
import tomllib
try:
    tomllib.loads(sys.stdin.buffer.read().decode('utf-8'))
except (ValueError, UnicodeError):
    sys.exit(86)
'@
  $oldEncoding = $OutputEncoding
  $oldPreference = $ErrorActionPreference
  try {
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    $ErrorActionPreference = 'Continue'
    $null = $Content | & $python.Path @arguments -c $validator 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $OutputEncoding = $oldEncoding
    $ErrorActionPreference = $oldPreference
  }
  if ($exitCode -eq 86) {
    throw 'TOML syntax validation failed; configuration was not written.'
  }
  if ($exitCode -ne 0) {
    throw "TOML validator execution failed (exit $exitCode); configuration was not written."
  }
}
