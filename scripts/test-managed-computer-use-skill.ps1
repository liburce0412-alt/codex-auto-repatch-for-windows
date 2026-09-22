[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$parseErrors = $null
$tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
    Invoke-Expression $statement.Extent.Text
  }
}
$temp = [IO.Path]::GetFullPath($TemporaryRoot)
$root = Join-Path $temp ('managed-cua-skill-' + [guid]::NewGuid().ToString('N'))
Assert-UnderPath $root $temp
$homeRoot = Join-Path $root 'home'
$marketplace = Join-Path $root 'marketplace'
$source = Join-Path $marketplace 'plugins\computer-use'
$cache = Join-Path $homeRoot 'plugins\cache\openai-bundled\computer-use\1.0.0'
$unified = Join-Path $homeRoot 'plugins\cache\openai-bundled\unified-computer-use\1.0.0'
$bin = Join-Path $root 'runtime\bin'
$modules = Join-Path $bin 'node_modules'
$skyRoot = Join-Path $modules '@oai\sky'
$launcher = Join-Path $modules '@oai\cua-repl\bin\cua-repl.mjs'
$node = Join-Path $bin 'node.exe'
$nodeRepl = Join-Path $bin 'node_repl.exe'
$manifest = Join-Path $unified '.mcp.json'
$cases = 0
$runtimeChecks = 0

