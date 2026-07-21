from pathlib import Path

SCRIPT = Path('router-provisioner.sh')
TESTS = Path('tests/test_router_provisioner.sh')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


script = SCRIPT.read_text(encoding='utf-8')
script = replace_once(
    script,
    'NETSHIFT_READY_ATTEMPTS=40\nNETSHIFT_READY_DELAY=3\n',
    'NETSHIFT_READY_ATTEMPTS=30\nNETSHIFT_READY_DELAY=2\n',
    'final readiness constants',
)
script = replace_once(
    script,
    'MAX_ATTEMPTS=40\nREADY_DELAY=3\n',
    'MAX_ATTEMPTS=30\nREADY_DELAY=2\n',
    'refresh readiness constants',
)
script = replace_once(
    script,
    "    pgrep -f '[s]ing-box' >/dev/null 2>&1 || return 1\n",
    "    pgrep -f '[s]ing-box run' >/dev/null 2>&1 || return 1\n",
    'helper process check',
)
script = replace_once(
    script,
    '''    if [ -d "$backup_dir/subscriptions" ]; then
        rm -rf "$SUBSCRIPTIONS"
        cp -a "$backup_dir/subscriptions" "$SUBSCRIPTIONS"
    fi
''',
    '''    rm -rf "$SUBSCRIPTIONS"
    if [ -d "$backup_dir/subscriptions" ]; then
        cp -a "$backup_dir/subscriptions" "$SUBSCRIPTIONS"
    fi
''',
    'subscription rollback',
)
script = replace_once(
    script,
    '''wait_for_netshift_ready() {
    attempt=1

    while [ "$attempt" -le "$NETSHIFT_READY_ATTEMPTS" ]; do
        if pgrep -f '[s]ing-box' >/dev/null 2>&1 && \\
            /usr/bin/sing-box check \\
                -c /etc/sing-box/config.json >/dev/null 2>&1 && \\
            validate_xhttp_config /etc/sing-box/config.json && \\
            nslookup www.gstatic.com 127.0.0.42 2>/dev/null | \\
                grep -Eq '198\\.18\\.'; then
            return 0
        fi

        sleep "$NETSHIFT_READY_DELAY"
        attempt=$((attempt + 1))
    done

    return 1
}
''',
    '''netshift_fakeip_ready() {
    nslookup www.gstatic.com 127.0.0.42 2>/dev/null | \\
        grep -Eq '198\\.18\\.'
}

wait_for_netshift_ready() {
    attempt=1

    while [ "$attempt" -le "$NETSHIFT_READY_ATTEMPTS" ]; do
        if pgrep -f '[s]ing-box run' >/dev/null 2>&1 && \\
            /usr/bin/sing-box check \\
                -c /etc/sing-box/config.json >/dev/null 2>&1 && \\
            validate_xhttp_config /etc/sing-box/config.json && \\
            netshift_fakeip_ready; then
            return 0
        fi

        sleep "$NETSHIFT_READY_DELAY"
        attempt=$((attempt + 1))
    done

    return 1
}
''',
    'final readiness function',
)
script = replace_once(
    script,
    "        fatal 'NetShift не поднял XHTTP-only и FakeIP за 120 секунд.'\n",
    "        fatal 'NetShift не поднял XHTTP-only и FakeIP за 60 секунд.'\n",
    'readiness error',
)
SCRIPT.write_text(script, encoding='utf-8')

tests = TESTS.read_text(encoding='utf-8')
tests = replace_once(
    tests,
    "    printf '%s\n' '# helpers fixture' > \"$helpers\"\n",
    "    printf '%s\\n' '# helpers fixture' > \"$helpers\"\n",
    'fixture newline',
)
tests = replace_once(
    tests,
    "        'MAX_ATTEMPTS=40' \\\n        'guarded refresh must use bounded readiness polling'",
    "        'MAX_ATTEMPTS=30' \\\n        'guarded refresh must use bounded readiness polling'",
    'readiness assertion',
)
TESTS.write_text(tests, encoding='utf-8')
