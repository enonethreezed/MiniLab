---
title: Installation
layout: default
nav_order: 2
---

# Installation Guide
{: .no_toc }

Requirements and one-time setup, from a bare host to a `vagrant up`-ready machine.
{: .fs-6 .fw-300 }

---

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Ubuntu 26.04 LTS (or similar Debian-based)

```bash
# VirtualBox — available directly in Ubuntu's multiverse repo
sudo add-apt-repository multiverse   # if not already enabled
sudo apt update
sudo apt install -y virtualbox virtualbox-ext-pack virtualbox-dkms

# Vagrant — HashiCorp's own apt repo, not in Ubuntu's default repos
wget -qO- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install -y vagrant
```

WinRM support (used to provision the Windows VMs) is bundled into Vagrant
core — no extra plugin needed.

Confirm hardware virtualization is available (VT-x/AMD-V — enable in
BIOS/UEFI if the count is 0):

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
```

## Optional: `tests/check-domain.sh` verification tooling

```bash
sudo apt install -y nmap ldap-utils samba-common-bin smbclient
```

`tests/check-lab.sh` only needs `curl` and `python3`, both present by
default on Ubuntu.

## Resources

- Available RAM: 24 GB minimum, 28+ GB recommended (`siem` alone uses 12 GB,
  sized for Guacamole; `winserver`/`win11` use 4 GB each)
- Disk space: ~40 GB (Windows boxes are large)

## Windows host with Hyper-V

Alternative to VirtualBox — `.\install.ps1 -Provider hyperv` instead of
VirtualBox. Requirements, all one-time:

- Windows 10/11 **Pro/Enterprise/Education**, or Windows Server — Hyper-V
  isn't available on Home editions.
- Enable the feature (requires a reboot):
  ```powershell
  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
  ```
- Create the lab's virtual switch (elevated PowerShell):
  ```powershell
  New-VMSwitch -SwitchName MiniLabSwitch -SwitchType Internal
  ```
  `Internal`, not `External` — keeps the lab on its fixed 192.168.56.0/24
  addressing and closed to the rest of the LAN, matching the VirtualBox
  side. See the comment at the top of the `Vagrantfile` for details.
- Vagrant itself needs no extra plugin (Hyper-V support is built in), but
  every `vagrant up` / `install.ps1` call must run from an **elevated**
  PowerShell session, or the provider fails to create VMs.

Once up, `forwarded_port` doesn't apply under Hyper-V — see
[Hyper-V provider](usage.html#hyper-v-provider-windows-host) in Usage for
how to reach each service by IP instead of `localhost`.

## Optional: Splunk license

A Splunk Enterprise license file at `splunk/Splunk.License` (gitignored, not
tracked in this repo) is optional — see [Splunk](splunk.html). Without one,
`ENABLE_SPLUNK=true` still works, just in Splunk Free/Trial mode.

→ [Usage](usage.html)
