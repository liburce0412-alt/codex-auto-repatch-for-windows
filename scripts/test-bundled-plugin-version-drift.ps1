[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $scriptRoot 'install-computer-use-local.ps1'
$parseErrors = $null
$tokens = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $installer,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
  throw "Installer has PowerShell parse errors: $($parseErrors.Message -join '; ')"
}

foreach ($statement in $installerAst.EndBlock.Statements) {
  if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
    Invoke-Expression $statement.Extent.Text
  }
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ("bundled-plugin-version-drift-" + [Guid]::NewGuid().ToString('N'))
$installedRoot = Join-Path $fixtureRoot 'installed'
$stableRoot = Join-Path $fixtureRoot 'stable'

function Set-FixtureMarketplace {
  param(
    [string]$Root,
    [string]$Version,
    [string]$PublicationPolicy
  )

  $descriptorRoot = Join-Path $Root 'plugins\fixture\.codex-plugin'
  $manifestRoot = Join-Path $Root '.agents\plugins'
  New-Item -ItemType Directory -Force -Path $descriptorRoot, $manifestRoot | Out-Null

  $descriptor = [ordered]@{
    name = 'fixture'
    version = $Version
  }
  if (-not [string]::IsNullOrWhiteSpace($PublicationPolicy)) {
    $descriptor['publicationPolicy'] = $PublicationPolicy
  }
  $manifest = [ordered]@{
    name = 'openai-bundled'
    plugins = @(
      [ordered]@{
        name = 'fixture'
        source = [ordered]@{
          source = 'local'
          path = './plugins/fixture'
        }
      }
    )
  }
  $descriptor | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $descriptorRoot 'plugin.json') -Encoding UTF8
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $manifestRoot 'marketplace.json') -Encoding UTF8
}

function Set-FixtureCliVersion {
  param([string]$Version)

  $script:FixturePluginList = [pscustomobject]@{
    installed = @()
    available = @(
      [pscustomobject]@{
        pluginId = 'fixture@openai-bundled'
        name = 'fixture'
        version = $Version
        installed = $false
        enabled = $false
        source = [pscustomobject]@{
          source = 'local'
          path = (Join-Path $stableRoot 'plugins\fixture')
        }
      }
    )
  }
}

function Get-BundledMarketplacePluginListWithCodexCli {
  param([switch]$IncludeAvailable)
  return $script:FixturePluginList
}

function Assert-ThrowsLike {
  param(
    [scriptblock]$Action,
    [string]$ExpectedMessage
  )

  try {
    & $Action
  } catch {
    if ($_.Exception.Message -notlike $ExpectedMessage) {
      throw "Expected failure '$ExpectedMessage' but got '$($_.Exception.Message)'"
    }
    return
  }
  throw "Expected failure '$ExpectedMessage' but the verification passed"
}

Set-FixtureMarketplace $installedRoot '2.0.0'
Set-FixtureMarketplace $stableRoot '1.0.0'
Set-FixtureCliVersion '1.0.0'
Assert-ThrowsLike {
  Test-AllBundledMarketplacePluginsAvailableWithCodexCli $stableRoot $installedRoot
} '*stable bundled marketplace descriptor version does not match the installed package for fixture*'

Set-FixtureMarketplace $stableRoot '2.0.0'
Set-FixtureCliVersion '1.0.0'
Assert-ThrowsLike {
  Test-AllBundledMarketplacePluginsAvailableWithCodexCli $stableRoot $installedRoot
} '*bundled plugin CLI version does not match the installed package for fixture@openai-bundled*'

Set-FixtureCliVersion '2.0.0'
$successOutput = @(Test-AllBundledMarketplacePluginsAvailableWithCodexCli $stableRoot $installedRoot 6>&1)
$successText = ($successOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
if ($successText -notmatch 'all publishable bundled marketplace plugins are available without changing install state: fixture') {
  throw "Matching descriptor versions did not report success: $successText"
}

# An INTERNAL_ONLY descriptor never reaches the marketplace mirror the CLI reads,
# so requiring CLI discovery for it fails every build that ships one. The
# descriptor-set and version comparisons still cover it: both sides are raw
# copies of the package.
Set-FixtureMarketplace $installedRoot '2.0.0' 'INTERNAL_ONLY'
Set-FixtureMarketplace $stableRoot '2.0.0' 'INTERNAL_ONLY'
$script:FixturePluginList = [pscustomobject]@{ installed = @(); available = @() }
$withheldOutput = @(Test-AllBundledMarketplacePluginsAvailableWithCodexCli $stableRoot $installedRoot 6>&1)
$withheldText = ($withheldOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
if ($withheldText -notmatch 'bundled plugins withheld from the marketplace mirror \(INTERNAL_ONLY\): fixture') {
  throw "An INTERNAL_ONLY descriptor absent from the CLI was not reported as withheld: $withheldText"
}

# The exemption must be scoped to the policy, not blanket-skip missing plugins.
Set-FixtureMarketplace $installedRoot '2.0.0'
Set-FixtureMarketplace $stableRoot '2.0.0'
$script:FixturePluginList = [pscustomobject]@{ installed = @(); available = @() }
Assert-ThrowsLike {
  Test-AllBundledMarketplacePluginsAvailableWithCodexCli $stableRoot $installedRoot
} '*bundled plugin is not discoverable as installed or available: fixture@openai-bundled*'

Write-Output "Bundled plugin version-drift regression passed: $fixtureRoot"