# Keep the real cache verifier; isolate only unrelated subprocess checks.
function Get-CuaSkyRuntimeRoot { return $skyRoot }
function Get-BundledMarketplacePluginListWithCodexCli { return $pluginList }
function Get-StableBundledMarketplaceRoot { return $marketplace }
function Test-ComputerUseNodeReplContextPatch { }
function Test-ComputerUseRuntimeImport { $script:runtimeChecks++ }
function Get-InstalledChromeBrowserClientTrust { return [pscustomobject]@{ Sha256='fixture'; TrustMode='fixture' } }
function Assert-ChromeBrowserClientTrustedBytes { }
function Write-Log { }
function Verify-Cache { Test-OfficialComputerUseCache $homeRoot $marketplace 'fixture-cli' }
function Expect-Failure([string]$Pattern) {
  try { Verify-Cache } catch {
    if ($_.Exception.Message -notlike $Pattern) { throw }
    $script:cases++
    return
  }
  throw "Expected verification failure: $Pattern"
}
function Save-Manifest { ConvertTo-JsonFile $manifest @{ mcpServers=@{ cua_repl=$server } } }
try {
  foreach ($pluginRoot in @($source, $cache, $unified, (Join-Path $marketplace 'plugins\chrome'))) {
    ConvertTo-JsonFile (Join-Path $pluginRoot '.codex-plugin\plugin.json') @{ name=(Split-Path $pluginRoot -Leaf); version='1.0.0' }
  }
  ConvertTo-JsonFile (Join-Path $unified '.codex-plugin\plugin.json') @{ name='unified-computer-use'; version='1.0.0' }
  Write-Utf8NoBom (Join-Path $source 'skills\computer-use\SKILL.md') 'packaged skill'
  Write-Utf8NoBom (Join-Path $source 'docs\api.md') 'packaged API'
  Write-Utf8NoBom (Join-Path $cache 'docs\api.md') 'packaged API'
  Copy-Item -LiteralPath (Join-Path $source '.codex-plugin\plugin.json') -Destination (Join-Path $cache '.codex-plugin\plugin.json') -Force
  foreach ($path in @($node, $nodeRepl, $launcher,
      (Join-Path $skyRoot 'dist\project\cua\sky_js\src\index.js'),
      (Join-Path $skyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'))) {
    Write-Utf8NoBom $path 'fixture'
  }
  ConvertTo-JsonFile (Join-Path $skyRoot 'package.json') @{ version='0.7.1' }
  $plugin = [pscustomobject]@{ pluginId='unified-computer-use@openai-bundled'; installed=$true; enabled=$true; version='1.0.0' }
  $pluginList = [pscustomobject]@{ installed=@($plugin) }
  $server = [ordered]@{
    command=$node; args=@($launcher); enabled=$true; enabled_tools=@('js','js_reset','turn_ended')
    env=[ordered]@{
      CUA_REPL_ENABLED_SURFACES='browser,computer'
      CUA_REPL_NODE_REPL_PATH=$nodeRepl
      NODE_REPL_NODE_MODULE_DIRS=$modules
      NODE_REPL_TRUSTED_SERVICES='{"sky":"@oai/sky/service"}'
    }
  }
  Save-Manifest
  Verify-Cache
  if (Test-Path -LiteralPath (Join-Path $cache 'skills\computer-use')) { throw 'verification recreated the retired skill' }
  if ($runtimeChecks -ne 1) { throw 'verification skipped the native runtime check' }
  $cases++
  $plugin.enabled=$false
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $plugin.enabled=$true
  $plugin.installed=$false
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $plugin.installed=$true
  $plugin.version='..'
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $plugin.version='1.0.0'
  ConvertTo-JsonFile (Join-Path $unified '.codex-plugin\plugin.json') @{ name='unified-computer-use'; version='0.9.0' }
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  ConvertTo-JsonFile (Join-Path $unified '.codex-plugin\plugin.json') @{ name='unified-computer-use'; version='1.0.0' }
  $server.env.CUA_REPL_ENABLED_SURFACES='browser'; Save-Manifest
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $server.env.CUA_REPL_ENABLED_SURFACES='browser,computer'
  $server.enabled=$false; Save-Manifest
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $server.enabled=$true
  $server.enabled_tools=@('js_reset'); Save-Manifest
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $server.enabled_tools=@('js','js_reset','turn_ended')
  $server.disabled_tools=@('js'); Save-Manifest
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $server.Remove('disabled_tools')
  $server.env.NODE_REPL_TRUSTED_SERVICES='{"browser":"@oai/browser-desktop/service"}'; Save-Manifest
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $server.env.NODE_REPL_TRUSTED_SERVICES='{"sky":"@oai/sky/service"}'
  $server.args=@(Join-Path $root 'retired-runtime\cua-repl.mjs'); Save-Manifest
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $server.args=@($launcher)
  $server.env.CUA_REPL_NODE_REPL_PATH=Join-Path $root 'missing-node-repl.exe'; Save-Manifest
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  $server.env.CUA_REPL_NODE_REPL_PATH=$nodeRepl
  Write-Utf8NoBom $manifest '{invalid-json'
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  Save-Manifest
  Write-Utf8NoBom (Join-Path $cache 'docs\api.md') 'changed API'
  Expect-Failure '*changed:docs\api.md*'
  Write-Utf8NoBom (Join-Path $cache 'docs\api.md') 'packaged API'
  Write-Utf8NoBom (Join-Path $source 'docs\missing.md') 'additional packaged API'
  Expect-Failure '*missing:docs\missing.md*'
  Write-Utf8NoBom (Join-Path $cache 'docs\missing.md') 'additional packaged API'
  New-Item -ItemType Directory -Path (Join-Path $cache 'skills\computer-use') -Force | Out-Null
  Expect-Failure '*missing:skills\computer-use\SKILL.md*'
  Write-Utf8NoBom (Join-Path $cache 'skills\computer-use\SKILL.md') 'changed skill'
  Expect-Failure '*changed:skills\computer-use\SKILL.md*'
  Write-Utf8NoBom (Join-Path $cache 'skills\computer-use\SKILL.md') 'packaged skill'
  $plugin.enabled=$false
  Verify-Cache
  $cases++
  Write-Output "MANAGED_CUA_SKILL_TESTS_PASSED cases=$cases"
} finally {
  Assert-UnderPath $root $temp
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
