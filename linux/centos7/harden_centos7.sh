#!/usr/bin/env bash
# CentOS 7 quick-hardening script (run as root). Idempotent-ish, logs to /root/harden.log
set -euo pipefail
LOG=/root/harden.log
exec > >(tee -a "$LOG") 2>&1

echo "[*] Updating packages"
yum -y clean all
yum -y update

echo "[*] Install basics: fail2ban, audit, tools"
yum -y install epel-release || true
yum -y install fail2ban audit audit-libs python3 tar vim wget curl net-tools

echo "[*] Configure password quality (PAM)"
authconfig --updateall
sed -ri 's/^(password\s+requisite\s+pam_pwquality.so).*$/\1 retry=3 minlen=14 difok=4 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1/' /etc/pam.d/system-auth
sed -ri 's/^(password\s+requisite\s+pam_pwquality.so).*$/\1 retry=3 minlen=14 difok=4 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1/' /etc/pam.d/password-auth

echo "[*] Apply hardened sshd_config"
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
cp "$(dirname "$0")/configs/sshd_config" /etc/ssh/sshd_config
chmod 600 /etc/ssh/sshd_config
systemctl restart sshd

echo "[*] Firewalld: default drop inbound, allow SSH/HTTP/HTTPS/DNS/SMB/FTP"
yum -y install firewalld
systemctl enable --now firewalld
for svc in ssh http https dns samba ftp; do
  firewall-cmd --permanent --add-service=$svc || true
done
firewall-cmd --set-default-zone=public
firewall-cmd --permanent --set-target=DROP
firewall-cmd --reload

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

echo "[*] Disable unused/legacy services if present"
for s in telnet.socket tftp xinetd cups rpcbind avahi-daemon ; do
  systemctl disable --now "$s" 2>/dev/null || true
done

echo "[*] Nginx/Apache TLS hardening snippets (copy if in use)"
if rpm -q nginx >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/nginx_tls.conf" /etc/nginx/conf.d/tls.conf
  nginx -t && systemctl reload nginx
fi
if rpm -q httpd >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/httpd_ssl.conf" /etc/httpd/conf.d/ssl-hardening.conf
  apachectl configtest && systemctl reload httpd
fi

echo "[*] Bind (named) options (if installed)"
if rpm -q bind >/dev/null 2>&1; then
  install -D -m 644 "$(dirname "$0")/configs/named-options.conf" /etc/named/ccdc-options.conf
  sed -i '/ccdc-options.conf/d' /etc/named.conf
  sed -i '1i include "/etc/named/ccdc-options.conf";' /etc/named.conf
  systemctl restart named
fi

echo "[*] Samba (if installed)"
if rpm -q samba >/dev/null 2>&1; then
  cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%s) || true
  install -D -m 644 "$(dirname "$0")/configs/smb.conf" /etc/samba/smb.conf
  systemctl restart smb || systemctl restart smb.service || true
fi

echo "[*] vsftpd (if installed)"
if rpm -q vsftpd >/dev/null 2>&1; then
  cp -a /etc/vsftpd/vsftpd.conf /etc/vsftpd/vsftpd.conf.bak.$(date +%s) || true
  install -D -m 600 "$(dirname "$0")/configs/vsftpd.conf" /etc/vsftpd/vsftpd.conf
  systemctl restart vsftpd
fi

echo "[*] automated updates"
yum -y install yum-cron
sed -i 's/^apply_updates = .*/apply_updates = yes/' /etc/yum/yum-cron.conf
systemctl enable --now yum-cron


echo "[*] Root SSH password login remains disabled; ensure you have a key before running this."
echo "[*] Done."
