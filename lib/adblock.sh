#!/bin/sh
# Ad blocking through AdGuard DNS. Sourced by lib/main.sh.
#
# NetShift resolves every LAN query through sing-box, so pointing its upstream
# at AdGuard filters ads for the whole network at once - no per-device setup.
# This deliberately does NOT install https-dns-proxy: NetShift treats it as a
# conflicting package and its own installer refuses to run while it is present.

ADGUARD_DEFAULT_DOH='dns.adguard-dns.com/dns-query'
ADGUARD_FAMILY_DOH='family.adguard-dns.com/dns-query'
ADGUARD_BOOTSTRAP='77.88.8.8'

# Personal endpoints are shown as https://d.adguard-dns.com/dns-query/<id>, so
# accept that form - but store it without the scheme. NetShift's own config
# builder copes with either, while its diagnostic splits the value on the first
# slash: "https://host/path" leaves it probing a host literally named "https:"
# and reporting a healthy resolver as broken.
strip_url_scheme() {
    case "$1" in
        https://*) printf '%s\n' "${1#https://}" ;;
        http://*) printf '%s\n' "${1#http://}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

valid_doh_url() {
    case "$(strip_url_scheme "$1")" in
        */*) return 0 ;;
        *) return 1 ;;
    esac
}

configure_adblock() {
    printf '\n'
    ask_yes_no 'Блокировать рекламу через AdGuard DNS?' yes || {
        log 'Блокировка рекламы пропущена.'
        return 0
    }

    resolver=''

    # With --yes every question answers itself, so never prompt for a secret
    # there: fall through to the public resolver instead.
    if [ "$ASSUME_YES" -eq 0 ] && \
        ask_yes_no 'Есть персональный AdGuard DNS?' no; then
        log 'Адрес из кабинета, например d.adguard-dns.com/dns-query/ВАШ_ИД'
        log 'Берётся в личном кабинете AdGuard, раздел «Устройства».'

        while :; do
            # A bare assignment would abort the run under set -e when the
            # reader hits end of input.
            candidate=$(ask_secret \
                'Персональный DoH-адрес (Enter - пропустить)') || candidate=''

            [ -n "$candidate" ] || break

            if valid_doh_url "$candidate"; then
                resolver=$(strip_url_scheme "$candidate")
                break
            fi

            warn 'Нужен адрес вида хост/путь, можно с https:// в начале.'
        done
    fi

    if [ -n "$resolver" ]; then
        log 'Выбран персональный AdGuard DNS.'
    elif [ "$ASSUME_YES" -eq 0 ] && \
        ask_yes_no 'Включить фильтр «Семейный» (плюс взрослый контент)?' no; then
        resolver=$ADGUARD_FAMILY_DOH
        log 'Выбран публичный AdGuard Family.'
    else
        resolver=$ADGUARD_DEFAULT_DOH
        log 'Выбран публичный AdGuard Default: реклама и трекеры.'
    fi

    run uci set 'netshift.settings.dns_type=doh'
    if [ "$DRY_RUN" -eq 1 ]; then
        log 'Был бы записан адрес AdGuard [REDACTED].'
    else
        uci set "netshift.settings.dns_server=$resolver"
    fi
    run uci set \
        "netshift.settings.bootstrap_dns_server=$ADGUARD_BOOTSTRAP"
    run uci commit netshift

    resolver=''
    log 'AdGuard DNS настроен как вышестоящий резолвер NetShift.'
    warn 'Реклама внутри видео (YouTube, VK Video) через DNS не блокируется.'
}
