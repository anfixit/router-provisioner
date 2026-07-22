#!/bin/sh
# NetShift installation, configuration and guarded lifecycle.

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

install_netshift() {
    if [ -x /usr/bin/netshift ] && [ -x /etc/init.d/netshift ]; then
        log 'NetShift уже установлен.'
        return 0
    fi

    installer="$TMP_DIR/netshift-install.sh"
    fetch_to_file "$NETSHIFT_INSTALLER" "$installer" || \
        fatal 'Не удалось скачать официальный установщик NetShift.'

    if [ "$DRY_RUN" -eq 1 ]; then
        log 'Официальный установщик NetShift был бы запущен.'
        return 0
    fi

    sh "$installer" || fatal 'Установка NetShift завершилась ошибкой.'
    [ -x /usr/bin/netshift ] && [ -x /etc/init.d/netshift ] || \
        fatal 'NetShift установлен не полностью.'
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
    run uci set 'netshift.settings.dns_type=udp'
    run uci set 'netshift.settings.dns_server=1.1.1.1'
    run uci set 'netshift.settings.bootstrap_dns_server=77.88.8.8'
    run uci set 'netshift.settings.global_proxy=1'
    run uci set 'netshift.settings.enable_ipv6=0'
    run uci set 'netshift.settings.download_lists_via_proxy=0'
    uci_delete netshift.settings.source_network_interfaces
    run uci add_list \
        'netshift.settings.source_network_interfaces=br-lan'

    run uci set 'netshift.VPN=section'
    run uci set 'netshift.VPN.connection_type=proxy'
    run uci set 'netshift.VPN.proxy_config_type=subscription'
    run uci set 'netshift.VPN.subscription_format_preference=xray'
    run uci set 'netshift.VPN.subscription_allow_insecure=0'
    run uci set 'netshift.VPN.subscription_group_mode=off'
    run uci set 'netshift.VPN.subscription_update_interval=disabled'
    run uci set 'netshift.VPN.urltest_check_interval=3m'
    run uci set 'netshift.VPN.urltest_tolerance=50'
    run uci set \
        'netshift.VPN.urltest_testing_url=https://www.gstatic.com/generate_204'
    run uci set 'netshift.VPN.global_proxy=1'
    run uci set 'netshift.VPN.user_domain_list_type=disabled'
    run uci set 'netshift.VPN.user_subnet_list_type=disabled'
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

install_boot_guard() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Были бы установлены $BOOT_HELPER и $BOOT_SERVICE"
        return 0
    fi

    cat > "$BOOT_HELPER" <<'EOF_BOOT_HELPER'
#!/bin/ash
set -u
TAG='router-provisioner-boot'
RULESET_URL='https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_outside.srs'
LOCK='/tmp/router-provisioner-netshift-start.lock'
PREFLIGHT='/tmp/russia_outside.preflight.srs'

log() { logger -t "$TAG" "$*"; }
cleanup() {
    rmdir "$LOCK" 2>/dev/null || true
    rm -f "$PREFLIGHT"
}
trap cleanup 0 HUP INT TERM
mkdir "$LOCK" 2>/dev/null || {
    log 'another startup is already running'
    exit 0
}

elapsed=0
while [ "$elapsed" -lt 120 ]; do
    if ubus call network.interface.wan status 2>/dev/null | \
        grep -q '"up"[[:space:]]*:[[:space:]]*true' && \
        ip route show default 2>/dev/null | grep -q '^default '; then
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

[ "$elapsed" -lt 120 ] || {
    log 'WAN was not ready after 120 seconds'
    exit 1
}

if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O "$PREFLIGHT" "$RULESET_URL" || {
        log 'ruleset preflight failed'
        exit 1
    }
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$PREFLIGHT" "$RULESET_URL" || {
        log 'ruleset preflight failed'
        exit 1
    }
else
    log 'no downloader available for ruleset preflight'
    exit 1
fi

