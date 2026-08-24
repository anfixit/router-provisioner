#!/bin/sh
# Per-service sections pinned to a fixed node. Sourced by lib/main.sh.
#
# Some services dislike an exit IP that hops between countries: Cloudflare
# starts asking for verification, sessions get re-checked, and a node in an
# unsupported country simply refuses to serve. Such a service gets its own
# NetShift section filtered down to one preferred node plus a reserve, and
# router-provisioner-pin keeps the selector on the preferred one.

PIN_HELPER='/usr/bin/router-provisioner-pin'
PINNED_DIR='/etc/router-provisioner'
PINNED_FILE='/etc/router-provisioner/pinned'
PINNED_COUNT=0

# NetShift builds route rules in section order, and the first matching rule
# wins. A pinned section must therefore sit ahead of the broad ones, otherwise
# a community list such as russia_inside - which already carries claude.ai -
# would grab the traffic first and the pinning would silently do nothing.
move_section_to_front() {
    run uci reorder "netshift.$1=$2"
}

section_name_is_valid() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
        *) return 0 ;;
    esac
}

read_pinned_service() {
    PIN_SECTION=''
    PIN_DOMAINS=''
    PIN_PRIMARY=''
    PIN_RESERVE=''
    PIN_EXCLUDE=''

    PIN_SECTION=$(ask_value \
        'Имя секции латиницей, например ANTHROPIC (Enter - закончить)' '')
    [ -n "$PIN_SECTION" ] || return 1

    if ! section_name_is_valid "$PIN_SECTION"; then
        warn 'Только латиница, цифры и подчёркивание. Сервис пропущен.'
        return 1
    fi

    PIN_DOMAINS=$(ask_value \
        'Домены через пробел, например claude.ai anthropic.com' '')
    if [ -z "$PIN_DOMAINS" ]; then
        warn 'Без доменов секция бессмысленна. Сервис пропущен.'
        return 1
    fi

    log 'Узел задаётся частью имени из подписки, например: Frankfurt'
    PIN_PRIMARY=$(ask_value 'Основной узел' '')
    if [ -z "$PIN_PRIMARY" ]; then
        warn 'Основной узел не задан. Сервис пропущен.'
        return 1
    fi

    PIN_RESERVE=$(ask_value \
        'Резервный узел, включается только при отказе (Enter - без резерва)' '')

    log 'Можно отсечь часть узлов по подстроке имени, например значок'
    log 'транспорта, если нужен только один тип соединения.'
    PIN_EXCLUDE=$(ask_value 'Исключить узлы, содержащие (Enter - ничего)' '')

    return 0
}

write_pinned_section() {
    section=$1

    uci_ensure_section "netshift.$section" section
    uci_set_required "netshift.$section.connection_type" proxy
    uci_set_required "netshift.$section.proxy_config_type" subscription
    uci_set_default "netshift.$section.subscription_format_preference" xray
    uci_set_default "netshift.$section.subscription_insecure" 0
    uci_set_default "netshift.$section.subscription_group_mode" off
    uci_set_default "netshift.$section.subscription_update_interval" 6h
    uci_set_default "netshift.$section.urltest_check_interval" 5m
    uci_set_default "netshift.$section.urltest_tolerance" 50
    uci_set_default "netshift.$section.urltest_testing_url" \
        https://www.gstatic.com/generate_204
    uci_set_default "netshift.$section.enable_udp_over_tcp" 0
    uci_set_required "netshift.$section.global_proxy" 0
    uci_set_default "netshift.$section.user_subnet_list_type" disabled
    uci_set_default "netshift.$section.mixed_proxy_enabled" 0
    uci_set_default "netshift.$section.resolve_real_ip_for_routing" 0

    # The section reuses the same subscription, then narrows it by node name.
    if [ "$DRY_RUN" -eq 0 ]; then
        subscription=$(uci -q get netshift.VPN.subscription_url) || subscription=''
        if [ -n "$subscription" ]; then
            uci -q delete "netshift.$section.subscription_url" 2>/dev/null || true
            uci add_list "netshift.$section.subscription_url=$subscription"
        fi

        uci -q delete "netshift.$section.subscription_filter_include_keywords" \
            2>/dev/null || true
        uci add_list \
            "netshift.$section.subscription_filter_include_keywords=$PIN_PRIMARY"
        [ -n "$PIN_RESERVE" ] && uci add_list \
            "netshift.$section.subscription_filter_include_keywords=$PIN_RESERVE"

        uci -q delete "netshift.$section.subscription_filter_exclude_keywords" \
            2>/dev/null || true
        [ -n "$PIN_EXCLUDE" ] && uci add_list \
            "netshift.$section.subscription_filter_exclude_keywords=$PIN_EXCLUDE"

        domains_text=''
        for domain in $PIN_DOMAINS; do
            if [ -z "$domains_text" ]; then
                domains_text=$domain
            else
                domains_text="$domains_text
$domain"
            fi
        done
        uci set "netshift.$section.user_domain_list_type=text"
        uci set "netshift.$section.user_domains_text=$domains_text"
    else
        log "Секция $section получила бы подписку и фильтр [REDACTED]."
    fi
}

