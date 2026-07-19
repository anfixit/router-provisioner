#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ROUTER_PROVISIONER_SOURCE_ONLY=1
export ROUTER_PROVISIONER_SOURCE_ONLY

# shellcheck source=../router-provisioner.sh
. "$PROJECT_DIR/router-provisioner.sh"

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

    if [ "$expected" != "$actual" ]; then
        fail_test "$message: expected=$expected actual=$actual"
    fi
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

test_profile_conversion() {
    result=$(profile_from_board_name 'glinet,gl-mt6000')
    assert_equal 'glinet_gl-mt6000' "$result" \
        'board name must become a firmware profile'
}

test_target_encoding() {
    result=$(encode_target 'mediatek/filogic')
    assert_equal 'mediatek%2Ffilogic' "$result" \
        'target slash must be URL encoded'
}

test_version_comparison() {
    assert_true '25.12.5 must be newer than 24.10.0' \
        version_ge '25.12.5' '24.10.0'
    assert_true '24.10.0 must equal itself' \
        version_ge '24.10.0' '24.10.0'
    assert_true '24.10.1-rc1 must pass 24.10.0' \
        version_ge '24.10.1-rc1' '24.10.0'
    assert_false '23.05.5 must be older than 24.10.0' \
        version_ge '23.05.5' '24.10.0'
}

test_release_parser() {
    fixture=$(mktemp -d)
    mkdir -p "$fixture/etc"
    cat > "$fixture/etc/openwrt_release" <<'EOF_RELEASE'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
DISTRIB_TARGET='mediatek/filogic'
EOF_RELEASE

    ROOT_PREFIX=$fixture
    release=$(parse_release_value DISTRIB_RELEASE)
    target=$(parse_release_value DISTRIB_TARGET)
    ROOT_PREFIX=''
    rm -rf "$fixture"

    assert_equal '25.12.5' "$release" 'release parser failed'
    assert_equal 'mediatek/filogic' "$target" 'target parser failed'
}

test_input_validation() {
    assert_true 'ed25519 public key must be accepted' \
        validate_public_key 'ssh-ed25519 AAAAC3NzaC1 example'
    assert_false 'private key material must be rejected' \
        validate_public_key '-----BEGIN OPENSSH PRIVATE KEY-----'
    assert_true 'strong Wi-Fi password must be accepted' \
        validate_wifi_password 'correct-horse-battery'
    assert_false 'short Wi-Fi password must be rejected' \
        validate_wifi_password 'short'
    assert_true 'HTTPS subscription must be accepted' \
        validate_subscription_url 'https://example.test/subscription'
    assert_false 'file subscription must be rejected' \
        validate_subscription_url 'file:///etc/shadow'
}

test_ssh_key_guidance() {
    output=$(print_ssh_key_help 2>&1)

    assert_contains "$output" 'ssh-keygen -t ed25519' \
        'SSH key creation command is missing'
    assert_contains "$output" 'cat ~/.ssh/id_ed25519.pub' \
        'macOS and Linux public-key command is missing'
    assert_contains "$output" 'Get-Content' \
        'PowerShell public-key command is missing'
    assert_contains "$output" 'type %USERPROFILE%' \
        'cmd.exe public-key command is missing'
}

test_public_key_retry() {
    expected='ssh-ed25519 AAAAC3NzaC1 example'
    result=$(
        printf '%s\n' 'not-a-key' "$expected" | \
            ask_public_key 2>/dev/null
    )

    assert_equal "$expected" "$result" \
        'invalid public key must be requested again'
}

test_wifi_password_retry() {
    expected='correct-password-123'
    result=$(
        printf '%s\n' \
            'short' \
            "$expected" \
            'different-password-456' \
            "$expected" \
            "$expected" | \
            ask_wifi_password 2>/dev/null
    )

    assert_equal "$expected" "$result" \
        'Wi-Fi password must retry until length and confirmation pass'
}

test_wifi_encryption_retry() {
    result=$(printf '%s\n' '3' '2' | ask_wifi_encryption 2>/dev/null)

    assert_equal 'sae-mixed' "$result" \
        'invalid Wi-Fi encryption choice must be requested again'
}

test_dry_run_tracks_root_password() {
    DRY_RUN=1
    ASSUME_YES=1
    ROOT_PASSWORD_AVAILABLE=0

    configure_root_password >/dev/null

    assert_equal '1' "$ROOT_PASSWORD_AVAILABLE" \
        'dry-run must remember the planned root password'

    DRY_RUN=0
    ASSUME_YES=0
    ROOT_PASSWORD_AVAILABLE=0
}

