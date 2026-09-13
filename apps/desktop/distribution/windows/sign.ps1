param([Parameter(Mandatory=$true)][string]$File)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($name in @('MOKAID_AZURE_SIGNING_ENDPOINT', 'MOKAID_AZURE_SIGNING_ACCOUNT', 'MOKAID_AZURE_CERTIFICATE_PROFILE')) {
  if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Required signing configuration is missing: $name" }
}
Import-Module TrustedSigning -RequiredVersion '0.5.8' -ErrorAction Stop
Invoke-TrustedSigning -Endpoint $env:MOKAID_AZURE_SIGNING_ENDPOINT `
  -CodeSigningAccountName $env:MOKAID_AZURE_SIGNING_ACCOUNT `
  -CertificateProfileName $env:MOKAID_AZURE_CERTIFICATE_PROFILE `
  -Files (Resolve-Path -LiteralPath $File).Path -FileDigest SHA256 `
  -TimestampRfc3161 'http://timestamp.acs.microsoft.com' -TimestampDigest SHA256 `
  -ExcludeEnvironmentCredential $true -ExcludeManagedIdentityCredential $true `
  -ExcludeWorkloadIdentityCredential $true -ExcludeAzureCliCredential $false
$signature = Get-AuthenticodeSignature -LiteralPath $File
if ($signature.Status -ne 'Valid') { throw "Authenticode verification failed for $File" }
