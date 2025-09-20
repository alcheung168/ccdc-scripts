#!/usr/bin/env bash
# CentOS 7 quick-hardening with iptables (no firewalld)
# - Idempotent-ish
# - Saves config backups
# - 120s firewall auto-rollback unless confirmed
# - Opens only scored services: SSH(22), HTTP(80), HTTPS(443), DNS(53/tcp+udp), SMB(139,445), FTP(21,20)

set -euo pipefail
LOG=/root/harden.log
exec > >(tee -a "$LOG") 2>&1

MARKER=/tmp/iptables-ok
IPT_BACKUP=/etc/sysconfig/iptables.bak.$(date +%s)

echo "[*] Starting CentOS 7 harden (iptables). Log: $LOG"

# --- 0) Updates & basic tools -------------------------------------------------
echo "[*] Updating system packages"
yum -y clean all
yum -y update || true   # CentOS 7 is EOL; update what’s available

echo "[*] Installing essentials"
yum -y install epel-release || true
yum -y install fail2ban audit audit-libs python3 tar vim wget curl net-tools iptables-services policycoreutils-python || true

# --- 1) PAM/password policy ---------------------------------------------------
echo "[*] Configuring password quality (PAM)"
authconfig --updateall
for f in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
  if grep -q 'pam_pwquality.so' "$f"; then
    sed -ri 's/^(password\s+requisite\s+pam_pwquality\.so).*$/\1 retry=3 minlen=14 difok=4 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1/' "$f"
  else
    echo "password    requisite     pam_pwquality.so retry=3 minlen=14 difok=4 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1" >> "$f"
  fi
done

# --- 2) SSH harden (safe) -----------------------------------------------------
echo "[*] Hardening SSH (safe mode)"
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
# Use your repo’s hardened config if present
if [ -f "$(dirname "$0")/configs/sshd_config" ]; then
  cp "$(dirname "$0")/configs/sshd_config" /etc/ssh/sshd_config
fi
chmod 600 /etc/ssh/sshd_config

# Only enforce key-only if a key exists (avoid lockout)
TEST_USER=root
if [ -s /root/.ssh/authorized_keys ] || [ -s /home/$TEST_USER/.ssh/authorized_keys ]; then
  echo "[*] authorized_keys found; keeping PasswordAuthentication no"
else
  echo "[!] No authorized_keys found; ensuring PasswordAuthentication yes to avoid lockout"
  sed -ri 's/^#?\s*PasswordAuthentication\s+.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
fi
systemctl enable sshd
systemctl restart sshd

# --- 3) Replace firewalld with iptables --------------------------------------
echo "[*] Disabling firewalld (if present) and enabling iptables-services"
systemctl disable --now firewalld 2>/dev/null || true
systemctl enable --now iptables || true

# Backup existing iptables rules if present
if [ -f /etc/sysconfig/iptables ]; then
  cp -a /etc/sysconfig/iptables "$IPT_BACKUP"
  echo "[*] Backed up existing iptables to $IPT_BACKUP"
fi

# Apply restrictive rules with auto-rollback
echo "[*] Applying iptables rules (scored services only) with 120s auto-rollback"
# Build ruleset in a temp file
TMP_RULES=$(mktemp)
cat > "$TMP_RULES" <<'EOF'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Allow loopback
-A INPUT -i lo -j ACCEPT

# Allow established/related
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# SSH
-A INPUT -p tcp --dport 22 -j ACCEPT
# HTTP/HTTPS
-A INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
# DNS
-A INPUT -p tcp --dport 53 -j ACCEPT
-A INPUT -p udp --dport 53 -j ACCEPT
# SMB
-A INPUT -p tcp --dport 139 -j ACCEPT
-A INPUT -p tcp --dport 445 -j ACCEPT
# FTP
-A INPUT -p tcp --dport 21 -j ACCEPT
-A INPUT -p tcp --dport 20 -j ACCEPT

# Drop everything else
-A INPUT -j DROP

COMMIT
EOF

# Load rules into kernel
iptables-restore < "$TMP_RULES"
# Save persistent rules
install -D -m 600 "$TMP_RULES" /etc/sysconfig/iptables
systemctl restart iptables

# Auto-rollback in 120s unless /tmp/iptables-ok exists
( sleep 120
  if [ ! -f "$MARKER" ]; then
    echo "[!] No confirmation marker; rolling back firewall"
    if [ -f "$IPT_BACKUP" ]; then
      cp -a "$IPT_BACKUP" /etc/sysconfig/iptables
      systemctl restart iptables || true
    else
      # minimal open-up to avoid lockout: allow SSH
      iptables -F; iptables -X
      iptables -P INPUT ACCEPT; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
      iptables -A INPUT -p tcp --dport 22 -j ACCEPT
      service iptables save
      systemctl restart iptables
    fi
  else
    echo "[*] Firewall confirmed OK."
  fi
) &

echo "[*] Verify remote access now, then run: touch $MARKER"

# --- 4) Fail2ban & auditd -----------------------------------------------------
echo "[*] Configuring fail2ban (sshd jail) and auditd"
cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban
systemctl enable --now auditd

# --- 5) Disable noisy/legacy services ----------------------------------------
echo "[*] Disabling legacy/noisy services if present"
for s in telnet.socket tftp xinetd cups rpcbind avahi-daemon ; do
  systemctl disable --now "$s" 2>/dev/null || true
done

# --- 6) Service-specific hardening (only if installed) -----------------------
echo "[*] Applying TLS hardening for Nginx/Apache (if installed)"
if rpm -q nginx >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/nginx_tls.conf" /etc/nginx/conf.d/tls.conf
  nginx -t && systemctl reload nginx || echo "[!] nginx config invalid; not reloaded"
fi
if rpm -q httpd >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/httpd_ssl.conf" /etc/httpd/conf.d/ssl-hardening.conf
  apachectl configtest && systemctl reload httpd || echo "[!] httpd config invalid; not reloaded"
fi

echo "[*] Applying BIND options (if installed)"
if rpm -q bind >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/named-options.conf" /etc/named/ccdc-options.conf
  grep -q 'ccdc-options.conf' /etc/named.conf || sed -i '1i include "/etc/named/ccdc-options.conf";' /etc/named.conf
  named-checkconf && systemctl restart named || echo "[!] named config invalid; not restarted"
fi

echo "[*] Applying Samba hardening (if installed)"
if rpm -q samba >/dev/null 2>&1; then
  cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%s) || true
  install -D -m 644 "$(dirname "$0")/configs/smb.conf" /etc/samba/smb.conf
  systemctl restart smb || systemctl restart smb.service || true
fi

echo "[*] Applying vsftpd hardening (if installed)"
if rpm -q vsftpd >/dev/null 2>&1; then
  cp -a /etc/vsftpd/vsftpd.conf /etc/vsftpd/vsftpd.conf.bak.$(date +%s) || true
  install -D -m 600 "$(dirname "$0")/configs/vsftpd.conf" /etc/vsftpd/vsftpd.conf
  systemctl restart vsftpd
fi

echo "[*] Done. CentOS 7 hardened with iptables."
echo "[*] Remember to confirm firewall within 120s: touch $MARKER"
