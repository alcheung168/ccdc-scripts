<# Quick wins: RDP/SMB/WinRM/Audit. Run after apply-secpol.ps1 #>
$ErrorActionPreference="Stop"

# Require NLA for RDP and restrict to Administrators + Remote Desktop Users
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f | Out-Null
net localgroup "Remote Desktop Users" /add "Administrators" | Out-Null 2>$null

# Disable legacy SMBv1 (2016/2019)
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
Set-SmbServerConfiguration -EnableSMB1Protocol $false -EnableSMB2Protocol $true -RequireSecuritySignature $true -Force | Out-Null

# Turn off Guest account, rename if needed
wmic useraccount where "name='Guest'" set disabled=true | Out-Null

# Enable Windows Firewall default-block inbound, allow RDP/HTTP/HTTPS/DNS/SMB as needed
netsh advfirewall set allprofiles state on
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound
foreach ($rule in @("RemoteDesktop-UserMode-In-TCP","File and Printer Sharing (SMB-In)","World Wide Web Services (HTTP Traffic-In)","World Wide Web Services (HTTPS Traffic-In)","DNS (TCP, Incoming)","DNS (UDP, Incoming)")) {
  netsh advfirewall firewall set rule name="$rule" new enable=yes | Out-Null 2>$null
}

# Enable advanced auditing categories if not domain-controlled
auditpol /set /category:* /success:enable /failure:enable | Out-Null

# --- Extra hardening toggles ---

# 1) Disable Print Spooler if this is NOT a print server (mitigates PrintNightmare-class issues)
Set-Service -Name Spooler -StartupType Disabled
Stop-Service Spooler -ErrorAction SilentlyContinue

# 2) LSA protection / block credential theft (RunAsPPL + no WDigest)
reg add HKLM\SYSTEM\CurrentControlSet\Control\Lsa /v RunAsPPL /t REG_DWORD /d 1 /f >$null
reg add HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest /v UseLogonCredential /t REG_DWORD /d 0 /f >$null

# 3) Disable WebClient (WebDAV) unless required (helps against some NTLM relay paths)
Set-Service WebClient -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service WebClient -ErrorAction SilentlyContinue

# 4) Require SMB server signing too (already in 2019 INF; enforce for 2016 here)
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force | Out-Null

# 5) Disable Guest & default shares (optional; confirm app needs)
wmic useraccount where "name='Guest'" set disabled=true | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" /v AutoShareWks /t REG_DWORD /d 0 /f >$null


Write-Host "[*] Service hardening complete."
