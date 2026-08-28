#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_COUNT=0

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equal() {
    expected=$1
    actual=$2
    message=$3
    TEST_COUNT=$((TEST_COUNT + 1))
    [ "$expected" = "$actual" ] || \
        fail_test "$message: expected=$expected actual=$actual"
}

assert_contains() {
    text=$1
    expected=$2
    message=$3
    TEST_COUNT=$((TEST_COUNT + 1))
    printf '%s' "$text" | grep -F "$expected" >/dev/null || \
        fail_test "$message"
}

assert_not_contains() {
    text=$1
    unexpected=$2
    message=$3
    TEST_COUNT=$((TEST_COUNT + 1))
    if printf '%s' "$text" | grep -F "$unexpected" >/dev/null; then
        fail_test "$message"
    fi
}

assert_true() {
    message=$1
    shift
    TEST_COUNT=$((TEST_COUNT + 1))
    "$@" || fail_test "$message"
}

assert_false() {
    message=$1
    shift
    TEST_COUNT=$((TEST_COUNT + 1))
    if "$@"; then
        fail_test "$message"
    fi
}

PROGRAM='router-provisioner'
VERSION='2.9.0'
DRY_RUN=0
ASSUME_YES=0
DIAGNOSE_ONLY=0
TMP_DIR=''
CONFIG_BACKUP=''

# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"
# shellcheck source=../lib/system.sh
. "$PROJECT_DIR/lib/system.sh"
# shellcheck source=../lib/netshift.sh
. "$PROJECT_DIR/lib/netshift.sh"
# shellcheck source=../lib/youtubeunblock.sh
. "$PROJECT_DIR/lib/youtubeunblock.sh"
# shellcheck source=../lib/adblock.sh
. "$PROJECT_DIR/lib/adblock.sh"
# shellcheck source=../lib/pinning.sh
. "$PROJECT_DIR/lib/pinning.sh"
# shellcheck source=../lib/lifecycle.sh
. "$PROJECT_DIR/lib/lifecycle.sh"

test_version_comparison() {
    assert_true 'newer OpenWrt must pass' \
        version_ge '25.12.5' '24.10.0'
    assert_true 'equal version must pass' \
        version_ge '24.10.0' '24.10.0'
    assert_false 'older OpenWrt must fail' \
        version_ge '23.05.5' '24.10.0'
}

test_public_key_validation() {
    assert_true 'ed25519 key must pass' \
        valid_public_key 'ssh-ed25519 AAAAC3Nza example'
    assert_false 'private key must fail' \
        valid_public_key '-----BEGIN OPENSSH PRIVATE KEY-----'
}

test_fetcher_selection() {
    fixture=$(mktemp -d)
    mkdir -p "$fixture/bin"
    cat > "$fixture/bin/uclient-fetch" <<'EOF_FETCH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-O' ]; then
        destination=$2
        break
    fi
    shift
done
printf 'ok' > "$destination"
EOF_FETCH
    chmod +x "$fixture/bin/uclient-fetch"

    PATH="$fixture/bin:$PATH" \
        fetch_to_file 'https://example.test/file' "$fixture/result"
    assert_equal 'ok' "$(cat "$fixture/result")" \
        'uclient-fetch invocation is incorrect'
    rm -rf "$fixture"
}

test_fetcher_prefers_ipv4_then_falls_back() {
    fixture=$(mktemp -d)
    mkdir -p "$fixture/bin"

    # Records every invocation and fails the -4 attempt, the way a router
    # without an IPv6 route fails the AAAA connection with EPERM.
    cat > "$fixture/bin/uclient-fetch" <<'EOF_FETCH'
#!/bin/sh
forced=0
destination=''
for argument in "$@"; do
    [ "$argument" = '-4' ] && forced=1
done
printf '%s\n' "$forced" >> "$FETCH_LOG"
[ "$forced" -eq 1 ] && exit 1
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-O' ]; then
        destination=$2
        break
    fi
    shift
done
printf 'fallback' > "$destination"
EOF_FETCH
    chmod +x "$fixture/bin/uclient-fetch"

    FETCH_LOG="$fixture/log"
    export FETCH_LOG
    : > "$FETCH_LOG"

    PATH="$fixture/bin:$PATH" \
        fetch_to_file 'https://example.test/file' "$fixture/result"

    assert_equal '1' "$(head -n 1 "$FETCH_LOG")" \
        'IPv4 must be forced on the first attempt'
    assert_equal '0' "$(sed -n '2p' "$FETCH_LOG")" \
        'a failed IPv4 attempt must fall back to the unforced call'
    assert_equal 'fallback' "$(cat "$fixture/result")" \
        'the fallback attempt must still produce the file'

    unset FETCH_LOG
    rm -rf "$fixture"
}

test_uplink_detection_is_interface_agnostic() {
    fixture=$(mktemp -d)
    mkdir -p "$fixture/bin"

    # A Wi-Fi client uplink: the device is phy1-sta0, not "wan". This is the
    # layout that made the hardcoded wan check time out on a real router.
    cat > "$fixture/bin/ip" <<'EOF_IP'
#!/bin/sh
printf 'default via 192.168.1.1 dev phy1-sta0  src 192.168.1.144 \n'
printf '192.168.1.0/24 dev br-lan scope link  src 10.65.77.1 \n'
EOF_IP
    chmod +x "$fixture/bin/ip"

    assert_equal 'phy1-sta0' \
        "$(PATH="$fixture/bin:$PATH" default_route_device)" \
        'the default route device must be detected for a Wi-Fi client uplink'

    PATH="$fixture/bin:$PATH" assert_true 'wait_for_wan must accept any uplink' \
        wait_for_wan 2

    cat > "$fixture/bin/ip" <<'EOF_IP_EMPTY'
#!/bin/sh
exit 0
EOF_IP_EMPTY
    chmod +x "$fixture/bin/ip"

    assert_equal '' "$(PATH="$fixture/bin:$PATH" default_route_device)" \
        'no default route must yield an empty device'

    rm -rf "$fixture"
}

