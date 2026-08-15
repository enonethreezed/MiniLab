# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Lab SOC/Blue Team — SIEM (ELK 8.x by default, Splunk optional) + Windows
# Server 2022 + Windows 11
# Red: 192.168.56.0/24 (host-only)
#   SIEM:       192.168.56.10
#   WinServer:  192.168.56.20
#   Win11:      192.168.56.30

SIEM_IP      = "192.168.56.10"
WSRV_IP      = "192.168.56.20"
WIN11_IP     = "192.168.56.30"
KALI_IP      = "192.168.56.100"
DOMAIN_NAME  = "minilab.local"

# Hyper-V has no automatic host-only network like VirtualBox's vboxnet0 - the
# private_network stanzas below pin every VM's NIC to this named switch.
# One-time host setup (elevated PowerShell), before the first
# `vagrant up --provider=hyperv`:
#   New-VMSwitch -SwitchName MiniLabSwitch -SwitchType Internal
# Deliberately "Internal" (host<->guests only), not "External"/bridged: that
# keeps the fixed 192.168.56.0/24 addressing above and matches the
# VirtualBox side, where this lab is host-only-only, not reachable from the
# rest of the LAN.
HYPERV_SWITCH = "MiniLabSwitch"

if ENV["ENABLE_SPLUNK"] == "true" && ENV["ENABLE_WAZUH"] == "true"
  abort "ENABLE_SPLUNK and ENABLE_WAZUH are mutually exclusive - set at " \
        "most one (leave both unset for the default, ELK)."
end

