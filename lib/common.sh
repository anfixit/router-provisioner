#!/bin/sh
# Shared Router Provisioner helpers. Sourced by lib/main.sh.

set -eu

PROGRAM='router-provisioner'
VERSION=${ROUTER_PROVISIONER_VERSION:-2.0.0}
DRY_RUN=0
ASSUME_YES=0
DIAGNOSE_ONLY=0
TMP_DIR=''
CONFIG_BACKUP=''

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
            for (index = 1; index <= count; index++) {
                left_value = number(left_parts[index])
                right_value = number(right_parts[index])
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

    if command_exists uclient-fetch; then
        uclient-fetch -q -O "$destination" "$url"
    elif command_exists wget; then
        wget -q -O "$destination" "$url"
    elif command_exists curl; then
        curl -fsSL "$url" -o "$destination"
    else
        return 127
    fi
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