test_dry_run_redacts_subscriptions() {
    fixture=$(mktemp -d)
    TMP_DIR=$fixture
    DIRECT_LIST="$fixture/direct.lst"
    DRY_RUN=1
    ASSUME_YES=1

    uci() {
        return 0
    }

    secret='https://example.test/private-token'
    output=$(printf '%s\n' "$secret" | configure_netshift 2>&1)

    assert_not_contains "$output" "$secret" \
        'subscription URL leaked into output'
    assert_contains "$output" '[REDACTED]' \
        'redacted subscription marker is missing'

    unset -f uci 2>/dev/null || true
    DRY_RUN=0
    ASSUME_YES=0
    TMP_DIR=''
    rm -rf "$fixture"
}

test_guarded_boot_contract() {
    source=$(cat "$PROJECT_DIR/runtime/router-provisioner-netshift-start")
    lifecycle=$(cat "$PROJECT_DIR/lib/lifecycle.sh")

    assert_contains "$source" 'uplink not reachable after 240 seconds' \
        'uplink readiness timeout is missing'
    assert_not_contains "$source" 'network.interface.wan' \
        'the uplink must not be hardcoded to an interface named wan'
    # A default route can point at the LAN bridge seconds into boot, so
    # readiness must be proven by an actual download, not by the route alone.
    assert_contains "$source" 'verifying reachability' \
        'a bare default route must not be trusted as a ready uplink'
    assert_contains "$source" 'ping -c 1 -W 2' \
        'reachability must be proved against a literal address'
    # A stop after list_update wipes /tmp/sing-box/rulesets, and the next
    # start skips regenerating them on an unchanged config hash.
    assert_not_contains "$source" 'prepare_lists' \
        'the extra stop/list_update dance destroys the local rule-set files'
    assert_contains "$source" 'first start failed; retrying once' \
        'bounded second attempt is missing'
    assert_contains "$source" \
        'stopping it to restore ordinary DNS and routing' \
        'fail-open cleanup is missing'
    assert_contains "$lifecycle" '/etc/init.d/netshift disable' \
        'native NetShift boot must be disabled'
    assert_contains "$lifecycle" 'START=99' \
        'guard service must start after ordinary network services'
    # NetShift's own subscription cron lands on :17 for every interval it
    # offers; two updaters rewriting the same cache collide there.
    assert_not_contains "$lifecycle" "printf '17 * * * * " \
        'the refresh cron must not share a minute with NetShift own updater'
}

test_refresh_contract() {
    source=$(cat "$PROJECT_DIR/runtime/router-provisioner-netshift-refresh")

    assert_contains "$source" 'cp -a /etc/netshift/subscriptions' \
        'refresh must back up subscription cache'
    assert_contains "$source" 'restoring previous cache' \
        'refresh rollback is missing'
    assert_contains "$source" 'service remains stopped' \
        'failed rollback must leave a safe stopped state'
}

test_launcher_preserves_interactive_stdin() {
    source=$(cat "$PROJECT_DIR/router-provisioner.sh")

    assert_contains "$source" 'Не используйте curl | sh.' \
        'launcher must explain why pipe execution is unsupported'
    assert_contains "$source" \
        'exec /bin/sh "$RUNTIME_DIR/main.sh" "$@"' \
        'launcher must execute the runtime file and forward arguments'
    assert_contains "$source" 'runtime/$helper' \
        'launcher must download lifecycle runtime helpers'
}

test_netshift_upgrades_to_latest() {
    fixture=$(mktemp -d)
    TMP_DIR=$fixture

    netshift_installed_version() {
        printf '%s\n' "$STUB_INSTALLED_VERSION"
    }
    github_latest_tag() {
        printf '%s\n' "$STUB_LATEST_TAG"
    }
    fetch_to_file() {
        printf 'exit 0\n' > "$2"
    }

    STUB_INSTALLED_VERSION='0.9.6'
    STUB_LATEST_TAG='0.9.6'
    output=$(install_netshift 2>&1)
    assert_contains "$output" 'NetShift уже последней версии.' \
        'up-to-date NetShift must not be reinstalled'

    STUB_LATEST_TAG='v0.9.7'
    DRY_RUN=1
    output=$(install_netshift 2>&1)
    assert_contains "$output" 'обновил бы NetShift до 0.9.7' \
        'outdated NetShift must be upgraded to the latest release'
    DRY_RUN=0

    STUB_INSTALLED_VERSION=''
    DRY_RUN=1
    output=$(install_netshift 2>&1)
    assert_contains "$output" 'установщик NetShift был бы запущен' \
        'missing NetShift must be installed'
    DRY_RUN=0

    unset -f netshift_installed_version github_latest_tag fetch_to_file
    TMP_DIR=''
    rm -rf "$fixture"
}

