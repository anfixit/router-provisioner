import re
from pathlib import Path

path = Path('tests/test_router_provisioner.sh')
text = path.read_text(encoding='utf-8')

old = """    assert_not_contains "$script" \\
        'sleep 2' \\
        'fixed two-second readiness delay must not remain'
"""
new = """    assert_contains "$script" \\
        'MAX_ATTEMPTS=40' \\
        'guarded refresh must use bounded readiness polling'
"""
if text.count(old) != 1:
    raise RuntimeError('readiness assertion block not found exactly once')
text = text.replace(old, new, 1)

policy_test = r'''test_xhttp_policy_patch() {
    fixture=$(mktemp -d)
    facade="$fixture/sing_box_config_facade.sh"
    helpers="$fixture/helpers.sh"
    printf '%s\n' '# helpers fixture' > "$helpers"
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
}

'''
pattern = (
    r'test_xhttp_policy_patch\(\) \{.*?'
    r'(?=test_xhttp_config_validation\(\) \{)'
)
text, count = re.subn(pattern, policy_test, text, count=1, flags=re.DOTALL)
if count != 1:
    raise RuntimeError('XHTTP policy test block not found exactly once')

path.write_text(text, encoding='utf-8')
