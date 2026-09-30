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

function Test-CodexTomlContent {
  param([AllowEmptyString()][string]$Content)

  $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    Write-Log 'warning: python not found; skipping tomllib syntax validation'
    return
  }
  $validator = @'
import sys
try:
    import tomllib
except ImportError:
    sys.exit(42)
try:
    tomllib.loads(sys.stdin.buffer.read().decode('utf-8'))
except (ValueError, UnicodeError):
    sys.exit(1)
'@
  $oldEncoding = $OutputEncoding
  $oldPreference = $ErrorActionPreference
  try {
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    $ErrorActionPreference = 'Continue'
    $null = $Content | & $python.Source -c $validator 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $OutputEncoding = $oldEncoding
    $ErrorActionPreference = $oldPreference
  }
  if ($exitCode -eq 42) {
    Write-Log 'warning: python has no tomllib; skipping TOML syntax validation'
    return
  }
  if ($exitCode -ne 0) {
    throw 'TOML syntax validation failed; configuration was not written.'
  }
}