test_github_asset_selection() {
    fixture=$(mktemp -d)
    TMP_DIR=$fixture

    cat > "$fixture/gh-release-$(cache_key 'Waujito/youtubeUnblockv1.3.1').json" \
        <<'EOF_RELEASE'
{"assets":[
{"browser_download_url":"https://example.test/luci-app-youtubeUnblock-1.3.1-1-abc.apk"},
{"browser_download_url":"https://example.test/youtubeUnblock-1.3.1-1-abc-aarch64_generic-openwrt-24.10.ipk"},
{"browser_download_url":"https://example.test/youtubeUnblock-1.3.1-1-abc-aarch64_generic-openwrt-25.12.apk"},
{"browser_download_url":"https://example.test/youtubeUnblock-1.3.1-1-abc-mipsel_24kc-openwrt-25.12.apk"}
]}
EOF_RELEASE

    url=$(github_asset_url 'Waujito/youtubeUnblock' 'v1.3.1' \
        '/youtubeUnblock-[^/]*-aarch64_generic-openwrt-[^/]*\.apk$')
    assert_equal \
        'https://example.test/youtubeUnblock-1.3.1-1-abc-aarch64_generic-openwrt-25.12.apk' \
        "$url" 'apk asset for the running architecture must be selected'

    url=$(github_asset_url 'Waujito/youtubeUnblock' 'v1.3.1' \
        '/youtubeUnblock-[^/]*-aarch64_generic-openwrt-[^/]*\.ipk$')
    assert_equal \
        'https://example.test/youtubeUnblock-1.3.1-1-abc-aarch64_generic-openwrt-24.10.ipk' \
        "$url" 'ipk asset for the running architecture must be selected'

    assert_false 'unknown architecture must not resolve an asset' \
        github_asset_url 'Waujito/youtubeUnblock' 'v1.3.1' \
        '/youtubeUnblock-[^/]*-powerpc_missing-openwrt-[^/]*\.apk$'

    TMP_DIR=''
    rm -rf "$fixture"
}

test_youtubeunblock_matches_reference() {
    DRY_RUN=1

    uci() {
        return 0
    }

    output=$(configure_youtubeunblock 2>&1)

    assert_contains "$output" 'youtubeUnblock.youtubeUnblock.queue_num=537' \
        'nfqueue number must match the reference router'
    assert_contains "$output" \
        'youtubeUnblock.youtubeUnblock.packet_mark=32768' \
        'packet mark must match the reference router'
    assert_contains "$output" 'conf_strat=ui_flags' \
        'configuration strategy must match the reference router'
    assert_contains "$output" 'faking_strategy=pastseq' \
        'faking strategy must match the reference router'
    assert_contains "$output" 'sni_domains=googlevideo.com' \
        'googlevideo.com must be handled by youtubeUnblock'
    assert_contains "$output" 'sni_domains=l.google.com' \
        'the full reference SNI domain list must be written'
    assert_contains "$output" 'udp_filter_quic=parse' \
        'QUIC filtering must match the reference router'

    unset -f uci 2>/dev/null || true
    DRY_RUN=0
}

test_netshift_settings_match_reference() {
    fixture=$(mktemp -d)
    TMP_DIR=$fixture
    DIRECT_LIST="$fixture/direct.lst"
    DRY_RUN=1
    ASSUME_YES=1

    uci() {
        return 0
    }

    output=$(printf 'https://example.test/sub\n' | configure_netshift 2>&1)

    assert_contains "$output" 'netshift.settings.dns_type=doh' \
        'DNS type must match the reference router'
    assert_contains "$output" \
        'netshift.settings.dns_server=dns.adguard-dns.com' \
        'DNS server must match the reference router'
    assert_contains "$output" 'netshift.VPN.subscription_insecure=0' \
        'NetShift only knows subscription_insecure, not the *_allow_* spelling'
    assert_not_contains "$output" 'subscription_allow_insecure' \
        'the unsupported subscription option must be gone'
    assert_not_contains "$output" 'netshift.settings.global_proxy' \
        'global_proxy is a per-section option, not a settings option'

    unset -f uci 2>/dev/null || true
    DRY_RUN=0
    ASSUME_YES=0
    TMP_DIR=''
    rm -rf "$fixture"
}

test_subscription_is_optional() {
    fixture=$(mktemp -d)
    TMP_DIR=$fixture
    ASSUME_YES=0

    # Redirect from a file rather than a pipe: a pipe would run the function
    # in a subshell and SUBSCRIPTION_COUNT would never reach this scope.
    printf '\n' > "$fixture/empty"
    read_subscriptions > "$fixture/out" 2>&1 < "$fixture/empty"
    output=$(cat "$fixture/out")

    assert_equal '0' "$SUBSCRIPTION_COUNT" \
        'an empty answer must leave no subscriptions'
    assert_contains "$output" 'NetShift настроен, но запускаться не будет' \
        'the user must be told NetShift stays stopped'
    assert_contains "$output" 'LuCI' \
        'the user must be told where to add the subscription later'

    printf 'https://example.test/a\nhttps://example.test/b\n' > "$fixture/two"
    read_subscriptions > "$fixture/out" 2>&1 < "$fixture/two"
    output=$(cat "$fixture/out")

    assert_equal '2' "$SUBSCRIPTION_COUNT" \
        'two subscriptions must be accepted'
    assert_not_contains "$output" 'example.test' \
        'subscription URLs must never be echoed'

    SUBSCRIPTION_COUNT=0
    SUBSCRIPTIONS=''
    TMP_DIR=''
    rm -rf "$fixture"
}

test_netshift_stays_stopped_without_subscription() {
    lifecycle=$(cat "$PROJECT_DIR/lib/netshift.sh")
    boot=$(cat "$PROJECT_DIR/runtime/router-provisioner-netshift-start")

    assert_contains "$lifecycle" 'Подписки нет, NetShift не запускается.' \
        'the installer must refuse to start NetShift without a subscription'
    assert_contains "$boot" 'no subscription configured' \
        'the boot guard must refuse to start NetShift without a subscription'
    assert_contains "$boot" 'netshift.VPN.subscription_url' \
        'the boot guard must read the subscription from UCI'
}

