#!/usr/bin/env bash
# Run inside disposable CI containers only: installs real distro packages.
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
source "$project/acme.sh"
detect_system
install_dependencies
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
ACME_HOME="$work/acme"
CERT_DIR="$work/cert"
STATE_DIR="$work/state"
LOCK_FILE="$work/lock"
RENEW_SCRIPT="$work/renew"
RENEW_LOG="$work/renew.log"
SYSTEM_CRONTAB="$work/system.cron"
ensure_private_dirs
if [[ "$SYSTEM" == alpine ]]; then
    # OpenRC service commands can be exercised in a disposable container.
    # This is not a VPS boot test.
    mkdir -p /run/openrc
    touch /run/openrc/softlevel
else
    # systemd is not PID 1 in these containers.
    start_cron() { :; }
fi
printf '0 1 * * * /bin/true # unrelated\n' | crontab -
printf '0 0 * * * root bash %s/acme.sh --cron -f >/dev/null 2>&1\n' "$ACME_HOME" > "$SYSTEM_CRONTAB"
with_lock configure_schedule
with_lock configure_schedule
[[ $(crontab -l | grep -c passeway-acme-renew) == 1 ]]
crontab -l | grep -q unrelated
[[ ! -s "$SYSTEM_CRONTAB" ]]
bash -n "$RENEW_SCRIPT"
with_lock configure_schedule remove
crontab -l | grep -q unrelated
if crontab -l | grep -q passeway-acme-renew; then exit 1; fi
printf 'Distribution dependencies and real crontab migration passed: %s\n' "$SYSTEM"
