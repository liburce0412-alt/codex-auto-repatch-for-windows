param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('recovery-copy-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$null = New-Item -ItemType Directory -Path (Join-Path $source 'app\resources') -Force
[IO.File]::WriteAllBytes((Join-Path $source 'app\resources\app.asar'), [byte[]](0, 1, 2, 255, 42))
[IO.File]::WriteAllText((Join-Path $source 'AppxManifest.xml'), '<Package/>')
[IO.File]::WriteAllText((Join-Path $source 'AppxSignature.p7x'), 'old signature')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Recoverable runner failed to parse.' }
$copy = $ast.Find({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-RecoveryPackageLayout'
}, $true)
. ([scriptblock]::Create($copy.Extent.Text))
$sharedCopy = Join-Path $PSScriptRoot 'lib\package-copy.ps1'
if (Test-Path -LiteralPath $sharedCopy) { . $sharedCopy }
function Write-Log { param($Message) }
function robocopy.exe {
  param($SourceRoot, $DestinationRoot)
  Copy-Item -LiteralPath (Join-Path $SourceRoot 'AppxManifest.xml') -Destination $DestinationRoot
  if ($script:mode -eq 'corrupt') {
    $null = New-Item -ItemType Directory -Path (Join-Path $DestinationRoot 'app\resources') -Force
    [IO.File]::WriteAllText((Join-Path $DestinationRoot 'app\resources\app.asar'), 'corrupt')
  }
  $global:LASTEXITCODE = if ($script:mode -eq 'error') { 8 } else { 1 }
}
foreach ($script:mode in @('partial', 'error', 'corrupt')) {
  $destination = Join-Path $root $script:mode
  $rejected = $false
  try { Copy-RecoveryPackageLayout -SourceRoot $source -DestinationRoot $destination }
  catch {
    if ($script:mode -ne 'corrupt' -or $_.Exception.Message -notlike '*original app.asar bytes*') { throw }
    $rejected = $true
  }
  if ($script:mode -eq 'corrupt') {
    if (-not $rejected) { throw 'A corrupt ASAR was accepted.' }
  } else {
    if ((Get-FileHash -LiteralPath (Join-Path $source 'app\resources\app.asar')).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $destination 'app\resources\app.asar')).Hash) { throw 'ASAR content changed.' }
    if (Test-Path -LiteralPath (Join-Path $destination 'AppxSignature.p7x')) { throw 'Old signature survived recovery preparation.' }
  }
}
$global:LASTEXITCODE = 0
Write-Output "Recovery copy handles incomplete/error copies and rejects corrupt ASAR. Fixtures: $root"