test_boot_guard_is_not_respawned() {
    lifecycle=$(cat "$PROJECT_DIR/lib/lifecycle.sh")

    assert_not_contains "$lifecycle" 'procd_set_param respawn' \
        'respawn restarts the one-shot helper forever and flaps NetShift'
    assert_contains "$lifecycle" 'One-shot boot task' \
        'the reason respawn is absent must stay documented'
}

test_adblock_defaults_to_adguard() {
    fixture=$(mktemp -d)
    TMP_DIR=$fixture
    DRY_RUN=1
    ASSUME_YES=1

    uci() {
        return 0
    }

    output=$(configure_adblock 2>&1)

    assert_contains "$output" 'netshift.settings.dns_type=doh' \
        'ad blocking must switch the upstream resolver to DoH'
    assert_contains "$output" '[REDACTED]' \
        'the resolver address must not be echoed'
    assert_contains "$output" 'через DNS не блокируется' \
        'in-stream video ads must be called out as not blocked'

    assert_true 'a personal AdGuard endpoint must be accepted' \
        valid_doh_url 'https://d.adguard-dns.com/dns-query/abc123'
    assert_true 'the public AdGuard endpoint must be accepted' \
        valid_doh_url "$ADGUARD_DEFAULT_DOH"
    assert_false 'a bare hostname must be rejected' \
        valid_doh_url 'dns.adguard-dns.com'
    assert_false 'a bootstrap IP must be rejected' \
        valid_doh_url '94.140.14.49'

    unset -f uci 2>/dev/null || true
    DRY_RUN=0
    ASSUME_YES=0
    TMP_DIR=''
    rm -rf "$fixture"
}

test_reconciliation_primitives_preserve_user_values() {
    fixture=$(mktemp -d)
    UCI_DB="$fixture/db"
    : > "$UCI_DB"
    DRY_RUN=0

    # Minimal stateful uci: enough to prove we read before writing.
    uci() {
        [ "$1" = '-q' ] && shift
        action=$1
        shift
        case "$action" in
            get)
                value=$(sed -n "s|^$1=||p" "$UCI_DB" | head -n 1)
                [ -n "$value" ] || return 1
                printf '%s\n' "$value"
                ;;
            set|add_list)
                key=${1%%=*}
                new=${1#*=}
                previous=$(sed -n "s|^$key=||p" "$UCI_DB" | head -n 1)
                grep -v "^$key=" "$UCI_DB" > "$UCI_DB.tmp" 2>/dev/null || true
                mv "$UCI_DB.tmp" "$UCI_DB"
                if [ "$action" = add_list ] && [ -n "$previous" ]; then
                    printf '%s=%s %s\n' "$key" "$previous" "$new" >> "$UCI_DB"
                else
                    printf '%s=%s\n' "$key" "$new" >> "$UCI_DB"
                fi
                ;;
            *) return 0 ;;
        esac
    }

    # The owner turned the global proxy off by hand; a re-run must not undo it.
    printf 'netshift.VPN.global_proxy=0\n' > "$UCI_DB"
    uci_set_default netshift.VPN.global_proxy 1
    assert_equal '0' "$(uci_value netshift.VPN.global_proxy)" \
        'an existing user value must survive a re-run'

    uci_set_default netshift.VPN.urltest_tolerance 50
    assert_equal '50' "$(uci_value netshift.VPN.urltest_tolerance)" \
        'a missing option must be filled in'

    # Correctness-critical options are repaired even when already set.
    printf 'netshift.settings.config_path=/wrong/path.json\n' >> "$UCI_DB"
    uci_set_required netshift.settings.config_path /etc/sing-box/config.json
    assert_equal '/etc/sing-box/config.json' \
        "$(uci_value netshift.settings.config_path)" \
        'a required option must be corrected'

    uci_add_list_once netshift.RU_DIRECT.community_lists youtube
    uci_add_list_once netshift.RU_DIRECT.community_lists youtube
    assert_equal 'youtube' \
        "$(uci_value netshift.RU_DIRECT.community_lists)" \
        'a list entry must not be added twice'

    unset -f uci 2>/dev/null || true
    rm -rf "$fixture"
}

test_uci_helpers_do_not_clobber_caller_variables() {
    fixture=$(mktemp -d)
    UCI_DB="$fixture/db"
    : > "$UCI_DB"
    DRY_RUN=0

    uci() {
        [ "$1" = '-q' ] && shift
        action=$1
        shift
        case "$action" in
            get)
                v=$(sed -n "s|^$1=||p" "$UCI_DB" | head -n 1)
                [ -n "$v" ] || return 1
                printf '%s\n' "$v"
                ;;
            set|add_list)
                printf '%s\n' "$1" >> "$UCI_DB"
                ;;
            *) return 0 ;;
        esac
    }

    # POSIX sh has no locals. A helper that assigns to "section", "option" or
    # "value" silently rewrites the caller's variable of the same name, and the
    # caller then builds nonsense keys out of it.
    section='@section[0]'
    option='keep-me'
    value='keep-me-too'
    type='keep-this'

    uci_ensure_section 'youtubeUnblock.youtubeUnblock' youtubeUnblock
    uci_set_default "youtubeUnblock.$section.name" 'Default section'
    uci_set_required "youtubeUnblock.$section.enabled" 1
    uci_add_list_once "youtubeUnblock.$section.sni_domains" youtube.com
    uci_delete "youtubeUnblock.$section.stale"

    assert_equal '@section[0]' "$section" \
        'uci helpers must not overwrite the caller section variable'
    assert_equal 'keep-me' "$option" \
        'uci helpers must not overwrite a caller variable named option'
    assert_equal 'keep-me-too' "$value" \
        'uci helpers must not overwrite a caller variable named value'
    assert_equal 'keep-this' "$type" \
        'uci helpers must not overwrite a caller variable named type'

    # The written keys must stay single-prefixed, not youtubeUnblock.<section>.
    assert_false 'a doubled config prefix means the section was clobbered' \
        grep -q 'youtubeUnblock\.youtubeUnblock\.youtubeUnblock' "$UCI_DB"

    unset -f uci 2>/dev/null || true
    unset section option value type 2>/dev/null || true
    rm -rf "$fixture"
}

