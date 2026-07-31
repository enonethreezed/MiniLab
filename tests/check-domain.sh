#!/usr/bin/env bash
# MiniLab domain health check — Linux/macOS
# Verifies the minilab.local AD domain (winserver as DC) and that win11 has
# joined it, using only nmap and native Samba/LDAP client tools (ldapsearch,
# nmblookup, smbclient) - no offensive/lateral-movement tooling
# (netexec/CrackMapExec and similar) is used, by design.
#
# Run from the repo root after both the "ad-domain" (winserver) and
# "domain-join" (win11) Vagrant provisioners have completed.
set -uo pipefail

WSRV_IP="${WSRV_IP:-192.168.56.20}"
WIN11_IP="${WIN11_IP:-192.168.56.30}"
DOMAIN_NAME="${DOMAIN_NAME:-minilab.local}"
NETBIOS_NAME="${NETBIOS_NAME:-MINILAB}"
# Domain policy/FSMO checks need an authenticated bind — anonymous LDAP can
# only read rootDSE, not directory objects. Administrator is the domain
# Administrator account (see README/STATUS for the credential design).
BIND_DN="${BIND_DN:-administrator@${DOMAIN_NAME}}"
BIND_PW="${BIND_PW:-vagrant}"
DOMAIN_BASE_DN="DC=$(echo "$DOMAIN_NAME" | sed 's/\./,DC=/g')"

PASS=0
FAIL=0

pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $* =="; }

for cmd in nmap ldapsearch nmblookup smbclient; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "Required tool '$cmd' not found. Install nmap, ldap-utils, and samba-common-bin/smbclient."
    exit 2
  fi
done

section "Domain Controller services ($WSRV_IP) — nmap"
NMAP_OUT=$(nmap -Pn -p 53,88,135,139,389,445,464,636,3268,3269 -sV "$WSRV_IP" 2>/dev/null)
for portsvc in "53:domain" "88:kerberos" "389:ldap" "445:microsoft-ds" "3268:ldap"; do
  port="${portsvc%%:*}"
  if echo "$NMAP_OUT" | grep -qE "^${port}/tcp[[:space:]]+open"; then
    pass "port $port open ($(echo "$NMAP_OUT" | grep -E "^${port}/tcp" | awk '{print $3}'))"
  else
    fail "port $port not open — expected for a domain controller"
  fi
done
if echo "$NMAP_OUT" | grep -qi "Domain: ${DOMAIN_NAME}"; then
  pass "nmap's LDAP service banner reports Domain: $DOMAIN_NAME"
else
  fail "nmap's LDAP service banner does not mention Domain: $DOMAIN_NAME"
fi

section "AD naming context & functional levels — ldapsearch (anonymous rootDSE)"
ROOTDSE_OUT=$(ldapsearch -x -H "ldap://${WSRV_IP}" -b "" -s base "(objectClass=*)" \
  namingContexts defaultNamingContext domainFunctionality forestFunctionality domainControllerFunctionality 2>/dev/null)
if echo "$ROOTDSE_OUT" | grep -qi "defaultNamingContext: ${DOMAIN_BASE_DN}"; then
  pass "defaultNamingContext is $DOMAIN_BASE_DN"
else
  fail "defaultNamingContext did not match expected $DOMAIN_BASE_DN"
fi
for level in "domainFunctionality" "forestFunctionality"; do
  value=$(echo "$ROOTDSE_OUT" | grep -oP "(?<=${level}: )\d+")
  if [ -n "$value" ] && [ "$value" -ge 0 ] 2>/dev/null; then
    pass "$level = $value (0=2000 .. 7=2016, expected for a fresh forest)"
  else
    fail "could not read $level from rootDSE"
  fi
done

section "FSMO role holder — ldapsearch (authenticated)"
FSMO_OUT=$(ldapsearch -x -H "ldap://${WSRV_IP}" -D "$BIND_DN" -w "$BIND_PW" \
  -b "$DOMAIN_BASE_DN" -s base "(objectClass=*)" fSMORoleOwner 2>/dev/null)
if echo "$FSMO_OUT" | grep -qi "fSMORoleOwner:.*CN=NTDS Settings"; then
  owner=$(echo "$FSMO_OUT" | grep -oP '(?<=CN=)[^,]+(?=,CN=Servers)')
  pass "PDC Emulator (domain naming FSMO) held by: $owner"
