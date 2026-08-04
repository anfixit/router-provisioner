#!/bin/sh
# Shared Router Provisioner helpers. Sourced by lib/main.sh.

set -eu

PROGRAM='router-provisioner'
VERSION=${ROUTER_PROVISIONER_VERSION:-2.3.0}
DRY_RUN=0
ASSUME_YES=0
DIAGNOSE_ONLY=0
TMP_DIR=''
CONFIG_BACKUP=''
NETSHIFT_READY=0
PINNED_COUNT=0

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

fatal() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup_runtime() {
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[DRY-RUN]'
        for argument in "$@"; do
            printf ' %s' "$argument"
        done
        printf '\n'
        return 0
    fi

    "$@"
}

uci_delete() {
    option=$1

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[DRY-RUN] uci -q delete %s\n' "$option"
        return 0
    fi

    uci -q delete "$option" 2>/dev/null || true
}

# Reconciliation primitives. The provisioner is re-run on routers whose owner
# has already tuned things by hand in LuCI, so it compares before writing and
# never deletes a section wholesale.
CONFIG_KEPT=0
CONFIG_CHANGED=0

uci_value() {
    uci -q get "$1" 2>/dev/null || printf ''
}

# Write only when the option has no value yet. Anything the user already chose
# stays untouched - these are preferences, not correctness requirements.
uci_set_default() {
    option=$1
    value=$2

    if [ -n "$(uci_value "$option")" ]; then
        CONFIG_KEPT=$((CONFIG_KEPT + 1))
        return 0
    fi

    run uci set "$option=$value"
    CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
}

# Write whenever the value differs. Reserved for options the guarded lifecycle
# depends on, where a wrong value breaks the router rather than the taste.
uci_set_required() {
    option=$1
    value=$2

    current=$(uci_value "$option")

    if [ "$current" = "$value" ]; then
        CONFIG_KEPT=$((CONFIG_KEPT + 1))
        return 0
    fi

    [ -n "$current" ] && log "Исправляю $option: '$current' -> '$value'"
    run uci set "$option=$value"
    CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
}

uci_list_contains() {
    uci -q get "$1" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$2"
}

uci_add_list_once() {
    option=$1
    value=$2

    if uci_list_contains "$option" "$value"; then
        CONFIG_KEPT=$((CONFIG_KEPT + 1))
        return 0
    fi

    run uci add_list "$option=$value"
    CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
}

uci_ensure_section() {
    section=$1
    type=$2

    if [ -n "$(uci_value "$section")" ]; then
        CONFIG_KEPT=$((CONFIG_KEPT + 1))
        return 0
    fi

    run uci set "$section=$type"
    CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
}

report_configuration_diff() {
    label=$1

    if [ "$CONFIG_CHANGED" -eq 0 ]; then
        log "$label: всё уже настроено, изменений нет."
    else
        log "$label: изменено $CONFIG_CHANGED, оставлено как было $CONFIG_KEPT."
    fi
}

ask_yes_no() {
    prompt=$1
    default=${2:-no}

    [ "$ASSUME_YES" -eq 1 ] && return 0

    while :; do
        if [ "$default" = yes ]; then
            printf '%s [Y/n]: ' "$prompt" >&2
        else
            printf '%s [y/N]: ' "$prompt" >&2
        fi

        IFS= read -r answer || return 1
        case "$answer" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
                return 1
                ;;
            '')
                [ "$default" = yes ]
                return
                ;;
            *)
                warn 'Введите y или n.'
                ;;
        esac
    done
}

ask_value() {
    prompt=$1
    default=${2:-}

    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi

    IFS= read -r value || return 1
    [ -n "$value" ] || value=$default
    printf '%s\n' "$value"
}

ask_secret() {
    prompt=$1
    value=''

    printf '%s: ' "$prompt" >&2
    if [ -t 0 ] && command_exists stty; then
        stty -echo
        IFS= read -r value || {
            stty echo
            printf '\n' >&2
            return 1
        }
        stty echo
        printf '\n' >&2
    else
        IFS= read -r value || return 1
    fi

    printf '%s\n' "$value"
}

