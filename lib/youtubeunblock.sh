#!/bin/sh
# youtubeUnblock installation and configuration. Sourced by lib/main.sh.
#
# youtubeUnblock is a DPI-bypass daemon for the YouTube/Google domains that
# stay on the DIRECT route. It complements NetShift instead of replacing it:
# NetShift keeps those domains out of the proxy (see YOUTUBE_LIST), and
# youtubeUnblock repairs the TLS handshake for them on the direct path.

YOUTUBEUNBLOCK_REPOSITORY='Waujito/youtubeUnblock'
YOUTUBEUNBLOCK_CONFIG='/etc/config/youtubeUnblock'
YOUTUBEUNBLOCK_SERVICE='/etc/init.d/youtubeUnblock'
YOUTUBEUNBLOCK_QUEUE_NUM=537
YOUTUBEUNBLOCK_PACKET_MARK=32768

# SNI domains that youtubeUnblock rewrites. Mirrors the reference router.
YOUTUBEUNBLOCK_SNI_DOMAINS='googlevideo.com
ggpht.com
ytimg.com
youtube.com
play.google.com
youtu.be
googleapis.com
googleusercontent.com
gstatic.com
l.google.com'

youtubeunblock_installed_version() {
    case "$(package_manager)" in
        apk)
            apk list --installed 2>/dev/null | \
                sed -n 's/^youtubeUnblock-\([0-9][^ ]*\).*/\1/p' | head -n 1
            ;;
        opkg)
            opkg list-installed 2>/dev/null | \
                sed -n 's/^youtubeUnblock - \([^ ]*\).*/\1/p' | head -n 1
            ;;
    esac
}

install_youtubeunblock_dependencies() {
    # nftables builds need the userspace queue module. Some images ship it
    # built in, so a failure here is reported but never fatal.
    case "$(package_manager)" in
        apk)
            run apk add kmod-nfnetlink-queue kmod-nft-queue || \
                warn 'Не удалось установить kmod-nfnetlink-queue/kmod-nft-queue.'
            ;;
        opkg)
            run opkg install kmod-nfnetlink-queue kmod-nft-queue || \
                warn 'Не удалось установить kmod-nfnetlink-queue/kmod-nft-queue.'
            ;;
    esac
}

install_youtubeunblock_package() {
    package_url=$1
    package_file="$TMP_DIR/$(basename "$package_url")"

    fetch_to_file "$package_url" "$package_file" || return 1
    [ -s "$package_file" ] || return 1

    case "$(package_manager)" in
        apk)
            apk add --allow-untrusted "$package_file"
            ;;
        opkg)
            opkg install --force-reinstall --force-downgrade "$package_file"
            ;;
        *)
            return 1
            ;;
    esac
}

install_youtubeunblock() {
    latest=$(github_latest_tag "$YOUTUBEUNBLOCK_REPOSITORY" || true)
    [ -n "$latest" ] || \
        fatal 'Не удалось определить последний релиз youtubeUnblock.'
    version=${latest#v}

    installed=$(youtubeunblock_installed_version)
    [ -n "$installed" ] && log "Установленный youtubeUnblock: $installed"
    log "Последний релиз youtubeUnblock: $version"

    if [ -n "$installed" ] && version_ge "$installed" "$version"; then
        log 'youtubeUnblock уже последней версии.'
        return 0
    fi

    architecture=$(release_value DISTRIB_ARCH)
    [ -n "$architecture" ] || \
        fatal 'Не удалось определить архитектуру для youtubeUnblock.'

    case "$(package_manager)" in
        apk) extension='apk' ;;
        opkg) extension='ipk' ;;
        *) fatal 'Не найден пакетный менеджер.' ;;
    esac

    daemon_url=$(github_asset_url "$YOUTUBEUNBLOCK_REPOSITORY" "$latest" \
        "/youtubeUnblock-[^/]*-${architecture}-openwrt-[^/]*\\.${extension}\$") || \
        fatal "Нет сборки youtubeUnblock $version для ${architecture} (${extension})."

    luci_url=$(github_asset_url "$YOUTUBEUNBLOCK_REPOSITORY" "$latest" \
        "/luci-app-youtubeUnblock-[^/]*\\.${extension}\$" || true)

    if [ "$DRY_RUN" -eq 1 ]; then
        log "Был бы установлен youtubeUnblock $version для $architecture."
        [ -n "$luci_url" ] && log 'Был бы установлен luci-app-youtubeUnblock.'
        return 0
    fi

    install_youtubeunblock_dependencies

    install_youtubeunblock_package "$daemon_url" || \
        fatal 'Установка youtubeUnblock завершилась ошибкой.'

    if [ -n "$luci_url" ]; then
        install_youtubeunblock_package "$luci_url" || \
            warn 'Не удалось установить luci-app-youtubeUnblock.'
    else
        warn "В релизе $version нет luci-app-youtubeUnblock.${extension}."
    fi

    [ -x "$YOUTUBEUNBLOCK_SERVICE" ] || \
        fatal 'youtubeUnblock установлен не полностью.'
}

