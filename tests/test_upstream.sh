#!/usr/bin/env bash
# Offline contract test against a real, unpacked upstream release.
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
source "$project/acme.sh"
upstream_fixture=${ACME_TEST_SOURCE:?Set ACME_TEST_SOURCE to an unpacked official release}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export PROFILE="$work/profile"
: > "$PROFILE"
ACME_HOME="$work/acme"
CERT_DIR="$work/cert"
STATE_DIR="$work/state"
RUN_TMP="$work/tmp"
mkdir -p "$RUN_TMP"
umask 077
ensure_private_dirs
email=''
download() {
    if [[ "$1" == *releases/latest ]]; then
        printf '{"tag_name":"3.1.6"}\n' > "$2"
    else
        tar -czf "$2" -C "$upstream_fixture/.." "$(basename "$upstream_fixture")"
    fi
}
install_client
download() { return 19; }
install_client # Existing clients must not be downloaded or overwritten.
acme --version
cert_home="$ACME_HOME/example.com_ecc"
mkdir -p "$cert_home"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -days 1 -subj /CN=example.com \
    -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' \
    -keyout "$cert_home/example.com.key" -out "$cert_home/fullchain.cer" 2>/dev/null
cp "$cert_home/fullchain.cer" "$cert_home/example.com.cer"
printf "Le_Domain='example.com'\nLe_Keylength='ec-256'\n" > "$cert_home/example.com.conf"
reload_cmd="printf reloaded > '$work/reloaded'"
deploy_certificate example.com 1
[[ $(cat "$work/reloaded") == reloaded ]]
[[ $(stat -c %a "$CERT_DIR/example.com.key") == 600 ]]
read_reload example.com <<< ""
[[ "$reload_cmd" == "printf reloaded > '$work/reloaded'" ]]
cp "$CERT_DIR/example.com.key" "$work/previous.key"
cp "$CERT_DIR/example.com.crt" "$work/previous.crt"
reload_cmd=false
if deploy_certificate example.com 1; then
    printf 'Expected reload failure\n' >&2
    exit 1
fi
cmp "$work/previous.key" "$CERT_DIR/example.com.key"
cmp "$work/previous.crt" "$CERT_DIR/example.com.crt"
acme --uninstall --nocron
[[ -s "$cert_home/fullchain.cer" && -s "$CERT_DIR/example.com.key" ]]
printf 'Official acme.sh installation, deployment, reload and preservation checks passed.\n'
