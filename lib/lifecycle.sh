#!/bin/sh
# Install deterministic NetShift boot and refresh helpers.

BOOT_HELPER='/usr/bin/router-provisioner-netshift-start'
REFRESH_HELPER='/usr/bin/router-provisioner-netshift-refresh'
BOOT_SERVICE='/etc/init.d/router-provisioner-netshift'
UPGRADE_HELPER='/usr/bin/router-provisioner-upgrade'
REPORT_HELPER='/usr/bin/router-provisioner-report'
VERSION_FILE='/etc/router-provisioner/version'

install_lifecycle_helpers() {
    runtime_dir=${ROUTER_PROVISIONER_RUNTIME_DIR:-}
    [ -n "$runtime_dir" ] || fatal 'Runtime directory is not set.'

    if [ "$DRY_RUN" -eq 1 ]; then
        log 'Guarded NetShift lifecycle would be installed.'
        return 0
    fi

    copy_lifecycle_helpers "$runtime_dir"

    cat > "$BOOT_SERVICE" <<'EOF_SERVICE'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    # One-shot boot task: it starts NetShift, verifies it and exits. Never add
    # respawn here - procd would restart it seconds after every exit, and each
    # run stops and restarts NetShift, which flaps the connection endlessly.
    procd_open_instance
    procd_set_param command /usr/bin/router-provisioner-netshift-start
    procd_set_param stdout 1
    procd_set_param stderr 1
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

    schedule_nightly_maintenance
}

schedule_nightly_maintenance() {
    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    temporary="/tmp/router-provisioner-cron.$$"
    # NetShift rewrites its own jobs to 09:13 and 09:17 on every restart, so a
    # crontab we are already rewriting must be corrected here too - otherwise a
    # re-run leaves the router doing its maintenance in the middle of the day.
    # Same treatment as the boot helper: drop NetShift's own subscription job,
    # which the refresh helper does better because it can roll back, and move
    # the list update to the small hours.
    grep -vE 'router-provisioner-netshift-refresh|router-provisioner-upgrade|router-provisioner-report' \
        /etc/crontabs/root | \
        grep -v '/usr/bin/netshift subscription_update' | \
        sed 's|^.*/usr/bin/netshift list_update *$|30 3 * * * /usr/bin/netshift list_update|' \
        > "$temporary" || true
    {
        cat "$temporary"
        # Not :17 - NetShift's own subscription cron lands there for every
        # interval it offers, and two updaters rewriting the same cache at the
        # same minute is how a working subscription turns into a broken one.
        # Nightly, not hourly. Every refresh restarts sing-box, and a restart
        # drops whatever node a selector was pinned to: sing-box keeps that
        # choice in memory only. A service then sees a new exit address and
        # asks the user to log in again. Twenty-four of those a day is a lot of
        # noise for a subscription that changes once in a while.
        printf '0 3 * * * %s\n' "$REFRESH_HELPER"
        # After the subscription refresh, so a component upgrade lands on a
        # configuration that is already current.
        printf '45 3 * * * %s\n' "$UPGRADE_HELPER"
        # Every five minutes: often enough that a stopped service is noticed
        # while it still matters, rare enough to stay invisible in the log.
        printf '*/5 * * * * %s\n' "$REPORT_HELPER"
    } > /etc/crontabs/root
    rm -f "$temporary"
    chmod 600 /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || \
        warn 'Cron restart failed; helper is installed but not scheduled.'
}

copy_lifecycle_helpers() {
    _lc_runtime=$1

    cp "$_lc_runtime/router-provisioner-netshift-start" \
        "$BOOT_HELPER" || fatal 'Failed to copy NetShift start helper.'
    chmod 700 "$BOOT_HELPER" || \
        fatal 'Failed to set permissions on NetShift start helper.'

    cp "$_lc_runtime/router-provisioner-netshift-refresh" \
        "$REFRESH_HELPER" || fatal 'Failed to copy NetShift refresh helper.'
    chmod 700 "$REFRESH_HELPER" || \
        fatal 'Failed to set permissions on NetShift refresh helper.'

    cp "$_lc_runtime/router-provisioner-upgrade" \
        "$UPGRADE_HELPER" || fatal 'Failed to copy the upgrade helper.'
    chmod 700 "$UPGRADE_HELPER" || \
        fatal 'Failed to set permissions on the upgrade helper.'

    cp "$_lc_runtime/router-provisioner-report" \
        "$REPORT_HELPER" || fatal 'Failed to copy the report helper.'
    chmod 700 "$REPORT_HELPER" || \
        fatal 'Failed to set permissions on the report helper.'

    # The router reports its own version, so an outdated router is visible from
    # the monitoring side instead of requiring an ssh session to each one.
    mkdir -p "$(dirname "$VERSION_FILE")"
    printf '%s\n' "$VERSION" > "$VERSION_FILE"
}

# A router that already runs the guard must pick up fixes on a re-run even when
# the owner declines the install question - they are declining a change of
# setup, not asking to keep a stale helper. Only the files and the schedule are
# touched here; what is enabled and what is running stays as the owner left it.
refresh_lifecycle_helpers() {
    [ -x "$BOOT_SERVICE" ] || return 0
    [ "$DRY_RUN" -eq 0 ] || return 0

    runtime_dir=${ROUTER_PROVISIONER_RUNTIME_DIR:-}
    [ -n "$runtime_dir" ] || return 0

    log 'Сторожевой запуск уже установлен, обновляю хелперы и расписание.'
    copy_lifecycle_helpers "$runtime_dir"
    schedule_nightly_maintenance
}