test_configuration_is_reconciled_not_rewritten() {
    netshift=$(cat "$PROJECT_DIR/lib/netshift.sh")
    youtubeunblock=$(cat "$PROJECT_DIR/lib/youtubeunblock.sh")

    assert_not_contains "$netshift" 'uci_delete netshift.VPN' \
        'the VPN section must never be wiped'
    assert_not_contains "$netshift" 'uci_delete netshift.RU_DIRECT' \
        'the exclusion section must never be wiped'
    assert_contains "$netshift" 'find_exclusion_section' \
        'a renamed exclusion section must be reused, not duplicated'
    assert_not_contains "$youtubeunblock" 'remove_youtubeunblock_sections' \
        'the youtubeUnblock section must not be recreated from scratch'
    assert_contains "$youtubeunblock" 'remove_extra_youtubeunblock_sections' \
        'only duplicate youtubeUnblock sections may be removed'
}

test_declining_a_step_never_aborts_the_run() {
    entrypoint=$(cat "$PROJECT_DIR/lib/main.sh")
    netshift=$(cat "$PROJECT_DIR/lib/netshift.sh")
    youtubeunblock=$(cat "$PROJECT_DIR/lib/youtubeunblock.sh")

    # Every optional block is gated by a question and returns instead of exiting.
    assert_contains "$entrypoint" 'Установить и настроить NetShift?' \
        'NetShift installation must be a question'
    assert_contains "$entrypoint" 'Установить youtubeUnblock?' \
        'youtubeUnblock installation must be a question'
    assert_contains "$entrypoint" 'Установить сторожевой запуск' \
        'the guarded lifecycle must be a question'

    # A failed component must report and return, never kill the whole run.
    assert_not_contains "$netshift" "fatal 'Установка NetShift завершилась" \
        'a failed NetShift install must not abort the run'
    assert_not_contains "$youtubeunblock" \
        "fatal 'Установка youtubeUnblock завершилась" \
        'a failed youtubeUnblock install must not abort the run'
    assert_contains "$entrypoint" 'зависимые шаги пропускаются' \
        'skipping dependent steps must be explained'
}

test_pinned_sections_are_optional_and_ordered() {
    pinning=$(cat "$PROJECT_DIR/lib/pinning.sh")
    boot=$(cat "$PROJECT_DIR/runtime/router-provisioner-netshift-start")

    assert_contains "$pinning" 'Направить отдельные сервисы через фиксированные' \
        'pinning must be offered, not forced'
    # NetShift builds rules in section order and the first match wins, so a
    # pinned section is useless unless it is moved ahead of the broad ones.
    assert_contains "$pinning" 'uci reorder' \
        'a pinned section must be moved ahead of the broad sections'
    assert_contains "$boot" 'router-provisioner-pin' \
        'boot must restore pinned nodes instead of waiting for cron'

    assert_true 'a plain section name must pass' \
        section_name_is_valid 'ANTHROPIC'
    assert_false 'a name with a dot must fail' \
        section_name_is_valid 'my.section'
    assert_false 'an empty name must fail' \
        section_name_is_valid ''
}

test_pin_helper_contract() {
    pin=$(cat "$PROJECT_DIR/runtime/router-provisioner-pin")

    assert_contains "$pin" 'endswith("-urltest-out")' \
        'OpenWrt jq has no regex, so keyword matching must avoid test()'
    assert_contains "$pin" "sed 's/ /%20/g'" \
        'this BusyBox has no od, so only spaces may be escaped'

    # Switching a selector closes every connection on the old node and shows the
    # service a new exit address. One unlucky probe must never cost a session -
    # but neither may a real outage wait three minutes for the cron to agree.
    # Evidence is gathered densely instead of slowly.
    assert_contains "$pin" 'BURST_PROBES=8' \
        'a miss on the primary must be re-asked, not believed'
    assert_contains "$pin" 'BURST_GAP=2' \
        'the burst must confirm a real outage in well under a minute'
    assert_contains "$pin" 'RECOVER_THRESHOLD=5' \
        'the return trip kills sessions too, and nothing is broken while it waits'
    assert_contains "$pin" 'primary and reserve are both silent' \
        'a dead uplink must not be mistaken for a dead node'
    assert_contains "$pin" 'state_store' \
        'counters must survive between cron runs'
    assert_not_contains "$pin" 'primary is back, switched to' \
        'the immediate switch-back is what dropped the session'
}

