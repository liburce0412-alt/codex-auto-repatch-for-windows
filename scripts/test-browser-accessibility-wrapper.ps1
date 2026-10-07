param(
  [Parameter(Mandatory = $true)][string]$FixtureJson,
  [Parameter(Mandatory = $true)][string]$NodePath,
  [switch]$ExpectFailure
)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install-computer-use-local.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Installer parse failed' }
$definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-BrowserAccessibilityAssets'}, $true)
if (-not $definition) { throw 'Missing AX asset wrapper' }
$body = $definition.Extent.Text.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'"))
. ([scriptblock]::Create($body))
function Write-Log([string]$Message) { Write-Output $Message }
$options = Get-Content -LiteralPath $FixtureJson -Raw -Encoding UTF8 | ConvertFrom-Json
# The wrapper uses the real Node executable; the isolated reference has no runtime.
$inventory = [pscustomobject]@{
  NodePath = $NodePath
  ReferenceNodePath = (Join-Path (Split-Path -Parent $FixtureJson) 'absent-runtime\node.exe')
  AllowedCuaBinRoots = @()
}
$OutputEncoding = [Text.ASCIIEncoding]::new()
$originalEncoding = $OutputEncoding
$failed = $false
try {
  Invoke-BrowserAccessibilityAssets $options.codexHomeRoot $options.marketplaceRoot $options.installedMarketplaceRoot $inventory -VerifyOnly
} catch {
  if (-not $ExpectFailure) { throw }
  if ($_.Exception.Message -notmatch 'AX asset missing or corrupt') { throw }
  $failed = $true
} finally {
  if (-not [object]::ReferenceEquals($OutputEncoding, $originalEncoding)) { throw 'Wrapper changed caller encoding' }
  if ($ErrorActionPreference -ne 'Stop') { throw 'Wrapper changed caller error preference' }
}
if ($ExpectFailure -and -not $failed) { throw 'Corrupt asset was silently accepted' }