configure_pinned_sections() {
    printf '\n'
    log 'Отдельный узел под сервис нужен там, где смена страны выхода ломает'
    log 'работу: Anthropic, банки, сервисы с проверкой геолокации.'

    ask_yes_no 'Направить отдельные сервисы через фиксированные узлы?' no || {
        log 'Фиксированные узлы пропущены.'
        return 0
    }

    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$PINNED_DIR"
        : > "$PINNED_FILE"
        chmod 600 "$PINNED_FILE"
    fi

    PINNED_COUNT=0
    position=0

    while read_pinned_service; do
        write_pinned_section "$PIN_SECTION"
        move_section_to_front "$PIN_SECTION" "$position"
        position=$((position + 1))
        PINNED_COUNT=$((PINNED_COUNT + 1))

        if [ "$DRY_RUN" -eq 0 ]; then
            printf '%s-out|%s|%s\n' \
                "$PIN_SECTION" "$PIN_PRIMARY" "$PIN_RESERVE" >> "$PINNED_FILE"
        fi

        log "Секция $PIN_SECTION настроена."
        ask_yes_no 'Добавить ещё один сервис?' no || break
    done

    if [ "$PINNED_COUNT" -eq 0 ]; then
        log 'Ни один сервис не задан.'
        return 0
    fi

    run uci commit netshift
    install_pin_helper
    log "Настроено сервисов с фиксированным узлом: $PINNED_COUNT"
}

# The pin helper runs every minute, and busybox crond announces every job it
# starts. That is 1440 lines a day into a 128 KB ring buffer held in RAM, which
# leaves barely eight hours of history - and nothing on disk. The first time an
# intermittent fault was investigated, the whole window had already been
# overwritten by the announcements of the helper meant to prevent such faults.
# Silence the announcements and give the buffer room, so the next fault is still
# visible when someone comes looking.
keep_log_buffer_usable() {
    _log_before=$CONFIG_CHANGED

    uci_set_required 'system.@system[0].cronloglevel' '9'
    uci_set_required 'system.@system[0].log_size' '512'

    [ "$CONFIG_CHANGED" -gt "$_log_before" ] || return 0

    run uci commit system
    run /etc/init.d/log restart >/dev/null 2>&1 || \
        warn 'Не удалось перезапустить log; размер буфера применится после перезагрузки.'
}

install_pin_helper() {
    runtime_dir=${ROUTER_PROVISIONER_RUNTIME_DIR:-}

    if [ "$DRY_RUN" -eq 1 ]; then
        log "Был бы установлен $PIN_HELPER и добавлен в cron."
        return 0
    fi

    [ -n "$runtime_dir" ] || {
        warn 'Runtime directory не задан, helper фиксации не установлен.'
        return 0
    }

    cp "$runtime_dir/router-provisioner-pin" "$PIN_HELPER" || {
        warn 'Не удалось скопировать helper фиксации узлов.'
        return 0
    }
    chmod 700 "$PIN_HELPER"

    keep_log_buffer_usable

    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    temporary="/tmp/router-provisioner-pin-cron.$$"
    grep -v 'router-provisioner-pin' /etc/crontabs/root > "$temporary" || true
    {
        cat "$temporary"
        printf '* * * * * %s\n' "$PIN_HELPER"
    } > /etc/crontabs/root
    rm -f "$temporary"
    chmod 600 /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || \
        warn 'Cron не перезапустился, фиксация узлов заработает позже.'
}
