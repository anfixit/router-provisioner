#!/bin/sh
# NetShift installation, configuration and guarded lifecycle.

NETSHIFT_REPOSITORY='yandexru45/netshift'
NETSHIFT_INSTALLER='https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh'
RUSSIA_OUTSIDE_URL='https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_outside.srs'
BOOT_HELPER='/usr/bin/router-provisioner-netshift-start'
REFRESH_HELPER='/usr/bin/router-provisioner-netshift-refresh'
BOOT_SERVICE='/etc/init.d/router-provisioner-netshift'
YOUTUBE_LIST='/etc/netshift/rulesets/youtube-direct.lst'
MAX_SUBSCRIPTIONS=2
SUBSCRIPTIONS=''
SUBSCRIPTION_COUNT=0

# The uplink is whatever carries the default route. Assuming an interface
# literally named "wan" broke Wi-Fi-client, wwan and pppoe uplinks. Real
# reachability is proven right after by the ruleset preflight download.
wait_for_wan() {
    timeout=${1:-120}
    elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        device=$(default_route_device)
        if [ -n "$device" ]; then
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
    if ! fetch_to_file "$NETSHIFT_INSTALLER" "$installer"; then
        warn 'Не удалось скачать официальный установщик NetShift.'
        return 1
    fi

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
        warn 'Установка NetShift завершилась ошибкой.'
        return 1
    fi

    if [ ! -x /usr/bin/netshift ] || [ ! -x /etc/init.d/netshift ]; then
        warn 'NetShift установлен не полностью.'
        return 1
    fi

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

    if ! /usr/bin/netshift component_action sing_box install_extended; then
        warn 'NetShift не смог установить sing-box extended.'
        return 1
    fi

    if ! /usr/bin/sing-box version 2>/dev/null | head -n 1 | grep -q extended; then
        warn 'Активен не sing-box extended.'
        return 1
    fi
}

# Subscriptions are optional. Everything else is still configured, so the
# remaining step is pasting the URL into LuCI later. SUBSCRIPTION_COUNT
# survives the wipe of SUBSCRIPTIONS and decides whether NetShift may start.
read_subscriptions() {
    SUBSCRIPTIONS=''
    SUBSCRIPTION_COUNT=0
    subscription_number=1

    printf '\n'
    log 'Ссылку подписки можно не вводить: нажмите Enter, чтобы пропустить.'
    log 'Тогда всё остальное настроится, а подписку добавите в LuCI позже.'

    while [ "$subscription_number" -le "$MAX_SUBSCRIPTIONS" ]; do
        # A bare assignment would abort the run under set -e when the reader
        # hits end of input, for example on Ctrl-D.
        subscription_url=$(ask_secret \
            "Ссылка подписки #$subscription_number (Enter - пропустить)") || \
            subscription_url=''

        [ -n "$subscription_url" ] || break

        case "$subscription_url" in
            https://*) : ;;
            *)
                warn 'Ссылка должна начинаться с https://. Пропущена.'
                subscription_number=$((subscription_number + 1))
                continue
                ;;
        esac

        if [ -z "$SUBSCRIPTIONS" ]; then
            SUBSCRIPTIONS=$subscription_url
        else
            SUBSCRIPTIONS="$SUBSCRIPTIONS
$subscription_url"
        fi
        SUBSCRIPTION_COUNT=$((SUBSCRIPTION_COUNT + 1))

        subscription_number=$((subscription_number + 1))

        # Plain "[ ... ] && break" would return 1 as the last command of the
        # loop body and set -e would kill the whole run.
        if [ "$ASSUME_YES" -eq 1 ]; then
            break
        fi
    done

    if [ "$SUBSCRIPTION_COUNT" -eq 0 ]; then
        warn 'Подписка не задана. NetShift настроен, но запускаться не будет.'
        warn 'Добавьте ссылку в LuCI: Services -> NetShift -> Секции -> VPN.'
    else
        log "Принято ссылок подписки: $SUBSCRIPTION_COUNT"
    fi
}

