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

# vagrant-vbguest — keeps Guest Additions in every VM matched to the host's
# VirtualBox version; mismatches show up as broken shared folders or
# kernel-module build failures on boxes like kalilinux/rolling
vagrant plugin install vagrant-vbguest
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

## Optional: Splunk license

A Splunk Enterprise license file at `splunk/Splunk.License` (gitignored, not
tracked in this repo) is optional — see [Splunk](splunk.html). Without one,
`ENABLE_SPLUNK=true` still works, just in Splunk Free/Trial mode.

→ [Usage](usage.html)
