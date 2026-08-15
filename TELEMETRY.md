# MiniLab Logging & Telemetry Roadmap

## Purpose

MiniLab is a portable Blue Team and detection-engineering laboratory built around Windows Server, Windows 11, Active Directory, Sysmon, and interchangeable SIEM platforms such as ELK, Splunk, and Wazuh.

The logging layer should therefore not be treated simply as a mechanism for forwarding more events to the SIEM.

The objective is to provide a **reproducible Windows telemetry environment** in which an analyst can:

1. Generate controlled activity.
2. Observe the resulting telemetry.
3. Understand the relationship between Windows events and attacker behavior.
4. Build detections.
5. Validate that detections work.
6. Repeat the same experiment across different SIEM platforms.

The desired evolution is:

```text
                         ┌── Windows Security
                         ├── Sysmon
                         ├── PowerShell
Windows endpoints ───────┼── Defender
                         ├── Firewall
                         ├── DNS
                         └── Active Directory
                                  │
                                  ▼
                         Telemetry pipeline
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
                   ELK          Splunk         Wazuh
                    │             │             │
                    └─────────────┼─────────────┘
                                  ▼
                         Detection engineering
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
               Detection rules            Validation tests
                    │                           │
                    └─────────────┬─────────────┘
                                  ▼
                         Reproducible results
```

---

## 1. Windows Advanced Audit Policy

