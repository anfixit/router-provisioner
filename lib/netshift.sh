#!/bin/sh
# NetShift installation, configuration and guarded lifecycle.

NETSHIFT_REPOSITORY='yandexru45/netshift'
NETSHIFT_INSTALLER='https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh'
RUSSIA_OUTSIDE_URL='https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_outside.srs'
BOOT_HELPER='/usr/bin/router-provisioner-netshift-start'
REFRESH_HELPER='/usr/bin/router-provisioner-netshift-refresh'
BOOT_SERVICE='/etc/init.d/router-provisioner-netshift'
YOUTUBE_LIST='/etc/netshift/rulesets/youtube-direct.lst'
SUBSCRIPTIONS=''

wait_for_wan() {
    timeout=${1:-120}
    elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if ubus call network.interface.wan status 2>/dev/null | \
            grep -q '"up"[[:space:]]*:[[:space:]]*true' && \
            ip route show default 2>/dev/null | grep -q '^default '; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

netshift_installed_version() {
    [ -x /usr/bin/netshift ] || return 0
    version=$(/usr/bin/netshift show_version 2>/dev/null | head -n 1) || true
    printf '%s\n' "${version#v}"
}

install_netshift() {
    installed=$(netshift_installed_version)
    latest=$(github_latest_tag "$NETSHIFT_REPOSITORY" || true)
    latest=${latest#v}

    if [ -n "$installed" ]; then
        log "Установленный NetShift: $installed"
    fi

    if [ -n "$latest" ]; then
        log "Последний релиз NetShift: $latest"
    else
        warn 'Не удалось определить последний релиз NetShift.'
    fi

    if [ -n "$installed" ] && [ -n "$latest" ] && \
        version_ge "$installed" "$latest"; then
        log 'NetShift уже последней версии.'
        return 0
    fi

    installer="$TMP_DIR/netshift-install.sh"
    fetch_to_file "$NETSHIFT_INSTALLER" "$installer" || \
        fatal 'Не удалось скачать официальный установщик NetShift.'

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$installed" ]; then
            log "Официальный установщик обновил бы NetShift до ${latest:-latest}."
        else
            log 'Официальный установщик NetShift был бы запущен.'
        fi
        return 0
    fi

    warn 'Официальный установщик NetShift может задать свои вопросы.'
    warn 'Он предложит удалить https-dns-proxy, если тот установлен.'

    if sh "$installer"; then
        :
    elif [ -n "$installed" ]; then
        warn "Обновление не удалось, остаётся установленный NetShift $installed."
        return 0
    else
        fatal 'Установка NetShift завершилась ошибкой.'
    fi

    [ -x /usr/bin/netshift ] && [ -x /etc/init.d/netshift ] || \
        fatal 'NetShift установлен не полностью.'

    current=$(netshift_installed_version)
    log "Активная версия NetShift: ${current:-неизвестна}"

    if [ -n "$latest" ] && [ -n "$current" ] && \
        ! version_ge "$current" "$latest"; then
        warn "Ожидался NetShift $latest, установлен $current."
    fi
}

install_extended_sing_box() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log 'Был бы установлен sing-box extended.'
        return 0
    fi

    if /usr/bin/sing-box version 2>/dev/null | \
        head -n 1 | grep -q extended; then
        log 'sing-box extended уже установлен.'
        return 0
    fi

    /usr/bin/netshift component_action sing_box install_extended || \
        fatal 'NetShift не смог установить sing-box extended.'

    /usr/bin/sing-box version 2>/dev/null | \
        head -n 1 | grep -q extended || \
        fatal 'Активен не sing-box extended.'
}

read_subscriptions() {
    SUBSCRIPTIONS=''
    subscription_number=1

    while :; do
        subscription_url=$(ask_secret \
            "Ссылка подписки #$subscription_number")

        case "$subscription_url" in
            https://*) : ;;
            *) fatal 'Ссылка подписки должна начинаться с https://.' ;;
        esac

        if [ -z "$SUBSCRIPTIONS" ]; then
            SUBSCRIPTIONS=$subscription_url
        else
            SUBSCRIPTIONS="$SUBSCRIPTIONS
$subscription_url"
        fi

        [ "$ASSUME_YES" -eq 1 ] && break
        ask_yes_no 'Добавить ещё одну подписку?' no || break
        subscription_number=$((subscription_number + 1))
    done
}

write_youtube_direct_list() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Был бы создан $YOUTUBE_LIST"
        return 0
    fi

    mkdir -p "$(dirname "$YOUTUBE_LIST")"
    cat > "$YOUTUBE_LIST" <<'EOF_YOUTUBE'
youtube.com
youtu.be
youtube-nocookie.com
youtubekids.com
googlevideo.com
ytimg.com
ggpht.com
youtubei.googleapis.com
youtubeembeddedplayer.googleapis.com
yt3.googleusercontent.com
EOF_YOUTUBE
    chmod 644 "$YOUTUBE_LIST"
}

