#!/usr/bin/env bash
# Debian 12 quick-hardening script (run as root). Idempotent-ish.
set -euo pipefail
LOG=/root/harden.log
exec > >(tee -a "$LOG") 2>&1

echo "[*] Updating packages"
apt-get update -y
apt-get full-upgrade -y

echo "[*] Install basics"
apt-get install -y fail2ban auditd ufw curl wget vim net-tools

echo "[*] Password quality"
apt-get install -y libpam-pwquality
sed -ri 's/^(password\s+requisite\s+pam_pwquality\.so).*$/\1 retry=3 minlen=14 difok=4 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1/' /etc/pam.d/common-password

echo "[*] Harden SSH"
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
cp "$(dirname "$0")/configs/sshd_config" /etc/ssh/sshd_config
chmod 600 /etc/ssh/sshd_config
systemctl restart ssh

echo "[*] UFW: default deny inbound, allow essentials"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
for p in ssh http https dns samba ftp; do ufw allow $p || true; done
ufw --force enable

echo "[*] Fail2ban basic sshd jail"
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

echo "[*] Auditd enabled"
systemctl enable --now auditd

echo "[*] Disable noisy/unused services if present"
for s in telnet.socket tftp cups avahi-daemon rpcbind ; do
  systemctl disable --now "$s" 2>/dev/null || true
done

echo "[*] Nginx/Apache TLS hardening snippets (if installed)"
if dpkg -s nginx >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/nginx_tls.conf" /etc/nginx/conf.d/tls.conf
  nginx -t && systemctl reload nginx
fi
if dpkg -s apache2 >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/nginx_tls.conf" /etc/apache2/conf-available/tls-hardening.conf
  a2enconf tls-hardening || true
  apache2ctl configtest && systemctl reload apache2
fi

echo "[*] Bind9 options (if installed)"
if dpkg -s bind9 >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/named-options.conf" /etc/bind/ccdc-options.conf
  if ! grep -q ccdc-options.conf /etc/bind/named.conf.options; then
    sed -i '1i include "/etc/bind/ccdc-options.conf";' /etc/bind/named.conf.options
  fi
  systemctl restart bind9
fi

echo "[*] Samba (if installed)"
if dpkg -s samba >/dev/null 2>&1; then
  cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%s) || true
  install -D -m 644 "$(dirname "$0")/configs/smb.conf" /etc/samba/smb.conf
  systemctl restart smbd nmbd || systemctl restart samba || true
fi

echo "[*] vsftpd (if installed)"
if dpkg -s vsftpd >/dev/null 2>&1; then
  cp -a /etc/vsftpd.conf /etc/vsftpd.conf.bak.$(date +%s) || true
  install -D -m 600 "$(dirname "$0")/configs/vsftpd.conf" /etc/vsftpd.conf
  systemctl restart vsftpd
fi

echo "[*] Done."
