#!/bin/sh
# Router Provisioner bootstrap launcher for OpenWrt.
# Downloads versioned runtime files without consuming interactive stdin.

set -eu

PROGRAM='router-provisioner'
VERSION='2.13.0'
REPOSITORY='anfixit/router-provisioner'
REF=${ROUTER_PROVISIONER_REF:-main}
RUNTIME_DIR=''

log() {
    printf '[INFO] %s\n' "$*"
}

fatal() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    [ -n "$RUNTIME_DIR" ] && rm -rf "$RUNTIME_DIR"
}

trap cleanup 0 HUP INT TERM

fetch_file() {
    remote_path=$1
    destination=$2
    url="https://raw.githubusercontent.com/${REPOSITORY}/${REF}/${remote_path}"

    # Prefer IPv4: a missing IPv6 route makes the AAAA attempt fail with
    # "Operation not permitted" before the request leaves the router.
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -4 -q -O "$destination" "$url" 2>/dev/null || \
            uclient-fetch -q -O "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$destination" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL "$url" -o "$destination" 2>/dev/null || \
            curl -fsSL "$url" -o "$destination"
    else
        return 127
    fi
}

main() {
    if [ "${1:-}" = '--version' ] || [ "${1:-}" = '-V' ]; then
        printf '%s\n' "$VERSION"
        exit 0
    fi

    [ "$(id -u 2>/dev/null || printf 1)" -eq 0 ] || \
        fatal 'Запустите скрипт от root.'
    [ -r /etc/openwrt_release ] || fatal 'OpenWrt не обнаружен.'

    case " $* " in
        *' --diagnose '*) : ;;
        *)
            [ -t 0 ] || \
                fatal 'Нужен интерактивный SSH-сеанс. Не используйте curl | sh.'
            ;;
    esac

    RUNTIME_DIR=$(mktemp -d "/tmp/${PROGRAM}.XXXXXX") || \
        fatal 'Не удалось создать временный каталог.'

    for module in \
        common system netshift youtubeunblock adblock pinning lifecycle main; do
        destination="$RUNTIME_DIR/${module}.sh"
        fetch_file "lib/${module}.sh" "$destination" || \
            fatal "Не удалось скачать lib/${module}.sh из ref ${REF}."
        [ -s "$destination" ] || fatal "Модуль lib/${module}.sh пуст."
    done

    for helper in \
        router-provisioner-netshift-start \
        router-provisioner-netshift-refresh \
        router-provisioner-pin \
        router-provisioner-upgrade \
        router-provisioner-report \
        router-provisioner-logship \
        router-provisioner-command; do
        destination="$RUNTIME_DIR/$helper"
        fetch_file "runtime/$helper" "$destination" || \
            fatal "Не удалось скачать runtime/$helper из ref ${REF}."
        [ -s "$destination" ] || fatal "Runtime helper $helper пуст."
    done

    ROUTER_PROVISIONER_RUNTIME_DIR=$RUNTIME_DIR
    ROUTER_PROVISIONER_VERSION=$VERSION
    export ROUTER_PROVISIONER_RUNTIME_DIR ROUTER_PROVISIONER_VERSION

    log "Запуск ${PROGRAM} v${VERSION}, ref=${REF}"
    exec /bin/sh "$RUNTIME_DIR/main.sh" "$@"
}

main "$@"