test_youtube_takes_the_direct_route() {
    netshift=$(cat "$PROJECT_DIR/lib/netshift.sh")

    # The page must leave from the owner's own address, same as the video it
    # describes. Left on the proxy it reaches Google from whichever country the
    # subscription picked, and YouTube answers in that language with that
    # country's ads - none of which Google sells into Russia.
    assert_contains "$netshift" 'googlevideo.com' \
        'the video CDN must stay on the direct route'
    assert_contains "$netshift" 'youtu.be' \
        'short links must follow the page'
    assert_contains "$netshift" 'jnn-pa.googleapis.com' \
        'attestation answered from another country invites a challenge'

    # The control plane is blocked far harder than the CDN. A blocked API host
    # loads the page but never starts playback - the failure that looks like
    # "YouTube is broken" while every other check passes.
    assert_not_contains "$netshift" 'youtubei.googleapis.com' \
        'the YouTube API must not be routed directly'
    assert_not_contains "$netshift" 'youtubeembeddedplayer.googleapis.com' \
        'the embedded player API must not be routed directly'

    assert_contains "$netshift" 'drop_youtube_community_list' \
        'the upstream youtube community list must be removed on re-run'

    # local_domain_lists is a uci list: pointing at the new name without
    # removing the old one leaves NetShift reading a file that is gone, which
    # yields an empty ruleset and sends YouTube back down the tunnel silently.
    assert_contains "$netshift" 'direct-route.lst' \
        'the list is named for what it does, not for the first user of it'
    assert_contains "$netshift" 'migrate_direct_list' \
        'an existing router must be migrated, not just pointed elsewhere'
    assert_contains "$netshift" 'uci del_list' \
        'the stale path must be removed from the uci list'
    assert_not_contains "$netshift" \
        'uci_add_list_once netshift.RU_DIRECT.community_lists youtube' \
        'the youtube community list must not be added back'
}

test_unconfigured_proxy_sections_are_removed() {
    netshift=$(cat "$PROJECT_DIR/lib/netshift.sh")

    # NetShift ships a "main" placeholder with proxy_config_type=url and no
    # proxy_string. It aborts the whole config generation on it, so sing-box
    # never gets a config and refuses to start on the package default.
    assert_contains "$netshift" 'remove_unconfigured_proxy_sections' \
        'an unfinished proxy section must be removed before configuring'
    assert_contains "$netshift" 'proxy_string' \
        'the placeholder is recognised by its empty proxy string'

    # The installer validation must use the same probe as the boot helper.
    assert_contains "$netshift" 'resolver_answers' \
        'validation must accept any answer from the sing-box resolver'
    assert_not_contains "$netshift" \
        'nslookup www.gstatic.com 127.0.0.42' \
        'gstatic never returns a FakeIP and must not be probed'
}

test_default_topology_routes_by_list() {
    netshift=$(cat "$PROJECT_DIR/lib/netshift.sh")
    adblock=$(cat "$PROJECT_DIR/lib/adblock.sh")

    # Route what is blocked, not everything: a global proxy pushes video
    # through the subscription and takes the whole net down with the proxy.
    assert_contains "$netshift" 'uci_set_default netshift.VPN.global_proxy 0' \
        'the proxy section must route by list, not globally'
    assert_contains "$netshift" \
        'uci_add_list_once netshift.VPN.community_lists russia_inside' \
        'the proxy section must carry the blocked-domains list'
    assert_contains "$netshift" 'netshift.YT_DIRECT' \
        'YouTube needs its own exclusion: russia_inside carries it'
    assert_not_contains "$netshift" 'netshift.RU_DIRECT.community_lists' \
        'Russian sites need no exclusion once nothing is proxied by default'

    # NetShift stores the resolver without a scheme; its diagnostic splits the
    # value on the first slash and would probe a host named "https:".
    assert_equal 'dns.adguard-dns.com/dns-query' \
        "$(strip_url_scheme 'https://dns.adguard-dns.com/dns-query')" \
        'the scheme must be stripped before storing the resolver'
    assert_equal 'd.adguard-dns.com/dns-query/id' \
        "$(strip_url_scheme 'd.adguard-dns.com/dns-query/id')" \
        'a scheme-less address must pass through untouched'
    assert_true 'the address shown by AdGuard must be accepted' \
        valid_doh_url 'https://d.adguard-dns.com/dns-query/id'
    assert_true 'the form the interface expects must be accepted too' \
        valid_doh_url 'd.adguard-dns.com/dns-query/id'
    assert_false 'a bare host is not a DoH endpoint' \
        valid_doh_url 'dns.adguard-dns.com'
    assert_not_contains "$adblock" "ADGUARD_DEFAULT_DOH='https://" \
        'the public resolver must be stored without a scheme'
}

test_maintenance_runs_at_night() {
    lifecycle=$(cat "$PROJECT_DIR/lib/lifecycle.sh")
    boot=$(cat "$PROJECT_DIR/runtime/router-provisioner-netshift-start")

    # Every refresh restarts sing-box, and a restart drops the pinned node,
    # which reads to a service as a new exit address and a fresh login prompt.
    assert_contains "$lifecycle" "printf '0 3 * * * %s" \
        'the subscription refresh must run nightly, not hourly'
    assert_not_contains "$lifecycle" "printf '41 * * * * %s" \
        'an hourly refresh restarts sing-box 24 times a day'

    # NetShift hardcodes 09:13 and 09:17 and rewrites the crontab on every
    # start, so the times can only be corrected afterwards.
    assert_contains "$boot" 'retime_netshift_cron' \
        'NetShift own schedule must be moved out of working hours'
    assert_contains "$boot" '30 3 * * * /usr/bin/netshift list_update' \
        'the list update must land at night'
    assert_contains "$boot" \
        "grep -v '/usr/bin/netshift subscription_update'" \
        'NetShift own subscription job duplicates the helper that can roll back'
}

