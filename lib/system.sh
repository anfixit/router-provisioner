#!/bin/sh
# OpenWrt diagnostics and base configuration. Sourced by lib/main.sh.

MIN_OPENWRT_VERSION='24.10.0'
MIN_OVERLAY_FREE_KIB=25600
MIN_RAM_KIB=65536

release_value() {
    key=$1
    sed -n "s/^${key}=['\"]\{0,1\}\([^'\"]*\).*/\1/p" \
        /etc/openwrt_release | head -n 1
}

board_value() {
    expression=$1
    ubus call system board 2>/dev/null | \
        jsonfilter -e "$expression" 2>/dev/null || true
}

package_manager() {
    if command_exists apk; then
        printf 'apk\n'
    elif command_exists opkg; then
        printf 'opkg\n'
    else
        printf 'none\n'
    fi
}

require_environment() {
    [ "$(id -u 2>/dev/null || printf 1)" -eq 0 ] || \
        fatal 'Запустите скрипт от root.'
    [ -r /etc/openwrt_release ] || fatal 'OpenWrt не обнаружен.'

    if [ "$DIAGNOSE_ONLY" -eq 0 ] && [ ! -t 0 ]; then
        fatal 'Нужен интерактивный SSH-сеанс. Не используйте curl | sh.'
    fi

    command_exists uci || fatal 'Команда uci не найдена.'
    command_exists ubus || fatal 'Команда ubus не найдена.'
    command_exists jsonfilter || fatal 'Команда jsonfilter не найдена.'
}

print_diagnostics() {
    openwrt_version=$(release_value DISTRIB_RELEASE)
    target=$(release_value DISTRIB_TARGET)
    architecture=$(release_value DISTRIB_ARCH)
    model=$(board_value '@.model')
    board=$(board_value '@.board_name')
    manager=$(package_manager)

    overlay_free_kib=$(df -Pk /overlay 2>/dev/null | \
        awk 'NR == 2 {print $4}' || true)
    [ -n "$overlay_free_kib" ] || overlay_free_kib=$(df -Pk / | \
        awk 'NR == 2 {print $4}')
    ram_kib=$(awk '$1 == "MemTotal:" {print $2}' /proc/meminfo)

    printf '\n=== Диагностика ===\n'
    printf 'Модель:             %s\n' "${model:-не определена}"
    printf 'Board:              %s\n' "${board:-не определён}"
    printf 'OpenWrt:            %s\n' "${openwrt_version:-не определён}"
    printf 'Target:             %s\n' "${target:-не определён}"
    printf 'Архитектура:        %s\n' "${architecture:-не определена}"
    printf 'Пакетный менеджер:  %s\n' "$manager"
    printf 'Свободный overlay:  %s MiB\n' \
        "$(awk -v value="$overlay_free_kib" 'BEGIN {printf "%.1f", value / 1024}')"
    printf 'RAM:                %s MiB\n' \
        "$(awk -v value="$ram_kib" 'BEGIN {printf "%.1f", value / 1024}')"

    [ "$manager" != none ] || fatal 'Не найден apk или opkg.'
    version_ge "$openwrt_version" "$MIN_OPENWRT_VERSION" || \
        fatal "Нужен OpenWrt $MIN_OPENWRT_VERSION или новее."
    [ "$overlay_free_kib" -ge "$MIN_OVERLAY_FREE_KIB" ] || \
        fatal 'Требуется не менее 25 MiB свободного overlay.'
    [ "$ram_kib" -ge "$MIN_RAM_KIB" ] || \
        fatal 'Требуется не менее 64 MiB RAM.'
}

install_required_packages() {
    manager=$(package_manager)

    case "$manager" in
        apk)
            run apk update
            run apk add ca-bundle jq
            ;;
        opkg)
            run opkg update
            run opkg install ca-bundle jq
            ;;
        *)
            fatal 'Не найден пакетный менеджер.'
            ;;
    esac
}

