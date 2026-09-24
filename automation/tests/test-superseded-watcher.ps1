$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'watch-codex-update-cycle.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Watcher syntax failed' }
$definition = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-MonitorHasCurrentRecord'}, $true)
Invoke-Expression $definition.Extent.Text
$fixture = Join-Path $PSScriptRoot ('fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$authorizationPath = Join-Path $fixture 'active.json'
$authorizationLastPath = Join-Path $fixture 'last.json'
$installHandoffPath = Join-Path $fixture 'pending.json'
$AuthorizationId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
function Check([bool]$Expected) {
  if ((Test-MonitorHasCurrentRecord) -ne $Expected) { throw 'Unexpected record ownership decision' }
}
Check $false
'{"authorization_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' | Set-Content $authorizationLastPath
Check $false
'{"authorization_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' | Set-Content $authorizationPath
Check $true
'{"authorization_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' | Set-Content $authorizationPath
'{"authorization_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"consumed"}' | Set-Content $authorizationLastPath
Check $true
'{"authorization_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' | Set-Content $authorizationLastPath
'{}' | Set-Content $installHandoffPath
Check $true
'invalid json' | Set-Content $authorizationPath
$threw = $false
try { Test-MonitorHasCurrentRecord | Out-Null } catch { $threw = $true }
if (-not $threw) { throw 'Corrupt authorization must fail closed' }
'SUPERSEDED_WATCHER_TESTS_PASSED cases=6'
