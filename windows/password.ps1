<# 
Bulk password reset tool for Windows (PowerShell)
Behavior mirrors the sh script:

- $env:ROOTUSER  (optional) : name of the superuser account; default "Administrator"
- $env:ROOTPASS  (required) : password to set for ROOTUSER
- $env:SSHUSER   (optional) : special account to assign a known password
- $env:PASS      (optional) : password for SSHUSER (must be set if SSHUSER is set)
- First script argument (required) : the password to set for ALL OTHER enabled local users

Usage examples (run from an elevated PowerShell prompt):
  $env:ROOTPASS = "SuperSecurePass"
  $env:SSHUSER  = "admin"
  $env:PASS     = "AdminPass123"
  .\password.ps1 "PasswordForEveryoneElse"

Or without SSHUSER/PASS:
  $env:ROOTPASS = "SuperSecurePass"
  .\password.ps1 "PasswordForEveryoneElse"
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$OtherUsersPassword
)

set-strictmode -version latest
$ErrorActionPreference = "Stop"

# --- elevation check ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Error "This script must be run in an elevated PowerShell session (Run as Administrator)."
  exit 1
}

# --- inputs / defaults ---
$RootUser = if ($env:ROOTUSER) { $env:ROOTUSER } else { "Administrator" }
if (-not $env:ROOTPASS) {
  Write-Error "ROOTPASS is not specified. Refusing to proceed to avoid locking out the superuser."
  exit 1
}
$SshUser = $env:SSHUSER
$SshPass = $env:PASS

# Paired variable validation for SSHUSER/PASS
if ($SshUser -and -not $SshPass) {
  Write-Error "SSHUSER is set but PASS is not. Aborting to prevent lockout."
  exit 1
}
if (-not $SshUser -and $SshPass) {
  Write-Error "PASS is set but SSHUSER is not. Aborting to prevent lockout."
  exit 1
}

# --- helper: set password for a local user ---
function Set-LocalUserPassword {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Password
  )
  $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
  try {
    Set-LocalUser -Name $User -Password $secure | Out-Null
    return $true
  } catch {
    Write-Warning "Failed to set password for '$User': $($_.Exception.Message)"
    return $false
  }
}

# --- resolve local users to target ---
# Start from all *enabled* local users and exclude common non-interactive/built-in accounts.
# (Administrator/root handled explicitly; Guest/DefaultAccount/WDAGUtilityAccount are skipped.)
$excludeNames = @("Guest","DefaultAccount","WDAGUtilityAccount")
$allEnabledLocalUsers = Get-LocalUser | Where-Object { $_.Enabled -eq $true }

# Emit CSV header (stdout)
Write-Output "username,password"

foreach ($u in $allEnabledLocalUsers) {
  $name = $u.Name

  if ($excludeNames -contains $name) {
    continue
  }

  if ($name -ieq $RootUser) {
    if (Set-LocalUserPassword -User $name -Password $env:ROOTPASS) {
      Write-Output "$name,$($env:ROOTPASS)"
    }
    continue
  }

  if ($SshUser -and ($name -ieq $SshUser)) {
    if (Set-LocalUserPassword -User $name -Password $SshPass) {
      Write-Output "$name,$SshPass"
    }
    continue
  }

  # All other eligible users
  if (Set-LocalUserPassword -User $name -Password $OtherUsersPassword) {
    Write-Output "$name,$OtherUsersPassword"
  }
}