create_configuration_backup() {
    timestamp=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf unknown)
    CONFIG_BACKUP="/tmp/router-provisioner-${timestamp}.tar.gz"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "Была бы создана резервная копия $CONFIG_BACKUP"
        return 0
    fi

    command_exists sysupgrade || fatal 'Команда sysupgrade не найдена.'
    sysupgrade -b "$CONFIG_BACKUP" || \
        fatal 'Не удалось создать резервную копию.'
    chmod 600 "$CONFIG_BACKUP"
    log "Резервная копия: $CONFIG_BACKUP"
    warn 'Скопируйте архив с роутера: /tmp очищается после перезагрузки.'
}

configure_identity() {
    if ask_yes_no 'Изменить hostname?' no; then
        current=$(uci -q get system.@system[0].hostname || printf OpenWrt)
        hostname=$(ask_value 'Новый hostname' "$current")
        case "$hostname" in
            ''|*[!A-Za-z0-9._-]*)
                warn 'Некорректный hostname, изменение пропущено.'
                ;;
            *)
                run uci set "system.@system[0].hostname=$hostname"
                run uci commit system
                ;;
        esac
    fi

    if ask_yes_no 'Изменить пароль root?' no; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log 'Пароль root был бы изменён интерактивно.'
        else
            passwd || fatal 'Не удалось изменить пароль root.'
        fi
    fi
}

valid_public_key() {
    case "$1" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

configure_ssh() {
    ask_yes_no \
        'Настроить SSH-ключ и ограничить Dropbear локальной сетью?' \
        yes || return 0

    public_key=$(ask_value \
        'Вставьте публичный SSH-ключ, либо оставьте пустым' '')

    if [ -n "$public_key" ]; then
        valid_public_key "$public_key" || \
            fatal 'Публичный SSH-ключ имеет неподдерживаемый формат.'

        if [ "$DRY_RUN" -eq 0 ]; then
            mkdir -p /etc/dropbear
            touch /etc/dropbear/authorized_keys
            chmod 700 /etc/dropbear
            chmod 600 /etc/dropbear/authorized_keys
            grep -Fx "$public_key" /etc/dropbear/authorized_keys \
                >/dev/null 2>&1 || \
                printf '%s\n' "$public_key" >> \
                    /etc/dropbear/authorized_keys
        fi
    fi

    ssh_port=$(ask_value 'SSH-порт' '22')
    case "$ssh_port" in
        ''|*[!0-9]*) fatal 'SSH-порт должен быть числом.' ;;
    esac
    [ "$ssh_port" -ge 1 ] && [ "$ssh_port" -le 65535 ] || \
        fatal 'SSH-порт вне диапазона 1..65535.'

    run uci set 'dropbear.@dropbear[0].Interface=lan'
    run uci set "dropbear.@dropbear[0].Port=$ssh_port"

    if [ -n "$public_key" ]; then
        run uci set 'dropbear.@dropbear[0].PasswordAuth=off'
        run uci set 'dropbear.@dropbear[0].RootPasswordAuth=off'
    else
        warn 'Ключ не задан: парольный вход оставлен включённым.'
    fi

    run uci commit dropbear
    warn 'Dropbear не перезапускается автоматически.'
}

configure_wifi() {
    ask_yes_no 'Изменить существующие Wi-Fi точки доступа?' no || return 0

    ssid=$(ask_value 'Новый SSID' '')
    [ -n "$ssid" ] || {
        warn 'SSID пустой, Wi-Fi не изменён.'
        return 0
    }

    wifi_password=$(ask_secret 'Новый Wi-Fi пароль, минимум 8 символов')
    [ "${#wifi_password}" -ge 8 ] || \
        fatal 'Wi-Fi пароль короче 8 символов.'

    found=0
    for section in $(uci -q show wireless | \
        sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
        mode=$(uci -q get "wireless.$section.mode" || true)
        [ "$mode" = ap ] || continue
        found=1
        run uci set "wireless.$section.ssid=$ssid"
        run uci set "wireless.$section.encryption=sae-mixed"

        if [ "$DRY_RUN" -eq 1 ]; then
            log "Пароль Wi-Fi для $section был бы сохранён скрытно."
        else
            uci set "wireless.$section.key=$wifi_password"
        fi
    done

    wifi_password=''
    [ "$found" -eq 1 ] || fatal 'Не найдено ни одной Wi-Fi AP-секции.'
    run uci commit wireless
}
