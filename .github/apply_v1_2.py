from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'router-provisioner.sh'
TESTS = ROOT / 'tests/test_router_provisioner.sh'
VERSION = ROOT / 'VERSION'


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


def replace_regex(text: str, pattern: str, new: str, label: str) -> str:
    result, count = re.subn(pattern, new, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise RuntimeError(f'{label}: expected one match, found {count}')
    return result


script = SCRIPT.read_text(encoding='utf-8')
script = replace_once(
    script,
    "PROGRAM_VERSION='1.1.0'",
    "PROGRAM_VERSION='1.2.0'",
    'program version',
)
script = replace_once(
    script,
    "NETSHIFT_REFRESH_HELPER='/usr/bin/router-provisioner-netshift-refresh'\n",
    "NETSHIFT_REFRESH_HELPER='/usr/bin/router-provisioner-netshift-refresh'\n"
    "NETSHIFT_HELPERS='/usr/lib/netshift/helpers.sh'\n"
    "NETSHIFT_READY_ATTEMPTS=40\n"
    "NETSHIFT_READY_DELAY=3\n",
    'runtime constants',
)
script = replace_regex(
    script,
    r"sing_box_extended_active\(\) \{.*?\n\}\n\ninstall_sing_box_extended\(\)",
    r'''sing_box_extended_active() {
    version=''

    if [ -x /usr/bin/sing-box ]; then
        version=$(/usr/bin/sing-box version 2>/dev/null | head -n 1)
    elif command_exists sing-box; then
        version=$(sing-box version 2>/dev/null | head -n 1)
    fi

    case "$version" in
        *extended*)
            return 0
            ;;
    esac

    return 1
}

install_sing_box_extended()''',
    'extended runtime detection',
)
extended_patch = r'''patch_netshift_extended_detection() {
    helpers=${1:-$NETSHIFT_HELPERS}
    marker='# BEGIN ROUTER_PROVISIONER_EXTENDED_DETECTION'

    [ -r "$helpers" ] || {
        error "Файл NetShift не найден: $helpers"
        return 1
    }

    if grep -F "$marker" "$helpers" >/dev/null 2>&1; then
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: в $helpers была бы исправлена проверка extended."
        return 0
    fi

    backup="${helpers}.before-router-provisioner"
    [ -e "$backup" ] || cp -p "$helpers" "$backup" || return 1

    cat >> "$helpers" <<'EOF_EXTENDED_DETECTION'

# BEGIN ROUTER_PROVISIONER_EXTENDED_DETECTION
# Use an absolute path: service environments may have a restricted PATH.
is_sing_box_extended() {
    local version=""

    if [ -x /usr/bin/sing-box ]; then
        version="$(/usr/bin/sing-box version 2>/dev/null | head -n 1)"
    elif command -v sing-box >/dev/null 2>&1; then
        version="$(sing-box version 2>/dev/null | head -n 1)"
    fi

    case "$version" in
        *extended*) return 0 ;;
    esac

    return 1
}
# END ROUTER_PROVISIONER_EXTENDED_DETECTION
EOF_EXTENDED_DETECTION
}

'''
script = replace_once(
    script,
    'patch_netshift_xhttp_policy() {\n',
    extended_patch + 'patch_netshift_xhttp_policy() {\n',
    'extended compatibility patch insertion',
)
script = replace_once(
    script,
    'patch_netshift_xhttp_policy() {\n    facade=${1:-$NETSHIFT_FACADE}\n\n',
    'patch_netshift_xhttp_policy() {\n'
    '    facade=${1:-$NETSHIFT_FACADE}\n'
    '    helpers=${2:-$NETSHIFT_HELPERS}\n\n'
    '    patch_netshift_extended_detection "$helpers" || return 1\n\n',
    'facade patch precondition',
)

refresh_helper = r'''install_xhttp_refresh_helper() {
    print_line
    print_line '=== Защита XHTTP-only ==='

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: был бы создан $NETSHIFT_REFRESH_HELPER."
        return 0
    fi

    cat > "$NETSHIFT_REFRESH_HELPER" <<'EOF_XHTTP_REFRESH'
#!/bin/ash

set -u

HELPERS='/usr/lib/netshift/helpers.sh'
FACADE='/usr/lib/netshift/sing_box_config_facade.sh'
CONFIG='/etc/sing-box/config.json'
SUBSCRIPTIONS='/etc/netshift/subscriptions'
MAX_ATTEMPTS=40
READY_DELAY=3

log() {
    logger -t router-provisioner-xhttp "$*"
}

patch_extended_detection() {
    marker='# BEGIN ROUTER_PROVISIONER_EXTENDED_DETECTION'

    [ -r "$HELPERS" ] || return 1
    grep -F "$marker" "$HELPERS" >/dev/null 2>&1 && return 0

    cat >> "$HELPERS" <<'EOF_EXTENDED_DETECTION'

# BEGIN ROUTER_PROVISIONER_EXTENDED_DETECTION
# Use an absolute path: service environments may have a restricted PATH.
is_sing_box_extended() {
    local version=""

    if [ -x /usr/bin/sing-box ]; then
        version="$(/usr/bin/sing-box version 2>/dev/null | head -n 1)"
    elif command -v sing-box >/dev/null 2>&1; then
        version="$(sing-box version 2>/dev/null | head -n 1)"
    fi

    case "$version" in
        *extended*) return 0 ;;
    esac

    return 1
}
# END ROUTER_PROVISIONER_EXTENDED_DETECTION
EOF_EXTENDED_DETECTION
}

patch_policy() {
    grep -F 'select($ob.type == "vless" and' \
        "$FACADE" >/dev/null 2>&1 && return 0

    temporary="${FACADE}.router-provisioner.$$"
    if ! awk '
        {
            print
            if (index($0, "| [ $candidates[]") > 0) {
                in_candidates = 1
                next
            }
            if (in_candidates && index($0, "| . as $ob") > 0) {
                print "            | select($ob.type == \"vless\" and"
                print "                     (($ob.transport.type // \"\") == \"xhttp\"))"
                inserted = inserted + 1
                in_candidates = 0
            }
        }
        END {if (inserted != 1) exit 42}
    ' "$FACADE" > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi

    chmod 644 "$temporary"
    mv "$temporary" "$FACADE"
}

validate_config() {
    [ -s "$CONFIG" ] || return 1

    jq -e '
        [.outbounds[]?
            | select(
                .type == "vless" and
                (.transport.type // "") == "xhttp"
            )
            | .tag
        ] as $xhttp_tags
        | [.outbounds[]?
            | select(.type == "urltest")
            | .tag
        ] as $urltest_tags
        | ($xhttp_tags | length) > 0
        and all(
            .outbounds[]?;
            if .type == "vless" then
                (.transport.type // "") == "xhttp"
            elif .type == "urltest" then
                all(.outbounds[]?; . as $tag |
                    ($xhttp_tags | index($tag)) != null)
            elif .type == "selector" then
                all(.outbounds[]?; . as $tag |
                    (($xhttp_tags | index($tag)) != null) or
                    (($urltest_tags | index($tag)) != null))
            else
                true
            end
        )
    ' "$CONFIG" >/dev/null 2>&1
}

fakeip_ready() {
    nslookup www.gstatic.com 127.0.0.42 2>/dev/null | \
        grep -Eq '198\.18\.'
}

configuration_ready() {
    pgrep -f '[s]ing-box' >/dev/null 2>&1 || return 1
    /usr/bin/sing-box check -c "$CONFIG" >/dev/null 2>&1 || return 1
    validate_config || return 1
    fakeip_ready
}

wait_for_ready() {
    attempt=1

    while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
        configuration_ready && return 0
        sleep "$READY_DELAY"
        attempt=$((attempt + 1))
    done

    return 1
}

show_check_error() {
    [ -s "$CONFIG" ] || {
        log 'sing-box config was not created'
        return 0
    }

    /usr/bin/sing-box check -c "$CONFIG" 2>&1 | \
        while IFS= read -r line; do
            log "sing-box check: $line"
        done
}

backup_dir="/tmp/router-provisioner-netshift.$$"
rm -rf "$backup_dir"
mkdir -p "$backup_dir"
[ -d "$SUBSCRIPTIONS" ] && cp -a "$SUBSCRIPTIONS" "$backup_dir/"
[ -f "$CONFIG" ] && cp -p "$CONFIG" "$backup_dir/config.json"

patch_extended_detection || exit 1
patch_policy || exit 1

if ! /usr/bin/netshift subscription_update; then
    log 'subscription_update returned an error; waiting for final service state'
fi

if ! wait_for_ready; then
    log 'NetShift did not become ready; forcing one controlled restart'
    /etc/init.d/netshift restart >/dev/null 2>&1 || true
fi

if ! wait_for_ready; then
    show_check_error
    log 'New subscription rejected; restoring the previous cache'

    if [ -d "$backup_dir/subscriptions" ]; then
        rm -rf "$SUBSCRIPTIONS"
        cp -a "$backup_dir/subscriptions" "$SUBSCRIPTIONS"
    fi
    [ -f "$backup_dir/config.json" ] && \
        cp -p "$backup_dir/config.json" "$CONFIG"

    /etc/init.d/netshift restart >/dev/null 2>&1 || true
    rm -rf "$backup_dir"
    exit 1
fi

rm -rf "$backup_dir"
log 'Subscription updated: XHTTP-only config and FakeIP are ready'
EOF_XHTTP_REFRESH

    chmod 700 "$NETSHIFT_REFRESH_HELPER"
    patch_netshift_xhttp_policy || \
        fatal 'Не удалось включить XHTTP-only политику.'
}

'''
script = replace_regex(
    script,
    r"install_xhttp_refresh_helper\(\) \{.*?\n\}\n\nprepare_root_crontab\(\) \{",
    refresh_helper + 'prepare_root_crontab() {',
    'guarded refresh helper',
)
script = replace_once(
    script,
    "configure_youtube_unblock() {\n    must_run uci set \\\n",
    "configure_youtube_unblock() {\n"
    "    for section in $(uci -q show youtubeUnblock 2>/dev/null | \\\n"
    "        sed -n 's/^youtubeUnblock\\.\\([^.=]*\\)=section$/\\1/p'); do\n"
    "        run uci -q delete \"youtubeUnblock.${section}\"\n"
    "    done\n\n"
    "    must_run uci set \\\n",
    'youtubeUnblock section cleanup',
)
script = replace_regex(
    script,
    r"    /etc/init.d/netshift enable \|\| \{.*?\n    configure_netshift_cron\n\}",
    r'''    /etc/init.d/netshift enable || {
        restore_netshift_config
        fatal 'Не удалось включить автозапуск NetShift.'
    }

    /etc/init.d/netshift stop >/dev/null 2>&1 || true
    /usr/bin/netshift list_update || \
        fatal 'Списки NetShift не обновились.'
    "$NETSHIFT_REFRESH_HELPER" || \
        fatal 'NetShift не собрал рабочую XHTTP-only конфигурацию.'
    configure_netshift_cron
}''',
    'initial NetShift activation',
)
readiness_function = r'''wait_for_netshift_ready() {
    attempt=1

    while [ "$attempt" -le "$NETSHIFT_READY_ATTEMPTS" ]; do
        if pgrep -f '[s]ing-box' >/dev/null 2>&1 && \
            /usr/bin/sing-box check \
                -c /etc/sing-box/config.json >/dev/null 2>&1 && \
            validate_xhttp_config /etc/sing-box/config.json && \
            nslookup www.gstatic.com 127.0.0.42 2>/dev/null | \
                grep -Eq '198\.18\.'; then
            return 0
        fi

        sleep "$NETSHIFT_READY_DELAY"
        attempt=$((attempt + 1))
    done

    return 1
}

'''
script = replace_once(
    script,
    'validate_netshift() {\n',
    readiness_function + 'validate_netshift() {\n',
    'readiness waiter insertion',
)
script = replace_regex(
    script,
    r"validate_netshift\(\) \{.*?\n\}\n\napply_services\(\) \{",
    r'''validate_netshift() {
    print_line
    print_line '=== Проверка NetShift ==='

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: проверка NetShift пропущена.'
        return 0
    fi

    sing_box_extended_active || \
        fatal 'Активен не sing-box extended.'

    if ! wait_for_netshift_ready; then
        /usr/bin/sing-box check \
            -c /etc/sing-box/config.json 2>&1 || true
        fatal 'NetShift не поднял XHTTP-only и FakeIP за 120 секунд.'
    fi

    info 'NetShift: XHTTP-only, sing-box и FakeIP готовы.'
}

apply_services() {''',
    'final NetShift validation',
)
SCRIPT.write_text(script, encoding='utf-8')

tests = TESTS.read_text(encoding='utf-8')
new_policy_test = r'''test_xhttp_policy_patch() {
    fixture=$(mktemp -d)
    facade="$fixture/sing_box_config_facade.sh"
    helpers="$fixture/helpers.sh"
    printf '# helpers fixture\n' > "$helpers"
    cat > "$facade" <<'EOF_FACADE'
prepare() {
    jq '
        | [ $candidates[]
            | . as $ob
            | (($ob.remark // $ob.tag // "") | tostring) as $name
          ] as $kept
    '
}
EOF_FACADE

    patch_netshift_xhttp_policy "$facade" "$helpers"
    patch_netshift_xhttp_policy "$facade" "$helpers"
    policy_count=$(grep -Fc 'select($ob.type == "vless" and' "$facade")
    detection_count=$(grep -Fc \
        '# BEGIN ROUTER_PROVISIONER_EXTENDED_DETECTION' "$helpers")

    assert_equal '1' "$policy_count" \
        'XHTTP-only patch must be inserted exactly once'
    assert_equal '1' "$detection_count" \
        'extended detection patch must be inserted exactly once'
    assert_contains "$(cat "$helpers")" '/usr/bin/sing-box version' \
        'extended detection must use the absolute binary path'
    rm -rf "$fixture"
}'''
tests = replace_regex(
    tests,
    r"test_xhttp_policy_patch\(\) \{.*?\n\}",
    new_policy_test,
    'XHTTP policy test',
)
tests = replace_once(
    tests,
    "    assert_contains \"$script\" \\\n        'local_domain_lists=$YOUTUBE_DIRECT_LIST' \\\n        'local YouTube direct list is not connected'\n",
    "    assert_contains \"$script\" \\\n"
    "        'local_domain_lists=$YOUTUBE_DIRECT_LIST' \\\n"
    "        'local YouTube direct list is not connected'\n"
    "    assert_contains \"$script\" \\\n"
    "        'wait_for_netshift_ready' \\\n"
    "        'bounded NetShift readiness wait is missing'\n"
    "    assert_contains \"$script\" \\\n"
    "        'subscription_update returned an error' \\\n"
    "        'guarded refresh must tolerate restart races'\n"
    "    assert_contains \"$script\" \\\n"
    "        'sing-box check:' \\\n"
    "        'guarded refresh must expose validation errors'\n"
    "    assert_not_contains \"$script\" \\\n"
    "        'sleep 2' \\\n"
    "        'fixed two-second readiness delay must not remain'\n",
    'NetShift schema assertions',
)
tests = replace_once(
    tests,
    "    assert_contains \"$script\" \\\n        'kmod-nft-queue kmod-nf-conntrack' \\\n        'youtubeUnblock kernel dependencies are missing'\n",
    "    assert_contains \"$script\" \\\n"
    "        'kmod-nft-queue kmod-nf-conntrack' \\\n"
    "        'youtubeUnblock kernel dependencies are missing'\n"
    "    assert_contains \"$script\" \\\n"
    "        'sed -n '\"'\"'s/^youtubeUnblock' \\\n"
    "        'duplicate youtubeUnblock sections must be removed'\n",
    'youtubeUnblock assertions',
)
TESTS.write_text(tests, encoding='utf-8')
VERSION.write_text('1.2.0\n', encoding='utf-8')
