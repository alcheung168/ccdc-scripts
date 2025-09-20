#!/usr/bin/env bash
# linux/triage.sh  — run as root
# Usage: bash triage.sh
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
OUT="/root/triage-$TS"
mkdir -p "$OUT"

echo "[*] Reports -> $OUT"

# 1) Services (running + enabled)
systemctl list-units --type=service --state=running > "$OUT/services_running.txt"
systemctl list-unit-files --type=service | sort > "$OUT/services_enabled.txt"

# 2) Listening ports
if command -v ss >/dev/null 2>&1; then
  ss -tulpn > "$OUT/listening.txt"
else
  netstat -tulpn > "$OUT/listening.txt" 2>&1 || true
fi

# 3) Packages
if command -v dpkg >/dev/null 2>&1; then
  dpkg -l > "$OUT/packages_all.txt"
  egrep -i 'x11|telnet|rsh|finger|irc|games|vnc|teamviewer|java|flash' "$OUT/packages_all.txt" > "$OUT/packages_suspect.txt" || true
elif command -v rpm >/dev/null 2>&1; then
  rpm -qa > "$OUT/packages_all.txt"
  egrep -i 'xorg|telnet|rsh|finger|irc|games|vnc|teamviewer|java|flash' "$OUT/packages_all.txt" > "$OUT/packages_suspect.txt" || true
fi

# 4) Sudoers & Cron & Users
{
  echo "### /etc/sudoers"
  grep -vE '^\s*#' /etc/sudoers 2>/dev/null || true
  echo -e "\n### /etc/sudoers.d/"
  ls -l /etc/sudoers.d 2>/dev/null || true
  grep -Rvh '^\s*#' /etc/sudoers.d 2>/dev/null || true
} > "$OUT/sudoers.txt"

{
  echo "### User crontabs"
  for u in $(cut -d: -f1 /etc/passwd); do
    crontab -l -u "$u" 2>/dev/null | sed "s/^/[$u] /" || true
  done
  echo -e "\n### System cron dirs"
  for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
    echo "[$d]"; ls -la "$d" 2>/dev/null || true
  done
} > "$OUT/cron.txt"

# 5) Login-capable users (non-/usr/sbin/nologin)
awk -F: '($7 !~ /nologin|false/){print $1 ":" $7}' /etc/passwd > "$OUT/login_users.txt"

# 6) Startup scripts / rc-local (if present)
[ -f /etc/rc.local ] && (echo "### /etc/rc.local"; cat /etc/rc.local) > "$OUT/rc_local.txt" || true

# 7) World-writable dirs (top offenders)
echo "### World-writable directories (top 200)" > "$OUT/world_writable_dirs.txt"
find / -xdev -type d -perm -0002 -print 2>/dev/null | head -n 200 >> "$OUT/world_writable_dirs.txt" || true

# 8) Quick summary
cat > "$OUT/README-summary.txt" <<'EOF'
=== QUICK CHECK ===
- listening.txt: only expect scored ports (22, 80, 443, 53/tcp+udp, 139, 445, 21, 20).
- services_running.txt: stop/disable cups, avahi-daemon, rpcbind, nfs*, snmpd, postfix (if not scored).
- packages_suspect.txt: remove VNC, TeamViewer, old Java/Flash, games/X11 on servers.
- sudoers.txt: kill NOPASSWD or broad ALL if not needed.
- cron.txt: remove weird jobs (curl|wget to suspicious domains, bash -i >& /dev/tcp/...).
- login_users.txt: lock any unexpected shells (chsh -s /usr/sbin/nologin <user>).
EOF

echo "[*] Done."

# === Helpers (optional) ===
cat > "$OUT/helpers.sh" <<'HEOF'
# Disable and stop services safely:
#   systemctl disable --now <svc>

# Remove packages:
#   Debian/Ubuntu: apt-get purge -y <pkg>
#   RHEL/CentOS:   yum remove -y <pkg>

# Lock a user account:
#   usermod -L <user> && chsh -s /usr/sbin/nologin <user>
HEOF
chmod +x "$OUT/helpers.sh"
