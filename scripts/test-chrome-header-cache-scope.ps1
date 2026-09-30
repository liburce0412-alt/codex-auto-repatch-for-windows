param(
  [Parameter(Mandatory = $true)][string]$OriginalService,
  [Parameter(Mandatory = $true)][string]$TemporaryRoot,
  [string]$OtherSupportedService,
  [string]$RuntimeService,
  [string]$OtherRuntimeService
)
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$installer=Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Installer parse failed.'}
foreach($name in @('Get-CuaBrowserHeaderCompatibilityServicePaths','Get-ChromeHeaderCompatibilityServicePaths','Invoke-ChromeHeaderCompatibility','Test-BrowserServiceMatchesHeaderOverlay','Test-ScopedBundledPluginDirectoryMatchesInstalledPackage','Get-ScopedBundledPluginCriticalFiles','Get-PluginVersion','Test-FilesMatchByContent')) {
  $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
  if(-not $definition){throw "Missing function: $name"}
  # AST-only imports do not retain the originating file's PSScriptRoot.
  $definitionText = $definition.Extent.Text.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'"))
  . ([scriptblock]::Create($definitionText))
}
function Write-Log([string]$Message) { Write-Host "[header-cache-test] $Message" }
$script:checks=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Expect-Failure([scriptblock]$Action,[string]$Pattern){$message=$null;try{& $Action | Out-Null}catch{$message=$_.Exception.Message};Assert ($message -and $message -match $Pattern) "Expected '$Pattern'; got '$message'"}
New-Item -ItemType Directory -Path $TemporaryRoot -Force | Out-Null
$root=Join-Path $TemporaryRoot ([guid]::NewGuid().ToString('N'))
$fixtureHome=Join-Path $root 'home'
$marketplace=Join-Path $root 'marketplace'
$installed=Join-Path $root 'installed'
$version='26.917.71314'
foreach($plugin in @('browser','chrome')) {
  $descriptor=Join-Path $installed "plugins\$plugin\.codex-plugin\plugin.json"
  New-Item -ItemType Directory -Path (Split-Path -Parent $descriptor) -Force | Out-Null
  [IO.File]::WriteAllText($descriptor,('{"name":"'+$plugin+'","version":"'+$version+'"}'))
  $sourceScripts=Join-Path $installed "plugins\$plugin\scripts"
  New-Item -ItemType Directory -Path $sourceScripts -Force | Out-Null
  Copy-Item -LiteralPath $OriginalService -Destination (Join-Path $sourceScripts 'browser-service.mjs')
  foreach($base in @((Join-Path $marketplace "plugins\$plugin"),(Join-Path $fixtureHome "plugins\cache\openai-bundled\$plugin\$version"),(Join-Path $root "openai-bundled-cache\$plugin\$version"),(Join-Path $fixtureHome ".tmp\bundled-marketplaces\openai-bundled\plugins\$plugin"))) {
    $scripts=Join-Path $base 'scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath $OriginalService -Destination (Join-Path $scripts 'browser-service.mjs')
    [IO.File]::WriteAllText((Join-Path $scripts 'browser-client.mjs'),'client must remain unchanged')
  }
}
$config=Join-Path $fixtureHome 'config.toml'
[IO.File]::WriteAllText($config,'model_provider = "untouched"')
$optional=Join-Path $marketplace 'plugins\sites\scripts\browser-service.mjs'
New-Item -ItemType Directory -Path (Split-Path -Parent $optional) -Force | Out-Null
[IO.File]::WriteAllText($optional,'optional plugin must remain unchanged')
$originalHash=(Get-FileHash -LiteralPath $OriginalService -Algorithm SHA256).Hash
$node=(Get-Command node.exe -ErrorAction Stop).Source
$patcher=Join-Path $PSScriptRoot 'patch-chrome-custom-provider-headers.cjs'
$pathOptions=@{CodexHomeRoot=$fixtureHome;MarketplaceRoot=$marketplace;InstalledMarketplaceRoot=$installed;NodePath=$node;PatcherPath=$patcher}
$paths=@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions)
Assert ($paths.Count -eq 8) 'Expected exactly browser/chrome copies in four existing roots.'
$invokeOptions=@{ServicePaths=$paths;NodePath=$node;PatcherPath=$patcher;BackupRoot=(Join-Path $root 'backups')}
Expect-Failure {Invoke-ChromeHeaderCompatibility @invokeOptions -VerifyOnly} 'missing custom-provider'
Assert (@($paths | Where-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ne $originalHash}).Count -eq 0) 'VerifyOnly changed a service.'
[IO.File]::WriteAllText($paths[-1],'unknown service version')
Expect-Failure {Get-ChromeHeaderCompatibilityServicePaths @pathOptions} 'differs from supported package profile'
Expect-Failure {Invoke-ChromeHeaderCompatibility @invokeOptions} 'preflight failed'
Assert (@($paths[0..6] | Where-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ne $originalHash}).Count -eq 0) 'Batch preflight modified earlier files before rejecting an unknown file.'
Copy-Item -LiteralPath $OriginalService -Destination $paths[-1] -Force
if($OtherSupportedService) {
  Assert ((Get-FileHash -LiteralPath $OtherSupportedService -Algorithm SHA256).Hash -ne $originalHash) 'Cross-profile fixture must have a different source hash.'
  Copy-Item -LiteralPath $OtherSupportedService -Destination $paths[-1] -Force
  Expect-Failure {Get-ChromeHeaderCompatibilityServicePaths @pathOptions} 'differs from supported package profile'
  Assert (@($paths[0..6] | Where-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ne $originalHash}).Count -eq 0) 'Cross-profile rejection changed another copy.'
  Copy-Item -LiteralPath $OriginalService -Destination $paths[-1] -Force
}
$packagedServices=@('browser','chrome' | ForEach-Object {Join-Path $installed "plugins\$_\scripts\browser-service.mjs"})
[IO.File]::WriteAllText($packagedServices[1],'future official browser service')
Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 4) 'One unsupported package source must not hide the supported plugin.'
[IO.File]::WriteAllText($packagedServices[0],'future official browser service')
Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 0) 'Unknown official versions must skip only the overlay.'
Assert (@($paths | Where-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ne $originalHash}).Count -eq 0) 'Unknown-source probe modified cache files.'
foreach($source in $packagedServices){Copy-Item -LiteralPath $OriginalService -Destination $source -Force}
$results=@(Invoke-ChromeHeaderCompatibility @invokeOptions)
Assert ($results.Count -eq 8) 'Not every expected cache copy was patched.'
Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 8) 'Complete patched copies must match their package profile.'
Invoke-ChromeHeaderCompatibility @invokeOptions -VerifyOnly | Out-Null
$count=@(Get-ChildItem -LiteralPath (Join-Path $root 'backups') -File).Count
Assert ($count -eq 8) 'Each modified copy must have an original backup.'
Invoke-ChromeHeaderCompatibility @invokeOptions | Out-Null
Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'backups') -File).Count -eq $count) 'Idempotent apply created extra backups.'
Assert ((Get-Content -LiteralPath $config -Raw) -eq 'model_provider = "untouched"') 'Config was modified.'
Assert ((Get-Content -LiteralPath $optional -Raw) -eq 'optional plugin must remain unchanged') 'Optional plugin was modified.'
foreach($service in $paths){Assert ((Get-Content -LiteralPath (Join-Path (Split-Path -Parent $service) 'browser-client.mjs') -Raw) -eq 'client must remain unchanged') 'Trusted client bytes changed.'}
if ($RuntimeService) {
  $relative = 'node_modules\@oai\browser-desktop\scripts\browser-service.mjs'
  $sourceBin = Join-Path $installed 'cua_node\bin'
  $currentBins = @((Join-Path $root 'runtimes\current-a\bin'), (Join-Path $root 'runtimes\current-b\bin'))
  $staleBin = Join-Path $root 'runtimes\stale\bin'
  $runtimeHash = (Get-FileHash -LiteralPath $RuntimeService).Hash
  foreach ($bin in @($sourceBin, $staleBin) + $currentBins) {
    $service = Join-Path $bin $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $service) -Force | Out-Null
    Copy-Item -LiteralPath $RuntimeService -Destination $service
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $service) 'browser-client.mjs'), 'trusted runtime client')
  }
  $descriptor = Join-Path $sourceBin 'node_modules\@oai\browser-desktop\package.json'
  [IO.File]::WriteAllText($descriptor, '{"name":"@oai/browser-desktop","version":"0.1.1","exports":{"./service":"./scripts/browser-service.mjs"}}')
  $inventory = [pscustomobject]@{
    NodePath = (Join-Path $currentBins[0] 'node.exe')
    ReferenceNodePath = (Join-Path $sourceBin 'node.exe')
    AllowedCuaBinRoots = @($currentBins[0], $currentBins[1], $currentBins[0])
  }
  $pathOptions.RuntimeInventory = $inventory
  $allPaths = @(Get-ChromeHeaderCompatibilityServicePaths @pathOptions)
  Assert ($allPaths.Count -eq 10) 'Current runtimes must join plugin paths, with duplicates removed.'
  $runtimePaths = @($currentBins | ForEach-Object { Join-Path $_ $relative })
  $runtimeInvoke = @{ServicePaths=$allPaths;NodePath=$node;PatcherPath=$patcher;BackupRoot=(Join-Path $root 'backups')}
  Expect-Failure { Invoke-ChromeHeaderCompatibility @runtimeInvoke -VerifyOnly } 'missing custom-provider'
  Assert ((Get-FileHash -LiteralPath $runtimePaths[0]).Hash -eq $runtimeHash) 'Runtime VerifyOnly wrote a patch.'
  [IO.File]::WriteAllText($runtimePaths[1], 'unknown runtime')
  Expect-Failure { Get-ChromeHeaderCompatibilityServicePaths @pathOptions } 'runtime differs from supported package profile'
  Expect-Failure { Invoke-ChromeHeaderCompatibility @runtimeInvoke } 'preflight failed'
  Assert ((Get-FileHash -LiteralPath $runtimePaths[0]).Hash -eq $runtimeHash) 'Runtime batch failure changed an earlier file.'
  if ($OtherRuntimeService) {
    Assert ((Get-FileHash -LiteralPath $OtherRuntimeService).Hash -ne $runtimeHash) 'Expected a distinct runtime profile.'
    Copy-Item -LiteralPath $OtherRuntimeService -Destination $runtimePaths[1] -Force
    Expect-Failure { Get-ChromeHeaderCompatibilityServicePaths @pathOptions } 'runtime differs from supported package profile'
  }
  Remove-Item -LiteralPath $runtimePaths[1] -Force
  Expect-Failure { Get-ChromeHeaderCompatibilityServicePaths @pathOptions } 'runtime service is missing'
  Copy-Item -LiteralPath $RuntimeService -Destination $runtimePaths[1]
  $packagedRuntime = Join-Path $sourceBin $relative
  [IO.File]::WriteAllText($packagedRuntime, 'future packaged runtime')
  Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 8) 'Unsupported runtime must not hide supported plugins.'
  Copy-Item -LiteralPath $RuntimeService -Destination $packagedRuntime -Force
  foreach ($source in $packagedServices) { [IO.File]::WriteAllText($source, 'future official browser service') }
  Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 2) 'Unsupported plugins must not hide the supported runtime.'
  foreach ($source in $packagedServices) { Copy-Item -LiteralPath $OriginalService -Destination $source -Force }
  $noPlugins = Join-Path $root 'no-plugin-marketplace'
  New-Item -ItemType Directory -Path $noPlugins | Out-Null
  $savedMarketplace = $pathOptions.InstalledMarketplaceRoot
  $pathOptions.InstalledMarketplaceRoot = $noPlugins
  Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 2) 'Runtime discovery must work without plugin descriptors.'
  $pathOptions.InstalledMarketplaceRoot = $savedMarketplace
  Invoke-ChromeHeaderCompatibility @runtimeInvoke | Out-Null
  Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 10) 'Complete runtime patches must remain discoverable.'
  Invoke-ChromeHeaderCompatibility @runtimeInvoke -VerifyOnly | Out-Null
  $backupCount = @(Get-ChildItem -LiteralPath (Join-Path $root 'backups') -File).Count
  Assert ($backupCount -eq 10) 'Each runtime write must have an original backup.'
  Invoke-ChromeHeaderCompatibility @runtimeInvoke | Out-Null
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'backups') -File).Count -eq $backupCount) 'Runtime reapply created redundant backups.'
  foreach ($bin in @($sourceBin, $staleBin)) {
    Assert ((Get-FileHash -LiteralPath (Join-Path $bin $relative)).Hash -eq $runtimeHash) 'Packaged or stale runtime was modified.'
  }
  foreach ($service in $runtimePaths) {
    Assert ([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $service) 'browser-client.mjs')) -ceq 'trusted runtime client') 'Trusted runtime client changed.'
  }
  [IO.File]::AppendAllText($runtimePaths[1], "`n")
  Expect-Failure { Get-ChromeHeaderCompatibilityServicePaths @pathOptions } 'runtime differs from supported package profile'
}
# Scoped final verification must accept the exact overlay, and reject other drift.
$browserRoot = Join-Path $marketplace 'plugins\browser'
$browserDescriptor = Join-Path $browserRoot '.codex-plugin\plugin.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $browserDescriptor) -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $installed 'plugins\browser\.codex-plugin\plugin.json') -Destination $browserDescriptor
Test-ScopedBundledPluginDirectoryMatchesInstalledPackage $installed $browserRoot 'browser' 'fixture'
Assert $true 'Exact supported overlay was rejected.'
$servicePath = Join-Path $browserRoot 'scripts\browser-service.mjs'
$validPatched = [IO.File]::ReadAllBytes($servicePath)
[IO.File]::AppendAllText($servicePath, '/*unrelated drift*/')
Expect-Failure {Test-ScopedBundledPluginDirectoryMatchesInstalledPackage $installed $browserRoot 'browser' 'fixture'} 'differs from the installed package'
[IO.File]::WriteAllBytes($servicePath, $validPatched)
[IO.File]::WriteAllText($browserDescriptor, ('{"version":"'+$version+'","unexpected":true}'))
Expect-Failure {Test-ScopedBundledPluginDirectoryMatchesInstalledPackage $installed $browserRoot 'browser' 'fixture'} 'differs from the installed package'
Write-Output "CHROME_HEADER_CACHE_SCOPE_PASSED checks=$script:checks root=$root"
