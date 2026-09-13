param([Parameter(Mandatory=$true)][string]$File)
$ErrorActionPreference = 'Stop'
$signature = Get-AuthenticodeSignature -LiteralPath $File
if ($signature.Status -ne 'Valid') { throw "Authenticode verification failed for $File" }
if ($null -eq $signature.TimeStamperCertificate) { throw 'Installer must have a trusted timestamp' }