write_youtube_direct_list() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Был бы создан $YOUTUBE_LIST"
        return 0
    fi

    mkdir -p "$(dirname "$YOUTUBE_LIST")"
    # The page belongs here too, not only the media. Left on the proxy it
    # reaches Google from whichever country the subscription picked that
    # minute, so YouTube answers in that country's language and serves that
    # country's ads - which Google does not sell into Russia at all. The split
    # was also incoherent: the page arrived from Germany while the video it
    # described streamed from the owner's own address.
    #
    # Measured on the router before this was changed: fetched over the direct
    # route from a Russian address, www.youtube.com answers 200 with a full
    # 880 KB document, TLS in 0.12 s, three times out of three. youtubeUnblock
    # carries the page as reliably as it carries the CDN.
    #
    # The control-plane API stays on the proxy, one host excepted: jnn-pa is
    # YouTube's attestation endpoint, and answering it from a different country
    # than the page came from is asking to be challenged.
    cat > "$YOUTUBE_LIST" <<'EOF_YOUTUBE'
googlevideo.com
ytimg.com
ggpht.com
yt3.googleusercontent.com
youtube.com
youtu.be
jnn-pa.googleapis.com
EOF_YOUTUBE
    chmod 644 "$YOUTUBE_LIST"
}

# Reconciles the NetShift configuration instead of rewriting it. Sections are
# never deleted, and any value the owner already picked in LuCI is left alone.
# Only the handful of options the guarded lifecycle depends on are enforced.
# NetShift ships a placeholder section - "main" out of the box - with
# proxy_config_type=url and no proxy_string. That combination is fatal: NetShift
# aborts the whole config generation with "Proxy string is not set", never
# writes /etc/sing-box/config.json, and sing-box then refuses to start on the
# package's own default file. Reconciliation otherwise never deletes sections,
# but an unfinished proxy section is not configuration, it is a trap.
remove_unconfigured_proxy_sections() {
    for candidate in $(uci show netshift 2>/dev/null | \
        sed -n 's/^netshift\.\([^.=]*\)=section$/\1/p'); do
        [ "$(uci_value "netshift.$candidate.connection_type")" = proxy ] || \
            continue

        case "$(uci_value "netshift.$candidate.proxy_config_type")" in
            ''|url) : ;;
            *) continue ;;
        esac

        [ -z "$(uci_value "netshift.$candidate.proxy_string")" ] || continue

        if [ "$DRY_RUN" -eq 1 ]; then
            log "Пустая секция $candidate была бы удалена."
            continue
        fi

        uci -q delete "netshift.$candidate" 2>/dev/null || continue
        warn "Удалена незаполненная секция $candidate: без ссылки прокси"
        warn 'NetShift отказывается собирать конфигурацию целиком.'
        CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
    done
}