[ -s "$PREFLIGHT" ] || {
    log 'ruleset preflight returned an empty file'
    exit 1
}

ready() {
    pgrep -f '[s]ing-box run' >/dev/null 2>&1 || return 1
    /usr/bin/sing-box check -c /etc/sing-box/config.json \
        >/dev/null 2>&1 || return 1
    nslookup www.gstatic.com 127.0.0.42 2>/dev/null | \
        grep -Eq '198\.18\.'
}

attempt_start() {
    /etc/init.d/netshift stop >/dev/null 2>&1 || true
    /etc/init.d/netshift start >/dev/null 2>&1 || true
    count=0
    while [ "$count" -lt 45 ]; do
        ready && return 0
        sleep 2
        count=$((count + 1))
    done
    return 1
}

if attempt_start; then
    log 'NetShift is ready'
    exit 0
fi

log 'first start failed; retrying once'
if attempt_start; then
    log 'NetShift recovered on the second attempt'
    exit 0
fi

log 'NetShift failed twice; stopping it to restore ordinary DNS and routing'
/etc/init.d/netshift stop >/dev/null 2>&1 || true
exit 1
EOF_BOOT_HELPER
    chmod 700 "$BOOT_HELPER"

    cat > "$BOOT_SERVICE" <<'EOF_BOOT_SERVICE'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/router-provisioner-netshift-start
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    /etc/init.d/netshift stop >/dev/null 2>&1 || true
}
EOF_BOOT_SERVICE
    chmod 755 "$BOOT_SERVICE"

    /etc/init.d/netshift stop >/dev/null 2>&1 || true
    /etc/init.d/netshift disable >/dev/null 2>&1 || true
    "$BOOT_SERVICE" enable
}

install_refresh_helper() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Был бы установлен $REFRESH_HELPER"
        return 0
    fi

    cat > "$REFRESH_HELPER" <<'EOF_REFRESH'
#!/bin/ash
set -u
TAG='router-provisioner-refresh'
BACKUP="/tmp/router-provisioner-refresh.$$"

log() { logger -t "$TAG" "$*"; }
cleanup() { rm -rf "$BACKUP"; }
trap cleanup 0 HUP INT TERM
mkdir -p "$BACKUP"

[ -d /etc/netshift/subscriptions ] && \
    cp -a /etc/netshift/subscriptions "$BACKUP/"
[ -f /etc/sing-box/config.json ] && \
    cp -p /etc/sing-box/config.json "$BACKUP/config.json"

/usr/bin/netshift subscription_update >/dev/null 2>&1 || true
count=0
while [ "$count" -lt 45 ]; do
    if pgrep -f '[s]ing-box run' >/dev/null 2>&1 && \
        /usr/bin/sing-box check -c /etc/sing-box/config.json \
            >/dev/null 2>&1 && \
        nslookup www.gstatic.com 127.0.0.42 2>/dev/null | \
            grep -Eq '198\.18\.'; then
        log 'subscription refresh succeeded'
        exit 0
    fi
    sleep 2
    count=$((count + 1))
done

log 'subscription refresh failed; restoring previous cache'
rm -rf /etc/netshift/subscriptions
[ -d "$BACKUP/subscriptions" ] && \
    cp -a "$BACKUP/subscriptions" /etc/netshift/subscriptions
[ -f "$BACKUP/config.json" ] && \
    cp -p "$BACKUP/config.json" /etc/sing-box/config.json
/etc/init.d/netshift restart >/dev/null 2>&1 || true
exit 1
EOF_REFRESH
    chmod 700 "$REFRESH_HELPER"

    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    temporary="/tmp/router-provisioner-cron.$$"
    grep -v 'router-provisioner-netshift-refresh' \
        /etc/crontabs/root > "$temporary" || true
    {
        cat "$temporary"
        printf '17 * * * * %s\n' "$REFRESH_HELPER"
    } > /etc/crontabs/root
    rm -f "$temporary"
    chmod 600 /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || true
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