test_half_working_ipv6_is_withdrawn() {
    netshift=$(cat "$PROJECT_DIR/lib/netshift.sh")
    entrypoint=$(cat "$PROJECT_DIR/lib/main.sh")

    # NetShift routes IPv4 only. A LAN that still advertises IPv6 gives clients
    # an address nothing forwards, and Happy Eyeballs makes every app try it
    # first and wait out the timeout - random multi-second hangs.
    assert_contains "$netshift" 'configure_ipv6_advertisement' \
        'a LAN advertising unusable IPv6 must be detected'
    assert_contains "$netshift" 'lan_advertises_ipv6' \
        'the check must look at what the LAN actually advertises'
    assert_contains "$netshift" 'Перестать раздавать IPv6 клиентам?' \
        'withdrawing IPv6 must be offered, not forced'
    assert_contains "$entrypoint" 'configure_ipv6_advertisement' \
        'the IPv6 step must run as part of the NetShift block'

    DRY_RUN=0
    uci() { return 1; }
    assert_false 'a LAN with nothing configured does not advertise IPv6' \
        lan_advertises_ipv6
    unset -f uci 2>/dev/null || true
}

test_uplink_check_survives_fakeip() {
    boot=$(cat "$PROJECT_DIR/runtime/router-provisioner-netshift-start")

    # The check used to download a ruleset from GitHub. Once
    # objects.githubusercontent.com was routed through the proxy - which is what
    # makes the list update work at all - that name started resolving to a
    # FakeIP address the router itself cannot reach, so the check failed every
    # time NetShift was running. The helper then stopped a healthy service and
    # left the household without a VPN for fifteen hours.
    assert_not_contains "$boot" 'allow-domains/releases' \
        'reachability must not depend on a name the proxy may capture'
    assert_not_contains "$boot" 'download_ruleset_preflight' \
        'the ruleset download must not be the uplink test'
    assert_contains "$boot" 'uplink_reachable' \
        'reachability is proved by literal addresses, which FakeIP cannot touch'
    assert_contains "$boot" '77.88.8.8' \
        'at least one probe target must be reachable from Russia'

    # A probe that disagrees with a healthy service is a broken probe.
    assert_contains "$boot" 'but NetShift is healthy, leaving it alone' \
        'a failed probe must never stop a service that is up and working'
}

test_readiness_checks_policy_route() {
    boot=$(cat "$PROJECT_DIR/runtime/router-provisioner-netshift-start")

    # A network or firewall reload drops the policy routing rule while leaving
    # the process, the nftables table and the tproxy rules in place: every
    # surface check passes and not one proxied site opens.
    assert_contains "$boot" 'policy_route_present' \
        'readiness must verify the policy routing rule'
    assert_contains "$boot" "lookup netshift" \
        'the rule is what actually delivers marked packets to sing-box'
}

test_router_reports_its_own_health() {
    report=$(cat "$PROJECT_DIR/runtime/router-provisioner-report")
    lifecycle=$(cat "$PROJECT_DIR/lib/lifecycle.sh")
    launcher=$(cat "$PROJECT_DIR/router-provisioner.sh")

    # NetShift was stopped by a broken check and stayed down fifteen hours; the
    # way it was found out was the owner noticing. The router knew all along.
    assert_contains "$report" 'router_last_seen_timestamp' \
        'silence must be detectable, which needs a heartbeat'
    assert_contains "$report" 'router_policy_route_present' \
        'the routing rule is invisible to every other check'
    assert_contains "$report" 'router_pin_respected' \
        'a group drifting off its primary costs the owner a signed-in session'
    assert_contains "$report" 'router_component_version' \
        'an outdated sing-box looks like a dead subscription and nothing else'

    # Delivery must not depend on the thing it reports about.
    assert_contains "$report" 'for attempt in direct proxy' \
        'a broken proxy must not take the alarm down with it'

    # Reading the delays sing-box already measured costs nothing; probing 26
    # nodes every five minutes would not.
    assert_contains "$report" '.history[-1].delay' \
        'node health must come from measurements that already exist'

    assert_contains "$lifecycle" "printf '*/5 * * * * %s" \
        'the report must be scheduled often enough to matter'
    assert_contains "$lifecycle" 'VERSION_FILE' \
        'the router must publish its own script version'
    assert_contains "$launcher" 'router-provisioner-report' \
        'the launcher must download the report helper'
}

test_component_upgrade_is_scheduled_and_quiet() {
    upgrade=$(cat "$PROJECT_DIR/runtime/router-provisioner-upgrade")
    lifecycle=$(cat "$PROJECT_DIR/lib/lifecycle.sh")
    launcher=$(cat "$PROJECT_DIR/router-provisioner.sh")

    # An outdated sing-box does not report itself - it looks like a subscription
    # where every node is unreachable, while the same nodes answer fine from
    # any other client.
    assert_contains "$upgrade" 'check_update' \
        'the upgrade must ask NetShift what the current version is'
    assert_contains "$upgrade" 'install_extended' \
        'an outdated sing-box must actually be upgraded'
    # Restarting when nothing changed drops the pinned node for no reason.
    assert_contains "$upgrade" "if [ \"\$status\" = 'latest' ]; then" \
        'an already current component must not trigger a restart'
    assert_contains "$upgrade" 'restore_pinned_nodes' \
        'an upgrade restart must put the pinned nodes back'
    # A silent run cannot be told apart from a run that never happened.
    assert_contains "$upgrade" 'is current' \
        'a nightly run must leave a trace even when there is nothing to do'
    # NetShift own installer is interactive and can reset the configuration.
    assert_contains "$upgrade" 'upgrade it by hand' \
        'NetShift itself must be reported, not upgraded unattended'

    assert_contains "$lifecycle" 'router-provisioner-upgrade' \
        'the upgrade helper must be installed and scheduled'
    assert_contains "$launcher" 'router-provisioner-upgrade' \
        'the launcher must download the upgrade helper'
}

