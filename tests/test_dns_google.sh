#!/bin/sh
# Exercise the installed command's migration functions with a fake UCI store.
set -eu
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
sed -n '/^restore_dns() {/,/^if \[ -f "\$DNS_PENDING" \]; then/{ /^if \[ -f "\$DNS_PENDING" \]; then/d; p; }' \
    "$(dirname "$0")/../runtime/router-provisioner-command" |
    sed 's|/etc/init.d/netshift restart|fake_restart|g' > "$dir/functions"
# shellcheck disable=SC1090
. "$dir/functions"
DNS_PENDING="$dir/pending"
resolver=old
pre=true
post=true
fake_restart() { echo restart >> "$dir/restarts"; }
uci() {
    case "$1:$2" in
        -q:get) case "$3" in *.dns_type) echo doh;; *) echo "$resolver";; esac ;;
        set:*) resolver=${2#*=} ;;
        changes:netshift|commit:netshift) return 0 ;;
        *) exit 2 ;;
    esac
}
google_dns_ready() { "$pre"; }
checks=0
local_dns_ready() {
    checks=$((checks + 1))
    "$post" && [ "$checks" -ge 6 ]
}
log() { :; }
sleep() { :; }
pre=false
if switch_google_dns; then exit 1; fi
[ "$resolver" = old ] && [ ! -f "$dir/restarts" ] || exit 1
pre=true
post=false
if switch_google_dns; then exit 1; fi
[ "$resolver" = old ] && [ ! -e "$DNS_PENDING" ] || exit 1
post=true
checks=0
switch_google_dns
[ "$resolver" = dns.google/dns-query ] && [ ! -e "$DNS_PENDING" ] || exit 1
switch_google_dns
[ "$(wc -l < "$dir/restarts" | tr -d ' ')" = 3 ]