remove_youtubeunblock_sections() {
    # Anonymous sections accumulate on every re-run, and duplicates make the
    # daemon bind the same queue twice. Delete index 0 until none are left.
    guard=0
    while [ "$guard" -lt 64 ]; do
        uci -q delete youtubeUnblock.@section[0] 2>/dev/null || break
        guard=$((guard + 1))
    done
}

configure_youtubeunblock() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log 'Секции youtubeUnblock были бы пересозданы.'
        section='@section[0]'
    else
        [ -f "$YOUTUBEUNBLOCK_CONFIG" ] || touch "$YOUTUBEUNBLOCK_CONFIG"
        remove_youtubeunblock_sections
        section=$(uci add youtubeUnblock section) || \
            fatal 'Не удалось создать секцию youtubeUnblock.'
    fi

    run uci set 'youtubeUnblock.youtubeUnblock=youtubeUnblock'
    run uci set 'youtubeUnblock.youtubeUnblock.conf_strat=ui_flags'
    run uci set \
        "youtubeUnblock.youtubeUnblock.packet_mark=$YOUTUBEUNBLOCK_PACKET_MARK"
    run uci set \
        "youtubeUnblock.youtubeUnblock.queue_num=$YOUTUBEUNBLOCK_QUEUE_NUM"

    run uci set "youtubeUnblock.$section.name=Default section"
    run uci set "youtubeUnblock.$section.enabled=1"
    run uci set "youtubeUnblock.$section.tls_enabled=1"
    run uci set "youtubeUnblock.$section.fake_sni=0"
    run uci set "youtubeUnblock.$section.faking_strategy=pastseq"
    run uci set "youtubeUnblock.$section.fake_sni_seq_len=1"
    run uci set "youtubeUnblock.$section.fake_sni_type=default"
    run uci set "youtubeUnblock.$section.frag=tcp"
    run uci set "youtubeUnblock.$section.frag_sni_reverse=1"
    run uci set "youtubeUnblock.$section.frag_sni_faked=0"
    run uci set "youtubeUnblock.$section.frag_middle_sni=1"
    run uci set "youtubeUnblock.$section.frag_sni_pos=1"
    run uci set "youtubeUnblock.$section.seg2delay=0"
    run uci set "youtubeUnblock.$section.fk_winsize=0"
    run uci set "youtubeUnblock.$section.synfake=0"
    run uci set "youtubeUnblock.$section.sni_detection=parse"
    run uci set "youtubeUnblock.$section.all_domains=0"

    uci_delete "youtubeUnblock.$section.sni_domains"
    printf '%s\n' "$YOUTUBEUNBLOCK_SNI_DOMAINS" | \
        while IFS= read -r sni_domain; do
            [ -n "$sni_domain" ] || continue
            run uci add_list \
                "youtubeUnblock.$section.sni_domains=$sni_domain"
        done

    run uci set "youtubeUnblock.$section.quic_drop=0"
    run uci set "youtubeUnblock.$section.udp_mode=drop"
    run uci set "youtubeUnblock.$section.udp_fake_seq_len=6"
    run uci set "youtubeUnblock.$section.udp_fake_len=64"
    run uci set "youtubeUnblock.$section.udp_filter_quic=parse"
    run uci set "youtubeUnblock.$section.udp_faking_strategy=none"

    run uci commit youtubeUnblock
}

start_youtubeunblock() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log 'youtubeUnblock был бы включён и перезапущен.'
        return 0
    fi

    "$YOUTUBEUNBLOCK_SERVICE" enable >/dev/null 2>&1 || \
        warn 'Не удалось включить автозапуск youtubeUnblock.'
    "$YOUTUBEUNBLOCK_SERVICE" restart >/dev/null 2>&1 || \
        warn 'Не удалось запустить youtubeUnblock.'

    # The package ships /usr/share/nftables.d/.../537-youtubeUnblock.nft, so
    # the nfqueue rule only lands after firewall4 regenerates its ruleset.
    /etc/init.d/firewall reload >/dev/null 2>&1 || \
        warn 'Не удалось перезагрузить firewall для youtubeUnblock.'

    if pgrep -f '[y]outubeUnblock' >/dev/null 2>&1; then
        log 'youtubeUnblock работает.'
    else
        warn 'Процесс youtubeUnblock не обнаружен, проверьте logread.'
    fi
}
