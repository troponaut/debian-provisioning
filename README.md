# Debian 12 (Cloud Image) Provisioning Script

This repository contains a single Bash script, `provision.sh`, designed to automate the initial setup and hardening of a freshly installed Debian 12 cloud image.

## Features

- **Root account disablement**: Removes root password, locks the account, and sets shell to nologin.
- **Package installation**: Installs `openssh-server`, `curl`, and `cloud-guest-utils`.
- **SSH hardening**:
  - Regenerates RSA (4096‑bit) and Ed25519 host keys.
  - Prunes weak Diffie–Hellman moduli.
  - Applies a best‑practice OpenSSH configuration from [troponaut/openssh‑hardening](https://github.com/troponaut/openssh-hardening).
  - Verifies the SSH daemon configuration before restarting.
- **Optional partition expansion**: Offers to grow the root partition to fill the disk.
- **Hostname configuration**: Prompts for and sets the system hostname, updating `/etc/hosts`.
- **Non‑root user creation**: Prompts for username, password, and SSH key; creates or updates the account with sudo access.
- **Execution checklist**: Displays a real‑time report of each action with success/failure indicators.
- **Optional reboot**: Offers to reboot the system at the end.

## Prerequisites

- A fresh Debian 12 (Bookworm) installation
- Internet connectivity during provisioning
- `bash`, `curl`, and `sudo` available

## Quick Start

To download and execute (as root) the provisioning script in one step, run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

```

Alternatively, you can manually fetch and inspect before running:

```bash
curl -fsSL https://raw.githubusercontent.com/troponaut/debian-provisioning/main/provision.sh -o provision.sh
chmod +x provision.sh
sudo ./provision.sh
```

## Repository Structure

```
provision.sh   # Main provisioning script
README.md      # This documentation
```

## Customization

Feel free to fork and adapt the script:

- Modify the list of packages to install in the **Install packages** section.
- Swap out or tweak the OpenSSH hardening rules.
- Add additional setup steps (e.g., firewall rules, package mirrors, locale settings).

---

*Maintained by [troponaut](https://github.com/troponaut)*
