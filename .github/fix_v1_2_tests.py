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
path.write_text(text.replace(old, new, 1), encoding='utf-8')
