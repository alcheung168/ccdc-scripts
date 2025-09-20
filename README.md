# CCDC-Style Quick Baselines

## Windows Server 2016 (.35) / 2019 (.37)
```powershell
git clone https://github.com/<you>/ccdc-baselines.git
cd ccdc-baselines\windows
# Apply local security policy
.\apply-secpol.ps1 -Template .\Server2016-baseline.inf   # or Server2019-baseline.inf
# Quick service hardening (RDP/SMB/firewall/audit)
.\service-hardening.ps1