**Status: implemented (bd `MiniLab-e40`, GitHub #18).** `winserver/win11-audit-policy.ps1` enable success+failure auditing at the *category* level (Account Logon, Account Management, Detailed Tracking, DS Access, Logon/Logoff, Object Access, Policy Change, Privilege Use) plus the `ProcessCreationIncludeCmdLine_Enabled` registry key for command-line arguments on 4688. The 12 bullet points below collapse into those 8 categories — e.g. "Kerberos Authentication"/"Kerberos Service Ticket Operations" are both subcategories already covered by enabling "Account Logon" wholesale, same for "Directory Service Access"/"Directory Service Changes" under "DS Access". No SIEM-side change needed: it's all Security channel, already collected everywhere — on ELK specifically that's the `system` integration (`system-1`), not `windows`; Elastic's own docs are explicit that Security/Application/System channel collection was moved out of the `windows` package into `system` as of 7.11.

Configure explicit Windows auditing rather than depending on the defaults of the Windows image.

The lab should enable relevant audit categories including:

- Account Logon
- Account Management
- Logon/Logoff
- Process Creation
- Object Access
- Policy Change
- Privilege Use
- Detailed Tracking
- Directory Service Access
- Directory Service Changes
- Kerberos Authentication
- Kerberos Service Ticket Operations
- Other relevant authentication and security auditing

Important events include:

| Event | Description |
|---:|---|
| 4624 | Successful logon |
| 4625 | Failed logon |
| 4672 | Special privileges assigned |
| 4688 | Process creation |
| 4697 | Service installed |
| 4698 | Scheduled task created |
| 4720 | User created |
| 4728 | Member added to global security group |
| 4732 | Member added to local security group |
| 4740 | Account locked out |
| 4768 | Kerberos TGT requested |
| 4769 | Kerberos service ticket requested |
| 4771 | Kerberos pre-authentication failed |
| 4776 | NTLM authentication |
| 5140 | Network share accessed |
| 5145 | Detailed network share access |
| 1102 | Audit log cleared |

The exact audit policy should be version-controlled so that every MiniLab instance produces comparable telemetry.

---

## 2. PowerShell Logging

**Status: implemented.** Script Block Logging (4104) and Module Logging (4103) are enabled by `winserver-baseline.ps1`/`win11-baseline.ps1` via registry, and the Operational channel is collected by all three SIEMs (ELK gets it for free from the default Fleet `windows` integration; Splunk and Wazuh each have an explicit `inputs.conf`/`ossec.conf` stanza).

**PowerShell Transcription: implemented (bd `MiniLab-w5t`, GitHub #19).** Confirmed a genuinely different collection mechanism from Script Block/Module Logging, as suspected: `winserver/win11-powershell-transcription.ps1` set `OutputDirectory` to `C:\PSTranscripts` via registry, and each SIEM needed its own *file* input (not eventchannel): ELK via Elastic's `log` package (`Custom Logs`, marked Deprecated in the registry — the newer `filestream` replacement requires Kibana ^9.4.0, incompatible with this lab's pinned ELK/Kibana 8.x, so the "deprecated" one is actually the only one that works here), Splunk via a `monitor://` stanza, Wazuh via a `<localfile>` with `log_format` `syslog` (its generic line-oriented text reader) instead of `eventchannel`.

Enable:

- Script Block Logging — done
- Module Logging — done
- PowerShell Transcription — done (file-based collection path, all 3 SIEMs)
- PowerShell Operational event collection — done, all 3 SIEMs

Important events:

| Event | Description |
|---:|---|
| 4103 | Module logging |
| 4104 | Script Block Logging |
| 4105 | Script started |
| 4106 | Script completed |

The objective is to support detection scenarios involving:

- Encoded PowerShell
- Download cradles
- `Invoke-Expression`
- Suspicious child processes
- PowerShell spawning LOLBins
- PowerShell network activity
- Obfuscated commands

---

## 3. Sysmon

**Status: fixed (bd `MiniLab-1f7`, GitHub #15).** MiniLab already installs Sysmon using the Olaf Hartong Sysmon Modular configuration on both endpoints. It reaches all 3 SIEMs now: ELK via the default Fleet `windows` integration's `sysmon_operational` data stream (enabled out of the box), Splunk via a `WinEventLog://Microsoft-Windows-Sysmon/Operational` `inputs.conf` stanza, Wazuh via a `<localfile>` eventchannel stanza in `ossec.conf` — both added by the Splunk forwarder/Wazuh agent scripts alongside the equivalent PowerShell Operational stanza.

The logging roadmap should ensure that the configuration provides useful telemetry for:

| Event | Description |
|---:|---|
| 1 | Process creation |
| 3 | Network connection |
| 7 | Image loaded |
| 8 | CreateRemoteThread |
| 10 | Process access |
| 11 | File creation |
| 12/13 | Registry modification |
| 15 | Alternate data streams |
| 22 | DNS query |
| 23 | File deletion |
| 25 | Process tampering |

Particular attention should be given to telemetry involving:

- PowerShell
- `cmd.exe`
- `rundll32.exe`
- `regsvr32.exe`
- `mshta.exe`
- `wscript.exe`
- `cscript.exe`
- `certutil.exe`
- `bitsadmin.exe`
- Scheduled tasks
- Windows services
- LSASS access
- Office applications spawning shells
- Browsers spawning unexpected processes

The goal is not maximum event volume. The goal is useful telemetry for detection engineering.

---

## 4. Windows Defender Telemetry

**Status: implemented (bd `MiniLab-1d0`, GitHub #16).** `winserver/win11-defender-telemetry.ps1` confirm real-time protection is on and bump the channel's max size. Unlike PowerShell/Sysmon, ELK needed explicit work too: the Fleet `windows` integration ships the `windows_defender` data stream with `enabled: false` by default (confirmed against the package manifest) - `elk-provision.sh` now does a GET-response/modify-PUT round trip against the created package policy to flip it on. Splunk/Wazuh get the usual `inputs.conf`/`ossec.conf` stanza.

Collect:

```text
Microsoft-Windows-Windows Defender/Operational
```

Telemetry should include:

- Threat detection
- Remediation
- Configuration changes
- Exclusion changes
- Signature updates
- Scan activity
- Suspicious behavior detections

A useful MiniLab scenario should demonstrate the relationship between:

```text
Attacker activity
      ↓
PowerShell / Process execution
      ↓
Sysmon
      ↓
Windows Defender
      ↓
SIEM correlation
```

This teaches investigation across multiple telemetry sources rather than relying on a single event.

---

## 5. Windows Firewall Logging

**Status: implemented (bd `MiniLab-nub`, GitHub #20).** `winserver/win11-firewall-logging.ps1` enable `-LogAllowed`/`-LogBlocked` on all 3 profiles via `Set-NetFirewallProfile`, keeping the default `pfirewall.log` path (correct ACLs already in place) and its 32767 KB hard cap (this log format can't be bumped to 100MB like the eventchannel-based sources). Confirmed the highest SIEM-side cost of the remaining items, as expected: no built-in shortcut on any of the 3, all needed a genuine file-monitor input built from scratch - reused the same mechanism as PowerShell Transcription (ELK's `log` package, Splunk `monitor://`, Wazuh `<localfile log_format="syslog">`), since both are plain-text files.

Enable Windows Firewall logging for:

- Dropped packets
- Successful connections

This is a **file-based log** (`pfirewall.log`), not a Windows Event Log channel — a different collection mechanism from Sysmon/Security/PowerShell above, and from the DNS channels below. Enabling it means setting `LogFileName`, `LogMaxSizeKilobytes`, and `LogAllowed`/`LogBlocked` via `Set-NetFirewallProfile` per profile (Domain/Private/Public), and making sure the destination directory is writable by the firewall service (`mpssvc`) — the default `%systemroot%\system32\LogFiles\Firewall\pfirewall.log` location already has the right ACLs; a custom path needs them granted explicitly. On the SIEM side, this needs a *file* input (not an eventchannel one) in whichever agent is running.

The firewall telemetry should complement Sysmon network events.

For example:

```text
Sysmon Event 3
      +
Windows Firewall
      +
DNS
      ↓
Network activity investigation
```

This provides multiple perspectives on the same network behavior.

---

## 6. DNS Telemetry

**Status: implemented (bd `MiniLab-qju`, GitHub #17).** `winserver-dns-telemetry.ps1` enables `DNS-Server/Analytical` (an Analytic channel, off by default — `wevtutil sl ... /e:true`) and bumps `DNS-Client/Operational`'s size; `win11-dns-telemetry.ps1` just bumps the latter, since Win11 isn't a DNS server. The premise was solid: `winserver` was already promoted with `-InstallDns:$true` in `ad-domain-setup.ps1`, so the DC already *is* the lab's DNS server — no extra role install needed.

This was the most novel of the telemetry fixes on the ELK side: neither the `windows` package nor any other bundled Elastic integration ships a DNS data stream at all (confirmed by inspecting every `data_stream/` folder in the actual package). `elk-provision.sh` now adds two package policies from Elastic's `winlog` *input* package ("Custom Windows Event Logs") instead, which requires an explicit channel name/dataset var rather than the "omit inputs, take the defaults" shortcut used everywhere else. Applied to the shared "Windows Endpoints" policy, so Win11 also technically subscribes to `DNS-Server/Analytical` even though it has no such channel — harmless (empty results), not clean. Splunk/Wazuh scope it correctly per-host since those configs are per-VM already.

DNS should become a first-class telemetry source.

Because the Windows Server VM acts as the Active Directory Domain Controller, MiniLab has a natural location for DNS telemetry.

Collect relevant:

```text
Microsoft-Windows-DNS-Server/Analytical
Microsoft-Windows-DNS-Client/Operational
```

`DNS-Server/Analytical` is an *Analytic* channel — those are disabled by default in Windows and won't accept new events (or sometimes even attach a collector) until explicitly enabled:

```powershell
wevtutil sl Microsoft-Windows-DNS-Server/Analytical /e:true
```

`DNS-Client/Operational` is a normal Operational channel and is enabled by default.

Potential detection scenarios:

- Suspicious external domains
- High-frequency DNS queries
- Repeated failed lookups
- Newly observed domains
- Internal/external DNS patterns
- Simulated DNS command-and-control activity

DNS telemetry is particularly valuable when combined with Sysmon Event 22 and network connection events.

---

## 7. Active Directory Telemetry

**Status: not implemented** beyond whatever Windows' default audit policy already produces (see §1 — this section overlaps with it directly for the DC-specific categories).

The existing `minilab.local` domain should be used as a detection-engineering feature rather than merely as infrastructure.

Focus on:

### Authentication

```text
4624
4625
4768
4769
4771
4776
```

### Account and group changes

```text
4720
4722
4724
4728
4732
4738
4756
```

### Directory changes

```text
5136
5137
5141
```

This enables scenarios involving:

- Account creation
- Privilege changes
- Group membership modification
- Kerberos abuse
- NTLM authentication
- Suspicious directory modifications
- Lateral movement

---

## 8. Windows Event Forwarding

**Status: deliberately not adopted as the default.** Discussed at length for this lab: WEF is a transport, not a data-quality improvement — the events it forwards are the same ones already available locally, just relayed through a collector. Its one real advantage here is resilience (a killed/blocked agent loses visibility; a native WinRM-based subscription is a different attack surface), which matters more in large fleets than in a 2-endpoint lab. Keeping it optional/Tier 3, as below, is the right call.

Add Windows Event Forwarding (WEF) as an optional advanced collection architecture.

The default architecture can remain:

```text
Windows
   ↓
Elastic Agent
   ↓
SIEM
```

An optional WEF architecture would provide:

```text
Windows endpoints
       ↓
Windows Event Forwarding
       ↓
Windows Event Collector
       ↓
SIEM
```

This allows MiniLab to demonstrate both agent-based and Windows-native event collection.

WEF should be optional rather than replacing the existing Elastic Agent architecture.

---

## 9. Telemetry Health Checks

**Status: implemented for ELK (bd `MiniLab-czn`, GitHub #21).** `tests/check-telemetry.sh` queries Elasticsearch directly for recent document counts in every data stream wired up across this session's telemetry work (Sysmon, PowerShell Operational + Transcription, Defender, both DNS channels, Firewall, Security), rather than just checking that Fleet/Kibana/agents are up like `check-lab.sh` does. Splunk/Wazuh event-arrival checks aren't implemented — those need their own SIEM-specific query mechanism, out of scope for this one script.

The existing lab health checks verify infrastructure and agent availability.

A dedicated telemetry health check should verify that the logging pipeline is actually producing useful data.

Proposed:

```text
tests/check-telemetry.sh
```

The check should verify:

```text
[OK] Sysmon installed
[OK] Sysmon running
[OK] Windows Security auditing configured
[OK] PowerShell Script Block Logging enabled
[OK] Defender Operational log enabled
[OK] Firewall logging enabled
[OK] DNS logging enabled
[OK] Elastic Agent healthy
[OK] Security events arriving
[OK] Sysmon events arriving
[OK] PowerShell events arriving
[OK] Defender events arriving
[OK] Events are recent
```

The important distinction is between:

```text
collector running
```

and:

```text
collector running + telemetry actually arriving
```

---

## 10. Deterministic Telemetry Generator

**Status: implemented (bd `MiniLab-ahu`, GitHub #22).** `scripts/generate-telemetry.ps1` runs all 12 actions below, each self-cleaning (test user/service/task/key/file all removed after), and prints the specific event it expects per action. Not a provisioner — run it manually against an already-provisioned `winserver`/`win11`, then verify with `tests/check-telemetry.sh` on the host.

Add a script capable of intentionally generating benign, deterministic events.

Proposed:

```text
scripts/generate-telemetry.ps1
```

The generator should produce activities such as:

1. Failed authentication
2. Successful authentication
3. Process creation
4. PowerShell execution
5. DNS query
6. Network connection
7. File creation
8. Registry modification
9. Scheduled task creation
10. Service creation
11. Account creation
12. Group membership modification

The purpose is not to simulate a complete attack.

The purpose is to establish a predictable relationship:

```text
Action
  ↓
Windows subsystem
  ↓
Expected event
  ↓
Collector
  ↓
SIEM
```

This creates a **telemetry contract** for MiniLab.

---

## 11. Attack → Telemetry → Detection Scenarios

**Status: not implemented.** Note this is content authoring (one scenario at a time), not infrastructure — sizing expectations accordingly matters when prioritizing it against the Tier 1 items.

Create a structured detection scenario repository.

Proposed structure:

```text
detections/
├── credential-access/
├── execution/
├── persistence/
├── privilege-escalation/
├── defense-evasion/
├── discovery/
├── lateral-movement/
└── command-and-control/
```

Each scenario should contain, where applicable:

```text
scenario.md
generate.ps1
expected-events.md
detection.md
```

A scenario should document:

- What activity is generated
- Which Windows components are involved
- Expected event IDs
- Expected fields
- Expected process tree
- Expected network activity
- Detection logic
- How the detection can be validated

Example:

```text
detections/
└── execution/
    └── encoded-powershell/
        ├── scenario.md
        ├── generate.ps1
        ├── expected-events.md
        └── detection.md
```

---

## 12. Scenario Correlation IDs

**Status: not implemented.**

Generated scenarios should optionally include a MiniLab-specific scenario identifier.

For example:

```text
MiniLabScenario=PS-001
```

or:

```text
MiniLabScenario=AD-003
```

This allows a complete exercise to be correlated across telemetry sources.

Example:

```text
Scenario: AD-003

4624
  ↓
4688
  ↓
4104
  ↓
22
  ↓
3
  ↓
Defender event
```

The analyst can then reconstruct the timeline from the generated activity.

---

## 13. Sigma Detection Layer

**Status: not implemented.** Directly solves this lab's recurring "does this apply to all 3 SIEMs?" question — Sigma is the standard portable detection format, and MiniLab's whole premise (interchangeable SIEM backends) is exactly the use case it's built for.

MiniLab supports multiple SIEM platforms:

```text
ELK
Splunk
Wazuh
```

Detection logic should therefore not be tightly coupled to a single SIEM.

Introduce:

```text
detections/
└── sigma/
    ├── win-suspicious-powershell.yml
    ├── win-lsass-access.yml
    ├── win-new-service.yml
    ├── win-scheduled-task.yml
    ├── win-account-created.yml
    └── win-ad-group-modification.yml
```

The conceptual architecture becomes:

```text
                   Sigma
                     ↓
             ┌───────┼───────┐
             ↓       ↓       ↓
            ELK    Splunk   Wazuh
```

This makes the detection content portable across MiniLab's supported SIEM implementations.

---

## 14. Event Coverage Matrix

**Status: not implemented** — and should be kept honest/current as each telemetry source above actually gets wired up per SIEM, not just per endpoint (see §3: "Sysmon ✓" on Win11/WinServer doesn't mean "Sysmon ✓" reaches the SIEM — those are two different claims).

The documentation should expose which telemetry is available from each endpoint and which scenarios use it.

Example:

| Telemetry | Win11 | WinServer | SIEM | Primary use |
|---|---:|---:|---:|---|
| Windows Security | ✓ | ✓ | ✓ | Authentication |
| Sysmon | ✓ | ✓ | ✓ | Process execution |
| PowerShell | ✓ | ✓ | ✓ | Script execution |
| Defender | ✓ | ✓ | ✓ | Threat detection |
| Firewall | ✓ | ✓ | ✓ | Network activity |
| DNS | ✓ | ✓ | ✓ | DNS analysis |
| AD DS | — | ✓ | ✓ | AD attacks |
| WEF | Optional | Optional | ✓ | Enterprise collection |

This should become part of the public documentation so users can understand the telemetry architecture before deploying the lab.

---

## 15. Telemetry Profiles

**Status: not implemented.** Bigger lift than it looks: each profile touches audit policy *and* Sysmon config *and* the input config of all 3 SIEM agents — three times the surface area of a single Tier-1 item.

A portable laboratory should account for different hardware constraints.

Introduce configurable telemetry profiles:

```text
MINILAB_LOG_PROFILE=light
MINILAB_LOG_PROFILE=standard
MINILAB_LOG_PROFILE=high
```

### Light

Essential telemetry:

```text
Windows Security
Sysmon
```

### Standard

```text
Windows Security
Sysmon
PowerShell
Defender
DNS
Firewall
```

### High

Everything in Standard plus:

- Verbose auditing
- Additional Sysmon telemetry
- Additional Windows diagnostic telemetry
- More detailed network auditing

This allows MiniLab to remain usable on laptops while still supporting intensive detection exercises.

---

## 16. Log Retention

**Status: not implemented.** Same caveat as §15: ILM policy (ELK), `indexes.conf` retention (Splunk), and log rotation (Wazuh) are three unrelated mechanisms — this is a per-SIEM task multiplied by three, not a single setting.

Provide configurable retention for SIEM data.

Example:

```text
MINILAB_RETENTION_DAYS=7
```

The default should be appropriate for a portable laboratory rather than a production SOC.

Retention should prevent repeated exercises from consuming excessive disk space.

---

## 17. Implementation Priorities

### Tier 1 — Foundational telemetry

1. ~~Windows Advanced Audit Policy~~ — done (bd `MiniLab-e40` / gh-18), includes AD-specific categories
2. ~~PowerShell logging~~ — done (Script Block/Module Logging + Transcription, bd `MiniLab-74o`/`MiniLab-w5t`)
3. ~~Sysmon reaching Splunk and Wazuh~~ — done (bd `MiniLab-1f7` / gh-15)
4. ~~Defender Operational logs~~ — done (bd `MiniLab-1d0` / gh-16)
5. ~~Windows Firewall logging~~ — done (bd `MiniLab-nub` / gh-20)
6. ~~DNS logging~~ — done (bd `MiniLab-qju` / gh-17)
7. ~~AD auditing~~ — folded into item 1
8. ~~`check-telemetry`~~ — done for ELK (bd `MiniLab-czn` / gh-21)
9. ~~Deterministic telemetry generator~~ — done (bd `MiniLab-ahu` / gh-22)

### Tier 2 — Detection engineering

10. Sigma rules
11. Attack/telemetry/detection scenarios
12. Event coverage matrix
13. Scenario correlation IDs
14. Automated detection validation

### Tier 3 — Advanced enterprise logging

15. Windows Event Forwarding
16. Configurable telemetry profiles
17. Retention policies
18. Expanded AD telemetry
19. Automated attack replay

---

## Target Architecture

The final logging architecture should evolve from:

```text
Windows
   ↓
Sysmon / Agent
   ↓
SIEM
   ↓
Analyst
```

to:

```text
                    ┌── Security
                    ├── Sysmon
                    ├── PowerShell
Windows ────────────┼── Defender
                    ├── Firewall
                    ├── DNS
                    └── AD
                         ↓
                  Telemetry pipeline
                         ↓
                 ELK / Splunk / Wazuh
                         ↓
                Detection engineering
                         ↓
          ┌──────────────┴──────────────┐
          ↓                             ↓
   Detection rules              Validation tests
          ↓                             ↓
       Alerts                    Expected events
          └──────────────┬──────────────┘
                         ↓
                Reproducible results
```

The end state is a **reproducible Windows telemetry and detection-engineering laboratory**, rather than simply a collection of VMs forwarding logs to a SIEM.

MiniLab should be able to answer three questions for every exercise:

1. **What did the simulated activity do?**
2. **Which telemetry proves that it happened?**
3. **Does the detection reliably identify that telemetry?**
