#!/usr/bin/env bash
# MiniLab installer wrapper - sets the right ENABLE_* env vars and runs
# `vagrant up` (or `vagrant destroy -f`), so you don't have to remember the
# flag names. Also wraps the lifecycle commands (start/stop/suspend/resume)
# for an already-created environment, with a fixed VM order.
#
# Usage:
#   ./install.sh [--siem splunk|wazuh] [--guacamole] [--velociraptor] [--kali-minimal] [--debug] [-- <vagrant up args>]
#   ./install.sh --destroy [-- <vagrant destroy args>]
#   ./install.sh --start|--stop|--suspend|--resume|--reload
#   ./install.sh --status
#
# Examples:
#   ./install.sh                              # ELK (default), no extras
#   ./install.sh --siem splunk --guacamole    # Splunk + Guacamole
#   ./install.sh --velociraptor               # ELK + Velociraptor hunting console
#   ./install.sh --kali-minimal -- kali       # stripped-down Kali attacker box only
#   ./install.sh --debug                      # verbose Vagrant/provisioner output (VAGRANT_LOG=debug)
#   ./install.sh --destroy                    # vagrant destroy -f (all VMs)
#   ./install.sh --destroy -- win11           # vagrant destroy -f win11 only
#   ./install.sh -- siem                      # bring up siem only
#   ./install.sh --siem splunk -- siem        # siem only, with Splunk
#   ./install.sh --stop                       # halt win11, then winserver, then siem
#   ./install.sh --start                      # up siem, then winserver, then win11
#   ./install.sh --reload                     # reload siem, then winserver, then win11
set -euo pipefail

SIEM=""
GUACAMOLE=false
VELOCIRAPTOR=false
KALI_MINIMAL=false
DEBUG=false
DESTROY=false
ACTION=""
VAGRANT_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [--siem splunk|wazuh] [--guacamole] [--velociraptor] [--kali-minimal] [--debug] [-- <vagrant up args>]
       ./install.sh --destroy [-- <vagrant destroy args>]
       ./install.sh --start|--stop|--suspend|--resume|--reload|--status

  --siem splunk|wazuh   Use Splunk or Wazuh instead of the default ELK stack
                        (mutually exclusive with each other)
  --guacamole           Enable the Guacamole RDP/SSH gateway on siem
  --velociraptor        Enable the Velociraptor hunting console on siem +
                        clients on winserver/win11 (not mutually exclusive
                        with --siem - additive alongside any SIEM stack)
  --kali-minimal        Bring up the Kali attacker box (implies ENABLE_KALI),
                        stripped to kali-linux-core after boot - the box
                        download is still the full kalilinux/rolling image
                        (no smaller official box exists), but the desktop
                        environment and default tool metapackage are purged
                        since this VM runs headless
  --debug               Export VAGRANT_LOG=debug before running vagrant -
                        verbose internal Vagrant/provisioner output, useful
                        when a provisioner fails and the plain log isn't
                        enough. Applies to every action below, not just
                        bringing the lab up. Also tees the whole session
                        (this wrapper's own output + Vagrant's) to
                        logs/debug.log, overwritten fresh each run.
  --destroy             Run `vagrant destroy -f` instead of `vagrant up`
                        (ignores --siem/--guacamole/--velociraptor, which
                        only matter when bringing the lab up)
  --start               Boot an already-created environment: siem, then
                        winserver, then win11 (kali last, if defined)
  --stop                Halt an already-created environment: win11, then
                        winserver, then siem (kali first, if defined)
  --suspend             Same order as --stop, but suspend instead of halt
  --resume              Same order as --start, but resume instead of up
  --reload              Same order as --start, but reload (restart +
                        re-run provisioners) instead of up
  --status              Run `vagrant status`
  -h, --help            Show this help

Anything after -- is passed straight through to `vagrant up` / `vagrant
destroy`. Not applicable to --start/--stop/--suspend/--resume/--reload/
--status, which always act on every VM currently defined in the Vagrantfile
(respecting whatever ENABLE_KALI was set to when the environment was
created).