configure_netshift() {
    read_subscriptions
    write_youtube_direct_list

    CONFIG_KEPT=0
    CONFIG_CHANGED=0

    remove_unconfigured_proxy_sections

    uci_ensure_section netshift.settings settings
    uci_set_default netshift.settings.dns_type doh
    uci_set_default netshift.settings.dns_server dns.adguard-dns.com
    uci_set_default netshift.settings.bootstrap_dns_server 77.88.8.8
    uci_set_default netshift.settings.dns_rewrite_ttl 60
    uci_set_default netshift.settings.enable_output_network_interface 0
    uci_set_default netshift.settings.enable_badwan_interface_monitoring 0
    uci_set_default netshift.settings.enable_yacd 0
    uci_set_default netshift.settings.disable_quic 0
    uci_set_default netshift.settings.update_interval 1d
    uci_set_default netshift.settings.download_lists_via_proxy 0
    uci_set_default netshift.settings.dont_touch_dhcp 0
    uci_set_default netshift.settings.log_level warn
    uci_set_default netshift.settings.exclude_ntp 0
    uci_set_default netshift.settings.shutdown_correctly 0
    uci_set_default netshift.settings.dns_via_outbound 0
    uci_set_default netshift.settings.block_doh 0
    uci_set_default netshift.settings.enable_ipv6 0

    # The boot guard validates exactly this file, so the path is not a taste.
    uci_set_required netshift.settings.config_path /etc/sing-box/config.json
    uci_set_default netshift.settings.cache_path /tmp/sing-box/cache.db
    uci_add_list_once netshift.settings.source_network_interfaces br-lan

    uci_ensure_section netshift.VPN section
    uci_set_required netshift.VPN.connection_type proxy
    uci_set_required netshift.VPN.proxy_config_type subscription
    uci_set_default netshift.VPN.subscription_format_preference xray
    uci_set_default netshift.VPN.subscription_insecure 0
    uci_set_default netshift.VPN.subscription_group_mode off
    uci_set_default netshift.VPN.subscription_update_interval 6h
    uci_set_default netshift.VPN.urltest_check_interval 3m
    uci_set_default netshift.VPN.urltest_tolerance 50
    uci_set_default netshift.VPN.urltest_testing_url \
        https://www.gstatic.com/generate_204
    uci_set_default netshift.VPN.enable_udp_over_tcp 0
    # Route by list, not everything. A global proxy pushes every byte through
    # the subscription - video included - and leaves the router useless the
    # moment the proxy is unhappy. With the list model only what is actually
    # blocked takes the tunnel, everything else goes out directly at full ISP
    # speed, and a dead subscription costs you the blocked sites, not the net.
    uci_set_default netshift.VPN.global_proxy 0
    uci_add_list_once netshift.VPN.community_lists russia_inside
    uci_set_default netshift.VPN.user_domain_list_type disabled
    uci_set_default netshift.VPN.user_subnet_list_type disabled
    uci_set_default netshift.VPN.mixed_proxy_enabled 0
    uci_set_default netshift.VPN.resolve_real_ip_for_routing 0

    subscriptions_file="$TMP_DIR/subscriptions"
    printf '%s\n' "$SUBSCRIPTIONS" > "$subscriptions_file"
    while IFS= read -r subscription_url; do
        [ -n "$subscription_url" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            log 'Была бы добавлена ссылка подписки [REDACTED].'
        elif uci_list_contains netshift.VPN.subscription_url \
            "$subscription_url"; then
            log 'Такая ссылка подписки уже есть, добавлять не нужно.'
        else
            uci add_list \
                "netshift.VPN.subscription_url=$subscription_url"
            CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
        fi
    done < "$subscriptions_file"
    SUBSCRIPTIONS=''

    configure_direct_section
    run uci commit netshift
    report_configuration_diff 'NetShift'
}

# The owner may have renamed or rebuilt the exclusion section - YT_DIRECT
# instead of RU_DIRECT, say. Reuse whichever one already keeps YouTube direct
# rather than creating a second, competing exclusion.
find_exclusion_section() {
    for candidate in $(uci show netshift 2>/dev/null | \
        sed -n 's/^netshift\.\([^.=]*\)=section$/\1/p'); do
        [ "$(uci_value "netshift.$candidate.connection_type")" = exclusion ] || \
            continue

        if uci_list_contains "netshift.$candidate.local_domain_lists" \
            "$YOUTUBE_LIST" || \
            uci_list_contains "netshift.$candidate.community_lists" youtube; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# The upstream "youtube" community list bundles the control plane with the CDN:
# its API hosts sit right next to googlevideo.com. Providers block those API
# hosts much harder, and a blocked API means the page loads while playback never
# starts. Earlier versions added this list here, so a re-run must take it out.
drop_youtube_community_list() {
    section=$1

    uci_list_contains "netshift.$section.community_lists" youtube || return 0

    if [ "$DRY_RUN" -eq 1 ]; then
        log "Из $section был бы убран community-список youtube."
        return 0
    fi

    uci -q del_list "netshift.$section.community_lists=youtube" 2>/dev/null || \
        return 0
    warn "Из $section убран community-список youtube: он уводил API YouTube"
    warn 'на прямой маршрут, где провайдер его блокирует.'
    CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
}

configure_direct_section() {
    existing=$(find_exclusion_section || printf '')

    if [ -n "$existing" ]; then
        log "Секция прямого маршрута уже есть: $existing. Дополняю, не переписываю."
        drop_youtube_community_list "$existing"
        uci_add_list_once "netshift.$existing.local_domain_lists" \
            "$YOUTUBE_LIST"
        return 0
    fi

    # An exclusion wins over the proxy lists, and it is needed for exactly one
    # reason: russia_inside carries YouTube, so without this the video CDN
    # would ride the subscription. Russian sites need no exclusion here - with
    # the list model nothing is proxied unless a list asks for it.
    uci_ensure_section netshift.YT_DIRECT section
    uci_set_required netshift.YT_DIRECT.connection_type exclusion
    uci_set_default netshift.YT_DIRECT.global_proxy 0
    uci_set_default netshift.YT_DIRECT.user_domain_list_type disabled
    uci_set_default netshift.YT_DIRECT.user_subnet_list_type disabled
    uci_add_list_once netshift.YT_DIRECT.local_domain_lists "$YOUTUBE_LIST"
}

# Which domains get a FakeIP depends entirely on the routing topology: with a
# global proxy NetShift marks everything in nftables and hands FakeIP only to
# the excluded lists, so demanding a 198.18.x answer for a chosen domain fails
# on a perfectly healthy router. What always holds is that sing-box answers DNS
# at all once it is up, so that is the readiness signal.
RESOLVER_PROBE_DOMAINS='example.com openwrt.org cloudflare.com'

resolver_answers() {
    for probe_domain in $RESOLVER_PROBE_DOMAINS; do
        if nslookup "$probe_domain" 127.0.0.42 2>/dev/null | \
            grep -Eq '^Address: *[0-9]'; then
            return 0
        fi
    done

    return 1
}

start_and_validate_netshift() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log 'NetShift не запускался в dry-run.'
        return 0
    fi

    # Without a subscription NetShift has no proxy outbound. Starting it would
    # point dnsmasq at a resolver that answers nothing and take the LAN offline,
    # so leave it stopped until a subscription appears.
    if [ "$SUBSCRIPTION_COUNT" -eq 0 ]; then
        log 'Подписки нет, NetShift не запускается.'
        log 'Добавьте подписку в LuCI и запустите скрипт повторно.'
        return 0
    fi

    wait_for_wan 120 || \
        fatal 'За 120 секунд не появился default-маршрут. Проверьте аплинк.'
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
            resolver_answers; then
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

# NetShift routes IPv4 only. A LAN that still advertises IPv6 hands every client
# a global address the client cannot actually use: the router itself reaches the
# IPv6 internet, the clients do not, because nothing forwards or proxies it.
# Applications see an IPv6 address on the interface, try IPv6 first per Happy
# Eyeballs, wait out the timeout and only then fall back to IPv4. The owner sees
# apps that hang for a few seconds at random - Telegram and Instagram worst of
# all, since they reopen long-lived connections most often.
lan_advertises_ipv6() {
    case "$(uci_value dhcp.lan.ra)" in
        ''|disabled) : ;;
        *) return 0 ;;
    esac

    case "$(uci_value dhcp.lan.dhcpv6)" in
        ''|disabled) : ;;
        *) return 0 ;;
    esac

    [ -n "$(uci_value network.lan.ip6assign)" ]
}

