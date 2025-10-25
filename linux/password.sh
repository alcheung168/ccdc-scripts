#!/bin/sh
# Bulk password reset tool (with configurable root account name)
# Usage:
#   sudo ROOTUSER="sysadmin" ROOTPASS="SuperSecurePass" SSHUSER="admin" PASS="AdminPass123" ./reset_passwords.sh "<OTHER_USERS_PASSWORD>"
#   # If your superuser is the default 'root', you can omit ROOTUSER=
#
# Effect:
#   - $ROOTUSER -> password set to $ROOTPASS
#   - $SSHUSER  -> password set to $PASS
#   - all other users with interactive shells -> password set to first argument ("<OTHER_USERS_PASSWORD>")

set -eu

# --- config / defaults ---
ROOTUSER="${ROOTUSER:-root}"   # allow systems where the superuser isn't named "root"

# --- safety checks ---
if [ $# -lt 1 ]; then
  echo "ERROR: Missing required argument for other users' password."
  echo "Usage: ROOTPASS=... [ROOTUSER=...] [SSHUSER=... PASS=...] $0 \"<OTHER_USERS_PASSWORD>\""
  exit 1
fi
OTHERPASS="$1"

# Require a root password to avoid lockout of the superuser
if [ -z "${ROOTPASS:-}" ]; then
  echo "ERROR: ROOTPASS is not specified. Exiting to prevent lockout."
  exit 1
fi

# If one of SSHUSER/PASS is set, require the other as well
if [ -n "${SSHUSER:-}" ] && [ -z "${PASS:-}" ]; then
  echo "ERROR: SSHUSER is defined, but PASS is not. Exiting to prevent lockout."
  exit 1
fi
if [ -z "${SSHUSER:-}" ] && [ -n "${PASS:-}" ]; then
  echo "ERROR: PASS is defined, but SSHUSER is not. Exiting to prevent lockout."
  exit 1
fi

# Ensure an unmatched placeholder if SSHUSER not provided
if [ -z "${SSHUSER:-}" ]; then
  SSHUSER="__NO_SUCH_USER__"
fi

# --- password change helper ---
CHANGEPASSWORD() {
  user="$1"
  newpass="$2"

  if command -v chpasswd >/dev/null 2>&1; then
    # chpasswd reads "user:pass" from stdin
    printf '%s:%s\n' "$user" "$newpass" | chpasswd
  elif command -v passwd >/dev/null 2>&1; then
    # passwd expects the password twice on stdin (non-interactive)
    # shellcheck disable=SC2005
    printf '%s\n%s\n' "$newpass" "$newpass" | passwd "$user" >/dev/null 2>&1
  else
    echo "ERROR: Neither 'chpasswd' nor 'passwd' found."
    exit 1
  fi
}

echo "username,password"

# Iterate over users with an interactive shell (anything whose shell ends with 'sh')
# This includes /bin/bash, /bin/sh, /usr/bin/zsh, etc., and excludes nologin/false.
for user in $(awk -F: '$7 ~ /sh$/ {print $1}' /etc/passwd); do
  if [ "$user" = "$ROOTUSER" ]; then
    CHANGEPASSWORD "$user" "$ROOTPASS"
    echo "$user,$ROOTPASS"
  elif [ "$user" = "$SSHUSER" ]; then
    CHANGEPASSWORD "$user" "$PASS"
    echo "$user,$PASS"
  else
    CHANGEPASSWORD "$user" "$OTHERPASS"
    echo "$user,$OTHERPASS"
  fi
done