Examples:
  ./install.sh -- siem                   # bring up siem only
  ./install.sh --siem splunk -- siem     # siem only, with Splunk
  ./install.sh -- winserver              # bring up winserver (DC) only
  ./install.sh --destroy -- win11        # destroy win11 only
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --siem)
      SIEM="${2:-}"
      case "$SIEM" in
        splunk|wazuh|elk) ;;
        *)
          echo "Error: --siem requires 'splunk', 'wazuh', or 'elk' (got '${SIEM}')" >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    --guacamole)
      GUACAMOLE=true
      shift
      ;;
    --velociraptor)
      VELOCIRAPTOR=true
      shift
      ;;
    --kali-minimal)
      KALI_MINIMAL=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --destroy|--start|--stop|--suspend|--resume|--reload|--status)
      ACTION="${1#--}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      VAGRANT_ARGS=("$@")
      break
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [ "$DEBUG" = true ]; then
  export VAGRANT_LOG=debug
  # Full session (this wrapper's own output + Vagrant's verbose output)
  # captured to logs/debug.log, truncated fresh each run - not appended,
  # so it always reflects only the most recent attempt. Still prints live
  # to the terminal too (tee), this isn't a silent redirect.
  mkdir -p logs
  exec > >(tee logs/debug.log) 2>&1
  echo "Debug mode: full output also being saved to logs/debug.log"
fi

# Machines actually defined right now (respects ENABLE_KALI at call time),
# in Vagrantfile declaration order.
defined_vms() {
  vagrant status --machine-readable 2>/dev/null \
    | awk -F, '$3 == "metadata" && $4 == "provider" { print $2 }'
}

run_in_order() {
  local cmd="$1"; shift
  local status=0
  for vm in "$@"; do
    echo "==> vagrant $cmd $vm"
    if ! vagrant "$cmd" "$vm"; then
      echo "Warning: 'vagrant $cmd $vm' failed" >&2
      status=1
    fi
  done
  return $status
}

case "$ACTION" in
  destroy)
    echo "Running: vagrant destroy -f ${VAGRANT_ARGS[*]:-}"
    vagrant destroy -f "${VAGRANT_ARGS[@]}"
    exit 0
    ;;
  status)
    vagrant status
    exit 0
    ;;
  start|resume|reload|stop|suspend)
    DEFINED="$(defined_vms)"
    UP_ORDER=(siem winserver win11 kali)
    ORDER=()
    for vm in "${UP_ORDER[@]}"; do
      echo "$DEFINED" | grep -qx "$vm" && ORDER+=("$vm")
    done
    case "$ACTION" in
      start)   run_in_order up "${ORDER[@]}"; exit $? ;;
      resume)  run_in_order resume "${ORDER[@]}"; exit $? ;;
      reload)  run_in_order reload "${ORDER[@]}"; exit $? ;;
      stop)
        DOWN_ORDER=()
        for ((i = ${#ORDER[@]} - 1; i >= 0; i--)); do DOWN_ORDER+=("${ORDER[i]}"); done
        run_in_order halt "${DOWN_ORDER[@]}"; exit $?
        ;;
      suspend)
        DOWN_ORDER=()
        for ((i = ${#ORDER[@]} - 1; i >= 0; i--)); do DOWN_ORDER+=("${ORDER[i]}"); done
        run_in_order suspend "${DOWN_ORDER[@]}"; exit $?
        ;;
    esac
    ;;
esac

ENV_ARGS=()
case "$SIEM" in
  splunk) ENV_ARGS+=("ENABLE_SPLUNK=true") ;;
  wazuh)  ENV_ARGS+=("ENABLE_WAZUH=true") ;;
  elk|"") ;; # default, nothing to set
esac
[ "$GUACAMOLE" = true ] && ENV_ARGS+=("ENABLE_GUACAMOLE=true")
[ "$VELOCIRAPTOR" = true ] && ENV_ARGS+=("ENABLE_VELOCIRAPTOR=true")
[ "$KALI_MINIMAL" = true ] && ENV_ARGS+=("ENABLE_KALI=true" "ENABLE_KALI_MINIMAL=true")

echo "Running: env ${ENV_ARGS[*]:-} vagrant up ${VAGRANT_ARGS[*]:-}"
env "${ENV_ARGS[@]}" vagrant up "${VAGRANT_ARGS[@]}"
