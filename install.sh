#!/usr/bin/env bash
# MiniLab installer wrapper - sets the right ENABLE_* env vars and runs
# `vagrant up` (or `vagrant destroy -f`), so you don't have to remember the
# flag names. Also wraps the lifecycle commands (start/stop/suspend/resume)
# for an already-created environment, with a fixed VM order.
#
# Usage:
#   ./install.sh [--siem splunk|wazuh] [--guacamole] [-- <vagrant up args>]
#   ./install.sh --destroy [-- <vagrant destroy args>]
#   ./install.sh --start|--stop|--suspend|--resume|--reload
#   ./install.sh --status
#
# Examples:
#   ./install.sh                              # ELK (default), no extras
#   ./install.sh --siem splunk --guacamole    # Splunk + Guacamole
#   ./install.sh --destroy                    # vagrant destroy -f (all VMs)
#   ./install.sh --destroy -- win11           # vagrant destroy -f win11 only
#   ./install.sh --stop                       # halt win11, then winserver, then siem
#   ./install.sh --start                      # up siem, then winserver, then win11
#   ./install.sh --reload                     # reload siem, then winserver, then win11
set -euo pipefail

SIEM=""
GUACAMOLE=false
DESTROY=false
ACTION=""
VAGRANT_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [--siem splunk|wazuh] [--guacamole] [-- <vagrant up args>]
       ./install.sh --destroy [-- <vagrant destroy args>]
       ./install.sh --start|--stop|--suspend|--resume|--reload|--status

  --siem splunk|wazuh   Use Splunk or Wazuh instead of the default ELK stack
                        (mutually exclusive with each other)
  --guacamole           Enable the Guacamole RDP/SSH gateway on siem
  --destroy             Run `vagrant destroy -f` instead of `vagrant up`
                        (ignores --siem/--guacamole, which only matter when
                        bringing the lab up)
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
destroy` (e.g. to target only specific VMs). Not applicable to
--start/--stop/--suspend/--resume/--reload/--status, which always act on
every VM currently defined in the Vagrantfile (respecting whatever
ENABLE_KALI was set to when the environment was created).
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

echo "Running: env ${ENV_ARGS[*]:-} vagrant up ${VAGRANT_ARGS[*]:-}"
env "${ENV_ARGS[@]}" vagrant up "${VAGRANT_ARGS[@]}"
