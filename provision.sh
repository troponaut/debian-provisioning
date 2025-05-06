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

# ─── Cleanup & exit on error ─────────────────────────────────────────────
cleanup() {
  print_error "Provisioning aborted by user or error."
  clear
  exit 1
}

# ─── Header Banner Function ─────────────────────────────────────────────
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
  print_info "Starting Debian 12 provisioning… (Cancel any dialog to abort)"
}

# ─── Start Provisioning ────────────────────────────────────────────────
print_banner
print_info "Loading…"
sleep 2

# ─── Ensure running as root ─────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  print_error "Please run as root."
  exit 1
fi

# ─── Confirm to Continue ───────────────────────────────────────────────
if whiptail --yesno "Do you want to continue provisioning?" 8 50; then
  print_info "Continuing provisioning"
else
  print_info "Exiting provisioning"
  clear
  exit 0
fi

### ─── 1. Root Password Configuration ──────────────────────────────────
if whiptail --yesno "Remove root password? (recommended)" 8 50; then
  print_info "Removing root password"
  passwd -d root
  print_success "Root password removed"
else
  ROOT_PASS=$(whiptail --passwordbox "Enter new root password:" 8 50 3>&1 1>&2 2>&3)
  print_info "Setting root password"
  echo "root:${ROOT_PASS}" | chpasswd
  print_success "Root password set"
fi

### ─── 2. Install Required Packages ────────────────────────────────────
print_info "Installing: openssh-server, curl, cloud-guest-utils"
apt-get update -qq
if apt-get install -y -qq openssh-server curl cloud-guest-utils; then
  print_success "Packages installed"
else
  print_error "Package installation failed, continuing anyway"
fi

### ─── 3. Regenerate SSH Host Keys & Prune Moduli ───────────────────────
print_info "Regenerating SSH host keys"
rm -f /etc/ssh/ssh_host_*
ssh-keygen -q -t rsa     -b 4096 -f /etc/ssh/ssh_host_rsa_key   -N ""
ssh-keygen -q -t ed25519 -f /etc/ssh/ssh_host_ed25519_key     -N ""
awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.safe
mv /etc/ssh/moduli.safe /etc/ssh/moduli
print_success "SSH host keys regenerated"

### ─── 4. Hardening OpenSSH (idempotent) ────────────────────────────────
print_info "Applying OpenSSH hardening"
HARDEN_FILE=/etc/ssh/sshd_config.d/99-hardening.conf
TMP_FILE="${HARDEN_FILE}.new"
if curl -fsSL https://raw.githubusercontent.com/troponaut/openssh-hardening/refs/heads/main/sshd_config.d/99-hardening.conf -o "$TMP_FILE"; then
  mkdir -p "$(dirname "$HARDEN_FILE")"
  if [[ -f "$HARDEN_FILE" ]]; then
    if ! cmp -s "$TMP_FILE" "$HARDEN_FILE"; then
      cp "$HARDEN_FILE" "${HARDEN_FILE}.bak-$(date +%s)"
      mv "$TMP_FILE" "$HARDEN_FILE"
      print_success "Hardening config updated, backup created"
    else
      rm "$TMP_FILE"
      print_success "Hardening config unchanged, skipped"
    fi
  else
    mv "$TMP_FILE" "$HARDEN_FILE"
    print_success "Hardening config installed"
  fi
else
  print_error "Failed to fetch hardening config, skipping"
fi

### ─── 5. Test & Restart sshd ──────────────────────────────────────────
print_info "Testing sshd configuration"
if sshd -t; then
  systemctl restart sshd && print_success "sshd restarted"
else
  print_error "sshd configuration test failed, skipping restart"
fi

