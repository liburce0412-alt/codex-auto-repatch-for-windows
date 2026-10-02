param([switch]$CheckExistingCertificate)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$patcher = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($patcher, [ref]$null, [ref]$null)
foreach ($name in @('Test-CodeSigningCertificate', 'Get-OrCreateSigningCertificate')) {
  $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
  if (-not $definition) { throw "Missing signing function: $name" }
  . ([scriptblock]::Create($definition.Extent.Text))
}
function Write-Log([string]$Message) { Write-Output $Message | Out-Host }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$key = [Security.Cryptography.RSA]::Create(2048)
try {
  foreach ($oid in @('1.3.6.1.5.5.7.3.3', '1.3.6.1.5.5.7.3.1', '')) {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=temporary-signing-fixture', $key, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if ($oid) {
      $usages = [Security.Cryptography.OidCollection]::new()
      [void]$usages.Add([Security.Cryptography.Oid]::new($oid))
      $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $false))
    }
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-1), [DateTimeOffset]::Now.AddDays(1))
    try { Assert ((Test-CodeSigningCertificate $certificate) -eq ($oid -eq '1.3.6.1.5.5.7.3.3')) "Wrong EKU decision: $oid" }
    finally { $certificate.Dispose() }
  }
} finally { $key.Dispose() }
# The default fixture is portable and never modifies a certificate store.
if (-not $CheckExistingCertificate) {
  Write-Output 'SIGNING_EKU_PASSED: raw certificates with code-signing, server-auth and absent EKU'
  return
}
# Optional local check is read-only. Any attempt to create a new key fails.
function New-SelfSignedCertificate { throw 'Existing signing certificate was not reused' }
$publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$first = Get-OrCreateSigningCertificate $publisher
$second = Get-OrCreateSigningCertificate $publisher
Assert ($first.Thumbprint -eq $second.Thumbprint) 'Signing identity changed between runs'
Assert ($first.HasPrivateKey -and (Test-CodeSigningCertificate $first)) 'Existing signing certificate is unusable'
Write-Output "SIGNING_CERTIFICATE_REUSE_PASSED: $($first.Thumbprint) expires=$($first.NotAfter.ToString('yyyy-MM-dd'))"
