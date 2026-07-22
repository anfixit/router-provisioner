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
VERSION='2.0.0'
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
    source=$(cat "$PROJECT_DIR/lib/netshift.sh")

    assert_contains "$source" 'WAN was not ready after 120 seconds' \
        'WAN readiness timeout is missing'
    assert_contains "$source" 'russia_outside.preflight.srs' \
        'remote ruleset preflight is missing'
    assert_contains "$source" 'first start failed; retrying once' \
        'bounded second attempt is missing'
    assert_contains "$source" \
        'stopping it to restore ordinary DNS and routing' \
        'fail-open cleanup is missing'
    assert_contains "$source" '/etc/init.d/netshift disable' \
        'native NetShift boot must be disabled'
    assert_contains "$source" 'START=99' \
        'guard service must start after ordinary network services'
}

test_launcher_preserves_interactive_stdin() {
    source=$(cat "$PROJECT_DIR/router-provisioner.sh")

    assert_contains "$source" 'Не используйте curl | sh.' \
        'launcher must explain why pipe execution is unsupported'
    assert_contains "$source" \
        'exec /bin/sh "$RUNTIME_DIR/main.sh" "$@"' \
        'launcher must execute the runtime file and forward arguments'
}

test_version_comparison
test_public_key_validation
test_fetcher_selection
test_dry_run_redacts_subscriptions
test_guarded_boot_contract
test_launcher_preserves_interactive_stdin

printf 'OK: %s assertions\n' "$TEST_COUNT"