configure_netshift() {
    read_subscriptions
    write_youtube_direct_list

    uci_delete netshift.VPN
    uci_delete netshift.RU_DIRECT

    run uci set 'netshift.settings=settings'
    run uci set 'netshift.settings.dns_type=doh'
    run uci set 'netshift.settings.dns_server=dns.adguard-dns.com'
    run uci set 'netshift.settings.bootstrap_dns_server=77.88.8.8'
    run uci set 'netshift.settings.dns_rewrite_ttl=60'
    run uci set 'netshift.settings.enable_output_network_interface=0'
    run uci set 'netshift.settings.enable_badwan_interface_monitoring=0'
    run uci set 'netshift.settings.enable_yacd=0'
    run uci set 'netshift.settings.disable_quic=0'
    run uci set 'netshift.settings.update_interval=1d'
    run uci set 'netshift.settings.download_lists_via_proxy=0'
    run uci set 'netshift.settings.dont_touch_dhcp=0'
    run uci set 'netshift.settings.config_path=/etc/sing-box/config.json'
    run uci set 'netshift.settings.cache_path=/tmp/sing-box/cache.db'
    run uci set 'netshift.settings.log_level=warn'
    run uci set 'netshift.settings.exclude_ntp=0'
    run uci set 'netshift.settings.shutdown_correctly=0'
    run uci set 'netshift.settings.dns_via_outbound=0'
    run uci set 'netshift.settings.block_doh=0'
    run uci set 'netshift.settings.enable_ipv6=0'
    uci_delete netshift.settings.source_network_interfaces
    run uci add_list \
        'netshift.settings.source_network_interfaces=br-lan'

    run uci set 'netshift.VPN=section'
    run uci set 'netshift.VPN.connection_type=proxy'
    run uci set 'netshift.VPN.proxy_config_type=subscription'
    run uci set 'netshift.VPN.subscription_format_preference=xray'
    run uci set 'netshift.VPN.subscription_insecure=0'
    run uci set 'netshift.VPN.subscription_group_mode=off'
    run uci set 'netshift.VPN.subscription_update_interval=disabled'
    run uci set 'netshift.VPN.urltest_check_interval=3m'
    run uci set 'netshift.VPN.urltest_tolerance=50'
    run uci set \
        'netshift.VPN.urltest_testing_url=https://www.gstatic.com/generate_204'
    run uci set 'netshift.VPN.enable_udp_over_tcp=0'
    run uci set 'netshift.VPN.global_proxy=1'
    run uci set 'netshift.VPN.user_domain_list_type=disabled'
    run uci set 'netshift.VPN.user_subnet_list_type=disabled'
    run uci set 'netshift.VPN.mixed_proxy_enabled=0'
    run uci set 'netshift.VPN.resolve_real_ip_for_routing=0'
    uci_delete netshift.VPN.subscription_url

    subscriptions_file="$TMP_DIR/subscriptions"
    printf '%s\n' "$SUBSCRIPTIONS" > "$subscriptions_file"
    while IFS= read -r subscription_url; do
        [ -n "$subscription_url" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            log 'Была бы добавлена ссылка подписки [REDACTED].'
        else
            uci add_list \
                "netshift.VPN.subscription_url=$subscription_url"
        fi
    done < "$subscriptions_file"
    SUBSCRIPTIONS=''

    run uci set 'netshift.RU_DIRECT=section'
    run uci set 'netshift.RU_DIRECT.connection_type=exclusion'
    run uci set 'netshift.RU_DIRECT.global_proxy=0'
    run uci add_list \
        'netshift.RU_DIRECT.community_lists=russia_outside'
    run uci set 'netshift.RU_DIRECT.user_domain_list_type=text'
    direct_domains='.ru
.su'
    run uci set \
        "netshift.RU_DIRECT.user_domains_text=$direct_domains"
    run uci set 'netshift.RU_DIRECT.user_subnet_list_type=disabled'
    run uci add_list \
        "netshift.RU_DIRECT.local_domain_lists=$YOUTUBE_LIST"
    run uci commit netshift
}

start_and_validate_netshift() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log 'NetShift не запускался в dry-run.'
        return 0
    fi

    wait_for_wan 120 || fatal 'WAN не поднялся за 120 секунд.'
    preflight_file="$TMP_DIR/russia_outside.srs"
    fetch_to_file "$RUSSIA_OUTSIDE_URL" "$preflight_file" && \
        [ -s "$preflight_file" ] || \
        fatal 'Роутер не может скачать russia_outside.srs напрямую.'

    "$BOOT_SERVICE" restart || true

    count=0
    while [ "$count" -lt 50 ]; do
        if pgrep -f '[s]ing-box run' >/dev/null 2>&1 && \
            /usr/bin/sing-box check -c /etc/sing-box/config.json \
                >/dev/null 2>&1 && \
            nslookup www.gstatic.com 127.0.0.42 2>/dev/null | \
                grep -Eq '198\.18\.'; then
            log 'NetShift, sing-box и FakeIP работают.'
            return 0
        fi
        sleep 2
        count=$((count + 1))
    done

    logread -e netshift -e sing-box -e router-provisioner-boot | \
        tail -n 80 >&2 || true
    fatal 'NetShift не стал готов за 100 секунд.'
}
