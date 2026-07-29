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
VERSION='2.1.1'
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

test_dry_run_redacts_subscriptions() {
    fixture=$(mktemp -d)
    TMP_DIR=$fixture
    YOUTUBE_LIST="$fixture/youtube.lst"
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

    assert_contains "$source" 'WAN was not ready after 120 seconds' \
        'WAN readiness timeout is missing'
    assert_contains "$source" 'russia_outside.preflight.srs' \
        'remote ruleset preflight is missing'
    assert_contains "$source" '/usr/bin/netshift list_update' \
        'lists must be prepared before NetShift starts'
    assert_contains "$source" 'first start failed; retrying once' \
        'bounded second attempt is missing'
    assert_contains "$source" \
        'stopping it to restore ordinary DNS and routing' \
        'fail-open cleanup is missing'
    assert_contains "$lifecycle" '/etc/init.d/netshift disable' \
        'native NetShift boot must be disabled'
    assert_contains "$lifecycle" 'START=99' \
        'guard service must start after ordinary network services'
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
    YOUTUBE_LIST="$fixture/youtube.lst"
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
test_dry_run_redacts_subscriptions
test_guarded_boot_contract
test_refresh_contract
test_launcher_preserves_interactive_stdin
test_netshift_upgrades_to_latest
test_github_asset_selection
test_youtubeunblock_matches_reference
test_netshift_settings_match_reference
test_youtubeunblock_is_wired_in

printf 'OK: %s assertions\n' "$TEST_COUNT"