# White-box test variables are consumed by the sourced runtime.
# shellcheck disable=SC2034
test_firmware_plan() {
    BOARD_NAME='glinet,gl-mt6000'
    OPENWRT_TARGET='mediatek/filogic'
    OPENWRT_VERSION='25.12.5'
    PACKAGE_MANAGER='apk'

    firmware_profile_exists() {
        return 0
    }

    output=$(print_firmware_plan '25.12.5' 2>&1)
    expected='https://firmware-selector.openwrt.org/'
    expected="${expected}?version=25.12.5"
    expected="${expected}&target=mediatek%2Ffilogic"
    expected="${expected}&id=glinet_gl-mt6000"

    assert_contains "$output" "$expected" \
        'firmware selector URL is incorrect'
    assert_contains "$output" 'owut check' \
        'owut upgrade instructions are missing'
}

test_diagnose_integration() {
    fixture=$(mktemp -d)
    mock_bin="$fixture/bin"
    mkdir -p \
        "$mock_bin" \
        "$fixture/etc" \
        "$fixture/proc" \
        "$fixture/tmp/sysinfo"

    cat > "$fixture/etc/openwrt_release" <<'EOF_RELEASE'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
DISTRIB_TARGET='mediatek/filogic'
EOF_RELEASE
    cat > "$fixture/proc/meminfo" <<'EOF_MEMINFO'
MemTotal:        1048576 kB
MemAvailable:     786432 kB
EOF_MEMINFO
    cat > "$fixture/proc/mounts" <<'EOF_MOUNTS'
rootfs / squashfs ro 0 0
/dev/ubi0_1 /overlay ubifs rw 0 0
EOF_MOUNTS

    cat > "$mock_bin/ubus" <<'EOF_UBUS'
#!/bin/sh
printf '%s\n' '{"model":"GL.iNet GL-MT6000",'\
'"board_name":"glinet,gl-mt6000"}'
EOF_UBUS
    cat > "$mock_bin/jsonfilter" <<'EOF_JSONFILTER'
#!/bin/sh
case "$2" in
    '@.model')
        printf '%s\n' 'GL.iNet GL-MT6000'
        ;;
    '@.board_name')
        printf '%s\n' 'glinet,gl-mt6000'
        ;;
esac
EOF_JSONFILTER
    cat > "$mock_bin/uclient-fetch" <<'EOF_FETCH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-O' ]; then
        destination=$2
        break
    fi
    shift
done
printf '%s\n' '{"stable_version":"25.12.5"}' > "$destination"
EOF_FETCH
    cat > "$mock_bin/apk" <<'EOF_APK'
#!/bin/sh
exit 0
EOF_APK
    cat > "$mock_bin/id" <<'EOF_ID'
#!/bin/sh
if [ "${1:-}" = '-u' ]; then
    printf '0\n'
    exit 0
