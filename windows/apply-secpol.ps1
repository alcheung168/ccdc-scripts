<# Apply local security policy baseline (run as admin). Usage:
   .\apply-secpol.ps1 -Template .\Server2019-baseline.inf
#>
param(
  [Parameter(Mandatory=$true)][string]$Template
)

$ErrorActionPreference = "Stop"
$log = "$env:TEMP\secpol-apply-$(Get-Date -f yyyyMMddHHmmss).log"
$cfgBackup = "$env:TEMP\current-secpol.inf"

Write-Host "[*] Backing up current policy to $cfgBackup"
secedit /export /cfg $cfgBackup | Out-Null

Write-Host "[*] Applying $Template"
secedit /configure /db "$env:WINDIR\Security\Database\secedit.sdb" `
  /cfg $Template /areas SECURITYPOLICY USER_RIGHTS REGKEYS /log $log

Write-Host "[*] Done. Log: $log"
Write-Host "Reboot recommended."
