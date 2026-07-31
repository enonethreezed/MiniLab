---
title: Guacamole
layout: default
nav_order: 6
---

# Guacamole
{: .no_toc }

Browser-based RDP/SSH gateway on `siem` — no local RDP/SSH client needed.
{: .fs-6 .fw-300 }

---

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## What it is

[Apache Guacamole](https://guacamole.apache.org/) lets you reach
`winserver`/`win11` RDP sessions and `siem`'s own SSH from a plain web
browser — useful when travelling with just a laptop.
`guacamole-server` isn't packaged for Debian at all (pulled from Debian
entirely in 2024, never returned), so this deploys the official
`guacamole/guacd` + `guacamole/guacamole` Docker images via Docker Compose —
the actual maintained install path, not a fallback.

Off by default (extra RAM/CPU, another moving part).

## Deployment

```bash
ENABLE_GUACAMOLE=true vagrant up siem

# Or run it standalone against an already-provisioned siem
ENABLE_GUACAMOLE=true vagrant provision siem --provision-with docker-setup,guacamole-setup
```

## Access

Web UI: **http://localhost:8280/guacamole** — credentials in
`logs/guacamole-credentials.txt` (`admin` / `vagrant`).

{: .warning }
Unlike every other service in this lab, this port forward is bound to
`0.0.0.0` (not `127.0.0.1`) — deliberately reachable from other devices on
your network (e.g. a phone/tablet), not just this machine:
`http://<host-LAN-IP>:8280/guacamole`. Keep that in mind on untrusted
networks — the `admin`/`vagrant` login is a lab-simple credential, not
hardened for that exposure.

## Connection profiles

Four connections are pre-configured (`scripts/guacamole-setup.sh`,
single-user `user-mapping.xml`, no DB backend needed for a home lab):

| Connection | Protocol | Target | Account |
|---|---|---|---|
| `winserver - Administrator (Domain)` | RDP | 192.168.56.20 | `MINILAB\Administrator` |
| `win11 - Administrator (Domain)` | RDP | 192.168.56.30 | `MINILAB\Administrator` |
| `win11 - vagrant (Local)` | RDP | 192.168.56.30 | local `vagrant` |
| `siem - SSH` | SSH | 127.0.0.1 | `vagrant`, via a dedicated keypair generated for Guacamole (not Vagrant's own `insecure_private_key`) |

## Verify

```bash
bash tests/check-guacamole.sh
```

Includes a real login check (`POST /api/tokens`), not just an HTTP 200 on
the login page — a permission-denied `user-mapping.xml` can still serve a
200 page while every login fails.

## Notes

- `siem`'s RAM is sized at 12GB specifically to leave headroom for this
  (guacd + Tomcat/webapp) on top of the SIEM stack.
- No TLS — plain HTTP, consistent with the rest of the lab's
  host-only-network posture; add an nginx reverse proxy in front if you
  want it.

→ [Usage](usage.html)
