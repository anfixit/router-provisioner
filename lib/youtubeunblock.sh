#!/bin/sh
# youtubeUnblock installation and configuration. Sourced by lib/main.sh.
#
# youtubeUnblock is a DPI-bypass daemon for the YouTube/Google domains that
# stay on the DIRECT route. It complements NetShift instead of replacing it:
# NetShift keeps those domains out of the proxy (see DIRECT_LIST), and
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
    if [ -z "$latest" ]; then
        warn 'Не удалось определить последний релиз youtubeUnblock.'
        return 1
    fi
    version=${latest#v}

    installed=$(youtubeunblock_installed_version)
    [ -n "$installed" ] && log "Установленный youtubeUnblock: $installed"
    log "Последний релиз youtubeUnblock: $version"

    if [ -n "$installed" ] && version_ge "$installed" "$version"; then
        log 'youtubeUnblock уже последней версии.'
        return 0
    fi

    architecture=$(release_value DISTRIB_ARCH)
    if [ -z "$architecture" ]; then
        warn 'Не удалось определить архитектуру для youtubeUnblock.'
        return 1
    fi

    case "$(package_manager)" in
        apk) extension='apk' ;;
        opkg) extension='ipk' ;;
        *) warn 'Не найден пакетный менеджер.'; return 1 ;;
    esac

    daemon_url=$(github_asset_url "$YOUTUBEUNBLOCK_REPOSITORY" "$latest" \
        "/youtubeUnblock-[^/]*-${architecture}-openwrt-[^/]*\\.${extension}\$") || {
        warn "Нет сборки youtubeUnblock $version для ${architecture} (${extension})."
        return 1
    }

    luci_url=$(github_asset_url "$YOUTUBEUNBLOCK_REPOSITORY" "$latest" \
        "/luci-app-youtubeUnblock-[^/]*\\.${extension}\$" || true)

    if [ "$DRY_RUN" -eq 1 ]; then
        log "Был бы установлен youtubeUnblock $version для $architecture."
        [ -n "$luci_url" ] && log 'Был бы установлен luci-app-youtubeUnblock.'
        return 0
    fi

    install_youtubeunblock_dependencies

    if ! install_youtubeunblock_package "$daemon_url"; then
        warn 'Установка youtubeUnblock завершилась ошибкой.'
        return 1
    fi

    if [ -n "$luci_url" ]; then
        install_youtubeunblock_package "$luci_url" || \
            warn 'Не удалось установить luci-app-youtubeUnblock.'
    else
        warn "В релизе $version нет luci-app-youtubeUnblock.${extension}."
    fi

    if [ ! -x "$YOUTUBEUNBLOCK_SERVICE" ]; then
        warn 'youtubeUnblock установлен не полностью.'
        return 1
    fi
}

# Keep the first section and drop the rest: duplicates make the daemon bind the
# same nfqueue twice, but the first one carries whatever the owner configured.
remove_extra_youtubeunblock_sections() {
    guard=0
    while [ "$guard" -lt 64 ]; do
        [ -n "$(uci_value 'youtubeUnblock.@section[1]')" ] || break
        uci -q delete 'youtubeUnblock.@section[1]' 2>/dev/null || break
        warn 'Удалена дублирующая секция youtubeUnblock.'
        CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
        guard=$((guard + 1))
    done
}

configure_youtubeunblock() {
    CONFIG_KEPT=0
    CONFIG_CHANGED=0

    if [ "$DRY_RUN" -eq 1 ]; then
        log 'Секция youtubeUnblock была бы создана или дополнена.'
        section='@section[0]'
    else
        [ -f "$YOUTUBEUNBLOCK_CONFIG" ] || touch "$YOUTUBEUNBLOCK_CONFIG"

        # Reuse the section the package's own uci-defaults created, or the one
        # a previous run left behind. Recreating it would discard whatever the
        # owner tuned in LuCI; duplicates would bind the same queue twice.
        if [ -n "$(uci_value 'youtubeUnblock.@section[0]')" ]; then
            section='@section[0]'
            log 'Секция youtubeUnblock уже есть, дополняю её.'
            remove_extra_youtubeunblock_sections
        else
            section=$(uci add youtubeUnblock section) || {
                warn 'Не удалось создать секцию youtubeUnblock.'
                return 1
            }
            CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
        fi
    fi

    # Queue number and packet mark must match the nftables rule the package
    # installs, so those are enforced. The rest are tuning knobs: apply them
    # as defaults so a hand-tuned strategy survives a re-run.
    uci_ensure_section youtubeUnblock.youtubeUnblock youtubeUnblock
    uci_set_required youtubeUnblock.youtubeUnblock.conf_strat ui_flags
    uci_set_required youtubeUnblock.youtubeUnblock.packet_mark \
        "$YOUTUBEUNBLOCK_PACKET_MARK"
    uci_set_required youtubeUnblock.youtubeUnblock.queue_num \
        "$YOUTUBEUNBLOCK_QUEUE_NUM"

    uci_set_default "youtubeUnblock.$section.name" 'Default section'
    uci_set_required "youtubeUnblock.$section.enabled" 1
    uci_set_default "youtubeUnblock.$section.tls_enabled" 1
    uci_set_default "youtubeUnblock.$section.fake_sni" 0
    uci_set_default "youtubeUnblock.$section.faking_strategy" pastseq
    uci_set_default "youtubeUnblock.$section.fake_sni_seq_len" 1
    uci_set_default "youtubeUnblock.$section.fake_sni_type" default
    uci_set_default "youtubeUnblock.$section.frag" tcp
    uci_set_default "youtubeUnblock.$section.frag_sni_reverse" 1
    uci_set_default "youtubeUnblock.$section.frag_sni_faked" 0
    uci_set_default "youtubeUnblock.$section.frag_middle_sni" 1
    uci_set_default "youtubeUnblock.$section.frag_sni_pos" 1
    uci_set_default "youtubeUnblock.$section.seg2delay" 0
    uci_set_default "youtubeUnblock.$section.fk_winsize" 0
    uci_set_default "youtubeUnblock.$section.synfake" 0
    uci_set_default "youtubeUnblock.$section.sni_detection" parse
    uci_set_default "youtubeUnblock.$section.all_domains" 0

    # Domains are added, never replaced: the owner may have appended their own.
    printf '%s\n' "$YOUTUBEUNBLOCK_SNI_DOMAINS" | \
        while IFS= read -r sni_domain; do
            [ -n "$sni_domain" ] || continue
            uci_add_list_once "youtubeUnblock.$section.sni_domains" \
                "$sni_domain"
        done

    uci_set_default "youtubeUnblock.$section.quic_drop" 0
    uci_set_default "youtubeUnblock.$section.udp_mode" drop
    uci_set_default "youtubeUnblock.$section.udp_fake_seq_len" 6
    uci_set_default "youtubeUnblock.$section.udp_fake_len" 64
    uci_set_default "youtubeUnblock.$section.udp_filter_quic" parse
    uci_set_default "youtubeUnblock.$section.udp_faking_strategy" none

    run uci commit youtubeUnblock
    report_configuration_diff 'youtubeUnblock'
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