test_log_buffer_survives_the_pin_cron() {
    pinning=$(cat "$PROJECT_DIR/lib/pinning.sh")

    # The pin helper runs every minute. busybox crond announces every job it
    # starts, so the helper alone writes 1440 lines a day into a ring buffer
    # that lives in RAM and defaults to 128 KB. An intermittent fault reported
    # the same evening had already been overwritten by those announcements.
    assert_contains "$pinning" 'keep_log_buffer_usable' \
        'installing a per-minute cron must also keep the log readable'
    assert_contains "$pinning" "'system.@system[0].cronloglevel' '9'" \
        'crond must stop announcing every run of the pin helper'
    assert_contains "$pinning" "'system.@system[0].log_size' '512'" \
        'the ring buffer must hold more than a single evening'
    assert_contains "$pinning" '/etc/init.d/log restart' \
        'a new buffer size only takes effect once log is restarted'
}

test_rerun_delivers_fixes_without_reanswering() {
    pinning=$(cat "$PROJECT_DIR/lib/pinning.sh")
    lifecycle=$(cat "$PROJECT_DIR/lib/lifecycle.sh")
    entrypoint=$(cat "$PROJECT_DIR/lib/main.sh")

    # Declining a step means declining a change of setup, not asking to keep a
    # stale helper. The helpers carry the failover and upgrade logic, so a
    # router left on an old copy keeps old bugs through every later release.
    assert_contains "$pinning" 'refresh_pinned_helper' \
        'a pinned router must get helper fixes whatever the owner answers'
    assert_contains "$lifecycle" 'refresh_lifecycle_helpers' \
        'a guarded router must get helper fixes whatever the owner answers'
    assert_contains "$entrypoint" 'refresh_lifecycle_helpers' \
        'the declined branch must still refresh what is already installed'

    # Answering yes and then pressing Enter at the first prompt used to empty
    # the pinned file before a single service had been entered.
    assert_contains "$pinning" 'staged="$PINNED_DIR/.pinned.$$"' \
        'services must be collected aside, not written over the live file'
    assert_not_contains "$pinning" ': > "$PINNED_FILE"' \
        'the live pinned file must never be emptied before it can be replaced'
    assert_contains "$pinning" 'прежние настройки оставлены как были' \
        'an empty answer must leave the existing pinning alone'

    # Refreshing must not silently re-enable or restart what the owner turned
    # off; only files and schedule are ours to maintain.
    assert_contains "$lifecycle" 'copy_lifecycle_helpers' \
        'the file copy must be reusable by both install and refresh'
    assert_contains "$lifecycle" 'schedule_nightly_maintenance' \
        'the schedule must be reusable by both install and refresh'

    # NetShift puts its own jobs back at 09:13 and 09:17 on every restart. A
    # crontab we are already rewriting must be corrected, or a re-run leaves the
    # router doing maintenance in the middle of the working day.
    assert_contains "$lifecycle" '30 3 * * * /usr/bin/netshift list_update' \
        'a re-run must move the list update back to the small hours'
    assert_contains "$lifecycle" "grep -v '/usr/bin/netshift subscription_update'" \
        'NetShift own subscription job duplicates the helper that can roll back'
}

test_youtubeunblock_is_wired_in() {
    launcher=$(cat "$PROJECT_DIR/router-provisioner.sh")
    entrypoint=$(cat "$PROJECT_DIR/lib/main.sh")

    assert_contains "$launcher" 'youtubeunblock' \
        'launcher must download the youtubeUnblock module'
    assert_contains "$entrypoint" 'install_youtubeunblock' \
        'entrypoint must install youtubeUnblock'
    assert_contains "$entrypoint" 'configure_youtubeunblock' \
        'entrypoint must configure youtubeUnblock'
    assert_contains "$entrypoint" 'start_youtubeunblock' \
        'entrypoint must start youtubeUnblock'
}

test_version_comparison
test_public_key_validation
test_fetcher_selection
test_fetcher_prefers_ipv4_then_falls_back
test_uplink_detection_is_interface_agnostic
test_dry_run_redacts_subscriptions
test_guarded_boot_contract
test_refresh_contract
test_launcher_preserves_interactive_stdin
test_netshift_upgrades_to_latest
test_github_asset_selection
test_youtubeunblock_matches_reference
test_netshift_settings_match_reference
test_log_buffer_survives_the_pin_cron
test_rerun_delivers_fixes_without_reanswering
test_youtubeunblock_is_wired_in
test_subscription_is_optional
test_netshift_stays_stopped_without_subscription
test_boot_guard_is_not_respawned
test_adblock_defaults_to_adguard
test_reconciliation_primitives_preserve_user_values
test_configuration_is_reconciled_not_rewritten
test_declining_a_step_never_aborts_the_run
test_pinned_sections_are_optional_and_ordered
test_pin_helper_contract
test_youtube_takes_the_direct_route
test_uci_helpers_do_not_clobber_caller_variables
test_unconfigured_proxy_sections_are_removed
test_default_topology_routes_by_list
test_maintenance_runs_at_night
test_half_working_ipv6_is_withdrawn
test_uplink_check_survives_fakeip
test_readiness_checks_policy_route
test_router_reports_its_own_health
test_component_upgrade_is_scheduled_and_quiet

printf 'OK: %s assertions\n' "$TEST_COUNT"
