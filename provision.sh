#!/usr/bin/env bash

set -euo pipefail

# ─── Modern Color Palette & Icons ──────────────────────────────────────
INFO="\033[1;36m"    # Bright Cyan
SUCCESS="\033[1;32m" # Bright Green
ERROR="\033[1;31m"   # Bright Red
PROMPT="\033[1;35m"  # Magenta
RESET="\033[0m"       # Reset colors

ICON_INFO="ℹ"
ICON_SUCCESS="✔"
ICON_ERROR="✖"

# ─── Print helpers ─────────────────────────────────────────────────────
print_info()    { echo -e "${INFO}${ICON_INFO} ${1}${RESET}"; }
print_success() { echo -e "${SUCCESS}${ICON_SUCCESS} ${1}${RESET}"; }
print_error()   { echo -e "${ERROR}${ICON_ERROR} ${1}${RESET}"; }

# ─── Header Banner ────────────────────────────────────────────────────
print_banner() {
  clear
  cat <<-'EOF'
 _          _ _           
| |        | | |          
| |__   ___| | | ___      
| '_ \ / _ \ | |/ _ \     
| | | |  __/ | | (_) | _ _ 
|_| |_|\___|_|_|\___(_|_|_)
EOF
  print_info "Starting Debian 12 provisioning…"
}

# ─── Start ────────────────────────────────────────────────────────────
print_banner

# Check for root
if [[ $EUID -ne 0 ]]; then
  print_error "Please run as root."
  exit 1
fi

echo -e "${PROMPT}Do you want to continue provisioning? (y/N)${RESET}"
read -r CONTINUE
if [[ ! "$CONTINUE" =~ ^[Yy] ]]; then
  print_info "Exiting provisioning"
  exit 0
fi

# ─── Collect Choices ──────────────────────────────────────────────────

echo -e "${PROMPT}Extend root partition to full disk? (y/N)${RESET}"
read -r ans
EXTEND_PART=0
if [[ "$ans" =~ ^[Yy] ]]; then EXTEND_PART=1; fi

default_host=$(hostname)
echo -e "${PROMPT}Enter hostname [${default_host}]:${RESET}"
read -r NEW_HOST
NEW_HOST=${NEW_HOST:-$default_host}

echo -e "${PROMPT}Enter username:${RESET}"
read -r USERNAME

# Check if user exists
if id -u "${USERNAME}" &>/dev/null; then
  USER_EXISTS=1
  print_info "User '${USERNAME}' exists; will ensure sudo privileges later."
else
  USER_EXISTS=0
  # Force non-empty password
  echo -e "${PROMPT}Enter password for ${USERNAME}:${RESET}"
  while true; do
    read -rs PASSWORD
    echo
    if [[ -n "$PASSWORD" ]]; then
      break
    fi
    print_error "Password cannot be empty. Please enter a password:"
  done
  echo -e "${PROMPT}Enter public SSH key for ${USERNAME}:${RESET}"
  read -r PUBKEY
fi

echo -e "${PROMPT}Reboot after completion? (y/N)${RESET}"
read -r ans
REBOOT=0
if [[ "$ans" =~ ^[Yy] ]]; then REBOOT=1; fi

# ─── Summary & Confirmation ───────────────────────────────────────────
echo -e "${INFO}=======================================${RESET}"
echo -e "${INFO}     PROVISIONING SUMMARY     ${RESET}"
echo -e "${INFO}=======================================${RESET}"
echo -e "${SUCCESS} • Install packages${RESET}"
echo -e "${SUCCESS} • Regenerate SSH host keys${RESET}"
echo -e "${SUCCESS} • Harden OpenSSH and restart sshd${RESET}"
if [[ $EXTEND_PART -eq 1 ]]; then
  echo -e "${SUCCESS} • Extend root partition${RESET}"
fi

echo -e "${SUCCESS} • Set hostname: ${NEW_HOST}${RESET}"
echo -e "${SUCCESS} • "$( [[ $USER_EXISTS -eq 1 ]] && echo "Ensure existing user '${USERNAME}' has sudo" || echo "Create new user '${USERNAME}' with sudo" )"${RESET}"
echo -e "${SUCCESS} • Disable root account${RESET}"
if [[ $REBOOT -eq 1 ]]; then
  echo -e "${SUCCESS} • Reboot after completion${RESET}"
else
  echo -e "${SUCCESS} • No reboot${RESET}"
fi

echo -e "${PROMPT}Proceed with these actions? (y/N)${RESET}"
read -r CONF
if [[ ! "$CONF" =~ ^[Yy] ]]; then
  print_info "Provisioning canceled."
  exit 0
