#!/bin/sh
# Hub enrolment: the last, optional step of a run. Nothing here may stop the
# run - the router is already configured by the time this is reached.

HUB_BASE_DEFAULT='https://anfisson.duckdns.org/hub'
HUB_CONF_PATH='/etc/router-provisioner/hub.conf'
HUB_TOKEN_RE='^[A-Za-z0-9_-]{16,64}$'

# People paste either the bare code or the whole one-line command shown on the
# hub page, so accept both. Same alphabet and length as the hub's TOKEN_RE.
extract_enroll_token() {
    input=$1
    candidate=$(printf '%s\n' "$input" | \
        sed -n 's#.*/enroll/\([A-Za-z0-9_-]*\).*#\1#p' | head -n 1)
    if [ -z "$candidate" ]; then
        candidate=$(printf '%s' "$input" | tr -d ' \t\r\n')
    fi
    printf '%s\n' "$candidate" | grep -Eq "$HUB_TOKEN_RE" || return 1
    printf '%s\n' "$candidate"
}

# The script is run as root, so refuse anything that is not what the hub
# serves (an error page, a captive-portal answer).
enroll_script_ok() {
    file=$1
    [ "$(head -n 1 "$file" 2>/dev/null)" = '#!/bin/ash' ] || return 1
    grep -qF "$HUB_CONF_PATH" "$file"
}

configure_hub() {
    if [ -f "$HUB_CONF_PATH" ]; then
        # Never source the file: it holds the hub key.
        hub_url=$(grep '^HUB_URL=' "$HUB_CONF_PATH" | head -n 1 | \
            sed "s/^HUB_URL=//; s/^'//; s/'\$//")
        log "Роутер уже подключён к хабу: $hub_url"
        return 0
    fi

    if [ "$ASSUME_YES" -eq 1 ]; then
        log 'Подключение к хабу пропущено (--yes): код вводится вручную.'
        return 0
    fi

    hub_input=$(ask_value 'Код подключения к хабу (Enter — пропустить)') || \
        hub_input=''
    if [ -z "$hub_input" ]; then
        log 'Подключение к хабу пропущено.'
        return 0
    fi

    if ! hub_token=$(extract_enroll_token "$hub_input"); then
        warn 'Это не код подключения. Хаб пропущен, код можно ввести при следующем запуске.'
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "Dry-run: скачал бы $HUB_BASE_DEFAULT/enroll/<код> и запустил его."
        return 0
    fi

    hub_script="$TMP_DIR/hub-enroll"
    if ! fetch_to_file "$HUB_BASE_DEFAULT/enroll/$hub_token" "$hub_script" || \
        ! enroll_script_ok "$hub_script"; then
        warn 'Код не принят: истёк, уже использован или хаб недоступен.'
        return 0
    fi

    /bin/sh "$hub_script" || warn 'Скрипт подключения завершился с ошибкой.'
    return 0
}