Vagrant.configure("2") do |config|

  # ──────────────────────────────────────────────────────────────────────────
  # 1. SIEM  (Debian Bookworm) - ELK by default, Splunk with ENABLE_SPLUNK=1,
  #    Wazuh with ENABLE_WAZUH=1. Mutually exclusive: only one SIEM stack is
  #    provisioned per run.
  # ──────────────────────────────────────────────────────────────────────────
  config.vm.define "siem" do |siem|
    # generic/debian12, not debian/bookworm64: the official box dropped its
    # hyperv build entirely (recent releases ship libvirt only) - generic/
    # debian12 is the same Debian 12 (bookworm) but published for
    # virtualbox/hyperv/libvirt/vmware_desktop alike.
    siem.vm.box      = "generic/debian12"
    siem.vm.hostname = "siem"

    siem.vm.network "private_network", ip: SIEM_IP, hyperv__switch_name: HYPERV_SWITCH
    # Kibana accesible desde el host en http://localhost:5601
    siem.vm.network "forwarded_port", guest: 5601, host: 5601, host_ip: "127.0.0.1"
    # Elasticsearch (opcional para consultas directas)
    siem.vm.network "forwarded_port", guest: 9200, host: 9200,  host_ip: "127.0.0.1"
    siem.vm.network "forwarded_port", guest: 8220, host: 18220, host_ip: "127.0.0.1"
    # Splunk Web + splunkd management REST API (ENABLE_SPLUNK=1)
    siem.vm.network "forwarded_port", guest: 8000, host: 8000, host_ip: "127.0.0.1"
    siem.vm.network "forwarded_port", guest: 8089, host: 8089, host_ip: "127.0.0.1"
    # Wazuh dashboard + manager API (ENABLE_WAZUH=1)
    siem.vm.network "forwarded_port", guest: 443, host: 4430, host_ip: "127.0.0.1"
    siem.vm.network "forwarded_port", guest: 55000, host: 55000, host_ip: "127.0.0.1"
    # Guacamole web UI (optional, ENABLE_GUACAMOLE=true) - localhost-only, same
    # as everything else in this lab. Keeps the host closed to inbound traffic
    # by default (no ufw exception needed for this port).
    siem.vm.network "forwarded_port", guest: 8080, host: 8280, host_ip: "127.0.0.1"
    # Velociraptor (optional, ENABLE_VELOCIRAPTOR=true) - GUI + client-server
    # frontend. Frontend is 8001, not Velociraptor's 8000 default, since that
    # clashes with Splunk Web on this same VM (ENABLE_SPLUNK=1).
    siem.vm.network "forwarded_port", guest: 8889, host: 8889, host_ip: "127.0.0.1"
    siem.vm.network "forwarded_port", guest: 8001, host: 8001, host_ip: "127.0.0.1"

    siem.vm.provider "virtualbox" do |vb|
      vb.name   = "SOC-SIEM"
      # 12GB: leaves headroom for guacd + Tomcat/Guacamole webapp
      # (ENABLE_GUACAMOLE=true) on top of ES(3g heap)+Kibana+Logstash+Fleet,
      # or Splunk Enterprise's indexer/search head when ENABLE_SPLUNK=1.
      # vb.memory = 12288
      vb.memory = 8192
      vb.cpus   = 2
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end

    siem.vm.provider "hyperv" do |hv|
      hv.vmname       = "SOC-SIEM"
      hv.memory       = 8192
      hv.cpus         = 2
      hv.linked_clone = true
    end

    if ENV["ENABLE_SPLUNK"] == "true"
      # Splunk dev license lives only on the host (splunk/Splunk.License,
      # gitignored) - upload it before the provisioner that consumes it, if
      # present. Not required: splunk-provision.sh falls back to Splunk
      # Free/Trial mode when no valid license is found (see MiniLab-cnu).
      if File.exist?("splunk/Splunk.License")
        siem.vm.provision "file", source: "splunk/Splunk.License",
          destination: "/tmp/Splunk.License"
      end

      siem.vm.provision "shell", name: "setup-splunk",
        path: "scripts/splunk-provision.sh",
        args: [SIEM_IP]
    elsif ENV["ENABLE_WAZUH"] == "true"
      siem.vm.provision "shell", name: "setup-wazuh",
        path: "scripts/wazuh-provision.sh",
        args: [SIEM_IP]
    else
      siem.vm.provision "shell", name: "setup-elk", path: "scripts/elk-provision.sh",
        env: { "ELK_IP" => SIEM_IP }
    end

    # Optional Guacamole (HTML5 RDP/SSH gateway) - lets you reach winserver/
    # win11 RDP sessions and siem's own SSH from a browser, no local RDP/SSH
    # client needed. Off by default (extra RAM/CPU, another moving part);
    # opt in with ENABLE_GUACAMOLE=true. guacamole-server isn't packaged for
    # Debian at all (pulled from Debian entirely in 2024) - Docker Compose
    # with the official images is the actual supported install path.
    if ENV["ENABLE_GUACAMOLE"] == "true"
      siem.vm.provision "shell", name: "docker-setup", path: "scripts/docker-setup.sh"

      siem.vm.provision "shell", name: "guacamole-setup",
        path: "scripts/guacamole-setup.sh",
        args: [WSRV_IP, WIN11_IP, DOMAIN_NAME.split(".")[0].upcase]
    end

    # Optional Velociraptor (live triage / VQL hunting console) - additive
    # alongside whichever SIEM stack is running, not mutually exclusive with
    # ENABLE_SPLUNK/ENABLE_WAZUH. Off by default; opt in with
    # ENABLE_VELOCIRAPTOR=true.
    if ENV["ENABLE_VELOCIRAPTOR"] == "true"
      siem.vm.provision "shell", name: "velociraptor-setup",
        path: "scripts/velociraptor-provision.sh",
        args: [SIEM_IP]
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 2. Windows Server 2022
  # ──────────────────────────────────────────────────────────────────────────
  config.vm.define "winserver" do |ws|
    ws.vm.box      = "gusztavvargadr/windows-server-2022-standard"
    ws.vm.hostname = "WIN-SRV22"

    ws.vm.network "private_network", ip: WSRV_IP, hyperv__switch_name: HYPERV_SWITCH
    # RDP desde el host
    ws.vm.network "forwarded_port", guest: 3389, host: 13389, host_ip: "127.0.0.1"

    ws.vm.communicator      = "winrm"
    # Administrator, not the local 'vagrant' account: promoting this VM to a
    # Domain Controller replaces the local SAM with the domain database, so
    # the local 'vagrant' account stops being a valid login afterward. The
    # built-in Administrator account (RID 500) becomes the domain
    # Administrator with the same password, and is a Domain Admin by
    # definition - no separate credential bootstrap needed.
    ws.winrm.username       = "Administrator"
    ws.winrm.password       = "vagrant"
    ws.winrm.transport      = :plaintext
    ws.winrm.basic_auth_only = true
    ws.winrm.timeout        = 300
    ws.winrm.retry_limit    = 20

    ws.vm.provider "virtualbox" do |vb|
      vb.name   = "SOC-WinServer2022"
      # vb.memory = 4096
      vb.memory = 6192
      vb.cpus   = 2
      vb.gui    = false
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      vb.customize ["modifyvm", :id, "--clipboard", "bidirectional"]
    end

    # No Hyper-V equivalent for the vb.customize calls above (NAT DNS
    # passthrough, clipboard integration) - Hyper-V has its own Enhanced
    # Session Mode for clipboard, unrelated to Vagrant provider config.
    ws.vm.provider "hyperv" do |hv|
      hv.vmname       = "SOC-WinServer2022"
      hv.memory       = 6192
      hv.cpus         = 2
      hv.linked_clone = true
    end

    ws.vm.provision "shell", name: "setup", privileged: true,
      path: "scripts/winserver-baseline.ps1"

    ws.vm.provision "shell", name: "defender-telemetry", privileged: true,
      path: "scripts/winserver-defender-telemetry.ps1"

    ws.vm.provision "shell", name: "audit-policy", privileged: true,
      path: "scripts/winserver-audit-policy.ps1"

    ws.vm.provision "shell", name: "powershell-transcription", privileged: true,
      path: "scripts/winserver-powershell-transcription.ps1"

    ws.vm.provision "shell", name: "firewall-logging", privileged: true,
      path: "scripts/winserver-firewall-logging.ps1"

    if ENV["ENABLE_SPLUNK"] == "true"
      ws.vm.provision "shell", name: "splunk-forwarder", privileged: true,
        path: "scripts/winserver-splunk-forwarder.ps1",
        args: [SIEM_IP]
    elsif ENV["ENABLE_WAZUH"] == "true"
      ws.vm.provision "shell", name: "wazuh-agent", privileged: true,
        path: "scripts/winserver-wazuh-agent.ps1",
        args: [SIEM_IP]
    else
      ws.vm.provision "shell", name: "elastic-agent", privileged: true,
        path: "scripts/winserver-elastic-agent.ps1",
        args: [SIEM_IP]
    end

    if ENV["ENABLE_VELOCIRAPTOR"] == "true"
      ws.vm.provision "shell", name: "velociraptor-agent", privileged: true,
        path: "scripts/winserver-velociraptor-agent.ps1"
    end

    ws.vm.provision "shell", name: "ad-domain", privileged: true,
      path: "scripts/ad-domain-setup.ps1",
      args: [DOMAIN_NAME],
      reboot: true

    # After ad-domain, not with the other telemetry provisioners above -
    # needs the DNS Server role, which only exists once ad-domain-setup.ps1
    # has promoted this box to a DC (-InstallDns:$true).
    ws.vm.provision "shell", name: "dns-telemetry", privileged: true,
      path: "scripts/winserver-dns-telemetry.ps1"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 3. Windows 11 (estación de trabajo)
  # ──────────────────────────────────────────────────────────────────────────
  config.vm.define "win11" do |w11|
    w11.vm.box      = "gusztavvargadr/windows-11"
    w11.vm.hostname = "WIN11-WS01"

    w11.vm.network "private_network", ip: WIN11_IP, hyperv__switch_name: HYPERV_SWITCH
    # RDP desde el host (puerto distinto al del servidor)
    w11.vm.network "forwarded_port", guest: 3389, host: 23389, host_ip: "127.0.0.1"

    w11.vm.communicator      = "winrm"
    w11.winrm.username       = "vagrant"
    w11.winrm.password       = "vagrant"
    w11.winrm.transport      = :plaintext
    w11.winrm.basic_auth_only = true
    w11.winrm.timeout        = 300
    w11.winrm.retry_limit    = 20

    w11.vm.provider "virtualbox" do |vb|
      vb.name   = "SOC-Win11-WS"
      # vb.memory = 4096
      vb.memory = 6192
      vb.cpus   = 2
      vb.gui    = false
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      vb.customize ["modifyvm", :id, "--clipboard", "bidirectional"]
    end

    w11.vm.provider "hyperv" do |hv|
      hv.vmname       = "SOC-Win11-WS"
      hv.memory       = 6192
      hv.cpus         = 2
      hv.linked_clone = true
    end

    w11.vm.provision "shell", name: "setup", privileged: true,
      path: "scripts/win11-baseline.ps1"

    w11.vm.provision "shell", name: "defender-telemetry", privileged: true,
      path: "scripts/win11-defender-telemetry.ps1"

    w11.vm.provision "shell", name: "audit-policy", privileged: true,
      path: "scripts/win11-audit-policy.ps1"

    w11.vm.provision "shell", name: "powershell-transcription", privileged: true,
      path: "scripts/win11-powershell-transcription.ps1"

    w11.vm.provision "shell", name: "firewall-logging", privileged: true,
      path: "scripts/win11-firewall-logging.ps1"

    w11.vm.provision "shell", name: "dns-telemetry", privileged: true,
      path: "scripts/win11-dns-telemetry.ps1"

    if ENV["ENABLE_SPLUNK"] == "true"
      w11.vm.provision "shell", name: "splunk-forwarder", privileged: true,
        path: "scripts/win11-splunk-forwarder.ps1",
        args: [SIEM_IP]
    elsif ENV["ENABLE_WAZUH"] == "true"
      w11.vm.provision "shell", name: "wazuh-agent", privileged: true,
        path: "scripts/win11-wazuh-agent.ps1",
        args: [SIEM_IP]
    else
      w11.vm.provision "shell", name: "elastic-agent", privileged: true,
        path: "scripts/win11-elastic-agent.ps1",
        args: [SIEM_IP]
    end

    if ENV["ENABLE_VELOCIRAPTOR"] == "true"
      w11.vm.provision "shell", name: "velociraptor-agent", privileged: true,
        path: "scripts/win11-velociraptor-agent.ps1"
    end

    w11.vm.provision "shell", name: "domain-join", privileged: true,
      path: "scripts/domain-join.ps1",
      args: [WSRV_IP, DOMAIN_NAME],
      reboot: true
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 4. Kali Linux (optional, ENABLE_KALI=true)
  # ──────────────────────────────────────────────────────────────────────────
  if ENV["ENABLE_KALI"] == "true"
    config.vm.define "kali" do |kali|
      kali.vm.box      = "kalilinux/rolling"
      kali.vm.hostname = "kali-atk"

      kali.vm.network "private_network", ip: KALI_IP, hyperv__switch_name: HYPERV_SWITCH

      kali.vm.provider "virtualbox" do |vb|
        vb.name   = "SOC-Kali"
        vb.gui    = false
        vb.memory = "2048"
      end

      kali.vm.provider "hyperv" do |hv|
        hv.vmname       = "SOC-Kali"
        hv.memory       = 2048
        hv.linked_clone = true
      end
    end
  end

end
