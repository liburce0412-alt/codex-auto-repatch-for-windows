param()
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'install-computer-use-local.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Installer failed to parse.' }
$install = $ast.Find({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-ComputerUse'
}, $true)
. ([scriptblock]::Create($install.Extent.Text))
$CodexHome = 'C:\fixture\home'
function Resolve-OrCreateDirectory { param($Path) $Path }
function Get-StableBundledMarketplaceRoot { param($Path) 'C:\fixture\stable' }
function Get-ReservedBundledMarketplaceRoot { param($Path) 'C:\fixture\reserved' }
function Get-InstalledBundledMarketplaceRoot { 'C:\fixture\installed' }
function Get-InstalledChromeBrowserClientTrust { param($Path) }
function Get-CurrentCodexAppServerRuntimeInventory {}
function Assert-UnderPath { param($Path, $Parent) }
function Remove-StaleChromeNativeHostEntries {}
function Repair-ComputerUseNodeReplContext {}
function Patch-ChromeWindowsRegistryParsing { param($Path, $Trust) }
function Write-PluginTree { param($Path) }
function Update-BundledMarketplaceManifest { param($Path) }
function Test-BundledMarketplaceRootUsable { param($Path) $true }
function Sync-BundledMarketplaceFromInstalledApp {
  param($MarketplaceRoot, $SourceRoot)
  if ($SourceRoot -ne 'C:\fixture\installed') { throw 'Wrong package source.' }
  $script:versions[$MarketplaceRoot] = 'current'
}
function Test-ScopedBundledMarketplaceCopy {
  param($MarketplaceRoot, $InstalledMarketplaceRoot, $Description)
  if ($script:versions[$MarketplaceRoot] -ne 'current') {
    throw "CLI marketplace remains stale before registration: $Description"
  }
}
# Stop after the real synchronization prefix, before any config or CLI writes.
function Update-CodexConfig { param($MarketplaceRoot) throw 'fixture-complete' }
foreach ($BrowserComputerUseOnly in @($true, $false)) {
  $script:versions = @{ 'C:\fixture\stable'='old'; 'C:\fixture\reserved'='old' }
  $completed = $false
  try { Install-ComputerUse }
  catch {
    if ($_.Exception.Message -ne 'fixture-complete') { throw }
    $completed = $true
  }
  if (-not $completed) { throw 'Synchronization did not reach the registration boundary.' }
}
Write-Output 'Both scoped and full repair refresh the CLI marketplace before registration.'