configure_ipv6_advertisement() {
    [ "$(uci_value netshift.settings.enable_ipv6)" = 0 ] || return 0
    lan_advertises_ipv6 || return 0

    printf '\n'
    log 'Роутер раздаёт клиентам IPv6, а NetShift маршрутизирует только IPv4.'
    log 'Устройства получают адрес, которым не могут пользоваться: приложения'
    log 'пробуют IPv6 первым, ждут таймаут и только потом переходят на IPv4.'
    log 'Выглядит это как случайные подвисания Telegram и подобных сервисов.'

    ask_yes_no 'Перестать раздавать IPv6 клиентам?' yes || {
        log 'IPv6 оставлен как есть.'
        return 0
    }

    uci_set_required dhcp.lan.ra disabled
    uci_set_required dhcp.lan.dhcpv6 disabled
    uci_delete dhcp.lan.ra_flags
    uci_delete dhcp.lan.ra_slaac
    uci_delete network.lan.ip6assign
    run uci commit dhcp
    run uci commit network

    if [ "$DRY_RUN" -eq 0 ]; then
        /etc/init.d/odhcpd restart >/dev/null 2>&1 || \
            warn 'odhcpd не перезапустился, анонсы прекратятся после перезагрузки.'
    fi

    log 'Анонсы IPv6 выключены. Выданные ранее адреса отпадут у клиентов сами.'
}