fi
exec /usr/bin/id "$@"
EOF_ID
    chmod +x "$mock_bin"/*

    output=$(
        PATH="$mock_bin:$PATH" \
        ROUTER_PROVISIONER_SOURCE_ONLY=0 \
        ROUTER_PROVISIONER_ROOT_PREFIX="$fixture" \
        "$PROJECT_DIR/router-provisioner.sh" --diagnose 2>&1
    )
    rm -rf "$fixture"

    assert_contains "$output" \
        'OpenWrt:                25.12.5' \
        'diagnose did not read OpenWrt release'
    assert_contains "$output" 'glinet_gl-mt6000' \
        'diagnose did not build firmware profile'
}

test_root_password_detection() {
    fixture=$(mktemp -d)
    mkdir -p "$fixture/etc"

    printf '%s\n' 'root:!:0:0:99999:7:::' > "$fixture/etc/shadow"
    ROOT_PREFIX=$fixture
    assert_false 'locked root password must be rejected' \
        root_has_password

    printf '%s\n' "root:\$6\$test\$hash:0:0:99999:7:::" \
        > "$fixture/etc/shadow"
    assert_true 'password hash must be accepted' root_has_password

    ROOT_PREFIX=''
    rm -rf "$fixture"
}

# White-box test variables are consumed by the sourced runtime.
# shellcheck disable=SC2034
test_subscription_redaction() {
    DRY_RUN=1
    ASSUME_YES=1
    TMP_DIR=$(mktemp -d)

    # Mock is invoked indirectly by configure_netshift.
    # shellcheck disable=SC2317
    uci() {
        if [ "${1:-}" = '-q' ] && [ "${2:-}" = 'get' ] && \
            [ "${3:-}" = 'network.lan.device' ]; then
            printf '%s\n' 'br-lan'
            return 0
        fi
        return 1
    }

    secret_url='https://secret.example.test/private-token'
    output=$(
        printf '%s\n\n\n' "$secret_url" | \
            configure_netshift 2>&1
    )

    assert_not_contains "$output" "$secret_url" \
        'subscription URL leaked into dry-run output'
    assert_contains "$output" '[REDACTED]' \
        'redacted subscription marker is missing'

    unset -f uci 2>/dev/null || true
    rm -rf "$TMP_DIR"
    TMP_DIR=''
    DRY_RUN=0
    ASSUME_YES=0
}

# White-box test variables are consumed by the sourced runtime.
# shellcheck disable=SC2034
test_extroot_device_guard() {
    fixture=$(mktemp -d)
    mkdir -p "$fixture/proc"
    cat > "$fixture/proc/mounts" <<'EOF_MOUNTS'
/dev/sda2 /overlay ubifs rw 0 0
/dev/sdb1 /mnt/data ext4 rw 0 0
EOF_MOUNTS
    cat > "$fixture/proc/swaps" <<'EOF_SWAPS'
Filename Type Size Used Priority
/dev/sdc1 partition 524284 0 -2
EOF_SWAPS

    ROOT_PREFIX=$fixture
    assert_true 'overlay device must be protected' \
        device_is_critical '/dev/sda2'
    assert_false 'ordinary data mount may be selected explicitly' \
        device_is_critical '/dev/sdb1'
    assert_true 'swap device must be protected' \
        device_is_critical '/dev/sdc1'
    ROOT_PREFIX=''

    rm -rf "$fixture"
}

test_installer_validation() {
    fixture=$(mktemp -d)
    valid_installer="$fixture/valid.sh"
    invalid_installer="$fixture/invalid.html"

    cat > "$valid_installer" <<'EOF_VALID'
#!/bin/sh
REPOSITORY='yandexru45/netshift'
exit 0
EOF_VALID
    printf '%s\n' '<html>NetShift download error</html>' \
        > "$invalid_installer"

    assert_true 'valid installer must be accepted' \
        validate_netshift_installer "$valid_installer"
    assert_false 'HTML response must be rejected' \
        validate_netshift_installer "$invalid_installer"

    rm -rf "$fixture"
}

silent_resource_check() {
    check_resources >/dev/null 2>&1
}

# White-box test variables are consumed by the sourced runtime.
# shellcheck disable=SC2034
test_resource_guard() {
    OVERLAY_FREE_KIB=30000
    RAM_TOTAL_KIB=262144
    assert_true 'sufficient resources must pass' \
        silent_resource_check

    OVERLAY_FREE_KIB=10000
    RAM_TOTAL_KIB=262144
    assert_false 'small overlay must fail' \
        silent_resource_check

    OVERLAY_FREE_KIB=30000
    RAM_TOTAL_KIB=32768
    assert_false 'less than 64 MiB RAM must fail' \
        silent_resource_check
}

test_current_netshift_schema() {
    script=$(cat "$PROJECT_DIR/router-provisioner.sh")

    assert_contains "$script" \
        'netshift.settings.global_proxy' \
        'global proxy must use the settings section'
    assert_contains "$script" \
        'subscription_allow_insecure' \
        'current allow-insecure option is missing'
    assert_not_contains "$script" \
        'subscription_insecure=' \
        'deprecated subscription option is present'
    assert_not_contains "$script" '/etc/crontabs/root' \
        'NetShift schedules must not be duplicated in cron'
}

test_ssh_session_safety() {
    apply_block=$(
        sed -n '/^apply_services()/,/^}/p' \
            "$PROJECT_DIR/router-provisioner.sh"
    )
    final_block=$(
        sed -n '/^print_final_instructions()/,/^}/p' \
            "$PROJECT_DIR/router-provisioner.sh"
    )

    assert_not_contains "$apply_block" 'dropbear restart' \
        'Dropbear must not restart during provisioning'
    assert_contains "$final_block" '/etc/init.d/dropbear restart' \
        'safe manual Dropbear restart instruction is missing'
}

test_repository_is_minimal() {
    runtime_count=0
    for runtime_file in "$PROJECT_DIR"/*.sh; do
        [ -f "$runtime_file" ] || continue
        runtime_count=$((runtime_count + 1))
    done
    assert_equal '1' "$runtime_count" \
        'repository must have one router runtime script'

    secret_file=$(
        find "$PROJECT_DIR" \
            \( -type d \( -name '.git' -o -name '.venv' \) \
                -prune \) -o \
            \( -type f \( -name '*.pem' -o -name '*.key' \
                -o -name '.env' \) -print \) | \
            head -n 1
    )

    TEST_COUNT=$((TEST_COUNT + 1))
    if [ -n "$secret_file" ]; then
        fail_test "secret-like file found: $secret_file"
    fi
}

main() {
    test_profile_conversion
    test_target_encoding
    test_version_comparison
    test_release_parser
    test_input_validation
    test_ssh_key_guidance
    test_public_key_retry
    test_wifi_password_retry
    test_wifi_encryption_retry
    test_dry_run_tracks_root_password
    test_firmware_plan
    test_diagnose_integration
    test_root_password_detection
    test_subscription_redaction
    test_extroot_device_guard
    test_installer_validation
    test_resource_guard
    test_current_netshift_schema
    test_ssh_session_safety
    test_repository_is_minimal

    printf 'PASS: %s tests\n' "$TEST_COUNT"
}

main "$@"
