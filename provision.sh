#!/usr/bin/env bash
set -euo pipefail

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  whiptail --msgbox "This script must be run as root." 8 40
  exit 1
fi

# 1. Remove root password
whiptail --infobox "Removing root password..." 6 50
passwd -d root

# 2. Install necessary packages
whiptail --infobox "Installing OpenSSH Server, curl, cloud-guest-utils..." 6 60
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  openssh-server curl cloud-guest-utils whiptail

# 3. Regenerate SSH host keys & harden moduli
whiptail --infobox "Rebuilding SSH host keys & pruning weak moduli..." 6 60
rm -f /etc/ssh/ssh_host_*
ssh-keygen -q -t rsa     -b 4096 -f /etc/ssh/ssh_host_rsa_key     -N ""
ssh-keygen -q -t ed25519    -f /etc/ssh/ssh_host_ed25519_key       -N ""
awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.safe
mv /etc/ssh/moduli.safe /etc/ssh/moduli

# 4. Fetch hardening config
whiptail --infobox "Fetching OpenSSH hardening config..." 6 60
mkdir -p /etc/ssh/sshd_config.d
curl -fsSL \
  https://raw.githubusercontent.com/troponaut/openssh-hardening/refs/heads/main/sshd_config.d/99-hardening.conf \
  -o /etc/ssh/sshd_config.d/99-hardening.conf

# 5. Test and restart sshd
whiptail --infobox "Testing sshd configuration..." 6 50
if sshd -t; then
  systemctl restart sshd
else
  whiptail --msgbox "sshd test failed – please check /etc/ssh/sshd_config*" 8 60
  exit 1
fi

# 6. Create (or skip) a non-root user
USERNAME=$(whiptail --inputbox "Enter the new username:" 8 40 3>&1 1>&2 2>&3)
if id -u "$USERNAME" &>/dev/null; then
  whiptail --msgbox "User '$USERNAME' already exists – skipping creation." 8 50
else
  # password
  PASSWORD=$(whiptail --passwordbox "Enter password for $USERNAME:" 8 50 3>&1 1>&2 2>&3)
  # ssh key
  PUBKEY=$(whiptail --inputbox "Paste public SSH key for $USERNAME:" 10 60 3>&1 1>&2 2>&3)

  whiptail --infobox "Creating user $USERNAME…" 6 50
  useradd -m -s /bin/bash "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  # SSH setup
  su - "$USERNAME" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  echo "$PUBKEY" > /home/"$USERNAME"/.ssh/authorized_keys
  chmod 600 /home/"$USERNAME"/.ssh/authorized_keys
  chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"/.ssh

  # optional sudo
  if whiptail --yesno "Add $USERNAME to sudo group?" 8 50; then
    usermod -aG sudo "$USERNAME"
  fi
fi

# 7. Optional partition expansion
if whiptail --yesno "Extend root partition to fill the disk?" 8 50; then
  whiptail --infobox "Expanding partition… please wait." 6 50

  # detect root device and partition number
  ROOTPART=$(findmnt / -o SOURCE -n)
  DISK="/dev/$(lsblk -no pkname "$ROOTPART")"
  PARTNUM="${ROOTPART##*[!0-9]}"

  # grow partition and filesystem
  growpart "$DISK" "$PARTNUM"
  resize2fs "$ROOTPART"
fi

# 8. Set hostname and update /etc/hosts
NEWHOST=$(whiptail --inputbox "Enter the new hostname:" 8 40 "$(hostname)" 3>&1 1>&2 2>&3)
whiptail --infobox "Setting hostname to $NEWHOST…" 6 50
hostnamectl set-hostname "$NEWHOST"
# update /etc/hosts: replace or append 127.0.1.1 line
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEWHOST/" /etc/hosts
else
  echo "127.0.1.1 $NEWHOST" >> /etc/hosts
fi

whiptail --msgbox "Provisioning complete!" 8 40
exit 0
