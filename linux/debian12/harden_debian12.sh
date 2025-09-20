#!/usr/bin/env bash
# Debian 12 quick-hardening script with iptables (run as root)
set -euo pipefail
LOG=/root/harden.log
exec > >(tee -a "$LOG") 2>&1

echo "[*] Updating packages"
apt-get update -y
apt-get full-upgrade -y

echo "[*] Install basics"
apt-get install -y fail2ban auditd curl wget vim net-tools iptables-persistent

echo "[*] Password quality"
apt-get install -y libpam-pwquality
sed -ri 's/^(password\s+requisite\s+pam_pwquality\.so).*$/\1 retry=3 minlen=14 difok=4 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1/' /etc/pam.d/common-password

echo "[*] Harden SSH"
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
cp "$(dirname "$0")/configs/sshd_config" /etc/ssh/sshd_config
chmod 600 /etc/ssh/sshd_config
systemctl restart ssh

echo "[*] Configuring iptables firewall"
# Flush existing rules
iptables -F
iptables -X
iptables -Z

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow inbound services (scored)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT    # SSH
iptables -A INPUT -p tcp --dport 80 -j ACCEPT    # HTTP
iptables -A INPUT -p tcp --dport 443 -j ACCEPT   # HTTPS
iptables -A INPUT -p tcp --dport 53 -j ACCEPT    # DNS TCP
iptables -A INPUT -p udp --dport 53 -j ACCEPT    # DNS UDP
iptables -A INPUT -p tcp --dport 445 -j ACCEPT   # SMB
iptables -A INPUT -p tcp --dport 139 -j ACCEPT   # NetBIOS SMB
iptables -A INPUT -p tcp --dport 21 -j ACCEPT    # FTP
iptables -A INPUT -p tcp --dport 20 -j ACCEPT    # FTP data

# Drop everything else
iptables -A INPUT -j DROP

# Save rules
iptables-save > /etc/iptables/rules.v4
echo "[*] iptables rules saved to /etc/iptables/rules.v4"
systemctl enable netfilter-persistent

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

echo "[*] unattended security upgrades"
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades


echo "[*] Done. Hardened with iptables."