version_ge() {
    awk -v left="$1" -v right="$2" '
        function number(value) {
            sub(/[^0-9].*$/, "", value)
            return value == "" ? 0 : value + 0
        }
        BEGIN {
            left_count = split(left, left_parts, ".")
            right_count = split(right, right_parts, ".")
            count = left_count > right_count ? left_count : right_count
            for (part = 1; part <= count; part++) {
                left_value = number(left_parts[part])
                right_value = number(right_parts[part])
                if (left_value > right_value) exit 0
                if (left_value < right_value) exit 1
            }
            exit 0
        }
    '
}

fetch_to_file() {
    url=$1
    destination=$2

    # Prefer IPv4. On routers whose IPv6 route is absent or broken the AAAA
    # attempt dies with "Operation not permitted" before any request is sent,
    # so fall back to the unforced call for IPv6-only networks.
    if command_exists uclient-fetch; then
        uclient-fetch -4 -q -O "$destination" "$url" 2>/dev/null || \
            uclient-fetch -q -O "$destination" "$url"
    elif command_exists wget; then
        wget -q -O "$destination" "$url"
    elif command_exists curl; then
        curl -4 -fsSL "$url" -o "$destination" 2>/dev/null || \
            curl -fsSL "$url" -o "$destination"
    else
        return 127
    fi
}

default_route_device() {
    ip route show default 2>/dev/null | \
        awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

uplink_interface() {
    device=$1
    [ -n "$device" ] || return 1

    for name in $(ubus list 'network.interface.*' 2>/dev/null | \
        sed 's/^network\.interface\.//'); do
        l3_device=$(ubus call "network.interface.$name" status 2>/dev/null | \
            jsonfilter -e '@.l3_device' 2>/dev/null)
        if [ "$l3_device" = "$device" ]; then
            printf '%s\n' "$name"
            return 0
        fi
    done

    return 1
}

github_latest_tag() {
    repository=$1

    if command_exists curl; then
        redirect=$(curl -sI -o /dev/null -w '%{redirect_url}' \
            --connect-timeout 5 -m 15 -A "$PROGRAM" \
            "https://github.com/${repository}/releases/latest" \
            2>/dev/null || true)
        case "$redirect" in
            */releases/tag/*)
                tag=${redirect##*/releases/tag/}
                case "$tag" in
                    ''|*/*) tag='' ;;
                esac
                if [ -n "$tag" ]; then
                    printf '%s\n' "$tag"
                    return 0
                fi
                ;;
        esac
    fi

    latest_json="$TMP_DIR/gh-latest-$(cache_key "$repository").json"
    fetch_to_file \
        "https://api.github.com/repos/${repository}/releases/latest" \
        "$latest_json" || return 1
    tag=$(sed -n \
        's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$latest_json" | head -n 1)
    [ -n "$tag" ] || return 1

    printf '%s\n' "$tag"
}

cache_key() {
    printf '%s' "$*" | tr -c 'A-Za-z0-9._-' '-'
}

github_asset_url() {
    repository=$1
    tag=$2
    pattern=$3

    release_json="$TMP_DIR/gh-release-$(cache_key "$repository$tag").json"
    if [ ! -s "$release_json" ]; then
        fetch_to_file \
            "https://api.github.com/repos/${repository}/releases/tags/${tag}" \
            "$release_json" || return 1
    fi

    url=$(grep -o \
        '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
        "$release_json" | \
        sed 's/.*"\(https:[^"]*\)"$/\1/' | \
        grep -E "$pattern" | head -n 1)
    [ -n "$url" ] || return 1

    printf '%s\n' "$url"
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --diagnose)
                DIAGNOSE_ONLY=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --yes)
                ASSUME_YES=1
                ;;
            --version|-V)
                printf '%s\n' "$VERSION"
                exit 0
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fatal "Неизвестный параметр: $1"
                ;;
        esac
        shift
    done
}