fi

# ─── Execute Actions with Checklist ───────────────────────────────────
echo -e "${INFO}Performing actions:${RESET}"

# 1. Install packages
echo -n " [ ] Install packages... "
if apt-get update -qq && apt-get install -y -qq openssh-server curl cloud-guest-utils; then
  echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] Install packages${RESET}"
else
  echo -e "\r ${ERROR}[${ICON_ERROR}] Install packages failed${RESET}"
fi

# 2. Regenerate SSH host keys
echo -n " [ ] Regenerate SSH host keys... "
if rm -f /etc/ssh/ssh_host_* && \
   ssh-keygen -q -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" && \
   ssh-keygen -q -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" && \
   awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.safe && mv /etc/ssh/moduli.safe /etc/ssh/moduli; then
  echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] SSH host keys regenerated${RESET}"
else
  echo -e "\r ${ERROR}[${ICON_ERROR}] SSH host keys failed${RESET}"
fi

# 3. Harden OpenSSH
echo -n " [ ] Harden OpenSSH... "
HARDEN_FILE=/etc/ssh/sshd_config.d/99-hardening.conf
TMP="${HARDEN_FILE}.new"
if curl -fsSL https://raw.githubusercontent.com/troponaut/openssh-hardening/main/sshd_config.d/99-hardening.conf -o "$TMP"; then
  mkdir -p "$(dirname "$HARDEN_FILE")"
  if [[ -f "$HARDEN_FILE" ]] && cmp -s "$TMP" "$HARDEN_FILE"; then
    rm "$TMP"
  else
    cp "$TMP" "$HARDEN_FILE"
  fi
  if sshd -t; then
    systemctl restart sshd
    echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] OpenSSH hardened${RESET}"
  else
    echo -e "\r ${ERROR}[${ICON_ERROR}] sshd config test failed${RESET}"
  fi
else
  echo -e "\r ${ERROR}[${ICON_ERROR}] OpenSSH hardening failed${RESET}"
fi

# 4. Partition expansion
echo -n " [ ] Extend partition... "
if [[ $EXTEND_PART -eq 1 ]]; then
  ROOTDEV=$(findmnt / -o SOURCE -n)
  DISK=/dev/$(lsblk -no pkname ${ROOTDEV})
  PARTNUM=${ROOTDEV##*[!0-9]}
  if growpart ${DISK} ${PARTNUM} && resize2fs ${ROOTDEV}; then
    echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] Partition extended${RESET}"
  else
    echo -e "\r ${ERROR}[${ICON_ERROR}] Partition failed${RESET}"
  fi
else
  echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] Partition skipped${RESET}"
fi

# 5. Set hostname
echo -n " [ ] Set hostname... "
hostnamectl set-hostname "${NEW_HOST}"
grep -q '^127\.0\.1\.1' /etc/hosts && \
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${NEW_HOST}/" /etc/hosts || \
  echo "127.0.1.1 ${NEW_HOST}" >> /etc/hosts
echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] Hostname set${RESET}"

# 6. Create/update user
echo -n " [ ] Create/update user... "
if [[ $USER_EXISTS -eq 1 ]]; then
  if id -nG "${USERNAME}" | grep -qw sudo; then
    echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] User in sudo group${RESET}"
  else
    usermod -aG sudo "${USERNAME}"
    echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] Added user to sudo group${RESET}"
  fi
else
  useradd -m -s /bin/bash "${USERNAME}"
  usermod -aG sudo "${USERNAME}"
  echo "${USERNAME}:${PASSWORD}" | chpasswd
  install -o ${USERNAME} -g ${USERNAME} -m 700 -d /home/${USERNAME}/.ssh
  echo "${PUBKEY}" > /home/${USERNAME}/.ssh/authorized_keys
  chmod 600 /home/${USERNAME}/.ssh/authorized_keys
  chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh
  echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] User created and configured${RESET}"
fi

# 7. Disable root
echo -n " [ ] Disable root... "
if passwd -d root && passwd -l root && usermod -s /usr/sbin/nologin root; then
  echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] Root disabled${RESET}"
else
  echo -e "\r ${ERROR}[${ICON_ERROR}] Root disable failed${RESET}"
fi

# 8. Reboot if requested
echo -n " [ ] Reboot system... "
if [[ $REBOOT -eq 1 ]]; then
  echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] Rebooting...${RESET}"
  sleep 1
  reboot
else
  echo -e "\r ${SUCCESS}[${ICON_SUCCESS}] No reboot${RESET}"
fi
