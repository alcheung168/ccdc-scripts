<#  windows/triage.ps1  — run as admin
    Usage:
      powershell -ep Bypass -File .\triage.ps1
#>

$ErrorActionPreference = "SilentlyContinue"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$out = "C:\Temp\triage-$ts"
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Out-T($name){ Join-Path $out $name }

Write-Host "[*] Writing reports to $out"

# 1) Running services (flag common risky ones)
$risky = @('Spooler','RemoteRegistry','WebClient','Telnet','SSDPSRV','upnphost','Fax','SNMP','IKEEXT','RemoteAccess')
Get-Service | Where-Object Status -eq 'Running' |
  Select-Object Status, Name, DisplayName, StartType |
  Sort-Object DisplayName |
  Tee-Object -FilePath (Out-T "services_running.txt") | Out-Null

$risky | ForEach-Object {
  Get-Service -Name $_ 2>$null | Where-Object Status -eq 'Running'
} | Select-Object Name, Status, StartType |
  Tee-Object -FilePath (Out-T "services_risky_running.txt") | Out-Null

# 2) Installed programs (registry, fast)
$uninstallPaths = @(
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = foreach ($p in $uninstallPaths){
  Get-ItemProperty $p 2>$null |
    Where-Object { $_.DisplayName } |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
}
$apps | Sort-Object DisplayName |
  Tee-Object -FilePath (Out-T "installed_programs.txt") | Out-Null

# 3) Listening ports → PID → process name
netstat -ano | Select-String LISTENING |
  Tee-Object -FilePath (Out-T "listening_raw.txt") | Out-Null

$portMap = foreach ($l in (netstat -ano | Select-String LISTENING)) {
  $parts = ($l -replace '\s+', ' ').Trim().Split(' ')
  $proto,$local,$foreign,$state,$pid = $parts
  try {
    $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Proto  = $proto
      Local  = $local
      PID    = $pid
      Proc   = $p.ProcessName
      Path   = ($p.Path)
    }
  } catch {}
}
$portMap | Sort-Object Local |
  Tee-Object -FilePath (Out-T "listening_ports_pid_process.txt") | Out-Null

# 4) Local groups of interest
'Administrators','Remote Desktop Users' | ForEach-Object {
  net localgroup $_ | Tee-Object -FilePath (Out-T ("group_"+($_ -replace ' ','_')+".txt")) -Append | Out-Null
}

# 5) Startup items (Run keys + Startup folders)
"HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
"HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" | ForEach-Object {
  if (Test-Path $_) {
    Get-ItemProperty $_ | Format-List * |
      Tee-Object -FilePath (Out-T "startup_registry.txt") -Append | Out-Null
  }
}
Get-ChildItem "$Env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue |
  Select-Object FullName |
  Tee-Object -FilePath (Out-T "startup_folder.txt") | Out-Null

# 6) Scheduled tasks (verbose)
schtasks /query /fo LIST /v |
  Tee-Object -FilePath (Out-T "scheduled_tasks.txt") | Out-Null

# 7) Quick summary
@"
=== QUICK CHECK ===
- Review listening_ports_pid_process.txt for unexpected ports (e.g., 1433, 3306, 5900, 5985/5986 if not needed).
- Review services_risky_running.txt and disable what you don't need.
- Review installed_programs.txt for old Java, MySQL/SQL Express, VNC/TeamViewer, toolbars, etc.
- Ensure only team accounts are in Administrators and RDP groups.
"@ | Tee-Object -FilePath (Out-T "README-summary.txt") | Out-Null

Write-Host "[*] Done. Reports in $out"

# === Helpers (optional) ===

function Disable-ServiceFast([string]$Name){
  Write-Host "[*] Disabling service $Name"
  Stop-Service $Name -Force -ErrorAction SilentlyContinue
  Set-Service $Name -StartupType Disabled -ErrorAction SilentlyContinue
}
function Uninstall-ByNameLike([string]$Pattern){
  Write-Host "[*] Attempting uninstall for products LIKE '$Pattern'"
  wmic product where "name like '$Pattern'" call uninstall /nointeractive
}
