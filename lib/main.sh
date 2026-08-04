#!/bin/sh
# Router Provisioner runtime entrypoint.

set -eu

RUNTIME_DIR=${ROUTER_PROVISIONER_RUNTIME_DIR:-}
[ -n "$RUNTIME_DIR" ] || {
    printf '[ERROR] Runtime directory is not set. Use router-provisioner.sh.\n' >&2
    exit 1
}

# shellcheck source=lib/common.sh
. "$RUNTIME_DIR/common.sh"
# shellcheck source=lib/system.sh
. "$RUNTIME_DIR/system.sh"
# shellcheck source=lib/netshift.sh
. "$RUNTIME_DIR/netshift.sh"
# shellcheck source=lib/youtubeunblock.sh
. "$RUNTIME_DIR/youtubeunblock.sh"
# shellcheck source=lib/adblock.sh
. "$RUNTIME_DIR/adblock.sh"
# shellcheck source=lib/pinning.sh
. "$RUNTIME_DIR/pinning.sh"
# shellcheck source=lib/lifecycle.sh
. "$RUNTIME_DIR/lifecycle.sh"

usage() {
    cat <<EOF_USAGE
Использование: $PROGRAM [--diagnose] [--dry-run] [--yes] [--version]

  --diagnose  Только диагностика устройства.
  --dry-run   Показать действия без изменения системы.
  --yes       Автоматически подтверждать обычные вопросы.
  --version   Показать версию.
  --help      Показать справку.
EOF_USAGE
}

print_final_report() {
    printf '\n=== Готово ===\n'
    [ -n "$CONFIG_BACKUP" ] && printf 'Backup: %s\n' "$CONFIG_BACKUP"

    if [ "$NETSHIFT_READY" -eq 1 ] && [ "$SUBSCRIPTION_COUNT" -eq 0 ]; then
        printf '\nПодписка не задана. NetShift настроен, но остановлен.\n'
        printf 'Добавьте ссылку: LuCI -> Services -> NetShift -> Секции -> VPN,\n'
        printf 'затем запустите этот скрипт повторно.\n\n'
    fi

    printf 'Проверка NetShift: netshift global_check\n'
    printf 'Проверка youtubeUnblock: %s status\n' "$YOUTUBEUNBLOCK_SERVICE"
    printf 'Журнал старта: logread -e router-provisioner-boot\n'

    if [ "$PINNED_COUNT" -gt 0 ]; then
        printf 'Фиксация узлов: logread -e router-provisioner-pin\n'
    fi

    printf 'Безопасное обновление: %s\n' "$REFRESH_HELPER"
    warn 'Dropbear не перезапущен. Проверьте новый вход во втором терминале.'
}

main() {
    parse_arguments "$@"
    require_environment

    TMP_DIR=$(mktemp -d "/tmp/${PROGRAM}.runtime.XXXXXX") || \
        fatal 'Не удалось создать временный каталог.'
    trap cleanup_runtime 0 HUP INT TERM

    printf '%s v%s\n' "$PROGRAM" "$VERSION"
    print_diagnostics

    [ "$DIAGNOSE_ONLY" -eq 1 ] && exit 0

    create_configuration_backup
    install_required_packages
    configure_identity
    configure_ssh
    configure_wifi

    # Every block below is optional. Declining one - or a component failing to
    # install - never aborts the run: the remaining steps still get their turn.
    run_netshift_steps
    run_youtubeunblock_steps
    configure_adblock

    if [ "$NETSHIFT_READY" -eq 1 ]; then
        configure_pinned_sections
        run_lifecycle_steps
    fi

    print_final_report
}

run_netshift_steps() {
    NETSHIFT_READY=0

    printf '\n'
    ask_yes_no 'Установить и настроить NetShift?' yes || {
        log 'NetShift пропущен.'
        return 0
    }

    if ! install_netshift; then
        warn 'NetShift не установлен, зависимые шаги пропускаются.'
        return 0
    fi

    if ! install_extended_sing_box; then
        warn 'sing-box extended недоступен, подписка работать не будет.'
        return 0
    fi

    configure_netshift
    NETSHIFT_READY=1
}

run_youtubeunblock_steps() {
    printf '\n'
    log 'youtubeUnblock снимает блокировку YouTube на прямом маршруте.'

    ask_yes_no 'Установить youtubeUnblock?' yes || {
        log 'youtubeUnblock пропущен.'
        return 0
    }

    if ! install_youtubeunblock; then
        warn 'youtubeUnblock не установлен, настройка пропускается.'
        return 0
    fi

    configure_youtubeunblock
    start_youtubeunblock
}

run_lifecycle_steps() {
    printf '\n'
    log 'Сторожевой запуск поднимает NetShift после перезагрузки и'
    log 'останавливает его, если тот не поднялся, чтобы не потерять интернет.'

    ask_yes_no 'Установить сторожевой запуск и обновление подписки?' yes || {
        log 'Сторожевой запуск пропущен, NetShift стартует штатно.'
        return 0
    }

    install_lifecycle_helpers
    start_and_validate_netshift
}

main "$@"
