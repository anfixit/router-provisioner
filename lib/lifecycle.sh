#!/bin/sh
# Install deterministic NetShift boot and refresh helpers.

BOOT_HELPER='/usr/bin/router-provisioner-netshift-start'
REFRESH_HELPER='/usr/bin/router-provisioner-netshift-refresh'
BOOT_SERVICE='/etc/init.d/router-provisioner-netshift'

install_lifecycle_helpers() {
    runtime_dir=${ROUTER_PROVISIONER_RUNTIME_DIR:-}
    [ -n "$runtime_dir" ] || fatal 'Runtime directory is not set.'

    if [ "$DRY_RUN" -eq 1 ]; then
        log 'Guarded NetShift lifecycle would be installed.'
        return 0
    fi

    install -m 700 \
        "$runtime_dir/router-provisioner-netshift-start" \
        "$BOOT_HELPER" || fatal 'Failed to install NetShift start helper.'
    install -m 700 \
        "$runtime_dir/router-provisioner-netshift-refresh" \
        "$REFRESH_HELPER" || fatal 'Failed to install NetShift refresh helper.'

    cat > "$BOOT_SERVICE" <<'EOF_SERVICE'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/router-provisioner-netshift-start
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 0
    procd_close_instance
}

stop_service() {
    /etc/init.d/netshift stop >/dev/null 2>&1 || true
}
EOF_SERVICE
    chmod 755 "$BOOT_SERVICE"

    /etc/init.d/netshift stop >/dev/null 2>&1 || true
    /etc/init.d/netshift disable >/dev/null 2>&1 || true
    "$BOOT_SERVICE" enable || fatal 'Failed to enable NetShift guard service.'

    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    temporary="/tmp/router-provisioner-cron.$$"
    grep -v 'router-provisioner-netshift-refresh' \
        /etc/crontabs/root > "$temporary" || true
    {
        cat "$temporary"
        printf '17 * * * * %s\n' "$REFRESH_HELPER"
    } > /etc/crontabs/root
    rm -f "$temporary"
    chmod 600 /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || \
        warn 'Cron restart failed; helper is installed but not scheduled.'
}
