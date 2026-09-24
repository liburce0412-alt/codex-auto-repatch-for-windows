param([string]$EncryptedSourcePath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'codex-appdata-backup.ps1')
$root = Join-Path $PSScriptRoot ('fixture-data-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$snapshot = Join-Path $root 'backup'
$restored = Join-Path $root 'restored'
New-Item -ItemType Directory -Path (Join-Path $source 'LocalCache\nested'),(Join-Path $source 'Settings'),(Join-Path $source 'SystemAppData') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $source 'LocalCache\nested\example'), 'sample user data')
[IO.File]::WriteAllText((Join-Path $source 'Settings\sample.dat'), 'settings fixture')
[IO.File]::WriteAllText((Join-Path $source 'SystemAppData\system.dat'), 'system fixture')
[IO.File]::WriteAllBytes((Join-Path $source 'LocalCache\empty'), [byte[]]@())
if ($EncryptedSourcePath) {
  if (-not ((Get-Item -LiteralPath $EncryptedSourcePath).Attributes -band [IO.FileAttributes]::Encrypted)) { throw 'encrypted regression source is not encrypted' }
  $encryptedHash = (Get-FileHash -LiteralPath $EncryptedSourcePath).Hash
  Copy-CodexDataContent $EncryptedSourcePath (Join-Path $source 'LocalCache\encrypted-content')
  if ((Get-FileHash -LiteralPath (Join-Path $source 'LocalCache\encrypted-content')).Hash -ne $encryptedHash) { throw 'encrypted source content copy mismatch' }
}
Save-CodexAppDataBackup $source $snapshot 'fixture-package'
New-Item -ItemType Directory -Path (Join-Path $restored 'Settings') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $restored 'Settings\sample.dat'), 'longer stale destination content to truncate')
Restore-CodexAppDataBackup $restored $snapshot
if ((Get-Content (Join-Path $restored 'LocalCache\nested\example') -Raw) -ne 'sample user data') { throw 'data was not restored' }
if ((Get-Content (Join-Path $restored 'Settings\sample.dat') -Raw) -ne 'settings fixture') { throw 'settings were not restored' }
if (Test-Path (Join-Path $restored 'SystemAppData\system.dat')) { throw 'OS-owned deployment metadata was restored' }
if ((Get-Item -LiteralPath (Join-Path $restored 'LocalCache\empty')).Length -ne 0) { throw 'empty file was not restored' }
if ($EncryptedSourcePath) {
  if ((Get-FileHash -LiteralPath (Join-Path $restored 'LocalCache\encrypted-content')).Hash -ne $encryptedHash -or
      (Get-FileHash -LiteralPath $EncryptedSourcePath).Hash -ne $encryptedHash) { throw 'encrypted content round-trip mismatch or source modified' }
  'ENCRYPTED_CONTENT_PASSED: encrypted source copied and restored with matching hashes; source unchanged'
}
function Reject([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch { if ($_.Exception.Message -like $Pattern) { return }; throw }
  throw "expected rejection: $Pattern"
}
Reject { Save-CodexAppDataBackup $source $snapshot 'fixture-package' } '*already exists*'
Reject { Copy-CodexDataContent (Join-Path $source 'Settings\sample.dat') (Join-Path $snapshot 'Settings\sample.dat') } '*'
if ((Get-Content -LiteralPath (Join-Path $snapshot 'Settings\sample.dat') -Raw) -ne 'settings fixture') { throw 'content copy overwrote existing backup' }
Reject { Assert-CodexDataPath $snapshot '..\outside' } '*escaped*'
New-Item -ItemType Junction -Path (Join-Path $source 'LocalCache\unexpected') -Target $restored | Out-Null
Reject { Save-CodexAppDataBackup $source (Join-Path $root 'reparse-backup') 'fixture-package' } '*reparse point*'
[IO.File]::WriteAllText((Join-Path $snapshot 'Settings\sample.dat'), 'corrupted')
$untouched = Join-Path $root 'must-remain-absent'
Reject { Restore-CodexAppDataBackup $untouched $snapshot } '*content changed*'
if (Test-Path $untouched) { throw 'restore wrote files before validating the whole backup' }
'APPDATA_BACKUP_PASSED: content round-trip; system metadata retained only; no overwrite of snapshot; traversal blocked; junction blocked; corruption rejected before restore'
