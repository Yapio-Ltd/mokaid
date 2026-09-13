param([Parameter(Mandatory=$true)][string]$File)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# A valid vendor signature is preserved byte-for-byte by release.py. A broken,
# untrusted or mismatched signature is an error, not permission to re-sign it.
(Get-AuthenticodeSignature -LiteralPath $File).Status.ToString()