### ─── 6. Create (or Skip) Non-Root User ─────────────────────────────────
USERNAME=$(whiptail --inputbox "Enter new username:" 8 40 3>&1 1>&2 2>&3)
if id -u "${USERNAME}" &>/dev/null; then
  print_info "User '${USERNAME}' exists."
  ACTION=$(whiptail --menu "Manage SSH key for user?" 10 50 3 \
    replace "Overwrite existing key" \
    append  "Append to existing key" \
    skip    "Leave existing keys unchanged" 3>&1 1>&2 2>&3)
  AUTHFILE="/home/${USERNAME}/.ssh/authorized_keys"
  if [[ "$ACTION" == "replace" ]]; then
    whiptail --msgbox "Existing key will be replaced." 8 50
    echo "$(whiptail --inputbox "New public key:" 10 60 3>&1 1>&2 2>&3)" > "$AUTHFILE"
    chown ${USERNAME}:${USERNAME} "$AUTHFILE"
    chmod 600 "$AUTHFILE"
    print_success "SSH key replaced for ${USERNAME}"
  elif [[ "$ACTION" == "append" ]]; then
    whiptail --msgbox "New key will be appended." 8 50
    echo "$(whiptail --inputbox "New public key:" 10 60 3>&1 1>&2 2>&3)" >> "$AUTHFILE"
    chown ${USERNAME}:${USERNAME} "$AUTHFILE"
    chmod 600 "$AUTHFILE"
    print_success "SSH key appended for ${USERNAME}"
  else
    print_info "Skipping SSH key management for ${USERNAME}"
  fi
else
  print_info "Creating user '${USERNAME}'"
  PASSWORD=$(whiptail --passwordbox "Password for ${USERNAME}:" 8 50 3>&1 1>&2 2>&3)
  PUBKEY=$(whiptail --inputbox "Public SSH key for ${USERNAME}:" 10 60 3>&1 1>&2 2>&3)
  useradd -m -s /bin/bash "${USERNAME}"
  echo "${USERNAME}:${PASSWORD}" | chpasswd
  install -o ${USERNAME} -g ${USERNAME} -m 700 -d /home/${USERNAME}/.ssh
  echo "${PUBKEY}" > /home/${USERNAME}/.ssh/authorized_keys
  chmod 600 /home/${USERNAME}/.ssh/authorized_keys
  chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh
  print_success "User '${USERNAME}' created"
  if whiptail --yesno "Add ${USERNAME} to sudo group?" 8 50; then
    usermod -aG sudo "${USERNAME}" && print_success "Added to sudo"
  fi
fi

### ─── 7. Optional Partition Expansion (guarded) ─────────────────────────
MARKER=/var/provision_partition_done
if [[ ! -f $MARKER ]]; then
  if whiptail --yesno "Extend root partition to full disk?" 8 50; then
    print_info "Expanding root partition"
    ROOTDEV=$(findmnt / -o SOURCE -n)
    DISK=/dev/$(lsblk -no pkname ${ROOTDEV})
    PARTNUM=${ROOTDEV##*[!0-9]}
    if growpart ${DISK} ${PARTNUM} && resize2fs ${ROOTDEV}; then
      touch $MARKER
      print_success "Partition expanded"
    else
      print_error "Partition expansion failed, skipping"
    fi
  else
    print_success "Partition expansion skipped"
  fi
else
  print_success "Partition already expanded, skipping"
fi

### ─── 8. Set Hostname & Update /etc/hosts ─────────────────────────────
NEWHOST=$(whiptail --inputbox "Enter hostname:" 8 40 "$(hostname)" 3>&1 1>&2 2>&3)
print_info "Setting hostname to ${NEWHOST}"
hostnamectl set-hostname "${NEWHOST}"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${NEWHOST}/" /etc/hosts
else
  echo "127.0.1.1 ${NEWHOST}" >> /etc/hosts
fi
print_success "Hostname set to ${NEWHOST}"

### ─── 9. Completion & Optional Reboot ─────────────────────────────────
if whiptail --yesno "Provisioning complete. Reboot now?" 8 50; then
  print_info "Rebooting system..."
  sleep 1
  reboot
else
  print_success "Provisioning finished. Exiting."
  clear
  exit 0
fi