else
  fail "Could not read fSMORoleOwner (check BIND_DN/BIND_PW credentials)"
fi

section "AD-integrated DNS zone — ldapsearch (authenticated)"
DNS_ZONE_DN="DC=${DOMAIN_NAME},CN=MicrosoftDNS,DC=DomainDnsZones,${DOMAIN_BASE_DN}"
DNS_OUT=$(ldapsearch -x -H "ldap://${WSRV_IP}" -D "$BIND_DN" -w "$BIND_PW" \
  -b "$DNS_ZONE_DN" -s base "(objectClass=*)" objectClass 2>/dev/null)
if echo "$DNS_OUT" | grep -qi "objectClass: dnsZone"; then
  pass "AD-integrated DNS zone for $DOMAIN_NAME exists (stored in DomainDnsZones partition)"
else
  fail "Could not find an AD-integrated DNS zone for $DOMAIN_NAME"
fi

section "Domain password/lockout policy — ldapsearch (authenticated)"
POLICY_OUT=$(ldapsearch -x -H "ldap://${WSRV_IP}" -D "$BIND_DN" -w "$BIND_PW" \
  -b "$DOMAIN_BASE_DN" -s base "(objectClass=*)" minPwdLength pwdProperties lockoutThreshold lockoutDuration 2>/dev/null)
MIN_LEN=$(echo "$POLICY_OUT" | grep -oP '(?<=minPwdLength: )\d+')
PWD_PROPS=$(echo "$POLICY_OUT" | grep -oP '(?<=pwdProperties: )\d+')
LOCKOUT_THRESH=$(echo "$POLICY_OUT" | grep -oP '(?<=lockoutThreshold: )\d+')
if [ -n "$MIN_LEN" ] && [ "$MIN_LEN" -ge 7 ]; then
  pass "minPwdLength = $MIN_LEN (>= 7)"
else
  fail "minPwdLength = ${MIN_LEN:-unknown} (expected >= 7)"
fi
if [ -n "$PWD_PROPS" ] && [ $((PWD_PROPS & 1)) -eq 1 ]; then
  pass "DOMAIN_PASSWORD_COMPLEX flag set (pwdProperties=$PWD_PROPS) — complexity required"
else
  fail "DOMAIN_PASSWORD_COMPLEX flag not set (pwdProperties=${PWD_PROPS:-unknown})"
fi
if [ -n "$LOCKOUT_THRESH" ]; then
  pass "lockoutThreshold = $LOCKOUT_THRESH (0 = disabled, default for a fresh AD DS forest)"
else
  fail "could not read lockoutThreshold"
fi

section "Domain Controller SMB — smbclient (anonymous connection)"
# Modern Windows blocks anonymous NULL-session share *enumeration* (that's
# expected, hardened behavior, not a failure) - but the DC still accepts an
# anonymous SMB protocol negotiation/session, which is enough to confirm the
# SMB service itself is genuinely responding, not just port-open.
SMBCLIENT_OUT=$(smbclient -L "//${WSRV_IP}/" -N -m SMB3 2>&1)
if echo "$SMBCLIENT_OUT" | grep -qi "Anonymous login successful"; then
  pass "smbclient anonymous SMB session established with the DC"
else
  fail "smbclient could not establish an anonymous SMB session with the DC"
fi

section "win11 domain membership — nmap smb-os-discovery + nmblookup"
SMB_OUT=$(nmap -Pn -p 445 --script smb-os-discovery "$WIN11_IP" 2>/dev/null)
if echo "$SMB_OUT" | grep -qE "^445/tcp[[:space:]]+open"; then
  pass "win11 port 445 (SMB) open"
else
  fail "win11 port 445 (SMB) not open — check File and Printer Sharing firewall rules"
fi

NMBLOOKUP_OUT=$(nmblookup -A "$WIN11_IP" 2>/dev/null)
if echo "$NMBLOOKUP_OUT" | grep -qE "${NETBIOS_NAME}[[:space:]]*<00>.*<GROUP>"; then
  pass "nmblookup shows win11 registered in domain/workgroup '$NETBIOS_NAME'"
else
  fail "nmblookup did not show win11 registered in domain/workgroup '$NETBIOS_NAME'"
fi

section "Summary"
echo "  Passed: $PASS   Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  Domain is NOT fully verified."
  exit 1
else
  echo "  Domain is healthy: winserver is DC for $DOMAIN_NAME, win11 is joined."
  exit 0
fi
